#!/usr/bin/env bash
#
# Restore one app's database from an encrypted backup.
#
# Deliberately interactive and deliberately slow. It verifies the candidate
# before it touches anything, shows you what you are about to install, asks
# out loud, and keeps the database it replaces.
#
# Usage:
#   ./restore.sh --list <app>
#   ./restore.sh <app> latest
#   ./restore.sh <app> 2026-09-14
#
# The age PRIVATE key is required here and nowhere else. Point at it with
# GOVA_AGE_KEY_FILE, or the script asks. See README.md § Key custody.
set -euo pipefail
cd "$(dirname "$0")"
source ./config.sh

usage() { sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }
[ $# -ge 1 ] || usage

# --- locate the app -----------------------------------------------------------

repo_for() {
    local want="$1"
    while read -r entry; do
        [ "${entry%%:*}" = "$want" ] && { echo "${entry#*:}"; return 0; }
    done < <(each_app)
    return 1
}

if [ "$1" = "--list" ]; then
    [ $# -eq 2 ] || usage
    app="$2"
    require_tools rclone
    base="$(gova_remote_base)"
    echo "daily:"
    rclone lsf "$base/$app/daily" 2>/dev/null | sort || true
    echo "monthly:"
    rclone lsf "$base/$app/monthly" 2>/dev/null | sort || true
    exit 0
fi

[ $# -eq 2 ] || usage
app="$1"
when="$2"
repo="$(repo_for "$app")" || die "unknown app '$app'. Known: $(each_app | cut -d: -f1 | tr '\n' ' ')"

require_tools sqlite3 age rclone docker

# --- find the private key -----------------------------------------------------

key="${GOVA_AGE_KEY_FILE:-}"
if [ -z "$key" ]; then
    read -r -p "Path to the age private key file: " key
fi
[ -f "$key" ] || die "no such key file: $key
The private key is not kept on this server by design. Retrieve it from your
password manager — see README.md § Key custody."

# --- pick the file ------------------------------------------------------------

work="$GOVA_WORK_DIR/restore-$$"
cleanup() { rm -rf "$work"; }
trap cleanup EXIT
mkdir -p "$work"

remote_base="$(gova_remote_base)/$app"

if [ "$when" = "latest" ]; then
    name="$(rclone lsf "$remote_base/daily" 2>/dev/null | sort | tail -1)"
    [ -n "$name" ] || die "no daily backups found for $app"
    src="$remote_base/daily/$name"
else
    name="$app-$when.db.age"
    if rclone lsf "$remote_base/daily/$name" >/dev/null 2>&1 \
        && [ -n "$(rclone lsf "$remote_base/daily/$name" 2>/dev/null)" ]; then
        src="$remote_base/daily/$name"
    elif [ -n "$(rclone lsf "$remote_base/monthly/$name" 2>/dev/null)" ]; then
        src="$remote_base/monthly/$name"
    else
        die "no backup named $name. Run: ./restore.sh --list $app"
    fi
fi

log "fetching $src"
rclone copyto "$src" "$work/$name"

# --- decrypt and verify BEFORE touching the live database ---------------------

candidate="$work/candidate.db"
log "decrypting"
age -d -i "$key" -o "$candidate" "$work/$name" \
    || die "decryption failed — wrong key, or the file is damaged"

log "checking integrity"
check="$(sqlite3 "$candidate" "PRAGMA integrity_check;" 2>&1 || true)"
[ "$check" = "ok" ] || die "integrity check failed: $check"

users="$(sqlite3 "$candidate" "SELECT count(*) FROM users;")"
[ "$users" -ge 1 ] || die "this backup contains no users — refusing to install it"

echo
echo "  backup:     $name"
echo "  users:      $users"
echo "  size:       $(du -h "$candidate" | cut -f1)"
echo "  tables:     $(sqlite3 "$candidate" "SELECT count(*) FROM sqlite_master WHERE type='table';")"
echo "  newest row: $(sqlite3 "$candidate" "SELECT max(created_at) FROM users;" 2>/dev/null || echo 'n/a')"
echo
echo "  This REPLACES $repo/data/app.db"
echo "  The current database will be kept alongside it, not deleted."
echo
read -r -p "Type the app name to confirm: " confirm
[ "$confirm" = "$app" ] || die "aborted"

# --- swap it in ---------------------------------------------------------------

# The app must be down. A running process holds the old file open, and the
# restored database would be written over by whatever it checkpoints next.
log "stopping $app"
( cd "$repo" && docker compose stop app )

stamp="$(date -u +%Y%m%dT%H%M%SZ)"
data="$repo/data"

if [ -f "$data/app.db" ]; then
    mv "$data/app.db" "$data/app.db.pre-restore-$stamp"
    log "kept previous database as app.db.pre-restore-$stamp"
fi

# The stale WAL is the trap here. Left in place it belongs to the database we
# just moved aside, and SQLite would try to replay it over the restored file.
# A VACUUM INTO snapshot is self-contained and needs neither of these.
rm -f "$data/app.db-wal" "$data/app.db-shm"

cp "$candidate" "$data/app.db"

# Match whatever the app's own database was owned by, so the container can
# still write to it. Falls back to the invoking user.
if [ -f "$data/app.db.pre-restore-$stamp" ]; then
    chown --reference="$data/app.db.pre-restore-$stamp" "$data/app.db" 2>/dev/null || true
    chmod --reference="$data/app.db.pre-restore-$stamp" "$data/app.db" 2>/dev/null || true
fi

log "starting $app"
( cd "$repo" && docker compose start app )

echo
log "restored $app from $name"
echo "Previous database: $data/app.db.pre-restore-$stamp"
echo "Delete it once you have confirmed the app works."
