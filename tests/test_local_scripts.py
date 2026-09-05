import importlib.util
from importlib.machinery import SourceFileLoader
import io
import json
import math
from pathlib import Path
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]


def load_script(name):
    path = ROOT / "bin" / name
    loader = SourceFileLoader(name.replace("-", "_"), str(path))
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


class ScriptTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.status = load_script("burnbar-local-status")
        cls.control = load_script("burnbar-local-control")

    def test_ollama_host_without_scheme_is_normalized_for_status(self):
        response = FakeResponse(b'{"models": []}')
        with mock.patch.object(self.status.urllib.request, "urlopen", return_value=response) as urlopen:
            self.status.ollama_models("127.0.0.1:11434")
        self.assertEqual(urlopen.call_args.args[0], "http://127.0.0.1:11434/api/ps")

    def test_ollama_host_without_scheme_is_normalized_for_control(self):
        response = FakeResponse(b'{"models": []}')
        with mock.patch.object(self.control.urllib.request, "urlopen", return_value=response) as urlopen:
            self.control.request("127.0.0.1:11434", "/api/tags")
        request = urlopen.call_args.args[0]
        self.assertEqual(request.full_url, "http://127.0.0.1:11434/api/tags")

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
                self.control.request("http://127.0.0.1:11434", "/api/tags")

    def test_control_rejects_overflowing_finite_json_syntax(self):
        response = FakeResponse(b'{"size": 1e999}')
        with mock.patch.object(self.control.urllib.request, "urlopen", return_value=response):
            with self.assertRaises(ValueError):
                self.control.request("http://127.0.0.1:11434", "/api/tags")

    def test_control_passes_model_as_json_data_not_a_shell_command(self):
        model = "model; touch /tmp/local-intelligence-injected"
        response = FakeResponse(b'{"ok": true}')
        with mock.patch.object(self.control.urllib.request, "urlopen", return_value=response) as urlopen:
            self.control.request(
                "http://127.0.0.1:11434", "/api/generate", {"model": model}
            )
        request = urlopen.call_args.args[0]
        self.assertEqual(json.loads(request.data), {"model": model})

    def test_gpu_probe_tolerates_absent_gpu_tools(self):
        with mock.patch.object(self.status.subprocess, "run", side_effect=FileNotFoundError):
            self.assertEqual(self.status.gpu_load(), (0.0, "cpu", -1))

    def test_gpu_probe_ignores_malformed_rocm_json_shape(self):
        nvidia_failure = mock.Mock(returncode=1, stdout="", stderr="")
        rocm_malformed = mock.Mock(returncode=0, stdout='{"card0": null}', stderr="")
        with mock.patch.object(
            self.status.subprocess, "run", side_effect=[nvidia_failure, rocm_malformed]
        ):
            self.assertEqual(self.status.gpu_load(), (0.0, "cpu", -1))

    def test_gpu_probe_ignores_nonfinite_utilization(self):
        completed = mock.Mock(returncode=0, stdout="0, nan\n1, inf\n", stderr="")
        with mock.patch.object(self.status.subprocess, "run", return_value=completed):
            load, backend, _index = self.status.gpu_load()
        self.assertTrue(math.isfinite(load))
        self.assertEqual((load, backend), (0.0, "cpu"))

    def test_gpu_probe_keeps_valid_devices_when_one_reads_na(self):
        completed = mock.Mock(returncode=0, stdout="0, 80\n1, [N/A]\n", stderr="")
        with mock.patch.object(self.status.subprocess, "run", return_value=completed):
            self.assertEqual(self.status.gpu_load(), (80.0, "nvidia", 0))

    def test_gpu_probe_picks_the_busiest_device_and_its_index(self):
        completed = mock.Mock(returncode=0, stdout="0, 5\n1, 75\n", stderr="")
        with mock.patch.object(self.status.subprocess, "run", return_value=completed):
            self.assertEqual(self.status.gpu_load(), (75.0, "nvidia", 1))

    def test_gpu_stats_asks_about_the_chosen_device(self):
        completed = mock.Mock(returncode=0, stdout="X, 1, 2, 3, 4, 5, 6, 7, 8\n", stderr="")
        with mock.patch.object(self.status.subprocess, "run", return_value=completed) as run:
            self.status.gpu_stats(1)
        self.assertIn("-i", run.call_args.args[0])
        self.assertEqual(run.call_args.args[0][-1], "1")

    def test_rocm_probe_skips_one_unreadable_card(self):
        nvidia_failure = mock.Mock(returncode=1, stdout="", stderr="")
        rocm = mock.Mock(returncode=0, stdout='{"card0": {"GPU use (%)": "75"}, "card1": {"GPU use (%)": "N/A"}}', stderr="")
        with mock.patch.object(self.status.subprocess, "run", side_effect=[nvidia_failure, rocm]):
            self.assertEqual(self.status.gpu_load(), (75.0, "rocm", -1))

    def test_bounded_int_survives_a_huge_integer(self):
        self.assertEqual(self.status.bounded_int(10**400), 10**16)
        self.assertEqual(self.status.bounded_int(True), 0)
        self.assertEqual(self.status.bounded_int(float("inf")), 0)

    def test_urls_with_query_or_fragment_are_rejected(self):
        for module in (self.status, self.control):
            for url in ("http://host:11434/ollama?key=a", "http://host:11434#frag"):
                with self.subTest(module=module.__name__, url=url):
                    with self.assertRaises(ValueError):
                        module.normalize_url(url)

    def test_remote_endpoints_are_recognised(self):
        self.assertTrue(self.status.is_local_endpoint("http://127.0.0.1:11434"))
        self.assertTrue(self.status.is_local_endpoint("localhost:11434"))
        self.assertFalse(self.status.is_local_endpoint("http://10.0.0.5:11434"))

    def test_cpu_load_uses_per_pid_deltas(self):
        samples = [{1: 9000, 2: 1000}, {2: 1100}]
        with mock.patch.object(self.status, "runner_ticks_by_pid", side_effect=samples), \
             mock.patch.object(self.status.time, "sleep"), \
             mock.patch.object(self.status.time, "monotonic", side_effect=[0.0, 0.2]), \
             mock.patch.object(self.status.os, "sysconf", return_value=100), \
             mock.patch.object(self.status.os, "cpu_count", return_value=8):
            self.assertAlmostEqual(self.status.cpu_load(0.2), 62.5)

    def test_control_refuses_a_model_name_it_would_have_to_change(self):
        with self.assertRaises(ValueError):
            self.control.model_name("a" * 257)
        with self.assertRaises(ValueError):
            self.control.model_name("bad\x00name")
        self.assertEqual(self.control.model_name("llama3.1:8b"), "llama3.1:8b")

    def test_control_warms_embedding_models_through_embed(self):
        responses = [FakeResponse(b'{"capabilities": ["embedding"]}'), FakeResponse(b'{"embeddings": []}')]
        with mock.patch.object(self.control.urllib.request, "urlopen", side_effect=responses) as urlopen:
            self.control.warm("http://127.0.0.1:11434", "nomic-embed-text")
        self.assertEqual(urlopen.call_args.args[0].full_url, "http://127.0.0.1:11434/api/embed")
        self.assertEqual(json.loads(urlopen.call_args.args[0].data)["keep_alive"], -1)

    def test_control_warms_completion_models_through_generate(self):
        responses = [FakeResponse(b'{"capabilities": ["completion", "tools"]}'), FakeResponse(b'{"done": true}')]
        with mock.patch.object(self.control.urllib.request, "urlopen", side_effect=responses) as urlopen:
            self.control.warm("http://127.0.0.1:11434", "llama3.1:8b")
        self.assertEqual(urlopen.call_args.args[0].full_url, "http://127.0.0.1:11434/api/generate")


if __name__ == "__main__":
    unittest.main()
