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

(defun teams4e-calendar--render ()
  "Render the current snapshot, retaining the selected occurrence if possible."
  (let* ((inhibit-read-only t)
         (selected (get-text-property (point) 'teams4e-calendar-event))
         (position (point))
         (range (teams4e-calendar--range))
         (day (car range))
         (loaded (equal (teams4e-calendar--key) teams4e-calendar--loaded-key)))
    (erase-buffer)
    (setq header-line-format
          (list " Calendar | " teams4e-calendar--name " | "
                (symbol-name teams4e-calendar--view)
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
      (insert (propertize (format-time-string "%A, %d %B\n" day)
                          'face 'font-lock-keyword-face))
      (let ((events (and loaded (teams4e-calendar--day-events day))))
        (if events
            (dolist (event events)
              (let ((start (point))
                    (location (teams4e--dig event 'location 'displayName)))
                (insert (propertize
                         (format "  %-15s " (teams4e-calendar--time-label event day))
                         'face 'font-lock-keyword-face)
                        (propertize (teams4e-calendar--line
                                     (or (teams4e--get event 'subject) "(Untitled event)"))
                                    'face 'bold)
                        "\n")
                (insert "                  "
                        (propertize
                         (string-join
                          (delq nil (list (teams4e-calendar--status event)
                                          (and (not (string-empty-p (or location "")))
                                               (teams4e-calendar--line location))
                                          (when (member (teams4e--get event 'type)
                                                        '("occurrence" "exception"))
                                            "Recurring")))
                          " | ")
                         'face 'shadow)
                        "\n")
                (add-text-properties start (point)
                                     (list 'teams4e-calendar-event (teams4e--get event 'id)
                                           'mouse-face 'highlight
                                           'rear-nonsticky t))))
          (insert (propertize
                   (cond ((not loaded) "  Not loaded\n")
                         (teams4e-calendar--error "  No events returned (incomplete)\n")
                         (t "  No matching events\n"))
                   'face 'shadow))))
      (insert "\n")
      (setq day (teams4e-calendar--midnight day 1)))
    (goto-char (or (and selected
                       (text-property-any (point-min) (point-max)
                                          'teams4e-calendar-event selected))
                  (min position (point-max))))))

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
  (setq teams4e-calendar--view view)
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
  (teams4e-calendar--show-range))

(defun teams4e-calendar-previous-period (&optional count)
  "Move COUNT periods backward."
  (interactive "p")
  (teams4e-calendar-next-period (- (or count 1))))

(defun teams4e-calendar-today ()
  "Visit today in the current agenda view."
  (interactive)
  (setq teams4e-calendar--date (current-time))
  (teams4e-calendar--show-range))

(defun teams4e-calendar-goto-date ()
  "Choose a date with Org's calendar date reader."
  (interactive)
  (setq teams4e-calendar--date (org-read-date nil t nil "Calendar date: "))
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

(defun teams4e-calendar-next-event (&optional backward)
  "Move to the next event, or previous event if BACKWARD is non-nil."
  (interactive)
  (let ((step (if backward -1 1))
        (id (get-text-property (point) 'teams4e-calendar-event)))
    (forward-line step)
    (while (and (not (if backward (bobp) (eobp)))
                (let ((next (get-text-property (point) 'teams4e-calendar-event)))
                  (or (null next) (equal id next))))
      (forward-line step))
    (beginning-of-line)))

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
  (pcase-let* ((`(,_ ,event) (teams4e-calendar--context))
               (inhibit-read-only t))
    (erase-buffer)
    (insert (propertize (teams4e-calendar--line (teams4e--get event 'subject))
                        'face '(:inherit bold :height 1.15)) "\n\n")
    (dolist (field '(start end))
      (when-let ((time (teams4e-calendar--time event field)))
        (insert (format "%-10s%s\n" (capitalize (symbol-name field))
                        (format-time-string "%a %d %b %Y  %H:%M %Z" time)))))
    (when (teams4e--get event 'isAllDay) (insert "All-day event (end date exclusive)\n"))
    (insert "Status    " (teams4e-calendar--status event) "\n"
            "Location  " (or (teams4e--dig event 'location 'displayName) "") "\n"
            "Organizer " (or (teams4e--dig event 'organizer 'emailAddress 'name) "") "\n")
    (when (teams4e--get event 'seriesMasterId)
      (insert "Series    Recurring occurrence\n"))
    (dolist (attendee (teams4e--get event 'attendees))
      (insert "          " (or (teams4e--dig attendee 'emailAddress 'name) "")
              " <" (or (teams4e--dig attendee 'emailAddress 'address) "") ">  "
              (or (teams4e--dig attendee 'status 'response) "") "\n"))
    (insert "\n")
    (dolist (link `(("Open in Outlook" . ,(teams4e--get event 'webLink))
                    ("Join meeting" . ,(or (teams4e--dig event 'onlineMeeting 'joinUrl)
                                          (teams4e--get event 'onlineMeetingUrl)))))
      (when (cdr link)
        (insert-text-button (car link) 'follow-link t
                            'action (let ((url (cdr link)))
                                      (lambda (_) (teams4e--open-url-in-browser url))))
        (insert "   ")))
    (insert "\n\n")
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
    (pop-to-buffer buffer '(display-buffer-reuse-window display-buffer-below-selected))
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
  "Inspect availability and propose alternatives for this calendar event."
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
  "Propose SLOT for the current calendar event, or read an exact time if nil."
  (teams4e--require-online)
  (teams4e-availability--require-proposal)
  (pcase-let* ((`(,owner ,event) (teams4e-calendar--context))
               (workspace (current-buffer)))
    (unless slot
      (let* ((original (teams4e-calendar--time event 'start))
             (end (teams4e-calendar--time event 'end))
             (start (org-read-date t t nil "Proposed start: " original))
             (finish (time-add start (time-subtract end original))))
        (setq slot `((start (dateTime . ,(format-time-string "%Y-%m-%dT%H:%M:%SZ" start t))
                           (timeZone . "UTC"))
                     (end (dateTime . ,(format-time-string "%Y-%m-%dT%H:%M:%SZ" finish t))
                         (timeZone . "UTC"))))))
    (let ((comment (read-string "Proposal note to organizer: "
                                teams4e-meeting-proposal-default-comment)))
      (teams4e--run-json
       (list "teams" "meeting" "propose" "send"
             "--eventId" (teams4e--get event 'id)
             "--start" (teams4e--event-date-time slot 'start)
             "--end" (teams4e--event-date-time slot 'end)
             "--comment" comment)
       (lambda (payload)
         (when (buffer-live-p owner)
           (with-current-buffer owner
             (teams4e-calendar--replace-event (teams4e--get payload 'event))
             (teams4e-calendar--render)))
         (when (buffer-live-p workspace)
           (with-current-buffer workspace (teams4e-availability-quit)))
         (message "Calendar time proposal sent"))))))

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
                       ("k" . teams4e-calendar-previous-event)
                       ("n" . teams4e-calendar-next-event)
                       ("p" . teams4e-calendar-previous-event)
                       ("]" . teams4e-calendar-next-period)
                       ("[" . teams4e-calendar-previous-period)
                       ("t" . teams4e-calendar-today)
                       ("G" . teams4e-calendar-goto-date)
                       ("d" . teams4e-calendar-day)
                       ("w" . teams4e-calendar-week)
                       ("m" . teams4e-calendar-month)
                       ("g" . teams4e-calendar-refresh)
                       ("/" . teams4e-calendar-filter)
                       ("x" . teams4e-calendar-toggle-declined)
                       ("c" . teams4e-calendar-select)
                       ("RET" . teams4e-calendar-open-event)
                       ("o" . teams4e-calendar-open-outlook)
                       ("J" . teams4e-calendar-join)
                       ("a" . teams4e-calendar-respond)
                       ("A" . teams4e-calendar-availability)
                       ("C" . teams4e-calendar-capture)))
      (define-key map (kbd (car binding)) (cdr binding)))
    map))

(defvar teams4e-calendar-event-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (dolist (binding '(("o" . teams4e-calendar-open-outlook)
                       ("J" . teams4e-calendar-join)
                       ("a" . teams4e-calendar-respond)
                       ("A" . teams4e-calendar-availability)
                       ("C" . teams4e-calendar-capture)))
      (define-key map (kbd (car binding)) (cdr binding)))
    map))

(define-derived-mode teams4e-calendar-mode special-mode "Teams-Calendar"
  "Browse calendar events independently of Teams chat history."
  (setq-local truncate-lines nil)
  (setq-local word-wrap t)
  (setq-local teams4e-calendar--date (current-time)
              teams4e-calendar--view teams4e-calendar-default-view
              teams4e-calendar--id teams4e-calendar-id
              teams4e-calendar--show-declined teams4e-calendar-show-declined)
  (add-hook 'kill-buffer-hook #'teams4e-calendar--cancel nil t))

(define-derived-mode teams4e-calendar-event-mode special-mode "Teams-Event"
  "Read a calendar event and act on it."
  (setq-local word-wrap t))

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
      (unless (derived-mode-p 'teams4e-calendar-mode) (teams4e-calendar-mode)))
    (pop-to-buffer buffer)
    (when (or refresh (not existing))
      (teams4e-calendar-refresh))))

(provide 'teams4e-calendar)
;;; teams4e-calendar.el ends here
