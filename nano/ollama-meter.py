#!/usr/bin/env python3
"""ollama-meter — a transparent reverse proxy in front of Ollama that writes
one journal line per inference request with the token counts Ollama itself
never persists.

Ollama 0.15 keeps no per-request token record anywhere: nothing in the
journal (OLLAMA_DEBUG=1 only adds the prompt-cache slot line), no metrics
endpoint, and /api/ps knows nothing about traffic. Every response *does*
carry prompt_eval_count and eval_count — but only the client sees them. So
this sits on Ollama's public port, forwards everything byte for byte, and
reads those two numbers off the way out. Whatever asks — a bar widget on
another machine, a voice server, `ollama run` — is counted the same.

Python 3 standard library only. Streaming responses are relayed chunk by
chunk with read1(), so a token reaches the client as soon as Ollama emits
it; only the tail of the body is kept for metering.

Journal line (stdout, one per metered request):

  meter ts=1788649079782 path=/api/generate model=llama3.2:3b status=200 \
        prompt=33 eval=137 ms=41875 client=100.101.176.48

ts is the request's end in epoch ms; prompt is prompt_eval_count (tokens
actually evaluated — cache hits are not included, Ollama does not report
them); eval is eval_count. A request that failed or was cut off logs -1 for
a count it never received.

Environment: METER_LISTEN (default 0.0.0.0:11434), METER_UPSTREAM (default
127.0.0.1:11435).
"""

import http.client
import http.server
import json
import os
import socket
import socketserver
import sys
import threading
import time

LISTEN = os.environ.get("METER_LISTEN", "0.0.0.0:11434")
UPSTREAM = os.environ.get("METER_UPSTREAM", "127.0.0.1:11435")
# Paths whose responses carry token counts. Everything else is forwarded
# and not logged.
METERED = ("/api/generate", "/api/chat", "/api/embed", "/api/embeddings",
           "/v1/chat/completions", "/v1/completions", "/v1/embeddings")
# The counts sit in the final JSON object of the body, which for a stream is
# the last NDJSON line (done:true) or the last SSE data: event. Keeping the
# tail is enough; a 300-word answer streams ~100 KB of text before it.
TAIL_BYTES = 64 * 1024
CHUNK = 64 * 1024
# Model load on a Jetson takes ~35 s and a long generation minutes; the
# upstream read timeout has to outlast a silent stretch between tokens, not
# the whole request.
UPSTREAM_TIMEOUT = 600
HOP_BY_HOP = {"connection", "keep-alive", "proxy-authenticate", "proxy-authorization",
              "te", "trailers", "transfer-encoding", "upgrade", "host"}

_log_lock = threading.Lock()


def log(line):
    with _log_lock:
        sys.stdout.write(line + "\n")
        sys.stdout.flush()


def split_hostport(text, default_port):
    host, _, port = text.rpartition(":")
    if not host:
        return text, default_port
    return host, int(port)


def count_of(obj, *keys):
    for key in keys:
        value = obj.get(key) if isinstance(obj, dict) else None
        if isinstance(value, bool):
            continue
        if isinstance(value, int) and 0 <= value < 10**12:
            return value
    return -1


def counts_from_tail(tail):
    """(prompt, eval, model) from the last JSON object in a response body:
    a plain JSON document, the last line of an NDJSON stream, or the last
    non-[DONE] SSE data: event. Any of them may carry Ollama's
    prompt_eval_count/eval_count or OpenAI's usage.{prompt,completion}_tokens."""
    text = tail.decode("utf-8", "replace")
    candidates = []
    stripped = text.strip()
    if stripped.endswith("}"):
        # Non-streamed: the whole document (or as much of it as the tail holds).
        candidates.append(stripped[stripped.rfind("\n{") + 1:] if "\n{" in stripped else stripped)
    for line in reversed(stripped.splitlines()):
        line = line.strip()
        if line.startswith("data:"):
            line = line[5:].strip()
        if line.startswith("{"):
            candidates.append(line)
            if len(candidates) > 4:
                break
    for raw in candidates:
        try:
            obj = json.loads(raw)
        except ValueError:
            continue
        if not isinstance(obj, dict):
            continue
        usage = obj.get("usage") if isinstance(obj.get("usage"), dict) else {}
        prompt = count_of(obj, "prompt_eval_count")
        if prompt < 0:
            prompt = count_of(usage, "prompt_tokens")
        evaluated = count_of(obj, "eval_count")
        if evaluated < 0:
            evaluated = count_of(usage, "completion_tokens")
        model = obj.get("model") if isinstance(obj.get("model"), str) else ""
        if prompt >= 0 or evaluated >= 0:
            return prompt, evaluated, model
    return -1, -1, ""


def safe_token(text, limit=96):
    """One word for the journal line: no spaces, no control characters."""
    out = "".join(c if c.isprintable() and not c.isspace() else "_" for c in str(text or ""))
    return out[:limit] or "-"


class Proxy(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "ollama-meter/1.0"

    def log_message(self, fmt, *args):  # quiet: the meter line is the log
        pass

    def read_body(self):
        length = self.headers.get("Content-Length")
        if length is not None:
            return self.rfile.read(max(0, int(length)))
        if "chunked" in (self.headers.get("Transfer-Encoding") or "").lower():
            body = b""
            while True:
                size_line = self.rfile.readline().split(b";", 1)[0].strip()
                size = int(size_line or b"0", 16)
                if size == 0:
                    while self.rfile.readline() not in (b"\r\n", b"\n", b""):
                        pass
                    return body
                body += self.rfile.read(size)
                self.rfile.readline()
        return b""

    def relay(self):
        started = time.monotonic()
        body = self.read_body()
        metered = self.command == "POST" and self.path.split("?", 1)[0] in METERED
        model = ""
        if metered:
            try:
                req = json.loads(body.decode("utf-8"))
                if isinstance(req, dict) and isinstance(req.get("model"), str):
                    model = req["model"]
            except ValueError:
                pass

        headers = {k: v for k, v in self.headers.items() if k.lower() not in HOP_BY_HOP}
        headers["Content-Length"] = str(len(body))
        headers["Host"] = UPSTREAM
        host, port = split_hostport(UPSTREAM, 11435)
        status = 502
        tail = b""
        try:
            conn = http.client.HTTPConnection(host, port, timeout=UPSTREAM_TIMEOUT)
            conn.request(self.command, self.path, body=body, headers=headers)
            resp = conn.getresponse()
        except (OSError, http.client.HTTPException) as e:
            self.send_error_json(502, "ollama-meter: upstream unavailable: %s" % e)
            if metered:
                self.meter(model, 502, -1, -1, started)
            return

        status = resp.status
        try:
            self.send_response(status)
            length = resp.getheader("Content-Length")
            for key, value in resp.getheaders():
                if key.lower() in HOP_BY_HOP or key.lower() == "content-length":
                    continue
                self.send_header(key, value)
            chunked = length is None
            if chunked:
                self.send_header("Transfer-Encoding", "chunked")
            else:
                self.send_header("Content-Length", length)
            self.send_header("Connection", "close")
            self.end_headers()
            while True:
                data = resp.read1(CHUNK)
                if not data:
                    break
                if chunked:
                    self.wfile.write(b"%x\r\n%s\r\n" % (len(data), data))
                else:
                    self.wfile.write(data)
                self.wfile.flush()
                tail = (tail + data)[-TAIL_BYTES:]
            if chunked:
                self.wfile.write(b"0\r\n\r\n")
                self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError, socket.timeout, OSError):
            # The client went away (or upstream stalled). Closing the upstream
            # connection is what tells Ollama to stop generating.
            pass
        finally:
            try:
                conn.close()
            except OSError:
                pass
        self.close_connection = True
        if metered:
            prompt, evaluated, resp_model = counts_from_tail(tail)
            self.meter(model or resp_model, status, prompt, evaluated, started)

    def meter(self, model, status, prompt, evaluated, started):
        log("meter ts=%d path=%s model=%s status=%d prompt=%d eval=%d ms=%d client=%s" % (
            int(time.time() * 1000), safe_token(self.path.split("?", 1)[0]), safe_token(model),
            status, prompt, evaluated, int((time.monotonic() - started) * 1000),
            safe_token(self.client_address[0], 64)))

    def send_error_json(self, code, message):
        payload = json.dumps({"error": message}).encode()
        try:
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(payload)))
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(payload)
        except OSError:
            pass
        self.close_connection = True

    do_GET = do_POST = do_PUT = do_DELETE = do_HEAD = do_OPTIONS = do_PATCH = relay


class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True
    request_queue_size = 64


def main():
    host, port = split_hostport(LISTEN, 11434)
    server = Server((host, port), Proxy)
    log("ollama-meter listening on %s:%d, upstream %s" % (host, port, UPSTREAM))
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
