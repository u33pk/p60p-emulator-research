#!/bin/bash
set -euo pipefail
P60P_PROJECT_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
if [[ -n ${P60P_CONFIG:-} ]]; then
    source "$P60P_CONFIG"
elif [[ -f "$P60P_PROJECT_ROOT/config.sh" ]]; then
    source "$P60P_PROJECT_ROOT/config.sh"
fi
: "${P60P_SDK_ROOT:?set P60P_SDK_ROOT in config.sh or the environment}"
: "${P60P_IMAGE_ROOT:?set P60P_IMAGE_ROOT in config.sh or the environment}"
: "${P60P_INSTANCE_PATH:?set P60P_INSTANCE_PATH in config.sh or the environment}"
P60P_INSTANCE_NAME=${P60P_INSTANCE_NAME:-HarmonyOS_P60P}
P60P_HDC_PORT=${P60P_HDC_PORT:-5555}
P60P_HDC_TARGET=127.0.0.1:$P60P_HDC_PORT
P60P_WORK_ROOT=${P60P_WORK_ROOT:-$P60P_PROJECT_ROOT/work}
P60P_EMULATOR_BIN=${P60P_EMULATOR_BIN:-$P60P_SDK_ROOT/emulator/Emulator}
P60P_HDC_BIN=${P60P_HDC_BIN:-$P60P_SDK_ROOT/sdk/default/openharmony/toolchains/hdc}
export DISPLAY=${P60P_DISPLAY:-${DISPLAY:-:0}}
if [[ -n ${P60P_XAUTHORITY:-} ]]; then
    export XAUTHORITY=$P60P_XAUTHORITY
fi
mkdir -p "$P60P_WORK_ROOT"
