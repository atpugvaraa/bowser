#!/usr/bin/env python3
"""Localhost test server: static files from a directory + /sse (long-lived event stream) + /ping.txt.
usage: testserver.py <port> <dir>   (binds 127.0.0.1 only)"""
import http.server, os, socketserver, sys, time
port, root = int(sys.argv[1]), sys.argv[2]
os.chdir(root)
import re
class H(http.server.SimpleHTTPRequestHandler):
    iso = False
    def translate_path(self, path):
        self.iso = path.startswith('/iso/')
        if self.iso: path = path[4:]
        return super().translate_path(path)
    def end_headers(self):
        if self.iso:                       # cross-origin isolation: enables SharedArrayBuffer / threaded WASM
            self.send_header('Cross-Origin-Opener-Policy', 'same-origin'); self.send_header('Cross-Origin-Embedder-Policy', 'require-corp')
        super().end_headers()
    def do_POST(self):
        m = re.match(r'^/result\?name=([A-Za-z0-9_.-]{1,60})$', self.path)
        if not m: self.send_response(404); self.end_headers(); return
        n = min(int(self.headers.get('Content-Length', 0)), 2_000_000)
        open('result-%s.json' % m.group(1), 'wb').write(self.rfile.read(n)); self.send_response(200); self.end_headers()
    def do_GET(self):
        if self.path.split('?')[0] == '/sse':
            self.send_response(200); self.send_header('Content-Type', 'text/event-stream'); self.send_header('Cache-Control', 'no-cache'); self.end_headers()
            try:
                for i in range(300):   # at most 10 minutes per stream
                    self.wfile.write(b': keepalive\n\n'); self.wfile.flush(); time.sleep(2)
            except Exception: pass
            return
        if self.path.split('?')[0] == '/dl':
            from urllib.parse import urlparse, parse_qs
            name = parse_qs(urlparse(self.path).query).get('name', ['file.bin'])[0]
            body = b'x' * 20000
            self.send_response(200); self.send_header('Content-Type', 'application/octet-stream')
            self.send_header('Content-Disposition', 'attachment; filename="%s"' % name); self.send_header('Content-Length', str(len(body))); self.end_headers(); self.wfile.write(body); return
        super().do_GET()
    def log_message(self, *a): pass
class S(socketserver.ThreadingMixIn, http.server.HTTPServer): daemon_threads = True
S(('127.0.0.1', port), H).serve_forever()
