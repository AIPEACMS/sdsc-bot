# Changelog

All notable user-facing changes to the SDSC bot.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [1.8.1] - 2026-08-16

### Fixed

- **The re-pick picker stays anchored to its bundle.** Toggling a slot no
  longer re-anchors the keyboard to the clicked weekend, which had shifted
  the weekend headers (and the check marks) one week into the future.
- **The picker's date header rows are inert.** Tapping a "Sat 15 Aug"
  header is answered instantly instead of leaving a pending spinner.

## [1.8.0] - 2026-08-16

### Fixed

- **Mark attendance (`/confirm`) now lists only the current week's four
  Saturday sessions** (Sat AM/PM × OCBC/PR) instead of every session of the
  rolling window. Each button carries a status mark scoped to the admin's own
  group: blue when some of the group's members are still unmarked, green when
  all are marked, and no icon when nobody from the group is allocated. The
  member list inside a session shows only the admin's own group.
- **Mark attendance rolls over at Saturday 00:00.** Until then the previous
  Saturday's sessions can always still be marked; the header names which
  weekend is being marked.
- **Re-picking and pressing Done with nothing selected** is now treated the
  same as "Not available" instead of confirming "(none)".
- **Messages now name the group leader.** The "Questions? Message …" line in
  prompts and the allocation notice use the member's group admin instead of
  the configured contact placeholder (which read "TBD" when unset).

### Changed

- **There are no Sunday sessions.** Sessions, availability and allocation are
  Saturday-only; the availability picker labels each weekend by its date
  ("Sat 15 Aug", no arbitrary week numbers) so it is clear which week a slot
  belongs to. Stale Sunday rows from earlier versions are ignored.

## [1.7.0] - 2026-08-12

### Added

- **Rolling availability windows.** Availability is now per-weekend with a
  weekly sliding bundle (current + next weekend) instead of a fixed 2-week
  cycle with a single deadline. Each weekend locks on its own Friday 18:00
  and is allocated right after; the picker always shows the current and
  next weekend and never closes mid-week.
- **2-week quiet rule.** Members who answer a bundle (available or not
  available) are not prompted again for the next 2 weeks. Non-responders
  are re-prompted the following week for the rolled bundle.
- **3-state attendance** — present, not-participated, or unmarked — with a
  recoverable tap-cycle. A "not participated" mark dismisses the unmarked
  reminders for that member.
- **Attendance-marking reminders.** Each Sunday the bot reminds every
  group's admin about members with no attendance mark, again on Monday, and
  surfaces it in the console log so the operator can chase slow admins.
- **Sessions, availability, allocations and attendance are keyed by
  weekend** instead of by 2-week cycle; existing databases migrate
  automatically on startup.

### Changed

- **`/start`, `/status`, `/mystatus` and the picker speak in bundles and
  per-weekend lock times** instead of cycle milestones.

## [1.6.0] - 2026-08-12

### Added

- **Groups are now numeric (1, 2, …) and led by admins.** The legacy letter
  groups are migrated automatically (A→1, B→2). Every admin leads their own
  group: promoting a member to admin hands them the lowest free group number
  (so a disbanded group is reclaimed, never skipped) and they leave their
  previous group.
- **Demoting an admin dissolves their group** — all its members, including
  the demoted admin, become group-less until reassigned.
- **Auto-assign groups** (`POST /api/assign-groups`): randomly and evenly
  distributes members without a group across the admins' groups. Checkers
  and former members are never assigned; admins are never assigned.
- **Manual group change** (`POST /api/users/{id}/group`): move a member to
  another admin-led group, or remove them from their group. Blocked for
  admins — they own their group until demoted.
- **New members start with no group** and are assigned later, automatically
  or manually.

## [1.5.1] - 2026-08-12

### Fixed

- **A console who steps down as admin now shows as `console | member`**
  instead of just `console` — the member group is reported explicitly for a
  plain member (including the console), and stays hidden only while admin is
  present (admin implies member).
- **The attendance endpoint also reports each session's `day` and `slot`**
  so the console can pair the Pasir Ris and OCBC sessions of the same slot
  into a timetable.

## [1.5.0] - 2026-08-12

### Added

- **The console user can demote themselves.** The tier API no longer blocks
  the console id, so the operator can retire as a member (tier `old`, admin
  cleared) while staying the console: no weekly prompts, no allocation, and
  the user shows as `console | old`. Promoting back is a tier change away.
- **The attendance endpoint reports each session's location and weekend**
  (`location`, `weekendIndex`), so the console can split the sheet into
  Pasir Ris / OCBC and cluster it by week.

### Changed

- **`/start` for a retired console** (tier `old`) lists only the console
  commands plus a note that they will not be prompted or allocated — the
  admin and member command lists are hidden until they re-promote.

## [1.4.0] - 2026-08-12

### Added

- **Admin API now drives the whole cycle**, so the desktop console's new
  Tools screen can run the operations the admin commands could:
  `POST /api/prompt`, `/api/remind`, `/api/allocate` run the cycle op now;
  `POST /api/ask` sends the availability picker to one member;
  `POST /api/broadcast` sends a message to every member;
  `GET`/`POST /api/attendance` list sessions with allocated members and
  toggle each member's attendance.
- **User management via the API**: `POST /api/users` adds a member by
  @handle (registered now or queued for first contact),
  `POST /api/users/{id}/admin` grants or strips the admin flag without
  touching the member tier, `POST /api/users/{id}/exp` sets experience.
- **`/api/users` now reports every group** a user belongs to (`groups`),
  most significant first — the console user is reported as
  `console | admin` instead of a single collapsed tier.

### Changed

- **`/reindicate` is now `/repick`** — the command and every mention were
  renamed to match the grid button.
- **`/holiday` command removed** — holiday opt-out now happens via the
  "Skip me this holiday" button on the prompt.
- **`/start` message cleaned up**: the member section matches the grid
  (`/repick`, `/mystatus`), and no removed commands are advertised.

## [1.3.1] - 2026-08-11

### Fixed

- **Typed slash commands were being swallowed.** The message bookkeeping
  middleware short-circuited the chain for any command, so commands typed
  directly (`/addkey`, and any admin/console slash command) never reached
  their handlers. Grid buttons were unaffected (they send plain text). The
  middleware now always continues the chain, so typed commands work again.

## [1.3.0] - 2026-08-11

### Added

- **Every incoming message is now logged.** The bot records each message it
  receives (sender + text, truncated) into the log ring and journal, so the
  console's Logs tab shows what actually arrived — no more invisible command
  attempts.
- **Time-based log retention.** The log ring keeps lines for a configurable
  window (default 14 days) and prunes older ones, instead of an opaque line
  cap. The window is set from the console via `POST /api/log-retention` and
  persisted across restarts; `GET /api/state` reports the current value.

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
