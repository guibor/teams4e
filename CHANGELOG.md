# Changelog

## Unreleased

- Repaired `b`/`B` after live Evil Collection reloads and made `b a` return to
  an unfiltered All Chats view by clearing the unread-only overlay.
- Based unread detection and local read-override expiry on the actual last
  message rather than `lastUpdatedDateTime`, so calendar, membership, and topic
  changes do not create false unread rows.
- Required a complete last-message preview before a calendar-created meeting
  chat may appear in message or unread views.
- Made logged-out OAuth and calendar-enrichment failures visible in headers and
  `*M365 Errors*` instead of leaving an unexplained empty meeting view.

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
