#!/usr/bin/env python3
"""Loopback-only Drime REST fixture. All accounts/files are disposable, in memory.
No real Drime credentials, cloud requests or dependencies. Not an app component.
"""
import argparse, hashlib, json, threading, time, uuid
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlsplit, parse_qs
from email.parser import BytesParser
from email.policy import default

parser=argparse.ArgumentParser();parser.add_argument('--port',type=int,default=19470);args=parser.parse_args()
guard=threading.RLock(); entries={}; uploads={}; options={}; next_id=1; counts={}
def stamp(): return time.strftime('%Y-%m-%dT%H:%M:%S',time.gmtime())+'.%06dZ'%int(time.time_ns()%1000000000//1000)
def make(name,parent,content=None):
 global next_id
 ident=next_id;next_id+=1
 value={'id':ident,'name':name,'parent_id':parent,'workspace_id':0,'type':'folder' if content is None else 'file','file_size':len(content or b''),'created_at':stamp(),'updated_at':stamp(),'hash':'hash-'+str(ident),'deleted_at':None,'is_deleted':0,'content':content}
 entries[ident]=value;return value
def visible(e):return not e['is_deleted']
def siblings(parent):return [v for v in entries.values() if visible(v) and v['parent_id']==parent]
def safe(e):return {k:v for k,v in e.items() if k!='content'}
def collision(name,parent,exclude=None):return any(e['name']==name and e['id']!=exclude for e in siblings(parent))
class Handler(BaseHTTPRequestHandler):
 protocol_version='HTTP/1.1'
 def log_message(self,*_):pass
 def send(self,code=200,obj=None,raw=None,headers=None):
  data=raw if raw is not None else json.dumps(obj if obj is not None else {'status':'success'}).encode()
  self.send_response(code);self.send_header('Content-Type','application/json' if raw is None else 'application/octet-stream');self.send_header('Content-Length',str(len(data)))
  for k,v in (headers or {}).items():self.send_header(k,v)
  self.end_headers();self.wfile.write(data)
 def do_GET(self):self.run_request('GET')
 def do_POST(self):self.run_request('POST')
 def do_PUT(self):self.run_request('PUT')
 def run_request(self,method):
  try:
   with guard:self.dispatch(method)
  except (BrokenPipeError,ConnectionResetError):pass
  except Exception as e:self.send(500,{'status':'error','kind':type(e).__name__})
 def dispatch(self,method):
  global options
  parsed=urlsplit(self.path);path=parsed.path;query=parse_qs(parsed.query)
  size=int(self.headers.get('Content-Length','0'));body=self.rfile.read(size)
  if path=='/__control' and method=='POST':options=json.loads(body);self.send();return
  if path=='/__stats':self.send(obj={'counts':counts,'entries':[safe(e) for e in entries.values()],'sessions':len(uploads)});return
  if path.startswith('/storage/'):
   if self.headers.get('Authorization'):self.send(403,{'status':'error','message':'credential leak'});return
   _,_,uid,number=path.split('/');u=uploads[uid];number=int(number)
   if options.pop('failPartOnce',False):self.send(503,{'status':'error'});return
   tag='"'+hashlib.sha256(body).hexdigest()+'"';u['parts'][number]=(body,tag);self.send(raw=b'',headers={'ETag':tag});return
  if path.startswith('/unsigned/'):
   if self.headers.get('Authorization'):self.send(403,{'status':'error','message':'credential leak'});return
   e=entries[int(path.split('/')[-1])];self.send(raw=e['content']);return
  if self.headers.get('Authorization')!='Bearer isolated-drime-token':self.send(401,{'status':'error'});return
  counts[path]=counts.get(path,0)+1
  if not path.startswith('/api/v1/'):self.send(404);return
  route=path[len('/api/v1/'):]; data=json.loads(body) if body and self.headers.get('Content-Type','').startswith('application/json') else {}
  if route=='users/me':self.send(obj={'user':{'id':123},'status':'success'});return
  if route.endswith('/verify-integrity'):
   if options.get('noIntegrityEndpoint'):self.send(404);return
   if options.get('sharedFile'):self.send(403);return
   e=entries[int(route.split('/')[1])];digest=hashlib.sha256(e['content']).hexdigest()
   if options.get('corruptIntegrity'):digest='0'*64
   if digest==data['sha256']:e['file_hash']=digest
   self.send(obj={'verified':digest==data['sha256'],'serverHash':digest,'status':'success'});return
  if route=='drive/file-entries':
   parent=int(query['folderId'][0]) if query.get('folderId') else None
   values=sorted(siblings(parent),key=lambda e:e['id']);page=int(query.get('page',['1'])[0]);limit=int(query.get('perPage',['1000'])[0])
   mode=options.get('listing')
   if mode=='incomplete':self.send(obj={'data':[],'current_page':1,'last_page':1,'total':1});return
   if mode=='bad-parent' and values:
    values=[dict(values[0],parent_id=999999)]+values[1:]
   if mode=='paginate':limit=1
   last=max(1,(len(values)+limit-1)//limit)
   self.send(obj={'data':[safe(e) for e in values[(page-1)*limit:page*limit]],'current_page':page,'last_page':last,'total':len(values)});return
  if route.startswith('file-entries/download/'):
   e=next((v for v in entries.values() if v['hash']==route.split('/')[-1] and visible(v)),None)
   if not e:self.send(404);return
   if options.get('redirectDownload'):
    self.send(302,raw=b'',headers={'Location':f'http://localhost:{args.port}/unsigned/{e["id"]}'});return
   raw=e['content']
   if options.get('corruptDownload') and raw:raw=bytes([raw[0]^1])+raw[1:]
   self.send(raw=raw);return
  if route.startswith('file-entries/') and route.split('/')[-1].isdigit():
   e=entries.get(int(route.split('/')[-1]));
   if not e:self.send(404);return
   if method=='GET':self.send(obj={'fileEntry':safe(e),'status':'success'});return
   if method=='PUT':
    if options.get('failFinalRename') and e['name'].startswith('.cloudmount-upload-') and not data['name'].startswith('.cloudmount-'):
     options.pop('failFinalRename');self.send(503,{'status':'error'});return
    if collision(data['name'],e['parent_id'],e['id']):self.send(409);return
    e['name']=data['name'];e['updated_at']=stamp()
    if options.pop('renameReplyLostOnce',False):self.send(503,{'status':'error'});return
    self.send(obj={'fileEntry':safe(e),'status':'success'});return
  if route=='folders':
   parent=data.get('parentId');name=data['name']
   if collision(name,parent):self.send(409);return
   self.send(201,{'status':'success','folder':safe(make(name,parent))});return
  if route=='file-entries/move':
   es=[entries[int(i)] for i in data['entryIds']];parent=data.get('destinationId')
   if any(collision(e['name'],parent,e['id']) for e in es):self.send(409);return
   for e in es:e['parent_id']=parent;e['updated_at']=stamp()
   self.send(obj={'status':'success','entries':[safe(e) for e in es]});return
  if route=='file-entries/delete':
   if not data['entryIds'] or data.get('deleteForever'):self.send(403);return
   es=[entries[int(i)] for i in data['entryIds']]
   mode=options.get('deleteMode','ok')
   if mode=='422-present':self.send(422,{'message':'本地化的刪除失敗訊息'});return
   for e in es:
    e['is_deleted']=1;e['deleted_at']=stamp()
   if mode=='422-absent':self.send(422,{'message':'Cet élément n’existe plus.'});return
   self.send();return
  if route=='uploads':
   if options.get('rejectUpload'):self.send(403);return
   msg=BytesParser(policy=default).parsebytes(b'Content-Type: '+self.headers['Content-Type'].encode()+b'\r\nMIME-Version: 1.0\r\n\r\n'+body)
   fields={};content=None;filename=None
   for part in msg.iter_parts():
    name=part.get_param('name',header='content-disposition');value=part.get_payload(decode=True)
    if name=='file':content=value;filename=part.get_filename()
    else:fields[name]=value.decode()
   parent=int(fields['parentId']) if fields['parentId'] else None
   if collision(filename,parent):self.send(409);return
   e=make(filename,parent,content)
   if options.pop('uploadReplyLostOnce',False):self.send(503,{'status':'error'});return
   self.send(201,{'status':'success','fileEntry':safe(e)});return
  if route=='s3/multipart/create':
   uid=str(uuid.uuid4());key='uploads/'+uid+'/'+uid;uploads[uid]={'key':key,'parts':{},'context':data}
   self.send(obj={'uploadId':uid,'key':key,'status':'success'});return
  if route=='s3/multipart/batch-sign-part-urls':
   self.send(obj={'urls':[{'partNumber':n,'url':f'http://127.0.0.1:{args.port}/storage/{data["uploadId"]}/{n}'} for n in data['partNumbers']]});return
  if route=='s3/multipart/abort':
   if options.get('abortFails'):self.send(503,{'status':'error'});return
   uploads.pop(data['uploadId'],None);self.send();return
  if route=='s3/multipart/complete':
   u=uploads[data['uploadId']]
   if any(u['parts'][p['PartNumber']][1]!=p['ETag'] for p in data['parts']):self.send(422);return
   u['content']=b''.join(u['parts'][p['PartNumber']][0] for p in data['parts']);self.send();return
  if route=='s3/entries':
   uid=data['filename'];u=uploads[uid]
   if collision(data['clientName'],data.get('parentId')):self.send(409);return
   e=make(data['clientName'],data.get('parentId'),u['content']);self.send(201,{'status':'success','fileEntry':safe(e)});return
  self.send(404,{'status':'error'})

server=ThreadingHTTPServer(('127.0.0.1',args.port),Handler)
print(f'Disposable Drime fixture on 127.0.0.1:{args.port}',flush=True)
server.serve_forever()
