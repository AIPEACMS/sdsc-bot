# SDSC Bot

Telegram bot for volunteer availability and allocation.

Pure Dart (`televerse` + `sqlite3`), long-polling, no webhook.

## Run

```sh
export TELEGRAM_TOKEN=...  # required
export CONSOLE_ID=...      # required 
dart pub get
dart run bin/main.dart
```

## Test / lint

```sh
dart pub get
./tool/test-affected.sh
./tool/test-affected.sh --all
dart analyze
```

Pass `--base <git-ref>` to include committed changes since a base reference,
or `--all` to run the complete suite. CI always runs the full suite.

## Deploy

**Primary — GitHub Releases + `sdsc.sh`:**

1. Bump `pubspec.yaml` + move CHANGELOG `[Unreleased]` to the new version.
2. Tag the build: `git tag v0.2.0 && git push --tags` - GitHub Actions builds
   the bundle and publishes it as a Release.
3. As an administrator, run `./sdsc.sh update` (latest) or
   `./sdsc.sh update v0.2.0` (pinned).

**Fallback — manual copy:** `./deploy.sh` builds the bundle locally.

## License
- This project is licensed under the [EUPL-1.2](LICENSE) License.
