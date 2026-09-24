# r/emacs announcement draft

Status: draft only. Nothing in this file has been posted.

## Title

teams4e: a mu4e-inspired Teams client with Org-mode replies

## Post

What I wanted from Teams was the workflow I already liked in mu4e: choose a
bookmark, scan headers, read in one pane, mark things for action, reply, and
move on. Not another browser tab, and not a new buffer for every chat.

So I built **teams4e**, a native Emacs client for Microsoft Teams. Think
**mu4e-style conversation triage, with replies written in Org mode**.
It is not a mu4e backend or a terminal UI wrapper; Emacs owns the interface,
and a small Python backend talks to Microsoft Graph.

[Repository, real Emacs demo, and setup](https://github.com/guibor/teams4e)

### What feels like mu4e?

- **Headers plus one reader.** Open a conversation beside the list, then move
  to another without accumulating chat buffers. Conversation navigation and
  actions still work from the reader. `j`/`k` navigate conversations;
  `M-j`/`M-k` navigate their messages.
- **Bookmark-driven views.** `b t` opens Today; `b m` opens Meetings.
  Custom bookmarks accept queries or Lisp predicates. `F` adds unread-only
  to the current view, and another `F` removes it.
- **Mark, then execute.** Queue actions across conversations and apply them
  with `x`, or select conversations for a bulk action. Opening a chat does
  not mark it read by default.
- **A separate compose buffer.** `R` replies, `c` composes, and
  `C-c C-c` sends. Drafts are recoverable.

The analogy is about the workflow, not identical bindings or mail semantics.
Here you usually triage a whole conversation; `r` and `i` queue mark-read,
not refile. mu4e itself is not required.
[The README explains the mapping](https://github.com/guibor/teams4e#the-mu4e-analogy).

### Write the reply in Org, not in a web textbox

Org is the **actual major mode** of the draft, not just somewhere to capture
a conversation afterward. Use your usual Org editing commands for emphasis,
lists, links, tables, and code blocks. A reply can look like this:

```org
*Quick update*

- *Done:* the pagination fix.
- *Next:* review [[https://example.org/review][the notes]].
```

On send, teams4e converts it to HTML. People in Teams get formatted text and
links, not raw Org markup. The composer sits below the reader so the recent
exchanges remain visible while you type. Participant `@` mentions and
attachments are supported too.

Org is the default and uses Emacs's built-in exporter. Prefer Markdown?
Set `teams4e-compose-editor` to `'markdown` and install markdown-mode plus
Pandoc. `'text` keeps the original plain/direct-HTML editor.
Failed conversions keep the draft; Org export does not execute Babel code.

### Other useful pieces

- **Local snooze:** `z` snoozes, `Z` chooses a wake time, and `b s` shows
  snoozed conversations.
- **Reading and capture:** images, attachments, links, compact Org action
  capture with source metadata, complete available thread exports to Markdown,
  link-hint, and whole-message expand-region selection.
- **Meeting context:** upcoming meetings by start time, intervals, location,
  participants, RSVP, join, and participant availability for proposing a new
  time, subject to calendar permissions.
- **Optional Agent Shell integration:** rich incoming-message rendering
  without starting an agent; explicit thread analysis or an ongoing
  conversation about open requests and next actions. Ordinary reading does
  not start AI or send content to an agent.

### The practical question: how does login work?

In a managed organization, registering another Entra app may not be an option.
teams4e can reuse compatible access from an **already approved** Microsoft 365
integration, such as an OAuth broker, CLI/TUI, or MCP-backed service.
It does not implement another device-code login.

If that integration can provide a fresh delegated Graph token, configure:

```elisp
(setq teams4e-token-command '("my-token-helper" "graph-token"))
```

That is a placeholder for **your** helper, not a bundled command. It prints
a raw token or JSON containing `access_token` and optionally `expires_at`.
The existing integration still owns login, consent, and refresh.

There is also a read-only credential-file interface. If an MCP service exposes
tools but not tokens, you can implement a backend adapter. No universal MCP
adapter is bundled: an arbitrary MCP or DavMail login does not automatically
work. This reuses approved access; it does **not** bypass tenant policy or
grant extra permissions.

[Authentication guide and adapter contract](https://github.com/guibor/teams4e/blob/main/AUTHENTICATION.md)

### Try it without a company account

```elisp
(require 'package-vc)
(package-vc-install "https://github.com/guibor/teams4e")
(require 'teams4e)
(setq teams4e-mock-mode t)
(teams4e)
```

The mock runs the real UI with synthetic conversations and no Graph requests.
The README GIF shows actual graphical Emacs captures in Moe Dark.
Requirements: Emacs 29.1+ and Python 3.10+, with no third-party Python packages.
Spacemacs, Evil, and AI services are optional.

This is a young, unofficial client. Calls and screen sharing stay in Teams;
the meeting view is not a complete Outlook replacement. Automated tests
cannot validate every tenant's permissions or payloads.

I'd welcome feedback from mu4e users on the workflow, and from anyone using
plain Emacs or other approved Microsoft 365 integrations. Please use synthetic
examples, not workplace conversations or credentials, in public reports.
