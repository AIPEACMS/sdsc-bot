# Changelog

All notable user-facing changes to the SDSC bot.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [1.2.0] - 2026-08-11

### Added

- **The admin API now has its own identity.** The bot generates an Ed25519
  keypair on first use (persisted in the DB) and signs every API response.
  `GET /api/server-info` exposes the public key and fingerprint so the console
  app can pin it on first connect after out-of-band verification. A fake
  backend can no longer pose as the bot even if it registers the console's
  public key — every response must be signed by the pinned server identity.

## [1.1.1] - 2026-08-11

### Fixed

- Admin API would not start on a fresh database with no console keys
  registered yet, so the very first key could never authenticate. The API now
  always listens; with no keys it rejects every request.

## [1.1.0] - 2026-08-11

### Changed

- **Console app authentication is now asymmetric.** The desktop console app
  generates an Ed25519 keypair on first run, the operator registers its public
  key with the console-only `/addkey` command, and every admin-API request is
  signed (timestamp + nonce + path + body hash). Registers with `/keys`,
  revokes with `/rmkey`.
- **The calendar-sync cron token never authorizes the admin API.** The two
  credentials are now fully separate — the loopback IPC token is scoped to
  the calendar sync only. The optional admin `ADMIN_API_TOKEN` remains as a
  manual bearer fallback.

## [Unreleased]

## [1.0.1] - 2026-08-11

### Fixed

- Admin API would not start without a dedicated admin token because the
  calendar-token fallback was never used. An unset token now correctly falls
  back and the API serves as intended.

## [1.0.0] - 2026-08-11

### Added

- **Admin HTTP API**: a token-authenticated HTTP server the new desktop
  console app talks to over the tailnet — list users, change a user's tier,
  set/reset the debug date, trigger a calendar sync, hold/unhold, and read
  recent logs. The token comes from the secret env file (`ADMIN_API_TOKEN`,
  falling back to the calendar IPC token); the port defaults to 8738.
- **In-memory log ring**: everything the bot logs is kept in a bounded
  buffer and served by `GET /api/logs`, so the console app can show
  copyable machine logs without touching journald.
- **`check` tier**: a non-member who only reports — their single button,
  `check-status`, prints this week's allocation (who is assigned to which
  session).
- **`old` tier**: archived former members — no buttons, no prompts, never
  allocated. Admin promotion is cleared when someone is moved to old.
- **Hold/unhold**: console-only buttons. `hold` suppresses every outgoing
  message (block & drop — nothing queues or replays) while the bot keeps
  running and the admin API stays reachable; `unhold` resumes. Persisted, so
  a restart keeps the bot held.

### Changed

- **Console buttons trimmed to hold/unhold.** Everything else the console
  used to do in Telegram (add-admin, set-date, reset-date, sync-calendar)
  now lives in the desktop console app. The commands still work when typed.
- **Admin grid drops `set-group`** — group changes move to the console app.
- **`check`/`old` users are excluded** from availability prompts, reminders,
  allocation, broadcasts, the `/ask` picker and the `/status` counts.
- `/users` now shows each member's tier.

## [0.9.0] - 2026-08-10

### Added

- **Availability timeline moved into the session week**: members are asked
  the same week the sessions happen — prompt Monday 08:00, reminder
  Thursday 18:00, deadline Friday 18:00, allocation Friday 19:00 sharp (the
  hour after the deadline). The confirmation message tells each member the
  exact allocation time (e.g. "Allocation runs at Fri 14 Aug at 7:00pm
  sharp") instead of leaving them guessing weeks ahead.
- **Sharp scheduling**: the scheduler arms a one-shot timer to the next
  milestone instead of relying only on the 12h tick, so prompts, reminders,
  deadline closure and allocation fire on their scheduled hour.
- **Smarter allocation**: experienced members are satisfied first, the
  "no OCBC 3 cycles in a row" rule is honoured, and each member is allocated
  at most one session per weekend so volunteers spread evenly across
  sessions.
- **Member status** (`/mystatus`): shows what the member indicated this
  cycle, what they are allocated to, and their attendance (total, plus
  OCBC/PR split).
- **`/adduser` wizard**: pressing the button asks for one handle, then
  shows a Confirm button before anything is added.
- **`/prompt` and `/remind` confirm first**: they show a confirmation
  dialog instead of messaging everyone immediately.
- **Holiday opt-out**: the holiday availability prompt carries a
  "Skip me this holiday" button; opting out (button or `/holiday`) stops
  further prompts and reminders for that holiday.

### Changed

- **Grid buttons**: attendance marking is now `mark-attend` (was
  `confirm`); the `allocate` and `announce` buttons are removed (allocation
  is automatic, and broadcast moves to a group chat); the member `holiday`
  button is gone — holiday prompts arrive automatically.
- **Allocation notice** no longer references a fixed Friday bail cut-off.

## [0.8.0] - 2026-08-10

### Added

- **Per-location availability picks**: the availability grid now lists each
  session with its location (e.g. `OCBC Sat AM`, `PR Sat PM`) as separate
  toggles, so members can say which location they can cover. Previously one
  toggle covered both locations of a slot. Existing slot-level picks are
  read as "both locations" (no data loss).

### Fixed

- **`/status` shows calendar context**: the sessions line now reads
  `sem1, week 5 & 6` (or `sem2`) when inside a semester, and
  `winter holiday` / `summer holiday` / `middle break` for breaks, instead
  of the raw ISO week. Prompt/reminder/deadline dates now include the
  weekday (e.g. `Mon 3 Aug`).
- **Prompt no longer chides new members**: the "we noticed you have not
  attended the past 2 weeks" variant is only used when the member joined
  more than 2 weeks ago AND the semester has been running for 2+ weeks.
  Fresh members and holiday-period cycles get the regular prompt.

## [0.7.1] - 2026-08-10

### Fixed

- **`/start` reply failing with HTTP 400 for the console**: the console
  section mentioned `/sync-calendar <yaml>`, and the literal angle brackets
  were parsed as an HTML tag, so Telegram rejected the whole reply (grid
  included) and nothing appeared on screen. The placeholder now uses square
  brackets (`[yaml]`), matching the older `<telegram_id>` fix.

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
