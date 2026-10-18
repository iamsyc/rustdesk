#!/usr/bin/env python3
"""Finalize a client bundle with the required texture-lifetime Flutter engine."""
import argparse
import os
from pathlib import Path
import re
import shutil
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("app", type=Path)
parser.add_argument("engine", type=Path)
parser.add_argument("--signing-identity", default=os.environ.get("RUSTDESK_SIGNING_IDENTITY"))
parser.add_argument("--ad-hoc", action="store_true", help="CI development artifacts only")
args = parser.parse_args()
if args.ad_hoc and args.signing_identity:
    parser.error("choose a persistent identity or --ad-hoc")
if not args.ad_hoc and (not args.signing_identity or args.signing_identity == "-"):
    parser.error("set RUSTDESK_SIGNING_IDENTITY or pass --signing-identity")
app, engine = args.app.resolve(), args.engine.resolve()
if app.suffix != ".app" or engine.name != "FlutterMacOS.framework":
    parser.error("expected an app bundle and FlutterMacOS.framework")
binary = engine / "FlutterMacOS"
required_selector = b"wrapRGBATexture:grContext:width:height:releaseProc:releaseContext:\x00"
engine_data = binary.read_bytes()
if required_selector not in engine_data:
    parser.error("Flutter engine lacks the required Metal texture lifetime patch")
if b"wrapYUVATexture:UVTex:YUVColorSpace:grContext:width:height:imageColorSpace:chromaCositedX:chromaCositedY:releaseProc:releaseContext:\x00" not in engine_data:
    parser.error("Flutter engine lacks native NV12 ownership, ICC and chroma-siting support")
backend = app / "Contents/Frameworks/liblibrustdesk.dylib"
architecture = subprocess.check_output(["lipo", "-archs", str(backend)], text=True).strip()
if architecture not in ("x86_64", "arm64"):
    parser.error(f"expected a single macOS architecture, got {architecture}")
renderer = app / "Contents/Frameworks/texture_rgba_renderer.framework/texture_rgba_renderer"
if b"FlutterRgbaRendererPluginOnPixelBuffer\x00" not in renderer.read_bytes():
    parser.error("texture renderer lacks the native pixel-buffer entry point")
for candidate in (binary, backend, renderer, app / "Contents/MacOS/RustDesk"):
    arch = subprocess.check_output(["lipo", "-archs", str(candidate)], text=True).strip()
    if arch != architecture:
        parser.error(f"expected {architecture} binary, got {arch}: {candidate}")
    build = subprocess.check_output(["xcrun", "vtool", "-show-build", str(candidate)], text=True)
    target = re.search(r"\bminos\s+(\S+)", build)
    if not target or target[1] != "15.8":
        parser.error(f"expected binary minimum macOS 15.8: {candidate}")
minimum = subprocess.check_output([
    "/usr/libexec/PlistBuddy", "-c", "Print :LSMinimumSystemVersion",
    str(app / "Contents/Info.plist"),
], text=True).strip()
if minimum != "15.8":
    parser.error(f"expected minimum macOS 15.8, got {minimum}")
destination = app / "Contents/Frameworks/FlutterMacOS.framework"
if engine == destination.resolve():
    parser.error("engine must be outside the app being finalized")
shutil.rmtree(destination)
subprocess.run(["ditto", str(engine), str(destination)], check=True)
if args.ad_hoc:
    subprocess.run([
        "codesign", "--force", "--deep", "--sign", "-", "--entitlements",
        str(Path(__file__).resolve().parent.parent / "flutter/macos/Runner/Release.entitlements"),
        str(app),
    ], check=True)
else:
    subprocess.run([
        "python3", str(Path(__file__).with_name("sign-macos-local.py")),
        str(app), "--identity", args.signing_identity,
    ], check=True)
subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
print(f"PASS: {architecture} client, macOS 15.8, texture lifetime engine, bundle signature")
