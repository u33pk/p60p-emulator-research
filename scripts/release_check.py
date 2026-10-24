#!/usr/bin/env python3
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
FORBIDDEN_SUFFIXES = {
    ".img", ".bin", ".mbn", ".zip", ".qcow2", ".so", ".hap", ".hsp",
    ".hwp7s", ".db", ".db-wal", ".db-shm", ".log", ".dylib", ".p7s",
}
FORBIDDEN_NAMES = {"Emulator", "userdata.img", "payload.bin", "update.bin", "Image"}
FORBIDDEN_PARTS = {"sdk", "deployed", "image_root", "node_modules", "__pycache__"}
MAX_FILE_SIZE = 4 * 1024 * 1024
SENSITIVE = re.compile(
    r"(?i)(password\s*[:=]|passwd\s*[:=]|refresh[_-]?token\s*[:=]|"
    r"access[_-]?token\s*[:=]|BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY|"
    r"/home/" r"orz|/Users/" r"vv|mutter-Xwaylandauth\.[A-Za-z0-9]+)"
)
errors = []
for path in ROOT.rglob("*"):
    rel = path.relative_to(ROOT)
    if any(part in FORBIDDEN_PARTS for part in rel.parts):
        errors.append(f"forbidden directory: {rel}")
        continue
    if path.is_symlink():
        errors.append(f"symlink is not allowed in release: {rel}")
        continue
    if not path.is_file():
        continue
    if path.name in FORBIDDEN_NAMES or path.suffix.lower() in FORBIDDEN_SUFFIXES:
        errors.append(f"forbidden file: {rel}")
    size = path.stat().st_size
    if size > MAX_FILE_SIZE:
        errors.append(f"file exceeds {MAX_FILE_SIZE} bytes: {rel}")
    if size <= 2 * 1024 * 1024:
        try:
            text = path.read_text()
        except (UnicodeDecodeError, OSError):
            text = ""
        match = SENSITIVE.search(text)
        if match:
            errors.append(f"local path or possible secret ({match.group(0)}): {rel}")
if errors:
    print("\n".join(errors), file=sys.stderr)
    raise SystemExit(1)
files = [p for p in ROOT.rglob("*") if p.is_file()]
print(f"release check passed: {len(files)} files, {sum(p.stat().st_size for p in files)} bytes")
