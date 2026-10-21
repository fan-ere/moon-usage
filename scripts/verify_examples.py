"""Run public examples on all targets and compare their documented results."""

import json
from pathlib import Path
import subprocess


ROOT = Path(__file__).resolve().parents[1]
TARGETS = ("wasm", "wasm-gc", "js", "native")


def run(example, target):
    result = subprocess.run(
        ["moon", "run", f"examples/{example}", "--target", target],
        cwd=ROOT,
        check=True,
        capture_output=True,
        text=True,
        encoding="utf-8",
    )
    return result.stdout


def main():
    expected_text = (ROOT / "docs/demo-output.txt").read_text(encoding="utf-8")
    expected_json = json.loads(
        (ROOT / "docs/bill-example.json").read_text(encoding="utf-8")
    )
    for target in TARGETS:
        if run("demo", target) != expected_text:
            raise RuntimeError(f"{target}: demo output differs from documented result")
        if json.loads(run("export", target)) != expected_json:
            raise RuntimeError(f"{target}: exported bill differs from documented result")
        print(f"{target}: demo text and complete JSON match", flush=True)


if __name__ == "__main__":
    main()
