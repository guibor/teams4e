# r/emacs announcement draft

## Title

teams4e: a mu4e-inspired Microsoft Teams client for Emacs

## Post

I wanted to handle Teams conversations the way I handle mail in Emacs:
scan a headers buffer, read in one reusable pane, reply, mark things done,
and get back to work. So I built **teams4e**.

Repository, illustrated demo, and setup:
https://github.com/guibor/teams4e

The workflow borrows from mu4e and terminal Teams clients:

- A conversation list and one reusable reader. `j`/`k` still select chats
  while the reader is open; `M-j`/`M-k` move between messages.
- Bookmarks and reversible unread filtering: `b t` for Today, then `F`
  for just today's unread conversations. Press `F` again to remove it.
- Snooze with `z` (three hours by default) or `Z` for a wake-time menu.
  Snoozed chats leave the ordinary inbox; `b s` shows them by wake time.
- Native compose buffers, participant `@` mentions, replies, attachments,
  read/unread actions, and bulk triage.
- Inline images and optional Markdown-style rendering through Agent Shell,
  including code blocks and tables.
- Compact Org capture with source links, complete paginated Markdown exports,
  and optional analysis with an agent of your choice.
- A meeting view with times, location, participants, RSVP, and an availability
  workspace for proposing another time, when calendar permissions allow it.

Opening a conversation does not mark it read by default. Snoozes are local,
and workday times, bookmarks, paths, agents, and browser choices are configurable.
It works in ordinary Emacs, with optional Evil bindings; Spacemacs is not required.

**The authentication approach is a big part of the project.** teams4e does not
register another OAuth application or run its own device-code login. It can use
a Microsoft 365 integration that already owns your login and consent, such as
an approved broker, CLI/TUI, or MCP-backed service.

If that integration can return a short-lived delegated Graph token, configure
a helper that prints it:

```elisp
(setq teams4e-token-command
      '("my-token-helper" "graph-token"))
```

That command is a placeholder for your own helper, not a bundled executable.
The helper prints either a raw token or a JSON object with `access_token` and
optionally `expires_at`; teams4e invokes it directly without a shell. The
existing integration continues to handle login and refresh.

There is also a read-only credential-file interface. If an MCP service exposes
operations but not tokens, you can write a backend adapter around those tools.
That adapter is an extension point, not an included universal MCP connector.
An existing MCP or DavMail login alone is not enough: you need compatible
Graph access or the corresponding adapter. This reuses approved access; it
does not bypass tenant policy or permissions.

[Authentication guide](https://github.com/guibor/teams4e/blob/main/AUTHENTICATION.md)

You can try the UI without an account:

```elisp
(package-vc-install "https://github.com/guibor/teams4e")
(require 'teams4e)
(setq teams4e-mock-mode t)
(teams4e)
```

The mock has synthetic conversations and meetings and makes no Graph requests.
Live use needs a work/school account and a compatible token source. Requirements
are Emacs 29.1+ and Python 3.10+, with no third-party Python packages.

This is a young, unofficial client. Calls and screen sharing stay in Teams,
and the meetings workspace is not a complete Outlook replacement. The automated
tests run without a tenant; permissions and payloads still vary in live use.

I'd especially welcome feedback on the Emacs workflow, accessible keybindings,
and adapters for other existing Microsoft 365 integrations. Please use synthetic
examples rather than workplace messages or tokens in public issues.
