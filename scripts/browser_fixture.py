#!/usr/bin/env python3
"""Loopback-only browser persistence fixture. No real sites, cookies or account credentials."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from http.cookies import SimpleCookie
import argparse, json, pathlib, secrets, os, datetime, threading

PAGE = r'''<!doctype html><html lang="zh-CN"><meta charset="utf-8"><title>Codex 浏览器连续性验收</title>
<style>body{max-width:850px;margin:60px auto;font:16px system-ui;background:#f5f8f8;color:#173438}button{padding:12px 20px;margin:12px 12px 12px 0}pre{padding:20px;background:white;border-radius:12px;line-height:1.8}</style>
<h1>浏览器连续性验收</h1><p>仅包含随机假值。先建立基线；每次重启或切换后只点“检查”，避免重新登录掩盖丢失。</p>
<button onclick="seed()">建立基线</button><button onclick="check()">检查保留情况</button><pre id="out">尚未检查</pre>
<script>
async function db(){return new Promise((ok,no)=>{let r=indexedDB.open('codex-switcher-fixture',1);r.onupgradeneeded=()=>r.result.createObjectStore('markers');r.onsuccess=()=>ok(r.result);r.onerror=()=>no(r.error)})}
async function seed(){let r=await fetch('/seed',{method:'POST'});let j=await r.json();localStorage.setItem('switcher-marker',j.marker);let d=await db();await new Promise((ok,no)=>{let t=d.transaction('markers','readwrite');t.objectStore('markers').put(j.marker,'baseline');t.oncomplete=ok;t.onerror=no});d.close();await check()}
async function check(){try{let j=await(await fetch('/check',{cache:'no-store'})).json();let d=await db();let value=await new Promise((ok,no)=>{let r=d.transaction('markers').objectStore('markers').get('baseline');r.onsuccess=()=>ok(r.result);r.onerror=no});d.close();j.localStorage=localStorage.getItem('switcher-marker')===j.marker;j.indexedDB=value===j.marker;delete j.marker;let receipt=await fetch('/report',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(j)});if(!receipt.ok)throw new Error('receipt');document.querySelector('#out').textContent=JSON.stringify(j,null,2)+'\n结果已记录到本机验收日志。'}catch(e){document.querySelector('#out').textContent='检查失败：'+e.name}}
</script></html>'''

def serve(port, state):
    if state.exists(): marker=json.loads(state.read_text())['marker']
    else:
        marker=secrets.token_hex(16)
        state.parent.mkdir(parents=True,exist_ok=True)
        fd=os.open(state,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
        with os.fdopen(fd,'w') as f: json.dump({'marker':marker},f)
    receipt_lock=threading.Lock()
    def record(event, result=None):
        entry={'time':datetime.datetime.now(datetime.timezone.utc).isoformat(),'event':event}
        if result is not None: entry['result']=result
        with receipt_lock:
            fd=os.open(str(state)+'.receipts.jsonl',os.O_WRONLY|os.O_CREAT|os.O_APPEND|os.O_NOFOLLOW,0o600)
            with os.fdopen(fd,'w') as f:
                f.write(json.dumps(entry,sort_keys=True)+'\n');f.flush();os.fsync(f.fileno())
    class Handler(BaseHTTPRequestHandler):
        def log_message(self,*args): pass
        def reply(self,body,kind='application/json',cookies=False):
            self.send_response(200)
            self.send_header('Content-Type',kind+'; charset=utf-8');self.send_header('Cache-Control','no-store')
            if cookies:
                for name,suffix in [('persistent','; Max-Age=604800'),('session',''),('short_lived','; Max-Age=120')]:
                    self.send_header('Set-Cookie',f'{name}={marker}; Path=/; SameSite=Strict; HttpOnly'+suffix)
            self.end_headers();self.wfile.write(body.encode())
        def do_GET(self):
            if self.path=='/': return self.reply(PAGE,'text/html')
            if self.path=='/check':
                cookie=SimpleCookie(self.headers.get('Cookie',''))
                data={name:cookie.get(name) is not None and cookie[name].value==marker for name in ['persistent','session','short_lived']}
                data['marker']=marker
                return self.reply(json.dumps(data))
            self.send_error(404)
        def do_POST(self):
            if self.path=='/seed':
                record('seed')
                return self.reply(json.dumps({'marker':marker}),cookies=True)
            if self.path=='/report':
                try:
                    n=int(self.headers.get('Content-Length','0'))
                    if n<1 or n>1024: raise ValueError()
                    result=json.loads(self.rfile.read(n))
                    keys={'persistent','session','short_lived','localStorage','indexedDB'}
                    if not isinstance(result,dict) or set(result)!=keys or any(type(v) is not bool for v in result.values()): raise ValueError()
                except (ValueError,TypeError):
                    return self.send_error(400)
                record('check',result)
                return self.reply('{"recorded":true}')
            self.send_error(404)
    server=ThreadingHTTPServer(('127.0.0.1',port),Handler)
    print(f'Fixture: http://127.0.0.1:{server.server_port} — synthetic data only',flush=True)
    try: server.serve_forever()
    except KeyboardInterrupt: pass
    finally: server.server_close()

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--port',type=int,default=8765);p.add_argument('--state',type=pathlib.Path,required=True);a=p.parse_args()
    serve(a.port,a.state)
