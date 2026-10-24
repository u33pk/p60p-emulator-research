#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CC=${CC:-aarch64-linux-musl-gcc}
command -v "$CC" >/dev/null || { echo "set CC to an aarch64 Linux C compiler" >&2; exit 1; }
mkdir -p "$ROOT/work"
"$CC" -static -O2 -Wall -Wextra -o "$ROOT/work/input_event_inject" "$ROOT/tools/input_event_inject.c"
echo "built $ROOT/work/input_event_inject"
