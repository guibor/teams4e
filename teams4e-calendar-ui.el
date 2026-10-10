;;; teams4e-calendar-ui.el --- Calendar overview and action discovery -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Derived presentation only: the agenda owns the sole calendar snapshot.

;;; Code:
(require 'teams4e-calendar)

(defcustom teams4e-calendar-show-overview t
  "Whether to include a compact overview of the loaded agenda range.
`teams4e-calendar-overview' enables it locally and jumps to it without fetching."
  :type 'boolean :group 'teams4e-calendar)

(defun teams4e-calendar-ui--complete-p ()
  "Whether the agenda has a complete snapshot of its current range."
  (and (equal (teams4e-calendar--key) teams4e-calendar--loaded-key)
       (not teams4e-calendar--loading) (not teams4e-calendar--error)))

(defun teams4e-calendar-ui--day-stats (day)
  "Derive DAY's overview from the unfiltered snapshot.
Counts cover the day.  Durations cover configured work hours, including gaps
shorter than the agenda's display threshold.  Union occupied time exactly once."
  (when (teams4e-calendar-ui--complete-p)
    (let* ((teams4e-calendar--filter "") (teams4e-calendar--show-declined t)
           (events (seq-filter (lambda (event) (nth 2 (teams4e-calendar--availability event)))
                               (teams4e-calendar--day-events day)))
           (parts (decode-time day))
           (hours teams4e-calendar-work-hours)
           (workday (and (memq (nth 6 parts) teams4e-calendar-work-days)
                         (<= 0 (car hours)) (< (car hours) (cdr hours)) (<= (cdr hours) 24)))
           (result (list :events (length events)
                         :conflicts (length (teams4e-calendar--conflicts day))
                         :unanswered (seq-count (lambda (event)
                                                  (eq (teams4e-calendar--summary-group event) 'unanswered))
                                                events))))
      (when workday
        (let* ((start (float-time (encode-time 0 0 (car hours) (nth 3 parts) (nth 4 parts) (nth 5 parts))))
               (end (float-time (encode-time 0 0 (cdr hours) (nth 3 parts) (nth 4 parts) (nth 5 parts))))
               (cursor start) (free 0) (longest 0)
               (blocks (sort (teams4e-calendar--busy-intervals start end)
                             (lambda (a b) (< (car a) (car b))))))
          (dolist (block blocks)
            (let ((gap (max 0 (- (car block) cursor))))
              (cl-incf free gap)
              (setq longest (max longest gap)
                    cursor (max cursor (cadr block)))))
          (let ((gap (max 0 (- end cursor))))
            (setq free (+ free gap) longest (max longest gap)))
          (setq result (append result (list :blocked (- end start free) :free free :longest longest)))))
      result)))

(defun teams4e-calendar-ui--duration (seconds)
  "Format SECONDS as hours and minutes, or -- when not applicable."
  (if (null seconds) "--"
    (let ((minutes (floor (/ seconds 60))))
      (format "%dh%02d" (/ minutes 60) (% minutes 60)))))

(defun teams4e-calendar-ui--overview-key ()
  "Return the overview identity for this viewport."
  (cons 'overview (teams4e-calendar--key)))

;;;###autoload
(defun teams4e-calendar-ui--insert-overview ()
  "Insert a local range overview before the chronological agenda."
  (when teams4e-calendar-show-overview
    (insert (propertize (concat (if (eq teams4e-calendar--view 'week) "Week" "Range")
                                " at a glance | This calendar, unfiltered\n")
                        'face 'bold 'teams4e-calendar-item (teams4e-calendar-ui--overview-key)))
    (if (not (teams4e-calendar-ui--complete-p))
        (insert (propertize "  Overview unavailable until this range is completely loaded.\n\n" 'face 'shadow))
      (insert (propertize (format "  %-12s %6s %8s %8s %8s %7s %6s\n"
                                  "Day" "Events" "Blocked" "Free" "Longest" "Clashes" "Reply")
                          'face 'bold))
      (let* ((range (teams4e-calendar--range)) (day (car range)) (owner (current-buffer)))
        (while (time-less-p day (cadr range))
          (let* ((stats (teams4e-calendar-ui--day-stats day))
                 (target (teams4e-calendar--day-key day))
                 (time day)
                 (start (point)))
            (insert-text-button
             (format "  %-12s %6d %8s %8s %8s %7d %6d"
                     (format-time-string "%a %d %b" day) (plist-get stats :events)
                     (teams4e-calendar-ui--duration (plist-get stats :blocked))
                     (teams4e-calendar-ui--duration (plist-get stats :free))
                     (teams4e-calendar-ui--duration (plist-get stats :longest))
                     (plist-get stats :conflicts) (plist-get stats :unanswered))
             'face (if (equal (format-time-string "%F" day) (format-time-string "%F"))
                       'font-lock-keyword-face 'default)
             'mouse-face 'highlight 'follow-link t
             'help-echo "Events and clashes cover the full day; durations cover work hours. Open this day."
             'action (lambda (_)
                       (when (buffer-live-p owner)
                         (with-current-buffer owner
                           (let ((position (teams4e-calendar--find-item target)))
                             (unless position (user-error "Calendar range changed"))
                             (goto-char position)
                             (setq teams4e-calendar--date time teams4e-calendar--focus nil
                                   teams4e-calendar--focus-day-heading nil)
                             (teams4e-calendar--center))))))
            (insert "\n")
            (add-text-properties start (point)
                                 (list 'teams4e-calendar-item (list 'overview-day target)
                                       'teams4e-calendar-day-time day)))
          (setq day (teams4e-calendar--midnight day 1))))
      (insert (propertize "  Blocking events/clashes: whole day. Durations: work hours; -- nonworking.\n\n"
                          'face 'shadow)))))

;;;###autoload
(defun teams4e-calendar-overview ()
  "Jump to the overview of the loaded range without fetching or changing it."
  (interactive)
  (unless (derived-mode-p 'teams4e-calendar-mode) (user-error "Open the calendar agenda first"))
  (setq-local teams4e-calendar-show-overview t)
  (setq teams4e-calendar--focus nil teams4e-calendar--focus-day-heading nil)
  (teams4e-calendar--render)
  (goto-char (teams4e-calendar--find-item (teams4e-calendar-ui--overview-key)))
  (dolist (window (get-buffer-window-list (current-buffer) nil t))
    (set-window-point window (point))
    (set-window-start window (point) t)))

(defun teams4e-calendar-ui--actions ()
  "Return applicable (LABEL . COMMAND) choices for the current calendar context."
  (let* ((agenda (derived-mode-p 'teams4e-calendar-mode))
         (item (get-text-property (point) 'teams4e-calendar-item))
         (section (get-text-property (point) 'teams4e-calendar-section))
         (event (when (or teams4e-calendar--event-id
                          (get-text-property (point) 'teams4e-calendar-event))
                  (condition-case nil (cadr (teams4e-calendar--context)) (user-error nil))))
         actions)
    (when event
      (when agenda (push '("Event: read invitation" . teams4e-calendar-open-event) actions))
      (push '("Event: capture to Org" . teams4e-calendar-capture) actions)
      (push '("Event: open Outlook" . teams4e-calendar-open-outlook) actions)
      (when (condition-case nil (teams4e-calendar--follow-url event) (user-error nil))
        (push '("Event: follow in Outlook" . teams4e-calendar-follow-in-outlook) actions))
      (unless (teams4e--get event 'isCancelled)
        (when (and (not (teams4e--get event 'isOrganizer)) (teams4e--get event 'attendees))
          (push '("Event: respond to invitation" . teams4e-calendar-respond) actions))
        (unless (teams4e--get event 'isAllDay)
          (push (cons (if (teams4e--get event 'isOrganizer)
                          "Event: availability / reschedule" "Event: availability / propose time")
                      #'teams4e-calendar-availability) actions))
        (when (teams4e-calendar--chat-id event)
          (push '("Event: open Teams chat" . teams4e-calendar-open-chat) actions))
        (when (or (teams4e--dig event 'onlineMeeting 'joinUrl) (teams4e--get event 'onlineMeetingUrl))
          (push '("Event: join meeting" . teams4e-calendar-join) actions))))
    (when agenda
      (when (memq (car-safe section) '(summary conflict))
        (push '("Section: fold / unfold" . teams4e-calendar-toggle-section) actions))
      (when (eq (car-safe item) 'overview-day)
        (push '("Day: open agenda" . teams4e-calendar-activate) actions))
      (setq actions (append (nreverse actions)
                            (list (cons (if (eq (car-safe item) 'slot) "Free slot: draft meeting" "Plan: new meeting")
                                        #'teams4e-calendar-create)
                                  (cons (if (eq (car-safe item) 'slot) "Free slot: draft focus block" "Plan: focus block")
                                        #'teams4e-calendar-block-time))
                            '(("Plan: find free time" . teams4e-calendar-find-free-slot)
                              ("Navigate: overview" . teams4e-calendar-overview)
                              ("Navigate: jump to meeting" . teams4e-calendar-jump-event)
                              ("Navigate: next conflict" . teams4e-calendar-next-conflict)
                              ("Navigate: previous conflict" . teams4e-calendar-previous-conflict)
                              ("Navigate: next unanswered invitation" . teams4e-calendar-next-response)
                              ("Navigate: now" . teams4e-calendar-today)
                              ("Navigate: next time slot" . teams4e-calendar-next-slot)
                              ("Navigate: choose date" . teams4e-calendar-goto-date)
                              ("View: filter" . teams4e-calendar-filter)
                              ("View: duration scaling" . teams4e-calendar-toggle-duration)
                              ("View: day" . teams4e-calendar-day)
                              ("View: week" . teams4e-calendar-week)
                              ("View: month" . teams4e-calendar-month)
                              ("View: choose calendar" . teams4e-calendar-select)
                              ("View: refresh" . teams4e-calendar-refresh)))))
    (append (if agenda actions (nreverse actions)) '(("Close pane" . quit-window)))))

(defun teams4e-calendar-ui--binding-label (command)
  "Describe only currently effective keys for COMMAND, or its M-x fallback."
  (let ((keys (seq-filter (lambda (key) (eq (key-binding key t) command))
                          (where-is-internal command (current-active-maps t)))))
    (if keys (mapconcat #'key-description keys ", ") (format "M-x %s" command))))

;;;###autoload
(defun teams4e-calendar-actions ()
  "Choose a contextual action, annotated with the actual active key bindings.
Opening or cancelling the menu neither fetches nor mutates calendar data."
  (interactive)
  (unless (derived-mode-p 'teams4e-calendar-mode 'teams4e-calendar-event-mode)
    (user-error "Open a calendar agenda or invitation first"))
  (let* ((source (current-buffer))
         (item (get-text-property (point) 'teams4e-calendar-item))
         (id teams4e-calendar--event-id)
         (range (teams4e-calendar--key))
         (actions (teams4e-calendar-ui--actions))
         (choices (mapcar (lambda (entry)
                            (cons (format "%s  [%s]" (car entry)
                                          (teams4e-calendar-ui--binding-label (cdr entry)))
                                  (cdr entry))) actions))
         (choice (completing-read "Calendar action: " choices nil t))
         (command (cdr (assoc choice choices))))
    (unless (buffer-live-p source) (user-error "Calendar buffer was closed"))
    (with-current-buffer source
      (unless (and (equal range (teams4e-calendar--key)) (equal id teams4e-calendar--event-id))
        (user-error "Calendar context changed; reopen the action menu"))
      (when item
        (let ((position (teams4e-calendar--find-item item)))
          (unless position (user-error "Calendar item changed; reopen the action menu"))
          (goto-char position)))
      (unless (memq command (mapcar #'cdr (teams4e-calendar-ui--actions)))
        (user-error "Action is no longer available"))
      (call-interactively command))))

(provide 'teams4e-calendar-ui)
;;; teams4e-calendar-ui.el ends here
