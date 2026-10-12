import http.server, sys, os, re
os.chdir(os.path.join(os.path.dirname(os.path.abspath(__file__)),'www'))
class H(http.server.SimpleHTTPRequestHandler):
    def do_POST(self):
        n=min(int(self.headers.get('Content-Length',0)),100000); b=self.rfile.read(n)
        name=re.sub(r'[^A-Za-z0-9_-]','',self.path.split('name=')[-1])[:40] or 'x'
        open(f'../result-{name}.json','wb').write(b); self.send_response(200); self.end_headers()
    def log_message(self,*a): pass
http.server.ThreadingHTTPServer(('127.0.0.1',8766),H).serve_forever()
