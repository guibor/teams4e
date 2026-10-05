;;; teams4e-calendar.el --- Independent Outlook calendar -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; A range-bounded, event-first agenda.  The buffer owns one Graph snapshot;
;; details and actions refer to event IDs in that snapshot, never synthetic chats.

;;; Code:
(require 'teams4e-meetings)
(require 'calendar)
(require 'org)
(require 'shr)
(require 'url-parse)
(require 'url-util)
(require 'hl-line)

(declare-function evil-set-initial-state "evil-core" (mode state))
(declare-function evil-local-set-key "evil-core" (state key def))
(declare-function evil-make-overriding-map "evil-core" (keymap &optional state copy))

(defgroup teams4e-calendar nil
  "Independent Microsoft 365 calendar."
  :group 'teams4e)

(defcustom teams4e-calendar-default-view 'week
  "Initial agenda range."
  :type '(choice (const day) (const week) (const month))
  :group 'teams4e-calendar)

(defcustom teams4e-calendar-id nil
  "Calendar ID to open by default, or nil for the primary calendar."
  :type '(choice (const :tag "Primary calendar" nil) string)
  :group 'teams4e-calendar)

(defcustom teams4e-calendar-show-declined nil
  "Whether the agenda includes cancelled and declined events."
  :type 'boolean :group 'teams4e-calendar)

(defcustom teams4e-calendar-capture-key nil
  "Org capture template key for calendar actions, or nil to choose a template."
  :type '(choice (const nil) string) :group 'teams4e-calendar)

(defcustom teams4e-calendar-outlook-url "https://outlook.office.com/calendar/"
  "Calendar URL used when no individual event link is available."
  :type 'string :group 'teams4e-calendar)

(defcustom teams4e-calendar-follow-browser-command 'auto
  "Browser argv for Follow handoff, or auto for best-effort background opening.
Auto uses macOS open -g (preserving an existing open -a browser choice);
elsewhere it uses `teams4e-browser-command'.  Nil delegates to `browse-url'.
The URL is appended as one argument.  No background-tab guarantee is possible."
  :type '(choice (const auto) (const nil) (repeat string))
  :group 'teams4e-calendar)

(defconst teams4e-calendar--buffer-name "*Teams Calendar*")
(defconst teams4e-calendar--detail-name "*Teams Calendar Event*")
(defvar-local teams4e-calendar--events nil)
(defvar-local teams4e-calendar--date nil)
(defvar-local teams4e-calendar--view nil)
(defvar-local teams4e-calendar--id nil)
(defvar-local teams4e-calendar--name "Primary calendar")
(defvar-local teams4e-calendar--filter "")
(defvar-local teams4e-calendar--show-declined nil)
(defvar-local teams4e-calendar--loaded-key nil)
(defvar-local teams4e-calendar--request nil)
(defvar-local teams4e-calendar--generation 0)
(defvar-local teams4e-calendar--error nil)
(defvar-local teams4e-calendar--loading nil)
(defvar-local teams4e-calendar--owner nil)
(defvar-local teams4e-calendar--event-id nil)
(defvar-local teams4e-calendar--focus nil)
(defvar-local teams4e-calendar--focus-day-heading nil)
(defvar-local teams4e-calendar--fold-state nil
  "Summary and conflict expansion overrides, keyed by calendar and event IDs.")

(defun teams4e-calendar--midnight (time &optional days)
  "Return local midnight at TIME plus calendar DAYS, including across DST."
  (let ((parts (decode-time time)))
    (encode-time 0 0 0 (+ (nth 3 parts) (or days 0))
                 (nth 4 parts) (nth 5 parts))))

(defun teams4e-calendar--range ()
  "Return the current half-open local calendar range."
  (let* ((date (or teams4e-calendar--date (current-time)))
         (parts (decode-time date))
         (day (teams4e-calendar--midnight date)))
    (pcase teams4e-calendar--view
      ('day (list day (teams4e-calendar--midnight day 1)))
      ('month (list (encode-time 0 0 0 1 (nth 4 parts) (nth 5 parts))
                    (encode-time 0 0 0 1 (1+ (nth 4 parts)) (nth 5 parts))))
      (_ (let ((start (teams4e-calendar--midnight
                       day (- (mod (- (nth 6 parts) calendar-week-start-day) 7)))))
           (list start (teams4e-calendar--midnight start 7)))))))

(defun teams4e-calendar--key ()
  "Return the identity of the current calendar viewport."
  (cons teams4e-calendar--id
        (mapcar (lambda (time) (format-time-string "%Y-%m-%dT%H:%M:%SZ" time t))
                (teams4e-calendar--range))))

(defun teams4e-calendar--time (event field)
  "Read EVENT FIELD as an absolute instant."
  (when-let ((value (teams4e--event-date-time event field)))
    (condition-case nil (date-to-time value) (error nil))))

(defun teams4e-calendar--line (text)
  "Make untrusted calendar TEXT a single display line."
  (replace-regexp-in-string "[\n\r\t]+" " " (or text "")))

(defun teams4e-calendar--status (event)
  "Return a concise status for EVENT."
  (cond
   ((teams4e--get event 'isCancelled) "Cancelled")
   ((teams4e--get event 'isOrganizer) "Organizer")
   (t (pcase (teams4e--dig event 'responseStatus 'response)
        ("accepted" "Accepted") ("tentativelyAccepted" "Tentative")
        ("declined" "Declined") ("notResponded" "Needs response")
        (_ (or (teams4e--get event 'showAs) ""))))))

(defun teams4e-calendar--visible-p (event)
  "Return non-nil if EVENT passes the local agenda filters."
  (and (or teams4e-calendar--show-declined
           (not (or (teams4e--get event 'isCancelled)
                    (equal (teams4e--dig event 'responseStatus 'response) "declined"))))
       (let ((case-fold-search t))
         (string-match-p
          (regexp-quote teams4e-calendar--filter)
          (mapconcat #'identity
                     (list (or (teams4e--get event 'subject) "")
                           (or (teams4e--dig event 'location 'displayName) "")
                           (or (teams4e--dig event 'organizer 'emailAddress 'name) ""))
                     " ")))))

(defun teams4e-calendar--day-events (day)
  "Return visible events overlapping local DAY, with exclusive end dates."
  (let ((next (teams4e-calendar--midnight day 1)))
    (seq-filter
     (lambda (event)
       (let ((start (teams4e-calendar--time event 'start))
             (end (teams4e-calendar--time event 'end)))
         (and start end (teams4e-calendar--visible-p event)
              (time-less-p start next)
              (or (time-less-p day end) (and (equal start day) (equal end day))))))
     teams4e-calendar--events)))

(defun teams4e-calendar--time-label (event day)
  "Return a spacious time interval for EVENT on DAY."
  (let ((start (teams4e-calendar--time event 'start))
        (end (teams4e-calendar--time event 'end))
        (next (teams4e-calendar--midnight day 1)))
    (if (teams4e--get event 'isAllDay) "All day"
      (format "%s - %s"
              (if (time-less-p start day) "..." (format-time-string "%H:%M" start))
              (cond ((time-less-p next end) "...")
                    ((equal next end) "24:00")
                    (t (format-time-string "%H:%M" end)))))))

(defcustom teams4e-calendar-work-hours '(9 . 18)
  "Local working hours used to display free gaps, as (START . END).
Hours are integers from 0 to 24.  This does not change Outlook working hours."
  :type '(cons integer integer) :group 'teams4e-calendar)

(defcustom teams4e-calendar-work-days '(1 2 3 4 5)
  "Weekdays on which to show free gaps: Sunday is 0, Saturday is 6."
  :type '(repeat integer) :group 'teams4e-calendar)

(defcustom teams4e-calendar-free-gap-minutes 15
  "Smallest free gap to display, in minutes; nil disables gap rows.
Gaps describe only the selected calendar, not all calendars or participants."
  :type '(choice (const nil) (integer :tag "Minutes"))
  :group 'teams4e-calendar)

(defface teams4e-calendar-busy '((t :inherit font-lock-keyword-face))
  "Busy event times." :group 'teams4e-calendar)
(defface teams4e-calendar-tentative '((t :inherit font-lock-constant-face))
  "Tentative availability, independent of RSVP." :group 'teams4e-calendar)
(defface teams4e-calendar-out-of-office '((t :inherit font-lock-warning-face))
  "Out-of-office event times." :group 'teams4e-calendar)
(defface teams4e-calendar-free '((t :inherit shadow))
  "Non-blocking events, distinct from actual free time." :group 'teams4e-calendar)
(defface teams4e-calendar-free-slot
  '((((class color) (min-colors 88) (background dark))
     :foreground "#a1e9c4" :background "#173d35" :weight bold :extend t)
    (((class color) (min-colors 88) (background light))
     :foreground "#17613d" :background "#dff5e8" :weight bold :extend t)
    (t :inherit success :weight bold))
  "Actual available slots and their summary, not free/following invitations."
  :group 'teams4e-calendar)
(defface teams4e-calendar-elsewhere '((t :inherit font-lock-type-face))
  "Working-elsewhere event times." :group 'teams4e-calendar)

(defun teams4e-calendar--availability (event)
  "Return (LABEL FACE BLOCKS-TIME) for EVENT's availability, not its RSVP."
  (cond
   ((or (teams4e--get event 'isCancelled)
        (equal (teams4e--dig event 'responseStatus 'response) "declined"))
    '("Not attending" teams4e-calendar-free nil))
   (t (pcase (teams4e--get event 'showAs)
        ("free" '("Free" teams4e-calendar-free nil))
        ("busy" '("Busy" teams4e-calendar-busy t))
        ("tentative" '("Tentative" teams4e-calendar-tentative t))
        ("oof" '("Out of office" teams4e-calendar-out-of-office t))
        ("workingElsewhere" '("Working elsewhere" teams4e-calendar-elsewhere nil))
        (_ '("Availability unknown" shadow t))))))

(defface teams4e-calendar-conflict '((t :inherit warning :weight bold))
  "Overlap labels, separate from an event's availability color."
  :group 'teams4e-calendar)

(defun teams4e-calendar--busy-intervals (start end)
  "Return (START END EVENT) intervals blocking the range START to END.
Use the unfiltered snapshot; cancelled, declined and free events do not block."
  (let ((first (float-time start)) (last (float-time end)) result)
    (dolist (event teams4e-calendar--events)
      (when (nth 2 (teams4e-calendar--availability event))
        (let ((a (teams4e-calendar--time event 'start))
              (b (teams4e-calendar--time event 'end)))
          (when (and a b (< (float-time a) (float-time b))
                     (< (float-time a) last) (> (float-time b) first))
            (push (list (max first (float-time a)) (min last (float-time b)) event)
                  result)))))
    (nreverse result)))

(defun teams4e-calendar--conflicts (day)
  "Return exact simultaneous-overlap segments on local DAY.
Each segment is (START END EVENTS).  Touching endpoints do not conflict.
Do not group transitive overlaps: A/B followed by B/C is not an A/C clash."
  (when (equal (teams4e-calendar--key) teams4e-calendar--loaded-key)
    (let* ((blocks (teams4e-calendar--busy-intervals
                    day (teams4e-calendar--midnight day 1)))
           (boundaries (sort (delete-dups
                              (apply #'append (mapcar (lambda (row) (seq-take row 2)) blocks)))
                             #'<))
           result)
      (while (cdr boundaries)
        (let* ((start (car boundaries)) (end (cadr boundaries))
               (active (seq-filter (lambda (row)
                                     (and (< (car row) end) (> (cadr row) start)))
                                   blocks)))
          (when (> (length active) 1)
            (push (list start end (mapcar (lambda (row) (nth 2 row)) active)) result)))
        (setq boundaries (cdr boundaries)))
      (nreverse result))))

(defun teams4e-calendar--conflict-labels (event conflicts &optional accepted-only)
  "Return day-local overlap labels for EVENT in CONFLICTS.
With ACCEPTED-ONLY, require another accepted event in the same segment.
Keep original segment numbers so labels still refer to the conflict details."
  (let ((id (teams4e--get event 'id)) (index 0) result)
    (dolist (segment conflicts)
      (cl-incf index)
      (when (and (seq-some (lambda (other) (equal id (teams4e--get other 'id))) (nth 2 segment))
                 (or (not accepted-only)
                     (and (equal (teams4e--dig event 'responseStatus 'response) "accepted")
                          (seq-some
                           (lambda (other)
                             (and (not (equal id (teams4e--get other 'id)))
                                  (equal (teams4e--dig other 'responseStatus 'response) "accepted")))
                           (nth 2 segment)))))
        (push (format "C%d" index) result)))
    (nreverse result)))

(defun teams4e-calendar--day-key (day)
  "Return a calendar-qualified row identity for DAY."
  (list 'day teams4e-calendar--id (format-time-string "%Y-%m-%d" day)))

(defun teams4e-calendar--section-open-p (key)
  "Whether summary or conflict KEY is expanded.
Summaries open and conflicts close by default.  Day folding is not supported."
  (when (memq (car-safe key) '(summary conflict))
    (let ((state (assoc key teams4e-calendar--fold-state)))
      (if state (eq (cdr state) 'open) (eq (car key) 'summary)))))

(defun teams4e-calendar--find-item (key)
  "Find the rendered row identified by KEY, without relying on its position."
  (when key
    (let ((position (point-min)))
      (while (and (< position (point-max))
                  (not (equal key (get-text-property position 'teams4e-calendar-item))))
        (setq position (next-single-property-change
                        position 'teams4e-calendar-item nil (point-max))))
      (when (< position (point-max)) position))))

(defun teams4e-calendar-toggle-section ()
  "Toggle a summary heading or enclosing conflict group without fetching.
Elsewhere do nothing; days and their timelines are never folded."
  (interactive)
  (let ((key (get-text-property (point) 'teams4e-calendar-section)))
    (when (memq (car-safe key) '(summary conflict))
      (setf (alist-get key teams4e-calendar--fold-state nil nil #'equal)
            (if (teams4e-calendar--section-open-p key) 'closed 'open))
      (setq teams4e-calendar--focus nil teams4e-calendar--focus-day-heading nil)
      (goto-char (or (teams4e-calendar--find-item key) (point)))
      (teams4e-calendar--render))))

(defun teams4e-calendar-activate ()
  "Activate an event action at point, or open the selected invitation."
  (interactive)
  (if-let ((button (button-at (point))))
      (button-activate button)
    (teams4e-calendar-open-event)))

(defun teams4e-calendar--action-button (label command id)
  "Insert LABEL invoking COMMAND for canonical event ID in this agenda."
  (let ((owner (current-buffer)))
    (insert-text-button
     label 'follow-link t 'action
     (lambda (_)
       (unless (buffer-live-p owner) (user-error "Calendar buffer was closed"))
       (with-current-buffer owner
         (let ((teams4e-calendar--event-id id))
           (call-interactively command)))))))

(defun teams4e-calendar--insert-conflict-event (event day key)
  "Insert actionable EVENT under conflict KEY on DAY, retaining only its ID."
  (let* ((start (point))
         (id (teams4e--get event 'id))
         (availability (teams4e-calendar--availability event)))
    (insert (propertize (format "      %-15s " (teams4e-calendar--time-label event day))
                        'face (cadr availability)))
    (teams4e-calendar--action-button
     (teams4e-calendar--line (or (teams4e--get event 'subject) "(Untitled event)"))
     #'teams4e-calendar-open-event id)
    (insert "\n")
    (add-text-properties start (point) '(teams4e-calendar-event-start t))
    (insert "      " (propertize (car availability) 'face (cadr availability))
            (propertize (concat " | " (teams4e-calendar--status event)
                                (unless (teams4e-calendar--visible-p event) " | Filtered out"))
                        'face 'shadow)
            "\n      ")
    (teams4e-calendar--action-button
     (if (teams4e--get event 'isOrganizer)
         "Availability / reschedule" "Availability / propose time")
     #'teams4e-calendar-availability id)
    (when (and (not (teams4e--get event 'isOrganizer)) (teams4e--get event 'attendees))
      (insert "   ")
      (teams4e-calendar--action-button "Respond" #'teams4e-calendar-respond id))
    (insert "   ")
    (teams4e-calendar--action-button "Outlook" #'teams4e-calendar-open-outlook id)
    (insert "\n")
    (add-text-properties start (point)
                         (list 'teams4e-calendar-event id
                               'teams4e-calendar-item (list 'conflict-event key id)))))

(defun teams4e-calendar--insert-conflicts (conflicts day)
  "Insert foldable overlap groups for CONFLICTS on DAY."
  (let ((index 0))
    (dolist (segment conflicts)
      (cl-incf index)
      (let* ((start (point))
             (events (nth 2 segment))
             ;; Stable across sorting and label changes; not a second event store.
             (key (list 'conflict (teams4e-calendar--day-key day)
                        (car segment) (cadr segment)
                        (sort (mapcar (lambda (event) (teams4e--get event 'id)) events)
                              #'string-lessp)))
             (open (teams4e-calendar--section-open-p key))
             (hidden (seq-count (lambda (event) (not (teams4e-calendar--visible-p event))) events))
             (titles (mapconcat (lambda (event)
                                 (teams4e-calendar--line (teams4e--get event 'subject)))
                               events "; ")))
        (insert (propertize
                 (format "    C%d [%s]  %s - %s  |  %d overlapping events%s\n"
                         index (if open "-" "+") (format-time-string "%H:%M" (car segment))
                         (if (equal (format-time-string "%H:%M" (cadr segment)) "00:00")
                             "24:00" (format-time-string "%H:%M" (cadr segment)))
                         (length events)
                         (if (> hidden 0) (format " (%d filtered out)" hidden) ""))
                 'face 'teams4e-calendar-conflict 'help-echo titles
                 'teams4e-calendar-item key))
        (when open
          (dolist (event events)
            (teams4e-calendar--insert-conflict-event event day key)))
        (add-text-properties start (point) (list 'teams4e-calendar-section key))))))

(defun teams4e-calendar--summary-group (event)
  "Return EVENT's day-summary group, excluding non-attending entries."
  (let ((response (teams4e--dig event 'responseStatus 'response)))
    (when (and (nth 2 (teams4e-calendar--availability event))
               (not (member response '("declined" "follow" "following"))))
      (cond ((teams4e--get event 'isOrganizer) 'organizing)
            ((equal response "accepted") 'accepted)
            ((equal response "tentativelyAccepted") 'tentative)
            ((and (teams4e--get event 'attendees)
                  (member response '(nil "" "none" "notResponded")))
             'unanswered)))))

(defun teams4e-calendar--insert-summary-group (label events key &optional respond conflicts)
  "Insert compact LABEL rows for EVENTS under summary KEY.
Offer RESPOND buttons for invitations, and accepted-only labels from CONFLICTS."
  (when events
    (insert (propertize (format "    %s (%d)\n" label (length events))
                        'face (if respond 'warning 'bold)))
    (dolist (event events)
      (let ((start (point)) (id (teams4e--get event 'id)))
        (insert "      - ")
        (teams4e-calendar--action-button
         (teams4e-calendar--line (or (teams4e--get event 'subject) "(Untitled event)"))
         #'teams4e-calendar-open-event id)
        (when-let ((labels (teams4e-calendar--conflict-labels event conflicts t)))
          (insert (propertize (concat "  [" (string-join labels ", ") "]")
                              'face 'teams4e-calendar-conflict)))
        (when (and respond (teams4e--get event 'attendees))
          (insert "   ")
          (teams4e-calendar--action-button "Respond" #'teams4e-calendar-respond id))
        (insert "\n")
        (add-text-properties start (point)
                             (list 'teams4e-calendar-event id
                                   'teams4e-calendar-item (list 'summary-event key id)))))))

(defun teams4e-calendar--insert-day-summary (day events gaps conflicts)
  "Insert a foldable summary from DAY's EVENTS, GAPS and CONFLICTS.
Only the summary heading folds the summary; the timeline always stays visible."
  (let* ((key (list 'summary (teams4e-calendar--day-key day)))
         (open (teams4e-calendar--section-open-p key))
         (minutes (/ (floor (apply #'+ (mapcar (lambda (gap) (- (cadr gap) (car gap))) gaps))) 60))
         (duration (format "%dh %02dm" (/ minutes 60) (% minutes 60)))
         (sorted (sort (copy-sequence events)
                       (lambda (a b) (time-less-p (teams4e-calendar--time a 'start)
                                                  (teams4e-calendar--time b 'start)))))
         groups)
    (dolist (event sorted)
      (when-let ((group (teams4e-calendar--summary-group event)))
        (push event (alist-get group groups))))
    (setq groups (mapcar (lambda (entry) (cons (car entry) (nreverse (cdr entry)))) groups))
    (let ((start (point)))
      (insert (propertize (format "  Summary [%s]  |  %d need response  |  %d conflicts"
                                  (if open "-" "+") (length (alist-get 'unanswered groups))
                                  (length conflicts))
                          'face 'bold)
              (if gaps (propertize (concat "  |  FREE " duration)
                                   'face 'teams4e-calendar-free-slot) "")
              "\n")
      (add-text-properties start (point)
                           (list 'teams4e-calendar-item key 'teams4e-calendar-section key)))
    (when open
      (cond
       (gaps
        (insert (propertize
                 (concat "    FREE " duration "  |  "
                         (mapconcat (lambda (gap)
                                      (format "%s - %s"
                                              (format-time-string "%H:%M" (car gap))
                                              (if (equal (format-time-string "%H:%M" (cadr gap)) "00:00")
                                                  "24:00"
                                                (format-time-string "%H:%M" (cadr gap)))))
                                    gaps "  |  ")
                         "\n")
                 'face 'teams4e-calendar-free-slot)))
       ((or teams4e-calendar--loading teams4e-calendar--error)
        (insert (propertize "    Free time unavailable\n" 'face 'shadow)))
       ((teams4e-calendar--free-gaps-available-p day)
        (insert (propertize
                 (format "    No free slots of at least %d min\n" teams4e-calendar-free-gap-minutes)
                 'face 'shadow))))
      (teams4e-calendar--insert-summary-group "Needs response" (alist-get 'unanswered groups) key t)
      (teams4e-calendar--insert-conflicts conflicts day)
      (teams4e-calendar--insert-summary-group "Tentative" (alist-get 'tentative groups) key t)
      (teams4e-calendar--insert-summary-group "Accepted" (alist-get 'accepted groups) key nil conflicts)
      (teams4e-calendar--insert-summary-group "Organizing" (alist-get 'organizing groups) key))
    (insert "\n")))

(defun teams4e-calendar--insert-event-conflicts (owner event)
  "Insert clickable overlap partners for EVENT from OWNER's snapshot."
  (let* ((start (teams4e-calendar--time event 'start))
         (end (teams4e-calendar--time event 'end))
         (others (and start end (nth 2 (teams4e-calendar--availability event))
                      (with-current-buffer owner
                        (seq-remove
                         (lambda (row) (equal (teams4e--get event 'id)
                                             (teams4e--get (nth 2 row) 'id)))
                         (teams4e-calendar--busy-intervals start end))))))
    (when others
      (insert (propertize "Overlapping events\n" 'face 'teams4e-calendar-conflict))
      (dolist (row others)
        (let* ((other (nth 2 row)) (id (teams4e--get other 'id)))
          (insert (format "  %s - %s  "
                          (format-time-string "%a %d %b %H:%M" (car row))
                          (format-time-string "%a %d %b %H:%M" (cadr row))))
          (insert-text-button
           (teams4e-calendar--line (or (teams4e--get other 'subject) "(Untitled event)"))
           'follow-link t 'action
           (lambda (_)
             (with-current-buffer owner
               (let ((teams4e-calendar--event-id id))
                 (teams4e-calendar-open-event)))))
          (insert (format " [%s]\n" (car (teams4e-calendar--availability other))))))
      (insert "\n"))))

(defun teams4e-calendar--free-gaps-available-p (day)
  "Whether the snapshot and working-hour settings support free slots on DAY."
  (and teams4e-calendar-free-gap-minutes
       (> teams4e-calendar-free-gap-minutes 0)
       (not teams4e-calendar--error) (not teams4e-calendar--loading)
       (equal (teams4e-calendar--key) teams4e-calendar--loaded-key)
       (memq (nth 6 (decode-time day)) teams4e-calendar-work-days)
       (<= 0 (car teams4e-calendar-work-hours))
       (< (car teams4e-calendar-work-hours) (cdr teams4e-calendar-work-hours))
       (<= (cdr teams4e-calendar-work-hours) 24)))

(defun teams4e-calendar--free-gaps (day)
  "Derive free intervals on DAY from the full snapshot, ignoring text filters.
Never infer free time from an incomplete, stale, or loading snapshot."
  (when (teams4e-calendar--free-gaps-available-p day)
    (let* ((parts (decode-time day))
           (start (float-time (encode-time 0 0 (car teams4e-calendar-work-hours)
                                           (nth 3 parts) (nth 4 parts) (nth 5 parts))))
           (end (float-time (encode-time 0 0 (cdr teams4e-calendar-work-hours)
                                         (nth 3 parts) (nth 4 parts) (nth 5 parts))))
           (cursor start) intervals gaps)
      (setq intervals (mapcar (lambda (row) (cons (car row) (cadr row)))
                              (teams4e-calendar--busy-intervals start end)))
      ;; Union overlapping blocks before calculating their complement.
      (dolist (block (sort intervals (lambda (a b) (< (car a) (car b)))))
        (when (>= (- (car block) cursor) (* 60 teams4e-calendar-free-gap-minutes))
          (push (list cursor (car block) nil) gaps))
        (setq cursor (max cursor (cdr block))))
      (when (>= (- end cursor) (* 60 teams4e-calendar-free-gap-minutes))
        (push (list cursor end nil) gaps))
      (nreverse gaps))))

(defun teams4e-calendar--center ()
  "Center point in every window displaying this agenda without stealing focus."
  (dolist (window (get-buffer-window-list (current-buffer) nil t))
    (set-window-point window (point))
    (with-selected-window window (recenter))))

(defun teams4e-calendar--focus-time (time &optional day-heading)
  "Center on TIME, or its day heading when DAY-HEADING is t.
When DAY-HEADING is `upcoming', exclude ended timed rows."
  (let* ((day (format-time-string "%Y-%m-%d" time))
         (target (float-time time))
         (heading (save-excursion
                    (goto-char (point-min))
                    (while (and (not (eobp))
                                (not (equal day (get-text-property (point) 'teams4e-calendar-day))))
                      (forward-line 1))
                    (unless (eobp) (point))))
         best score)
    (save-excursion
      (goto-char (or heading (point-min)))
      (while (and (< (point) (point-max))
                  (equal day (get-text-property (point) 'teams4e-calendar-day)))
        (when-let ((start (get-text-property (point) 'teams4e-calendar-row-start)))
          (let* ((end (get-text-property (point) 'teams4e-calendar-row-end))
                 (distance (cond ((< target start) (- start target))
                                 ((>= target end) (+ 1 (- target end)))
                                 (t 0))))
            (unless (or (get-text-property (point) 'teams4e-calendar-all-day)
                        (and (eq day-heading 'upcoming) (<= end target)))
              (when (or (null score) (< distance score))
                (setq best (point) score distance)))))
        (forward-line 1)))
    (goto-char (or (and (eq day-heading t) heading) best heading (point-min)))
    (teams4e-calendar--center)))

(defun teams4e-calendar--position-anchor (position)
  "Capture a semantic anchor for POSITION before replacing the rendered text."
  (save-excursion
    (goto-char position)
    (let* ((direct (get-text-property position 'teams4e-calendar-item))
           (item (or direct
                     (save-excursion
                       (beginning-of-line)
                       (while (and (> (point) (point-min))
                                   (not (get-text-property (point) 'teams4e-calendar-item)))
                         (forward-line -1))
                       (get-text-property (point) 'teams4e-calendar-item))))
           (day (get-text-property position 'teams4e-calendar-day))
           (start (and item (teams4e-calendar--find-item item)))
           (line (if start (count-lines start (line-beginning-position)) 0))
           (column (current-column))
           (event (get-text-property position 'teams4e-calendar-event))
           before after last)
      (save-excursion
        (goto-char (point-min))
        (while (< (point) (point-max))
          (let ((key (get-text-property (point) 'teams4e-calendar-item)))
            (when (and key (not (equal key last)) (not (equal key item)))
              (if (< (point) position) (push key before) (push key after)))
            (setq last key))
          (forward-line 1)))
      (list :item item :gap (not direct) :day day :event event :line line :column column
            :fallback (and item (append (nreverse after) before)) :position position))))

(defun teams4e-calendar--anchor-position (anchor)
  "Resolve ANCHOR in the new render, preferring its event and surviving neighbors."
  (let* ((item (plist-get anchor :item))
         (exact (teams4e-calendar--find-item item))
         (event (plist-get anchor :event))
         (day-key (list 'day teams4e-calendar--id (plist-get anchor :day)))
         (start (or exact
                    (and event (teams4e-calendar--find-item (list 'event day-key event)))
                    (seq-some #'teams4e-calendar--find-item (plist-get anchor :fallback))
                    (teams4e-calendar--find-item day-key)
                    (min (or (plist-get anchor :position) 1) (point-max)))))
    (save-excursion
      (goto-char start)
      (when exact
        (let ((remaining (plist-get anchor :line)))
          (while (and (> remaining 0)
                      (save-excursion
                        (forward-line 1)
                        (let ((next (get-text-property (point) 'teams4e-calendar-item)))
                          (or (equal item next) (and (plist-get anchor :gap) (null next))))))
            (forward-line 1)
            (setq remaining (1- remaining)))))
      (move-to-column (or (plist-get anchor :column) 0))
      (point))))

(defun teams4e-calendar--screen-row (window)
  "Return point's visual row in WINDOW, accounting for wrapped lines."
  (save-excursion
    (goto-char (window-point window))
    (vertical-motion 0 window)
    (count-screen-lines (window-start window) (point) nil window)))

(defun teams4e-calendar--window-anchors ()
  "Capture independent point and viewport anchors for each agenda window."
  (mapcar
   (lambda (window)
     (with-selected-window window
       (list :window window
             :point (teams4e-calendar--position-anchor (window-point window))
             :start (teams4e-calendar--position-anchor (window-start window))
             :row (teams4e-calendar--screen-row window)
             :vscroll (window-vscroll window t)
             :hscroll (window-hscroll window))))
   (get-buffer-window-list (current-buffer) nil t)))

(defun teams4e-calendar--restore-window-anchors (anchors)
  "Restore ANCHORS without stealing focus or recentering ordinary refreshes."
  (dolist (state anchors)
    (let ((window (plist-get state :window)))
      (when (and (window-live-p window) (eq (window-buffer window) (current-buffer)))
        (let ((position (teams4e-calendar--anchor-position (plist-get state :point)))
              (start (teams4e-calendar--anchor-position (plist-get state :start)))
              (row (plist-get state :row)))
          (set-window-start window start t)
          (set-window-point window position)
          (with-selected-window window
            ;; Keep an unchanged viewport exactly; compensate only for changed rows.
            (when (and (<= 0 row) (< row (window-body-height window))
                       (/= row (teams4e-calendar--screen-row window)))
              (goto-char position)
              (recenter row)))
          (set-window-hscroll window (plist-get state :hscroll))
          (set-window-vscroll window (plist-get state :vscroll) t))))))

(defun teams4e-calendar--render ()
  "Render the snapshot, preserving the selected occurrence and day."
  (let* ((inhibit-read-only t)
         (anchor (teams4e-calendar--position-anchor (point)))
         (windows (teams4e-calendar--window-anchors))
         (range (teams4e-calendar--range))
         (day (car range))
         (loaded (equal (teams4e-calendar--key) teams4e-calendar--loaded-key)))
    (erase-buffer)
    (setq header-line-format
          (list " Calendar | " teams4e-calendar--name " | "
                (symbol-name teams4e-calendar--view)
                " | " '(:eval (format-time-string "%a %d %b" teams4e-calendar--date))
                (if teams4e-calendar--loading " | Loading..." "")
                (if teams4e-calendar--error " | Incomplete" "")
                (unless (string-empty-p teams4e-calendar--filter)
                  (concat " | " teams4e-calendar--filter))))
    (insert (propertize
             (format "%s - %s  (%s)\n\n"
                     (format-time-string "%a %d %b %Y" day)
                     (format-time-string "%a %d %b %Y"
                                         (time-subtract (cadr range) (seconds-to-time 1)))
                     (format-time-string "%Z" day))
             'face 'bold))
    (when teams4e-calendar--error
      (insert (propertize (concat teams4e-calendar--error "\n\n") 'face 'warning)))
    (while (time-less-p day (cadr range))
      (let* ((day-start (point))
             (section (teams4e-calendar--day-key day))
             (day-key (format-time-string "%Y-%m-%d" day))
             (today (equal day-key (format-time-string "%Y-%m-%d")))
             (events (and loaded (teams4e-calendar--day-events day)))
             (gaps (teams4e-calendar--free-gaps day))
             (conflicts (teams4e-calendar--conflicts day))
             (rows (append
                    (mapcar (lambda (event)
                              (list (float-time (teams4e-calendar--time event 'start))
                                    (float-time (teams4e-calendar--time event 'end)) event))
                            events)
                    gaps)))
        (insert (propertize (concat (format-time-string "%A, %d %B" day)
                                    (if today "  TODAY" "")
                                    (if loaded
                                        (format "  |  %d event%s%s" (length events)
                                                (if (= (length events) 1) "" "s")
                                                (if teams4e-calendar--error " returned" ""))
                                      "  |  Not loaded")
                                    (if conflicts (format "  |  %d conflict%s" (length conflicts)
                                                          (if (= (length conflicts) 1) "" "s")) "")
                                    "\n")
                            'teams4e-calendar-item section
                            'face '(:inherit font-lock-keyword-face :weight bold)))
        (when loaded (teams4e-calendar--insert-day-summary day events gaps conflicts))
        (dolist (row (sort rows (lambda (a b) (< (car a) (car b)))))
          (pcase-let* ((`(,start-time ,end-time ,event) row)
                       (start (point))
                       (availability (if event (teams4e-calendar--availability event)
                                       '("Free" teams4e-calendar-free-slot nil)))
                       (face (nth 1 availability))
                       (conflict-labels (and event (teams4e-calendar--conflict-labels event conflicts)))
                       (location (teams4e--dig event 'location 'displayName))
                       (ongoing (and today (not (teams4e--get event 'isAllDay))
                                     (<= start-time (float-time))
                                     (< (float-time) end-time))))
            (insert (propertize
                     (format "%s %-15s "
                             (if ongoing ">" " ")
                             (if event (teams4e-calendar--time-label event day)
                               (format "%s - %s" (format-time-string "%H:%M" start-time)
                                       (format-time-string "%H:%M" end-time))))
                     'face face)
                    (propertize
                     (if event
                         (teams4e-calendar--line (or (teams4e--get event 'subject) "(Untitled event)"))
                       (format "[FREE] Free in this calendar (%d min)" (/ (- end-time start-time) 60)))
                     'face (if (nth 2 availability) 'bold face))
                    (if conflict-labels
                        (propertize (concat "  [" (string-join conflict-labels ", ") "]")
                                    'face 'teams4e-calendar-conflict)
                      "")
                    "\n")
            (add-text-properties start (point)
                                 (list 'teams4e-calendar-row-start start-time
                                       'teams4e-calendar-row-end end-time
                                       'teams4e-calendar-all-day (teams4e--get event 'isAllDay)
                                       'teams4e-calendar-event-start (and event t)))
            (unless event
              (put-text-property start (point) 'teams4e-calendar-item
                                 (list 'slot section start-time end-time)))
            (when event
              (insert "                  "
                      (propertize (car availability) 'face face)
                      (propertize
                       (concat " | "
                               (string-join
                                (delq nil (list (teams4e-calendar--status event)
                                                (and (not (string-empty-p (or location "")))
                                                     (teams4e-calendar--line location))
                                                (when (member (teams4e--get event 'type)
                                                              '("occurrence" "exception"))
                                                  "Recurring")))
                                " | "))
                       'face 'shadow)
                      "\n")
              (add-text-properties start (point)
                                   (list 'teams4e-calendar-event (teams4e--get event 'id)
                                         'teams4e-calendar-item
                                         (list 'event section (teams4e--get event 'id))
                                         'mouse-face 'highlight)))))
        (unless rows
          (insert (propertize
                   (cond ((not loaded) "  Not loaded\n")
                         (teams4e-calendar--error "  No events returned (incomplete)\n")
                         (t "  No matching events\n"))
                   'face 'shadow)))
        (insert "\n")
        (add-text-properties day-start (point)
                             (list 'teams4e-calendar-day day-key 'teams4e-calendar-day-time day
                                   'rear-nonsticky t)))
      (setq day (teams4e-calendar--midnight day 1)))
    (let ((position (teams4e-calendar--anchor-position anchor)))
      (teams4e-calendar--restore-window-anchors windows)
      (goto-char position))
    (when teams4e-calendar--focus
      (teams4e-calendar--focus-time teams4e-calendar--focus teams4e-calendar--focus-day-heading)
      (when (and loaded (not teams4e-calendar--loading))
        (setq teams4e-calendar--focus nil teams4e-calendar--focus-day-heading nil)))))

(defun teams4e-calendar--cancel ()
  "Cancel any request owned by this buffer."
  (cl-incf teams4e-calendar--generation)
  (teams4e--cancel-process teams4e-calendar--request)
  (setq teams4e-calendar--request nil))

(defun teams4e-calendar-refresh ()
  "Explicitly fetch the displayed calendar range, with no chat enumeration."
  (interactive)
  (teams4e--require-online)
  (teams4e-calendar--cancel)
  (let* ((buffer (current-buffer))
         (generation teams4e-calendar--generation)
         (key (teams4e-calendar--key))
         (args (append (list "teams" "calendar" "view"
                             "--start" (nth 1 key) "--end" (nth 2 key))
                       (when (car key) (list "--calendarId" (car key))))))
    (setq teams4e-calendar--error nil teams4e-calendar--loading t)
    (teams4e-calendar--render)
    (setq teams4e-calendar--request
          (teams4e--run-json
           args
           (lambda (payload)
             (when (buffer-live-p buffer)
               (with-current-buffer buffer
                 (when (= generation teams4e-calendar--generation)
                   (setq teams4e-calendar--events (teams4e--get payload 'events)
                         teams4e-calendar--loaded-key key
                         teams4e-calendar--request nil
                         teams4e-calendar--loading nil
                         teams4e-calendar--error
                         (unless (eq t (teams4e--get payload 'complete))
                           (or (teams4e--get payload 'error) "Incomplete calendar response")))
                   (teams4e-calendar--render)))))
           (lambda (status detail)
             (teams4e--report-error args status detail)
             (when (buffer-live-p buffer)
               (with-current-buffer buffer
                 (when (= generation teams4e-calendar--generation)
                   (setq teams4e-calendar--request nil teams4e-calendar--loading nil
                         teams4e-calendar--error
                         (format "Calendar unavailable: %s" (or detail status "request failed")))
                   (teams4e-calendar--render)))))))))

(defun teams4e-calendar--show-range ()
  "Reuse the loaded range or request the newly selected one."
  (if (equal (teams4e-calendar--key) teams4e-calendar--loaded-key)
      (progn
        (teams4e-calendar--cancel)
        (setq teams4e-calendar--loading nil)
        (teams4e-calendar--render))
    (teams4e-calendar-refresh)))

(defun teams4e-calendar-set-view (view)
  "Display a day, week or month agenda VIEW."
  (interactive (list (intern (completing-read "Calendar view: " '("day" "week" "month") nil t))))
  (setq teams4e-calendar--view view
        teams4e-calendar--focus teams4e-calendar--date
        teams4e-calendar--focus-day-heading nil)
  (teams4e-calendar--show-range))

(defun teams4e-calendar-day ()
  "Display the day agenda."
  (interactive) (teams4e-calendar-set-view 'day))
(defun teams4e-calendar-week ()
  "Display the week agenda."
  (interactive) (teams4e-calendar-set-view 'week))
(defun teams4e-calendar-month ()
  "Display the month agenda."
  (interactive) (teams4e-calendar-set-view 'month))

(defun teams4e-calendar-next-period (&optional count)
  "Move COUNT periods forward without changing the view."
  (interactive "p")
  (let* ((count (or count 1))
         (date (car (teams4e-calendar--range)))
         (parts (decode-time date)))
    (setq teams4e-calendar--date
          (pcase teams4e-calendar--view
            ('month (encode-time 0 0 0 1 (+ count (nth 4 parts)) (nth 5 parts)))
            ('day (teams4e-calendar--midnight date count))
            (_ (teams4e-calendar--midnight date (* 7 count))))))
  (setq teams4e-calendar--focus teams4e-calendar--date
        teams4e-calendar--focus-day-heading nil)
  (teams4e-calendar--show-range))

(defun teams4e-calendar-previous-period (&optional count)
  "Move COUNT periods backward."
  (interactive "p")
  (teams4e-calendar-next-period (- (or count 1))))

(defun teams4e-calendar-today ()
  "Center on now or the nearest timed row in today's agenda."
  (interactive)
  (setq teams4e-calendar--date (current-time)
        teams4e-calendar--focus teams4e-calendar--date
        teams4e-calendar--focus-day-heading nil)
  (teams4e-calendar--show-range))

(defun teams4e-calendar-next-slot ()
  "Center on the ongoing or next timed slot, never an ended event.
After today's last slot, visit tomorrow.  Without today's snapshot, after
working hours start on tomorrow instead.  Empty days land on their heading."
  (interactive)
  (let* ((now (current-time))
         (target
          (let ((teams4e-calendar--date now))
            (if (if (equal (teams4e-calendar--key) teams4e-calendar--loaded-key)
                    (or (seq-some
                         (lambda (event)
                           (and (not (teams4e--get event 'isAllDay))
                                (time-less-p now (teams4e-calendar--time event 'end))))
                         (teams4e-calendar--day-events (teams4e-calendar--midnight now)))
                        (seq-some (lambda (gap) (> (cadr gap) (float-time now)))
                                  (teams4e-calendar--free-gaps (teams4e-calendar--midnight now))))
                  (< (nth 2 (decode-time now)) (cdr teams4e-calendar-work-hours)))
                now
              (teams4e-calendar--midnight now 1)))))
    (setq teams4e-calendar--date target
          teams4e-calendar--focus target
          teams4e-calendar--focus-day-heading 'upcoming)
    (teams4e-calendar--show-range)))

(defun teams4e-calendar-goto-date ()
  "Choose a date with Org's calendar date reader."
  (interactive)
  (setq teams4e-calendar--date (org-read-date nil t nil "Calendar date: ")
        teams4e-calendar--focus teams4e-calendar--date
        teams4e-calendar--focus-day-heading nil)
  (teams4e-calendar--show-range))

(defun teams4e-calendar-filter (text)
  "Filter the loaded view by literal TEXT; an empty string clears it."
  (interactive (list (read-string "Calendar filter (empty clears): " teams4e-calendar--filter)))
  (setq teams4e-calendar--filter text)
  (teams4e-calendar--render))

(defun teams4e-calendar-toggle-declined ()
  "Toggle cancelled and declined events without making a request."
  (interactive)
  (setq teams4e-calendar--show-declined (not teams4e-calendar--show-declined))
  (teams4e-calendar--render))

(defun teams4e-calendar-next-day (&optional count)
  "Move COUNT local days, reusing the snapshot while inside its range."
  (interactive "p")
  (let ((date (or (get-text-property (point) 'teams4e-calendar-day-time)
                  teams4e-calendar--date)))
    (setq teams4e-calendar--date (teams4e-calendar--midnight date (or count 1))
          teams4e-calendar--focus teams4e-calendar--date
          teams4e-calendar--focus-day-heading t)
    (teams4e-calendar--show-range)))

(defun teams4e-calendar-previous-day (&optional count)
  "Move COUNT days backward."
  (interactive "p")
  (teams4e-calendar-next-day (- (or count 1))))

(defun teams4e-calendar-next-event (&optional backward)
  "Move to an event's first line, skipping gaps and metadata.
With BACKWARD, move to the previous event.  Stay put at the boundary."
  (interactive)
  (setq teams4e-calendar--focus nil teams4e-calendar--focus-day-heading nil)
  (let* ((step (if backward -1 1))
         (original (point))
         (item (get-text-property original 'teams4e-calendar-item))
         found)
    (forward-line step)
    (while (and (not found) (not (if backward (bobp) (eobp))))
      (when (and (get-text-property (point) 'teams4e-calendar-event-start)
                 (not (equal item (get-text-property (point) 'teams4e-calendar-item))))
        (setq found (point)))
      (unless found (forward-line step)))
    (goto-char (or found original))
    (when found
      (setq teams4e-calendar--date
            (get-text-property found 'teams4e-calendar-day-time)))))

(defun teams4e-calendar-previous-event ()
  "Move to the previous calendar event."
  (interactive)
  (teams4e-calendar-next-event t))

(defun teams4e-calendar--context ()
  "Return (OWNER EVENT) for the current row or detail buffer."
  (let* ((owner (or teams4e-calendar--owner (current-buffer)))
         (id (or teams4e-calendar--event-id
                 (get-text-property (point) 'teams4e-calendar-event))))
    (unless (and id (buffer-live-p owner)) (user-error "No calendar event here"))
    (with-current-buffer owner
      (unless (equal (teams4e-calendar--key) teams4e-calendar--loaded-key)
        (user-error "This calendar range is not loaded yet"))
      (list owner (or (seq-find (lambda (event) (equal id (teams4e--get event 'id)))
                               teams4e-calendar--events)
                      (user-error "This event is no longer in the loaded range"))))))

(defun teams4e-calendar--replace-event (event)
  "Merge updated EVENT into the current canonical snapshot by ID."
  (let ((old (seq-find (lambda (item) (equal (teams4e--get item 'id)
                                           (teams4e--get event 'id)))
                       teams4e-calendar--events)))
    (when old
      (let ((merged (copy-tree old)))
        (dolist (pair event)
          (setf (alist-get (car pair) merged) (cdr pair)))
        (setq teams4e-calendar--events
              (mapcar (lambda (item) (if (eq item old) merged item))
                      teams4e-calendar--events))))))

(defun teams4e-calendar--render-detail ()
  "Render the selected event from its owning calendar buffer."
  (pcase-let* ((`(,owner ,event) (teams4e-calendar--context))
               (inhibit-read-only t))
    (erase-buffer)
    (insert (propertize (teams4e-calendar--line (teams4e--get event 'subject))
                        'face '(:inherit bold :height 1.15)) "\n\n")
    (dolist (field '(start end))
      (when-let ((time (teams4e-calendar--time event field)))
        (insert (format "%-10s%s\n" (capitalize (symbol-name field))
                        (format-time-string "%a %d %b %Y  %H:%M %Z" time)))))
    (when (teams4e--get event 'isAllDay) (insert "All-day event (end date exclusive)\n"))
    (let ((availability (teams4e-calendar--availability event)))
      (insert "Show as   " (propertize (car availability) 'face (cadr availability)) "\n"))
    (insert "Status    " (teams4e-calendar--status event) "\n"
            "Location  " (or (teams4e--dig event 'location 'displayName) "") "\n"
            "Organizer " (or (teams4e--dig event 'organizer 'emailAddress 'name) "") "\n")
    (when (teams4e--get event 'seriesMasterId)
      (insert "Series    Recurring occurrence\n"))
    (insert "\n")
    (dolist (link `(("Open in Outlook" . ,(teams4e--get event 'webLink))
                    ("Join meeting" . ,(or (teams4e--dig event 'onlineMeeting 'joinUrl)
                                          (teams4e--get event 'onlineMeetingUrl)))))
      (when (cdr link)
        (insert-text-button (car link) 'follow-link t
                            'action (let ((url (cdr link)))
                                      (lambda (_) (teams4e--open-url-in-browser url))))
        (insert "   ")))
    (when (and (teams4e--get event 'webLink)
               (not (teams4e--get event 'isOrganizer))
               (not (teams4e--get event 'isCancelled)))
      (insert-text-button "Follow in Outlook" 'follow-link t
                          'action (lambda (_) (teams4e-calendar-follow-in-outlook)))
      (insert "   "))
    (when (teams4e-calendar--chat-id event)
      (insert-text-button "Teams chat" 'follow-link t
                          'action (lambda (_) (teams4e-calendar-open-chat)))
      (insert "   "))
    (insert-text-button (if (teams4e--get event 'isOrganizer)
                            "Availability / reschedule" "Availability / propose time") 'follow-link t
                        'action (lambda (_) (teams4e-calendar-availability)))
    (insert "\n\n")
    (teams4e-calendar--insert-event-conflicts owner event)
    (when (teams4e--get event 'attendees)
      (insert (propertize "Participants\n" 'face 'bold))
    (dolist (attendee (teams4e--get event 'attendees))
      (insert "          " (or (teams4e--dig attendee 'emailAddress 'name) "")
              " <" (or (teams4e--dig attendee 'emailAddress 'address) "") ">  "
              (or (teams4e--dig attendee 'status 'response) "") "\n"))
      (insert "\n"))
    (let ((body (teams4e--dig event 'body 'content)))
      (if (and body (equal (downcase (or (teams4e--dig event 'body 'contentType) "")) "html")
               (fboundp 'libxml-parse-html-region))
          (let ((dom (with-temp-buffer
                       (insert body) (libxml-parse-html-region (point-min) (point-max))))
                (shr-inhibit-images t) (shr-use-fonts nil))
            (shr-insert-document dom))
        (insert (or body (teams4e--get event 'bodyPreview) ""))))
    (goto-char (point-min))))

(defun teams4e-calendar--refresh-reader (owner)
  "Redraw the singleton reader when it refers to OWNER's current snapshot."
  (when-let ((reader (get-buffer teams4e-calendar--detail-name)))
    (with-current-buffer reader
      (when (and (eq teams4e-calendar--owner owner)
                 (ignore-errors (teams4e-calendar--context)))
        (let ((position (point)))
          (teams4e-calendar--render-detail)
          (goto-char (min position (point-max))))))))

(defun teams4e-calendar-open-event ()
  "Open the singleton event reader; fetch its full body only on demand."
  (interactive)
  (pcase-let* ((`(,owner ,event) (teams4e-calendar--context))
               (id (teams4e--get event 'id))
               (buffer (get-buffer-create teams4e-calendar--detail-name))
               (generation (buffer-local-value 'teams4e-calendar--generation owner)))
    (with-current-buffer buffer
      (teams4e-calendar-event-mode)
      (setq teams4e-calendar--owner owner teams4e-calendar--event-id id)
      (teams4e-calendar--render-detail))
    (pop-to-buffer buffer '((display-buffer-reuse-window display-buffer-below-selected)))
    (unless (or (assq 'body event) teams4e-offline-mode)
      (teams4e--run-json
       (list "teams" "calendar" "event" "get" "--eventId" id)
       (lambda (payload)
         (when (and (buffer-live-p owner)
                    (= generation (buffer-local-value 'teams4e-calendar--generation owner)))
           (with-current-buffer owner (teams4e-calendar--replace-event payload))
           (when (and (buffer-live-p buffer)
                      (equal id (buffer-local-value 'teams4e-calendar--event-id buffer)))
             (with-current-buffer buffer (teams4e-calendar--render-detail)))))
       (lambda (_status detail)
         (message "Calendar details unavailable: %s" (or detail "request failed")))))))

(defun teams4e-calendar-open-outlook ()
  "Open the selected event in Outlook, or the calendar if no event is selected."
  (interactive)
  (let ((event (ignore-errors (cadr (teams4e-calendar--context)))))
    (teams4e--open-url-in-browser
     (or (teams4e--get event 'webLink) teams4e-calendar-outlook-url))))

(defun teams4e-calendar--follow-url (event)
  "Return EVENT's verified Outlook web link, never an RSVP-action URL.
Convert only Microsoft's documented legacy OWA format to its modern item URL."
  (let* ((link (teams4e--get event 'webLink))
         (url (and (stringp link) (url-generic-parse-url link)))
         (host (and url (downcase (or (url-host url) "")))))
    (unless (and url (equal (url-type url) "https")
                 (member host '("outlook.office.com" "outlook.office365.com" "outlook.live.com"))
                 (not (url-user url)) (not (url-password url)))
      (user-error "This invitation has no supported HTTPS Outlook webLink"))
    (pcase-let ((`(,path . ,query) (url-path-and-query url)))
      (let ((id (and query (cadr (assoc "itemid" (url-parse-query-string query))))))
        (if (and (member host '("outlook.office365.com" "outlook.live.com"))
                 (equal path "/owa/") (stringp id) (not (string-empty-p id)))
            (concat "https://" host "/calendar/item/" (url-hexify-string id))
          link)))))

(defun teams4e-calendar-follow-in-outlook ()
  "Open this invitation for Follow in Outlook; the user must choose Follow there.
No RSVP is sent or inferred.  Background opening is browser-dependent."
  (interactive)
  (let* ((event (cadr (teams4e-calendar--context)))
         (url (teams4e-calendar--follow-url event))
         (command
          (if (eq teams4e-calendar-follow-browser-command 'auto)
              (if (eq system-type 'darwin)
                  (if (and teams4e-browser-command
                           (equal (file-name-nondirectory (car teams4e-browser-command)) "open"))
                      (append teams4e-browser-command '("-g"))
                    '("/usr/bin/open" "-g"))
                teams4e-browser-command)
            teams4e-calendar-follow-browser-command)))
    (when (or (teams4e--get event 'isOrganizer) (teams4e--get event 'isCancelled))
      (user-error "Follow is for received, non-cancelled invitations"))
    (teams4e--open-with-command url command "Outlook invitation")
    (message "Opening invitation; choose Follow in Outlook. No response changed in teams4e.")))

(defun teams4e-calendar--chat-id (event)
  "Extract the exact, case-sensitive Teams thread ID from EVENT's join URL.
Short meeting links without a thread ID cannot be resolved locally."
  (let* ((url (or (teams4e--dig event 'onlineMeeting 'joinUrl)
                  (teams4e--get event 'onlineMeetingUrl)))
         (path (and url (url-unhex-string (url-filename (url-generic-parse-url url)))))
         (case-fold-search nil))
    (when (and path
               (string-match "/\\(19:meeting_[^/?#]+@thread\\.[[:alnum:]]+\\)\\(?:/\\|\\'\\)"
                             path))
      (match-string 1 path))))

(defun teams4e-calendar-open-chat ()
  "Open this invitation's real Teams chat without enumerating recent chats."
  (interactive)
  (teams4e--require-online)
  (let* ((event (cadr (teams4e-calendar--context)))
         (id (teams4e-calendar--chat-id event)))
    (unless id
      (user-error "This invitation has no resolvable Teams thread link; use v to join or o for Outlook"))
    (teams4e--run-json
     (list "teams" "chat" "get" "--chatId" id)
     (lambda (chat) (teams4e-open-chat chat)))))

(defun teams4e-calendar-join ()
  "Join the selected event, if it has an online meeting URL."
  (interactive)
  (let* ((event (cadr (teams4e-calendar--context)))
         (url (or (teams4e--dig event 'onlineMeeting 'joinUrl)
                  (teams4e--get event 'onlineMeetingUrl))))
    (unless url (user-error "This event has no online meeting link"))
    (teams4e--open-url-in-browser url)))

(defun teams4e-calendar-respond ()
  "Respond to the selected event; accepting without a note sends no response."
  (interactive)
  (teams4e--require-online)
  (pcase-let* ((`(,owner ,event) (teams4e-calendar--context))
               (generation (buffer-local-value 'teams4e-calendar--generation owner)))
    (when (or (teams4e--get event 'isOrganizer) (teams4e--get event 'isCancelled)
              (null (teams4e--get event 'attendees)))
      (user-error "This event cannot be answered as an invitation"))
    (let* ((response (completing-read "Response: " '("accepted" "tentativelyAccepted" "declined") nil t))
           (comment (read-string (if (equal response "accepted")
                                     "Note (empty: accept without notifying): "
                                   "Note to organizer: "))))
      (teams4e--run-json
       (list "teams" "meeting" "respond" "--eventId" (teams4e--get event 'id)
             "--response" response "--comment" comment)
       (lambda (payload)
         (when (and (buffer-live-p owner)
                    (= generation (buffer-local-value 'teams4e-calendar--generation owner)))
           (with-current-buffer owner
             (teams4e-calendar--replace-event (teams4e--get payload 'event))
             (teams4e-calendar--render))
           (teams4e-calendar--refresh-reader owner))
         (message "Calendar response saved: %s" response))))))

(defun teams4e-calendar-capture ()
  "Capture an event action and its metadata, not a copy of the calendar."
  (interactive)
  (let* ((event (cadr (teams4e-calendar--context)))
         (url (teams4e--get event 'webLink))
         (title (teams4e-calendar--line (teams4e--get event 'subject)))
         (start (teams4e-calendar--time event 'start)))
    (org-capture-string
     (concat "* " (if url (org-link-make-string url title) title) "\n"
             (when start (concat (format-time-string "<%Y-%m-%d %a %H:%M>" start) "\n"))
             ":PROPERTIES:\n:CALENDAR_EVENT_ID: " (teams4e--get event 'id)
             "\n:LOCATION: " (teams4e-calendar--line (teams4e--dig event 'location 'displayName))
             "\n:END:\n")
     teams4e-calendar-capture-key)))

(defun teams4e-calendar-availability ()
  "Inspect availability; propose a time or reschedule an event you organize."
  (interactive)
  (teams4e--require-online)
  (pcase-let* ((`(,owner ,event) (teams4e-calendar--context))
               (buffer (get-buffer-create teams4e--availability-buffer-name))
               (configuration (current-window-configuration))
               (frame (selected-frame))
               (day (teams4e-calendar--midnight
                     (or (teams4e-calendar--time event 'start) (current-time)))))
    (with-current-buffer buffer
      (teams4e--cancel-process teams4e-availability--request)
      (teams4e-availability-mode)
      (setq teams4e-availability--source-event event
            teams4e-availability--event-id (teams4e--get event 'id)
            teams4e-availability--window
            (list (teams4e-calendar--midnight day -1)
                  (teams4e-calendar--midnight
                   day (max 1 teams4e-meeting-proposal-search-days)))
            teams4e-availability--day day
            teams4e-availability--activity-domain teams4e-meeting-proposal-activity-domain
            teams4e-availability--window-configuration configuration
            teams4e-availability--origin-frame frame
            teams4e-availability--proposal-function #'teams4e-calendar--propose
            teams4e-calendar--owner owner
            teams4e-calendar--event-id (teams4e--get event 'id))
      (use-local-map (copy-keymap teams4e-availability-mode-map))
      (local-set-key (kbd "v") #'teams4e-calendar-respond)
      (local-set-key (kbd "J") #'teams4e-calendar-join)
      (local-set-key (kbd "o") #'teams4e-calendar-open-outlook)
      (when (fboundp 'evil-local-set-key)
        (dolist (state '(normal motion))
          (evil-local-set-key state (kbd "v") #'teams4e-calendar-respond)
          (evil-local-set-key state (kbd "J") #'teams4e-calendar-join)
          (evil-local-set-key state (kbd "o") #'teams4e-calendar-open-outlook))))
    (pop-to-buffer buffer)
    (teams4e-availability--request)))

(defun teams4e-calendar--propose (slot)
  "Propose or reschedule to SLOT; read an exact time when SLOT is nil."
  (teams4e--require-online)
  (teams4e-availability--require-proposal)
  (pcase-let* ((`(,owner ,event) (teams4e-calendar--context))
               (workspace (current-buffer))
               (generation (buffer-local-value 'teams4e-calendar--generation owner)))
    (unless slot
      (let* ((original (teams4e-calendar--time event 'start))
             (end (teams4e-calendar--time event 'end))
             (start (org-read-date t t nil "Proposed start: " original))
             (finish (time-add start (time-subtract end original))))
        (setq slot `((start (dateTime . ,(format-time-string "%Y-%m-%dT%H:%M:%SZ" start t))
                           (timeZone . "UTC"))
                     (end (dateTime . ,(format-time-string "%Y-%m-%dT%H:%M:%SZ" finish t))
                         (timeZone . "UTC"))))))
    (let* ((reschedule (teams4e-availability--reschedule-p))
           (comment (unless reschedule
                      (read-string "Proposal note to organizer: "
                                   teams4e-meeting-proposal-default-comment))))
      (teams4e--run-json
       (append (if reschedule '("teams" "calendar" "event" "reschedule")
                 '("teams" "meeting" "propose" "send"))
               (list "--eventId" (teams4e--get event 'id)
                     "--start" (teams4e--event-date-time slot 'start)
                     "--end" (teams4e--event-date-time slot 'end))
               (unless reschedule (list "--comment" comment)))
       (lambda (payload)
         (when (and (buffer-live-p owner)
                    (= generation (buffer-local-value 'teams4e-calendar--generation owner)))
           (with-current-buffer owner
             (teams4e-calendar--replace-event (teams4e--get payload 'event))
             (teams4e-calendar--render))
           (teams4e-calendar--refresh-reader owner))
         (when (and (buffer-live-p workspace)
                    (eq owner (buffer-local-value 'teams4e-calendar--owner workspace))
                    (equal (teams4e--get event 'id)
                           (buffer-local-value 'teams4e-calendar--event-id workspace)))
           (with-current-buffer workspace (teams4e-availability-quit)))
         (message (if reschedule "Calendar event rescheduled" "Calendar time proposal sent")))))))

(defun teams4e-calendar-select ()
  "Choose a calendar visible to the signed-in user."
  (interactive)
  (teams4e--require-online)
  (let ((buffer (current-buffer)))
    (teams4e--run-json
     '("teams" "calendar" "list")
     (lambda (calendars)
       (when (buffer-live-p buffer)
         (let* ((choices
                 (cons '("Primary calendar" . nil)
                       (mapcar
                        (lambda (calendar)
                          (cons (format "%s <%s> [%s]"
                                        (teams4e--get calendar 'name)
                                        (or (teams4e--dig calendar 'owner 'address) "")
                                        (teams4e--get calendar 'id))
                                (teams4e--get calendar 'id)))
                        calendars)))
                (choice (completing-read "Calendar: " choices nil t)))
           (with-current-buffer buffer
             (setq teams4e-calendar--id (cdr (assoc choice choices))
                   teams4e-calendar--name
                   (or (teams4e--get
                        (seq-find (lambda (item)
                                    (equal teams4e-calendar--id (teams4e--get item 'id)))
                                  calendars)
                        'name)
                       "Primary calendar"))
             (teams4e-calendar--show-range))))))))

(defvar teams4e-calendar-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (dolist (binding '(("j" . teams4e-calendar-next-event)
                       ("J" . teams4e-calendar-next-event)
                       ("K" . teams4e-calendar-previous-event)
                       ("h" . teams4e-calendar-previous-day)
                       ("H" . teams4e-calendar-previous-day)
                       ("l" . teams4e-calendar-next-day)
                       ("L" . teams4e-calendar-next-day)
                       ("." . teams4e-calendar-goto-date)
                       ("k" . teams4e-calendar-previous-event)
                       ("n" . teams4e-calendar-next-event)
                       ("p" . teams4e-calendar-previous-event)
                       ("]" . teams4e-calendar-next-period)
                       ("[" . teams4e-calendar-previous-period)
                       ("t" . teams4e-calendar-today)
                       ("N" . teams4e-calendar-next-slot)
                       ("G" . teams4e-calendar-goto-date)
                       ("d" . teams4e-calendar-day)
                       ("w" . teams4e-calendar-week)
                       ("m" . teams4e-calendar-month)
                       ("g" . teams4e-calendar-refresh)
                       ("/" . teams4e-calendar-filter)
                       ("x" . teams4e-calendar-toggle-declined)
                       ("c" . teams4e-calendar-select)
                       ("RET" . teams4e-calendar-activate)
                       ("TAB" . teams4e-calendar-toggle-section)
                       ("<tab>" . teams4e-calendar-toggle-section)
                       ("o" . teams4e-calendar-open-outlook)
                       ("f" . teams4e-calendar-follow-in-outlook)
                       ("v" . teams4e-calendar-join)
                       ("T" . teams4e-calendar-open-chat)
                       ("r" . teams4e-calendar-availability)
                       ("a" . teams4e-calendar-respond)
                       ("A" . teams4e-calendar-availability)
                       ("C" . teams4e-calendar-capture)))
      (define-key map (kbd (car binding)) (cdr binding)))
    map))

;; Extend already-loaded maps during a Lisp-only update, preserving custom keys.
(dolist (binding '(("f" . teams4e-calendar-follow-in-outlook)
                   ("N" . teams4e-calendar-next-slot)
                   ("TAB" . teams4e-calendar-toggle-section)
                   ("<tab>" . teams4e-calendar-toggle-section)
                   ("RET" . teams4e-calendar-activate)))
  (when (memq (lookup-key teams4e-calendar-mode-map (kbd (car binding)))
              '(nil teams4e-calendar-open-event))
    (define-key teams4e-calendar-mode-map (kbd (car binding)) (cdr binding))))

(defvar teams4e-calendar-event-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (dolist (binding '(("o" . teams4e-calendar-open-outlook)
                       ("f" . teams4e-calendar-follow-in-outlook)
                       ("v" . teams4e-calendar-join)
                       ("T" . teams4e-calendar-open-chat)
                       ("r" . teams4e-calendar-availability)
                       ("a" . teams4e-calendar-respond)
                       ("A" . teams4e-calendar-availability)
                       ("C" . teams4e-calendar-capture)))
      (define-key map (kbd (car binding)) (cdr binding)))
    map))

(defun teams4e-calendar--install-navigation ()
  "Keep agenda navigation ahead of Evil's window motions.
Read the public mode map so user customizations remain authoritative."
  (when (fboundp 'evil-local-set-key)
    (dolist (state '(normal motion))
      (dolist (key '("j" "k" "J" "K" "h" "l" "H" "L" "t" "N" "f" "TAB" "<tab>" "RET"))
        (evil-local-set-key state (kbd key)
                            (lookup-key teams4e-calendar-mode-map (kbd key)))))))

(define-derived-mode teams4e-calendar-mode special-mode "Teams-Calendar"
  "Browse calendar events independently of Teams chat history."
  (teams4e-calendar--install-navigation)
  (hl-line-mode 1)
  (setq-local truncate-lines nil)
  (setq-local word-wrap t)
  (setq-local teams4e-calendar--date (current-time)
              teams4e-calendar--focus teams4e-calendar--date
              teams4e-calendar--view teams4e-calendar-default-view
              teams4e-calendar--id teams4e-calendar-id
              teams4e-calendar--show-declined teams4e-calendar-show-declined)
  (add-hook 'kill-buffer-hook #'teams4e-calendar--cancel nil t))

(define-derived-mode teams4e-calendar-event-mode special-mode "Teams-Event"
  "Read a calendar event and act on it."
  (setq-local word-wrap t)
  (when (fboundp 'evil-local-set-key)
    (dolist (state '(normal motion))
      (evil-local-set-key state (kbd "f")
                          (lookup-key teams4e-calendar-event-mode-map (kbd "f"))))))

;; Extend a reader map already loaded before this command was available.
(unless (lookup-key teams4e-calendar-event-mode-map (kbd "f"))
  (define-key teams4e-calendar-event-mode-map (kbd "f") #'teams4e-calendar-follow-in-outlook))

(with-eval-after-load 'evil
  (dolist (mode '(teams4e-calendar-mode teams4e-calendar-event-mode))
    (evil-set-initial-state mode 'motion))
  (evil-make-overriding-map teams4e-calendar-mode-map 'motion)
  (evil-make-overriding-map teams4e-calendar-event-mode-map 'motion))

;;;###autoload
(defun teams4e-calendar (&optional refresh)
  "Resume the independent calendar; prefix REFRESH explicitly reloads it.
The first invocation opens the current week by default, without loading chats."
  (interactive "P")
  (let ((existing (get-buffer teams4e-calendar--buffer-name))
        (buffer (get-buffer-create teams4e-calendar--buffer-name)))
    (with-current-buffer buffer
      (unless (derived-mode-p 'teams4e-calendar-mode) (teams4e-calendar-mode))
      (teams4e-calendar--install-navigation)
      (hl-line-mode 1)
      (when existing (teams4e-calendar--render)))
    (pop-to-buffer buffer)
    (when (or refresh (not existing))
      (teams4e-calendar-refresh))))

(provide 'teams4e-calendar)
;;; teams4e-calendar.el ends here
