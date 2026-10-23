"""Run the CSV-to-bill workflow and leave inspectable artifacts in a new directory."""

import argparse
import json
from pathlib import Path
import subprocess
import sys


ROOT = Path(__file__).resolve().parents[1]
CLIENT = ROOT / "integrations" / "ledger" / "ledger.py"
FIXTURES = CLIENT.parent / "fixtures"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path, help="A directory that does not exist yet")
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)

    def cli(*arguments, rejected=None):
        result = subprocess.run([sys.executable, str(CLIENT), *map(str, arguments)],
                                capture_output=True, text=True, encoding="utf-8", timeout=60)
        if rejected is not None:
            if result.returncode != 2 or rejected not in result.stderr:
                raise RuntimeError(result.stdout + result.stderr)
            return result.stderr.strip()
        if result.returncode != 0:
            raise RuntimeError(result.stdout + result.stderr)
        return result.stdout

    def write_json(name, value):
        path = args.output / name
        path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        return path

    config = json.loads((FIXTURES / "config.json").read_text(encoding="utf-8"))
    initial = args.output / "initial.bill.json"
    first = json.loads(cli("import-csv", FIXTURES / "events.csv", FIXTURES / "config.json", initial))
    if first["total_minor"] != "35":
        raise RuntimeError("Initial amount must be 35")
    verified = json.loads(cli("verify", initial))
    if verified != {"verified": True, "total_minor": "35"}:
        raise RuntimeError("Replay result differs")
    (args.output / "initial.report.txt").write_text(cli("report", initial), encoding="utf-8")

    config["input_revision"] = "events-2"
    late_config = write_json("late.config.json", config)
    late = args.output / "late.bill.json"
    cli("import-csv", FIXTURES / "events-late.csv", late_config, late)
    changes = json.loads(cli("compare", initial, late))
    if changes["quantity_delta"] != 5 or changes["total_minor_delta"] != "10" or changes["added_event_ids"] != ["late"]:
        raise RuntimeError("Late event difference is incorrect")
    config["plan_revision"] = "price-2"
    config["plan"]["tiers"][0]["rate"] = 2
    config["plan"]["tiers"][1]["rate"] = 1
    repriced = args.output / "repriced.bill.json"
    cli("import-csv", FIXTURES / "events-late.csv", write_json("repriced.config.json", config), repriced)
    price_changes = json.loads(cli("compare", late, repriced))
    if price_changes["total_minor_delta"] != "-15" or not price_changes["plan_changed"]:
        raise RuntimeError("Repricing difference is incorrect")

    failures = {}
    header = "id,account,meter,time,value\n"
    for label, rows, error in (
        ("conflict", "x,demo-customer,requests,11,10\nx,demo-customer,requests,11,12\n", "DuplicateConflict"),
        ("format", "x,demo-customer,requests,11,1.5\n", "nonnegative Int32"),
    ):
        source = args.output / f"{label}.csv"
        source.write_text(header + rows, encoding="utf-8")
        destination = args.output / f"{label}.bill.json"
        failures[label] = cli("import-csv", source, FIXTURES / "config.json", destination, rejected=error)
        if destination.exists():
            raise RuntimeError("Rejected input created an archive")
    config["aggregation"] = "unknown"
    destination = args.output / "unknown.bill.json"
    failures["unknown"] = cli("import-csv", FIXTURES / "events.csv", write_json("unknown.config.json", config), destination,
                              rejected="aggregation")
    if destination.exists():
        raise RuntimeError("Unknown configuration created an archive")
    tampered = json.loads(initial.read_text(encoding="utf-8"))
    tampered["bill"]["quote"]["total_minor"] = "0"
    failures["tampered"] = cli("report", write_json("tampered.bill.json", tampered), rejected="BillMismatch")
    evidence = {"initial_minor": "35", "late_minor": "45", "repriced_minor": "30",
                "late_difference": changes, "price_difference": price_changes,
                "verified": verified, "rejections": failures}
    write_json("evidence.json", evidence)
    print(json.dumps({"passed": True, "output": str(args.output.resolve()), **evidence}, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, RuntimeError, subprocess.TimeoutExpired) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        raise SystemExit(2)
