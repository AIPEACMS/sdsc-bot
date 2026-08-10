# Changelog

All notable user-facing changes to the SDSC bot.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/).

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
- **One-command deploy** via `deploy.sh` (build → bundle → SSH scp →
  extract + restart).
- **README slimmed** to a minimal description.

### Removed

- Public self-registration flow: members can only exist after an admin's
  `/adduser`.
- `ADMIN_IDS` environment variable (admin promotion is now `/addadmin`).
- Identifying information (handles, org names) from code, README, and git
  history.
