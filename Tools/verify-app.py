"""Validate the distributable bundle without launching it or accessing hardware."""
import os
from pathlib import Path
import plistlib
import struct
import subprocess
import sys
from bundle_signature import verify_bundle_signature

app = Path(sys.argv[1] if len(sys.argv) > 1 else "build/Applications.noindex/Sony Headphone Control.app")
info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
assert info["CFBundleIdentifier"] == "local.sonymenu.app"
assert info["CFBundleDisplayName"] == "Sony Headphone Control"
assert info.get("LSUIElement", False) is False
assert info["LSApplicationCategoryType"] == "public.app-category.utilities"
assert info.get("NSBluetoothAlwaysUsageDescription")
executable = app / "Contents/MacOS" / info["CFBundleExecutable"]
assert executable.is_file() and os.access(executable, os.X_OK)
icon_name = info["CFBundleIconFile"]
icon = app / "Contents/Resources" / (icon_name if icon_name.endswith(".icns") else icon_name + ".icns")
data = icon.read_bytes()
assert data[:4] == b"icns" and struct.unpack(">I", data[4:8])[0] == len(data)
chunks = set()
offset = 8
while offset < len(data):
    kind = data[offset:offset + 4]
    length = struct.unpack(">I", data[offset + 4:offset + 8])[0]
    assert length >= 8 and offset + length <= len(data)
    chunks.add(kind)
    offset += length
assert offset == len(data)
assert {b"ic07", b"ic08", b"ic09", b"ic10"}.issubset(chunks), chunks
assert chunks.intersection({b"icp4", b"ic04"}), "Missing 16px icon"
assert chunks.intersection({b"icp5", b"ic05"}), "Missing 32px icon"
assert (app / "Contents/Resources/ThirdPartyNotices.txt").is_file()
for name in ["Headphones.png", "HeadphonesSilver.png"]:
    artwork = (app / "Contents/Resources" / name).read_bytes()
    assert artwork[:8] == b"\x89PNG\r\n\x1a\n"
    assert min(struct.unpack(">II", artwork[16:24])) >= 128
signature = verify_bundle_signature(app)
print(f"Verified {info['CFBundleShortVersionString']}: app metadata, executable, icon sizes, notices and {signature}.")
