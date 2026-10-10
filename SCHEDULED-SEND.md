# Scheduled Sending

Write now in the normal Org, Markdown, or text composer; deliver at the start
of the **next configured workday**, or choose a particular date and time.
Source text, rendered content, mentions, recipient, and chat/channel reply
identity are retained in a private local outbox.

## Commands

| Command | Default binding | Action |
| --- | --- | --- |
| `teams4e-compose-schedule` | `C-c C-s` in a composer | Queue this draft for the next workday |
| `teams4e-compose-schedule-at` | `C-c C-t` in a composer | Queue for an explicit date/time |
| `teams4e-send-next-workday` | `M-x` / command palette | Open a new scheduled draft; `C-c C-c` queues it |
| `teams4e-reply-next-workday` | `M-x` / command palette | Reply with the same scheduling workflow |
| `teams4e-outbox` | `M-x` / command palette | Inspect queued messages and delivery results |
| `teams4e-outbox-edit` | `e` / `RET` in outbox | Hold delivery, then edit the original source |
| `teams4e-outbox-cancel` | `d` in outbox | Cancel a pending job; retain its record |

`C-u C-c C-s` also chooses an explicit date/time. Prefix either compose/reply
command to choose one before writing. The compose header and outbox show the
scheduled time, timezone abbreviation and UTC offset. These are ordinary,
customizable keymaps: `teams4e-compose-mode-map` and
`teams4e-outbox-view-mode-map`. `g` refreshes the outbox and `q` closes its pane.

The scheduling commands enqueue directly, without a second confirmation.
The dedicated compose/reply commands do **not** enqueue until `C-c C-c`.
For an ordinary unscheduled draft, `C-c C-c` still sends immediately.

## Workdays And Timezones

By default, sending uses `teams4e-calendar-work-days` and the existing snooze
setting `teams4e-workday-start` (`"07:00"`). NEXT always means a later calendar
date: Monday at 06:00 schedules Tuesday, not Monday at 07:00. A custom
Sunday-Thursday workweek is respected; no weekday pattern is hardcoded into
the calculation. Public holidays are not inferred.

```elisp
(with-eval-after-load 'teams4e
  ;; Optional overrides; nil inherits the settings described above.
  (setq teams4e-schedule-start-time "07:00"
        teams4e-schedule-work-days '(0 1 2 3 4) ; example: Sunday-Thursday
        teams4e-schedule-time-zone "Europe/London") ; use your IANA zone
  (teams4e-outbox-mode 1))
```

The timezone defaults to the backend machine's local timezone, including DST.
Set it explicitly when that machine is in a different zone from you.
Calculation uses civil dates, not 24-hour additions. If a next-workday start
falls in a DST gap, it advances to the first valid minute; a repeated hour uses
its earlier occurrence. Explicit ambiguous/nonexistent local times are rejected.
Disambiguate with an offset, for example `2026-11-01T01:30:00-05:00`.
Ordinary input is `YYYY-MM-DD HH:MM`; past times are rejected.

The resolved absolute instant is persisted. Changing timezone or workday
preferences afterward does not silently move existing jobs; edit/reschedule them.

## Delivery And Recovery

**This is a local scheduler, not Teams' native scheduled-message service.**
Queuing enables `teams4e-outbox-mode` in the current session. It checks every
30 seconds and delivers at most one due message per tick. Enable the mode in
your init, as above, to resume after restarting Emacs. If Emacs is closed,
the machine is asleep, offline mode is on, or authentication is unavailable,
delivery cannot happen at the scheduled time. No OS daemon or OpenClaw job is
installed. Disabling the mode stops future ticks, not an already claimed send.

`teams4e-outbox-late-grace` defaults to 900 seconds. Jobs missed by more than
that are **held**, not silently sent hours later. Use `e`, then `C-c C-s` or
`C-c C-t`, to reschedule. An expired original time cannot be requeued unchanged.

Editing atomically holds delivery before opening the source. Closing an edited
buffer does not resume delivery; only an explicit queue command does. Its source
edits are recoverable through the outbox or `teams4e-compose-drafts`. Revision
checks reject competing/stale editors. Queuing again while the first enqueue
response is uncertain cannot create another message with the same job ID;
inspect the outbox rather than composing a duplicate.

The queue binds delivery to the Graph account verified when enqueuing. Switching
accounts holds affected messages. Authentication failures before sending leave
them pending, subject to the late grace period. Existing token providers remain
responsible for authentication and refresh; no credentials are saved in the queue.

A durable SQLite claim prevents two workers from sending the same job. Known
HTTP 429 rejections honor `Retry-After`, with at most five attempts and the same
late-delivery limit. Other rejected requests are held for review. A timeout,
5xx, missing acknowledgement, or interrupted claimed send becomes **uncertain**:
it is never automatically retried. A crashed `sending` claim is classified as
uncertain after five minutes. Verify the chat in Teams before composing again.
There is no promise of exactly-once remote delivery: the documented API has no
message-send idempotency key. Cancellation/editing cannot revoke an in-flight,
sent, or uncertain request.

File attachments are deliberately rejected before enqueueing; their content
must not change between composition and delivery. Native quote attachments and
mentions are supported. Email-recipient drafts resolve an **existing** chat
before queuing; create the chat first if it does not yet exist.

## Storage And Installation

`teams4e-outbox-file` defaults to
`~/.local/share/teams4e/outbox.sqlite3` (or under `XDG_DATA_HOME`). It contains
confidential message source and rendered payloads, but no tokens. The file is
mode 0600; a newly created queue directory uses 0700. It is **not encrypted**, automatically
purged, or synchronized across machines. Keep it on one machine's local disk;
do not replicate an active queue. Retain it across package/cache updates.
Cancelled/sent records remain available locally.

Install the new Lisp module and the complete `bin/` runtime, including
`teams4e_outbox.py`; Python 3.10+ and timezone data are required. A custom backend
adapter must implement the new `teams outbox` commands before using these
features. Restart Emacs after updating, or reload `teams4e-ui.el`,
`teams4e-advanced.el`, and `teams4e-outbox.el`, then reopen compose buffers so
their copied minor-mode keymaps include the new keys. Do not reload while a
send or enqueue is in flight.

Mock mode uses a separate `.mock` queue file and the existing synthetic tenant.
It never reads live credentials or sends external messages. The Python tests
exercise time boundaries, custom workweeks, DST, durable restart, races,
cancellation, editing, throttling, uncertain outcomes, and mock delivery.

## API Findings

Checked 2026-10-10: Microsoft documents scheduling, editing, rescheduling and
deleting scheduled messages in the
[Teams client](https://support.microsoft.com/en-us/teams/chat/schedule-chat-messages-in-microsoft-teams).
The published [Graph chatMessage resource](https://learn.microsoft.com/en-us/graph/api/resources/chatmessage?view=graph-rest-1.0)
does not expose a scheduled-send property or scheduling method. This implementation
therefore defers the documented
[chat send](https://learn.microsoft.com/en-us/graph/api/chat-post-messages?view=graph-rest-1.0)
or [channel/reply send](https://learn.microsoft.com/en-us/graph/api/chatmessage-post?view=graph-rest-1.0)
operation locally. It does not invent an endpoint, repurpose `createdDateTime`,
scrape Teams' private APIs, or request additional account permissions.
Retry handling follows Microsoft's
[429 guidance](https://learn.microsoft.com/en-us/graph/throttling).
