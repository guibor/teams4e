# r/emacs announcement draft

Status: draft only. Nothing in this file has been posted.

## Title

teams4e: a Microsoft Teams client for Emacs, inspired by mu4e

## Post

Hi everyone,

I've been working on **teams4e**, an Emacs client for Microsoft Teams.
The motivation is similar to what I get from mu4e: correspondence can be
searched, acted on, and connected to my Org files without leaving Emacs.

[Repository and demo](https://github.com/guibor/teams4e)

The mu4e influence is more than the headers/message layout. There are
configurable bookmarks, actions on the conversation at point, deferred marks,
and bulk operations. A chat that needs follow-up can become an Org entry with
a source link, rather than remaining unread just so I remember to deal with it.

Some of the main features:

- **Bookmarks and filtering.** Define views with query strings or Lisp
  predicates. Inbox, Today, Meetings, and Snoozed are included. An unread-only
  restriction can be toggled on top of the current view without losing it.
- **Org capture.** Capture a compact entry with the conversation title, source
  link, dates, and a short message excerpt. Edit it into a TODO, then use your
  normal Org scheduling and refiling workflow. The destination file is
  configurable. Full-thread capture and Markdown export are separate actions.
- **Org-mode composition.** Replies use actual `org-mode` by default, with
  your usual editing commands for lists, links, tables, and code blocks. On
  send, the source is exported to HTML; Teams recipients do not see raw Org
  markup. Markdown and plain text are alternatives. The draft opens below
  recent messages, and supports recovery, participant mentions, and attachments.
- **Reading and triage.** One reusable reader, read/unread marks, bulk actions,
  local snooze, images, attachments, and links. Opening a chat does not mark
  it read by default, though that can be changed.
- **Meetings.** Start-time ordering, time and place, participants, RSVP, joining,
  and an availability view for proposing a new time, subject to permissions.

These are Emacs commands, not a prescribed set of shortcuts. For example,
`teams4e-capture-current-summary` is bound to `a a` by default and
`teams4e-reply` to `R`; invoke them through `M-x` or bind them differently.
The README documents the commands, default bindings, keymaps, and customization
options. A bookmark is ordinary configuration:

```elisp
(with-eval-after-load 'teams4e
  (add-to-list 'teams4e-bookmarks
               '(:name "Project Atlas" :query "name:Atlas" :key ?p)
               t))
```

It is not a mu4e backend or an attempt to reproduce every mu4e feature. The
usual unit is a Teams conversation, not a mail message. Capture uses editable
package-provided Org entries; mu4e's Org link types and capture-template fields
are not implemented.

There are optional integrations with link-hint, expand-region, and Agent
Shell. Agent Shell can supply rich message rendering without starting an
agent; thread analysis and an ongoing discussion of outstanding requests are
explicit, separate commands. Ordinary reading does not invoke AI.

**Authentication:** teams4e does not register
another Entra application or implement its own device-code login. It can
consume a delegated Graph token from an existing approved broker, CLI/TUI, or
compatible MCP-backed integration:

```elisp
(setq teams4e-token-command '("my-token-helper" "graph-token"))
```

This is a placeholder for your own helper. It must print a raw Graph token or
JSON with `access_token` and optionally `expires_at`; the existing
integration owns login and refresh. A read-only credential-file interface is
also supported. Services that expose tools but not tokens need a backend
adapter; there is no universal MCP adapter bundled. An arbitrary MCP or
DavMail login is not sufficient, and tenant consent and policy still apply.

[Authentication setup and adapter contract](https://github.com/guibor/teams4e/blob/main/AUTHENTICATION.md)

You can try the real frontend with a bundled mock tenant, without an account.
It requires Emacs 29.1+ and Python 3.10+, with no third-party Python packages.
mu4e, Evil, and Spacemacs are not dependencies. The README includes installation,
an account-free example, and actual Emacs captures using synthetic data.

This is still a young, unofficial client. Calls and screen sharing remain in
Teams, and the meeting view is not a full calendar replacement. I'd welcome
feedback on the Org workflow, customization, and integration with approved
Microsoft 365 tools. Please use synthetic data in public reports.
