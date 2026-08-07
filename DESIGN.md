# Design

## Architecture

`msteams.el` is split at the authentication and process boundary:

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

- `msteams-cache-file`: a rebuildable SQLite reading/search cache.
- `msteams-state-file`: favorites, muted/handled/snoozed triage, bookmarks, and
  other small UI state.
- `msteams-draft-directory`: private recoverable compose drafts.

A chat is represented once in `msteams--chats`. Optional participant and
meeting enrichment is merged into that alist. Filters and bookmarks select the
same objects; they do not maintain synchronized inbox copies.

## Modules

### `msteams.el`

Package entry point. It loads configuration, the core UI, advanced workflows,
and optional Evil integration.

### `msteams-config.el`

Defines the `msteams` customization group and all public settings. It also
contains compatibility migrations for defaults that changed in live sessions.

### `msteams-ui.el`

Implements the asynchronous process transport, headers buffer, singleton
reader, compose buffers, rendering, images, message mutation commands, and
basic capture/open commands.

Main entry points:

- `msteams-inbox`: open or refresh the headers buffer.
- `msteams-open-chat`: render a chat in the shared reader.
- `msteams-send` and `msteams-reply`: create native compose buffers.
- `msteams--run-json`: issue one backend request and dispatch parsed JSON.
- `msteams--enrich-meetings`: attach linked event data to existing chat rows.

### `msteams-advanced.el`

Implements bookmarks and query evaluation, deferred/bulk actions, cache sync,
offline search, channel views, full-thread Markdown, Org capture, attachment
workflows, and optional agent analysis.

Main entry points:

- `msteams-bookmark-jump`: apply a configured view/query.
- `msteams-execute-marks`: apply deferred row actions serially.
- `msteams-bulk-action`: apply one operation to selected conversations.
- `msteams-sync`: refresh the local SQLite cache.
- `msteams-channels`: choose a team and channel.
- `msteams-export-current-thread`: fetch and write complete Markdown.
- `msteams-capture-current-summary`: capture compact conversation metadata.
- `msteams-analyze-current-thread`: export then start an `agent-shell` session.

### `msteams-evil.el`

Adds normal/motion bindings after Evil loads. It mirrors the ordinary major
mode maps; business logic does not depend on Evil or Spacemacs.

### `bin/msteams_graph.py`

Implements the command dispatcher, credential-provider boundary, Graph
requests, retries, pagination, chat/channel operations, linked event lookup,
file transfer, and persistent JSON-lines server.

Main functions:

- `graph_request`: issue a Graph request and enforce Graph-host token scoping.
- `get_token`: obtain a short-lived token from the configured provider.
- `list_chats` and `list_chat_messages`: fetch bounded conversation data.
- `get_meeting_event_batch`: fetch linked events with bounded concurrency.
- `dispatch`: map the CLI-compatible argv protocol to one operation.

### `bin/msteams_cache.py`

Owns the private SQLite schema and cache reads, writes, synchronization
watermarks, and full-text search.

### `bin/msteams_mock.py`

Implements the same command contract against a persistent fake tenant. Tests
can exercise destructive and asynchronous workflows without Graph access.

## Meeting Metadata

Graph chat data may include `onlineMeetingInfo.calendarEventId`. The adapter
fetches `/me/events/{id}` with a narrow field selection and returns the event
beside the chat id. Emacs merges the result into `meetingContext.event`.

The inbox schedule column, upcoming-meeting predicate/sort, and reader banner
all read this same attachment. A calendar permission failure is soft: the
conversation and participants remain available and the event is omitted.

## Reader And Navigation

There is one buffer named by `msteams--read-buffer-name`. Opening another chat
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
