#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
"""Offline HTTP fixture for packaged-app navigation and reader checks."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import argparse
from html import escape
from time import sleep
from pathlib import Path
from threading import Event

retry_enabled = Event()

PAGE = b'''<!doctype html><html lang="en"><head><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Designing for attention</title><style>
*{box-sizing:border-box}body{margin:0;color:#252731;background:#fff;font:15px/1.65 -apple-system,BlinkMacSystemFont,sans-serif}
main{max-width:650px;margin:auto;padding:30px 24px}h1{margin:0 0 18px;font-size:30px;line-height:1.16;letter-spacing:-.8px}
h2{margin:30px 0 10px;font-size:17px;line-height:1.3}p{margin:0 0 18px;color:#555966}.lead{font-size:17px;color:#343844}
blockquote{margin:24px 0;padding:0;color:#41465a}a{color:#4659ad}
.controls{margin-top:32px;padding-top:20px;border-top:1px solid #eceef2;font-size:13px}.controls nav{display:flex;gap:16px}
form{display:grid;gap:8px;margin:18px 0}input,button{min-width:0;font:inherit;border:1px solid #d9dce4;border-radius:4px;padding:8px;background:#fff;color:inherit}
button{justify-self:start;cursor:pointer;padding-inline:16px}input[type=file]{width:100%;font-size:12px}
</style></head><body><main><h1>Designing for attention</h1>
<p class="lead">A workspace should help you keep the thread of an idea.</p>
<p>Reading is rarely a straight line. We compare a source, write a thought, follow a reference, then return to the original page.</p>
<h2>Keep context in view</h2><p>Place the source beside the draft. Let the reader move between them without rebuilding the workspace each time.</p>
<blockquote>A useful interface preserves the work already in progress.</blockquote>
<h2>Make the return predictable</h2><p>Returning to a reference should recover the same document, including the details the reader left unfinished.</p>
<section class="controls" aria-label="Interactive reference"><nav><a href="/next">Next page</a><a href="/popup" target="_blank">Open reference</a></nav>
<form action="/submitted" method="post" target="_blank"><label for="draft">Working draft</label><input id="draft" name="test" value="preserved"><button>Send draft</button></form>
<input type="file" multiple aria-label="Attach reference files"></section></main></body></html>'''

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/slow-download":
            self.send_response(200)
            self.send_header("Content-Type", "application/octet-stream")
            self.send_header("Content-Disposition", 'attachment; filename="neutrino-download-fixture.bin"')
            self.send_header("Content-Length", str(1024 * 1024))
            self.end_headers()
            try:
                for _ in range(64):
                    self.wfile.write(b"r" * (16 * 1024))
                    self.wfile.flush()
                    sleep(0.15)
            except (BrokenPipeError, ConnectionResetError):
                pass
            return
        if self.path == "/navigation-retry/enable":
            retry_enabled.set()
        elif self.path == "/navigation-retry" and not retry_enabled.is_set():
            # A genuine provisional network failure, with no committed HTTP
            # response. The same address becomes available for native Retry.
            self.close_connection = True
            return
        page = PAGE.replace(b"Designing for attention", b"Calm workspaces").replace(
            b"A workspace should help you keep the thread of an idea.",
            b"Reduce the work of remembering where everything belongs.").replace(
            b"Place the source beside the draft. Let the reader move between them without rebuilding the workspace each time.",
            b"Group references around a project, keep notes beside them, and make each return feel familiar."
        ).replace(
            b"A useful interface preserves the work already in progress.",
            b"A calm workspace makes the next step easy to find."
        ) if self.path.startswith('/comparison') else PAGE
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(page)))
        self.end_headers()
        self.wfile.write(page)

    def do_POST(self):
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            self.send_error(400, "Invalid Content-Length")
            self.close_connection = True
            return
        if length < 0 or length > 16 * 1024:
            self.send_error(413, "Fixture request body exceeds 16 KB")
            self.close_connection = True
            return
        submitted = self.rfile.read(length)
        if self.path != "/submitted":
            self.do_GET()
            return
        body = escape(submitted.decode("utf-8", errors="replace"))
        page = (
            "<!doctype html><html><head><title>Neutrino POST fixture</title></head>"
            '<body><output id="request-method">POST</output>'
            f'<pre id="submitted-body">{body}</pre>'
            "<script>if (window.opener) window.opener.neutrinoPostPopup = window;</script>"
            "</body></html>"
        ).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(page)))
        self.end_headers()
        self.wfile.write(page)

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--port-file", type=Path, help="Write a dynamically allocated loopback port when ready.")
args = parser.parse_args()
server = ThreadingHTTPServer(("127.0.0.1", 0 if args.port_file else 8765), Handler)
if args.port_file:
    args.port_file.write_text(str(server.server_port), encoding="ascii")
print(f"Fixture ready at http://127.0.0.1:{server.server_port}/", flush=True)
server.serve_forever()
