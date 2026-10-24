#!/bin/bash
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
DB=/data/app/el1/100/database/com.ohos.sceneboard/phone_sceneboard/rdb/Launcher.db
"$P60P_HDC_BIN" tconn "$P60P_HDC_TARGET"
"$P60P_HDC_BIN" -t "$P60P_HDC_TARGET" shell 'echo "== identity =="; id; echo "== SELinux =="; getenforce; echo "== boot =="; param get bootevent.boot.completed; echo "== model =="; param get const.product.model; echo "== hardware =="; param get ohos.boot.hardware'
echo "== launcher rows =="
"$P60P_HDC_BIN" -t "$P60P_HDC_TARGET" shell "/system/bin/sqlite3 $DB 'select count(*) from gridlayout_info;'"
