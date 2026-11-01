# SDSC Bot

Telegram bot for volunteer availability and allocation.

Every 2 weeks it prompts members for their availability for the next 2
weekends, then allocates them to sessions (Sat/Sun, AM/PM).

- Pure Dart (`televerse` + `sqlite3`), long-polling, no webhook
- Scheduler runs in-process and catches up on restart

## Run

```sh
export TELEGRAM_TOKEN=...  # required
export CONSOLE_ID=...      # required — the console user's Telegram id (secret)
dart pub get
dart run bin/main.dart
```

## Test / lint

For local development, run the affected test suites with four workers. Bot
integration tests wait for a fake Telegram long-poll readiness signal instead
of sleeping for a guessed startup interval:

```sh
./tool/test-affected.sh
./tool/test-affected.sh --all
dart analyze
```

Pass `--base <git-ref>` to include committed changes since a base reference,
or `--all` to run the complete suite. CI always runs the full suite.

## Deploy

**Primary — GitHub Releases + `sdsc.sh`:**

1. Bump `pubspec.yaml` + move CHANGELOG `[Unreleased]` to the new version,
   commit, push.
2. Tag the build: `git tag v0.2.0 && git push --tags` — GitHub Actions builds
   the bundle and publishes it as a Release.
3. On the VM: `./sdsc.sh update` (latest) or `./sdsc.sh update v0.2.0`
   (pinned). Pulls the release, verifies checksum, swaps the bundle,
   restarts the service, rolls back on failure.

Secrets never touch CI: `TELEGRAM_TOKEN` / `CONSOLE_ID` live only in the
secret env file on the VM.

### Runtime ownership and migration

The tracked unit is `deploy/sdsc-bot.service`, installed as
`/etc/systemd/system/sdsc-bot.service`. The bot runs as unprivileged `sbo:sbo`,
with no sudo access. Long polling and user ports require no elevated privileges.
Privileged deployment remains separate from the runtime account:

- `/opt/sdsc-bot/bin/main` and the installed bundle remain root-owned and
  executable/readable by `sbo`, not writable by it. Do not delete the binary.
- `/var/lib/sdsc-bot` is owned by `sbo:sbo`, mode `0700`, and is the working
  directory for writable state. `SDSC_DB` selects the database path; its default
  `sdsc.db` resolves here. Preserve the existing database and any SQLite sidecars.
- `/etc/sdsc-bot/sdsc-bot.env` remains `root:root`, mode `0600`. Systemd loads
  it before starting the bot; `sbo` does not need file access. Track the unit,
  never the secret environment file.

For the existing installation, a privileged administrator performs the migration:

1. Stop `sdsc-bot.service` before changing the account or starting another
   instance. Rename the existing `sdsc-bot` account and group to `sbo`, preserving
   its existing numeric user and group IDs; do not create a second account or
   grant sudo access.
2. Preserve the live database at its configured path, with its writable state
   accessible to `sbo`. Set the state directory ownership and permissions above,
   and ensure `SDSC_DB` resolves to the existing database, not a new empty file.
3. Install the tracked unit, run `systemctl daemon-reload`, then
   `systemctl start sdsc-bot.service`. Check `systemctl status sdsc-bot.service`
   confirms it is active under the renamed account.
4. Have the user send one bot message and test the console once. Wait for their
   explicit cleanup authorization before removing any old state or configuration.

This is a runtime configuration migration, not a new application build; no
version bump or release is needed. The updater and calendar job are unchanged;
calendar scheduling can be migrated separately after its environment is checked.

**Fallback — manual copy:** `./deploy.sh` builds the bundle locally and ships
it over SSH (set `SDSC_HOST=user@host`) when GitHub is unreachable.

## License
- This project is licensed under the [EUPL-1.2](LICENSE) License.
