#!/usr/bin/env python3
"""Apply the shared release metadata to the macOS application manifest."""
import json,plistlib,re
from pathlib import Path
root=Path(__file__).resolve().parent.parent
release=json.loads((root/'Release.json').read_text())
assert re.fullmatch(r'\d+\.\d+\.\d+',release['version'])
assert re.fullmatch(r'\d+(?:\.\d+){0,2}',release['build'])
p=root/'Resources/Info.plist'
info=plistlib.loads(p.read_bytes())
info.update({'CFBundleShortVersionString':release['version'],'CFBundleVersion':release['build'],'CloudMountDeveloper':release['developer'],'CloudMountEmail':release['email']})
p.write_bytes(plistlib.dumps(info))
