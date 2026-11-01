#!/usr/bin/env python3
"""Audit the shipped arm64 programs, optionally remove build-only load paths."""
import json
from pathlib import Path
import plistlib
import re
import subprocess
import sys

app = Path(sys.argv[1]).resolve()
fix = "--remove-build-rpaths" in sys.argv[2:]
info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
assert info["LSMinimumSystemVersion"] == "26.0", "App must require macOS 26"
programs = [app / "Contents/MacOS/CloudMount"] + [app / "Contents/Helpers" / name for name in ("CloudMountHelper", "CloudMountVaultHelper", "CloudMountRclone")]
report = []
for program in programs:
    architectures = subprocess.check_output(["/usr/bin/lipo", "-archs", str(program)], text=True).split()
    assert "arm64" in architectures, f"Missing Apple Silicon executable: {program.name}"
    loads = subprocess.check_output(["/usr/bin/otool", "-l", str(program)], text=True)
    paths = re.findall(r"cmd LC_RPATH\s+cmdsize \d+\s+path (.*?) \(offset", loads)
    for path in paths:
        if path.startswith("/") and not path.startswith(("/usr/lib/", "/System/Library/")):
            assert fix, f"Build-machine runtime search path: {program.name}: {path}"
            subprocess.run(["/usr/bin/install_name_tool", "-delete_rpath", path, str(program)], check=True)
    libraries = subprocess.check_output(["/usr/bin/otool", "-L", str(program)], text=True).splitlines()[1:]
    libraries = [line.strip().split(" (compatibility")[0] for line in libraries]
    for library in libraries:
        assert library.startswith(("/usr/lib/", "/System/Library/")), f"External library dependency: {program.name}: {library}"
    minimum = re.search(r"cmd LC_BUILD_VERSION.*?minos ([\d.]+)", loads, re.S)
    report.append({"executable": str(program.relative_to(app)), "architectures": architectures,
                   "minimumOS": minimum[1] if minimum else None,
                   "onlySystemLinkedLibraries": True, "buildRpathsRemoved": fix})
print(json.dumps({"appMinimumOS": "26.0", "target": "Apple Silicon", "programs": report}, indent=2))
