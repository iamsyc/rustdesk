#!/usr/bin/env python3
"""Sign local RustDesk builds with a persistent certificate identity."""
import argparse
import os
from pathlib import Path
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("app", type=Path)
parser.add_argument("--identity", default=os.environ.get("RUSTDESK_SIGNING_IDENTITY"))
args = parser.parse_args()
if not args.identity or args.identity == "-":
    parser.error("set RUSTDESK_SIGNING_IDENTITY or pass a certificate identity")
app = args.app.resolve()
if app.suffix != ".app" or not (app / "Contents/MacOS/RustDesk").is_file():
    parser.error("expected a RustDesk app bundle")

def sign(path):
    command = [
        "codesign", "--force", "--sign", args.identity,
        "--preserve-metadata=identifier,entitlements",
    ]
    if path == app:
        command += ["--entitlements", str(Path(__file__).resolve().parent.parent /
                                          "flutter/macos/Runner/Release.entitlements")]
    subprocess.run(command + [str(path)], check=True)

magic = {bytes.fromhex(v) for v in (
    "feedface", "cefaedfe", "feedfacf", "cffaedfe", "cafebabe", "bebafeca",
    "cafebabf", "bfbafeca",
)}
main = app / "Contents/MacOS/RustDesk"
for path in sorted((app / "Contents").rglob("*")):
    if path.is_symlink() or not path.is_file() or path == main:
        continue
    with path.open("rb") as stream:
        if stream.read(4) not in magic:
            continue
    sign(path)
for path in sorted(app.rglob("*.framework"), key=lambda p: len(p.parts), reverse=True):
    if not path.is_symlink():
        sign(path)
sign(app)
subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
result = subprocess.run(["codesign", "-d", "-r-", str(app)], capture_output=True,
                        text=True, check=True)
requirement = next(line for line in result.stdout.splitlines() + result.stderr.splitlines()
                   if "designated =>" in line)
if "cdhash" in requirement:
    raise RuntimeError("app identity is still tied to a single build")
print(requirement)
