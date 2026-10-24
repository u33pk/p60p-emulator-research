#!/usr/bin/env python3
import argparse
import hashlib
import json
from pathlib import Path


def digest(data):
    return hashlib.sha256(data).hexdigest()


def main():
    parser = argparse.ArgumentParser(description="Apply a checked, version-specific binary patch")
    parser.add_argument("manifest", type=Path)
    parser.add_argument("binary", type=Path, help="a writable copy; never patch an SDK original")
    args = parser.parse_args()
    manifest = json.loads(args.manifest.read_text())
    data = args.binary.read_bytes()
    if "size" in manifest and len(data) != manifest["size"]:
        raise SystemExit(f"size mismatch: got {len(data)}, expected {manifest['size']}")
    if "source_sha256" in manifest and digest(data) != manifest["source_sha256"]:
        raise SystemExit("source SHA-256 mismatch; this patch belongs to another build")
    for patch in manifest["patches"]:
        offset = int(patch["offset"], 0)
        old = bytes.fromhex(patch["old"])
        new = bytes.fromhex(patch["new"])
        if len(old) != len(new) or data[offset:offset + len(old)] != old:
            raise SystemExit(f"original bytes mismatch at {patch['offset']}")
    for patch in manifest["patches"]:
        offset = int(patch["offset"], 0)
        new = bytes.fromhex(patch["new"])
        data = data[:offset] + new + data[offset + len(new):]
    args.binary.write_bytes(data)
    print(f"patched {args.binary}; sha256={digest(data)}")


if __name__ == "__main__":
    main()
