;;; teams4e-calendar-create.el --- Org drafts for calendar events -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; One editable Org draft is the source of truth.  Only explicit submission posts
;; an event; reading, choosing people/times, and exporting never send invitations.

;;; Code:
(require 'teams4e-calendar)
(require 'teams4e-compose)
(require 'org-id)

(defcustom teams4e-calendar-new-duration 30
  "Initial duration of new calendar events, in minutes."
  :type 'integer :group 'teams4e-calendar)

(defcustom teams4e-calendar-new-online-meeting t
  "Whether new drafts request a Teams meeting link."
  :type 'boolean :group 'teams4e-calendar)

(defvar-local teams4e-calendar-compose--pending nil)
(defvar-local teams4e-calendar-compose--submitted-payload nil)

(defun teams4e-calendar-compose--get (name)
  "Read draft property NAME at the first heading."
  (save-excursion (goto-char (point-min)) (org-entry-get nil name)))

(defun teams4e-calendar-compose--put (name value)
  "Set draft property NAME to VALUE at the first heading."
  (save-excursion (goto-char (point-min)) (org-entry-put nil name value)))

(defun teams4e-calendar-compose--time (name)
  "Read explicit date, time, and UTC offset from draft property NAME."
  (let ((value (teams4e-calendar-compose--get name)))
    (unless (and value (string-match-p "T[0-9:]+\\(?:Z\\|[+-][0-9][0-9]:?[0-9][0-9]\\)\\'" value))
      (user-error "%s must include date, time, and UTC offset" name))
    (condition-case nil (date-to-time value)
      (error (user-error "Invalid %s" name)))))

(defun teams4e-calendar-compose--payload (&optional source-only)
  "Read and validate the Org draft; with SOURCE-ONLY keep the body as Org."
  (save-excursion
    (goto-char (point-min))
    (unless (org-at-heading-p) (user-error "Keep the meeting title on the first Org heading"))
    (let* ((title (org-get-heading t t t t))
           (start (teams4e-calendar-compose--time "START_AT"))
           (end (teams4e-calendar-compose--time "END_AT"))
           (online (downcase (or (teams4e-calendar-compose--get "TEAMS") "")))
           (show-as (or (teams4e-calendar-compose--get "SHOW_AS") "busy"))
           (transaction (teams4e-calendar-compose--get "TRANSACTION_ID"))
           (required (split-string (or (teams4e-calendar-compose--get "REQUIRED") "") "[,; \t]+" t))
           (optional (split-string (or (teams4e-calendar-compose--get "OPTIONAL") "") "[,; \t]+" t))
           (location (or (teams4e-calendar-compose--get "LOCATION") "")))
      (when (string-empty-p title) (user-error "A meeting title is required"))
      (unless (time-less-p start end) (user-error "End must be after start"))
      (unless (member online '("yes" "no")) (user-error "TEAMS must be yes or no"))
      (unless (member show-as '("free" "tentative" "busy" "oof" "workingElsewhere"))
        (user-error "Invalid SHOW_AS value"))
      (unless (and transaction (not (string-empty-p transaction)))
        (user-error "Keep the draft's TRANSACTION_ID for safe retries"))
      (dolist (email (append required optional))
        (unless (string-match-p "\\`[^[:space:]<>,;@]+@[^[:space:]<>,;@]+\\'" email)
          (user-error "Use plain email addresses in REQUIRED and OPTIONAL")))
      (org-end-of-meta-data t)
      `((subject . ,title)
        (start . ,(format-time-string "%Y-%m-%dT%H:%M:%SZ" start t))
        (end . ,(format-time-string "%Y-%m-%dT%H:%M:%SZ" end t))
        (required . ,(vconcat required)) (optional . ,(vconcat optional))
        (location . ,location) (showAs . ,show-as)
        (online . ,(if (equal online "yes") t :json-false))
        (transactionId . ,transaction)
        (body . ,(let ((body (buffer-substring-no-properties (point) (point-max))))
                   (if source-only body (teams4e-compose--org-html body))))))))

(defun teams4e-calendar-compose-set-time ()
  "Choose the draft's start and duration without submitting."
  (interactive)
  (barf-if-buffer-read-only)
  (let* ((start (org-read-date t t nil "Meeting start: "
                               (teams4e-calendar-compose--time "START_AT")))
         (minutes (read-number "Duration (minutes): " teams4e-calendar-new-duration)))
    (unless (> minutes 0) (user-error "Duration must be positive"))
    (teams4e-calendar-compose--put "START_AT" (format-time-string "%Y-%m-%dT%H:%M:%S%z" start))
    (teams4e-calendar-compose--put "END_AT"
                                  (format-time-string "%Y-%m-%dT%H:%M:%S%z"
                                                      (time-add start (* 60 minutes))))))

(defun teams4e-calendar-compose-add-attendee (query &optional optional)
  "Search QUERY and add a required attendee, or OPTIONAL with a prefix."
  (interactive (list (read-string "Attendee search: ") current-prefix-arg))
  (barf-if-buffer-read-only)
  (let ((buffer (current-buffer)) (property (if optional "OPTIONAL" "REQUIRED")))
    (teams4e--search-user
     query
     (lambda (user)
       (when (buffer-live-p buffer)
         (with-current-buffer buffer
           (barf-if-buffer-read-only)
           (let ((email (or (teams4e--get user 'mail) (teams4e--get user 'userPrincipalName)))
                 (old (split-string (or (teams4e-calendar-compose--get property) "") "[,; \t]+" t)))
             (unless email (user-error "This user has no email address"))
             (teams4e-calendar-compose--put
              property (string-join (delete-dups (append old (list email))) ", ")))))))))

(defun teams4e-calendar-compose-send ()
  "Create this event and send invitations using the explicit draft contents.
Retries keep the transaction ID and original payload.  Check Outlook before
replacing a submitted draft after an ambiguous failure."
  (interactive)
  (unless teams4e-calendar-compose-mode (user-error "Not a calendar draft"))
  (when teams4e-calendar-compose--pending (user-error "This draft is already being submitted"))
  (when (teams4e-calendar-compose--get "CREATED_ID") (user-error "This meeting was already created"))
  (teams4e--require-online)
  (let* ((source (teams4e-calendar-compose--payload t))
         (hash (secure-hash 'sha256
                            (json-encode (cons (cons 'calendarId (teams4e-calendar-compose--get "CALENDAR_ID"))
                                               source))))
         (previous (teams4e-calendar-compose--get "SUBMITTED_HASH"))
         (buffer (current-buffer))
         (owner teams4e-calendar--owner)
         (calendar (teams4e-calendar-compose--get "CALENDAR_ID"))
         payload)
    (when (equal calendar "") (setq calendar nil))
    (unless (or (null previous) (equal previous hash))
      (user-error "Submitted draft changed: check Outlook before starting a replacement draft"))
    (setq payload (or teams4e-calendar-compose--submitted-payload
                      (progn
                        (setf (alist-get 'body source) (teams4e-compose--org-html (alist-get 'body source)))
                        (json-encode source))))
    (teams4e-calendar-compose--put "SUBMITTED_HASH" hash)
    (setq teams4e-calendar-compose--submitted-payload payload)
    (setq teams4e-calendar-compose--pending t buffer-read-only t header-line-format "Submitting meeting...")
    (let ((failure
           (lambda (_status detail)
             (when (buffer-live-p buffer)
               (with-current-buffer buffer
                 (setq teams4e-calendar-compose--pending nil buffer-read-only nil
                       header-line-format "Submission failed; check Outlook before replacing this draft")))
             (message "Calendar creation failed: %s" (or detail "unknown error")))))
      (condition-case error-data
          (teams4e--run-json
           (append (list "teams" "calendar" "event" "create" "--draft" payload)
                   (when calendar (list "--calendarId" calendar)))
           (lambda (result)
             (let* ((event (teams4e--get result 'event)) (id (teams4e--get event 'id)))
               (if (not (and (stringp id) (not (string-empty-p id))))
                   (funcall failure nil "No event ID returned; check Outlook before retrying")
                 (when (buffer-live-p buffer)
                   (with-current-buffer buffer
                     (let ((inhibit-read-only t)) (teams4e-calendar-compose--put "CREATED_ID" id))
                     (setq teams4e-calendar-compose--pending nil header-line-format "Meeting created")))
                 (when (buffer-live-p owner)
                   (with-current-buffer owner
                     (when (and (equal calendar teams4e-calendar--id)
                                (equal teams4e-calendar--loaded-key (teams4e-calendar--key)))
                       (let ((range (teams4e-calendar--range))
                             (start (teams4e-calendar--time event 'start))
                             (end (teams4e-calendar--time event 'end)))
                         (when (and start end (time-less-p start (cadr range)) (time-less-p (car range) end))
                           (if (seq-some (lambda (old) (equal id (teams4e--get old 'id))) teams4e-calendar--events)
                               (teams4e-calendar--replace-event event)
                             (push event teams4e-calendar--events))
                           (teams4e-calendar--render))))))
                 (message "Meeting created: %s" (teams4e--get event 'subject)))))
           failure)
        (error (funcall failure nil (error-message-string error-data)))))))

(defvar teams4e-calendar-compose-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-c") #'teams4e-calendar-compose-send)
    (define-key map (kbd "C-c C-a") #'teams4e-calendar-compose-add-attendee)
    (define-key map (kbd "C-c C-t") #'teams4e-calendar-compose-set-time)
    (define-key map (kbd "C-c C-k") #'quit-window)
    map))

(define-minor-mode teams4e-calendar-compose-mode
  "Edit a meeting draft in Org.  C-c C-c explicitly creates it and sends invitations."
  :lighter " Calendar-Draft")

;;;###autoload
(defun teams4e-calendar-create ()
  "Open a new editable Org meeting draft without sending or fetching anything."
  (interactive)
  (let* ((owner (and (derived-mode-p 'teams4e-calendar-mode) (current-buffer)))
         (calendar (if owner teams4e-calendar--id teams4e-calendar-id))
         (day (and owner (get-text-property (point) 'teams4e-calendar-day-time)))
         (start (or (and owner (get-text-property (point) 'teams4e-calendar-row-start))
                    (and day (time-add day (* 3600 (car teams4e-calendar-work-hours))))
                    (* 1800 (ceiling (/ (float-time) 1800)))))
         (buffer (generate-new-buffer "*Calendar Draft*")))
    (with-current-buffer buffer
      (org-mode)
      (insert "* New meeting\n:PROPERTIES:\n:END:\n\n")
      (setq-local teams4e-calendar--owner owner)
      (dolist (entry `(("START_AT" . ,(format-time-string "%Y-%m-%dT%H:%M:%S%z" start))
                       ("END_AT" . ,(format-time-string "%Y-%m-%dT%H:%M:%S%z"
                                                      (time-add start (* 60 teams4e-calendar-new-duration))))
                       ("REQUIRED" . "") ("OPTIONAL" . "") ("LOCATION" . "")
                       ("TEAMS" . ,(if teams4e-calendar-new-online-meeting "yes" "no"))
                       ("SHOW_AS" . "busy") ("CALENDAR_ID" . ,(or calendar "")) ("TRANSACTION_ID" . ,(org-id-uuid))))
        (teams4e-calendar-compose--put (car entry) (cdr entry)))
      (teams4e-calendar-compose-mode 1)
      (org-show-all)
      (goto-char (point-min))
      (end-of-line))
    (pop-to-buffer buffer '((display-buffer-reuse-window display-buffer-below-selected)))))

(provide 'teams4e-calendar-create)
;;; teams4e-calendar-create.el ends here
