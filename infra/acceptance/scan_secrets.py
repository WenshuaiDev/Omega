"""Scan known fixture secrets in files, exported image config/history and layers."""
import gzip
from pathlib import Path
import sys
import tarfile

bundle, inputs, evidence = map(Path, sys.argv[1:])
markers = [p.read_bytes().strip() for p in inputs.glob("*/secrets/*") if p.is_file()]
markers += [p.read_bytes().splitlines()[1] for p in inputs.glob("*/tls/key.pem")]
assert markers and all(len(value) >= 32 for value in markers)
count = 0


def check(data, label):
    global count
    count += 1
    if any(value in data for value in markers):
        raise SystemExit("Secret marker found in " + label)


for root in (bundle, evidence):
    for path in root.rglob("*"):
        if path.is_file() and path.name != "images.tar":
            check(path.read_bytes(), str(path))
with tarfile.open(bundle / "images.tar", "r") as archive:
    for member in archive:
        if not member.isfile():
            continue
        data = archive.extractfile(member).read()
        check(data, member.name)
        if data[:2] == b"\x1f\x8b":
            check(gzip.decompress(data), member.name + " decompressed gzip layer")
        elif data[:4] == b"\x28\xb5\x2f\xfd":
            raise SystemExit("Unsupported zstd layer: extend scanner before claiming a pass")
print(f"Secret scan passed: {len(markers)} private fixture markers, {count} file/config/history/raw/decompressed layer checks; marker values never printed")
