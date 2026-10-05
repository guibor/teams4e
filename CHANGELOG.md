# Changelog

## Unreleased

- Highlight real free slots separately from free/following invitations. Add a
  foldable day summary with free intervals and total duration, unanswered
  invitations, conflicts, tentative/accepted meetings, and organizer events.
  Compact lists exclude non-attending entries; RSVP actions reuse canonical
  events. Folding a summary never hides its day's timeline.

- Remove calendar day folding. TAB now toggles conflict groups only and does
  nothing elsewhere in the agenda. Ignore old day-fold state during live updates;
  keep all days visible and preserve conflict actions and `t` recentering.

- Fold calendar days and conflict groups with `TAB`. Expanded conflicts show
  each meeting with direct invite, RSVP, availability/rescheduling, and Outlook
  actions using canonical event IDs. Retain expansion through redraws and filters;
  keep conflict counts visible on closed days. `t` unfolds today and recenters
  without refreshing a loaded range; TAB/RET/t work in Evil normal and motion.

- Fix calendar invite display with Spacemacs/window-purpose by passing a correctly
  structured display action; test opening and reusing the reader with Purpose.
  Make H/L navigation explicit in Evil normal/motion states, center on highlighted
  day headings, and use stored calendar dates rather than Org date-reader calls.
- Show exact calendar overlap intervals and matching event labels, including
  filtered-out conflicts. Exclude free/declined/cancelled time and touching
  endpoints; link directly between overlapping invites in the reusable reader.

- Center the independent agenda on now; add event/day navigation and Org date
  selection (`j/k`, `h/l`, uppercase aliases, `t`, `.`). Color availability
  independently of RSVP, subdue free events, and derive conservative working-hour
  gaps from the complete unfiltered snapshot. Preserve selected multi-day rows.
  Add direct invite-to-chat lookup (`T`) and time-proposal access (`r`); move the
  agenda/reader join binding from `J` to `v`. All faces and work hours are options.
  Reuse the availability workspace to reschedule an organizer's timed occurrence
  with a start/end-only PATCH; block whole-series and all-day changes.

- Add an independent calendar workspace with day/week/month agendas, calendar
  selection, on-demand event details, RSVP, availability/time proposals, and Org
  capture. Load calendarView occurrences directly with the existing credentials
  and Outlook request guard, without enumerating or synthesizing Teams chats.
  Add synthetic appointments and all-day/recurring events for offline testing.

- Add `teams4e-switch-to-buffer` to resume existing Teams buffers without
  fetching data, preserving filters, positions and a saved reading layout.
  Prefer unfinished drafts; prefix refresh keeps draft text intact. First
  use opens the inbox normally, and navigation does not trigger auto-preview.

- Load upcoming meetings from one next-14-days calendarView projection matched
  to loaded chats, avoiding per-chat metadata and historical scans. Keep nearest
  recurring occurrences, briefly remember empty matches, and preserve partial
  results on pagination errors. Configure the horizon with
  `teams4e-meeting-upcoming-days` (up to 60).
- Coordinate Outlook envelopes across backend workers and cap their JSON batches
  at two items to reduce MailboxConcurrency throttling. Older concurrency
  overrides cannot bypass this guard; Teams chat batching stays unchanged.

- Open meeting availability on the original day with consecutive, duration-preserving
  slots. Add availability and proximity rankings, local previous/next-day navigation,
  full time intervals, and aligned participant gutters. Unknown schedules never count
  as free; day/view changes reuse the loaded schedules.

- Anchor every inbox column boundary, including exactly full and truncated
  cells, and widen meeting-column separators to keep unread bold rows aligned.

- Pace persistent-backend Graph reads with a shared 40-operation/10-second
  budget, counting individual JSON batch items. Share 429 cooldowns across
  workers, honor Retry-After seconds and dates, and retry only throttled
  batch items. Report exhausted calendar throttling as retriable.
- Accept meetings without an organizer response when the note is blank,
  including whitespace-only notes. Notes still send a response; tentative,
  decline, and propose-new-time behavior is unchanged.

- Raise default chat coverage to 300, opened-thread history to 100 messages,
  meeting batches to 64, and calendar lookahead to 60 days. Keep automatic
  previews at 50 and remove the default message date cutoff.
- Read newest-created messages by default, matching the terminal client;
  retain modified-date ordering for explicit date-window and sync requests.
- Start the live thread request alongside its SQLite cache read. Ignore
  late cache results after a live response or a chat switch.
- Select the latest end immediately on explicit reopen, respecting display
  order. Defer calendar enrichment outside meeting views/readers and retain
  matching calendar context for five minutes.

- Resolve recurring calendar links to the current or nearest future occurrence,
  including rescheduled exceptions; skip cancelled and declined occurrences.
- Choose the nearest calendar match independently of parallel response order,
  follow future calendar pages, and search the full 45-day lookup window.
- Continue explicit meeting enrichment through all loaded chats in bounded
  batches; clear stale occurrences when a series has no upcoming instance.
- Document opening chats outside recents and the meeting view's coverage limits.

- Make Org the default compose editor, with Markdown and legacy text options;
  send rendered HTML while preserving source-format drafts and native mentions.
- Keep the transcript visible above replies and preserve the reader's end
  position across cache, network, and meeting-context refreshes.
- Restructure the README around evaluation, approved authentication, and daily
  use; move the complete workflow reference to `USAGE.md`.
- Add security/data-handling guidance and a scoped public-readiness review;
  refresh the draft r/emacs announcement with composition and agent workflows.

- Render native forwarded-message attachments using their original content,
  sender, and date; include every reference in reader, copy, and Markdown export.
- Restore editable message forwarding with `a f`, preserving destination drafts,
  source links, and attachment links; sending remains explicit.
- Add complete-message expand-region selection and `M-h` in both readers.
  Restore `M-w` to normal region copying instead of Org capture, including Evil.
- Add account-free forwarding, expand-region, and Evil copy regression tests.

- Made rendered message links discoverable by link-hint, including older
  Agent Shell renderers, and exposed attachment/card URLs for link copying.
- Fixed complete thread export and agent analysis rejecting duplicate message
  IDs across history pages: validate the backend's raw row count before
  deduplicating, while still rejecting missing rows and incomplete pagination.

- Added an optional ongoing Agent Shell companion with bounded change detection,
  draft/busy protection, pause/resume, source-linked conversation evidence,
  opt-in linked meeting context, and explicitly selected reference files.
- Added account-free companion regression tests and byte compilation to CI.

- Made the agent-analysis prompt configurable, with a general default that
  requires no separately installed skill. Existing skill prompts remain usable
  through `teams4e-thread-analysis-prompt`.
- Expanded public installation/update instructions, snooze examples, account-free
  walkthroughs, contribution guidance, and an r/emacs announcement draft.

- Matched the terminal client's snooze workflow: `z` uses a configurable
  default duration, `Z` offers short/workday/custom choices, and `b s` shows
  wake-sorted snoozed chats that stay out of every ordinary and unread view.
- Added `F` as the direct unread-only toggle while retaining `U`, `b u`, and
  `M-F` as compatibility aliases.
- Made read/unread actions optimistic: the inbox updates immediately while
  Graph reconciles in the background, with race-safe rollback on failure.
- Removed the unused message-forwarding command and its keybindings.
- Added chat-aware mention completion: typing `@` in compose lazily loads and
  chooses a current participant, while repeated occurrences use one valid
  Graph mention payload.
- Documented the primary deployment model: reuse an already approved Microsoft
  365 OAuth owner through a token command, read-only credential record, or
  custom MCP/broker backend adapter, without claiming to bypass tenant consent.
- Added optional Agent Shell Markdown rendering for rich message bodies, including
  lists, checkboxes, syntax-highlighted code, and aligned GFM tables.
- Reworked the public README around account-free evaluation, portable
  configuration, authentication boundaries, daily workflows, and limitations.
- Replaced the remaining personal test and demo identity with reserved synthetic
  example data.
- Reduced the initial focused-chat request to one 50-message Graph page, kept
  deeper history behind `L` and `G`, and added transcript-render timing to the
  redacted performance report.
- Made chat replies use the same explicit `messageReference` attachment flow as
  the TUI, with a bounded plain-text quote preview, avoiding malformed quote
  payloads from the previous reply action.
- Added distinct activity bookmarks for the local calendar day (`b t`), the
  rolling last 24 hours (`b 2`), and the rolling last 7 days (`b w`).
- Preserved a conversation's read/unread state across sending, while retaining
  `C-c C-c` as the native compose-buffer send binding.
- Added a redacted in-memory `teams4e-performance-report` covering backend
  operations and Emacs inbox and transcript rendering, with configurable
  artificial mock latency for account-free responsiveness testing.
- Removed the duplicate cache-first inbox redraw, coalesced adjacent member and
  calendar completion redraws, and reused canonical chat objects across fresh
  list responses.
- Preserved matching linked meeting context briefly across cache/live chat
  replacement, while explicit refresh, expiry, or changed event linkage still
  invalidates it.
- Made `U`, `b u`, and `M-F` reversibly toggle the composable unread
  overlay without replacing the active bookmark or query; `b a` remains the
  explicit reset. Sessions left in the former standalone unread-query state can
  exit it with the same toggle.
- Batched missing/stale meeting chat metadata reads in groups of 20 and split
  meeting headers into fixed When, Conversation, Response, and Location
  columns with stable left-to-right table layout.
- Batched direct calendar-event reads through Microsoft Graph JSON batches of
  at most 20 requests, collapsed stale or missing event fallbacks into one
  shared bounded `calendarView` scan, and stopped retrying failed enrichment
  rows recursively within the same Emacs refresh.
- Made chat export and agent analysis use a dedicated live history operation
  that exhausts Graph pagination, verifies returned count/completion metadata,
  records page count and oldest/newest timestamps in Markdown, and refuses to
  describe a partial offline cache as complete.
- Grouped reader and Markdown messages by the displayed local date instead of
  the raw UTC date. Reader day rules are stronger, message headers use compact
  local times, bodies have a consistent inset, and Markdown has readable day
  headings plus export count/range metadata.
- Replaced the generic calendar-unavailable label with actionable login,
  permission, missing-event-link, or diagnostic states while retaining the
  redacted backend detail in `*M365 Errors*`.
- Repaired `b`/`B` after live Evil Collection reloads and made `b a` return to
  an unfiltered All Chats view by clearing the unread-only overlay.
- Resolved built-in bookmark symbols before callable symbols, preventing
  Emacs/compat's two-argument `all` function from intercepting `b a` while
  retaining symbol-function predicates for custom bookmarks.
- Based unread detection and local read-override expiry on the actual last
  message rather than `lastUpdatedDateTime`, so calendar, membership, and topic
  changes do not create false unread rows.
- Required a complete last-message preview before a calendar-created meeting
  chat may appear in message or unread views.
- Made logged-out OAuth and calendar-enrichment failures visible in headers and
  `*M365 Errors*` instead of leaving an unexplained empty meeting view.
- Recovered automatically when a live Quelpa upgrade removes the versioned
  package directory still referenced by `teams4e-backend-program`, without
  masking unrelated invalid custom backend paths.

## 0.1.0 - 2026-08-08

- Initial standalone package extraction.
- Renamed the project and public Lisp namespace from `msteams` to `teams4e`
  before public release, with Lisp, executable, and environment compatibility
  entry points for private configs.
- Mu4e-style headers, singleton reader, compose, bookmarks, marks, and bulk
  actions for Teams chats and channels.
- External short-lived-token command and read-only credential-store adapters.
- SQLite cache, offline search, background sync, and persistent mock tenant.
- Inline images, attachments, Org capture, complete Markdown export, and
  optional `agent-shell` analysis.
- Linked calendar event metadata and an upcoming-meetings view.
- Meeting-only `a p` flow with availability-ranked alternatives, custom and
  unrestricted search windows, manual fallback, and real Outlook new-time
  proposals without a duplicate calendar model.
- Expanded meetings into a calendar-light daily workspace: next-meeting and
  overlap summaries, response-needed state, RSVP/join/calendar actions, a
  participant availability matrix, working hours, and a complete returned
  calendar-block sheet with private subject/location masking.
- Added `getSchedule` batching for up to 20 participants per Graph request,
  soft partial-permission failures, and one-shot accept/tentative/decline
  mutations.
- Message views now order by the actual last-message timestamp and omit the
  meeting interval column; meeting-only views add that column, order by event
  start, and show complete start/end intervals.
- Message views omit meeting chat stubs with no usable last message, while
  meeting-only views retain them and resolve missing calendar event IDs through
  a bounded chat-metadata fallback.
- Lowercase `r` and `i` both queue mark-read; reply remains uppercase `R`.
- Deferred Evil bindings use the runtime `evil-define-key*` API so compiled
  package startup does not call a macro as a function.
- Added a minimal chat/cursor logo and an account-free Moe Dark README demo.
