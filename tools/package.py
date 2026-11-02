"""Publish immutable bundles so rebuilding never overwrites a loaded library."""
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import uuid


def package(root):
    build = root / "build"
    files = {"Contents/MacOS/Dockboard": build / "Dockboard",
             "Contents/Info.plist": root / "src/app/Info.plist",
             "Contents/Resources/driver.py": root / "src/app/driver.py"}
    for source in sorted((root / "src/runtime").glob("*.m")):
        path = build / "runtime" / (source.stem + ".dylib")
        files["Contents/Resources/runtime/" + path.name] = path
    digest = hashlib.sha256()
    for name, path in sorted(files.items()):
        digest.update(name.encode())
        digest.update(hashlib.sha256(path.read_bytes()).digest())
    bundles = build / "bundles"
    bundles.mkdir(exist_ok=True)
    destination = bundles / digest.hexdigest() / "Dockboard.app"
    if not destination.exists():
        with tempfile.TemporaryDirectory(dir=bundles) as staging:
            app = Path(staging) / "Dockboard.app"
            for name, path in files.items():
                target = app / name
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(path, target)
            subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", str(app)], check=True)
            destination.parent.mkdir()
            app.rename(destination)
    link = build / "Dockboard.app"
    if link.exists() and not link.is_symlink():
        link.rename(bundles / ("previous-" + uuid.uuid4().hex + ".app"))
    temporary = build / (".Dockboard-" + uuid.uuid4().hex)
    temporary.symlink_to(destination.relative_to(build), target_is_directory=True)
    os.replace(temporary, link)
    return destination


if __name__ == "__main__":
    print(package(Path(__file__).resolve().parents[1]))
