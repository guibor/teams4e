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
  overlay used by `U`, `b u`, and `M-F` without replacing the active
  bookmark/query; All Chats clears it.
- `teams4e--query-chat-p`: resolve known built-in view symbols before callable
  predicates, then evaluate custom functions or textual query clauses.
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
cache or transcript representation is created.

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

## Meeting Metadata

Graph chat data may include `onlineMeetingInfo.calendarEventId`. The adapter
fetches those events with a narrow field selection in Graph JSON batches of at
most 20 requests. If a list row omits the ID, or its ID returns 404, an explicit
meeting view fetches `/chats/{id}` through the same bounded JSON batch helper.
Batch containers may run concurrently up to the configured enrichment bound.
Any rows still unresolved by direct IDs contribute their join URLs to one bounded
`calendarView` scan for that backend request. Emacs merges the result into
`meetingContext.event`. One Emacs refresh sends one enrichment request; a
retriable row is reconsidered only after the user explicitly refreshes again.
The fallback prioritizes recent message-less meeting rows before
message-bearing meeting history so its fixed bound remains useful for
calendar-created future meetings.

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
`assets/demo.gif` illustrates the headers, singleton reader, and meeting
projection with non-account data and the installed Moe Dark palette.
`tools/teams4e-demo.el` launches the real UI against the bundled mock and
prefers `moe-dark`, with `wombat` as a dependency-free fallback.
`tools/readme-demo.html` is the fixed-format Moe Dark source used to render the
compact README animation.

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
