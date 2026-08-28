<p align="center">
  <img src="assets/logo.png" width="104" alt="teams4e logo">
</p>

<h1 align="center">teams4e</h1>

<p align="center">
  <strong>A mu4e-inspired Microsoft Teams client for Emacs.</strong><br>
  Reuse approved Microsoft 365 access. Read, triage, and write without leaving Emacs.
</p>

<p align="center">
  <a href="https://github.com/guibor/teams4e/actions/workflows/test.yml"><img alt="Tests" src="https://github.com/guibor/teams4e/actions/workflows/test.yml/badge.svg"></a>
  <a href="https://www.gnu.org/software/emacs/"><img alt="Emacs 29.1+" src="https://img.shields.io/badge/Emacs-29.1%2B-7f5ab6?logo=gnuemacs&logoColor=white"></a>
  <a href="https://www.python.org/"><img alt="Python 3.10+" src="https://img.shields.io/badge/Python-3.10%2B-3776ab?logo=python&logoColor=white"></a>
  <a href="LICENSE"><img alt="GPL-3.0-or-later" src="https://img.shields.io/badge/license-GPL--3.0--or--later-187b75"></a>
</p>

<p align="center">
  <a href="#try-it-without-a-teams-account">Try the mock</a> |
  <a href="#installation">Install</a> |
  <a href="#reuse-the-login-you-already-have">Connect</a> |
  <a href="#daily-workflow">Keys</a> |
  <a href="#meetings-without-living-in-the-calendar">Meetings</a> |
  <a href="#development">Develop</a>
</p>

![teams4e mock tenant demo](assets/demo.gif)

`teams4e` gives Microsoft Teams the interaction model that makes `mu4e`
effective: a compact headers buffer, one reusable reader, native compose
buffers, bookmarks, deferred marks, bulk actions, and keyboard commands that
continue to work while a thread is open.

It is built for chat, triage, meeting context, capture, and automation. Calls,
screen sharing, and advanced calendar editing still open in Microsoft Teams or
Outlook.

> [!IMPORTANT]
> `teams4e` is deliberately not another OAuth application. If an MCP service,
> corporate broker, CLI, TUI, or DavMail-like bridge already has approved
> delegated Microsoft 365 access, it can continue to own login, consent, and
> token refresh. `teams4e` consumes only a short-lived Graph token, or delegates
> its backend operations to an adapter around that service.

This separation matters in managed tenants where registering one more Entra
application is difficult or prohibited. It does **not** bypass tenant policy or
grant permissions: the existing integration must already be approved for the
Graph operations you want to use.

The package is not affiliated with or supported by Microsoft.

## What It Feels Like

| Surface | Experience |
| --- | --- |
| Inbox | Aligned date, type, conversation, state, and preview columns; unread is bold, not noisy |
| Reader | One singleton thread buffer, local-time day separators, inline images, attachments, reactions, and rich Markdown-style formatting |
| Navigation | `j`/`k` stay on the conversation list even from the reader; `M-j`/`M-k` move between messages |
| Triage | Read/unread, favorites, bookmarks, composable filters, deferred marks, bulk actions, and undo |
| Meetings | Upcoming meetings, intervals, location, response state, participants, conflicts, RSVP, join, and propose-new-time |
| Capture | Compact or full Org capture, complete Markdown export, clipboard copy, and optional Agent Shell analysis |
| Scale | Bounded Graph reads, asynchronous enrichment, one persistent backend, SQLite search cache, and cache-first opening |
| Editing | Native Emacs compose buffers for new messages, replies, forwards, mentions, attachments, and Markdown-like rich text |

Chats, group chats, one-to-one conversations, meeting chats, teams, channels,
channel posts, and replies all use the same Emacs workflow.

## Try It Without a Teams Account

Install the package, enable its persistent local mock, and open the inbox:

```elisp
(package-vc-install "https://github.com/guibor/teams4e")

(setq teams4e-mock-mode t)
(teams4e)
```

Or use the interactive commands:

```text
M-x teams4e-mock-enable
M-x teams4e
```

The mock uses the production argv/JSON boundary and supports messages,
reactions, editing, deletion, read state, channels, search, exports, and
meeting metadata. It never reads credentials or contacts Microsoft Graph.

Add controlled latency with `teams4e-mock-delay-ms`, then inspect
`M-x teams4e-performance-report`. See
[LOCAL-TESTING.md](LOCAL-TESTING.md) for the complete account-free workflow.

## Installation

### Emacs 29 package-vc

```elisp
(package-vc-install "https://github.com/guibor/teams4e")

(use-package teams4e
  :commands (teams4e teams4e-inbox teams4e-meetings teams4e-status))
```

The repository includes its Python backend, so the package needs the `bin`
directory as well as the Emacs Lisp files.

### Spacemacs or Quelpa

```elisp
(teams4e :location
         (recipe :fetcher git
                 :url "https://github.com/guibor/teams4e.git"
                 :files ("*.el" ("bin" "bin/*"))))
```

Then configure it normally:

```elisp
(use-package teams4e
  :defer t
  :commands (teams4e teams4e-inbox teams4e-meetings teams4e-status))
```

### Requirements

- Emacs 29.1 or newer.
- Python 3.10 or newer.
- No third-party Python packages.
- For live use, an external source of delegated Microsoft Graph access tokens.

`M-x teams4e`, `M-x teams`, and `M-x teams4e-inbox` open the
same inbox.

## Reuse the Login You Already Have

The normal live setup is a small bridge between `teams4e` and an existing
Microsoft 365 integration:

```text
approved OAuth owner
(MCP / broker / CLI / TUI / DavMail-like bridge)
             |
      fresh delegated Graph access
             |
 token command, credential file, or backend adapter
             |
         teams4e in Emacs
```

There are three supported patterns:

1. **Token command, recommended.** Point `teams4e-token-command` at an existing
   helper that prints a fresh, short-lived Microsoft Graph access token.
2. **Broker-owned credential file.** Let the approved integration maintain a
   JSON credential record; `teams4e` reads the Graph access token but never
   writes the file or handles its refresh token.
3. **Backend adapter.** If an MCP server exposes tools but intentionally does
   not export tokens, wrap those tools behind the `teams4e` argv/JSON backend
   contract. The token then never leaves the approved service.

Having an MCP connection by itself is not enough: its host must expose a Graph
token through one of the first two boundaries, or provide the operations needed
by the third. See [AUTHENTICATION.md](AUTHENTICATION.md) for complete examples,
the credential JSON shape, adapter protocol, verification steps, and security
notes.

## Authentication

### Use a token command

This is the preferred boundary. Configure an argv list; no shell is involved:

```elisp
(setq teams4e-token-command
      '("my-token-helper" "token" "--resource" "graph"))
```

The command may print a raw token or one JSON object:

```json
{"access_token":"REDACTED","expires_at":1786123456}
```

`expires_at` can be Unix seconds or milliseconds. A JWT `exp` claim is
also accepted. Only the short-lived access token is retained in backend memory,
and the command is called again near expiry.

### Read a broker-owned credential file

The alternative is a read-only JSON credential store managed by another
program:

```elisp
(setq teams4e-credentials-file "~/.config/my-m365/credentials.json"
      teams4e-credential-server-name "m365"
      teams4e-credential-server-url nil)
```

Candidate entries use `server_name`, optional `server_url`,
`graph_access_token`, and `graph_expires_at`. If the same OAuth owner can
refresh that file, expose it as:

```elisp
(setq teams4e-bootstrap-program "/path/to/my-oauth-owner")
```

It is invoked as:

```text
HELPER --refresh-if-needed --credentials FILE
```

`teams4e` never writes the credential file or stores a refresh token. Keep
the file readable only by your user.

After configuring either boundary, run:

```text
M-x teams4e-status
M-x teams4e
```

Use `M-x teams4e-login` only when you configured
`teams4e-bootstrap-program`; it asks that external owner to refresh or establish
the shared credential. It does not implement a teams4e-specific login flow.

### Graph permissions

Permissions are determined by your token provider and tenant policy. Basic chat
workflows typically need delegated chat and message permissions. Calendar
features are independent:

- Reading free/busy commonly needs `Calendars.ReadBasic`.
- Ranked alternate-time suggestions commonly need
  `Calendars.Read.Shared`.
- RSVP and new-time proposals need `Calendars.ReadWrite`.

Meeting chats remain readable when calendar access is unavailable. Sharing
policy may hide another participant's calendar subject or location even when
free/busy is visible.

## Daily Workflow

The headers buffer owns navigation and actions. Opening a conversation does not
turn the reader into a separate mini-application.

| Key | Action |
| --- | --- |
| `j` / `k` | Next/previous conversation, including from the reader |
| `RET` or `l` | Open the selected conversation |
| `r` or `i` | Queue mark-read |
| `R` | Reply |
| `c` or `C` | Compose a new message |
| `f` or `F` | Forward the selected or latest message |
| `o` / `O` | Open in browser / native Teams app |
| `b` | Choose a bookmark |
| `U`, `b u`, or `M-F` | Toggle unread-only on top of the current view |
| `m` | Deferred-mark prefix |
| `x` | Apply deferred marks |
| `M` / `T` | Select one / all visible conversations |
| `X` | Run a bulk action |
| `a` | Current-conversation action prefix |
| `a a` / `a A` | Capture a summary / complete thread to Org |
| `a e` / `a y` | Export / copy complete Markdown |
| `a g` | Export and analyze with Agent Shell |
| `a p` | Open participant availability |
| `a v` / `a J` | RSVP / join |
| `a C` | Open the linked Outlook event |
| `G` / `L` | Load complete history / load more |
| `M-j` / `M-k` | Next/previous message in the transcript |
| `q` | Close the reader or restore the previous layout |

Compose buffers use `C-c C-c` to send and `C-c C-k` to abort.
Sending preserves the conversation's prior read/unread state.

Use `M-x teams4e-dispatch` or `a ?` when you do not remember a key.
Ordinary Emacs and optional Evil maps expose the same operations.

## Views That Compose

Bookmarks filter one canonical chat list. They do not create duplicate inboxes
that need synchronization.

| Bookmark | View | Order |
| --- | --- | --- |
| `b i` | Relevant inbox | Newest message first |
| `b a` | All chats; clear overlays | Newest message first |
| `b u` | Toggle unread-only in the current view | Preserve current order |
| `b t` | Activity today in local time | Newest message first |
| `b 2` | Activity in the last 24 hours | Newest message first |
| `b w` | Activity in the last 7 days | Newest message first |
| `b m` | Upcoming and active meetings | Earliest start first |
| `b M` | All meeting chats | Earliest known start first |

A normal inbox excludes muted, handled-current, and actively snoozed
conversations. `b a` is the explicit unfiltered view.

Queries support terms such as `unread`, `favorite`,
`mentioned`, `attachment`, `type:meeting`,
`name:TEXT`, `message:TEXT`, `today`, and `after:7d`.
Terms are ANDed, `|` creates simple OR clauses, and `-` negates a term.
`teams4e-bookmarks` accepts built-in queries, text queries, or your own
predicate functions.

## Meetings Without Living in the Calendar

`M-x teams4e-meetings` or `b m` opens a calendar-light meeting view:

1. **Scan** upcoming and active meetings by start time, including intervals,
   response state, location, overlap warnings, and invitations awaiting action.
2. **Inspect** participants, organizer, join link, proposal state, and meeting
   chat in the singleton reader.
3. **Act** with RSVP, join, and open-in-Outlook commands.
4. **Negotiate** in a full-window availability buffer with ranked alternatives,
   per-participant status, working hours, and returned calendar blocks.
5. **Capture** the meeting summary or complete thread into Org or Markdown.

In the availability buffer, `j`/`k` select an interval and `RET`
proposes it. Use `s`/`b` for suggestions/calendar blocks, `r` to
change the range, `w` to cycle work/personal/unrestricted hours, and
`m` for an exact manual start.

Private calendar blocks never expose returned subject or location through this
UI. Advanced event creation, recurrence, organizer moves, and cancellation
remain in Outlook.

## Rich Threads, Exports, and Agents

Teams HTML is converted into Markdown structure before display. When
[Agent Shell](https://github.com/xenodium/agent-shell) is installed, the reader
renders headings, emphasis, links, blockquotes, lists, checkboxes,
syntax-highlighted code, and aligned GFM tables. Without it, the same thread
falls back to a dependency-free plain renderer. Authenticated images always use
the Teams backend.

Thread export and agent analysis make a dedicated live request that follows
every Graph pagination link. The exported document records message count,
page count, and oldest/newest timestamps. A partial offline cache is never
presented as a complete transcript.

```elisp
(setq teams4e-message-renderer 'auto
      teams4e-highlight-code-blocks t
      teams4e-thread-analysis-agent 'codex)
```

Set the agent identifier to any configuration registered with Agent Shell.

## Configuration Belongs to You

No organization-specific tenant domain, client ID, employee identity, file path,
browser profile, or OAuth implementation is built into `teams4e`. Public settings are Emacs
customization options, including:

- Token command, credential file, bootstrap helper, and credential selectors.
- Browser command and native app command.
- Cache, state, draft, image, download, export, and Org capture paths.
- Bookmarks, default view, message order, unread behavior, and preview behavior.
- Chat, message, member, image, and meeting load/concurrency limits.
- Meeting search horizon, confidence, work-hour policy, and proposal text.
- Markdown renderer and Agent Shell configuration.

A complete, portable starting point might look like:

```elisp
(use-package teams4e
  :commands (teams4e teams4e-meetings)
  :custom
  (teams4e-token-command '("my-token-helper" "graph-token"))
  (teams4e-default-view 'inbox)
  (teams4e-mark-read-on-open nil)
  (teams4e-preview-on-move nil)
  (teams4e-message-order 'oldest-first)
  (teams4e-message-limit 50)
  (teams4e-load-more-count 100)
  (teams4e-message-renderer 'auto)
  (teams4e-confirm-send nil)
  (teams4e-confirm-apply nil)
  (teams4e-capture-file "~/Documents/teams.org"))
```

Run `M-x customize-group RET teams4e RET` for every option.

## Architecture

```text
Emacs UI and workflow
        |
        | argv request / one JSON response
        v
Bundled Python Graph adapter -------- SQLite reading/search cache
        |
        | short-lived delegated token
        v
Your OAuth owner -------------------- Microsoft Graph
```

Emacs owns views, reader state, rendering, compose buffers, marks, capture, and
actions. The Python adapter owns Graph HTTP details, retries, pagination,
bounded concurrency, cache persistence, and the mock protocol. Your external
provider remains the sole owner of app registration, login, consent, and token
refresh.

Message bodies and tokens are never interpolated into shell commands.
Performance reporting excludes people, titles, IDs, URLs, message content, and
tokens.

More implementation detail is in [DESIGN.md](DESIGN.md).

## Development

Run the complete offline suite:

```sh
make test
make compile
```

The tests use patched Graph requests and the persistent mock. They require no
credentials or tenant.

Launch the reproducible graphical demo with:

```sh
Emacs -Q --load tools/teams4e-demo.el
```

The demo prefers Moe Dark when installed and falls back to Emacs's built-in
Wombat theme. Its data uses reserved example identities only.

See [LOCAL-TESTING.md](LOCAL-TESTING.md) for delayed UI testing, Microsoft Dev
Proxy, and live developer-tenant validation.

## Current Boundaries

- Live use requires a separately configured delegated Graph token source.
- Calls, screen sharing, and rich meeting participation stay in Teams.
- Calendar data depends on Graph permissions and tenant sharing policy.
- This is a young package. The mock and automated suite are comprehensive, but
  live tenants still differ in policy and payload details.

Issues and focused pull requests are welcome.

## Compatibility

The project was renamed before its first public release. `(require 'msteams)`
and `bin/msteams-graph` remain compatibility shims. New configuration should
use `teams4e-*`, `(require 'teams4e)`, and
`bin/teams4e-graph`.

Microsoft's official desktop URL scheme is still `msteams://`; that
scheme is unrelated to the package name.

## License

GNU General Public License version 3 or later. See [LICENSE](LICENSE).
