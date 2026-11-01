#!/usr/bin/env python3
"""Run one owned Xcode test job with an outer timeout; never reset OS daemons."""
import argparse,os,signal,subprocess,sys
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('--device',required=True);p.add_argument('--derived',default='.build/mobile');p.add_argument('--timeout',type=int,default=240);p.add_argument('--only',action='append',default=[]);a=p.parse_args()
os.chdir(Path(__file__).resolve().parent.parent)
cmd=['xcodebuild','-project','Mobile/CloudMountMobile.xcodeproj','-scheme','CloudMountMobile','-destination','platform=iOS Simulator,id='+a.device,'-derivedDataPath',a.derived,'-jobs','4','CODE_SIGN_IDENTITY=-','-parallel-testing-enabled','NO','-test-timeouts-enabled','YES','-maximum-test-execution-time-allowance','90']
cmd+=['-only-testing:'+name for name in a.only];cmd+=['test']
job=subprocess.Popen(cmd,start_new_session=True)
try:sys.exit(job.wait(timeout=a.timeout))
except subprocess.TimeoutExpired:
 print('CloudMount test job timed out; terminating only its process group.',flush=True)
 os.killpg(job.pid,signal.SIGTERM)
 try:job.wait(timeout=10)
 except subprocess.TimeoutExpired:os.killpg(job.pid,signal.SIGKILL);job.wait()
 sys.exit(124)
