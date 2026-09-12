"""Reading local GPU tokens out of Ollama's own server journal.

The dedicated ollama-meter unit is optional and is only installed on nano. On
any other Ollama host the lane reported `available: true` and zero tokens while
the GPU was plainly busy, because journalctl's own "-- No entries --" note made
a missing unit look like a quiet one.
"""
import ast
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]


def load():
    src = (REPO / "bin" / "burnbar-collect").read_text()
    tree = ast.parse(src)
    want_fn = {"parse_ollama_journal"}
    want_const = {"RE_OLLAMA_PROMPT", "RE_OLLAMA_EVAL"}
    body = [n for n in tree.body
            if isinstance(n, (ast.Import, ast.ImportFrom))
            or (isinstance(n, ast.FunctionDef) and n.name in want_fn)
            or (isinstance(n, ast.Assign)
                and getattr(n.targets[0], "id", "") in want_const)]
    ns = {}
    exec(compile(ast.Module(body=body, type_ignores=[]), "<ollama>", "exec"), ns)
    return ns


# Real lines, copied from `journalctl -u ollama -o short-unix` on vic.
PROMPT = ("1789090509.744824 vic ollama[2258101]: slot print_timing: id  0 | "
          "task 8079 | prompt eval time =     218.53 ms /    15 tokens "
          "(   14.57 ms per token,    68.64 tokens per second)")
EVAL = ("1789090509.744824 vic ollama[2258101]: slot print_timing: id  0 | "
        "task 8079 |        eval time =   79998.83 ms /  1494 tokens "
        "(   53.58 ms per token,    18.68 tokens per second)")
TOTAL = ("1789090509.744824 vic ollama[2258101]: slot print_timing: id  0 | "
         "task 8079 |       total time =   80217.36 ms /  1509 tokens")
NOISE = ("1789090509.744824 vic ollama[2258101]: [GIN] 2026/09/10 - 21:35:09 | "
         "200 |  1m20s |  127.0.0.1 | POST     \"/api/generate\"")


class OllamaJournalTests(unittest.TestCase):
    def setUp(self):
        self.ns = load()
        self.parse = self.ns["parse_ollama_journal"]

    def test_a_prompt_line_cannot_be_read_as_a_generated_line(self):
        """'prompt eval time' contains 'eval time'. If the eval pattern matched
        it, a 15-token prompt would be counted as 15 generated tokens."""
        self.assertIsNone(self.ns["RE_OLLAMA_EVAL"].match(PROMPT))
        self.assertIsNotNone(self.ns["RE_OLLAMA_PROMPT"].match(PROMPT))

    def test_one_request_becomes_one_point_carrying_both_counts(self):
        points = self.parse([PROMPT, EVAL, TOTAL, NOISE], {})
        self.assertEqual(len(points), 1)
        ts, total, _ident, model, split = points[0]
        self.assertEqual(total, 15 + 1494)
        self.assertEqual(split, [15, 0, 1494, 0])
        self.assertEqual(model, "ollama")
        self.assertEqual(ts, 1789090509744, "short-unix seconds must become ms")

    def test_the_total_line_is_not_counted_a_second_time(self):
        """total = prompt + generated, so counting it would double everything."""
        self.assertEqual(self.parse([PROMPT, EVAL, TOTAL], {})[0][1], 1509)

    def test_a_fully_cached_prompt_still_counts_its_generation(self):
        points = self.parse([EVAL], {})
        self.assertEqual(len(points), 1)
        self.assertEqual(points[0][4], [0, 0, 1494, 0])

    def test_tasks_interleave_without_crossing_counts(self):
        other_p = PROMPT.replace("task 8079", "task 9001").replace("/    15 tokens", "/   500 tokens")
        other_e = EVAL.replace("task 8079", "task 9001").replace("/  1494 tokens", "/     7 tokens")
        points = self.parse([PROMPT, other_p, other_e, EVAL], {})
        self.assertEqual(sorted(p[1] for p in points), [507, 1509])

    def test_an_unpaired_prompt_is_carried_between_reads_not_lost(self):
        state = {}
        self.assertEqual(self.parse([PROMPT], state), [])
        self.assertEqual(self.parse([EVAL], state)[0][4], [15, 0, 1494, 0])

    def test_unpaired_prompts_cannot_grow_without_bound(self):
        state = {}
        for task in range(200):
            self.parse([PROMPT.replace("task 8079", "task %d" % task)], state)
        self.assertLessEqual(len(state["ollamaPrompt"]), 64)

    def test_noise_alone_produces_nothing(self):
        self.assertEqual(self.parse([NOISE, TOTAL, "", "-- No entries --"], {}), [])


if __name__ == "__main__":
    unittest.main()
