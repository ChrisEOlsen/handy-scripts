#!/usr/bin/env bash
#
# Shared configuration. Sourced by restore.sh and verify-restore.sh.
#
# Taking a backup is no longer done from here: each app runs a `backup` service
# in its own docker-compose.yml, so deploying the app deploys its backups. This
# directory is the RESTORE side, which stays on the host and stays manual —
# swapping a live database needs the app stopped, and a container can only stop
# its sibling if it is handed the Docker socket. backup.sh is kept for a host
# that has no compose stack.
# Override any of these in the environment rather than editing this file, so a
# `git pull` on the server never clobbers local settings.

# Settings live here rather than in a shell profile because cron does not read
# one: a cron job gets a near-empty environment, so an `export` in ~/.profile is
# invisible to it and GOVA_AGE_RECIPIENT would arrive empty every night. This
# file is not in git, so a `git pull` on the server cannot clobber it.
GOVA_ENV_FILE="${GOVA_ENV_FILE:-$HOME/.gova-backup.env}"
# shellcheck source=/dev/null
[ -f "$GOVA_ENV_FILE" ] && . "$GOVA_ENV_FILE"

# The apps to back up, as "name:path-to-repo". Each repo's live database is at
# <repo>/data/app.db — that path is the docker bind mount from
# docker-compose.yml, so the host can read it directly while the container
# writes to it. WAL mode makes that safe for a reader.
: "${GOVA_APPS:=grassroots-client-tracking:$HOME/repos/grassroots-client-tracking grfp-ws-lift-tracker:$HOME/repos/grfp-ws-lift-tracker}"

# rclone remote, bucket, and an optional folder inside it. Everything lands
# under <remote>:<bucket>[/<prefix>]/<app>/…
: "${GOVA_RCLONE_REMOTE:=r2}"

# REQUIRED, and separate from any folder. With an s3 backend the first path
# segment of remote:path IS the bucket — not a directory the way it is on
# Google Drive. Folding the two together is how the backup first ran against a
# bucket literally named "backups" and answered 403 on every upload, which
# reads exactly like a bad credential.
: "${GOVA_BACKUP_BUCKET:=}"

# R2 credentials, for restore and the verify drill. rclone reads a remote
# entirely from RCLONE_CONFIG_<NAME>_* variables, so there is no rclone.conf on
# this machine either — the same values the apps' .env files already hold.
: "${RCLONE_CONFIG_R2_TYPE:=s3}"
: "${RCLONE_CONFIG_R2_PROVIDER:=Cloudflare}"
: "${RCLONE_CONFIG_R2_REGION:=auto}"
export RCLONE_CONFIG_R2_TYPE RCLONE_CONFIG_R2_PROVIDER RCLONE_CONFIG_R2_REGION
export RCLONE_CONFIG_R2_ACCESS_KEY_ID RCLONE_CONFIG_R2_SECRET_ACCESS_KEY RCLONE_CONFIG_R2_ENDPOINT
# Optional folder inside the bucket. Empty means each app's folder sits at the
# bucket root, which is what the backup service writes by default.
: "${GOVA_RCLONE_PREFIX:=}"

# The <remote>:<bucket>[/<prefix>] base every path is built from. Assembled
# rather than interpolated so an empty prefix does not leave a doubled slash,
# which R2 treats as a real, differently named key.
gova_remote_base() {
    [ -n "$GOVA_BACKUP_BUCKET" ] || die "GOVA_BACKUP_BUCKET is not set. See README.md."
    if [ -n "$GOVA_RCLONE_PREFIX" ]; then
        echo "$GOVA_RCLONE_REMOTE:$GOVA_BACKUP_BUCKET/$GOVA_RCLONE_PREFIX"
    else
        echo "$GOVA_RCLONE_REMOTE:$GOVA_BACKUP_BUCKET"
    fi
}

# The age RECIPIENT — a public key, safe to keep on the server.
#
# This is the whole point of using a keypair instead of a passphrase: the
# server can encrypt a backup but cannot read one. Someone who takes the
# server gets today's database, which they already had, and nothing else.
#
# The matching PRIVATE key must NOT live here. See README.md § Key custody.
: "${GOVA_AGE_RECIPIENT:=}"

# How long daily snapshots are kept. Backups taken on the first of the month
# are also copied to monthly/ and kept indefinitely.
: "${GOVA_DAILY_RETENTION_DAYS:=30}"

# Where snapshots are staged before upload. Wiped on exit, including on error.
: "${GOVA_WORK_DIR:=/tmp/gova-backup}"

die() { echo "ERROR: $*" >&2; exit 1; }
log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"; }

# Fails loudly rather than producing a backup nobody can read.
require_tools() {
    for tool in "$@"; do
        command -v "$tool" >/dev/null 2>&1 || die "$tool is not installed. See README.md § Install."
    done
}

# Splits "name:path" pairs in GOVA_APPS into the caller's loop.
each_app() {
    for entry in $GOVA_APPS; do
        echo "$entry"
    done
}
