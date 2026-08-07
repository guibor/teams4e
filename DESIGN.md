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

## Modules

### `teams4e.el`

Package entry point. It loads configuration, the core UI, advanced workflows,
and optional Evil integration. It also defines `M-x teams4e` as the primary
inbox entry command.

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
- `teams4e--enrich-meetings`: attach linked event data to existing chat rows.

### `teams4e-advanced.el`

Implements bookmarks and query evaluation, deferred/bulk actions, cache sync,
offline search, channel views, full-thread Markdown, Org capture, attachment
workflows, availability-ranked meeting proposals, and optional agent analysis.

Main entry points:

- `teams4e-bookmark-jump`: apply a configured view/query.
- `teams4e-execute-marks`: apply deferred row actions serially.
- `teams4e-bulk-action`: apply one operation to selected conversations.
- `teams4e-sync`: refresh the local SQLite cache.
- `teams4e-channels`: choose a team and channel.
- `teams4e-export-current-thread`: fetch and write complete Markdown.
- `teams4e-capture-current-summary`: capture compact conversation metadata.
- `teams4e-analyze-current-thread`: export then start an `agent-shell` session.
- `teams4e-meeting-propose-new-time`: rank or manually select an alternate
  meeting interval and send it to the organizer.

### `teams4e-evil.el`

Adds normal/motion bindings after Evil loads. It mirrors the ordinary major
mode maps; business logic does not depend on Evil or Spacemacs.

### `bin/teams4e_graph.py`

Implements the command dispatcher, credential-provider boundary, Graph
requests, retries, pagination, chat/channel operations, linked event lookup,
file transfer, and persistent JSON-lines server.

Main functions:

- `graph_request`: issue a Graph request and enforce Graph-host token scoping.
- `get_token`: obtain a short-lived token from the configured provider.
- `list_chats` and `list_chat_messages`: fetch bounded conversation data.
- `list_meeting_events_batch`: fetch linked events with bounded concurrency.
- `get_meeting_time_suggestions`: ask Outlook to rank alternate intervals while
  preserving the linked event's duration.
- `propose_new_meeting_time`: send one tentative response containing the chosen
  alternate interval.
- `dispatch`: map the CLI-compatible argv protocol to one operation.

### `bin/teams4e_cache.py`

Owns the private SQLite schema and cache reads, writes, synchronization
watermarks, and full-text search.

### `bin/teams4e_mock.py`

Implements the same command contract against a persistent fake tenant. Tests
can exercise destructive and asynchronous workflows without Graph access.

## Meeting Metadata

Graph chat data may include `onlineMeetingInfo.calendarEventId`. The adapter
fetches `/me/events/{id}` with a narrow field selection and returns the event
beside the chat id. Emacs merges the result into `meetingContext.event`.

The meeting-only schedule column, meeting predicates/sort, and reader banner
all read this same attachment. Message-oriented views use the compact headers
schema without a meeting column and sort descending by `lastMessagePreview`
time, so calendar-only changes neither consume inbox width nor reorder the
inbox. Meeting-only views switch the schema and row projection together, sort
ascending by event start, and display the complete start/end interval. Rows
with no known start follow rows with calendar data.

A calendar permission failure is soft: the conversation and participants
remain available and the event is omitted.

The `a p` action operates on that same attached event. It calls
`/me/findMeetingTimes` to rank alternatives inside a configurable window and
shows local intervals, confidence, and unavailable attendees. The chooser can
retry with unrestricted hours, choose another range, or build a manual slot.
An availability permission failure is also soft: the manual path remains
available. The chosen slot is sent with
`/me/events/{id}/tentativelyAccept`, `sendResponse=true`, and an editable
comment. This mutation is deliberately one-shot rather than persistent-server
traffic, and diagnostic logging redacts the comment.

Successful proposal state is merged into `meetingContext.proposal` on the
existing chat. The reader banner and meeting status can therefore react
immediately without a proposal database or second calendar object. The linked
event's original start/end remain authoritative for meeting sorting until the
organizer changes the event. Sending requires delegated `Calendars.ReadWrite`;
organizer-owned, cancelled, and proposal-disabled events are rejected before
the mutation.

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
