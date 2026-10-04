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
| `j / k`, `n / p` | Next / previous event |
| `[ / ]` | Previous / next day, week, or month |
| `d / w / m` | Day / week / month agenda |
| `t` | Current day in the active view |
| `G` | Choose a date using Org's date reader and calendar |
| `RET` | Read an event in one reusable detail pane |
| `/` | Filter subject, location, or organizer; empty input clears |
| `x` | Include / hide declined and cancelled events |
| `c` | Choose a calendar returned by Microsoft Graph |
| `a` | Accept, tentative, or decline |
| `A` | Participant availability and propose-new-time workspace |
| `J` | Join an online meeting |
| `o` | Open the event in Outlook, or the calendar when no event is selected |
| `C` | Org capture: title, link, time, location, and event ID |
| `g` | Refresh the displayed range |
| `q` | Quit the current pane |

These are ordinary, customizable Emacs keymaps:
`teams4e-calendar-mode-map` and `teams4e-calendar-event-mode-map`.
Evil uses motion state with the local calendar map taking precedence.
The event reader also provides RSVP, availability, join, Outlook, and capture
commands. Text selection and copying use normal Emacs behavior.

Invitations accept without notifying the organizer when the acceptance note is
empty, matching the existing meeting action. Other response types retain their
existing backend behavior. Proposals are explicit actions, never sent simply
by moving through suggestions. Meeting organizers and events that prohibit
proposals retain the API's restrictions.

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

Example optional configuration:

```elisp
(with-eval-after-load 'teams4e-calendar
  (setq teams4e-calendar-default-view 'week
        teams4e-calendar-show-declined nil
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
- Create/edit/delete, recurrence-rule editing, and attendee changes open Outlook
  for now. The native actions are reading, RSVP, proposals, join, and capture.
- No automatic export to Org Agenda or modification of Org task files.
- Validation uses unit tests and an isolated synthetic tenant, not an actual
  company account. Real tenant permissions and policy still need a user check.

See Microsoft's [calendarView API](https://learn.microsoft.com/en-us/graph/api/calendar-list-calendarview?view=graph-rest-1.0)
and [calendar listing API](https://learn.microsoft.com/en-us/graph/api/user-list-calendars?view=graph-rest-1.0).
