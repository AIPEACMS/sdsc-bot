# SDSC Bot

Telegram bot for volunteer availability and allocation.

Every 2 weeks it prompts members for their availability for the next 2
weekends, then allocates them to sessions (Sat/Sun, AM/PM).

- Pure Dart (`televerse` + `sqlite3`), long-polling, no webhook
- Scheduler runs in-process and catches up on restart

## Run

```sh
export TELEGRAM_TOKEN=...  # required
dart pub get
dart run bin/main.dart
```

## Test / lint

```sh
dart test
dart analyze
```

## Deploy

```sh
./deploy.sh
```

Builds a self-contained AOT bundle and deploys it to the production VM
by whatever private channel is available (`ssh user@host`).
