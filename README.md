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

```sh
dart test
dart analyze
```

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

**Fallback — manual copy:** `./deploy.sh` builds the bundle locally and ships
it over SSH (set `SDSC_HOST=user@host`) when GitHub is unreachable.
