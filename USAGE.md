# Using teams4e

The complete workflow reference. Start with the [README](README.md) for
installation and [AUTHENTICATION.md](AUTHENTICATION.md) for live access.

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
| `o` / `O` | Open in browser / native Teams app |
| `b` | Choose a bookmark |
| `F` | Toggle unread-only on top of the current view |
| `U`, `b u`, or `M-F` | Compatibility aliases for unread-only |
| `z` / `Z` | Snooze for the default duration / choose a wake time |
| `M-U` | Undo the last completed action |
| `m` | Deferred-mark prefix |
| `x` | Apply deferred marks |
| `M` / `T` | Select one / all visible conversations |
| `X` | Run a bulk action |
| `a` | Current-conversation action prefix |
| `a a` / `a A` | Capture a summary / complete thread to Org |
| `a f` | Forward the message at point to another chat for review |
| `a e` / `a y` | Export / copy complete Markdown |
| `a g` | Export and analyze with Agent Shell |
| `a p` | Open participant availability |
| `a v` / `a J` | RSVP / join |
| `a C` | Open the linked Outlook event |
| `G` / `L` | Load complete history / load more |
| `M-j` / `M-k` | Next/previous message in the transcript |
| `M-h` | Select the complete message at point |
| `M-w` | Copy the selected region (ordinary Emacs behavior) |
| `q` | Close the reader or restore the previous layout |

In a chat compose buffer, type `@` to choose one of the conversation's
participants and insert a real Teams mention. `C-c C-m` invokes the same
command. Use `C-q @` when you need a literal at-sign instead.

Forward from a chat or channel reader with `a f` (or
`M-x teams4e-forward-message`). Choose a destination chat, review the editable
text, then send. This is a readable text forward like the TUI workflow, not a
native Teams forwarding badge: it includes sender, date, available source URL,
forwarded/quoted content, and attachment links. It does not reupload files or
grant access to protected links. An existing destination draft is preserved
and the forward is appended.

With expand-region installed, your existing `er/expand-region` binding includes
a complete message as an expansion step in chat and channel readers. `M-h`
selects that message directly; `M-w` copies the selection, including in Evil.
Date separators and neighboring messages are excluded.

### Writing Messages

New replies and messages use **Org mode** by default. Write normal Org
emphasis, links, lists, tables and code blocks; teams4e sends a rendered HTML
fragment, not the Org source. `C-c C-c` sends and `C-c C-k` aborts.
Mentions and attachments work in every editor, and Evil starts in Insert state.

Choose the default for **new** drafts:

```elisp
(setq teams4e-compose-editor 'org)       ; default, built into Emacs
;; (setq teams4e-compose-editor 'markdown) ; markdown-mode + Pandoc
;; (setq teams4e-compose-editor 'text)     ; previous plain/direct-HTML editor
```

For Markdown, install the Emacs `markdown-mode` package and
[Pandoc](https://pandoc.org/installing.html) (`brew install pandoc` on macOS).
It must be available on Emacs's executable path, or set
`teams4e-compose-pandoc-program` to its full path. Conversion failures keep
the draft and never fall back to sending raw markup. Org export does not
execute Babel code and rejects includes, setup files, macros and calls.

`C-c C-b`, `C-c C-i`, `` C-c C-` `` and `C-c C-l` insert bold, italic,
code and link markup for the selected editor. The legacy editor alone uses
`C-c C-h` to switch between plain text and direct HTML.

Draft recovery keeps the source and editor together. Older saved drafts stay
in the legacy editor rather than being reinterpreted as Org.

When replying from a transcript or chat inbox, the editor opens **below the
conversation**, leaving recent exchanges visible above. Sending or discarding
closes only that editor split, never the frame. On very small frames the
normal buffer display is used instead. Customize
`teams4e-compose-window-height` (default `0.4`) for the editor's share.

Opening a chat jumps to the absolute end. Cache refreshes keep you there
until you move up; search results still jump to the requested message.
Sending preserves the conversation's prior read/unread state.

Use `M-x teams4e-dispatch` or `a ?` when you do not remember a key.
Ordinary Emacs and optional Evil maps expose the same operations.

## Views That Compose

Bookmarks filter one canonical chat list. They do not create duplicate inboxes
that need synchronization.

| Bookmark | View | Order |
| --- | --- | --- |
| `b i` | Relevant inbox | Newest message first |
| `b a` | All active chats; clear overlays | Newest message first |
| `b u` | Toggle unread-only in the current view | Preserve current order |
| `b s` | Snoozed chats, with wake times | Earliest wake first |
| `b t` | Activity today in local time | Newest message first |
| `b 2` | Activity in the last 24 hours | Newest message first |
| `b w` | Activity in the last 7 days | Newest message first |
| `b m` | Upcoming and active meetings | Earliest start first |
| `b M` | All meeting chats | Earliest known start first |

Active snoozes are hidden from ordinary views, including All and its unread-only
overlay. `b s` is the explicit Snoozed view; it replaces the message-time column
with each conversation's wake time. You can apply `F` there too to see only
unread snoozed chats. In any view, a second `F` removes the unread overlay.

For example, `b t`, then `F`, shows today's unread conversations; another `F`
returns to all of today's conversations. `b a` clears the view and unread
filters, but keeps active snoozes hidden.

`z` applies `teams4e-default-snooze-minutes` immediately (three hours by
default). `Z` offers 10 minutes, one hour, three hours, end of workday,
tomorrow morning, next week, a custom date/time, and unsnooze. Tomorrow and
next week use `teams4e-workday-start` (07:00 by default); end of workday uses
`teams4e-workday-end` (18:00 by default) and wakes the next morning when the
workday has already ended. Snoozing is local, persistent, and does not change
Teams read state. Expired snoozes return on the next view redraw or refresh;
there is no separate alarm notification or cross-device snooze synchronization.

| After `Z` | Wake time |
| --- | --- |
| `m` / `1` / `3` | In 10 minutes / 1 hour / 3 hours |
| `e` | End of workday, or next morning if it has ended |
| `t` / `w` | Tomorrow / seven calendar days from now, at workday start |
| `d` | Choose a date and time |
| `u` | Unsnooze |

Times use Emacs's local timezone. Workday settings are user preferences; the
snooze menu does not consult calendar working hours or skip weekends.

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

Rendered message links and URL attachments support
[link-hint](https://github.com/noctuid/link-hint.el) without extra Teams-specific
configuration. Use your existing shortcut or `M-x link-hint-open-link`;
`M-x link-hint-copy-link` copies the destination. After updating, refresh an
already open thread to rebuild its rendered links.

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
Agent analysis is an explicit `a g` action; ordinary reading does not start an
agent. The configured agent can read the exported conversation, so use a
provider appropriate for that content.

The default prompt asks for decisions, questions, and action items without
requiring a custom skill. Customize `teams4e-thread-analysis-prompt` to supply
your own instructions; `%s` expands to the absolute Markdown path:

```elisp
(setq teams4e-thread-analysis-prompt
      "Read %s and extract decisions and next actions with owners.")
```

For an agent with a separately installed `thread-analysis` skill, the previous
prompt is still available as configuration:

```elisp
(setq teams4e-thread-analysis-prompt "$thread-analysis of this thread: %s")
```

## Ongoing Interaction Companion

`M-x teams4e-companion` opens a reusable Agent Shell conversation about what
needs your response, what you are waiting on, and sensible next actions. It
checks Teams every ten minutes by default, sends changed context when the agent
is idle, and lets you correct its understanding in conversation.

There is no generated task ledger. Calendar context and selected Org/Markdown
files are opt-in. Monitoring is bounded, visible, and pausable; read state is
never treated as proof that an obligation is complete.

See [COMPANION.md](COMPANION.md) for setup, keys, scope, and the mock walkthrough.

