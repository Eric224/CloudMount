#!/usr/bin/env python3
"""Run an owned, bounded iOS development test job; no daemon resets or cloud credentials on Mac."""
import argparse,os,plistlib,signal,subprocess,sys,uuid
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('--platform',choices=['iOS','iOS Simulator'],default='iOS');p.add_argument('--device',required=True);p.add_argument('--derived',default='.build/mobile-physical-011');p.add_argument('--timeout',type=int,default=240);p.add_argument('--only',action='append',default=[]);p.add_argument('--nas-host');p.add_argument('--readonly-connections',action='store_true');p.add_argument('--webdav-fixture',action='store_true');a=p.parse_args()
os.chdir(Path(__file__).resolve().parent.parent)
products=Path(a.derived).resolve()/'Build/Products'
plans=sorted(products.glob('CloudMountMobile_*.xctestrun'),key=lambda x:x.stat().st_mtime)
if not plans:raise SystemExit('Build for testing first; no generated device test plan found.')
data=plistlib.loads(plans[-1].read_bytes())
# Xcode may emit either legacy format 1 or configuration-based format 2.
# Opt-in flags must reach the hosted test process in both formats.
targets=[]
for configuration in data.get('TestConfigurations',[]):
 targets += configuration.get('TestTargets',[])
if not targets:
 for name,target in data.items():
  if isinstance(target,dict) and not name.startswith('__'):
   targets.append(dict(target,BlueprintName=name))
   data[name]=targets[-1]
for target in targets:
 if target.get('BlueprintName')=='CloudMountMobileTests':
  env=target.setdefault('EnvironmentVariables',{})
  if a.nas_host:env['CLOUDMOUNT_DEVICE_NAS_TEST']='1';env['CLOUDMOUNT_DEVICE_DAV_HOST']=a.nas_host
  if a.readonly_connections:env['CLOUDMOUNT_DEVICE_READ_TEST']='1'
  if a.webdav_fixture:env['CLOUDMOUNT_DEVICE_DAV_FIXTURE']='1'
plan=products/('CloudMount-device-run-'+str(uuid.uuid4())+'.xctestrun');plan.write_bytes(plistlib.dumps(data))
cmd=['xcodebuild','test-without-building','-xctestrun',str(plan),'-destination','platform='+a.platform+',id='+a.device,'-destination-timeout','30','-parallel-testing-enabled','NO','-test-timeouts-enabled','YES','-maximum-test-execution-time-allowance','90']
cmd+=['-only-testing:'+name for name in a.only]
job=subprocess.Popen(cmd,start_new_session=True)
try:
 try:result=job.wait(timeout=a.timeout)
 except subprocess.TimeoutExpired:
  print('CloudMount device test timed out; stopping only its owned process group.',flush=True);os.killpg(job.pid,signal.SIGTERM)
  try:job.wait(timeout=10)
  except subprocess.TimeoutExpired:os.killpg(job.pid,signal.SIGKILL);job.wait()
  result=124
finally:plan.unlink(missing_ok=True)
sys.exit(result)
