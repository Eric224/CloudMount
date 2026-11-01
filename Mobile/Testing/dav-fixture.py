#!/usr/bin/env python3
"""Disposable loopback-only DAV server, never use with user cloud data."""
import argparse,base64,hashlib,http.server,os,ssl,urllib.parse,xml.sax.saxutils,shutil,email.utils
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('--root',required=True);p.add_argument('--port',type=int,default=19463);p.add_argument('--cert');p.add_argument('--key');p.add_argument('--canonical-slashes',action='store_true');p.add_argument('--existing-mkcol-redirect',action='store_true');p.add_argument('--move-error-after-commit',action='store_true');p.add_argument('--weak-properties',action='store_true');p.add_argument('--conditional-race',action='store_true');a=p.parse_args()
root=Path(a.root).resolve();root.mkdir(parents=True,exist_ok=True);(root/'home').mkdir(exist_ok=True)
class Handler(http.server.BaseHTTPRequestHandler):
 protocol_version='HTTP/1.1'
 def log_message(self,*args):pass
 def path_for(self,path=None):
  parsed=urllib.parse.urlsplit(path or self.path);parts=urllib.parse.unquote(parsed.path).lstrip('/')
  resolved=(root/parts).resolve()
  if resolved!=root and root not in resolved.parents:raise ValueError('unsafe path')
  return resolved
 def reply(self,status,body=b'',headers={}):
  self.send_response(status)
  for k,v in headers.items():self.send_header(k,v)
  self.send_header('Content-Length',str(len(body)));self.end_headers()
  if self.command!='HEAD':self.wfile.write(body)
 def read_body(self):return self.rfile.read(int(self.headers.get('Content-Length','0')))
 def authorized(self):
  if self.headers.get('Authorization')=='Basic '+base64.b64encode(b'test:test').decode():return True
  self.read_body();self.reply(401,headers={'WWW-Authenticate':'Basic realm="isolated-test"'});return False
 def etag(self,path):return '"'+hashlib.sha256(path.read_bytes() if path.is_file() else str(path.stat().st_mtime_ns).encode()).hexdigest()+'"'
 def canonical(self):
  if not a.canonical_slashes:return False
  path=urllib.parse.urlsplit(self.path).path
  target=None
  if self.command in ['MKCOL','PROPFIND','MOVE','DELETE'] and path.endswith('/') and path!='/':target=path[:-1]
  if self.command in ['PUT','GET'] and not path.endswith('/'):target=path+'/'
  if target:
   self.read_body();self.reply(301,headers={'Location':target});return True
  return False
 def do_PROPFIND(self):
  if not self.authorized():return
  if self.canonical():return
  self.read_body();path=self.path_for()
  if not path.exists():return self.reply(404)
  entries=[path]+(list(path.iterdir()) if path.is_dir() and self.headers.get('Depth')=='1' else [])
  body='<?xml version="1.0" encoding="utf-8"?><d:multistatus xmlns:d="DAV:">'
  for item in entries:
   href='/'+urllib.parse.quote(str(item.relative_to(root)),safe='/')+('/' if item.is_dir() else '')
   body+='<d:response><d:href>'+xml.sax.saxutils.escape(href)+'</d:href><d:propstat><d:prop><d:resourcetype>'+('<d:collection/>' if item.is_dir() else '')+'</d:resourcetype><d:getcontentlength>'+str(item.stat().st_size if item.is_file() else 0)+'</d:getcontentlength><d:getlastmodified>'+email.utils.formatdate(item.stat().st_mtime,usegmt=True)+'</d:getlastmodified><d:getetag>'+xml.sax.saxutils.escape(('W/' if a.weak_properties and item.is_file() else '')+self.etag(item))+'</d:getetag></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>'
  self.reply(207,(body+'</d:multistatus>').encode(),{'Content-Type':'application/xml; charset=utf-8'})
 def do_MKCOL(self):
  if not self.authorized():return
  if self.canonical():return
  self.read_body();path=self.path_for()
  if a.existing_mkcol_redirect and path.name.startswith('race-created-') and not path.exists():path.mkdir()
  if path.exists():return self.reply(301,headers={'Location':self.path}) if a.existing_mkcol_redirect else self.reply(405)
  if not path.parent.exists():return self.reply(409)
  path.mkdir();self.reply(201)
 def do_GET(self):
  if not self.authorized():return
  if self.canonical():return
  path=self.path_for()
  if not path.is_file():return self.reply(404)
  self.reply(200,path.read_bytes(),{'Content-Type':'application/octet-stream','ETag':self.etag(path)})
 def do_HEAD(self):self.do_GET()
 def do_PUT(self):
  if not self.authorized():return
  if self.canonical():return
  body=self.read_body();path=self.path_for()
  if not path.parent.is_dir():return self.reply(409)
  if self.headers.get('If-None-Match')=='*' and path.exists():return self.reply(412)
  if self.headers.get('If-Match') and (not path.exists() or self.etag(path)!=self.headers['If-Match']):return self.reply(412)
  exists=path.exists();tmp=path.with_name('.fixture-staged-'+os.urandom(8).hex());tmp.write_bytes(body);tmp.replace(path);self.reply(204 if exists else 201)
 def do_MOVE(self):
  if not self.authorized():return
  if self.canonical():return
  self.read_body();path=self.path_for();dest=self.path_for(self.headers.get('Destination'))
  if not path.exists():return self.reply(404)
  if dest.exists() and self.headers.get('Overwrite')=='F':return self.reply(412)
  condition=self.headers.get('If')
  if a.conditional_race and condition and dest.name.startswith('race-replace-'):dest.write_bytes(b'external-update')
  if condition and (not dest.exists() or ('(['+self.etag(dest)+'])') not in condition):return self.reply(412)
  if a.move_error_after_commit and dest.name.startswith('reject-noop-'):return self.reply(201)
  path.replace(dest);self.reply(500 if a.move_error_after_commit else 201)
 def do_DELETE(self):
  if not self.authorized():return
  if self.canonical():return
  self.read_body();path=self.path_for()
  if not path.exists():return self.reply(404)
  if self.headers.get('If-Match') and self.headers['If-Match']!=self.etag(path):return self.reply(412)
  if path.is_dir():path.rmdir()
  else:path.unlink()
  self.reply(204)
server=http.server.ThreadingHTTPServer(('127.0.0.1',a.port),Handler)
if a.cert:
 context=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER);context.load_cert_chain(a.cert,a.key);server.socket=context.wrap_socket(server.socket,server_side=True)
print('fixture-ready',a.port,flush=True);server.serve_forever()
