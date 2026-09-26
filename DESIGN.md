# Design

## Architecture

`teams4e` is split at the authentication and process boundary:

1. Emacs owns views, selection, rendering, compose state, capture, and local
   triage state.
2. The Python adapter owns Microsoft Graph HTTP details, pagination, bounded
   concurrency, the SQLite cache, and the mock command protocol.
3. An external token provider owns OAuth, application registration, refresh
   tokens, and tenant-specific consent.

The Emacs process passes arguments as an argv list and parses one JSON document
from stdout. Message content and tokens are never interpolated into a shell
command.

This boundary is the package's deployment strategy, not only an implementation
detail. An existing approved MCP service, corporate broker, CLI, TUI, or
DavMail-like bridge can remain the sole OAuth owner. It may expose a fresh
delegated Graph token through an argv command, maintain a credential record
that the bundled adapter reads without writing, or implement the backend
contract itself so its token never leaves the service. An MCP connection alone
does not imply token export, and none of these patterns bypass tenant consent.

Custom adapters use process-per-command operation by default. Each invocation
receives the normal backend argv and emits one JSON document. A full drop-in
backend named `teams4e-graph` may implement the optional persistent transport:
the frontend starts it with `serve`, sends JSON-lines objects containing integer
`id` and string-array `args`, and expects correlated `result` or redacted
`error` responses. See [AUTHENTICATION.md](AUTHENTICATION.md).

## Data Ownership

Microsoft Graph is authoritative for chats, messages, server read state, and
calendar events. The package keeps three intentionally narrow local stores:

- `teams4e-cache-file`: a rebuildable SQLite reading/search cache.
- `teams4e-state-file`: favorites, muted/handled/snoozed triage, bookmarks, and
  other small UI state.
- `teams4e-draft-directory`: private recoverable compose drafts.

A chat is represented once in `teams4e--chats`. Optional participant and
meeting enrichment is merged into that alist. Filters and bookmarks select the
same objects; they do not maintain synchronized inbox copies.

Fresh cache or Graph chat rows are merged into the existing chat cons cell by
chat ID, preserving object identity for the singleton reader. A linked event
attachment may cross that replacement only while its short in-memory lifetime
has not expired and its event or join-link signature still matches. Explicit
refresh drops the attachment. This is object reuse, not another calendar cache.

## Modules

### `teams4e.el`

Package entry point. It loads configuration, the core UI, advanced workflows,
the meeting workspace, and optional Evil integration. It also defines
`M-x teams4e` as the primary inbox entry command.

### `msteams.el`

Pre-public-release compatibility entry point. It requires `teams4e` and aliases
the former Lisp namespace. New code does not depend on it, and Microsoft's
native `msteams://` URL protocol remains unchanged.

`bin/msteams-graph` is the matching executable shim. Before importing the new
backend it maps former `MSTEAMS_*` selectors to `TEAMS4E_*` only when the new
name is unset, so explicit current configuration always wins.

### `teams4e-config.el`

Defines the `teams4e` customization group and all public settings. It also
contains compatibility migrations for defaults that changed in live sessions.

### `teams4e-ui.el`

Implements the asynchronous process transport, headers buffer, singleton
reader, compose buffers, rendering, images, message mutation commands, and
basic capture/open commands.

Main entry points:

- `teams4e-inbox`: open or refresh the headers buffer.
- `teams4e-open-chat`: render a chat in the shared reader.
- `teams4e-send` and `teams4e-reply`: create native compose buffers.
- `teams4e--run-json`: issue one backend request and dispatch parsed JSON.
- `teams4e-performance-report`: display content-free timings and item counts
  retained in one bounded in-memory ring.
- `teams4e--executable`: honor the configured backend and recover only from a
  removed versioned package path after a live package upgrade.
- `teams4e--enrich-meetings`: attach linked event data to existing chat rows
  with one bounded backend request per explicit refresh.
- `teams4e--unread-p`: compare the real last-message timestamp with Graph's
  read marker; chat metadata timestamps are deliberately excluded.
- `teams4e--apply-pending-send-read-state`: transfer the pre-send read state to
  the next outgoing last-message marker without creating persistent state.

### `teams4e-advanced.el`

Implements bookmarks and query evaluation, deferred/bulk actions, cache sync,
offline search, channel views, full-thread Markdown, Org capture, attachment
workflows, proposal primitives, and optional agent analysis.

Main entry points:

- `teams4e-bookmark-jump`: apply a configured view/query.
- `teams4e-toggle-unread-filter`: reversibly toggle the independent unread
  overlay used directly by `F` (with `U`, `b u`, and `M-F` retained as aliases)
  without replacing the active bookmark/query; All Chats clears it.
- `teams4e-snooze-quick` / `teams4e-snooze`: apply the terminal-compatible
  default or key-selected wake time using the existing persisted timestamp.
- `teams4e--query-chat-p`: resolve known built-in view symbols before callable
  predicates, then evaluate custom functions or textual query clauses. Active
  snoozes are excluded unless a clause explicitly requests `snoozed`.
- `teams4e-execute-marks`: apply deferred row actions serially.
- `teams4e-bulk-action`: apply one operation to selected conversations.
- `teams4e-sync`: refresh the local SQLite cache.
- `teams4e-channels`: choose a team and channel.
- `teams4e-export-current-thread`: fetch and write complete Markdown.
- `teams4e-capture-current-summary`: capture compact conversation metadata.
- `teams4e-analyze-current-thread`: export then start an `agent-shell` session.
- `teams4e-meeting-propose-new-time`: rank or manually select an alternate
  meeting interval through the meeting workspace, with a legacy minibuffer
  fallback when that module is not loaded.

Chat export and agent analysis use a separate full-history backend command,
not the bounded reader or SQLite cache. `export_message_history` follows Graph
until no `@odata.nextLink` remains and returns the same message objects with a
small completion envelope: page count, message count, and oldest/newest
timestamps. Emacs validates that envelope before writing the mode-0600 file or
starting an agent. The Markdown header records that evidence; no second message
cache or transcript representation is created. The initial agent prompt comes
from `teams4e-thread-analysis-prompt`, with the export path substituted for `%s`.
Its default is ordinary analysis instructions, with no personal skill dependency.

Activity bookmarks are textual projections over the canonical chat list.
`today` compares the last message's local calendar-day key, while `after:1d` and
`after:7d` remain rolling elapsed-time windows. Sending records one in-memory
pre-send read state; normalization consumes it only when a new outgoing
last-message marker appears.

Transcript day grouping and display both derive from the local Emacs timezone;
the previous raw-UTC day split could disagree with local message times around
midnight. `teams4e--local-day-key`, `teams4e--day-heading`, and
`teams4e--message-time-label` feed both the reader and Markdown renderer.
Reader day rules provide the primary temporal separation, with compact
sender/time headers and a consistent body inset. Export headings retain an ISO
day key alongside the readable local day name.

Calendar errors stay attached to `meetingContext.eventError`, but the visible
label classifies the useful recovery: missing local credentials request login,
Graph access failures identify calendar permission, missing event IDs say the
chat has no linked event, and unknown failures point to `*M365 Errors*`. The
diagnostic retains a bounded, redacted backend detail.

`teams4e--run-json` times each backend operation under a fixed content-free
label. Inbox and transcript rendering record separate Emacs events. The bounded
event ring
contains only operation, transport, status, item count, duration, and local
time; it never records argv values, IDs, URLs, people, titles, bodies, or
tokens. `teams4e-performance-report` renders this ring without persisting it.

Cache-first opening paints cached rows once before Graph starts. Member and
calendar completion callbacks mutate their established caches/attachments and
request a shared short timer; adjacent completions therefore produce one
tabulated-list redraw. Direct user actions still redraw immediately.

### `teams4e-meetings.el`

Implements the calendar-light meeting experience on the canonical chat/event
object. It owns overlap detection, the singleton full-window availability
buffer, Suggestions and Calendar blocks projections, RSVP, join, and linked
calendar actions. It stores no calendar rows or proposals after rendering.

Main entry points:

- `teams4e-meetings`: open upcoming and active meeting chats in event order.
- `teams4e-meeting-availability`: fetch and open the participant matrix and
  block sheet for the meeting at point.
- `teams4e-meeting-respond`: accept, tentatively accept, or decline once.
- `teams4e-meeting-join`: open the event's join URL.
- `teams4e-meeting-open-calendar`: hand advanced editing to Outlook.

### `teams4e-evil.el`

Adds normal/motion bindings after Evil loads. It mirrors the ordinary major
mode maps through the runtime-safe `evil-define-key*` function; business logic
does not depend on Evil or Spacemacs. `teams4e-evil-refresh-bookmark-bindings`
reasserts the `b`/`B` prefix when a headers or reader mode starts and when the
inbox opens, repairing maps changed by a later Evil Collection reload.

### `teams4e-companion.el`

Optional ongoing Agent Shell briefing. The module is loaded only on invocation.
It reads the canonical chat list, fetches bounded recent messages only for
changed conversations, and keeps delivery fingerprints rather than inferred
obligation state. One timer drives polling and idle-safe delivery. Generation
checks discard callbacks after cancellation; account/provider changes pause
the session. Failed message reads are not acknowledged as successful evidence.

One pending snapshot waits for an idle shell with an empty comint prompt. Each
session owns a private latest-context file, so starting a new conversation does
not overwrite evidence still accessible to the previous agent. User-selected
reference files and optional linked meeting events contribute to the same
snapshot. There is no task ledger or second inbox model.

Integration uses `agent-shell-start`, `agent-shell-insert`, Shell Maker's busy
check, and the comint process mark. The upstream implementations are documented
in [Agent Shell](https://github.com/xenodium/agent-shell/blob/main/agent-shell.el)
and [Shell Maker](https://github.com/xenodium/shell-maker/blob/main/shell-maker.el).

### `bin/teams4e_graph.py`

Implements the command dispatcher, credential-provider boundary, Graph
requests, retries, pagination, chat/channel operations, linked event lookup,
file transfer, and persistent JSON-lines server.

Main functions:

- `graph_request`: issue a Graph request and enforce Graph-host token scoping.
- `get_token`: obtain a short-lived token from the configured provider.
- `list_chats` and `list_chat_messages`: fetch bounded conversation data.
- `meeting_event_record`: resolve one linked event, including a chat-metadata
  fallback when the list response omitted its event ID.
- `list_meeting_events_batch`: fetch linked events with bounded concurrency.
- `get_meeting_time_suggestions`: ask Outlook to rank alternate intervals while
  preserving the linked event's duration.
- `get_meeting_availability`: combine ranked suggestions with `getSchedule`
  free/busy records while allowing either side to fail softly.
- `get_meeting_schedules`: batch at most 20 participant addresses per request,
  preserve participant order, and retain per-address errors.
- `respond_to_meeting`: send one accept, tentative, or decline action.
- `propose_new_meeting_time`: send one tentative response containing the chosen
  alternate interval.
- `dispatch`: map the CLI-compatible argv protocol to one operation.

### `bin/teams4e_cache.py`

Owns the private SQLite schema and cache reads, writes, synchronization
watermarks, and full-text search.

### `bin/teams4e_mock.py`

Implements the same command contract against a persistent fake tenant. Tests
can exercise destructive and asynchronous workflows without Graph access.
`TEAMS4E_MOCK_DELAY_MS`, exposed as `teams4e-mock-delay-ms`, adds a bounded
delay to each non-cache request so cache-first and concurrency behavior can be
tested locally under controlled latency.

## Chat Loading

An opened thread requests the newest 100 messages without a date cutoff;
automatic previews retain a 50-message bound. Without a modified-date filter,
the adapter uses `createdDateTime desc`, matching the terminal client.
Explicit modified-date windows and background sync still pair their filter
with `lastModifiedDateTime desc`, as required by Graph.

The SQLite snapshot and live request run independently. The live request owns
the reader's cancellation handle. Cache callbacks verify the request generation,
chat identity, and absence of a completed live response before rendering.
They cannot overwrite a newer response or start another network fetch on error.
This uses the existing message list and SQLite store, not another chat cache.

Explicit reopen selects the latest end immediately, then refreshes. Subsequent
responses retain navigation into older messages and explicit message-link
targets. Backend request and transcript rendering timings are available through
`M-x teams4e-performance-report`; offline tests verify ordering, not tenant
latency.

## Graph Request Budget

Graph JSON/text reads in one backend process share a locked rolling budget:
40 operations per 10 seconds, with each JSON batch item counted separately.
Requests wait outside the lock. A 429 extends a shared cooldown even on the
final failed attempt; workers cannot shorten an existing cooldown. Numeric
and HTTP-date Retry-After values are honored without clipping. Missing or
invalid headers use a 10-second exponential fallback, bounded at 60 seconds.

Batch envelopes can succeed while individual items are throttled. The batch
helper retains successes and permanent errors, retries only 429 items up to
the existing attempt limit, and uses the longest returned Retry-After.
No new persisted state or conversation cache is introduced. Separate backend
processes and other applications do not share this budget, so it mitigates
rather than guarantees avoidance of tenant-wide throttling.
See [Microsoft's throttling guidance](https://learn.microsoft.com/en-us/graph/throttling).

Blank acceptance notes map to `sendResponse: false` on the Graph accept
action; the calendar acceptance itself is still performed. Nonempty notes,
tentative responses, declines, and proposed times keep their previous behavior.
See [the accept API](https://learn.microsoft.com/en-us/graph/api/event-accept?view=graph-rest-1.0).

## Meeting Metadata

Upcoming views now take a calendar-first path: one paginated `calendarView`
lookup from now through `teams4e-meeting-upcoming-days` (14 by default, capped
at 60). Match the returned events to the loaded chat thread keys or known
event/series IDs in memory. CalendarView already expands recurrence, so this
path makes no per-chat metadata requests, series-instance requests, or
historical fallback scans. Keep the nearest active/future non-declined,
non-cancelled occurrence. A late page failure preserves received events and
marks the result incomplete through the existing eventError field.

Successful unmatched rows carry their lookup horizon in the canonical
meetingContext, not an error or a separate cache. The ordinary context TTL
prevents repeated scans on bookmark switches; changing the horizon or pressing
g permits another lookup. The view remains chat-backed: a calendar event
without a loaded Teams chat is not synthesized into a new conversation.

This addresses a MailboxConcurrency report where six legacy workers plus
parallel calendar chunks could exceed Outlook's four-request mailbox limit.
All Outlook JSON envelopes now share one process-wide transport lock. Outlook
JSON batches hold at most two items, reserving some headroom for other clients;
Teams chat batches still hold up to 20. The lock is released on HTTP errors and
exceptions; queued workers recheck the shared rate budget at dispatch.
Other processes are outside this guard.

The broader lookup below remains for explicit all-meeting views and individual
chat inspection.

Graph chat data may include `onlineMeetingInfo.calendarEventId`. The adapter
fetches those events with a narrow field selection in Outlook JSON batches of
at most two requests. If a list row omits the ID, or its ID returns 404, an explicit
meeting view fetches `/chats/{id}` through the same bounded JSON batch helper.
Workers may prepare requests concurrently, but Outlook transport is serialized.
Any rows still unresolved by direct IDs contribute their join URLs to one bounded
`calendarView` scan for that backend request. Emacs merges the result into
`meetingContext.event`. Ordinary inbox refreshes defer calendar enrichment.
An explicit meeting view continues through the remaining loaded candidates in
batches of `teams4e-meeting-enrichment-limit`, stopping when the user leaves the
meeting view. Each pass removes its attempted rows before continuing, so a
retriable error cannot loop within that pass. The fallback prioritizes recent
message-less meeting rows before message-bearing meeting history.

Recurring event IDs may identify a series master or an old occurrence.
The adapter resolves either through
[`/me/events/{seriesMasterId}/instances`](https://learn.microsoft.com/en-us/graph/api/event-list-instances?view=graph-rest-1.0),
following pagination and choosing the current or nearest future occurrence
within 60 days. Rescheduled exceptions participate; cancelled and declined
occurrences do not. Each series is resolved once per backend batch. Single
events need no instances request. An explicit null event clears a previous
occurrence when the lookup returns no upcoming instance or fails.

Join-URL fallback searches chronological seven-day windows in parallel.
All pages of a future window are read, and all responses in a parallel batch
are compared before retiring a matched URL. Previously, the first responding
window could win with a later occurrence, and a page budget reserved in advance
could truncate the advertised 45-day range even when windows were empty.
Historical fallback remains page-capped. The future scan is date-bounded,
not page-capped, so dense calendars can require more requests.

Coverage is still limited to the loaded chat metadata set (300 by default).
This is not calendar-first discovery: invitations without a loaded Teams chat
will not appear. Raising `teams4e-chat-metadata-limit` and explicitly refreshing
can cover older chats, at additional request cost. Regression tests use mock
Graph responses; tenant-specific access and calendar coverage require live
validation.

`teams4e--apply-meeting-context` stamps a private in-memory fetch time. During
a subsequent chat-list normalization, a still-fresh context with matching
event or join-link signature is carried onto the same reused chat cons cell.
Expiry, changed linkage, or `teams4e-recent-refresh` removes it, after which the
normal bounded enrichment path remains authoritative.

The meeting-only fixed When, Conversation, Response, and Location columns,
meeting predicates/sort, and reader banner all read this same attachment. The
headers buffer fixes its paragraph direction to left-to-right so bidirectional
cell content cannot reorder table columns. Message-oriented views use the compact headers
schema without a meeting column and sort descending by `lastMessagePreview`
time, so calendar-only changes neither consume inbox width, reorder the inbox,
nor change unread state. A message-bearing row requires both the preview id and
timestamp. Meeting chats without that complete preview are suppressed, which
prevents calendar-created chat stubs from becoming undated unread rows.
Meeting-only views retain those same canonical chats, switch the schema and row
projection together, sort ascending by event start, and display the complete
start/end interval. Rows with no known start follow rows with calendar data.

A calendar permission failure is soft: the conversation and participants
remain available, `meetingContext.eventError` is attached to the same canonical
chat, the failure count appears in meeting headers, and diagnostics go to
`*M365 Errors*`. A missing shared OAuth identity is shown directly in the inbox
header with the `teams4e-login` recovery command.

The meeting view detects overlaps only among currently enriched active event
attachments. It excludes cancelled, declined, duplicate-event, and
boundary-touching rows. This gives the headers a cheap conflict warning and a
next/conflict/response summary without polling another calendar collection.

The `a p` action opens one `*Teams Availability*` buffer for that same attached
event. The backend calls `/me/findMeetingTimes` for ranked, duration-preserving
alternatives and `/me/calendar/getSchedule` for participant free/busy,
working hours, and shareable blocks. `getSchedule` requests are chunked at 20
addresses and bounded to three workers. The UI renders two projections of the
one response: a participant matrix with selected-slot conflict detail, and a
chronological block sheet. Missing schedule permission does not erase ranked
suggestions; missing suggestion permission does not erase blocks. Subject and
location are suppressed for blocks Graph marks private.

The workspace can retry with work, personal, or unrestricted hours, choose
another range, or build a manual slot. The chosen slot is sent with
`/me/events/{id}/tentativelyAccept`, `sendResponse=true`, and an editable
comment. `a v` similarly maps accept, tentative, and decline to their Graph
event actions. Mutations are deliberately one-shot rather than
persistent-server traffic, and diagnostic logging redacts comments.

Successful proposal state is merged into `meetingContext.proposal` on the
existing chat. The reader banner and meeting status can therefore react
immediately without a proposal database or second calendar object. On later
event reads, the same display derives the pending interval from the signed-in
attendee's `proposedNewTime`, so refresh and restart do not require local
persistence. The linked event's original start/end remain authoritative for
meeting sorting until the organizer changes the event. Sending requires
delegated `Calendars.ReadWrite`; organizer-owned, cancelled, and
proposal-disabled events are rejected before the mutation.

Availability reading depends on tenant sharing and delegated calendar scopes.
Free/busy may be available while another participant's subject/location is
withheld. Organizer rescheduling, event creation, recurrence editing, and
cancellation stay outside the package and open the linked Outlook event. This
keeps Graph authoritative and avoids a second calendar synchronization model.

## Documentation Assets

`assets/logo.png` is a minimal chat-outline and block-cursor package mark.
`assets/demo.gif` consists of actual graphical Emacs captures of the headers,
singleton reader, Org reply split, and meeting details. Moe Dark and Iosevka
are loaded normally; conversation data comes from the bundled mock backend.
There is no HTML reconstruction or screenshot restyling.

`tools/capture-demo.el` exercises those UI states and exports the frames with
`x-export-frames`. The capture workflow pins the theme, font, and optional
Agent Shell Markdown renderer, then assembles the PNGs into a GIF.
`tools/teams4e-demo.el` launches an interactive version with the same synthetic
tenant and fresh temporary state, without attaching to a user's Emacs server.
See [capture instructions](tools/README.md) and `assets/capture.json` for
reproduction details and image provenance.

## Reader And Navigation

There is one buffer named by `teams4e--read-buffer-name`. Opening another chat
or channel replaces its contents. The linked headers buffer remains the owner
of conversation selection, marks, filters, and bookmarks. Reader bindings such
as `j`, `k`, `r`, `i`, and `b` delegate back to that owner, while `M-j` and
`M-k` navigate messages inside the transcript.

## Refile State

Refile is implemented as a handled marker paired with the chat's current
last-message marker. It is local and undoable. When the marker changes, the
handled state expires, so no duplicate folder or server-side representation is
required. The function remains available to callers, but the main keymaps bind
lowercase `r` to mark-read.
