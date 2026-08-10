# Changelog

All notable user-facing changes to the SDSC bot.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [0.7.0] - 2026-08-10

### Changed

- **`/start` list trimmed to current commands**: removed the retired
  `/holidayset` and `/holidayclear` lines; added the console's
  `/sync-calendar` to the console section and its grid.
- **More interactive command responses**: the picker/wizard pattern from
  `ask`/`announce` now covers the remaining argument-taking commands.
  - `add-user` / `add-admin` → picker of users who have contacted the bot
    but aren't registered yet (paginated, tap to add).
  - `set-exp` / `set-group` → pick the value first (experienced/newbie,
    A/B), then pick the member.
  - `set-date` → asks you to send the date as the next message (with a
    Cancel button) instead of demanding it inline.
  - `sync-calendar` → asks you to paste the calendar YAML as the next
    message (with a Cancel button).

## [Unreleased]

## [0.6.0] - 2026-08-10

### Added

- **Academic-calendar integration**: the bot ingests the NTU academic
  calendar YAML (from the `parse-ntu-calander` tool) and derives break
  weeks automatically — recess weeks become mid-term breaks, the S1→S2 gap
  becomes the winter break, and post-semester weeks become the summer break.
- **Calendar IPC endpoint**: the bot exposes a token-authenticated loopback
  TCP listener; a cron script pushes the year's calendar YAML into the
  running process without a restart.
- **`calendar-sync.sh`**: yearly (Aug 1) side-script that fetches the
  calendar YAML from the parse repo and pushes it via IPC; fails silently
  if the year isn't published yet.
- **`/sync-calendar`** (console): manually apply a calendar YAML.

### Removed

- Manual admin holiday commands (`/holidayset`, `/holidayclear` and their
  grid buttons) — breaks now come from the academic calendar.

## [0.5.0] - 2026-08-10

### Added

- **Interactive command responses**: commands that need arguments now show
  inline buttons instead of a dead-end "Usage:" message.
  - `ask` → paginated member picker (6 per page, ⬅➡ paging) → tap a member
    to send them the availability picker.
  - `announce` (broadcast) → asks you to type the message, then shows a
    [Send] [Cancel] confirmation before sending to all members.
  - Reusable picker API (`Pickers`): paginated member picker + confirm
    dialogs, with a 10-minute wizard timeout.

### Fixed

- **Grid buttons now actually run their commands**: the text middleware
  previously consumed every message before the button-press handlers could
  run — pressing a grid button did nothing. Handlers now continue the
  middleware chain.
- **Admin inline callbacks (confirm, setexp, setgroup) now work**: the
  member callback handler was consuming all callbacks first.

## [0.4.1] - 2026-08-10

### Changed

- **Grid button labels never wrap**: every word in a button label is at most
  8 characters (Telegram folds longer words). Long commands are split into
  two short words (e.g. `set-holiday`, `clear-holiday`, `add-admin`,
  `re-pick`).

## [0.4.0] - 2026-08-10

### Changed

- **Command grid buttons show no leading slash** (e.g. `status` not
  `/status`); pressing a button still runs the command.
- **Grid buttons are color-coded by tier**: green = member commands, blue =
  admin, red = console. A member sees only green; an admin sees blue +
  green; the console sees all three.

## [0.3.2] - 2026-08-10

### Fixed

- **`/start` greeting failing with HTTP 400**: the help text used literal
  angle brackets (`<telegram_id>`, `<YYYY-MM-DD>`) inside an HTML-parsed
  message; Telegram rejected them as malformed tags and the whole reply
  (including the command grid) never sent. Placeholders now use square
  brackets.
- **Availability timestamps stored as UTC instead of UTC+8**: the member's
  pick was written with UTC wall-clock components labeled as local time.
- **Attendance recency ignored the debug clock**: `/setdate` now also drives
  the "attended in the past N days" prompt selection.
- **Week/cycle math pinned to UTC+8** (Singapore): all week and availability
  calculations consistently use the configured offset (default 8); tests
  cover the UTC→Singapore day boundary.

## [0.3.1] - 2026-08-10

### Fixed

- **Console auto-registers on first `/start`**: the console (configured via
  `CONSOLE_ID`) is registered as an admin member on first `/start`, so the
  console grid appears immediately instead of `/start` staying silent.

## [0.3.0] - 2026-08-10

### Added

- **Reply-keyboard command grids**: a persistent button grid above the
  message bar, one per role and strictly nested (member ⊂ admin ⊂ console).
  Each user sees the grid of their highest role; the grids never merge.
- **`/grid`** (console): cycle through the console/admin/member grids to
  preview what each role sees; `/help` returns to the console's own grid.
- **`/help`**: re-sends the user's command grid.

## [0.2.1] - 2026-08-10

### Fixed

- **Graceful shutdown on SIGTERM/SIGINT**: the bot now stops the update
  fetcher instead of hanging, so `systemctl restart` and `sdsc.sh update`
  complete cleanly instead of waiting out the systemd stop timeout.

## [0.2.0] - 2026-08-10

### Added

- **Console role**: the first user (configured via `CONSOLE_ID` in the secret
  env file) has admin rights + debug rights, but is not an admin per se and
  can step down from admin later.
- **Gated `/start`**: a user must first be added by an admin before `/start`
  responds. Until then the bot stays silent (no reply, no traffic). Once
  added, `/start` shows the user's own usable command list, filtered by role.
- **`/adduser @handle`** (admin): add a member by handle, persisted to the DB.
  No message-first requirement — a not-yet-seen handle is queued and the user
  is auto-registered the first time they contact the bot.
- **`/addadmin @handle`** (console): promote a user to admin (also queued and
  auto-promoted on first contact if not yet seen).
- **`/demote`** (console): the console can step down from admin; admins cannot
  remove each other.
- **Debug clock** (console): `/setdate YYYY-MM-DD [HH:MM]` temporarily
  overrides "now" to test prompt/reminder/allocation timing; `/resetdate`
  clears it.
- **Same-day message dedupe**: a given message kind is never sent to the same
  user twice in one local day (prompt, reminder, allocation).
- **Scheduler tick reduced** from 5 minutes to 12 hours.
- **CI/CD**: GitHub Actions lint/test/build on every push, and a release
  workflow that builds the bundle and publishes it as a GitHub Release when
  a `v*` tag is pushed. The VM pulls builds via `./sdsc.sh update`.

### Changed

- **Member messages rewritten** in plain, human-readable English (prompt,
  reminder, allocation, holiday variants, confirmations).
- **Console id** no longer hard-coded — read from `CONSOLE_ID` env (secret
  file, never in the repo); `ADMIN_IDS` env removed.
- **One-command deploy** via `deploy.sh` (build → bundle → copy to the
  production VM → extract + restart).
- **README slimmed** to a minimal description.

### Removed

- Public self-registration flow: members can only exist after an admin's
  `/adduser`.
- `ADMIN_IDS` environment variable (admin promotion is now `/addadmin`).
- Identifying information (handles, org names) from code, README, and git
  history.
