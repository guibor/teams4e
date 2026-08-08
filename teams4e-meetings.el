;;; teams4e-meetings.el --- Meeting workspace and availability -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; A singleton, calendar-backed meeting workspace layered on the canonical
;; Teams chat object.  It renders ranked times, participant free/busy state,
;; returned calendar blocks, RSVP, join, and calendar fallback actions without
;; retaining another calendar or proposal database.

;;; Code:

(require 'teams4e-advanced)
(require 'button)
(require 'cl-lib)
(require 'seq)
(require 'subr-x)

(declare-function evil-define-key* "evil-core")

(defvar teams4e-meeting-availability-interval)

(defconst teams4e--availability-buffer-name "*Teams Availability*")

(defvar-local teams4e-availability--chat nil)
(defvar-local teams4e-availability--event-id nil)
(defvar-local teams4e-availability--payload nil)
(defvar-local teams4e-availability--window nil)
(defvar-local teams4e-availability--activity-domain 'work)
(defvar-local teams4e-availability--view 'suggestions)
(defvar-local teams4e-availability--selected-id nil)
(defvar-local teams4e-availability--row-ids nil)
(defvar-local teams4e-availability--request nil)
(defvar-local teams4e-availability--window-configuration nil)
(defvar-local teams4e-availability--origin-frame nil)
(defvar-local teams4e-availability--error nil)

(defface teams4e-availability-free
  '((t :inherit success))
  "Face for an available participant."
  :group 'teams4e)

(defface teams4e-availability-busy
  '((t :inherit font-lock-warning-face :weight semi-bold))
  "Face for a busy participant or calendar block."
  :group 'teams4e)

(defface teams4e-availability-tentative
  '((t :inherit font-lock-constant-face))
  "Face for tentative availability."
  :group 'teams4e)

(defface teams4e-availability-oof
  '((t :inherit font-lock-keyword-face :weight semi-bold))
  "Face for out-of-office availability."
  :group 'teams4e)

(defface teams4e-availability-unknown
  '((t :inherit shadow))
  "Face for unavailable free/busy information."
  :group 'teams4e)

(defface teams4e-availability-selected
  '((t :inherit highlight :weight semi-bold))
  "Face for the selected availability row."
  :group 'teams4e)

(defun teams4e-availability--participants ()
  "Return normalized participants from the current availability payload."
  (teams4e--get teams4e-availability--payload 'participants))

(defun teams4e-availability--schedules ()
  "Return free/busy schedules from the current availability payload."
  (teams4e--get teams4e-availability--payload 'schedules))

(defun teams4e-availability--suggestions ()
  "Return ranked suggestions from the current availability payload."
  (teams4e--get teams4e-availability--payload 'suggestions))

(defun teams4e-availability--participant-name (participant)
  "Return a compact display name for PARTICIPANT."
  (if (teams4e--get participant 'isSelf)
      "You"
    (or (teams4e--get participant 'name)
        (teams4e--get participant 'email)
        "Unknown")))

(defun teams4e-availability--participant-email (participant)
  "Return PARTICIPANT's normalized email address."
  (when-let ((email (teams4e--get participant 'email)))
    (downcase email)))

(defun teams4e-availability--schedule (participant)
  "Return the schedule record matching PARTICIPANT."
  (let ((wanted (teams4e-availability--participant-email participant)))
    (seq-find
     (lambda (schedule)
       (let ((address (teams4e--get schedule 'scheduleId)))
         (and wanted (stringp address)
              (string-equal wanted (downcase address)))))
     (teams4e-availability--schedules))))

(defun teams4e-availability--status-name (status)
  "Return a concise display name for Graph availability STATUS."
  (pcase (and status (downcase status))
    ("free" "Free")
    ("workingelsewhere" "Elsewhere")
    ("tentative" "Tentative")
    ("busy" "Busy")
    ((or "oof" "outofoffice") "OOF")
    (_ "Unknown")))

(defun teams4e-availability--status-face (status)
  "Return the semantic face for Graph availability STATUS."
  (pcase (and status (downcase status))
    ((or "free" "workingelsewhere") 'teams4e-availability-free)
    ("tentative" 'teams4e-availability-tentative)
    ("busy" 'teams4e-availability-busy)
    ((or "oof" "outofoffice") 'teams4e-availability-oof)
    (_ 'teams4e-availability-unknown)))

(defun teams4e-availability--blocking-status-p (status)
  "Return non-nil when availability STATUS should be treated as a conflict."
  (not (member (and status (downcase status))
               '("free" "workingelsewhere"))))

(defun teams4e-availability--suggestion-status (suggestion participant)
  "Return PARTICIPANT's availability in SUGGESTION."
  (if (teams4e--get participant 'isSelf)
      (or (teams4e--get suggestion 'organizerAvailability) "unknown")
    (let ((wanted (teams4e-availability--participant-email participant)))
      (or
       (seq-some
        (lambda (entry)
          (let ((address
                 (teams4e--dig entry 'attendee 'emailAddress 'address)))
            (when (and wanted (stringp address)
                       (string-equal wanted (downcase address)))
              (teams4e--get entry 'availability))))
        (teams4e--get suggestion 'attendeeAvailability))
       "unknown"))))

(defun teams4e-availability--time (object field)
  "Return OBJECT FIELD as an Emacs time value."
  (when-let ((value (teams4e--event-date-time object field)))
    (ignore-errors (date-to-time value))))

(defun teams4e-availability--overlap-p (item slot)
  "Return non-nil when calendar ITEM overlaps time SLOT."
  (let ((item-start (teams4e-availability--time item 'start))
        (item-end (teams4e-availability--time item 'end))
        (slot-start (teams4e-availability--time slot 'start))
        (slot-end (teams4e-availability--time slot 'end)))
    (and item-start item-end slot-start slot-end
         (time-less-p item-start slot-end)
         (time-less-p slot-start item-end))))

(defun teams4e-availability--conflict-items (participant slot)
  "Return PARTICIPANT's non-free calendar items overlapping SLOT."
  (seq-filter
   (lambda (item)
     (and (teams4e-availability--blocking-status-p
           (teams4e--get item 'status))
          (teams4e-availability--overlap-p item slot)))
   (teams4e--get (teams4e-availability--schedule participant)
                  'scheduleItems)))

(defun teams4e-availability--block-title (item)
  "Return a privacy-aware title for calendar ITEM."
  (cond
   ((teams4e--get item 'isPrivate) "Private block")
   ((let ((subject (teams4e--get item 'subject)))
      (and (stringp subject) (not (string-empty-p subject)) subject)))
   (t (format "%s block"
              (teams4e-availability--status-name
               (teams4e--get item 'status))))))

(defun teams4e-availability--block-location (item)
  "Return a readable location from calendar ITEM."
  (unless (teams4e--get item 'isPrivate)
    (let ((location (teams4e--get item 'location)))
      (cond
       ((stringp location) location)
       ((listp location) (teams4e--get location 'displayName))
       (t nil)))))

(defun teams4e-availability--slot-id (suggestion)
  "Return a stable identifier for SUGGESTION's time slot."
  (let ((slot (teams4e--get suggestion 'meetingTimeSlot)))
    (format "%s/%s"
            (or (teams4e--event-date-time slot 'start) "")
            (or (teams4e--event-date-time slot 'end) ""))))

(defun teams4e-availability--selected-suggestion ()
  "Return the currently selected ranked suggestion."
  (seq-find
   (lambda (suggestion)
     (equal teams4e-availability--selected-id
            (teams4e-availability--slot-id suggestion)))
   (teams4e-availability--suggestions)))

(defun teams4e-availability--confidence-face (confidence)
  "Return a face appropriate for CONFIDENCE percentage."
  (cond
   ((>= confidence 80) 'teams4e-availability-free)
   ((>= confidence 50) 'teams4e-availability-tentative)
   (t 'teams4e-availability-busy)))

(defun teams4e-availability--insert-tab (label view)
  "Insert one availability tab LABEL selecting VIEW."
  (if (eq teams4e-availability--view view)
      (insert (propertize label 'face 'bold))
    (insert-text-button
     label
     'follow-link t
     'help-echo (format "Show %s" (downcase label))
     'teams4e-availability-view view
     'action
     (lambda (button)
       (teams4e-availability-set-view
        (button-get button 'teams4e-availability-view))))))

(defun teams4e-availability--format-window ()
  "Return the current availability search window in local time."
  (if (and (car teams4e-availability--window)
           (cadr teams4e-availability--window))
      (format "%s - %s"
              (format-time-string "%a %b %e %H:%M"
                                  (car teams4e-availability--window))
              (format-time-string "%a %b %e %H:%M"
                                  (cadr teams4e-availability--window)))
    "unknown"))

(defun teams4e-availability--insert-heading ()
  "Insert meeting and search context for the availability workspace."
  (let* ((event (teams4e--get teams4e-availability--payload 'event))
         (where (teams4e--meeting-location-label teams4e-availability--chat))
         (response (teams4e--meeting-status-label teams4e-availability--chat))
         (participants (teams4e-availability--participants))
         (proposal-reason
          (teams4e--get teams4e-availability--payload
                         'proposalUnavailableReason)))
    (insert (propertize (teams4e--chat-label teams4e-availability--chat)
                        'face '(:weight bold :height 1.15)))
    (insert "\n")
    (insert (format "Current: %s"
                    (or (teams4e--meeting-time-label
                         teams4e-availability--chat)
                        "calendar time unavailable")))
    (when response (insert (format "  |  %s" response)))
    (when where (insert (format "  |  %s" where)))
    (insert "\n")
    (insert (format "Search: %s  |  %s hours  |  %d participant%s\n"
                    (teams4e-availability--format-window)
                    (symbol-name teams4e-availability--activity-domain)
                    (length participants)
                    (if (= (length participants) 1) "" "s")))
    (when proposal-reason
      (insert (propertize (concat proposal-reason "\n")
                          'face 'teams4e-availability-tentative)))
    (when-let ((schedule-error
                (teams4e--get teams4e-availability--payload 'scheduleError)))
      (insert (propertize
               (format "Calendar blocks unavailable: %s\n" schedule-error)
               'face 'teams4e-availability-busy)))
    (when (and event (teams4e--get event 'isCancelled))
      (insert (propertize "This meeting is cancelled.\n"
                          'face 'teams4e-availability-busy)))
    (insert "\n")
    (teams4e-availability--insert-tab "Suggestions" 'suggestions)
    (insert "   ")
    (teams4e-availability--insert-tab "Calendar blocks" 'blocks)
    (insert "\n\n")))

(defun teams4e-availability--insert-suggestion-details (suggestion)
  "Insert participant conflicts and returned blocks for SUGGESTION."
  (when suggestion
    (let* ((slot (teams4e--get suggestion 'meetingTimeSlot))
           (confidence (or (teams4e--get suggestion 'confidence) 0))
           (reason (teams4e--get suggestion 'suggestionReason))
           available conflicts)
      (insert (propertize
               (format "Selected: %s  |  %d%% confidence\n"
                       (or (teams4e--meeting-slot-time-label slot)
                           "unknown time")
                       confidence)
               'face 'bold))
      (dolist (participant (teams4e-availability--participants))
        (let* ((name (teams4e-availability--participant-name participant))
               (status
                (teams4e-availability--suggestion-status
                 suggestion participant))
               (items
                (teams4e-availability--conflict-items participant slot)))
          (if (teams4e-availability--blocking-status-p status)
              (push (list participant status items) conflicts)
            (push (if (equal (downcase status) "workingelsewhere")
                      (format "%s (elsewhere)" name)
                    name)
                  available))))
      (insert (format "Available: %s\n"
                      (if available
                          (string-join (nreverse available) ", ")
                        "none confirmed")))
      (if conflicts
          (progn
            (insert (propertize "Conflicts and unknown availability:\n"
                                'face 'teams4e-availability-busy))
            (dolist (conflict (nreverse conflicts))
              (pcase-let ((`(,participant ,status ,items) conflict))
                (insert "  "
                        (propertize
                         (format "%s - %s"
                                 (teams4e-availability--participant-name
                                  participant)
                                 (teams4e-availability--status-name status))
                         'face (teams4e-availability--status-face status)))
                (if items
                    (progn
                      (insert ": ")
                      (insert
                       (string-join
                        (mapcar
                         (lambda (item)
                           (let ((location
                                  (teams4e-availability--block-location item)))
                             (format "%s - %s%s"
                                     (or (teams4e--meeting-slot-time-label item)
                                         "unknown time")
                                     (teams4e-availability--block-title item)
                                     (if (and location
                                              (not (string-empty-p location)))
                                         (format " @ %s" location)
                                       ""))))
                         items)
                        "; ")))
                  (insert ": calendar details withheld or unavailable"))
                (insert "\n"))))
        (insert (propertize "Everyone is available for this slot.\n"
                            'face 'teams4e-availability-free)))
      (when (and (stringp reason) (not (string-empty-p reason)))
        (insert (propertize (format "Outlook: %s\n" reason) 'face 'shadow)))
      (insert "\n"))))

(defun teams4e-availability--insert-status-cell (status width)
  "Insert availability STATUS padded to WIDTH."
  (let ((label (teams4e-availability--status-name status)))
    (insert (propertize
             (format (format "%%-%ds" width)
                     (truncate-string-to-width label width nil nil "..."))
             'face (teams4e-availability--status-face status)))))

(defun teams4e-availability--insert-suggestions ()
  "Insert the ranked participant availability matrix."
  (let* ((suggestions (teams4e-availability--suggestions))
         (participants (teams4e-availability--participants))
         (participant-width 12))
    (unless (and teams4e-availability--selected-id suggestions)
      (setq teams4e-availability--selected-id
            (and suggestions
                 (teams4e-availability--slot-id (car suggestions)))))
    (teams4e-availability--insert-suggestion-details
     (teams4e-availability--selected-suggestion))
    (insert (propertize (format "  %-27s %7s " "Time" "Score") 'face 'bold))
    (dolist (participant participants)
      (insert (propertize
               (format (format "%%-%ds" participant-width)
                       (truncate-string-to-width
                        (teams4e-availability--participant-name participant)
                        participant-width nil nil "..."))
               'face 'bold)))
    (insert (propertize "Conflicts\n" 'face 'bold))
    (insert (make-string (+ 40 (* participant-width (length participants)) 28)
                         ?-)
            "\n")
    (setq teams4e-availability--row-ids nil)
    (if suggestions
        (dolist (suggestion suggestions)
          (let* ((id (teams4e-availability--slot-id suggestion))
                 (slot (teams4e--get suggestion 'meetingTimeSlot))
                 (confidence (or (teams4e--get suggestion 'confidence) 0))
                 (start (point))
                 blocking)
            (push id teams4e-availability--row-ids)
            (insert (if (equal id teams4e-availability--selected-id) "> " "  "))
            (insert (format "%-27s "
                            (truncate-string-to-width
                             (or (teams4e--meeting-slot-time-label slot)
                                 "Unknown time") 27 nil nil "...")))
            (insert (propertize (format "%6d%% " confidence)
                                'face
                                (teams4e-availability--confidence-face
                                 confidence)))
            (dolist (participant participants)
              (let ((status
                     (teams4e-availability--suggestion-status
                      suggestion participant)))
                (when (teams4e-availability--blocking-status-p status)
                  (push (teams4e-availability--participant-name participant)
                        blocking))
                (teams4e-availability--insert-status-cell
                 status participant-width)))
            (insert (if blocking
                        (string-join (nreverse blocking) ", ")
                      "None")
                    "\n")
            (add-text-properties
             start (point)
             (list 'teams4e-availability-id id
                   'teams4e-availability-record suggestion
                   'mouse-face 'highlight
                   'help-echo "Select this proposed meeting time"))
            (when (equal id teams4e-availability--selected-id)
              (add-face-text-property start (1- (point))
                                      'teams4e-availability-selected t))))
      (insert (propertize
               (concat "No ranked suggestions were returned. Review calendar "
                       "blocks or enter an exact time manually.\n")
               'face 'teams4e-availability-unknown)))
    (setq teams4e-availability--row-ids
          (nreverse teams4e-availability--row-ids))))

(defun teams4e-availability--working-hours-label (schedule)
  "Return compact working hours from SCHEDULE."
  (when-let ((hours (teams4e--get schedule 'workingHours)))
    (let ((days (teams4e--get hours 'daysOfWeek))
          (start (teams4e--get hours 'startTime))
          (end (teams4e--get hours 'endTime)))
      (when (and start end)
        (format "%s %s-%s"
                (if days
                    (mapconcat
                     (lambda (day) (capitalize (substring day 0 2)))
                     days ",")
                  "")
                (substring start 0 (min 5 (length start)))
                (substring end 0 (min 5 (length end))))))))

(defun teams4e-availability--blocks ()
  "Return every returned calendar block with its participant, sorted by time."
  (let (blocks)
    (dolist (participant (teams4e-availability--participants))
      (let ((schedule (teams4e-availability--schedule participant))
            (index 0))
        (dolist (item (teams4e--get schedule 'scheduleItems))
          (cl-incf index)
          (push `((id . ,(format "%s/%s/%d"
                                 (teams4e-availability--participant-email
                                  participant)
                                 (or (teams4e--event-date-time item 'start) "")
                                 index))
                  (participant . ,participant)
                  (item . ,item))
                blocks))))
    (sort blocks
          (lambda (left right)
            (let ((left-time
                   (teams4e-availability--time
                    (teams4e--get left 'item) 'start))
                  (right-time
                   (teams4e-availability--time
                    (teams4e--get right 'item) 'start)))
              (cond
               ((and left-time right-time) (time-less-p left-time right-time))
               (left-time t)
               (t nil)))))))

(defun teams4e-availability--selected-block (blocks)
  "Return the selected entry from BLOCKS."
  (seq-find
   (lambda (entry)
     (equal teams4e-availability--selected-id
            (teams4e--get entry 'id)))
   blocks))

(defun teams4e-availability--insert-block-details (entry)
  "Insert details for selected calendar block ENTRY."
  (when entry
    (let* ((participant (teams4e--get entry 'participant))
           (item (teams4e--get entry 'item))
           (location (teams4e-availability--block-location item)))
      (insert (propertize
               (format "Selected block: %s - %s\n"
                       (teams4e-availability--participant-name participant)
                       (or (teams4e--meeting-slot-time-label item)
                           "unknown time"))
               'face 'bold))
      (insert (format "%s - %s%s\n\n"
                      (teams4e-availability--status-name
                       (teams4e--get item 'status))
                      (teams4e-availability--block-title item)
                      (if (and location (not (string-empty-p location)))
                          (format " @ %s" location)
                        ""))))))

(defun teams4e-availability--insert-blocks ()
  "Insert the complete returned calendar block sheet."
  (let ((blocks (teams4e-availability--blocks)))
    (unless (and teams4e-availability--selected-id blocks)
      (setq teams4e-availability--selected-id
            (and blocks (teams4e--get (car blocks) 'id))))
    (teams4e-availability--insert-block-details
     (teams4e-availability--selected-block blocks))
    (insert (propertize "Working hours: " 'face 'bold))
    (insert
     (string-join
      (delq nil
            (mapcar
             (lambda (participant)
               (when-let ((label
                           (teams4e-availability--working-hours-label
                            (teams4e-availability--schedule participant))))
                 (format "%s %s"
                         (teams4e-availability--participant-name participant)
                         label)))
             (teams4e-availability--participants)))
      "  |  "))
    (insert "\n\n")
    (insert (propertize
             (format "  %-27s %-18s %-11s %-38s %s\n"
                     "Time" "Participant" "State" "Calendar block" "Location")
             'face 'bold))
    (insert (make-string 115 ?-) "\n")
    (setq teams4e-availability--row-ids nil)
    (if blocks
        (dolist (entry blocks)
          (let* ((id (teams4e--get entry 'id))
                 (participant (teams4e--get entry 'participant))
                 (item (teams4e--get entry 'item))
                 (status (teams4e--get item 'status))
                 (location (or (teams4e-availability--block-location item) ""))
                 (start (point)))
            (push id teams4e-availability--row-ids)
            (insert (if (equal id teams4e-availability--selected-id) "> " "  "))
            (insert (format "%-27s %-18s "
                            (truncate-string-to-width
                             (or (teams4e--meeting-slot-time-label item)
                                 "Unknown time") 27 nil nil "...")
                            (truncate-string-to-width
                             (teams4e-availability--participant-name participant)
                             18 nil nil "...")))
            (insert (propertize
                     (format "%-11s"
                             (teams4e-availability--status-name status))
                     'face (teams4e-availability--status-face status)))
            (insert (format " %-38s %s\n"
                            (truncate-string-to-width
                             (teams4e-availability--block-title item)
                             38 nil nil "...")
                            location))
            (add-text-properties
             start (point)
             (list 'teams4e-availability-id id
                   'teams4e-availability-record entry
                   'mouse-face 'highlight
                   'help-echo "Inspect this calendar block"))
            (when (equal id teams4e-availability--selected-id)
              (add-face-text-property start (1- (point))
                                      'teams4e-availability-selected t))))
      (insert (propertize "No calendar blocks were returned for this window.\n"
                          'face 'teams4e-availability-free)))
    (setq teams4e-availability--row-ids
          (nreverse teams4e-availability--row-ids))))

(defun teams4e-availability--goto-selected ()
  "Move point to the selected availability row."
  (let ((position
         (and teams4e-availability--selected-id
              (text-property-any
               (point-min) (point-max)
               'teams4e-availability-id teams4e-availability--selected-id))))
    (goto-char (or position (point-min)))
    (beginning-of-line)))

(defun teams4e-availability--render ()
  "Render the singleton meeting availability workspace."
  (let ((inhibit-read-only t))
    (erase-buffer)
    (teams4e-availability--insert-heading)
    (cond
     (teams4e-availability--error
      (insert (propertize teams4e-availability--error
                          'face 'teams4e-availability-busy)))
     ((null teams4e-availability--payload)
      (insert (propertize "Loading Outlook availability..."
                          'face 'shadow)))
     ((eq teams4e-availability--view 'blocks)
      (teams4e-availability--insert-blocks))
     (t (teams4e-availability--insert-suggestions)))
    (teams4e-availability--goto-selected)
    (setq header-line-format
          (format "Teams meeting workspace - %s - %s"
                  (teams4e--chat-label teams4e-availability--chat)
                  (if (eq teams4e-availability--view 'blocks)
                      "calendar blocks"
                    "suggestions")))))

(defun teams4e-availability-next (&optional count)
  "Select the next availability row by COUNT."
  (interactive "p")
  (let* ((count (or count 1))
         (index (or (cl-position teams4e-availability--selected-id
                                 teams4e-availability--row-ids
                                 :test #'equal)
                    -1))
         (target (+ index count)))
    (unless (and (>= target 0) (< target (length teams4e-availability--row-ids)))
      (user-error "No more availability rows"))
    (setq teams4e-availability--selected-id
          (nth target teams4e-availability--row-ids))
    (teams4e-availability--render)))

(defun teams4e-availability-previous (&optional count)
  "Select the previous availability row by COUNT."
  (interactive "p")
  (teams4e-availability-next (- (or count 1))))

(defun teams4e-availability-set-view (view)
  "Switch the availability workspace to VIEW."
  (interactive
   (list (intern (completing-read "Meeting view: "
                                  '("suggestions" "blocks") nil t))))
  (unless (memq view '(suggestions blocks))
    (user-error "Unsupported meeting workspace view: %s" view))
  (setq teams4e-availability--view view
        teams4e-availability--selected-id nil)
  (teams4e-availability--render))

(defun teams4e-availability-show-suggestions ()
  "Show ranked suggestions in the meeting workspace."
  (interactive)
  (teams4e-availability-set-view 'suggestions))

(defun teams4e-availability-show-blocks ()
  "Show returned participant calendar blocks in the meeting workspace."
  (interactive)
  (teams4e-availability-set-view 'blocks))

(defun teams4e-availability--proposal-allowed-p ()
  "Return non-nil when the current meeting accepts a new-time proposal."
  (teams4e--get teams4e-availability--payload 'proposalAllowed))

(defun teams4e-availability--require-proposal ()
  "Reject proposal actions unavailable for the current meeting."
  (unless (teams4e-availability--proposal-allowed-p)
    (user-error
     "%s"
     (or (teams4e--get teams4e-availability--payload
                        'proposalUnavailableReason)
         "A new-time proposal is unavailable for this meeting"))))

(defun teams4e-availability--close-after-send (_payload)
  "Close the availability workspace after a successful proposal."
  (when (derived-mode-p 'teams4e-availability-mode)
    (teams4e-availability-quit)))

(defun teams4e-availability-choose ()
  "Propose the selected ranked time from the availability workspace."
  (interactive)
  (unless (eq teams4e-availability--view 'suggestions)
    (user-error "Calendar blocks are not proposal slots; choose Suggestions"))
  (teams4e-availability--require-proposal)
  (let ((suggestion (or (teams4e-availability--selected-suggestion)
                        (user-error "No ranked meeting time is selected")))
        (workspace (current-buffer)))
    (teams4e--proposal-send
     teams4e-availability--chat
     teams4e-availability--event-id
     (teams4e--get suggestion 'meetingTimeSlot)
     (lambda (_payload)
       (when (buffer-live-p workspace)
         (with-current-buffer workspace
           (teams4e-availability-quit)))))))

(defun teams4e-availability-manual ()
  "Enter and propose an exact start while preserving the meeting duration."
  (interactive)
  (teams4e-availability--require-proposal)
  (let ((workspace (current-buffer)))
    (teams4e--proposal-send
     teams4e-availability--chat
     teams4e-availability--event-id
     (teams4e--proposal-manual-slot teams4e-availability--chat)
     (lambda (_payload)
       (when (buffer-live-p workspace)
         (with-current-buffer workspace
           (teams4e-availability-quit)))))))

(defun teams4e-availability--request ()
  "Request and render availability for the current workspace state."
  (teams4e--cancel-process teams4e-availability--request)
  (setq teams4e-availability--payload nil
        teams4e-availability--error nil
        teams4e-availability--selected-id nil)
  (teams4e-availability--render)
  (let* ((buffer (current-buffer))
         (args
          (list "teams" "meeting" "availability"
                "--eventId" teams4e-availability--event-id
                "--searchStart"
                (teams4e--proposal-utc-string
                 (car teams4e-availability--window))
                "--searchEnd"
                (teams4e--proposal-utc-string
                 (cadr teams4e-availability--window))
                "--activityDomain"
                (symbol-name teams4e-availability--activity-domain)
                "--maxCandidates"
                (number-to-string
                 (max 1 teams4e-meeting-proposal-max-candidates))
                "--minimumConfidence"
                (number-to-string
                 (max 0 teams4e-meeting-proposal-minimum-confidence))
                "--availabilityInterval"
                (number-to-string
                 (max 5 teams4e-meeting-availability-interval)))))
    (setq
     teams4e-availability--request
     (teams4e--run-json
      args
      (lambda (payload)
        (when (buffer-live-p buffer)
          (with-current-buffer buffer
            (setq teams4e-availability--request nil
                  teams4e-availability--payload payload)
            (when-let ((event (teams4e--get payload 'event)))
              (teams4e--apply-meeting-context
               teams4e-availability--chat `((event . ,event))))
            (teams4e-availability--render))))
      (lambda (status detail)
        (teams4e--report-error args status detail)
        (when (buffer-live-p buffer)
          (with-current-buffer buffer
            (setq teams4e-availability--request nil
                  teams4e-availability--error
                  (format "Availability request failed: %s"
                          (string-trim
                           (or detail "unknown backend error"))))
            (teams4e-availability--render))))))))

(defun teams4e-availability-refresh ()
  "Refresh the current availability and calendar-block sheet."
  (interactive)
  (teams4e-availability--request))

(defun teams4e-availability-change-range ()
  "Choose another search date range and refresh availability."
  (interactive)
  (setq teams4e-availability--window (teams4e--proposal-read-window))
  (teams4e-availability--request))

(defun teams4e-availability-cycle-hours ()
  "Cycle work, personal/weekend, and unrestricted availability domains."
  (interactive)
  (setq teams4e-availability--activity-domain
        (pcase teams4e-availability--activity-domain
          ('work 'personal)
          ('personal 'unrestricted)
          (_ 'work)))
  (teams4e-availability--request))

(defun teams4e-availability-scroll-left ()
  "Scroll the wide availability matrix left."
  (interactive)
  (scroll-right 12))

(defun teams4e-availability-scroll-right ()
  "Scroll the wide availability matrix right."
  (interactive)
  (scroll-left 12))

(defun teams4e-availability-quit ()
  "Close the availability workspace and restore its previous window layout."
  (interactive)
  (let ((buffer (current-buffer))
        (configuration teams4e-availability--window-configuration)
        (frame teams4e-availability--origin-frame))
    (teams4e--cancel-process teams4e-availability--request)
    (setq teams4e-availability--request nil)
    (when (and (window-configuration-p configuration)
               (frame-live-p frame)
               (eq frame (window-configuration-frame configuration)))
      (set-window-configuration configuration))
    (when (buffer-live-p buffer)
      (kill-buffer buffer))))

(defvar teams4e-availability-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (define-key map (kbd "j") #'teams4e-availability-next)
    (define-key map (kbd "n") #'teams4e-availability-next)
    (define-key map (kbd "k") #'teams4e-availability-previous)
    (define-key map (kbd "p") #'teams4e-availability-previous)
    (define-key map (kbd "RET") #'teams4e-availability-choose)
    (define-key map (kbd "s") #'teams4e-availability-show-suggestions)
    (define-key map (kbd "b") #'teams4e-availability-show-blocks)
    (define-key map (kbd "g") #'teams4e-availability-refresh)
    (define-key map (kbd "r") #'teams4e-availability-change-range)
    (define-key map (kbd "w") #'teams4e-availability-cycle-hours)
    (define-key map (kbd "m") #'teams4e-availability-manual)
    (define-key map (kbd "v") #'teams4e-meeting-respond)
    (define-key map (kbd "J") #'teams4e-meeting-join)
    (define-key map (kbd "o") #'teams4e-meeting-open-calendar)
    (define-key map (kbd "h") #'teams4e-availability-scroll-left)
    (define-key map (kbd "l") #'teams4e-availability-scroll-right)
    (define-key map (kbd "q") #'teams4e-availability-quit)
    (define-key map (kbd "?") #'describe-mode)
    map)
  "Keymap for the singleton Teams meeting availability workspace.")

(define-derived-mode teams4e-availability-mode special-mode "Teams-Availability"
  "Inspect meeting suggestions, participant conflicts, and calendar blocks.

Use j/k to move rows, RET to propose the selected suggestion, s/b to switch
between suggestions and blocks, r to change the range, w to cycle hour domains,
m for an exact time, v to RSVP, J to join, o for the calendar event, and q to
return to the previous Teams layout."
  (setq-local truncate-lines t)
  (add-hook 'kill-buffer-hook
            (lambda ()
              (teams4e--cancel-process teams4e-availability--request))
            nil t))

(defun teams4e--meeting-current-chat ()
  "Return the meeting chat associated with the current command context."
  (or (and (derived-mode-p 'teams4e-availability-mode)
           teams4e-availability--chat)
      (teams4e--chat-at-point)
      (user-error "No Teams meeting here")))

(defun teams4e--meeting-with-event-id (chat callback)
  "Invoke CALLBACK with CHAT and its linked event ID, fetching context if needed."
  (unless (teams4e--meeting-chat-p chat)
    (user-error "The current Teams conversation is not a meeting chat"))
  (if-let ((event-id (teams4e--proposal-event-id chat)))
      (funcall callback chat event-id)
    (teams4e--fetch-meeting-context
     chat
     (lambda (_context)
       (if-let ((event-id (teams4e--proposal-event-id chat)))
           (funcall callback chat event-id)
         (message "This meeting chat has no linked calendar event")))
     (lambda (status detail)
       (teams4e--report-error
        (teams4e--meeting-context-args chat) status detail)
       (message "Meeting calendar details are unavailable")))))

;;;###autoload
(defun teams4e-meeting-availability (&optional chat)
  "Open the singleton availability workspace for meeting CHAT."
  (interactive)
  (teams4e--require-online)
  (setq chat (or chat (teams4e--meeting-current-chat)))
  (teams4e--meeting-with-event-id
   chat
   (lambda (resolved-chat event-id)
     (let* ((buffer (get-buffer-create teams4e--availability-buffer-name))
            (configuration (current-window-configuration))
            (frame (selected-frame))
            (window (teams4e--proposal-default-window resolved-chat)))
       (with-current-buffer buffer
         (teams4e-availability-mode)
         (setq teams4e-availability--chat resolved-chat
               teams4e-availability--event-id event-id
               teams4e-availability--window window
               teams4e-availability--activity-domain
               teams4e-meeting-proposal-activity-domain
               teams4e-availability--view 'suggestions
               teams4e-availability--selected-id nil
               teams4e-availability--window-configuration configuration
               teams4e-availability--origin-frame frame)
         (teams4e-availability--render))
       (pop-to-buffer buffer)
       (delete-other-windows)
       (with-current-buffer buffer
         (teams4e-availability--request))))))

(defun teams4e--meeting-join-url (chat)
  "Return the best available join URL for meeting CHAT."
  (or (teams4e--dig (teams4e--get chat 'meetingContext)
                     'event 'onlineMeeting 'joinUrl)
      (teams4e--dig (teams4e--get chat 'meetingContext)
                     'onlineMeetingInfo 'joinWebUrl)
      (teams4e--dig chat 'onlineMeetingInfo 'joinWebUrl)))

;;;###autoload
(defun teams4e-meeting-join (&optional chat)
  "Open meeting CHAT's join URL in the configured browser."
  (interactive)
  (setq chat (or chat (teams4e--meeting-current-chat)))
  (if-let ((url (teams4e--meeting-join-url chat)))
      (teams4e--open-url-in-browser url)
    (teams4e--fetch-meeting-context
     chat
     (lambda (_context)
       (if-let ((url (teams4e--meeting-join-url chat)))
           (teams4e--open-url-in-browser url)
         (message "This meeting has no join URL")))
     (lambda (status detail)
       (teams4e--report-error
        (teams4e--meeting-context-args chat) status detail)))))

;;;###autoload
(defun teams4e-meeting-open-calendar (&optional chat)
  "Open meeting CHAT's linked Outlook calendar event."
  (interactive)
  (setq chat (or chat (teams4e--meeting-current-chat)))
  (if-let ((url (teams4e--get (teams4e--meeting-event chat) 'webLink)))
      (teams4e--open-url-in-browser url)
    (teams4e--fetch-meeting-context
     chat
     (lambda (_context)
       (if-let ((url (teams4e--get (teams4e--meeting-event chat) 'webLink)))
           (teams4e--open-url-in-browser url)
         (message "This meeting has no linked calendar URL")))
     (lambda (status detail)
       (teams4e--report-error
        (teams4e--meeting-context-args chat) status detail)))))

;;;###autoload
(defun teams4e-meeting-respond (&optional chat)
  "Accept, tentatively accept, or decline meeting CHAT."
  (interactive)
  (teams4e--require-online)
  (setq chat (or chat (teams4e--meeting-current-chat)))
  (teams4e--meeting-with-event-id
   chat
   (lambda (resolved-chat event-id)
     (let* ((event (teams4e--meeting-event resolved-chat))
            (_cancelled-check
             (when (teams4e--get event 'isCancelled)
               (user-error "Cannot respond to a cancelled meeting")))
            (_organizer-check
             (when (teams4e--get event 'isOrganizer)
               (user-error "The organizer cannot RSVP as an attendee")))
            (choices '(("Accept" . "accepted")
                       ("Tentative" . "tentativelyAccepted")
                       ("Decline" . "declined")))
            (label (completing-read "Meeting response: "
                                    (mapcar #'car choices) nil t))
            (response (cdr (assoc label choices)))
            (comment (read-string (format "%s note to organizer: " label)))
            (args (list "teams" "meeting" "respond"
                        "--eventId" event-id
                        "--response" response
                        "--comment" comment)))
       (teams4e--run-json
        args
        (lambda (payload)
          (teams4e--apply-meeting-context
           resolved-chat `((event . ,(teams4e--get payload 'event))))
          (teams4e--meeting-refresh-displays resolved-chat)
          (when-let ((workspace (get-buffer teams4e--availability-buffer-name)))
            (with-current-buffer workspace
              (when (and teams4e-availability--payload
                         (equal event-id teams4e-availability--event-id))
                (setf (alist-get 'event teams4e-availability--payload)
                      (teams4e--get payload 'event))
                (teams4e-availability--render))))
          (message "%s: %s" label (teams4e--chat-label resolved-chat)))
        (lambda (status detail)
          (teams4e--report-error args status detail)
          (message "Meeting response failed: %s"
                   (string-trim
                    (or (teams4e--redacted-detail args detail)
                        "unknown backend error")))))))))

;;;###autoload
(defun teams4e-meetings ()
  "Open the upcoming and in-progress meeting workspace."
  (interactive)
  (setq teams4e--active-view 'upcoming
        teams4e--active-query nil
        teams4e--active-filter-name "Upcoming meetings")
  (teams4e-inbox))

(define-key teams4e-action-map (kbd "p") #'teams4e-meeting-availability)
(define-key teams4e-action-map (kbd "v") #'teams4e-meeting-respond)
(define-key teams4e-action-map (kbd "J") #'teams4e-meeting-join)
(define-key teams4e-action-map (kbd "C") #'teams4e-meeting-open-calendar)

(when (fboundp 'which-key-add-keymap-based-replacements)
  (which-key-add-keymap-based-replacements
    teams4e-action-map
    "p" "meeting availability"
    "v" "meeting response"
    "J" "join meeting"
    "C" "calendar event"))

(with-eval-after-load 'evil
  (evil-define-key* '(normal motion) teams4e-availability-mode-map
    (kbd "j") #'teams4e-availability-next
    (kbd "k") #'teams4e-availability-previous
    (kbd "RET") #'teams4e-availability-choose
    (kbd "s") #'teams4e-availability-show-suggestions
    (kbd "b") #'teams4e-availability-show-blocks
    (kbd "g") #'teams4e-availability-refresh
    (kbd "r") #'teams4e-availability-change-range
    (kbd "w") #'teams4e-availability-cycle-hours
    (kbd "m") #'teams4e-availability-manual
    (kbd "v") #'teams4e-meeting-respond
    (kbd "J") #'teams4e-meeting-join
    (kbd "o") #'teams4e-meeting-open-calendar
    (kbd "h") #'teams4e-availability-scroll-left
    (kbd "l") #'teams4e-availability-scroll-right
    (kbd "q") #'teams4e-availability-quit))

(defalias 'teams-meetings #'teams4e-meetings)
(defalias 'teams-meeting-availability #'teams4e-meeting-availability)
(defalias 'teams-meeting-respond #'teams4e-meeting-respond)
(defalias 'teams-meeting-join #'teams4e-meeting-join)
(defalias 'teams-meeting-open-calendar #'teams4e-meeting-open-calendar)

(provide 'teams4e-meetings)

;;; teams4e-meetings.el ends here
