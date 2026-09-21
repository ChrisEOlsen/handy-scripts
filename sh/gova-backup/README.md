# gova-backup

Nightly encrypted backups of the GOVA app databases, and — the part that
matters — a restore that has been tested.

Runs on the **server** (`theonewhocentres`), not on a laptop. The app
containers are minimal Debian with no `sqlite3`, `age` or `rclone`; the
databases are bind-mounted to the host at `~/repos/<app>/data/app.db`, so the
host reads them directly. WAL mode makes that safe while the apps are serving.

| Script | What it does |
|---|---|
| `backup.sh` | Snapshot → verify → encrypt → upload → rotate. Cron runs this. |
| `restore.sh` | Restore one app from a chosen backup. Interactive. |
| `verify-restore.sh` | Prove a backup still decrypts and opens. Run monthly, by hand. |
| `config.sh` | Shared settings. Override in the environment, don't edit. |

## Why not just rsync the .db file

Both apps open SQLite with `_journal_mode=WAL`. Committed transactions sit in
`app.db-wal` until a checkpoint folds them into `app.db`. So:

- copying `app.db` alone silently loses the most recent writes;
- copying all three files mid-write can capture an inconsistent set.

Both restore without complaining and look correct. `VACUUM INTO` uses SQLite's
own online-backup path instead: one self-contained file, WAL contents included,
taken safely while the app runs.

## Install (once, on the server)

```sh
sudo apt update && sudo apt install -y sqlite3 age rclone
git clone <this repo> ~/repos/handy-scripts
```

Configure the Google Drive remote — this is interactive and needs a browser:

```sh
rclone config          # name it: gdrive
rclone lsd gdrive:     # confirm it works
```

Generate the encryption keypair. **Do this on your laptop, not the server:**

```sh
age-keygen -o grfp-backup.key
# public key: age1xxxxxxxx...
```

Put the **public** key on the server:

```sh
echo 'export GOVA_AGE_RECIPIENT=age1xxxxxxxx...' >> ~/.profile
```

Schedule it:

```sh
crontab -e
15 3 * * *  /home/chris/repos/handy-scripts/sh/gova-backup/backup.sh >> /var/log/gova-backup.log 2>&1
```

## Key custody — read this

The server holds only the **public** key. It can create backups; it cannot read
them. That is on purpose: someone who takes the server gets the live database,
which they already had, and not three years of history.

The consequence is blunt: **lose the private key and every backup is
permanently unreadable.** There is no recovery and no reset.

So put `grfp-backup.key` in at least two places that are not the server:

- your password manager, as a secure note;
- a printed copy somewhere physical, or a second offline drive.

The private key is needed only by `restore.sh` and `verify-restore.sh`, only
when you actually run them. It should never be committed, never be on the
server, and never be in the Drive folder that holds the backups.

## Restoring

See what exists:

```sh
./restore.sh --list grfp-ws-lift-tracker
```

Restore the newest, or a specific day:

```sh
./restore.sh grfp-ws-lift-tracker latest
./restore.sh grassroots-client-tracking 2026-09-14
```

The script verifies the candidate before touching anything, prints what it is
about to install, and makes you type the app name to confirm. It stops the
container, moves the current database aside as
`app.db.pre-restore-<timestamp>`, removes the stale `-wal`/`-shm`, copies the
restored file in, and starts the container.

**Nothing is deleted.** The database you replaced stays on disk until you
remove it yourself.

## Testing that backups work

`backup.sh` verifies every snapshot before it uploads — integrity check plus a
row count — and refuses to upload a file that fails. That runs nightly and is
the safety net against silently shipping a corrupt backup over a good one.

What it cannot check is that the encryption round-trips and that your key still
opens the archive, because it does not have the key. That is what
`verify-restore.sh` is for:

```sh
GOVA_AGE_KEY_FILE=~/grfp-backup.key ./verify-restore.sh grfp-ws-lift-tracker
```

Run it monthly, and after any change to `backup.sh`. It touches no app data.

## What the privacy policy says

Both apps' `/privacy` pages name Cloudflare and Resend as the only third
parties. Once backups are live, Google Drive joins that list. A line like:

> Encrypted backups are stored with Google Drive. They are encrypted before
> they leave our server and Google cannot read them.

If you would rather not add Google, point `GOVA_RCLONE_REMOTE` at Cloudflare
R2 instead — Cloudflare is already named, so the processor list does not grow.
