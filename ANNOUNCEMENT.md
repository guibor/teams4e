# r/emacs announcement draft

Status: draft only. Nothing in this file has been posted.

## Title

teams4e: Microsoft Teams in Emacs, with mu4e-style triage and Org replies

## Post

I wanted to deal with Teams conversations the way I deal with mail in Emacs:
scan headers, read in one pane, reply, capture an action, and move on.
So I built **teams4e**, a native Emacs client with a mu4e-inspired workflow.

[Repository, demo, and setup](https://github.com/guibor/teams4e)

It is not a browser embedded in Emacs or a terminal UI wrapper. Emacs owns the
interface; a small Python backend talks to Microsoft Graph.

**The part that may matter most at work is authentication.** teams4e does not
ask you to register another Entra app or run a new device-code login. Instead,
it can reuse compatible access from an *already approved* Microsoft 365
integration: an OAuth broker, CLI/TUI, or an MCP-backed service.

If that integration can provide a fresh delegated Graph token, point teams4e
at a helper:

```elisp
(setq teams4e-token-command '("my-token-helper" "graph-token"))
```

That is a placeholder for **your** helper, not a command shipped with the
package. It prints a raw token or JSON containing `access_token` and
optionally `expires_at`. Your existing integration keeps responsibility for
login, consent, and refresh.

There is also a read-only credential-file interface. If an MCP service exposes
tools but not tokens, you can implement a backend adapter without exporting its
tokens. No universal MCP adapter is bundled, and an arbitrary MCP or DavMail
login does not automatically work. This reuses approved access; it does **not**
bypass tenant policy or grant additional permissions.

[Authentication guide and adapter contract](https://github.com/guibor/teams4e/blob/main/AUTHENTICATION.md)

On the Emacs side:

- **One reusable reader.** `j`/`k` still move through conversations while it is
  open; `M-j`/`M-k` move between messages. No growing pile of chat buffers.
- **Org replies by default.** Markdown and plain text are options. Org/Markdown
  are converted to HTML on send, and recent exchanges stay visible above the
  composer. Draft recovery, participant `@` mentions, and attachments are included.
- **Triage that composes.** Bookmarks, deferred marks, bulk actions, and a
  reversible unread overlay: `b t` for Today, `F` for today's unread chats,
  another `F` to go back. `z` snoozes; `b s` shows snoozed conversations.
- **Emacs integration.** Compact Org capture with source links, paginated
  Markdown exports, link-hint, and whole-message expand-region selection.
  Agent Shell optionally supplies rich rendering without starting an agent.
- **Meeting context.** Times, location, participants, RSVP, and an availability
  view for proposing another time, subject to calendar permissions.
- **Optional agents.** Analyze one exported thread, or explicitly start an
  ongoing Agent Shell conversation about open requests and next actions.
  Ordinary reading does not start AI or send content to an agent.

You can try the actual UI without a Teams account:

```elisp
(require 'package-vc)
(package-vc-install "https://github.com/guibor/teams4e")
(require 'teams4e)
(setq teams4e-mock-mode t)
(teams4e)
```

The mock uses synthetic conversations and makes no Graph requests.
Requirements are Emacs 29.1+ and Python 3.10+, with no third-party Python
packages. Spacemacs and Evil are optional.

This is a young, unofficial client. Calls and screen sharing stay in Teams;
the meeting view is not a full Outlook replacement. The mock and automated
tests cannot validate every tenant's permissions or payloads.

I'd especially like feedback on the plain-Emacs workflow, accessibility, and
integration with other approved Microsoft 365 tools. Please use synthetic
examples, not workplace conversations or credentials, in public reports.
