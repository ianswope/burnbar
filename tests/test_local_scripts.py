import importlib.util
from importlib.machinery import SourceFileLoader
import io
import json
from pathlib import Path
import subprocess
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]


def load_script(path, name):
    loader = SourceFileLoader(name, str(path))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    assert spec is not None
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


class FakeResponse(io.BytesIO):
    def __enter__(self):
        return self

    def __exit__(self, *_args):
        return False


# What the status probe's shell snippet prints on the Jetson, verbatim.
TEGRA_SAMPLE = """cpu_ticks 30 120
gpu_load 999
gpu_hz 1020000000 1020000000
temp_gpu 50468
rail_VDD_IN 4968 1520
rail_VDD_CPU_GPU_CV 4960 1784
rail_VDD_SOC 4960 496
fan_pwm 77
mem 7802844 4023972
model NVIDIA Jetson Orin Nano Engineering Reference Developer Kit Super
"""


class ScriptTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.status = load_script(ROOT / "bin" / "burnbar-local-status", "burnbar_local_status")
        cls.control = load_script(ROOT / "bin" / "burnbar-local-control", "burnbar_local_control")
        cls.meter = load_script(ROOT / "nano" / "ollama-meter.py", "ollama_meter")

    # ── URL handling, shared by both scripts ──────────────────────────────
    def test_ollama_host_without_scheme_is_normalized_for_status(self):
        response = FakeResponse(b'{"models": []}')
        with mock.patch.object(self.status.urllib.request, "urlopen", return_value=response) as urlopen:
            self.status.ollama_models("nano:11434")
        self.assertEqual(urlopen.call_args.args[0], "http://nano:11434/api/ps")

    def test_ollama_host_without_scheme_is_normalized_for_control(self):
        response = FakeResponse(b'{"models": []}')
        with mock.patch.object(self.control.urllib.request, "urlopen", return_value=response) as urlopen:
            self.control.request("nano:11434", "/api/tags")
        request = urlopen.call_args.args[0]
        self.assertEqual(request.full_url, "http://nano:11434/api/tags")

    def test_non_http_ollama_urls_are_rejected(self):
        for module in (self.status, self.control):
            with self.subTest(module=module.__name__):
                with self.assertRaises(ValueError):
                    module.normalize_url("file:///tmp/ollama")

    def test_authorityless_ollama_urls_are_rejected(self):
        invalid_urls = ("", "   ", "http://", "https://", "http:///api")
        for module in (self.status, self.control):
            for url in invalid_urls:
                with self.subTest(module=module.__name__, url=url):
                    with self.assertRaises(ValueError):
                        module.normalize_url(url)

    def test_malformed_http_scheme_is_not_reinterpreted_as_a_hostname(self):
        for module in (self.status, self.control):
            for url in ("http:/127.0.0.1:11434", "https:/example.com"):
                with self.subTest(module=module.__name__, url=url):
                    with self.assertRaises(ValueError):
                        module.normalize_url(url)

    def test_urls_with_query_or_fragment_are_rejected(self):
        for module in (self.status, self.control):
            for url in ("http://host:11434/ollama?key=a", "http://host:11434#frag"):
                with self.subTest(module=module.__name__, url=url):
                    with self.assertRaises(ValueError):
                        module.normalize_url(url)

    def test_status_rejects_nonstandard_nonfinite_json_numbers(self):
        with self.assertRaises(ValueError):
            self.status.read_json_response(FakeResponse(b'{"load": NaN}'))

    def test_status_rejects_overflowing_finite_json_syntax(self):
        with self.assertRaises(ValueError):
            self.status.read_json_response(FakeResponse(b'{"load": 1e999}'))

    def test_control_rejects_nonstandard_nonfinite_json_numbers(self):
        response = FakeResponse(b'{"size": Infinity}')
        with mock.patch.object(self.control.urllib.request, "urlopen", return_value=response):
            with self.assertRaises(ValueError):
                self.control.request("http://nano:11434", "/api/tags")

    def test_control_rejects_overflowing_finite_json_syntax(self):
        response = FakeResponse(b'{"size": 1e999}')
        with mock.patch.object(self.control.urllib.request, "urlopen", return_value=response):
            with self.assertRaises(ValueError):
                self.control.request("http://nano:11434", "/api/tags")

    def test_control_passes_model_as_json_data_not_a_shell_command(self):
        model = "model; touch /tmp/local-intelligence-injected"
        response = FakeResponse(b'{"ok": true}')
        with mock.patch.object(self.control.urllib.request, "urlopen", return_value=response) as urlopen:
            self.control.request("http://nano:11434", "/api/generate", {"model": model})
        request = urlopen.call_args.args[0]
        self.assertEqual(json.loads(request.data), {"model": model})

    def test_bounded_int_survives_a_huge_integer(self):
        self.assertEqual(self.status.bounded_int(10**400), 10**16)
        self.assertEqual(self.status.bounded_int(True), 0)
        self.assertEqual(self.status.bounded_int(float("inf")), 0)

    # ── the ssh host is an argument, never an option ───────────────────────
    def test_ssh_host_shapes(self):
        for module in (self.status, self.control):
            with self.subTest(module=module.__name__):
                self.assertEqual(module.ssh_host(" nano "), "nano")
                self.assertEqual(module.ssh_host("pi@10.0.0.9"), "pi@10.0.0.9")
                for bad in ("", "-oProxyCommand=x", "na no", "a" * 129, "n\x00o"):
                    with self.assertRaises(ValueError):
                        module.ssh_host(bad)

    def test_status_passes_host_after_double_dash(self):
        completed = mock.Mock(returncode=0, stdout=TEGRA_SAMPLE, stderr="")
        with mock.patch.object(self.status.subprocess, "run", return_value=completed) as run:
            self.status.telemetry("nano")
        argv = run.call_args.args[0]
        self.assertEqual(argv[0], "ssh")
        self.assertIn("BatchMode=yes", argv)
        self.assertEqual(argv[argv.index("--") + 1], "nano")

    # ── Jetson sysfs → panel fields ───────────────────────────────────────
    def test_telemetry_parses_the_jetson_snippet(self):
        fields = self.status.parse_telemetry(TEGRA_SAMPLE)
        self.assertEqual(fields["gpu"], 99.9)
        self.assertEqual(fields["cpu"], 25.0)
        self.assertEqual((fields["clockMhz"], fields["clockMaxMhz"]), (1020, 1020))
        self.assertEqual(fields["tempC"], 50)
        self.assertAlmostEqual(fields["powerW"], 7.6, places=1)
        self.assertAlmostEqual(fields["gpuRailW"], 8.8, places=1)
        self.assertEqual(fields["fanPct"], 30)
        self.assertEqual((fields["vramTotalMb"], fields["vramUsedMb"]), (7620, 3690))
        self.assertEqual(fields["gpuName"], "Jetson Orin Nano Super")

    def test_telemetry_missing_lines_read_as_absent_not_zero_load(self):
        fields = self.status.parse_telemetry("gpu_hz 1020000000 1020000000\nmodel Something\n")
        self.assertNotIn("gpu", fields)
        self.assertNotIn("powerW", fields)
        self.assertEqual(fields["clockMhz"], 1020)

    def test_telemetry_reports_a_failed_ssh_with_its_reason(self):
        completed = mock.Mock(returncode=255, stdout="", stderr="ssh: connect to host nano port 22: No route to host\n")
        with mock.patch.object(self.status.subprocess, "run", return_value=completed):
            fields, error = self.status.telemetry("nano")
        self.assertEqual(fields, {})
        self.assertIn("No route to host", error)

    def test_telemetry_bounds_a_stalled_ssh(self):
        with mock.patch.object(self.status.subprocess, "run",
                               side_effect=subprocess.TimeoutExpired(["ssh"], 8)):
            fields, error = self.status.telemetry("nano")
        self.assertEqual(fields, {})
        self.assertIn("ssh nano", error)

    def test_telemetry_without_a_gpu_reading_is_an_error(self):
        completed = mock.Mock(returncode=0, stdout="mem 100 50\n", stderr="")
        with mock.patch.object(self.status.subprocess, "run", return_value=completed):
            fields, error = self.status.telemetry("nano")
        self.assertIn("no GPU load", error)
        self.assertEqual(fields["vramUsedMb"], 0)

    # ── model control ─────────────────────────────────────────────────────
    def test_control_refuses_a_model_name_it_would_have_to_change(self):
        with self.assertRaises(ValueError):
            self.control.model_name("a" * 257)
        with self.assertRaises(ValueError):
            self.control.model_name("bad\x00name")
        self.assertEqual(self.control.model_name("llama3.2:3b"), "llama3.2:3b")

    def test_control_warms_embedding_models_through_embed(self):
        responses = [FakeResponse(b'{"capabilities": ["embedding"]}'), FakeResponse(b'{"embeddings": []}')]
        with mock.patch.object(self.control.urllib.request, "urlopen", side_effect=responses) as urlopen:
            self.control.warm("http://nano:11434", "nomic-embed-text")
        self.assertEqual(urlopen.call_args.args[0].full_url, "http://nano:11434/api/embed")
        self.assertEqual(json.loads(urlopen.call_args.args[0].data)["keep_alive"], -1)

    def test_control_warms_completion_models_through_generate(self):
        responses = [FakeResponse(b'{"capabilities": ["completion", "tools"]}'), FakeResponse(b'{"done": true}')]
        with mock.patch.object(self.control.urllib.request, "urlopen", side_effect=responses) as urlopen:
            self.control.warm("http://nano:11434", "llama3.2:3b")
        self.assertEqual(urlopen.call_args.args[0].full_url, "http://nano:11434/api/generate")

    def test_control_cache_drop_is_best_effort(self):
        ok = mock.Mock(returncode=0, stdout="", stderr="")
        with mock.patch.object(self.control.subprocess, "run", return_value=ok) as run:
            self.assertEqual(self.control.prepare("nano"), "")
        argv = run.call_args.args[0]
        self.assertEqual(argv[argv.index("--") + 1], "nano")
        self.assertIn("sudo -n", argv[-1])
        no_sudo = mock.Mock(returncode=1, stdout="", stderr="sudo: a password is required\n")
        with mock.patch.object(self.control.subprocess, "run", return_value=no_sudo):
            self.assertIn("password is required", self.control.prepare("nano"))
        with mock.patch.object(self.control.subprocess, "run", side_effect=FileNotFoundError("ssh")):
            self.assertIn("cache not dropped", self.control.prepare("nano"))
        self.assertEqual(self.control.prepare(""), "")

    # ── the meter's response parsing ──────────────────────────────────────
    def test_meter_reads_counts_from_a_plain_response(self):
        body = json.dumps({"model": "llama3.2:3b", "response": "hi", "done": True,
                           "prompt_eval_count": 31, "eval_count": 7}).encode()
        self.assertEqual(self.meter.counts_from_tail(body), (31, 7, "llama3.2:3b"))

    def test_meter_reads_counts_from_the_last_ndjson_line(self):
        lines = [json.dumps({"model": "m", "response": "a", "done": False}),
                 json.dumps({"model": "m", "response": "b", "done": False}),
                 json.dumps({"model": "m", "response": "", "done": True, "prompt_eval_count": 33, "eval_count": 53})]
        body = ("\n".join(lines) + "\n").encode()
        self.assertEqual(self.meter.counts_from_tail(body), (33, 53, "m"))

    def test_meter_reads_openai_usage_from_json_and_sse(self):
        plain = json.dumps({"model": "m", "usage": {"prompt_tokens": 31, "completion_tokens": 3}}).encode()
        self.assertEqual(self.meter.counts_from_tail(plain)[:2], (31, 3))
        sse = (b'data: {"choices":[{"delta":{"content":"x"}}]}\n\n'
               b'data: {"choices":[],"usage":{"prompt_tokens":5,"completion_tokens":2}}\n\n'
               b'data: [DONE]\n\n')
        self.assertEqual(self.meter.counts_from_tail(sse)[:2], (5, 2))

    def test_meter_embed_has_prompt_only(self):
        body = json.dumps({"model": "nomic-embed-text", "embeddings": [[0.1]], "prompt_eval_count": 4}).encode()
        self.assertEqual(self.meter.counts_from_tail(body), (4, -1, "nomic-embed-text"))

    def test_meter_reads_nothing_from_an_error_or_junk(self):
        self.assertEqual(self.meter.counts_from_tail(b'{"error":"boom"}'), (-1, -1, ""))
        self.assertEqual(self.meter.counts_from_tail(b"not json at all"), (-1, -1, ""))
        self.assertEqual(self.meter.counts_from_tail(b'{"prompt_eval_count": true, "eval_count": -4}'), (-1, -1, ""))

    def test_meter_line_tokens_carry_no_whitespace(self):
        self.assertEqual(self.meter.safe_token("bad model\nname"), "bad_model_name")
        self.assertEqual(self.meter.safe_token(""), "-")

    # ── compute-GPU detection ─────────────────────────────────────────────
    def test_intel_igpu_is_not_a_compute_gpu(self):
        import tempfile
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            intel = root / "0000:00:02.0"
            intel.mkdir()
            (intel / "class").write_text("0x030000\n")
            (intel / "vendor").write_text("0x8086\n")
            self.assertEqual(self.status.pci_compute_gpus(root), [])

    def test_nvidia_display_adapter_counts_as_a_compute_gpu(self):
        import tempfile
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            nvidia = root / "0000:01:00.0"
            nvidia.mkdir()
            (nvidia / "class").write_text("0x030000\n")
            (nvidia / "vendor").write_text("0x10de\n")
            found = self.status.pci_compute_gpus(root)
            self.assertEqual(len(found), 1)
            self.assertEqual(found[0]["vendor"], "NVIDIA")

    def test_amd_3d_controller_counts_as_a_compute_gpu(self):
        import tempfile
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            amd = root / "0000:03:00.0"
            amd.mkdir()
            (amd / "class").write_text("0x030200\n")
            (amd / "vendor").write_text("0x1002\n")
            found = self.status.pci_compute_gpus(root)
            self.assertEqual(found[0]["vendor"], "AMD")

    def test_localhost_is_this_machine(self):
        self.assertTrue(self.status.is_local_host("localhost"))
        self.assertTrue(self.status.is_local_host("127.0.0.1"))
        self.assertFalse(self.status.is_local_host("nano"))
        self.assertFalse(self.status.is_local_host("burnbar-no-such-host"))

    def test_nvidia_smi_na_fields_become_zero(self):
        completed = mock.Mock(
            returncode=0,
            stdout="NVIDIA GeForce RTX 4090, 12, 1024, 24576, 45, 120.50, 450.00, 2100, 2520, [N/A]\n",
            stderr="",
        )
        with mock.patch.object(self.status.shutil, "which", return_value="/usr/bin/nvidia-smi"), \
             mock.patch.object(self.status.subprocess, "run", return_value=completed), \
             mock.patch.object(self.status, "local_ollama_cpu", return_value=4.0):
            fields, error = self.status.nvidia_telemetry()
        self.assertEqual(error, "")
        self.assertEqual(fields["gpuName"], "NVIDIA GeForce RTX 4090")
        self.assertEqual(fields["gpu"], 12.0)
        self.assertEqual(fields["fanPct"], 0)
        self.assertEqual(fields["cpu"], 4.0)


if __name__ == "__main__":
    unittest.main()
