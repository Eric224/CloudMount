#!/usr/bin/env python3
"""Loopback Moto adapter for current S3 copy/delete preconditions.
Moto implements PutObject conditions but omits current CopyObject/DeleteObject
conditions. This test adapter supplies them atomically; not a runtime component.
"""
import argparse,http.client,threading
from http.server import BaseHTTPRequestHandler,ThreadingHTTPServer
from urllib.parse import unquote,urlsplit,quote
p=argparse.ArgumentParser();p.add_argument('--port',type=int,default=19466);p.add_argument('--upstream',type=int,default=19472);a=p.parse_args();lock=threading.RLock();injected=set()
class Handler(BaseHTTPRequestHandler):
 protocol_version='HTTP/1.1'
 def log_message(self,*args):pass
 def do_HEAD(self):self.handle_request()
 def do_GET(self):self.handle_request()
 def do_PUT(self):self.handle_request()
 def do_DELETE(self):self.handle_request()
 def upstream(self,method,path,body=None,headers=None):
  c=http.client.HTTPConnection('127.0.0.1',a.upstream,timeout=20)
  headers=dict(headers or {});headers.setdefault('Authorization','AWS cloudmount-test-access:isolated-fixture')
  c.request(method,path,body=body,headers=headers)
  r=c.getresponse();data=r.read();out=(r.status,dict(r.getheaders()),data);c.close();return out
 def handle_request(self):
  try:
   body=self.rfile.read(int(self.headers.get('Content-Length','0')))
   with lock:
    if self.command in ['PUT','DELETE']:
     key=unquote(urlsplit(self.path).path).split('/')[-1]
     if self.path not in injected and ((self.command=='PUT' and self.headers.get('x-amz-copy-source') and key.startswith('race-copy-destination-')) or (self.command=='DELETE' and key.startswith('race-delete-source-'))):
      injected.add(self.path);self.upstream('PUT',self.path,b'external-edit')
     status,headers,_=self.upstream('HEAD',self.path)
     match=self.headers.get('If-Match');none=self.headers.get('If-None-Match')
     if (match and (status!=200 or match!=next((v for k,v in headers.items() if k.lower()=='etag'),None))) or (none=='*' and status==200):self.reply(412,{},b'');return
     source=self.headers.get('x-amz-copy-source')
     if source and self.headers.get('x-amz-copy-source-if-match'):
      ss,sh,_=self.upstream('HEAD',quote(unquote(source),safe='/'))
      if ss!=200 or next((v for k,v in sh.items() if k.lower()=='etag'),None)!=self.headers['x-amz-copy-source-if-match']:self.reply(412,{},b'');return
    headers={k:v for k,v in self.headers.items() if k.lower() not in ['host','connection','content-length']}
    self.reply(*self.upstream(self.command,self.path,body,headers))
  except (BrokenPipeError,ConnectionResetError):pass
 def reply(self,status,headers,body):
  self.send_response(status)
  for k,v in headers.items():
   if k.lower() not in ['content-length','transfer-encoding','connection','server','date']:self.send_header(k,v)
  self.send_header('Content-Length',headers.get('Content-Length',str(len(body))) if self.command=='HEAD' else str(len(body)))
  self.end_headers()
  if self.command!='HEAD':self.wfile.write(body)
print('S3 conditional proxy on 127.0.0.1:'+str(a.port),flush=True)
ThreadingHTTPServer(('127.0.0.1',a.port),Handler).serve_forever()
