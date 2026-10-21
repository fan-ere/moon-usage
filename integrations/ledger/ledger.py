"""Local bill archive client. MoonBit performs every billing/replay calculation."""

import argparse
import json
import os
from pathlib import Path
import subprocess
import sys


ROOT = Path(__file__).resolve().parents[2]
FILE_LIMIT = 16 * 1024 * 1024


def read_text(path):
    if path.stat().st_size > FILE_LIMIT:
        raise ValueError("Input file exceeds 16 MiB")
    return path.read_text(encoding="utf-8")


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
    args = parser.parse_args()
    try:
        if args.command == "record":
            result = record(args.input, args.archive)
            output = {"archive": str(args.archive), "total_minor": result["bill"]["quote"]["total_minor"]}
        elif args.command == "verify":
            result = verify(args.archive)
            output = {"verified": True, "total_minor": result["bill"]["quote"]["total_minor"]}
        else:
            output = compare(args.before, args.after)
        print(json.dumps(output, ensure_ascii=False, indent=2))
        return 0
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
