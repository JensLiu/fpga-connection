#!/usr/bin/env python3
"""
Launch an N-FPGA-SDR simulation cluster.

Starts one sdr_hub, N Verilator FPGA simulations, and N sdr_sim instances.
All process output is written to per-process log files.

Usage examples:
    python run_sim.py                        # 2 pairs, default ports
    python run_sim.py --pairs 4              # 4 FPGA-SDR pairs
    python run_sim.py --pairs 3 --build      # build first, then run
    python run_sim.py --log-dir /tmp/run1    # custom log directory
"""

import argparse
import pathlib
import signal
import subprocess
import sys
import time

BASE    = pathlib.Path(__file__).parent.resolve()
VTOP    = BASE / "sim" / "obj_dir" / "Vtop"
SDR_SIM = BASE / "sw" / "sdr_sim"
SDR_HUB = BASE / "sw" / "sdr_hub"


def parse_args():
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    ap.add_argument(
        "--pairs", type=int, default=2, metavar="N",
        help="Number of FPGA-SDR pairs (default: 2)",
    )
    ap.add_argument(
        "--hub-port", type=int, default=14000, metavar="PORT",
        help="Hub TCP port (default: 14000)",
    )
    ap.add_argument(
        "--fpga-base-port", type=int, default=12345, metavar="PORT",
        help="First FPGA Verilator port; each pair gets base+i (default: 12345)",
    )
    ap.add_argument(
        "--log-dir", type=pathlib.Path, default=pathlib.Path("logs"), metavar="DIR",
        help="Directory for log files (default: logs/)",
    )
    ap.add_argument(
        "--build", action="store_true",
        help="Run make in sim/ and sw/ before launching",
    )
    return ap.parse_args()


def build():
    for directory in ("sim", "sw"):
        print(f"Building {directory}/...")
        subprocess.run(["make", "-C", str(BASE / directory)], check=True)


def check_binaries():
    missing = [b for b in (VTOP, SDR_SIM, SDR_HUB) if not b.exists()]
    if missing:
        sys.exit(
            "Missing binaries:\n"
            + "\n".join(f"  {b}" for b in missing)
            + "\nRun with --build or build manually."
        )


def main():
    args = parse_args()

    if args.build:
        build()

    check_binaries()

    args.log_dir.mkdir(parents=True, exist_ok=True)

    procs = []   # list of (subprocess.Popen, log_path)
    logs  = []   # open file handles

    def launch(cmd, log_name):
        log_path = args.log_dir / log_name
        f = log_path.open("w")
        logs.append(f)
        p = subprocess.Popen(
            [str(c) for c in cmd],
            stdout=f,
            stderr=subprocess.STDOUT,
        )
        procs.append((p, log_path))
        print(f"  pid={p.pid:<6}  {' '.join(str(c) for c in cmd)}")
        print(f"  {'':6}   -> {log_path}")

    def stop_all(sig=None, _frame=None):
        print("\nStopping all processes...", flush=True)
        for p, _ in procs:
            try:
                p.terminate()
            except OSError:
                pass
        time.sleep(0.5)
        for p, _ in procs:
            if p.poll() is None:
                p.kill()
        for f in logs:
            f.close()
        sys.exit(0)

    signal.signal(signal.SIGINT,  stop_all)
    signal.signal(signal.SIGTERM, stop_all)

    n = args.pairs

    # Each burst costs (TX_BURSTS + 4 control packets) × 52k cycles at div=868.
    # The gap must cover N-1 bursts so every FPGA's S_IDLE window sees all others.
    gap_cycles = max((n - 1) * 650_000, 700_000)

    print(f"\n=== hub (port {args.hub_port}, {n} SDRs) ===")
    launch([SDR_HUB, args.hub_port, n], "hub.log")
    time.sleep(0.2)

    print(f"\n=== {n} FPGA simulation(s)  [gap_cycles={gap_cycles:,}] ===")
    for i in range(n):
        port = args.fpga_base_port + i
        launch([VTOP, port, f"+fpga_id={i + 1}", f"+gap_cycles={gap_cycles}"],
               f"fpga{i + 1}.log")
    time.sleep(0.5)

    print(f"\n=== {n} SDR simulator(s) ===")
    for i in range(n):
        port = args.fpga_base_port + i
        launch([SDR_SIM, "sim", port, args.hub_port], f"sdr{i + 1}.log")

    print(f"\nAll running. Logs in {args.log_dir.resolve()}/")
    print("Ctrl+C to stop.\n")

    # Monitor: report unexpected exits and stop everything if any process dies.
    while True:
        time.sleep(1)
        for p, log_path in list(procs):
            rc = p.poll()
            if rc is not None:
                print(f"  pid={p.pid} ({log_path.name}) exited with code {rc}", flush=True)
                procs.remove((p, log_path))
        if not procs:
            print("All processes have exited.")
            for f in logs:
                f.close()
            sys.exit(0)


if __name__ == "__main__":
    main()
