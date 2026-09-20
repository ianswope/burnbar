"""A duplicate name at the root of a QML file makes the whole type unavailable.

Twice in one afternoon (2026-09-20) the widget vanished from the bar with the
only evidence in the shell's own log: first a second `onOpenedChanged` handler,
then a second `clockText` function. qmllint parses both files happily - the
syntax is fine, the declaration is not - so the failure only shows up when
Quickshell loads the plugin, by which point the bar is already empty.

QML allows one handler per signal and one method per name in a scope. These
checks look at the root scope of each file, which is where a careless insert
lands, and they are deliberately simple: no QML parser, just the indentation the
house style already enforces.
"""
import re
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
QML = ["BarWidget.qml", "BurnPanel.qml", "Service.qml"]

# Root-scope declarations are indented exactly two spaces in these files.
FUNCTION = re.compile(r"^  function ([A-Za-z_][A-Za-z0-9_]*)\s*\(", re.M)
HANDLER = re.compile(r"^  (on[A-Z][A-Za-z0-9_]*)\s*:", re.M)
PROPERTY = re.compile(r"^  (?:readonly )?property (?:[A-Za-z_][\w.<>]*) ([A-Za-z_]\w*)\s*:", re.M)


def duplicates(names):
    seen, dupes = set(), []
    for n in names:
        if n in seen and n not in dupes:
            dupes.append(n)
        seen.add(n)
    return dupes


class QmlDuplicateTests(unittest.TestCase):
    def check(self, pattern, what):
        for name in QML:
            text = (REPO / name).read_text()
            found = duplicates(pattern.findall(text))
            self.assertEqual(found, [], f"{name} declares {what} twice: {found}")

    def test_no_function_is_declared_twice_in_a_root_scope(self):
        # "Duplicate method name" - BurnPanel.qml, clockText, 2026-09-20.
        self.check(FUNCTION, "a function")

    def test_no_signal_handler_is_written_twice_in_a_root_scope(self):
        # "Property value set multiple times" - BurnPanel.qml, onOpenedChanged.
        self.check(HANDLER, "a signal handler")

    def test_no_property_is_declared_twice_in_a_root_scope(self):
        self.check(PROPERTY, "a property")

    def test_the_check_would_actually_catch_one(self):
        # A guard that never fires is not a guard.
        self.assertEqual(duplicates(["a", "b", "a"]), ["a"])
        self.assertEqual(
            duplicates(FUNCTION.findall("  function f(x) {}\n  function f(y) {}\n")), ["f"])


if __name__ == "__main__":
    unittest.main()
