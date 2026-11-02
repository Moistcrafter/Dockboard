import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("package", Path(__file__).parents[1] / "tools/package.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class PackageTests(unittest.TestCase):
    def test_rebuild_preserves_previous_mapped_files(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(module.subprocess, "run"):
            root = Path(directory)
            for name in ("build/Dockboard", "build/runtime/Base.dylib", "src/runtime/Base.m", "build/runtime/Obsolete.dylib", "src/app/Info.plist", "src/app/driver.py"):
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(b"first")
            first = module.package(root)
            self.assertFalse((first / "Contents/Resources/runtime/Obsolete.dylib").exists())
            self.assertEqual(module.package(root), first)
            (root / "build/runtime/Base.dylib").write_bytes(b"second")
            second = module.package(root)
            self.assertNotEqual(first, second)
            self.assertEqual((first / "Contents/Resources/runtime/Base.dylib").read_bytes(), b"first")
            self.assertEqual((second / "Contents/Resources/runtime/Base.dylib").read_bytes(), b"second")
            self.assertEqual((root / "build/Dockboard.app").resolve(), second.resolve())
