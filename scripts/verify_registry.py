"""After publication, install the exact registry version in an independent consumer."""

from pathlib import Path
import re
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]


def main():
    manifest = (ROOT / "moon.mod").read_text(encoding="utf-8")
    name = re.search(r'^name\s*=\s*"([^"]+)"', manifest, re.M).group(1)
    version = re.search(r'^version\s*=\s*"([^"]+)"', manifest, re.M).group(1)
    with tempfile.TemporaryDirectory(prefix="moon-usage-consumer-") as temporary:
        source = Path(temporary)
        (source / "moon.mod").write_text('name = "verification/usage-consumer"\nversion = "0.0.1"\n', encoding="utf-8")
        (source / "moon.pkg").write_text('import { "' + name + '" @usage }\n', encoding="utf-8")
        (source / "consumer_test.mbt").write_text('''///|
test "registry package supports billing replay comparison and batch" {
  let plan : @usage.Plan = {
    currency: "CNY", pricing: Graduated, rounding: HalfEven,
    per_units: 1, base_minor: 5,
    tiers: [{ up_to: Some(10), rate: 3 }, { up_to: None, rate: 2 }],
  }
  let events : Array[@usage.Event] = [
    { id: "first", account: "a", meter: "m", time: 11, value: 10 },
  ]
  let input : @usage.BillInput = {
    input_revision: "events-1", plan_revision: "price-1", events,
    account: "a", meter: "m", start: 10, end: 20, aggregation: Sum, plan,
  }
  let decoded = @usage.BillInput::from_string(input.to_json().stringify()).unwrap()
  let snapshot = @usage.capture(decoded).unwrap()
  let restored = @usage.Snapshot::from_string(snapshot.to_string()).unwrap()
  assert_eq(restored.replay().unwrap().quote.total_minor, 35L)
  assert_eq(@usage.compare_snapshots(snapshot, restored).unwrap().total_minor_delta, 0L)
  let requests : Array[@usage.BillRequest] = [
    { id: "bill-a", account: "a", meter: "m", start: 10, end: 20,
      aggregation: Sum, plan_revision: "price-1", plan },
  ]
  assert_eq(@usage.capture_batch(events, "events-1", requests).unwrap().totals[0].total_minor, 35L)
}
''', encoding="utf-8")
        subprocess.run(["moon", "add", "--upgrade", f"{name}@{version}"], cwd=source, check=True)
        subprocess.run(["moon", "check", "--deny-warn"], cwd=source, check=True)
        subprocess.run(["moon", "test", "--deny-warn", "--target", "js"], cwd=source, check=True)
    print(f"Independent registry consumer passed: {name}@{version}")


if __name__ == "__main__":
    main()
