import socket, json, base64, os, struct, subprocess, sys, time, urllib.request, tempfile, statistics
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
class WS:
    def __init__(s, url):
        host,rest=url[5:].split('/',1); h,p=host.split(':'); s.sock=socket.create_connection((h,int(p)),timeout=60)
        key=base64.b64encode(os.urandom(16)).decode()
        s.sock.sendall(f"GET /{rest} HTTP/1.1\r\nHost: {host}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n".encode())
        buf=b""
        while b"\r\n\r\n" not in buf: buf+=s.sock.recv(1024)
        s.buf=buf.split(b"\r\n\r\n",1)[1]; s.id=0
    def send(s,method,params=None):
        s.id+=1; data=json.dumps({"id":s.id,"method":method,"params":params or {}}).encode()
        mask=os.urandom(4); n=len(data); hdr=bytes([0x81])
        hdr+= bytes([0x80|n]) if n<126 else bytes([0x80|126])+struct.pack(">H",n) if n<65536 else bytes([0x80|127])+struct.pack(">Q",n)
        s.sock.sendall(hdr+mask+bytes(b^mask[i%4] for i,b in enumerate(data))); return s.id
    def _read(s,n):
        while len(s.buf)<n: s.buf+=s.sock.recv(65536)
        d,s.buf=s.buf[:n],s.buf[n:]; return d
    def recv(s):
        b1,b2=s._read(2); n=b2&0x7f
        if n==126: n=struct.unpack(">H",s._read(2))[0]
        elif n==127: n=struct.unpack(">Q",s._read(8))[0]
        return json.loads(s._read(n))
    def call(s,method,params=None):
        i=s.send(method,params)
        while True:
            m=s.recv()
            if m.get("id")==i: return m
def one(url,port,prof=None):
    prof=prof or tempfile.mkdtemp(prefix="chrome-bench-")
    p=subprocess.Popen([CHROME,f"--remote-debugging-port={port}","--remote-allow-origins=*",f"--user-data-dir={prof}","--no-first-run","--no-default-browser-check","--headless=new","--window-size=1280,800","about:blank"],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    try:
        for _ in range(100):
            try: tabs=json.load(urllib.request.urlopen(f"http://127.0.0.1:{port}/json/list",timeout=2)); 
            except Exception: time.sleep(0.2); continue
            pg=[t for t in tabs if t["type"]=="page"]
            if pg: break
        ws=WS(pg[0]["webSocketDebuggerUrl"]); ws.call("Page.enable"); ws.call("Runtime.enable")
        ws.send("Page.navigate",{"url":url}); t0=time.time()
        while time.time()-t0<60:
            m=ws.recv()
            if m.get("method")=="Page.loadEventFired": break
        time.sleep(1.5)
        r=ws.call("Runtime.evaluate",{"expression":"JSON.stringify((()=>{const n=performance.getEntriesByType('navigation')[0]||{};const fcp=(performance.getEntriesByName('first-contentful-paint')[0]||{}).startTime;return {dcl:Math.round(n.domContentLoadedEventEnd),load:Math.round(n.loadEventEnd),fcp:Math.round(fcp||-1),res:performance.getEntriesByType('resource').length}})())","returnByValue":True})
        return json.loads(r["result"]["result"]["value"])
    finally:
        p.terminate()
        try: p.wait(10)
        except Exception: p.kill()
if __name__=="__main__":
    url=sys.argv[1]; n=int(sys.argv[2]); out=[]
    shared=tempfile.mkdtemp(prefix="chrome-warm-") if len(sys.argv)>3 else None
    for i in range(n):
        out.append(one(url,9300+i,shared)); print("CHROME",json.dumps(out[-1]),flush=True)
    f=lambda k: statistics.median(x[k] for x in out)
    print("CHROME-MEDIAN n=%d fcp=%d dcl=%d load=%d res=%d"%(n,f('fcp'),f('dcl'),f('load'),f('res')))
