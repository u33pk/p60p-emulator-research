#!/bin/bash
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
[[ -x $P60P_EMULATOR_BIN ]] || { echo "Emulator not executable: $P60P_EMULATOR_BIN" >&2; exit 1; }
[[ -d $P60P_IMAGE_ROOT ]] || { echo "imageRoot not found: $P60P_IMAGE_ROOT" >&2; exit 1; }
mkdir -p "$P60P_INSTANCE_PATH"
"$P60P_PROJECT_ROOT/scripts/seed_launcher.sh" > "$P60P_WORK_ROOT/seed_launcher.log" 2>&1 &
exec "$P60P_EMULATOR_BIN" -start "$P60P_INSTANCE_NAME" \
    -instancePath "$P60P_INSTANCE_PATH" -imageRoot "$P60P_IMAGE_ROOT"
