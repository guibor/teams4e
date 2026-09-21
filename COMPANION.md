# Teams Companion

`M-x teams4e-companion` opens one ongoing Agent Shell conversation about your
Teams interactions. Return to it during the day to discuss open questions,
commitments, and what to do next. It receives fresh evidence as you respond
in Teams or teams4e.

The agent is asked to distinguish:

- **Your next actions:** requests or commitments that may need your response.
- **Waiting on others:** questions you have asked or dependencies still open.
- **Uncertain:** cases where ownership or completion needs your judgment.

Its recommendations are conversational inferences, not a second task system.
Tell it "I already covered this in the meeting", "I'm waiting for a decision",
or "This isn't mine". Those corrections stay in the agent conversation.
Reading a message or sending a reply does not automatically close a commitment.

## Start

Install and configure [Agent Shell](https://github.com/xenodium/agent-shell)
and one of its agents, then select the same identifier used for thread analysis:

```elisp
(setq teams4e-thread-analysis-agent 'codex) ; Or another registered agent.
```

After Teams is connected:

```text
M-x teams4e-companion
```

Starting a new companion enables monitoring by default. A check runs every ten
minutes while Emacs and the companion buffer remain alive. Checks fetch bounded
Teams data; unchanged conversations do not cause another agent submission.
A change in local calendar date also prompts a fresh assessment.

This sends sampled Teams content to your chosen agent. Calendar and task-file
sharing are separately opt-in. The companion makes only read requests to Teams;
it does not mark chats read, send replies, or update calendars.

The normal Agent Shell input stays available. Ask, for example:

> What are the three things worth doing before lunch?
>
> I replied to the release discussion. What is still waiting on me?
>
> That request belongs to someone else; keep it out of my recommendations.
>
> Compare the outstanding requests with the task file I attached.

## Everyday Keys

These bindings apply only in the companion's Agent Shell buffer:

| Key | Action |
| --- | --- |
| `C-c t r` | Check for changes now |
| `C-u C-c t r` | Reread the full bounded sample and request a fresh briefing |
| `C-c t p` | Pause/resume monitoring |
| `C-c t a` | Attach a saved local Org, Markdown, or text file |
| `C-c t d` | Stop sharing an attached file in future updates |
| `C-c t o` | Choose and open a Teams conversation |
| `C-c t s` | Show monitor state and last successful check |

The mode line says `Teams:watch` or `Teams:paused`. Pausing cancels pending
collection and queued updates. It does not cancel an agent turn already
submitted; use Agent Shell's normal interrupt command for that.

Updates wait while the agent is busy or you have unsent text at its prompt.
Only one pending snapshot is retained. Background delivery preserves your
window layout and focus.

`M-x teams4e-companion` returns to the existing buffer.
`C-u M-x teams4e-companion` starts a fresh conversation and resets the
delivery markers. Killing the companion buffer stops monitoring. Automatic
reattachment to a restored agent session after restarting Emacs is not yet
implemented.

## Scope and Cadence

```elisp
(setq teams4e-companion-interval 600
      teams4e-companion-chat-limit 12
      teams4e-companion-message-limit 30
      teams4e-companion-query 'inbox)
```

The query is independent of the currently displayed bookmark and unread
overlay. The default relevant inbox includes read conversations but excludes
muted, handled-current, and snoozed conversations. The most recently active
matching chats are sampled from the bounded chat metadata list. Channels are
not included in this first version.

A check sends a factual inventory plus recent excerpts for changed conversations.
It does not export every complete thread each time. Old edits that do not
change the last-message preview may require a forced refresh. Conversations
outside the sample remain outside its coverage, even if discussed earlier.

To start with manual checks only:

```elisp
(setq teams4e-companion-auto-watch nil)
```

The effective monitoring interval is at least 60 seconds. You can customize
`teams4e-companion-instructions` for preferred tone and priorities.

## Share Calendar and Tasks

To include linked event details from a bounded selection of meeting chats:

```elisp
(setq teams4e-companion-include-calendar t)
```

Then refresh. This reuses the Teams meeting backend and its existing calendar
permissions. It includes returned event data such as times, attendees, and
location. It is **not your complete calendar** and cannot establish that an
unlisted time is free. Permission failures remain explicit unknowns.

Use `C-c t a` to attach a particular saved task or calendar-export file, or set:

```elisp
(setq teams4e-companion-context-files
      '("~/Documents/tasks.org"
        "~/Documents/project-notes.md"))
```

There is no automatic scan of `org-agenda-files`, note directories, or private
configuration. At most eight explicitly listed local files are read, up to
`teams4e-companion-context-limit` bytes each (24,000 by default). Unsaved buffer
edits are not included. Files are reread on each check; changed contents trigger
an update. Omitted content is labeled.

Removing a reference prevents future inclusion. It does not erase information
already submitted to the agent.

## Data and Limitations

The companion keeps delivery fingerprints, not inferred task states. Its only
generated content file is the latest `context.md` in a private directory for
each session under `teams4e-companion-directory`. The directory has mode 0700
and the file mode 0600. Snapshots contain conversation content and are retained
for inspection; they are not an Org ledger. Old session directories are not
automatically deleted.

`teams4e-companion-snapshot-limit` caps snapshot text at 120,000 characters,
plus an explicit truncation notice. More sources or larger samples can exceed
that budget. Agent conversation history and retention are controlled by Agent
Shell and your selected provider.

The prompt requests discussion and recommendations, not autonomous actions.
It does not change your agent's tools, permissions, or sandbox. Use an agent
configuration appropriate for the content you choose to share.

Monitoring pauses when account/provider settings change. Start a fresh companion
for a different identity so the package does not mix accounts in an ongoing
conversation. Authentication failures or failed chat reads must not be
interpreted as an empty inbox or completed work.

## Account-Free Testing

Enable the bundled mock before starting the companion:

```elisp
(setq teams4e-mock-mode t)
```

Teams reads then use synthetic local data. The Agent Shell itself still uses
your real configured agent. No Teams account is needed to try a conversation,
send a mock reply, and ask how the situation has changed.

`make test` also runs companion tests without any agent service. They cover
draft protection, busy agents, delivery deduplication, cancellation, account
changes, bounded reference files, optional calendar failure, and a real
subprocess roundtrip through the mock backend that detects an outgoing reply.
