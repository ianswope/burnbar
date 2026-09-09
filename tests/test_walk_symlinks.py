"""Discovery must not lose a session store just because it is a symlink.

os.walk skips symlinked directories by default, so a transcript store moved to
another disk and linked back into place would contribute nothing and say
nothing about it. Following them means a cycle has to be survivable too.
"""
import ast
import os
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]


def load_walk():
    """Pull walk() out of the collector without running a collection."""
    tree = ast.parse((REPO / "bin" / "burnbar-collect").read_text())
    fn = next(n for n in tree.body
              if isinstance(n, ast.FunctionDef) and n.name == "walk")
    ns = {"os": os, "Path": Path}
    exec(compile(ast.Module(body=[fn], type_ignores=[]), "<walk>", "exec"), ns)
    return ns["walk"]


class WalkSymlinkTests(unittest.TestCase):
    def setUp(self):
        self.walk = load_walk()

    def test_finds_transcripts_behind_a_symlinked_directory(self):
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp)
            root = base / "projects"
            (root / "here").mkdir(parents=True)
            (root / "here" / "a.jsonl").write_text("{}")
            elsewhere = base / "on-another-disk"
            elsewhere.mkdir()
            (elsewhere / "b.jsonl").write_text("{}")
            (root / "linked").symlink_to(elsewhere, target_is_directory=True)

            found = sorted(p.name for p in self.walk(root, lambda n: n.endswith(".jsonl")))
            self.assertEqual(found, ["a.jsonl", "b.jsonl"])

    def test_a_symlink_cycle_terminates_and_yields_each_file_once(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "projects"
            (root / "deep").mkdir(parents=True)
            (root / "deep" / "c.jsonl").write_text("{}")
            (root / "deep" / "loop").symlink_to(root, target_is_directory=True)

            found = [p.name for p in self.walk(root, lambda n: n.endswith(".jsonl"))]
            self.assertEqual(found, ["c.jsonl"])

    def test_a_broken_symlink_is_not_fatal(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "projects"
            root.mkdir(parents=True)
            (root / "d.jsonl").write_text("{}")
            (root / "gone").symlink_to(Path(tmp) / "missing", target_is_directory=True)

            found = [p.name for p in self.walk(root, lambda n: n.endswith(".jsonl"))]
            self.assertEqual(found, ["d.jsonl"])

    def test_a_missing_root_yields_nothing(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.assertEqual(list(self.walk(Path(tmp) / "nope", lambda n: True)), [])


if __name__ == "__main__":
    unittest.main()
