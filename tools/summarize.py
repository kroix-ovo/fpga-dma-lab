"""Collect successful local simulation reports and source fingerprints."""

import hashlib
import json
from pathlib import Path
import platform
import subprocess
from datetime import datetime, timezone
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]


def main():
    reports = {}
    for simulator in ("icarus", "verilator"):
        directory = ROOT / "artifacts" / simulator
        tree = ET.parse(directory / "results.xml")
        if (
            tree.findall(".//failure")
            or tree.findall(".//error")
            or len(tree.findall(".//testcase")) != 2
        ):
            raise SystemExit(f"Incomplete or failed tests: {simulator}")
        report = json.loads((directory / "report.json").read_text())
        faults = json.loads((directory / "faults.json").read_text())
        if report["status"] != "passed" or faults["status"] != "passed":
            raise SystemExit(f"Failed evidence: {simulator}")
        reports[simulator] = {
            "seed_count": len(report["seeds"]),
            "tlp_count": report["tlp_count"],
            "demos": report["demos"],
            "rtl_test_cases": 2,
        }
    files = []
    for folder, patterns in [
        ("rtl", ("*.sv", "*.svh")),
        ("vendor", ("*.v",)),
        ("python", ("*.py",)),
        ("sim", ("*.py",)),
        ("spec", ("*.json",)),
    ]:
        for pattern in patterns:
            files.extend((ROOT / folder).rglob(pattern))
    fingerprints = {
        str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest()
        for path in sorted(files)
    }
    result = {
        "created_utc": datetime.now(timezone.utc).isoformat(),
        "platform": platform.platform(),
        "python": platform.python_version(),
        "simulations": reports,
        "sha256": fingerprints,
        "scope": "Local transaction-level RTL simulation; no synthesis, physical board, Windows driver or IOMMU validation",
    }
    for tool, command in [
        ("icarus", ["iverilog", "-V"]),
        ("verilator", ["verilator", "--version"]),
    ]:
        result[f"{tool}_version"] = subprocess.check_output(
            command, text=True, stderr=subprocess.DEVNULL
        ).splitlines()[0]
    (ROOT / "artifacts" / "validation.json").write_text(
        json.dumps(result, indent=2) + "\n"
    )
    print(json.dumps(reports, indent=2))


if __name__ == "__main__":
    main()
