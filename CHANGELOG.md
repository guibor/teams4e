# Changelog

## Unreleased

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
