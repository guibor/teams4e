<p align="center">
  <img src="assets/logo.png" width="104" alt="teams4e logo">
</p>

<h1 align="center">teams4e</h1>

<p align="center">
  <strong>Microsoft Teams, with a mu4e-inspired Emacs workflow.</strong><br>
  One inbox. One reader. Your editor.
</p>

<p align="center">
  <a href="https://github.com/guibor/teams4e/actions/workflows/test.yml"><img alt="Tests" src="https://github.com/guibor/teams4e/actions/workflows/test.yml/badge.svg"></a>
  <a href="https://www.gnu.org/software/emacs/"><img alt="Emacs 29.1+" src="https://img.shields.io/badge/Emacs-29.1%2B-7f5ab6?logo=gnuemacs&logoColor=white"></a>
  <a href="https://www.python.org/"><img alt="Python 3.10+" src="https://img.shields.io/badge/Python-3.10%2B-3776ab?logo=python&logoColor=white"></a>
  <a href="LICENSE"><img alt="GPL-3.0-or-later" src="https://img.shields.io/badge/license-GPL--3.0--or--later-187b75"></a>
</p>

<p align="center">
  <a href="#try-it-without-a-teams-account">Try the mock</a> |
  <a href="#reuse-the-login-you-already-have">Authentication</a> |
  <a href="#installation">Install</a> |
  <a href="USAGE.md">Workflow and keys</a> |
  <a href="SECURITY.md">Privacy</a>
</p>

![Illustrative teams4e inbox and meeting workflow](assets/demo.gif)

*Illustrative Moe Dark animation, not a recording of the current UI. All
conversations and identities are synthetic. The mock below runs the real client.*

**teams4e is a native Emacs interface to Teams conversations, not an embedded
browser or a terminal wrapper.** Scan headers, open a conversation in one
reusable reader, reply in Org or Markdown, and turn a message into an Org action
without losing your place.

It borrows the useful parts of mu4e: bookmarks, deferred marks, bulk actions,
a predictable reading pane, and keyboard-driven triage. Ordinary Emacs works;
Spacemacs, Evil, Agent Shell, and a particular theme are not required.

> [!IMPORTANT]
> **Live access reuses an existing approved Microsoft 365 integration.**
> teams4e does not register another Entra application or implement its own
> device-code login. It needs a compatible delegated Graph token from your
> existing broker/CLI/TUI/MCP integration, or a custom backend adapter.
> An arbitrary MCP connection is not sufficient, and tenant policy still applies.
> [How to connect](#reuse-the-login-you-already-have).

This is a young, unofficial client, not affiliated with Microsoft. Calls and
screen sharing still belong in Teams; advanced calendar editing stays in Outlook.

## Why teams4e?

| What you want to do | How it works |
| --- | --- |
| Read without accumulating buffers | One reusable reader for chats and channel threads; inline images, links, attachments, and optional rich rendering |
| Write in your editor | Org by default, optional Markdown or plain text; rendered HTML on send, recoverable drafts, mentions, replies, and attachments |
| Keep context while replying | The composer opens below the transcript, with recent exchanges visible above |
| Triage a busy inbox | Bookmarks, reversible unread overlays, read/unread marks, favorites, bulk actions, and local snooze |
| Find the meeting, not just its chat | Start-time ordering, time intervals, location, participants, RSVP, join, and an availability/propose-new-time workspace |
| Take the conversation with you | Compact Org capture with source links, complete paginated Markdown export, and editable text forwarding |
| Ask an agent for help, explicitly | Per-thread analysis or an optional ongoing Agent Shell companion; no agent starts during ordinary reading |

**A small example:** `b t` opens Today; `F` narrows it to unread conversations;
`RET` opens one; `R` starts an Org reply below it. Send with `C-c C-c`.
Another `F` restores Today without the unread overlay.

Opening a conversation does **not** mark it read by default. Snooze is local,
not a change to Teams read state. All of these defaults are configurable.

## Try It Without a Teams Account

Requirements: **Emacs 29.1+ and Python 3.10+**. The bundled backend uses only
Python's standard library. Git is needed for a source-based installation.

Evaluate this in Emacs:

```elisp
(require 'package-vc)
(package-vc-install "https://github.com/guibor/teams4e")
(require 'teams4e)
(setq teams4e-mock-mode t)
(teams4e)
```

The persistent mock has synthetic people, chats, channels, messages, and
meetings. It uses the real frontend/backend contract without reading tokens or
contacting Graph. You can send mock replies, mark, snooze, search, and export.

Run `M-x teams4e-mock-disable` before configuring a live account.
The optional Agent Shell companion still uses your selected agent, even when
Teams itself is in mock mode. See [LOCAL-TESTING.md](LOCAL-TESTING.md).

## Reuse the Login You Already Have

In a managed organization, another Microsoft 365 integration may already own
login, consent, and refresh. teams4e keeps those responsibilities there.

| Your existing integration can... | Configure... |
| --- | --- |
| Return a fresh delegated Microsoft Graph token | `teams4e-token-command`, the recommended boundary |
| Maintain a compatible credential record | A read-only `teams4e-credentials-file` |
| Expose tools but not tokens | Your own executable adapter behind `teams4e-backend-program` |

For a token helper:

```elisp
(setq teams4e-token-command '("my-token-helper" "graph-token"))
```

**That executable is a placeholder, not a bundled command.** Your helper must
reuse the approved integration and print only a raw Graph access token or:

```json
{"access_token":"REDACTED","expires_at":1786123456}
```

It is invoked as an argument list, without a shell. The external owner handles
login and refresh; teams4e consumes the short-lived token.

An existing MCP or DavMail login alone does not establish compatibility.
If a service does not export Graph tokens, an adapter must implement the needed
operations. **No universal MCP adapter is bundled.** This architecture avoids
duplicating an approved login setup; it does not expand its permissions or
bypass Entra consent or conditional access.

After configuration, run `M-x teams4e-status`, then `M-x teams4e`.
Use `M-x teams4e-login` only when an external bootstrap helper is configured.

[AUTHENTICATION.md](AUTHENTICATION.md) covers all three patterns, exact JSON
formats, helper contracts, permissions, and troubleshooting. Chat can work
without calendar access. Sovereign-cloud endpoints are not currently configurable.

## Installation

### Emacs package-vc

Use the install command above, then configure normally:

```elisp
(use-package teams4e
  :commands (teams4e teams4e-inbox teams4e-meetings teams4e-status))
```

### Spacemacs / Quelpa

Add the package recipe to your layer:

```elisp
(teams4e :location
         (recipe :fetcher git
                 :url "https://github.com/guibor/teams4e.git"
                 :files ("*.el" ("bin" "bin/*"))))
```

Keep the `bin/` directory: the package is Emacs Lisp **and** its Python backend.
This public recipe needs no private repository or personal configuration.

### Manual checkout

```sh
git clone https://github.com/guibor/teams4e.git ~/src/teams4e
```

```elisp
(add-to-list 'load-path (expand-file-name "~/src/teams4e"))
(require 'teams4e)
```

Choose your own checkout directory. Make sure `python3` is on Emacs's
executable path, especially when launching Emacs from a desktop icon.

### Updating

Update the installation Emacs actually loads:

- **package-vc:** `M-x package-vc-upgrade RET teams4e RET`.
- **Spacemacs/Quelpa:** update through the package manager that installed it,
  retaining the recipe's `bin` files.
- **Manual:** `git -C ~/src/teams4e pull --ff-only`, with your checkout path.

Restart Emacs so its Lisp and persistent backend use the same version.
`M-x find-library RET teams4e RET` identifies the loaded installation.
Pulling an unrelated checkout does not update your installed package.

## Daily Workflow

| Key | Action |
| --- | --- |
| `j` / `k` | Next/previous conversation, even from the reader |
| `RET` / `q` | Open / close the reader |
| `R` / `c` | Reply / compose |
| `r` or `i`, then `x` | Queue mark-read, then apply |
| `b` | Bookmarks: `i` inbox, `a` all active, `t` today, `m` meetings, `s` snoozed |
| `F` | Toggle unread-only on the current view; press again to undo |
| `z` / `Z` | Default snooze / choose a wake time |
| `o` / `O` | Open in browser / Teams app |
| `M-j` / `M-k` | Move between messages |
| `a a` | Capture a compact Org action with source metadata |
| `a e` / `a g` | Export complete Markdown / export for agent analysis |
| `a ?` | Action help |

`F` is the unread toggle, **not** forward; forwarding is `a f`.
`b a` clears the view/unread filters but still hides active snoozes;
`b s` is the explicit Snoozed view.

[USAGE.md](USAGE.md) contains the full key reference, queries, bulk actions,
snooze wake times, message selection, link-hint, and forwarding details.

### Write in Org or Markdown

New drafts use real Org mode. Write emphasis, lists, links, tables, and code;
teams4e converts the source to Teams HTML when sending.

```elisp
(setq teams4e-compose-editor 'org)        ; default, built in
;; (setq teams4e-compose-editor 'markdown) ; markdown-mode + Pandoc
;; (setq teams4e-compose-editor 'text)     ; legacy plain/direct-HTML editor
```

`C-c C-c` sends; `C-c C-k` discards. `@` selects a real Teams mention.
The reply editor opens below the conversation; closing it does not close your
Emacs frame. Existing drafts retain their source format.

Markdown needs the Emacs `markdown-mode` package and [Pandoc](https://pandoc.org/installing.html).
For rich incoming-message rendering, install [Agent Shell](https://github.com/xenodium/agent-shell);
its renderer runs locally without starting an agent. Otherwise, reading falls
back to plain text. [Composition details](USAGE.md#writing-messages).

### How Far Back Does History Go?

Opening a chat defaults to a recent **30-day window and 50 messages** for speed.
`L` loads more; `G` requests complete available history for that read.
Configure `teams4e-message-days` and `teams4e-message-limit` to change the
initial bounds; `nil` removes the respective bound.

Export and agent analysis make a separate request that follows every Graph
pagination link, records counts and the date range, and rejects incomplete
results. "Complete" means everything the API makes available to your account,
not messages deleted or unavailable under retention/access policies.

## Meetings Without Living in the Calendar

`b m` orders upcoming/active meetings by **start time**, with intervals,
location, and response state. Normal message views stay ordered by last message.

Inspect participants, RSVP, join, or open the Outlook event. The availability
workspace compares returned free/busy information and calendar blocks, offers
alternate slots, and lets you propose a new time. Calendar permissions and
sharing policy determine what is visible; unavailable data is not "free."

This is a useful calendar companion, not a complete replacement for Outlook.
[Meeting workflow](USAGE.md#meetings-without-living-in-the-calendar).

## Optional Agent Workflows

- **One thread:** `a g` exports the full available conversation, then opens
  Agent Shell with a configurable prompt and agent.
- **Ongoing context:** `M-x teams4e-companion` opens a reusable discussion of
  open requests, commitments, and possible next actions. Monitoring starts
  when you invoke it; it is bounded, visible, and pausable.

Neither starts during ordinary reading. Calendar context and reference files
are opt-in. The companion does not send messages or mutate calendars itself,
but it does not restrict your agent's tools or permissions. Choose a provider
approved for the content. [Companion setup and limits](COMPANION.md).

## Configuration Belongs to You

`M-x customize-group RET teams4e RET` exposes package options. Authentication,
paths, bookmarks, browser/app launchers, history limits, work hours, compose
format, renderer, and agent instructions are configurable.

For example, after setting up authentication:

```elisp
(setq teams4e-compose-editor 'org
      teams4e-mark-read-on-open nil
      teams4e-preview-on-move nil
      teams4e-message-order 'oldest-first
      teams4e-message-days 30
      teams4e-message-limit 50
      teams4e-default-snooze-minutes 180
      teams4e-capture-file "~/Documents/teams.org")
```

The capture path above is an example, not a required directory.
Sending and applying marks do not ask for an extra confirmation by default.
Set `teams4e-confirm-send` and `teams4e-confirm-apply` to `t` if you prefer one.

## Privacy and Public Use

The package ships no organization-specific login owner, tenant ID, credentials,
private-repository dependency, or required agent skill. Demos and fixtures use
synthetic data. Ordinary use does not require AI services.

**Your runtime data is still sensitive.** Caches, drafts, images, downloads,
exports, captures, and agent snapshots may contain workplace information.
Local storage is not an encrypted vault; keep it outside Git and use suitable
device protections. Redact diagnostics before sharing them.

[SECURITY.md](SECURITY.md) describes data boundaries and safe reporting.
[PUBLIC-READINESS.md](PUBLIC-READINESS.md) records the publication audit and its
limits; a clean secret scan is not a guarantee of security.

## Development and Documentation

The Emacs frontend owns views, composition, capture, and navigation. The bundled
Python adapter owns Graph requests, pagination, retries, caching, and the mock.
An external provider owns authentication. See [DESIGN.md](DESIGN.md).

```sh
make test
make compile
git diff --check
```

No account is needed for the test suite. CI also exercises real Evil,
link-hint, expand-region, and Org/Markdown composition. Live tenant behavior
still needs live validation.

| Guide | What it covers |
| --- | --- |
| [Authentication](AUTHENTICATION.md) | Token helpers, credential files, adapters, and permissions |
| [Usage](USAGE.md) | All keys, views, snooze, composition, meetings, capture, and exports |
| [Local testing](LOCAL-TESTING.md) | Synthetic tenant, latency simulation, fixtures, and integration testing |
| [Companion](COMPANION.md) | Optional ongoing agent discussion and its data scope |
| [Contributing](CONTRIBUTING.md) | Portable changes and reproducible, redacted reports |
| [Changelog](CHANGELOG.md) | Changes and compatibility notes |

Feedback and focused PRs are welcome, especially on accessibility, plain-Emacs
workflows, and adapters for approved integrations. Please use synthetic examples
in public reports. An [r/emacs announcement draft](ANNOUNCEMENT.md) is included.

## Compatibility and License

`M-x teams4e`, `M-x teams`, and `M-x teams4e-inbox` open the same inbox.
The former `msteams` Lisp package and executable remain compatibility shims;
new configuration should use `teams4e`. Microsoft's `msteams://` URL scheme
is unrelated to that rename.

GNU General Public License version 3 or later. See [LICENSE](LICENSE).
