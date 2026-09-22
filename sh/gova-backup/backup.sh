#!/usr/bin/env bash
#
# Nightly backup of every GOVA app database on this server.
#
# NOT the normal path any more. Each app runs a `backup` service in its own
# docker-compose.yml, so deploying the app deploys its backups. This is the
# fallback for a host with no compose stack — keep it working, but do not run
# it alongside the containers or both will write the same object.
#
# For each app:  snapshot -> integrity check -> encrypt -> upload -> rotate.
#
# Why not rsync the file
# ----------------------
# Both apps open SQLite with _journal_mode=WAL. Committed transactions live in
# app.db-wal until a checkpoint folds them into app.db, so a copy of app.db
# alone is missing the most recent writes, and a copy of all three files taken
# mid-write can be inconsistent. Both restore without complaint and look fine,
# which is the dangerous part. `VACUUM INTO` uses SQLite's own online backup
# path: one consistent file, WAL contents included, taken safely while the app
# is serving traffic.
#
# Usage:   ./backup.sh
# Cron:    15 3 * * *  /home/chris/repos/handy-scripts/sh/gova-backup/backup.sh >> /var/log/gova-backup.log 2>&1
set -euo pipefail
cd "$(dirname "$0")"
source ./config.sh

require_tools sqlite3 age rclone
[ -n "$GOVA_AGE_RECIPIENT" ] || die "GOVA_AGE_RECIPIENT is not set. See README.md § Key custody."

# Staged snapshots are plaintext copies of the whole database, including
# clients' medical notes. They are removed whatever happens — a failed upload
# must not leave one behind.
cleanup() { rm -rf "$GOVA_WORK_DIR"; }
trap cleanup EXIT
rm -rf "$GOVA_WORK_DIR"
mkdir -p "$GOVA_WORK_DIR"

today="$(date -u +%F)"
day_of_month="$(date -u +%d)"
failures=0

while read -r entry; do
    app="${entry%%:*}"
    repo="${entry#*:}"
    db="$repo/data/app.db"

    log "=== $app"

    if [ ! -f "$db" ]; then
        echo "ERROR: $db does not exist — skipping $app" >&2
        failures=$((failures + 1))
        continue
    fi

    snapshot="$GOVA_WORK_DIR/$app-$today.db"

    # A consistent copy, taken while the app runs.
    if ! sqlite3 "$db" "VACUUM INTO '$snapshot'"; then
        echo "ERROR: snapshot failed for $app" >&2
        failures=$((failures + 1))
        continue
    fi

    # Verify the SNAPSHOT, not the live database. Uploading a corrupt file
    # over a good one is how a backup system destroys the thing it protects.
    check="$(sqlite3 "$snapshot" "PRAGMA integrity_check;" 2>&1 || true)"
    if [ "$check" != "ok" ]; then
        echo "ERROR: integrity check failed for $app: $check" >&2
        failures=$((failures + 1))
        continue
    fi

    # A structurally valid but empty database passes integrity_check happily.
    # Every one of these apps has users, so zero of them means something is
    # wrong upstream and this snapshot should not overwrite a good one.
    users="$(sqlite3 "$snapshot" "SELECT count(*) FROM users;" 2>/dev/null || echo 0)"
    if [ "$users" -lt 1 ]; then
        echo "ERROR: $app snapshot has no users — refusing to upload" >&2
        failures=$((failures + 1))
        continue
    fi

    log "$app: snapshot ok ($(du -h "$snapshot" | cut -f1), $users users)"

    # Encrypted here, on this machine, before it touches the network. Google
    # stores a blob it cannot read.
    encrypted="$snapshot.age"
    if ! age -r "$GOVA_AGE_RECIPIENT" -o "$encrypted" "$snapshot"; then
        echo "ERROR: encryption failed for $app" >&2
        failures=$((failures + 1))
        continue
    fi
    rm -f "$snapshot"

    remote_daily="$(gova_remote_base)/$app/daily"
    if ! rclone copy "$encrypted" "$remote_daily/" --no-traverse; then
        echo "ERROR: upload failed for $app" >&2
        failures=$((failures + 1))
        continue
    fi
    log "$app: uploaded to $remote_daily/$(basename "$encrypted")"

    # The first of the month is kept forever, in its own prefix so the daily
    # rotation below cannot reach it.
    if [ "$day_of_month" = "01" ]; then
        remote_monthly="$(gova_remote_base)/$app/monthly"
        rclone copy "$encrypted" "$remote_monthly/" --no-traverse \
            && log "$app: kept as monthly"
    fi

    # Rotate dailies only. Runs after a confirmed upload, so a failed night
    # never expires yesterday's good copy.
    rclone delete "$remote_daily" --min-age "${GOVA_DAILY_RETENTION_DAYS}d" \
        && log "$app: pruned dailies older than ${GOVA_DAILY_RETENTION_DAYS}d"

done < <(each_app)

if [ "$failures" -gt 0 ]; then
    die "$failures app(s) failed — see above"
fi
log "all backups complete"
