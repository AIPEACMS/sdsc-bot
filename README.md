# SDSC Bot

Telegram bot for SDSC volunteer scheduling. Every 2 weeks it asks members for
their availability for the next 2 weekends, then allocates experienced members
to OCBC and new members to Pasir Ris — without giving anyone OCBC 3 cycles in a
row.

Built in pure Dart: `televerse` (Telegram Bot API), `sqlite3` (storage),
long-polling, no webhook required. Runs on a production VM as a
self-contained AOT bundle (no Docker, no Dart SDK on the VM).

## How a cycle works

A cycle is the 2-week block whose first session weekend is an **odd ISO week**
(`blockWeek`). Weeks are grouped odd+even:

| When | What happens |
|------|--------------|
| Mon of `blockWeek-1` | Prompt: **msg1** (or **msg1A** if the member did not attend in the past 14 days, or holiday variant **msg5A/5B**) with an availability picker |
| Thu of `blockWeek-1` | Reminder **msg2** to members who have not responded |
| Fri of `blockWeek-1` | Availability deadline (cycle closes) |
| Wed of `blockWeek` | Allocation runs; **msg4** sent to each allocated member (bail by Fri 12:00pm) |
| Sat/Sun of `blockWeek` and `blockWeek+1` | Sessions |

Members toggle Sat/Sun × AM/PM slots for each of the 2 weekends. **msg3**
confirms their pick; `/reindicate` reopens it. `/holiday` opts out of a break
(**msg5Z**).

`attend` is a separate concept: the admin marks a member as attended via
`/confirm` — it is **not** the same as indicating availability or being
allocated.

## Configuration (environment variables)

| Variable | Default | Purpose |
|----------|---------|---------|
| `TELEGRAM_TOKEN` | *(required)* | Bot token from @BotFather |
| `ADMIN_IDS` | empty | Comma-separated Telegram user ids granted admin commands |
| `SDSC_DB` | `sdsc.db` | SQLite file path (mount a volume) |
| `GROUP_A_CONTACT` | `TBD` | Contact for group A |
| `GROUP_B_CONTACT` | `TBD @tbd` | Contact for group B |
| `OCBC_CAPACITY` | `6` | Per-slot OCBC capacity |
| `PR_CAPACITY` | `20` | Per-slot Pasir Ris capacity (soft — overflow still allocated) |
| `SLOT_AM_START` / `SLOT_AM_END` | `09:00` / `12:00` | AM slot window |
| `SLOT_PM_START` / `SLOT_PM_END` | `13:00` / `17:00` | PM slot window |
| `PROMPT_HOUR` / `REMINDER_HOUR` / `DEADLINE_HOUR` / `ALLOCATION_HOUR` | `8` / `18` / `18` / `9` | Firing hours (local) |
| `TZ_OFFSET` | `8` | Hours from UTC (Singapore) |

## Run locally

```sh
export TELEGRAM_TOKEN=... ADMIN_IDS=...  # ADMIN_IDS optional
dart pub get
dart run bin/main.dart
```

## Deploy

Deployment is a single self-contained AOT bundle on a production VM — no
Docker, no Dart SDK on the VM. See `AGENTS.md` at the repo root for the full
redeploy flow (build with `dart build cli`, tar, scp, restart systemd service).

The scheduler is a periodic timer inside the process; on restart it catches up
any due prompts/reminders/allocations automatically.

## Member commands

| Command | Purpose |
|---------|---------|
| `/start` | Register (name → experience → group) or view status |
| `/reindicate` | Update availability for the current cycle |
| `/holiday` | Opt out of a winter/summer break |

## Admin commands

| Command | Purpose |
|---------|---------|
| `/status` | Cycle state, responders, allocations |
| `/users` | Registered members with id / experience / group / streak |
| `/prompt` | Send availability prompts now |
| `/remind` | Send reminders to non-responders now |
| `/ask <telegram_id>` | Prompt a single member |
| `/allocate` | Run allocation and send msg4 now |
| `/confirm` | Mark members as attended (button flow) |
| `/setexp <experienced\|newbie>` | Change a member's experience (button flow) |
| `/setgroup <A\|B>` | Change a member's group (button flow) |
| `/holidayset <middle\|winter\|summer> <YYYY-MM-DD>` | Mark a week as a break |
| `/holidayclear <YYYY-MM-DD>` | Remove a break |
| `/broadcast <message>` | Send a message to every member |

## Development

```sh
dart test      # unit + integration tests
dart analyze   # static analysis
```
