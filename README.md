# teams4e

<img src="assets/logo.png" alt="teams4e logo" width="64" align="right">

teams4e is an Emacs client for Microsoft Teams chats, channels, and meetings.
It is inspired by [mu4e](https://www.djcbsoftware.nl/code/mu/mu4e/): use
bookmarks to select conversations, read them in a headers/message layout, and
act on them without leaving Emacs. Replies can be composed in Org mode, and
conversations can be captured into Org with links back to their source.

The package provides interactive commands, mode-local keymaps, and user
options. The bindings below are defaults, not a required workflow; use
`M-x`, bind the commands you need, and configure the views and actions to
suit your setup. mu4e, Evil, Spacemacs, and AI services are not required.

## Features

- Bookmarks defined by queries or Lisp predicates, with an unread-only filter
  that can be applied to the current view and removed again.
- Conversation actions for Org capture, Markdown export, read/unread state,
  snooze, and opening the source in Teams. Marks and bulk actions allow
  several conversations to be processed together.
- An Org-mode composer with HTML conversion on send, recoverable drafts,
  participant mentions, and attachments. Markdown and plain text are
  alternative editors. Recent messages remain visible while replying.
- One reusable reader for chats and channel threads, with images, attachments,
  message navigation, and optional rich rendering, link-hint, and
  expand-region integration.
- A meeting view with start times, intervals, participants, location, RSVP,
  joining, and an availability workspace for proposing another time.
- Optional Agent Shell commands for analysing an exported thread or discussing
  outstanding requests. These run only when invoked.

## The mu4e Analogy

The main connection is between correspondence and the rest of an Emacs
workflow. A conversation may need a reply, a task in Org, a reference in a
project note, or no further attention. Bookmarks let you choose what to work
on; the reader and conversation actions let you deal with it in place.

Like mu4e's [bookmarks](https://www.djcbsoftware.nl/code/mu/mu4e/Bookmarks.html),
teams4e bookmarks are named queries with configurable shortcut keys.
Its Org capture actions serve a similar purpose to
[mu4e's Org integration](https://www.djcbsoftware.nl/code/mu/mu4e/Org_002dmode.html):
keep actionable material in your notes with enough context to return to the
original correspondence.

This is an independent client, not a mu4e backend or an exact keymap clone.
The usual unit of triage is a Teams conversation rather than a mail message.
Org capture uses package-provided entries, not mu4e's link types or capture
template fields. See [Org capture](#org-capture-and-conversation-actions)
and [customization](#customization) below.

## Screenshots

![Actual teams4e inbox, reader, Org reply, and meetings in Moe Dark](assets/demo.gif)

Actual graphical Emacs captures using Moe Dark, Iosevka, and synthetic Teams
data. Incoming formatting uses Agent Shell's optional Markdown renderer.
[Reader](assets/thread.png), [Org reply](assets/reply.png),
[meeting details](assets/meetings.png), and
[capture instructions](tools/README.md).

## Requirements

Emacs 29.1+, Python 3.10+, and Git for installation from source. The bundled
Python backend has no third-party Python dependencies.

Live access requires a compatible, approved Microsoft 365 integration to
provide authentication, or a custom backend adapter. teams4e does not
register an Entra application or implement device-code login.
See [authentication](#reuse-the-login-you-already-have); the mock below needs
no account.

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

## Commands and Key Bindings

Start with `M-x teams4e`. Use `M-x customize-group RET teams4e RET` for user
options, `C-h f` for a command's documentation, and `C-h m` for the active
mode's bindings. `M-x teams4e-dispatch` provides command help.

The following are selected **default local bindings**, primarily in the
headers buffer. The chat reader delegates conversation actions to the linked
headers buffer. They can be changed independently of the commands.

| Command | Default binding | Purpose |
| --- | --- | --- |
| `teams4e-bookmark-jump` | `b` | Select a configured bookmark |
| `teams4e-filter` | `s` | Enter a query |
| `teams4e-toggle-unread-filter` | `F` | Toggle unread-only within the current view |
| `teams4e-recent-open` | `RET` | Open the selected conversation |
| `teams4e-reply` / `teams4e-send` | `R` / `c` | Reply / compose |
| `teams4e-mark-read-later` | `r` or `i` | Queue mark-read |
| `teams4e-execute-marks` | `x` | Apply queued actions |
| `teams4e-snooze-quick` / `teams4e-snooze` | `z` / `Z` | Default snooze / choose a wake time |
| `teams4e-capture-current-summary` | `a a` | Start a compact Org capture |
| `teams4e-capture-current-thread` | `a A` | Capture the available transcript |
| `teams4e-jump-to-capture` | `a j` | Visit an existing capture |
| `teams4e-export-current-thread` | `a e` | Export Markdown |
| `teams4e-analyze-current-thread` | `a g` | Export for Agent Shell analysis |

The full [usage reference](USAGE.md) covers reader navigation, bulk actions,
snooze choices, message selection, and channel-specific commands.
See [changing bindings](#changing-bindings) for examples.

## Org Capture and Conversation Actions

`teams4e-capture-current-summary` starts an editable `org-capture` entry
containing the conversation title, source link, dates, participants when
available, and a short last/selected-message excerpt. It does not download
the whole thread. Meeting captures also include available calendar context.

Use this to turn a request into a task: capture it, give the heading a
meaningful title and a TODO keyword, and schedule or refile it using Org's
ordinary commands. The source link remains with the task. To include the
destination in your agenda, add it to `org-agenda-files` as you would any
other Org file; teams4e does not change your agenda configuration.

The destination is configurable:

```elisp
(with-eval-after-load 'teams4e
  (setq teams4e-capture-file "~/org/teams.org")) ; choose your own file
```

The default value is `nil`, which resolves to `teams.org` under
`org-directory`, or under `~/Documents` if necessary. The compact capture
opens an existing matching entry when one is found instead of creating another.
`teams4e-jump-to-capture` also returns to that entry.

For reference material, use `teams4e-capture-current-thread` to capture the
available transcript, or `teams4e-export-current-thread` to save Markdown.
`teams4e-capture-current-message` writes the selected message to the capture
file. These are separate choices: capturing an action need not copy a long
conversation into your notes.

The compact and full-thread commands supply their own editable capture
entries. They do not currently expose a user-defined capture-template option
or mu4e-compatible `org-store-link` fields. The captured entry is ordinary
Org text, not a second task database synchronized with Teams.

The `teams4e-action-map` prefix groups these commands with read/unread,
snooze, browser, and other conversation actions. You can bind its commands
directly or add bindings for your own interactive functions.

## Write in Org or Markdown

New drafts use `org-mode` with a compose minor mode.
`teams4e-reply` and `teams4e-send` open the editor; normal Org commands
remain available for emphasis, lists, links, tables, and source blocks.
For example:

```org
*Quick update*

- *Done:* the pagination fix.
- *Next:* review [[https://example.org/review][the notes]].
```

`teams4e-compose-send` (default `C-c C-c`) exports an HTML fragment, so people
in Teams receive formatted text and clickable links, **not raw Org syntax**.
Recipients do not need Emacs or Org. Org composition uses Emacs's built-in
exporter; it does not require Pandoc or an AI service.

The reply buffer opens below the reader, keeping recent exchanges visible
while you write. Recoverable drafts retain their source and editor choice.
Real Teams `@` mentions and attachments work in all three editors.

```elisp
(setq teams4e-compose-editor 'org)        ; default, built in
;; (setq teams4e-compose-editor 'markdown) ; markdown-mode + Pandoc
;; (setq teams4e-compose-editor 'text)     ; legacy plain/direct-HTML editor
```

The default `C-c C-k` binding discards the draft; closing it does not close
your Emacs frame. Conversion errors preserve the draft instead of sending raw markup.
Org export does not execute Babel code; includes, setup files, macros, and
calls are rejected.

Markdown drafts similarly become HTML on send. They need the Emacs
`markdown-mode` package and [Pandoc](https://pandoc.org/installing.html).
The `text` option retains the original plain/direct-HTML editor.
For rich incoming-message rendering, install [Agent Shell](https://github.com/xenodium/agent-shell);
its renderer runs locally without starting an agent. Otherwise, reading falls
back to plain text. [Composition details](USAGE.md#writing-messages).

## History and Export

Opening a chat defaults to a recent **30-day window and 50 messages** for speed.
`teams4e-chat-load-more` (default `L`) loads more;
`teams4e-chat-load-all` (default `G`) requests complete available history.
Configure `teams4e-message-days` and `teams4e-message-limit` to change the
initial bounds; `nil` removes the respective bound.

Export and agent analysis make a separate request that follows every Graph
pagination link, records counts and the date range, and rejects incomplete
results. "Complete" means everything the API makes available to your account,
not messages deleted or unavailable under retention/access policies.

## Meetings Without Living in the Calendar

`M-x teams4e-meetings` orders upcoming/active meetings by start time, with
intervals, location, and response state. Normal message views stay ordered by last message.

Inspect participants, RSVP, join, or open the Outlook event. The availability
workspace compares returned free/busy information and calendar blocks, offers
alternate slots, and lets you propose a new time. Calendar permissions and
sharing policy determine what is visible; unavailable data is not "free."

This is a useful calendar companion, not a complete replacement for Outlook.
[Meeting workflow](USAGE.md#meetings-without-living-in-the-calendar).

## Optional Agent Workflows

- `teams4e-analyze-current-thread` exports the full available conversation,
  then opens Agent Shell with a configurable prompt and agent.
- `teams4e-companion` opens a reusable discussion of
  open requests, commitments, and possible next actions. Monitoring starts
  when you invoke it; it is bounded, visible, and pausable.

Neither starts during ordinary reading. Calendar context and reference files
are opt-in. The companion does not send messages or mutate calendars itself,
but it does not restrict your agent's tools or permissions. Choose a provider
approved for the content. [Companion setup and limits](COMPANION.md).

## Customization

User options belong to the `teams4e` customization group. Use Customize or
set them in your init file after loading the package. For example:

```elisp
(with-eval-after-load 'teams4e
  ;; These values show the current defaults; change them to suit your setup.
  (setq teams4e-compose-editor 'org
        teams4e-mark-read-on-open nil
        teams4e-preview-on-move nil
        teams4e-message-order 'oldest-first
        teams4e-message-days 30
        teams4e-message-limit 50
        teams4e-default-snooze-minutes 180))
```

Authentication, paths, work hours, browser/app launchers, rendering, and agent
instructions are also configurable. Sending and applying marks do not ask for
an extra confirmation by default; set `teams4e-confirm-send` and
`teams4e-confirm-apply` to `t` to enable one.

### Bookmarks

`teams4e-bookmarks` is a list of plists with `:name`, `:query`, and
`:key`. A query can be a built-in view symbol, a query string, or a function
accepting a chat. For example, add a project view without replacing the
built-in bookmarks:

```elisp
(with-eval-after-load 'teams4e
  (add-to-list 'teams4e-bookmarks
               '(:name "Project Atlas"
                 :query "name:Atlas"
                 :key ?p)
               t))
```

With the default bookmark binding, this makes `b p` select that view.
Choose an unused shortcut of your own. Query terms include `unread`,
`favorite`, `mentioned`, `type:meeting`, `name:TEXT`, and `after:7d`.
See [query syntax](USAGE.md#views-that-compose) for combinations and predicates.

`teams4e-toggle-unread-filter` narrows the current view without replacing
its query; invoke it again to remove that restriction. Active snoozes stay
hidden from ordinary views, including All; the Snoozed bookmark exposes them.
Snooze is local and does not change Teams read state.

### Changing Bindings

Use the package's mode maps rather than global bindings for buffer-local
actions. For example, add an alternative unread-filter binding in both the
headers and chat reader, and an Org-capture alias under the action prefix:

```elisp
(with-eval-after-load 'teams4e
  (keymap-set teams4e-recent-mode-map "C-c u"
              #'teams4e-toggle-unread-filter)
  (keymap-set teams4e-chat-mode-map "C-c u"
              #'teams4e-chat-toggle-unread-filter)
  (keymap-set teams4e-action-map "n"
              #'teams4e-capture-current-summary))
```

These are examples, not additional package defaults. The last form adds
`a n` alongside the default `a a` binding. Use `keymap-unset` if you
also want to remove an old binding. Your own interactive commands can be added
to the same prefix map; this does not add them to the separate dispatcher menu.

With Evil, state-specific maps may take precedence over ordinary mode maps.
For example, add the same reader binding in Normal and Motion states from
your init file:

```elisp
(with-eval-after-load 'teams4e
  (with-eval-after-load 'evil
    (evil-define-key* '(normal motion) teams4e-chat-mode-map
      (kbd "C-c u") #'teams4e-chat-toggle-unread-filter)))
```

The package refreshes some built-in Evil bindings when its modes start. When
overriding those keys, put your customization in a mode hook registered after
loading teams4e. Ordinary mode hooks can also configure buffer-local settings;
no Evil or Spacemacs configuration is needed for non-modal use.

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
