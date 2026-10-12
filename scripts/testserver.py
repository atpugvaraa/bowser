#!/usr/bin/env python3
"""Localhost test server: static files from a directory + /sse (long-lived event stream) + /ping.txt.
usage: testserver.py <port> <dir>   (binds 127.0.0.1 only)"""
import http.server, os, socketserver, sys, time
port, root = int(sys.argv[1]), sys.argv[2]
os.chdir(root)
class H(http.server.SimpleHTTPRequestHandler):
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
