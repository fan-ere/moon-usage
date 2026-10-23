"""Local bill archive client. MoonBit performs every billing/replay calculation."""

import argparse
import csv
import io
import json
import os
import re
from pathlib import Path
import subprocess
import sys


ROOT = Path(__file__).resolve().parents[2]
FILE_LIMIT = 16 * 1024 * 1024


def read_text(path):
    # Bound the read itself: a file may grow after a separate stat() call.
    with path.open("rb") as stream:
        content = stream.read(FILE_LIMIT + 1)
    if len(content) > FILE_LIMIT:
        raise ValueError("Input file exceeds 16 MiB")
    return content.decode("utf-8")


def invoke(command, payload):
    process = subprocess.run(
        ["moon", "run", "integrations/ledger/bridge", "--target", "js"],
        cwd=ROOT,
        input=json.dumps({"command": command, "payload": payload}, ensure_ascii=False),
        capture_output=True,
        text=True,
        encoding="utf-8",
        check=True,
    )
    response = json.loads(process.stdout)
    if response.get("ok") is not True:
        raise ValueError(response.get("error", "MoonBit bridge rejected the request"))
    return response["snapshot"]


def verify(path):
    # Send original text so duplicate JSON keys cannot disappear in a Python parse.
    return invoke("verify", read_text(path))


def record(source, destination):
    snapshot = invoke("capture", read_text(source))
    return save_snapshot(snapshot, destination)


def save_snapshot(snapshot, destination):
    encoded = json.dumps(snapshot, ensure_ascii=False, indent=2) + "\n"
    if len(encoded.encode("utf-8")) > FILE_LIMIT:
        raise ValueError("Archive exceeds the client's 16 MiB limit")
    # Exclusive create: even an existing symlink or concurrent writer cannot be overwritten.
    descriptor = os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="\n") as stream:
            stream.write(encoded)
    except BaseException:
        destination.unlink()
        raise
    return snapshot


def import_csv(source, config, destination):
    """Adapt one account/meter CSV; MoonBit validates and calculates the input."""
    def unique_object(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError(f"Duplicate configuration key: {key}")
            result[key] = value
        return result

    def invalid_number(token):
        raise ValueError(f"Expected a plain integer in configuration: {token}")

    def integer(token):
        if not re.fullmatch(r"0|[1-9][0-9]{0,9}", token) or int(token) > 2147483647:
            return invalid_number(token)
        return int(token)

    data = json.loads(read_text(config), object_pairs_hook=unique_object,
                      parse_int=integer, parse_float=invalid_number, parse_constant=invalid_number)
    keys = {"input_revision", "plan_revision", "account", "meter", "start", "end",
            "aggregation", "reset_policy", "plan"}
    if not isinstance(data, dict) or set(data) != keys:
        raise ValueError("Configuration must contain the BillInput fields except events")
    reader = csv.reader(io.StringIO(read_text(source).removeprefix("\ufeff")), strict=True)
    try:
        header = next(reader, None)
        if header != ["id", "account", "meter", "time", "value"]:
            raise ValueError("CSV header must be id,account,meter,time,value")
        events = []
        for row in reader:
            line = reader.line_num
            if len(row) != 5 or any(not field.strip() for field in row):
                raise ValueError(f"CSV line {line}: expected five nonempty fields")
            if len(events) >= 100000:
                raise ValueError("CSV event limit is 100000")
            if row[1] != data["account"] or row[2] != data["meter"]:
                raise ValueError(f"CSV line {line}: account/meter differs from configuration")
            numbers = []
            for label, token in zip(("time", "value"), row[3:]):
                if not re.fullmatch(r"0|[1-9][0-9]{0,9}", token) or int(token) > 2147483647:
                    raise ValueError(f"CSV line {line}: {label} must be a nonnegative Int32")
                numbers.append(int(token))
            events.append(dict(zip(header, row[:3] + numbers)))
        if not events:
            raise ValueError("CSV must contain at least one event")
    except csv.Error as error:
        raise ValueError(f"CSV line {reader.line_num}: {error}") from error
    data["events"] = events
    snapshot = invoke("capture", json.dumps(data, ensure_ascii=False))
    return save_snapshot(snapshot, destination)


def report(path):
    snapshot = verify(path)
    bill = snapshot["bill"]
    usage, quote = bill["usage"], bill["quote"]
    lines = [
        "moon-usage verified bill",
        f"Account: {bill['account']}", f"Meter: {bill['meter']}",
        f"Period: [{bill['start']}, {bill['end']})",
        f"Input revision: {snapshot['input']['input_revision']}",
        f"Plan revision: {snapshot['input']['plan_revision']}",
        f"Aggregation: {snapshot['input']['aggregation']}",
        f"Quantity: {usage['quantity']}",
        f"Accepted events: {usage['accepted_events']}; duplicate deliveries: {usage['duplicate_events']}",
        f"Baseline: {usage['baseline_id']}; resets: {usage['reset_events']}",
        f"Pricing: {quote['pricing']}; rounding: {quote['rounding']}",
    ]
    for item in quote["lines"]:
        lines.append(f"Tier {item['tier']}: quantity={item['quantity']} rate={item['rate']} "
                     f"exact_minor={item['numerator']}/{quote['denominator']}")
    lines.extend([
        f"Usage minor: {quote['usage_minor']}", f"Base minor: {quote['base_minor']}",
        f"Total minor: {quote['total_minor']} {quote['currency']}",
        "Recomputed from archived input; not a payment request or tax invoice.",
    ])
    return "\n".join(lines)


def compare(before_path, after_path):
    before, after = verify(before_path), verify(after_path)
    old, new = before["input"], after["input"]
    for key in ("account", "meter", "start", "end", "aggregation", "reset_policy"):
        if old[key] != new[key]:
            raise ValueError(f"Cannot compare different billing contexts: {key}")
    if old["plan"]["currency"] != new["plan"]["currency"]:
        raise ValueError("Cannot subtract amounts in different currencies")
    if old["events"] != new["events"] and old["input_revision"] == new["input_revision"]:
        raise ValueError("Changed events require a new input_revision")
    if old["plan"] != new["plan"] and old["plan_revision"] == new["plan_revision"]:
        raise ValueError("Changed prices require a new plan_revision")
    old_events = {event["id"]: event for event in old["events"]}
    new_events = {event["id"]: event for event in new["events"]}
    old_ids, new_ids = set(old_events), set(new_events)
    return {
        "currency": new["plan"]["currency"],
        "before_input_revision": old["input_revision"],
        "after_input_revision": new["input_revision"],
        "before_plan_revision": old["plan_revision"],
        "after_plan_revision": new["plan_revision"],
        "quantity_delta": after["bill"]["usage"]["quantity"] - before["bill"]["usage"]["quantity"],
        "total_minor_delta": str(int(after["bill"]["quote"]["total_minor"]) - int(before["bill"]["quote"]["total_minor"])),
        "added_event_ids": sorted(new_ids - old_ids),
        "removed_event_ids": sorted(old_ids - new_ids),
        "changed_event_ids": sorted(key for key in old_ids & new_ids if old_events[key] != new_events[key]),
        "plan_changed": old["plan"] != new["plan"],
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    create = commands.add_parser("record", help="Calculate input JSON and create a new archive")
    create.add_argument("input", type=Path)
    create.add_argument("archive", type=Path)
    check = commands.add_parser("verify", help="Recompute and check an archived bill")
    check.add_argument("archive", type=Path)
    difference = commands.add_parser("compare", help="Verify two archives and show signed changes")
    difference.add_argument("before", type=Path)
    difference.add_argument("after", type=Path)
    ingest = commands.add_parser("import-csv", help="Calculate CSV events with a JSON billing configuration")
    ingest.add_argument("events", type=Path)
    ingest.add_argument("config", type=Path)
    ingest.add_argument("archive", type=Path)
    display = commands.add_parser("report", help="Verify an archive and print a readable bill")
    display.add_argument("archive", type=Path)
    args = parser.parse_args()
    try:
        if args.command in ("record", "import-csv"):
            result = (record(args.input, args.archive) if args.command == "record"
                      else import_csv(args.events, args.config, args.archive))
            output = {"archive": str(args.archive), "total_minor": result["bill"]["quote"]["total_minor"]}
        elif args.command == "verify":
            result = verify(args.archive)
            output = {"verified": True, "total_minor": result["bill"]["quote"]["total_minor"]}
        elif args.command == "report":
            print(report(args.archive))
            return 0
        else:
            output = compare(args.before, args.after)
        print(json.dumps(output, ensure_ascii=False, indent=2))
        return 0
    except (OSError, ValueError, RecursionError, subprocess.CalledProcessError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
