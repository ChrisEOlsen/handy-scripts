#!/usr/bin/env bash
#
# Prove a backup is actually restorable, without touching production.
#
# Downloads the newest backup, decrypts it, and opens it as a real database:
# integrity check, table count, row counts on the tables that matter. Nothing
# is written to any app's data directory.
#
# Run this by hand, roughly monthly, and after any change to backup.sh.
#
# Why this is not in cron
# -----------------------
# It needs the age PRIVATE key, and the private key is deliberately not kept on
# this server — see README.md § Key custody. Putting it here to automate this
# drill would hand today's attacker every historical backup too.
#
# backup.sh already runs the automatable half of this every night: it checks
# integrity and row counts on the snapshot BEFORE encrypting, and refuses to
# upload a file that fails. What only this script can prove is that the
# encryption round-trips and that your key still opens the archive.
#
# Usage:  ./verify-restore.sh <app>
set -euo pipefail
cd "$(dirname "$0")"
source ./config.sh

[ $# -eq 1 ] || { echo "usage: $0 <app>" >&2; exit 1; }
app="$1"
require_tools sqlite3 age rclone

key="${GOVA_AGE_KEY_FILE:-}"
if [ -z "$key" ]; then
    read -r -p "Path to the age private key file: " key
fi
[ -f "$key" ] || die "no such key file: $key"

work="$GOVA_WORK_DIR/verify-$$"
cleanup() { rm -rf "$work"; }
trap cleanup EXIT
mkdir -p "$work"

remote="$(gova_remote_base)/$app/daily"
name="$(rclone lsf "$remote" 2>/dev/null | sort | tail -1)"
[ -n "$name" ] || die "no backups found at $remote"

log "newest backup: $name"
rclone copyto "$remote/$name" "$work/$name"

age -d -i "$key" -o "$work/candidate.db" "$work/$name" \
    || die "FAILED: could not decrypt. Your key does not match these backups."
log "decrypted ok"

check="$(sqlite3 "$work/candidate.db" "PRAGMA integrity_check;" 2>&1 || true)"
[ "$check" = "ok" ] || die "FAILED: integrity check: $check"
log "integrity ok"

echo
echo "  file:   $name"
echo "  size:   $(du -h "$work/candidate.db" | cut -f1)"
echo "  tables: $(sqlite3 "$work/candidate.db" "SELECT count(*) FROM sqlite_master WHERE type='table';")"
echo
# Row counts for whatever tables this app happens to have. Each app has a
# different set, so ask the database rather than assuming.
for t in $(sqlite3 "$work/candidate.db" \
        "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name;"); do
    printf "  %-22s %s\n" "$t" "$(sqlite3 "$work/candidate.db" "SELECT count(*) FROM \"$t\";")"
done
echo
log "PASS — $app can be restored from $name"
