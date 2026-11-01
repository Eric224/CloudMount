#!/usr/bin/env python3
"""Loopback-only S3 paging/signature fixture. All objects are disposable memory data."""
import argparse,base64,hashlib,hmac,json,threading
from http.server import BaseHTTPRequestHandler,ThreadingHTTPServer
from urllib.parse import urlsplit,parse_qsl,unquote,quote
from xml.sax.saxutils import escape
p=argparse.ArgumentParser();p.add_argument('--port',type=int,default=19474);a=p.parse_args()
objects={'scope/browse/%04d.txt'%i:('file-%d'%i).encode() for i in range(257)}
objects['outside.txt']=b'outside-scope';lock=threading.RLock();requests=[]
def mac(key,data):return hmac.new(key,data.encode(),hashlib.sha256).digest()
class Handler(BaseHTTPRequestHandler):
 protocol_version='HTTP/1.1'
 def log_message(self,*args):pass
 def reply(self,status,body=b'',headers=None):
  self.send_response(status)
  for k,v in (headers or {}).items():self.send_header(k,v)
  self.send_header('Content-Length',str(len(body)));self.end_headers()
  if self.command!='HEAD':self.wfile.write(body)
 def do_GET(self):self.handle_request()
 def do_HEAD(self):self.handle_request()
 def do_PUT(self):self.handle_request()
 def do_DELETE(self):self.handle_request()
 def signed(self,body):
  try:
   auth=self.headers['Authorization'];scheme,rest=auth.split(' ',1)
   fields=dict(s.split('=',1) for s in rest.split(', '));credential=fields['Credential'].split('/')
   if scheme!='AWS4-HMAC-SHA256' or credential[0]!='cloudmount-test-access':return False
   names=fields['SignedHeaders'].split(';');parts=urlsplit(self.path)
   headers=''.join(k+':'+ ' '.join(self.headers[k].split())+'\n' for k in names)
   query='&'.join(quote(k,safe='-_.~')+'='+quote(v,safe='-_.~') for k,v in sorted(parse_qsl(parts.query,keep_blank_values=True),key=lambda x:(quote(x[0],safe='-_.~'),quote(x[1],safe='-_.~'))))
   payload=hashlib.sha256(body).hexdigest()
   if self.headers['x-amz-content-sha256']!=payload:return False
   canonical='\n'.join([self.command,parts.path or '/',query,headers,fields['SignedHeaders'],payload])
   day,region,service,request=credential[1:];scope='/'.join(credential[1:])
   key=mac(mac(mac(mac(b'AWS4cloudmount-test-secret',day),region),service),request)
   message='AWS4-HMAC-SHA256\n'+self.headers['x-amz-date']+'\n'+scope+'\n'+hashlib.sha256(canonical.encode()).hexdigest()
   return hmac.compare_digest(hmac.new(key,message.encode(),hashlib.sha256).hexdigest(),fields['Signature'])
  except (KeyError,ValueError,AttributeError,TypeError):return False
 def handle_request(self):
  try:
   body=self.rfile.read(int(self.headers.get('Content-Length','0')))
   if not self.signed(body):self.reply(403);return
   parts=urlsplit(self.path);path=unquote(parts.path)
   if not path.startswith('/mobile-tests'):self.reply(404);return
   key=path.removeprefix('/mobile-tests').lstrip('/');query=dict(parse_qsl(parts.query))
   with lock:
    requests.append((self.command,key,query))
    tag=lambda b:'"'+hashlib.md5(b).hexdigest()+'"'
    if self.command=='GET' and query.get('list-type')=='2':
     prefix=query.get('prefix','');delimiter=query.get('delimiter');entries={}
     for name in sorted(objects):
      if not name.startswith(prefix):continue
      rest=name[len(prefix):]
      if delimiter and delimiter in rest:entries[prefix+rest.split(delimiter)[0]+delimiter]=True
      else:entries[name]=False
     offset=0
     if 'continuation-token' in query:
      context,offset=json.loads(base64.urlsafe_b64decode(query['continuation-token']))
      if context!=prefix:self.reply(400);return
     keys=sorted(entries);maximum=min(1000,max(1,int(query.get('max-keys','1000'))));end=min(offset+maximum,len(keys))
     more=end<len(keys);token=base64.urlsafe_b64encode(json.dumps([prefix,end]).encode()).decode()
     xml='<ListBucketResult><IsTruncated>'+str(more).lower()+'</IsTruncated>'
     for name in keys[offset:end]:
      if entries[name]:xml+='<CommonPrefixes><Prefix>'+escape(name)+'</Prefix></CommonPrefixes>'
      else:xml+='<Contents><Key>'+escape(name)+'</Key><Size>'+str(len(objects[name]))+'</Size><LastModified>2026-01-01T00:00:00Z</LastModified><ETag>'+escape(tag(objects[name]))+'</ETag></Contents>'
     if more:xml+='<NextContinuationToken>'+escape(token)+'</NextContinuationToken>'
     self.reply(200,(xml+'</ListBucketResult>').encode(),{'Content-Type':'application/xml'});return
    current=objects.get(key)
    if self.command in ['HEAD','GET']:
     self.reply(404 if current is None else 200,current or b'',{'ETag':tag(current),'Last-Modified':'Thu, 01 Jan 2026 00:00:00 GMT'} if current is not None else None);return
    match=self.headers.get('If-Match');none=self.headers.get('If-None-Match')
    if (match and (current is None or match!=tag(current))) or (none=='*' and current is not None):self.reply(412);return
    if self.command=='DELETE':objects.pop(key,None);self.reply(204);return
    source=self.headers.get('x-amz-copy-source')
    if source:
     source=unquote(source).removeprefix('/mobile-tests/');value=objects.get(source)
     if value is None:self.reply(404);return
     if self.headers.get('x-amz-copy-source-if-match') and self.headers['x-amz-copy-source-if-match']!=tag(value):self.reply(412);return
     objects[key]=value
     self.reply(200,('<CopyObjectResult><ETag>'+escape(tag(value))+'</ETag></CopyObjectResult>').encode());return
    objects[key]=body;self.reply(200,headers={'ETag':tag(body)})
  except (BrokenPipeError,ConnectionResetError):pass
print('Browsing fixture 127.0.0.1:'+str(a.port),flush=True)
ThreadingHTTPServer(('127.0.0.1',a.port),Handler).serve_forever()
