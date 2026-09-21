#!/usr/bin/env bash
#
# Shared configuration. Sourced by backup.sh, restore.sh and verify-restore.sh.
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

# rclone remote and prefix. `rclone config` creates the remote; the name here
# must match. Everything lands under <remote>:<prefix>/<app>/…
: "${GOVA_RCLONE_REMOTE:=G-Drive}"
: "${GOVA_RCLONE_PREFIX:=grfp-backups}"

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
