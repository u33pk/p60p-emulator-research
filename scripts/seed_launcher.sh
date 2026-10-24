#!/bin/bash
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
DB=/data/app/el1/100/database/com.ohos.sceneboard/phone_sceneboard/rdb/Launcher.db
[[ -x $P60P_HDC_BIN ]] || { echo "hdc not executable: $P60P_HDC_BIN" >&2; exit 1; }
for _ in $(seq 1 180); do
    "$P60P_HDC_BIN" tconn "$P60P_HDC_TARGET" >/dev/null 2>&1 || true
    if "$P60P_HDC_BIN" list targets 2>/dev/null | grep -q "$P60P_HDC_TARGET"; then
        completed=$("$P60P_HDC_BIN" shell 'param get bootevent.boot.completed' 2>/dev/null | tr -d '[:space:]')
        if [[ $completed == true ]] && "$P60P_HDC_BIN" shell "test -f $DB" 2>/dev/null; then
            break
        fi
    fi
    sleep 2
done
count=$("$P60P_HDC_BIN" shell "/system/bin/sqlite3 $DB 'select count(*) from gridlayout_info;'" 2>/dev/null | tr -d '[:space:]')
if [[ $count != 0 ]]; then
    [[ $count =~ ^[0-9]+$ ]] || { echo "launcher database is unavailable" >&2; exit 1; }
    echo "launcher layout already present: $count"
    exit 0
fi
"$P60P_HDC_BIN" file send "$P60P_PROJECT_ROOT/scripts/seed_launcher.sql" /data/local/tmp/p60p_seed_launcher.sql
"$P60P_HDC_BIN" shell 'test -s /data/local/tmp/p60p_seed_launcher.sql'
"$P60P_HDC_BIN" shell "/system/bin/sqlite3 $DB < /data/local/tmp/p60p_seed_launcher.sql"
count=$("$P60P_HDC_BIN" shell "/system/bin/sqlite3 $DB 'select count(*) from gridlayout_info;'" 2>/dev/null | tr -d '[:space:]')
[[ $count == 15 ]] || { echo "launcher seed verification failed: $count" >&2; exit 1; }
for delay in 0 30; do
    if ((delay)); then sleep "$delay"; fi
    pid=$("$P60P_HDC_BIN" shell 'pidof com.ohos.sceneboard' 2>/dev/null | tr -d '[:space:]')
    if [[ -n $pid ]]; then "$P60P_HDC_BIN" shell "kill -9 $pid"; fi
done
echo "launcher layout seeded"
