# localhost-only pass-through of https://webglsamples.org with aquarium default fish = 30000 (index 9). Public content only.
import http.server, sys, urllib.request, re
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.startswith('/result'): self.send_response(200); self.end_headers(); return
        try: r = urllib.request.urlopen(urllib.request.Request('https://webglsamples.org' + self.path, headers={'User-Agent': 'Mozilla/5.0'}), timeout=30); body = r.read(); ct = r.headers.get('Content-Type', 'application/octet-stream')
        except Exception as e: self.send_response(502); self.end_headers(); return
        if self.path.split('?')[0].endswith('/aquarium-common.js'): body = body.replace(b'fishSetting: 2,', b'fishSetting: 9,')
        if self.path.split('?')[0].endswith('/aquarium.html'):
            inj = b"<script>var t=setInterval(function(){var e=document.getElementById('setSetting9');if(e){clearInterval(t);e.click()}},300);var samples=[];setTimeout(function(){var iv=setInterval(function(){samples.push(+document.getElementById('fps').textContent)},1000);setTimeout(function(){clearInterval(iv);var a=samples.slice().sort(function(x,y){return x-y});fetch('/result',{method:'POST',body:JSON.stringify({ua:navigator.userAgent.slice(-40),fish:30000,median_fps:a[a.length>>1],min:a[0],max:a[a.length-1],samples:samples})});document.title='aq done'},25000)},12000)</script></body>"
            body = body.replace(b'</body>', inj)
        self.send_response(200); self.send_header('Content-Type', ct); self.send_header('Content-Length', str(len(body))); self.end_headers(); self.wfile.write(body)
    def do_POST(self):
        n = int(self.headers.get('Content-Length', 0)); open('aq-result.json', 'wb').write(self.rfile.read(min(n, 100000))); self.send_response(200); self.end_headers()
    def log_message(self, *a): pass
http.server.ThreadingHTTPServer(('127.0.0.1', int(sys.argv[1])), H).serve_forever()
