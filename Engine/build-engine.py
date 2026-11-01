#!/usr/bin/env python3
"""Rebuild CloudMount's complete rclone engine using the reviewed local patch."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile
import urllib.request

engine = Path(__file__).resolve().parent
project = engine.parent
manifest = json.loads((engine / "upstream.json").read_text())
go = sys.argv[1] if len(sys.argv) > 1 else shutil.which("go")
if not go:
    raise SystemExit("Go 1.26 or later is required. Pass the go executable as the first argument.")
build = Path(tempfile.mkdtemp(prefix="cloudmount-engine-"))
try:
    archive = build / "source.tar.gz"
    with urllib.request.urlopen(manifest["url"], timeout=60) as source, archive.open("wb") as target:
        shutil.copyfileobj(source, target)
    if hashlib.sha256(archive.read_bytes()).hexdigest() != manifest["sha256"]:
        raise SystemExit("Upstream source checksum mismatch; build stopped.")
    with tarfile.open(archive) as source:
        for member in source.getmembers():
            resolved = (build / member.name).resolve()
            if build not in resolved.parents:
                raise SystemExit("Unsafe archive entry")
            if member.issym() or member.islnk():
                target = (resolved.parent / member.linkname).resolve()
                if build not in target.parents:
                    raise SystemExit("Unsafe archive link")
        source.extractall(build)
    source = build / ("rclone-" + manifest["version"])
    subprocess.run(["patch", "-p1", "-i", str(engine / "rclone-1.75.2-cloudmount.patch")], cwd=source, check=True)
    environment = dict(os.environ, GOTOOLCHAIN="local", GOMAXPROCS="2", MACOSX_DEPLOYMENT_TARGET="13.0",
                       CGO_CFLAGS="-O2 -g -mmacosx-version-min=13.0", CGO_LDFLAGS="-O2 -g -mmacosx-version-min=13.0")
    subprocess.run([go, "test", "-p", "2", "./backend/drime", "-run", "TestCloudMount", "-count=1"], cwd=source, env=environment, check=True)
    subprocess.run([go, "build", "-tags", ",".join(manifest["tags"]), "-p", "2", "-trimpath", "-ldflags",
                    "-s -w -X github.com/rclone/rclone/fs.Version=" + manifest["engine_version"],
                    "-o", str(project / "Resources/CloudMountRclone"), "."], cwd=source, env=environment, check=True)
finally:
    shutil.rmtree(build)
