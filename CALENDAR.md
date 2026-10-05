# Independent Calendar

`M-x teams4e-calendar` opens your Microsoft 365 calendar without loading Teams
chats. It includes ordinary appointments, focus blocks, all-day and multi-day
events, invitations, and each recurring occurrence in the displayed range.
`teams4e-meetings` remains the chat-oriented meeting view.

## Daily Use

The default is a chronological, day-grouped week agenda. Times use the Emacs
machine's local timezone; week boundaries respect `calendar-week-start-day`.
The time interval has its own fixed-width area, while titles and metadata wrap
rather than being squeezed into narrow columns. Dates are local calendar dates,
so moving by a day across DST does not assume every day has 24 hours.

| Default key | Action |
| --- | --- |
| `j / k`, `J / K`, `n / p` | Next / previous event, skipping gaps |
| `h / l`, `H / L` | Center on the previous / next highlighted day heading; no fetch inside the loaded range |
| `[ / ]` | Previous / next day, week, or month |
| `d / w / m` | Day / week / month agenda |
| `t` | Center on now, or the closest timed row today |
| `.`, `G` | Choose a date using Org's date reader and calendar |
| `TAB` | Fold / unfold a Summary heading or conflict group; no effect on the timeline |
| `RET` | Read an event or activate its action button |
| `/` | Filter subject, location, or organizer; empty input clears |
| `x` | Include / hide declined and cancelled events |
| `c` | Choose a calendar returned by Microsoft Graph |
| `a` | Accept, tentative, or decline |
| `r`, `A` | Availability workspace: propose a time, or reschedule your own event |
| `T` | Open the invite's Teams chat directly, without scanning recents |
| `v` | Join an online meeting |
| `o` | Open the event in Outlook, or the calendar when no event is selected |
| `C` | Org capture: title, link, time, location, and event ID |
| `g` | Refresh the displayed range |
| `q` | Quit the current pane |

First load centers on the ongoing or nearest timed row. Explicit refreshes keep
your selected occurrence and day, including multi-day events; reopening resumes
your position. `t` recenters without fetching when today is already loaded.

The time and availability label use theme-aware faces: `teams4e-calendar-busy`,
`-tentative`, `-out-of-office`, `-elsewhere`, and `-free`. Actual available gaps
use the separate `teams4e-calendar-free-slot` face: bold text with a green-tinted
background and an explicit `[FREE]` label. Free/following invitations remain
subdued, so a non-blocking appointment cannot be mistaken for an available slot.
Free and declined/cancelled events have subdued titles. RSVP remains separate
text: accepting a "free" invitation does not make it look busy.
A `>` marks a timed row covering now when the agenda is rendered.

Free gaps describe **this calendar only**, not all your calendars. Busy,
tentative, out-of-office, and unknown availability block time; free,
working-elsewhere, declined, and cancelled events do not. Overlapping blocks
are merged before gaps are calculated, using the complete unfiltered snapshot.
No gaps are inferred during loading or after an incomplete response.

Overlap summaries appear just below the day heading, with exact intervals and
labels such as `C1`. The affected event titles carry matching labels. This
does not replace their busy/free colors. Back-to-back events do not conflict;
free, working-elsewhere, declined, and cancelled entries are excluded. Tentative
and unknown availability conservatively count as blocking time.

Three-way overlaps show the actual simultaneous count, not misleading pair
counts or transitive groups. Filtering cannot hide the existence of a clash:
summaries say how many affected events are filtered out.

Each day has an independently foldable **Summary**, above its chronological
timeline. It starts open and shows available intervals plus their combined
duration, then **Needs response**, foldable conflicts, **Tentative**, **Accepted**,
and **Organizing**, in that order. Empty meeting groups are omitted. Within each
group, titles follow start time, without repeating time/location details. Titles
open invitations; unanswered and tentative invitations also have a Respond
button. The normal `a`, `r`, `o`, and capture commands work on these rows too.

Unanswered means an attendee invitation with no response, not an ordinary
appointment or an event you organize. Declined, cancelled, free/following, and
working-elsewhere entries are excluded from the summary's meeting lists, even
when `x` exposes them in the timeline. Lists respect the text filter; conflicts
and free slots continue to use the full snapshot. The free-time total sums the
shown slots within your configured working hours and minimum-gap threshold,
not every minute in a 24-hour day. Partial/loading data never claims free time.

`TAB` on the Summary heading hides only its summary; the day and timeline stay
visible. Conflicts start collapsed and keep their own expansion when the summary
is closed and reopened. On day headings, ordinary event rows (including summary
meeting lists), free gaps, or blank lines, TAB does nothing. Folding and local
filtering do not fetch anything. `H/L` reach day headings, `j/k` navigate timeline
events and expanded conflict details, and `t` recenters on now.

Expand a conflict to see **every involved meeting**, including filtered-out
partners, with its full interval, availability, and RSVP state. Click its title
(or use `RET` on the meeting row) to read the invitation. Use `r` for
availability/rescheduling, `a` to respond (including decline), or `o` for Outlook.
The same actions are buttons under each meeting; `RET` activates a button at
point. Your own events offer rescheduling; received invitations offer time
proposals and RSVP. Folding or browsing never changes an invitation. Successful
responses and moves update the original snapshot and recompute the conflicts;
a proposal alone does not resolve a clash until the organizer changes the time.

The invite reader also links to overlap partners and their exact shared
intervals, reusing the same pane.
As with free gaps, overlap detection covers only the loaded selected calendar.

![Expanded calendar conflict with per-meeting actions in real Emacs and Moe](assets/calendar-folds.png)

The [invite detail](assets/calendar-conflicts.png) and expanded agenda above use
real Emacs with Moe and window-purpose, with synthetic appointments only.

These are ordinary, customizable Emacs keymaps:
`teams4e-calendar-mode-map` and `teams4e-calendar-event-mode-map`.
Evil uses motion state with the local calendar map taking precedence.
The event reader also provides RSVP, availability, join, Outlook, and capture
commands, plus clickable Teams-chat and availability actions. Text selection
and copying use normal Emacs behavior. The availability workspace retains its
own bindings; its existing `J` join shortcut is unchanged.

Invitations accept without notifying the organizer when the acceptance note is
empty, matching the existing meeting action. Other response types retain their
existing backend behavior. `r` or `A` opens the same day timeline, availability
ranking, proximity ranking, and participant-block sheet used by Teams meetings.
Selecting a slot with `RET` sends the action; browsing slots never does.

For an invitation, this sends a new-time proposal (with a note to the organizer).
For an event you organize, it moves that **single occurrence**, updating only
start/end and allowing Outlook to notify attendees. No second confirmation is
added. The workspace identifies this organizer action explicitly. Recurrence-rule
changes, all-day moves, and cancelled events remain in Outlook; a series master
cannot be moved accidentally. Outlook can reject an occurrence moved across
adjacent occurrences. Prohibited attendee proposals remain prohibited.

Reopening `teams4e-calendar` resumes the buffer without a request. Use a prefix
argument to refresh. Filtering is entirely local. Visiting a different date
range replaces the single loaded snapshot. This is not a persistent offline
calendar database: an existing buffer remains readable offline, but a new range
requires a working token and network.

## Setup

Use the same backend, external Graph token provider, and authentication settings
as teams4e. No separate app registration or new login flow is introduced.
This does not bypass tenant permissions: calendar read access must already be
authorized for that token, and responses/proposals need calendar write access.
See [authentication](AUTHENTICATION.md).

Update **both** the Lisp package and your installed Python backend. A deployment
that copies `teams4e-graph` and its Python modules outside the checkout must
reinstall those files too. Restart the persistent backend or Emacs afterward.
An older backend will reject the new `teams calendar` commands.

For Lisp-only calendar updates in an existing session, evaluate with `M-:`:

```elisp
(progn (load "teams4e-calendar.el") (teams4e-calendar))
```

This reinstalls the agenda's buffer-local Evil navigation bindings and redraws
from the current snapshot without fetching. The invite pane uses a standard
Emacs display action that is also tested with Spacemacs' window-purpose enabled.

Example optional configuration:

```elisp
(with-eval-after-load 'teams4e-calendar
  (setq teams4e-calendar-default-view 'week
        teams4e-calendar-show-declined nil
        teams4e-calendar-work-hours '(9 . 18)
        teams4e-calendar-work-days '(1 2 3 4 5) ; Mon-Fri; use 0-4 for Sun-Thu
        teams4e-calendar-free-gap-minutes 15 ; nil hides gap rows
        teams4e-calendar-capture-key "t"))

;; Optional; teams4e does not install a global calendar shortcut.
(global-set-key (kbd "M-s C") #'teams4e-calendar)
```

`teams4e-calendar-id` selects a non-default calendar on first use. Interactive
calendar selection changes only this calendar buffer. Configure
`teams4e-calendar-outlook-url` for a different Outlook deployment if needed.

For a local synthetic calendar, enable the existing mock backend and open
`teams4e-calendar`. Reset or recreate older mock state to get the newly seeded
appointments. See [local testing](LOCAL-TESTING.md); reset affects only mock data.

## Architecture and UI Choices

The calendar owns one canonical list of Graph event objects for one loaded
range. Its detail pane retains an event ID and a reference to the calendar
buffer. It neither creates artificial chat objects nor writes a synchronized
copy of the calendar into Org files. Org capture is an intentional export.

The backend uses:
- `GET /me/calendars` for explicit calendar selection.
- `GET /me/calendarView`, or a selected calendar's `calendarView`, for the
  displayed range. Graph expands recurrence, including exceptions.
- `GET /me/events/{id}` for the full description on demand.
- Existing response, availability, and proposal APIs for event actions.
- `PATCH /me/events/{id}` for explicit organizer rescheduling, with only start/end
  in the request. See [Graph event updates](https://learn.microsoft.com/en-us/graph/api/event-update?view=graph-rest-1.0).
- `GET /chats/{id}` only when explicitly opening an invite's Teams chat.
  The thread ID comes from the meeting link and preserves its case. Short links
  without a thread ID currently fall back to join/Outlook; no speculative search
  through every chat is performed. See [Graph chat lookup](https://learn.microsoft.com/en-us/graph/api/chat-get?view=graph-rest-1.0).

Only the requested range is fetched, paginated serially with 100 events per
page. There is no per-chat matching or per-event enrichment on the agenda path.
Existing shared Outlook throttling and retry handling remain in force.
A later-page failure preserves returned rows and labels the view incomplete.
Late responses cannot replace a newly selected range.

The first UI borrows the readable agenda approach from Org Agenda and
[khal](https://github.com/pimutils/khal), and explicit date/view navigation from
[calfw](https://github.com/haji-ali/emacs-calfw). It works in terminal Emacs and
with variable-width themes without a graphical dependency.

This release uses **day/week/month agenda lists**, not a graphical time-block
grid. A calfw adapter or time-block view is a good next presentation layer, but
should consume these same event objects rather than introduce a second store.
[org-timeblock](https://github.com/ichernyshovvv/org-timeblock) is attractive for
Org tasks; importing Outlook events into Org solely to drive it would add the
synchronization problem this implementation deliberately avoids.

## Current Boundaries

- One selected calendar at a time; no merged multi-account calendar.
- No background calendar polling or persistent offline event cache.
- Create/delete, general editing, recurrence rules, all-day moves, and attendee
  changes open Outlook. Native actions include RSVP, proposals, moving your own
  timed occurrence, join/chat, and capture.
- No automatic export to Org Agenda or modification of Org task files.
- Validation uses unit tests and an isolated synthetic tenant, not an actual
  company account. Real tenant permissions and policy still need a user check.

See Microsoft's [calendarView API](https://learn.microsoft.com/en-us/graph/api/calendar-list-calendarview?view=graph-rest-1.0)
and [calendar listing API](https://learn.microsoft.com/en-us/graph/api/user-list-calendars?view=graph-rest-1.0).
