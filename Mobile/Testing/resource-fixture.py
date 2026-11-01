#!/usr/bin/env python3
"""Loopback-only bounded-response and conditional S3 fixture; no user data."""
import argparse, hashlib, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit
p=argparse.ArgumentParser();p.add_argument('--port',type=int,default=19471);a=p.parse_args()
objects={};lock=threading.Lock()
class Handler(BaseHTTPRequestHandler):
 protocol_version='HTTP/1.1'
 def log_message(self,*args): pass
 def reply(self,code=200,body=b'',headers=None,head=False):
  self.send_response(code);self.send_header('Content-Length',str(len(body)))
  for k,v in (headers or {}).items():self.send_header(k,v)
  self.end_headers()
  if not head:self.wfile.write(body)
 def do_HEAD(self):self.run('HEAD')
 def do_GET(self):self.run('GET')
 def do_DELETE(self):self.run('DELETE')
 def do_PUT(self):self.run('PUT')
 def do_POST(self):self.run('POST')
 def run(self,method):
  try:self.dispatch(method)
  except (BrokenPipeError,ConnectionResetError):pass
 def dispatch(self,method):
  path=urlsplit(self.path).path
  if method in ['PUT','POST']:body=self.rfile.read(int(self.headers.get('Content-Length','0')))
  if path.startswith('/bounded/'):
   route=path.split('/')[-1]
   if route=='redirect':self.reply(302,headers={'Location':'/bounded/small'});return
   if route=='small':self.reply(body=b'ok');return
   if route=='slow':time.sleep(3);self.reply(body=b'ok');return
   if route=='large':self.reply(body=b'x'*1_048_576);return
   if route=='chunked':
    self.send_response(200);self.send_header('Transfer-Encoding','chunked');self.end_headers()
    for i in range(1024):self.wfile.write(b'1000\r\n'+b'x'*4096+b'\r\n');self.wfile.flush();time.sleep(.001)
    self.wfile.write(b'0\r\n\r\n');return
  mode=path.split('/')[1]
  with lock:
   current=objects.get(path);tag=lambda b:'"'+hashlib.md5(b).hexdigest()+'"'
   if method in ['HEAD','GET']:
    self.reply(404 if current is None else 200,body=current or b'',headers={'ETag':tag(current)} if current is not None else None,head=method=='HEAD');return
   if method in ['PUT','DELETE']:
    copying=self.headers.get('x-amz-copy-source')
    ignores=mode=='ignores' or (mode=='ignore-copy' and copying) or (mode=='ignore-delete' and method=='DELETE')
    if not ignores:
     if self.headers.get('If-None-Match')=='*' and current is not None:self.reply(412);return
     if self.headers.get('If-Match') and (current is None or self.headers['If-Match']!=tag(current)):self.reply(412);return
     if copying and self.headers.get('x-amz-copy-source-if-match'):
      original=objects.get(copying)
      if original is None or tag(original)!=self.headers['x-amz-copy-source-if-match']:self.reply(412);return
    if method=='PUT':
     if copying:body=objects.get(copying,b'')
     objects[path]=body;self.reply(200,headers={'ETag':tag(body)});return
    if mode=='reject-valid-delete' and self.headers.get('If-Match'):self.reply(412);return
    if mode=='no-delete':self.reply(403);return
    objects.pop(path,None);self.reply(204);return
  self.reply(404)
print('Resource fixture on 127.0.0.1:'+str(a.port),flush=True)
ThreadingHTTPServer(('127.0.0.1',a.port),Handler).serve_forever()
