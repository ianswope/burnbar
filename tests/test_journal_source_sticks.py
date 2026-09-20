"""A warm read must go back to the journal its kept points came from.

On a host with no `ollama-meter` unit, the cold read falls back to Ollama's own
journal and caches `source: "ollama"` with a cursor. Every read after that used
to call journal_lines(cursor) with no unit, which defaults to METER_UNIT, the
unit this host does not run. journalctl returned nothing, no error, and the
`not cursor` guard meant the fallback never fired again.

The lane therefore stayed `available: true` and simply stopped advancing:
on gus it sat at 103,176 tokens with lastAt 22:19:04 for nearly three hours
while Ollama was logging requests the whole time. Frozen, not broken, which is
the hard kind to notice.
"""
import ast
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]


def load(meter_unit="ollama-meter", ollama_unit="ollama"):
    """Pull journal_source_args out of the collector without running a
    collection, with the two unit names pinned."""
    tree = ast.parse((REPO / "bin" / "burnbar-collect").read_text())
    fn = next(n for n in tree.body
              if isinstance(n, ast.FunctionDef) and n.name == "journal_source_args")
    ns = {
        "METER_UNIT": meter_unit, "OLLAMA_UNIT": ollama_unit,
        "JOURNAL_MATCH": "meter ts=", "OLLAMA_MATCH": "print_timing",
    }
    exec(compile(ast.Module(body=[fn], type_ignores=[]), "<j>", "exec"), ns)
    return ns["journal_source_args"]


class JournalSourceSticksTests(unittest.TestCase):
    def test_an_ollama_cache_reads_the_ollama_unit(self):
        unit, match = load()("ollama")
        self.assertEqual(unit, "ollama")
        self.assertEqual(match, "print_timing")

    def test_a_meter_cache_reads_the_meter_unit(self):
        unit, match = load()("meter")
        self.assertEqual(unit, "ollama-meter")
        self.assertEqual(match, "meter ts=")

    def test_an_absent_or_unknown_source_falls_back_to_the_meter(self):
        """A cache written before the Ollama path existed has no source at all,
        and it came from the meter."""
        for source in ("", None, "something-else"):
            unit, match = load()(source)
            self.assertEqual(unit, "ollama-meter", repr(source))
            self.assertEqual(match, "meter ts=", repr(source))

    def test_the_unit_names_are_not_hardcoded(self):
        """--ollama-unit and --meter-host/--meter-unit must still reach it."""
        unit, _ = load(ollama_unit="ollama-custom")("ollama")
        self.assertEqual(unit, "ollama-custom")
        unit, _ = load(meter_unit="meter-custom")("meter")
        self.assertEqual(unit, "meter-custom")

    def test_the_two_sources_never_share_a_match_pattern(self):
        """The line shapes differ, so a cursor from one is meaningless to the
        other and the grep must differ too."""
        ollama, meter = load()("ollama"), load()("meter")
        self.assertNotEqual(ollama[0], meter[0])
        self.assertNotEqual(ollama[1], meter[1])

    def test_the_warm_read_actually_calls_it(self):
        """Guard the wiring, not just the helper: the read that uses a cached
        cursor must pass the resolved unit, or this whole file proves nothing."""
        src = (REPO / "bin" / "burnbar-collect").read_text()
        self.assertIn("read_unit, read_match = journal_source_args(local_source)", src)
        self.assertIn("journal_lines(cursor, read_unit, read_match)", src)
        # and the cold re-read after a refused cursor must use it too
        self.assertIn('journal_lines("", read_unit, read_match)', src)


if __name__ == "__main__":
    unittest.main()
