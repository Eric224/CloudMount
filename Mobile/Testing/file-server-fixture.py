#!/usr/bin/env python3
"""Loopback-only disposable FTP/FTPS/SFTP servers. Never point at user data."""
import argparse,asyncio,logging,threading,json,os
from pathlib import Path
import asyncssh
from pyftpdlib.authorizers import DummyAuthorizer
from pyftpdlib.handlers import FTPHandler,TLS_FTPHandler
from pyftpdlib.servers import FTPServer
from pyftpdlib.ioloop import IOLoop

async def main():
 p=argparse.ArgumentParser();p.add_argument('--root',required=True);a=p.parse_args()
 root=Path(a.root).resolve()
 if not str(root).startswith('/private/tmp/cloudmount-'):raise SystemExit('Dedicated /private/tmp/cloudmount-* root required')
 root.mkdir(parents=True,exist_ok=True);os.chmod(root,0o700)
 logging.basicConfig(level=logging.CRITICAL)
 key=asyncssh.generate_private_key('ssh-ed25519');(root/'host-key').write_bytes(key.export_private_key());os.chmod(root/'host-key',0o600)
 (root/'fingerprint.txt').write_text(key.get_fingerprint('sha256'))
 class SSHServer(asyncssh.SSHServer):
  def begin_auth(self,username):return True
  def password_auth_supported(self):return True
  def validate_password(self,username,password):return username=='test' and password=='test'
 for kind,port in [('ftp',19467),('ftps',19468)]:
  folder=root/kind;folder.mkdir(exist_ok=True)
  auth=DummyAuthorizer();auth.add_user('test','test',str(folder),perm='elradfmwMT')
  handler=type(kind+'Handler',(TLS_FTPHandler if kind=='ftps' else FTPHandler,),{})
  handler.authorizer=auth;handler.passive_ports=range(19480,19530);handler.banner='CloudMount isolated fixture'
  if kind=='ftps':
   handler.certfile=str(root/'certificate.pem');handler.keyfile=str(root/'certificate-key.pem');handler.tls_control_required=True;handler.tls_data_required=True
  server=FTPServer(('127.0.0.1',port),handler,ioloop=IOLoop())
  threading.Thread(target=server.serve_forever,kwargs={'timeout':0.2,'blocking':True,'handle_exit':False},daemon=True).start()
 folder=root/'sftp';folder.mkdir(exist_ok=True)
 server=await asyncssh.create_server(SSHServer,'127.0.0.1',19469,server_host_keys=[key],sftp_factory=lambda channel:asyncssh.SFTPServer(channel,chroot=str(folder)))
 print(json.dumps({'ready':True,'ports':[19467,19468,19469],'fingerprint':key.get_fingerprint('sha256')}),flush=True)
 await server.wait_closed()
asyncio.run(main())
