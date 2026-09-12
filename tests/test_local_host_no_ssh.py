"""A meter host that IS this machine must never be reached over ssh.

The collector discovered a GPU locally and then tried to read its journal
through `ssh localhost`. On a host with no key or no trusted host key for
itself that fails, and the lane published "available: false" with
"Host key verification failed" as the only clue — a card sitting right there,
reporting zero tokens.

burnbar-local-status already had is_local_host(); the collector did not, so the
two disagreed about what "local" meant.
"""
import ast
import socket
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]


def load(meter_host):
    """Pull ssh_command + is_local_host out of the collector without running a
    collection, with METER_HOST pinned to the host under test."""
    tree = ast.parse((REPO / "bin" / "burnbar-collect").read_text())
    wanted = {"ssh_command", "is_local_host", "fqdn_once"}
    body = [n for n in tree.body
            if (isinstance(n, ast.FunctionDef) and n.name in wanted)
            or (isinstance(n, ast.Assign)
                and getattr(n.targets[0], "id", "") == "_FQDN")]
    ns = {"socket": socket, "shlex": __import__("shlex"), "METER_HOST": meter_host}
    exec(compile(ast.Module(body=body, type_ignores=[]), "<ssh>", "exec"), ns)
    # Pre-seed the cache: a real getfqdn() blocks for seconds on a host whose
    # name does not resolve, and a test suite must not depend on DNS.
    ns["_FQDN"] = socket.gethostname().strip().rstrip(".").lower()
    return ns


class LocalHostNoSshTests(unittest.TestCase):
    def test_localhost_aliases_run_directly(self):
        for host in ("localhost", "127.0.0.1", "::1", "", "  localhost  "):
            ns = load(host)
            got = ns["ssh_command"](["journalctl", "-u", "ollama"])
            self.assertEqual(got, ["journalctl", "-u", "ollama"],
                             "%r must not be wrapped in ssh" % host)

    def test_this_machines_own_name_runs_directly(self):
        for host in (socket.gethostname(), socket.gethostname().upper(),
                     socket.gethostname() + "."):
            ns = load(host)
            self.assertEqual(ns["ssh_command"](["true"]), ["true"],
                             "%r is this machine" % host)

    def test_the_cheap_names_answer_without_a_dns_lookup(self):
        """getfqdn() blocks for 5s on a host whose name does not resolve, and
        this runs on every journal read. localhost and our own hostname must
        never reach it."""
        calls = []

        def explode():
            calls.append(1)
            raise AssertionError("getfqdn() must not be called for a cheap name")

        for host in ("localhost", "127.0.0.1", "::1", "", socket.gethostname()):
            ns = load(host)
            ns["_FQDN"] = None          # force a miss to be observable
            ns["fqdn_once"] = explode
            self.assertTrue(ns["is_local_host"](host), host)
        self.assertEqual(calls, [], "a cheap name reached DNS")

    def test_the_dns_answer_is_asked_for_once_and_cached(self):
        ns = load("nano")
        ns["_FQDN"] = None
        calls = []
        real = socket.getfqdn

        class Stub:
            gethostname = staticmethod(socket.gethostname)

            @staticmethod
            def getfqdn():
                calls.append(1)
                return "someother.host"
        ns["socket"] = Stub
        self.assertFalse(ns["is_local_host"]("nano"))
        self.assertFalse(ns["is_local_host"]("nano"))
        self.assertFalse(ns["is_local_host"]("other"))
        self.assertEqual(len(calls), 1, "getfqdn() should be cached, saw %d calls" % len(calls))
        self.assertIs(real, socket.getfqdn)

    def test_a_real_remote_still_goes_over_ssh(self):
        ns = load("nano")
        got = ns["ssh_command"](["journalctl", "-u", "ollama-meter"])
        self.assertEqual(got[0], "ssh")
        self.assertIn("BatchMode=yes", got)
        # The host is passed after -- so it can never read as an option, and
        # the remote words arrive as one shell-quoted string.
        self.assertEqual(got[got.index("--") + 1], "nano")
        self.assertEqual(got[-1], "journalctl -u ollama-meter")

    def test_a_user_qualified_remote_is_still_remote(self):
        ns = load("pi@nano")
        self.assertEqual(ns["ssh_command"](["true"])[0], "ssh")

    def test_the_collector_and_the_probe_agree_on_local(self):
        """Both scripts must answer identically, or the lane finds a GPU and
        then cannot read it."""
        probe = ast.parse((REPO / "bin" / "burnbar-local-status").read_text())
        want = {"is_local_host", "fqdn_once"}
        pbody = [n for n in probe.body
                 if (isinstance(n, ast.FunctionDef) and n.name in want)
                 or (isinstance(n, ast.Assign)
                     and getattr(n.targets[0], "id", "") == "_FQDN")]
        pns = {"socket": socket}
        exec(compile(ast.Module(body=pbody, type_ignores=[]), "<p>", "exec"), pns)
        pns["_FQDN"] = socket.gethostname().strip().rstrip(".").lower()
        for host in ("localhost", "127.0.0.1", "::1", socket.gethostname(),
                     "nano", "pi@nano", "example.com", ""):
            self.assertEqual(load(host)["is_local_host"](host),
                             pns["is_local_host"](host),
                             "collector and probe disagree about %r" % host)


if __name__ == "__main__":
    unittest.main()
