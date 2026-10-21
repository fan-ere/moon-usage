"""Exercise the standalone client through real processes and temporary archives."""

import copy
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


HERE = Path(__file__).resolve().parent
FIXTURES = HERE / "fixtures"


class LedgerIntegration(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="moon-usage-ledger-")
        self.root = Path(self.temp.name)

    def tearDown(self):
        self.temp.cleanup()

    def cli(self, *arguments, success=True):
        run = subprocess.run(
            [sys.executable, str(HERE / "ledger.py"), *map(str, arguments)],
            capture_output=True, text=True, encoding="utf-8",
        )
        if success:
            self.assertEqual(run.returncode, 0, run.stderr)
            return json.loads(run.stdout)
        self.assertEqual(run.returncode, 2, run.stdout + run.stderr)
        return run.stderr

    def archive(self, fixture, name="bill.json"):
        destination = self.root / name
        self.cli("record", FIXTURES / fixture, destination)
        return destination

    def altered_input(self, name, change):
        value = json.loads((FIXTURES / "initial.json").read_text(encoding="utf-8"))
        change(value)
        path = self.root / name
        path.write_text(json.dumps(value), encoding="utf-8")
        return path

    def test_archive_late_arrival_and_new_price_workflow(self):
        initial = self.archive("initial.json", "initial.json")
        late = self.archive("late.json", "late.json")
        repriced = self.archive("repriced.json", "repriced.json")
        self.assertEqual(self.cli("verify", initial)["total_minor"], "35")
        self.assertEqual(self.cli("verify", late)["total_minor"], "45")
        self.assertEqual(self.cli("verify", repriced)["total_minor"], "30")
        difference = self.cli("compare", initial, late)
        self.assertEqual(difference["quantity_delta"], 5)
        self.assertEqual(difference["total_minor_delta"], "10")
        self.assertEqual(difference["added_event_ids"], ["late"])
        difference = self.cli("compare", late, repriced)
        self.assertEqual(difference["total_minor_delta"], "-15")
        self.assertTrue(difference["plan_changed"])
        saved = json.loads(initial.read_text(encoding="utf-8"))
        self.assertEqual(len(saved["input"]["events"]), 2)
        self.assertEqual(len(saved["input"]["plan"]["tiers"]), 2)
        self.assertEqual(saved["bill"]["usage"]["duplicate_events"], 1)

    def test_modified_archive_is_rejected_without_rewriting(self):
        path = self.archive("initial.json")
        saved = json.loads(path.read_text(encoding="utf-8"))
        saved["bill"]["quote"]["total_minor"] = "0"
        path.write_text(json.dumps(saved), encoding="utf-8")
        original = path.read_bytes()
        self.assertIn("BillMismatch", self.cli("verify", path, success=False))
        self.assertEqual(path.read_bytes(), original)

    def test_existing_archive_is_not_overwritten(self):
        path = self.archive("initial.json")
        original = path.read_bytes()
        self.cli("record", FIXTURES / "late.json", path, success=False)
        self.assertEqual(path.read_bytes(), original)

    def test_invalid_input_does_not_create_archive(self):
        source = self.altered_input("invalid.json", lambda data: data.update(start=10.5))
        destination = self.root / "not-created.json"
        self.assertIn("InvalidSnapshot", self.cli("record", source, destination, success=False))
        self.assertFalse(destination.exists())
        source.write_text('{"account":"a","account":"b"}', encoding="utf-8")
        self.assertIn("Duplicate key", self.cli("record", source, destination, success=False))
        self.assertFalse(destination.exists())

    def test_comparing_different_currency_or_context_is_rejected(self):
        before = self.archive("initial.json")
        for key in ("currency", "meter"):
            def change(data):
                if key == "currency":
                    data["plan"]["currency"] = "USD"
                    data["plan_revision"] = "usd-plan"
                else:
                    data["meter"] = "another-meter"
            source = self.altered_input(f"{key}-input.json", change)
            after = self.root / f"{key}-bill.json"
            self.cli("record", source, after)
            self.cli("compare", before, after, success=False)

    def test_changed_data_requires_new_revision_labels(self):
        before = self.archive("initial.json")
        for key in ("events", "plan"):
            def change(data):
                if key == "events":
                    for event in data["events"]:
                        event["value"] = 15
                else:
                    data["plan"]["base_minor"] = 7
            source = self.altered_input(f"{key}-input.json", change)
            after = self.root / f"{key}-bill.json"
            self.cli("record", source, after)
            self.assertIn("revision", self.cli("compare", before, after, success=False))

    def test_removed_and_changed_events_are_reported(self):
        before = self.archive("late.json")
        data = json.loads((FIXTURES / "late.json").read_text(encoding="utf-8"))
        data["events"] = [copy.deepcopy(data["events"][0])]
        data["events"][0]["value"] = 8
        data["input_revision"] = "corrected"
        source = self.root / "correction-input.json"
        source.write_text(json.dumps(data), encoding="utf-8")
        after = self.root / "correction.json"
        self.cli("record", source, after)
        difference = self.cli("compare", before, after)
        self.assertEqual(difference["removed_event_ids"], ["late"])
        self.assertEqual(difference["changed_event_ids"], ["first"])
        self.assertEqual(difference["total_minor_delta"], "-16")


if __name__ == "__main__":
    unittest.main(verbosity=2)
