#!/bin/bash
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
OUTPUT_DIR=${1:-$P60P_WORK_ROOT/screenshots}
mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR=$(cd "$OUTPUT_DIR" && pwd)
"$P60P_EMULATOR_BIN" -instance "$P60P_INSTANCE_NAME" -screenshot -screenshotPath "$OUTPUT_DIR"
