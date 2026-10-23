"""Inspect the actual source archive, then run its batch example without Git or caches."""

from pathlib import Path, PurePosixPath
import re
import subprocess
import tempfile
import zipfile


ROOT = Path(__file__).resolve().parents[1]


def main():
    manifest = (ROOT / "moon.mod").read_text(encoding="utf-8")
    name = re.search(r'^name\s*=\s*"([^"]+)"', manifest, re.M).group(1)
    version = re.search(r'^version\s*=\s*"([^"]+)"', manifest, re.M).group(1)
    subprocess.run(["moon", "package", "--list"], cwd=ROOT, check=True)
    archive = ROOT / "_build" / "publish" / f"{name.replace('/', '-')}-{version}.zip"
    with zipfile.ZipFile(archive) as package:
        paths = {entry.filename.replace("\\", "/") for entry in package.infolist()}
        required = {"moon.mod", "moon.pkg", "LICENSE", "README.md", "pkg.generated.mbti",
                    "aggregate.mbt", "rating.mbt", "snapshot.mbt", "comparison.mbt", "batch.mbt"}
        if not required <= paths:
            raise RuntimeError(f"Package is incomplete: {sorted(required - paths)}")
        for name in paths:
            path = PurePosixPath(name)
            if path.is_absolute() or ".." in path.parts or ":" in name:
                raise RuntimeError(f"Unsafe archive path: {name}")
            if any(part in {".git", "_build", ".moon", "__pycache__"} for part in path.parts):
                raise RuntimeError(f"Local cache included in package: {name}")
            if (any(word in path.name for word in ("申报", "复审", "报名", "credentials"))
                    or path.name in {"LOCAL_VALIDATION.md", "DEPTH_REVIEW.md", ".env"}
                    or path.suffix == ".pyc"):
                raise RuntimeError(f"Private material included in package: {name}")
        with tempfile.TemporaryDirectory(prefix="moon-usage-package-") as temporary:
            source = Path(temporary)
            package.extractall(source)
            result = subprocess.run(["moon", "run", "examples/batch", "--target", "js"],
                                    cwd=source, capture_output=True, text=True, encoding="utf-8", check=True)
            if result.stdout != "a: 35\nb: 55\nCNY total: 90\n":
                raise RuntimeError("Packaged example produced incorrect bills")
    print(f"Package inspection and clean extracted-source execution passed: {archive}")


if __name__ == "__main__":
    main()
