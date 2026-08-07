# msteams.el

`msteams.el` is a keyboard-driven Microsoft Teams client for Emacs. It uses a
mu4e-style headers buffer, one reusable reader pane, native compose buffers,
and a bundled Python adapter for Microsoft Graph.

The package is not affiliated with or supported by Microsoft.

## Features

- Chats, group chats, meeting chats, teams, channels, and channel replies.
- Read/unread state, favorites, reactions, edit/delete, reply, and forwarding.
- Mu4e-style deferred marks, bulk selection, undo, bookmarks, and saved views.
- Inline images, attachments, complete Markdown export, and Org capture.
- A single reusable reader buffer rather than one buffer per conversation.
- SQLite-backed cache, search, offline reading, and background synchronization.
- Linked calendar metadata for meeting chats: time, location, response state,
  organizer, attendees, and join link.
- Optional Evil bindings and optional `agent-shell` thread analysis.
- A persistent local mock for development without a Teams account.

## Requirements

- Emacs 29.1 or newer.
- Python 3.10 or newer; the backend uses only the Python standard library.
- A command or credential owner that supplies a delegated Microsoft Graph
  access token. `msteams.el` does not register an OAuth application or own a
  refresh token.

Tenant policy and delegated permissions determine which actions are available.
Meeting event enrichment requires `Calendars.ReadBasic` or `Calendars.Read`.
Without calendar permission, meeting chats still work but omit event details.

## Installation

With `package-vc`:

```elisp
(package-vc-install "https://github.com/guibor/msteams.el")
```

With `use-package` after installation:

```elisp
(use-package msteams
  :commands (msteams-inbox teams-inbox msteams-channels teams-channels))
```

A Spacemacs/Quelpa recipe must include the Python backend:

```elisp
(msteams :location
         (recipe :fetcher git
                 :url "git@github.com:guibor/msteams.el.git"
                 :files ("*.el" ("bin" "bin/*"))))
```

Run `M-x msteams-inbox` or its compatibility alias `M-x teams-inbox`.

## Authentication

Authentication belongs to an external program. The package supports two
interfaces so an existing company login flow, credential broker, or CLI can
remain the only owner of OAuth state.

### Token command

This is the preferred interface. Configure an argv list; no shell is used:

```elisp
(setq msteams-token-command
      '("my-m365-token-helper" "token" "--resource" "graph"))
```

The command writes either a raw access token or one JSON object to stdout:

```json
{"access_token":"REDACTED","expires_at":1786123456}
```

`expires_at` is Unix seconds or milliseconds. A JWT `exp` claim is also
accepted. The backend caches only the short-lived access token in memory and
runs the command again near expiry.

### Read-only credential store

Alternatively, point the package at a JSON store owned by another program:

```elisp
(setq msteams-credentials-file "~/.config/my-m365/credentials.json"
      msteams-credential-server-name "m365"
      msteams-credential-server-url nil)
```

Each candidate entry has `server_name`, optional `server_url`,
`graph_access_token`, and `graph_expires_at`. An optional
`msteams-bootstrap-program` may refresh that store. It is invoked as:

```text
HELPER --refresh-if-needed --credentials FILE
```

The package reads the resulting access token and never writes credentials or
refresh tokens. Protect the store with user-only file permissions.

### Mock tenant

The mock exercises the real backend command protocol without network access:

```elisp
(setq msteams-mock-mode t)
```

Or run `M-x msteams-mock-enable`, then `M-x msteams-inbox`. Mock state lives in
`msteams-mock-state-file` and is visibly identified in status output. It is for
UI and workflow testing; it does not validate tenant permissions.

## Core Keys

The ordinary Emacs and Evil maps share the same main operations.

| Key | Action |
| --- | --- |
| `j` / `k` | Next/previous conversation, including from the reader |
| `RET` or `l` | Open the selected conversation |
| `r` or `i` | Queue mark-read |
| `R` | Reply |
| `c` or `C` | Compose a new message |
| `f` or `F` | Forward the selected/latest message |
| `o` / `O` | Open in browser / native Teams app |
| `b` | Open a bookmark; `b m` is upcoming meetings |
| `M-F` | Toggle unread filtering on top of the active view |
| `m` | Deferred-mark prefix |
| `x` | Apply deferred marks |
| `M` / `T` | Select one / all visible conversations for bulk action |
| `X` | Choose and apply a bulk action |
| `a` | Current-conversation action prefix |
| `a a` / `a A` | Capture a summary / complete thread to Org |
| `a e` / `a y` | Export / copy complete Markdown |
| `a g` | Export and analyze the complete thread with `agent-shell` |
| `G` / `L` | Load complete history / load more in the reader |
| `M-j` / `M-k` | Next/previous message within a transcript |
| `q` | Close the reader pane or restore the previous window layout |

Run `M-x msteams-dispatch` or use `a ?` for the discoverable command menus.

## Views And Meetings

Bookmarks compose with the current inbox data rather than creating separate
copies. Useful defaults include:

- `b i`: relevant inbox, excluding muted and locally handled conversations.
- `b a`: all chats.
- `b u`: unread chats.
- `b m`: upcoming and currently active meetings, sorted by start time.
- `b M`: all meeting chats.

Meeting chats remain the canonical conversation objects. When a chat exposes
`onlineMeetingInfo.calendarEventId`, the backend fetches that linked event and
attaches it to the chat. The headers schedule column and reader banner render
from that attachment; there is no second calendar inbox or synchronization
model.

`msteams-meeting-enrichment-limit` and
`msteams-meeting-enrichment-concurrency` bound the optional calendar work.

## What Refile Means

The retained refile operation is local triage state, not a Teams server move.
It marks a conversation "handled until new activity" and suppresses it from
the relevant inbox. The state expires automatically when the conversation's
last-message marker changes. It can still be selected from the action/bulk
interfaces or invoked as `M-x msteams-mark-refile-later`, but it deliberately
has no dedicated `r` binding; lowercase `r` marks read.

## Configuration

Important options include:

- `msteams-message-limit`, `msteams-message-days`, and
  `msteams-load-more-count` for transcript depth.
- `msteams-preview-on-move` and `msteams-mark-read-on-open`, both nil by
  default.
- `msteams-message-order` for oldest-first or newest-first transcripts.
- `msteams-bookmarks` for mu4e-style named filters.
- `msteams-status-style` for restrained symbols or terminal-safe letters.
- `msteams-browser-command` and `msteams-app-command` for external launchers.
- `msteams-capture-file` and `msteams-export-directory` for durable output.
- `msteams-thread-analysis-agent` for `codex`, `cursor`, `claude-code`, or
  another registered `agent-shell` configuration.

Use `M-x customize-group RET msteams RET` for the complete list.

## Development

```sh
make test
make compile
```

The test suite uses the local mock and patched Graph requests. Live tenant
behavior still depends on the token's delegated permissions and tenant policy.

## License

GNU General Public License version 3 or later. See `LICENSE`.
