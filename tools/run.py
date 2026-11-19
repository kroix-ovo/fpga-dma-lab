"""Build and run RTL tests. Requires the project's locked Python environment."""

import argparse
import os
from pathlib import Path
import sys
import xml.etree.ElementTree as ET
from cocotb_tools.runner import get_runner

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--sim", choices=["verilator", "icarus"], default="verilator")
    parser.add_argument("--seeds", type=int, default=100)
    parser.add_argument(
        "--demo", choices=["all", "telemetry", "iq", "none"], default="all"
    )
    parser.add_argument("--waves", action="store_true")
    args = parser.parse_args()
    if not 1 <= args.seeds <= 10000:
        parser.error("--seeds must be 1..10000")
    directory = ROOT / "artifacts" / args.sim
    directory.mkdir(parents=True, exist_ok=True)
    for path in [ROOT / "python", ROOT / "sim"]:
        sys.path.insert(0, str(path))
    os.environ["PYTHONPATH"] = os.pathsep.join(
        [str(ROOT / "python"), str(ROOT / "sim"), os.environ.get("PYTHONPATH", "")]
    )
    os.environ["LAB_SEEDS"] = str(args.seeds)
    os.environ["LAB_DEMO"] = args.demo
    os.environ["LAB_ARTIFACTS"] = str(directory)
    runner = get_runner(args.sim)
    sources = sorted((ROOT / "vendor").glob("*.v")) + sorted(
        (ROOT / "rtl").glob("*.sv")
    )
    flags = (
        [
            "-Wno-fatal",
            "-Wno-WIDTH",
            "-Wno-UNOPTFLAT",
            "-CFLAGS",
            "-std=c++17",
        ]
        if args.sim == "verilator"
        else ["-g2012"]
    )
    runner.build(
        includes=[ROOT / "rtl"],
        sources=sources,
        hdl_toplevel="dma_lab",
        build_dir=directory / "build",
        build_args=flags,
        waves=args.waves,
        always=True,
    )
    for name in (
        "results.xml",
        "report.json",
        "faults.json",
        "scene.svg",
        "telemetry.json",
        "iq.csv",
    ):
        (directory / name).unlink(missing_ok=True)
    runner.test(
        hdl_toplevel="dma_lab",
        test_module="test_system",
        test_dir=directory,
        results_xml="results.xml",
        waves=args.waves,
    )
    results = ET.parse(directory / "results.xml")
    if (
        not results.findall(".//testcase")
        or results.findall(".//failure")
        or results.findall(".//error")
    ):
        raise SystemExit(1)


if __name__ == "__main__":
    main()
