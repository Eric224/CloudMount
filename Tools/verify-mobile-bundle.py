#!/usr/bin/env python3
"""Validate the signed development bundle without installing or launching it."""
import json,plistlib,re,subprocess,sys
from pathlib import Path
app=Path(sys.argv[1]).resolve()
subprocess.run(['codesign','--verify','--deep','--strict',str(app)],check=True)
required={'en','zh-Hant','zh-Hans'}
release=json.loads((Path(__file__).resolve().parent.parent/'Release.json').read_text())
devices={'00008120-000944213CD8C01E','00008130-001049D61E6A001C'}
results=[]
for bundle in [app]+sorted((app/'PlugIns').glob('*.appex')):
 info=plistlib.loads((bundle/'Info.plist').read_bytes())
 assert info['CFBundleShortVersionString']==release['version'] and info['CFBundleVersion']==release['build']
 assert info['CloudMountDeveloper']==release['developer'] and info['CloudMountEmail']==release['email']
 assert set(info['CFBundleLocalizations'])==required
 assert info['CFBundleDevelopmentRegion']=='en'
 for language in required:
  assert (bundle/(language+'.lproj')/'InfoPlist.strings').is_file(),(bundle,language)
 assert (bundle/'CloudMount_CloudMountVaultCore.bundle/4096words_en.txt').is_file()
 profile=plistlib.loads(subprocess.check_output(['security','cms','-D','-i',str(bundle/'embedded.mobileprovision')],stderr=subprocess.DEVNULL))
 ent=plistlib.loads(subprocess.check_output(['codesign','-d','--entitlements',':-',str(bundle)],stderr=subprocess.DEVNULL))
 assert 'group.com.codex.cloudmount.mobile' in ent['com.apple.security.application-groups']
 assert 'Q7K9XTM528.com.codex.cloudmount.mobile.shared' in ent['keychain-access-groups']
 assert ent['application-identifier']=='Q7K9XTM528.'+info['CFBundleIdentifier']
 assert devices.issubset(set(profile['ProvisionedDevices']))
 results.append({'bundle':info['CFBundleIdentifier'],'version':info['CFBundleShortVersionString'],'build':info['CFBundleVersion'],'developer':info['CloudMountDeveloper'],'email':info['CloudMountEmail'],'both_registered_devices_in_profile':True,'languages':sorted(required),'profile_expires':profile['ExpirationDate'].isoformat()})
assert len(results)==3
runtime=app/'Frameworks/CloudMountMobileRuntime.framework/CloudMountMobileRuntime'
assert runtime.is_file()
for binary in list(app.rglob('*.dylib'))+[app/'CloudMountMobile',runtime]+[b/'CloudMountProvider' for b in (app/'PlugIns').glob('CloudMountProvider.appex')]+[b/'CloudMountProviderUI' for b in (app/'PlugIns').glob('CloudMountProviderUI.appex')]:
 output=subprocess.check_output(['otool','-L',str(binary)],text=True)
 assert '/.build/' not in '\n'.join(output.splitlines()[1:]) and '/Users/' not in '\n'.join(output.splitlines()[1:])
 for dependency in re.findall(r'\s+(@rpath/\S+) \(',output):
  if '.framework/' in dependency:
   relative=dependency.removeprefix('@rpath/')
   assert (app/'Frameworks'/relative).is_file(),dependency
  elif dependency.startswith('@rpath/'):
   name=dependency.removeprefix('@rpath/')
   assert any((folder/name).is_file() for folder in [binary.parent,app/'Frameworks',Path('/usr/lib/swift')]),dependency
print(json.dumps({'bundles':results,'runtime_dependencies':'embedded','signature':'verified','recovery_wordlist':'present in app and both extensions'},indent=2))
