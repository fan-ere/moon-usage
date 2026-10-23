"""Exercise the standalone client through real processes and temporary archives."""

import copy
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

import ledger


HERE = Path(__file__).resolve().parent
FIXTURES = HERE / "fixtures"


class LedgerIntegration(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="moon-usage-ledger-")
        self.root = Path(self.temp.name)

    def tearDown(self):
        self.temp.cleanup()

    def cli(self, *arguments, success=True, as_text=False):
        run = subprocess.run(
            [sys.executable, str(HERE / "ledger.py"), *map(str, arguments)],
            capture_output=True, text=True, encoding="utf-8",
        )
        if success:
            self.assertEqual(run.returncode, 0, run.stderr)
            return run.stdout if as_text else json.loads(run.stdout)
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
            self.assertIn("revision", self.cli("compare", before, after, success=False).lower())

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

    def csv_input(self, text):
        path = self.root / "events.csv"
        path.write_text(text, encoding="utf-8")
        return path

    def test_input_limit_bounds_actual_bytes_and_rejects_invalid_utf8(self):
        source = self.root / "size.json"
        with patch.object(ledger, "FILE_LIMIT", 8):
            source.write_bytes(b"12345678")
            self.assertEqual(ledger.read_text(source), "12345678")
            source.write_bytes(b"123456789")
            with self.assertRaisesRegex(ValueError, "exceeds"):
                ledger.read_text(source)
            source.write_bytes("用量输入".encode("utf-8"))
            with self.assertRaisesRegex(ValueError, "exceeds"):
                ledger.read_text(source)
        source.write_bytes(b"\xff")
        target = self.root / "invalid-encoding.bill.json"
        self.assertIn("decode", self.cli("record", source, target, success=False))
        self.assertFalse(target.exists())

    def test_bridge_failures_preserve_diagnostics_and_never_create_archives(self):
        destination = self.root / "failed.bill.json"
        failures = [
            (FileNotFoundError(), "add moon to PATH"),
            (subprocess.TimeoutExpired("moon", 60), "timed out"),
            (subprocess.CompletedProcess([], 1, "", "Compiler error: missing package"), "missing package"),
            (subprocess.CompletedProcess([], 0, "not json", ""), "invalid JSON"),
            (subprocess.CompletedProcess([], 0, "[]", ""), "response object"),
            (subprocess.CompletedProcess([], 0, '{"ok":true}', ""), "omitted snapshot"),
        ]
        for failure, message in failures:
            with self.subTest(message=message):
                kwargs = ({"side_effect": failure} if isinstance(failure, Exception)
                          else {"return_value": failure})
                with patch.object(ledger.subprocess, "run", **kwargs) as call:
                    with self.assertRaisesRegex(ValueError, message):
                        ledger.record(FIXTURES / "initial.json", destination)
                    self.assertEqual(call.call_args.kwargs["timeout"], ledger.BRIDGE_TIMEOUT)
                self.assertFalse(destination.exists())

    def test_csv_to_readable_bill_and_replay(self):
        archive = self.root / "csv-bill.json"
        result = self.cli("import-csv", FIXTURES / "events.csv", FIXTURES / "config.json", archive)
        self.assertEqual(result["total_minor"], "35")
        report = self.cli("report", archive, as_text=True)
        for expected in ("Quantity: 10", "duplicate deliveries: 1", "exact_minor=30/1", "Total minor: 35 CNY"):
            self.assertIn(expected, report)
        saved = json.loads(archive.read_text(encoding="utf-8"))
        self.assertEqual(len(saved["input"]["events"]), 2)
        self.assertEqual(self.cli("verify", archive)["total_minor"], "35")
        saved["bill"]["quote"]["total_minor"] = "99"
        archive.write_text(json.dumps(saved), encoding="utf-8")
        self.assertIn("BillMismatch", self.cli("report", archive, success=False))

    def test_csv_conflicting_retry_is_rejected_before_writing(self):
        source = self.csv_input("id,account,meter,time,value\nx,demo-customer,requests,11,10\nx,demo-customer,requests,11,12\n")
        archive = self.root / "conflict.json"
        self.assertIn("DuplicateConflict", self.cli("import-csv", source, FIXTURES / "config.json", archive, success=False))
        self.assertFalse(archive.exists())

    def test_csv_format_and_scope_errors_do_not_create_archive(self):
        for text in (
            "id,account,meter,time,value\n",
            "id,account,meter,time,value,value\n",
            "id,account,meter,time,value\nx,demo-customer,requests,11,1e1\n",
            "id,account,meter,time,value\nx,demo-customer,requests,11,1.5\n",
            "id,account,meter,time,value\nx,demo-customer,requests,11,-1\n",
            "id,account,meter,time,value\nx,demo-customer,requests,2147483648,1\n",
            "id,account,meter,time,value\nx,demo-customer,requests,11,1,extra\n",
            "id,account,meter,time,value\nx,other,requests,11,1\n",
            'id,account,meter,time,value\n"unclosed,demo-customer,requests,11,1',
        ):
            with self.subTest(text=text):
                archive = self.root / "bad.json"
                self.cli("import-csv", self.csv_input(text), FIXTURES / "config.json", archive, success=False)
                self.assertFalse(archive.exists())

    def test_csv_unknown_configuration_and_invalid_numbers_are_rejected(self):
        original = (FIXTURES / "config.json").read_text(encoding="utf-8")
        for text, expected in (
            (original.replace('"sum"', '"unknown"'), "aggregation"),
            (original.replace('"start": 10', '"start": -0'), "plain integer"),
            (original.replace('"start": 10', '"start": 1e1'), "plain integer"),
            (original.replace('"start": 10', '"start": 10.0000000000000001'), "plain integer"),
            (original.replace('"start": 10', '"start": 10, "start": 11'), "Duplicate"),
            (original.replace('"start": 10', '"extra": 1, "start": 10'), "except events"),
        ):
            with self.subTest(expected=expected, text=text):
                config = self.root / "config.json"
                config.write_text(text, encoding="utf-8")
                archive = self.root / "unknown.json"
                self.assertIn(expected, self.cli("import-csv", FIXTURES / "events.csv", config, archive, success=False))
                self.assertFalse(archive.exists())

    def test_csv_counter_baseline_and_reset_policy(self):
        config = json.loads((FIXTURES / "config.json").read_text(encoding="utf-8"))
        config.update(aggregation="counter", reset_policy="restart_at_zero")
        config_path = self.root / "counter-config.json"
        config_path.write_text(json.dumps(config), encoding="utf-8")
        source = self.csv_input("id,account,meter,time,value\nbase,demo-customer,requests,9,100\nread,demo-customer,requests,11,110\nreset,demo-customer,requests,12,4\n")
        archive = self.root / "counter.json"
        self.assertEqual(self.cli("import-csv", source, config_path, archive)["total_minor"], "43")
        self.assertIn("Baseline: base; resets: 1", self.cli("report", archive, as_text=True))
        config["reset_policy"] = "reject_decrease"
        config_path.write_text(json.dumps(config), encoding="utf-8")
        rejected = self.root / "decrease.json"
        self.assertIn("CounterDecreased", self.cli("import-csv", source, config_path, rejected, success=False))
        self.assertFalse(rejected.exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)
