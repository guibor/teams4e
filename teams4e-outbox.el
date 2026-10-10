;;; teams4e-outbox.el --- Durable local scheduled sending -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Commentary:
;; The Python outbox owns delivery state. Emacs only edits drafts and ticks it.
;;; Code:
(require 'teams4e-compose)
(require 'teams4e-calendar)
(require 'tabulated-list)
(declare-function evil-local-set-key "evil-core" (state key def))
(declare-function markdown-mode "markdown-mode" ())

(defcustom teams4e-outbox-file
  (expand-file-name "teams4e/outbox.sqlite3"
                    (or (getenv "XDG_DATA_HOME") (expand-file-name "~/.local/share")))
  "Private persistent scheduled messages, not a disposable reading cache."
  :type 'file :group 'teams4e)
(defcustom teams4e-schedule-time-zone nil
  "IANA timezone for scheduled sending, e.g. Europe/London.
Nil uses the backend machine's local timezone, including its DST rules."
  :type '(choice (const nil) string) :group 'teams4e)
(defcustom teams4e-schedule-work-days nil
  "Workdays for scheduled sending, Sunday=0 through Saturday=6.
Nil reuses `teams4e-calendar-work-days'; no separate Monday-Friday assumption."
  :type '(choice (const nil) (repeat integer)) :group 'teams4e)
(defcustom teams4e-schedule-start-time nil
  "HH:MM for NEXT workday sending; nil reuses `teams4e-workday-start' (07:00).
NEXT always skips today, even when it is before this time."
  :type '(choice (const nil) string) :group 'teams4e)
(defcustom teams4e-outbox-late-grace 900
  "Seconds after scheduled time during which delivery is still allowed.
Older jobs are held for explicit rescheduling, never silently sent late."
  :type 'natnum :group 'teams4e)
(defvar teams4e-outbox--timer nil)
(defvar teams4e-outbox--running nil)

(defun teams4e-outbox--call (operation args callback &optional failure)
  "Invoke local outbox OPERATION with ARGS and CALLBACK or FAILURE."
  (condition-case error-data
      (progn
        (when (member operation '("put" "run")) (teams4e--require-online))
        (teams4e--run-json
         (append (list "teams" "outbox" operation "--store" (expand-file-name teams4e-outbox-file)) args)
         callback failure))
    (error (if failure (funcall failure "start" (error-message-string error-data))
             (signal (car error-data) (cdr error-data))))))

(defun teams4e-outbox--tick ()
  "Try one due item; never overlap timer requests or send in offline mode."
  (unless (or teams4e-outbox--running teams4e-offline-mode)
    (setq teams4e-outbox--running t)
    (teams4e-outbox--call
     "run" (list "--grace" (number-to-string teams4e-outbox-late-grace))
     (lambda (job)
       (setq teams4e-outbox--running nil)
       (unless (equal (teams4e--get job 'state) "idle")
         (message "Teams outbox: %s %s" (teams4e--get job 'state)
                  (or (teams4e--get job 'note) ""))))
     (lambda (_status _detail)
       (setq teams4e-outbox--running nil)
       (message "Teams outbox unavailable; messages retained. Check authentication/outbox.")))))

;;;###autoload
(define-minor-mode teams4e-outbox-mode
  "Deliver locally queued Teams messages while Emacs is running.
Enable in init to resume after restart. Disabling stops future ticks, not an
already claimed send. No OS service, OpenClaw job or credentials are installed."
  :global t :group 'teams4e
  (when (timerp teams4e-outbox--timer) (cancel-timer teams4e-outbox--timer))
  (setq teams4e-outbox--timer
        (when teams4e-outbox-mode (run-at-time 1 30 #'teams4e-outbox--tick))))

(defun teams4e-outbox--spec (explicit)
  "Build a time specification, prompting for a date when EXPLICIT is non-nil."
  `((mode . ,(if explicit "explicit" "next"))
    (value . ,(if explicit
                  (read-string "Send at (YYYY-MM-DD HH:MM; optional UTC offset): ") ""))
    (zone . ,teams4e-schedule-time-zone)
    (start . ,(or teams4e-schedule-start-time teams4e-workday-start))
    (days . ,(vconcat (or teams4e-schedule-work-days teams4e-calendar-work-days)))))

(defun teams4e-outbox--choose-time (explicit &optional submit)
  "Set the current draft's time; EXPLICIT prompts, SUBMIT also enqueues."
  (unless (teams4e-compose-p) (user-error "Open a Teams composer first"))
  (when teams4e-compose--outbox-busy (user-error "Scheduling is already in progress"))
  (let ((spec (teams4e-outbox--spec explicit)) (buffer (current-buffer)))
    (setq teams4e-compose--outbox-busy t)
    (teams4e-outbox--call
     "time" (list "--payload" (json-serialize spec :null-object nil))
     (lambda (when)
       (when (buffer-live-p buffer)
         (with-current-buffer buffer
           (setq teams4e-compose--outbox-busy nil teams4e-compose--schedule when)
           (teams4e-compose--save-draft)
           (teams4e-compose--update-header)
           (if submit (teams4e-outbox-submit)
             (message "Draft will be queued for %s with C-c C-c"
                      (teams4e--get when 'displayTime))))))
     (lambda (_status detail)
       (when (buffer-live-p buffer)
         (with-current-buffer buffer (setq teams4e-compose--outbox-busy nil)))
       (message "Schedule not set; draft retained: %s" detail)))))

;;;###autoload
(defun teams4e-compose-schedule (&optional explicit)
  "Queue this draft for the NEXT workday; prefix EXPLICIT chooses date/time."
  (interactive "P")
  (teams4e-outbox--choose-time explicit t))

(defun teams4e-compose-schedule-at ()
  "Queue the current draft for an explicit date/time."
  (interactive)
  (teams4e-compose-schedule t))

;;;###autoload
(defun teams4e-send-next-workday (&optional explicit)
  "Compose now for the NEXT workday; prefix EXPLICIT chooses a date/time.
Only C-c C-c commits the schedule. The ordinary draft editor is retained."
  (interactive "P")
  ;; Chat selection can be asynchronous; use its callback directly.
  (let ((open (lambda (target)
                (teams4e--open-compose target)
                (teams4e-outbox--choose-time explicit))))
    (if-let ((chat (teams4e--chat-at-point))) (funcall open chat)
      (teams4e--select-chat open))))

;;;###autoload
(defun teams4e-reply-next-workday (&optional explicit)
  "Reply now, queue with C-c C-c for the NEXT workday or EXPLICIT time."
  (interactive "P")
  (teams4e-reply)
  (teams4e-outbox--choose-time explicit))

(defun teams4e-outbox-submit ()
  "Freeze source, rendered body and recipient in the durable local outbox."
  (interactive)
  (unless (and (teams4e-compose-p) teams4e-compose--schedule)
    (user-error "Choose a schedule first with C-c C-s or C-c C-t"))
  (when teams4e-compose--outbox-busy (user-error "Scheduling is already in progress"))
  (when teams4e-compose--attachments
    (user-error "Scheduled file attachments are not supported; draft retained"))
  (let* ((buffer (current-buffer))
         (source (buffer-substring-no-properties (point-min) (point-max)))
         (rendered (teams4e-compose--render-body source))
         (mentions (teams4e-compose--effective-mentions source))
         (id (or teams4e-compose--outbox-id
                 (setq teams4e-compose--outbox-id
                       (secure-hash 'sha256 (format "%s:%s:%s" (current-time) (random) source)))))
         (payload
          `((id . ,id) (revision . ,teams4e-compose--outbox-revision)
            (when . ,teams4e-compose--schedule)
            (message . ,(cdr rendered)) (contentType . ,(car rendered))
            (draft . ((body . ,source) (editor . ,(symbol-name teams4e-compose--editor))
                      (contentType . ,teams4e-compose--content-type)
                      (target . ,(teams4e-compose--draft-target-record))
                      (replyTo . ,(teams4e-compose--draft-reply-record))
                      (mentions . ,(vconcat mentions)))))))
    (when (string-empty-p (string-trim source)) (user-error "Message is empty"))
    (teams4e-compose--save-draft)
    (setq teams4e-compose--outbox-busy t buffer-read-only t)
    (teams4e-outbox--call
     "put" (list "--payload" (json-serialize payload :null-object nil))
     (lambda (job)
       (teams4e-outbox-mode 1)
       (when (buffer-live-p buffer)
         (with-current-buffer buffer (teams4e-compose--delete-draft))
         (kill-buffer buffer))
       (message "Teams outbox: %s for %s (Emacs must be running)"
                (teams4e--get job 'state) (teams4e--get job 'displayTime)))
     (lambda (_status detail)
       (when (buffer-live-p buffer)
         (with-current-buffer buffer
           (setq teams4e-compose--outbox-busy nil buffer-read-only nil)
           (teams4e-compose--update-header)))
       (message "Not confirmed queued; draft retained. Check outbox before retrying: %s" detail)))))

(defvar teams4e-outbox-view-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map tabulated-list-mode-map)
    (define-key map (kbd "g") #'teams4e-outbox)
    (define-key map (kbd "e") #'teams4e-outbox-edit)
    (define-key map (kbd "RET") #'teams4e-outbox-edit)
    (define-key map (kbd "d") #'teams4e-outbox-cancel)
    map))
(define-derived-mode teams4e-outbox-view-mode tabulated-list-mode "Teams-Outbox"
  "Scheduled local messages. Edit holds delivery until explicitly queued again."
  (setq tabulated-list-format [("State" 10 t) ("Send at" 34 t) ("To" 24 t) ("Message / status" 0 nil)]
        tabulated-list-padding 1)
  (tabulated-list-init-header)
  (when (fboundp 'evil-local-set-key)
    (dolist (state '(normal motion))
      (dolist (binding '(("g" . teams4e-outbox) ("e" . teams4e-outbox-edit)
                         ("RET" . teams4e-outbox-edit) ("d" . teams4e-outbox-cancel)
                         ("q" . quit-window)))
        (evil-local-set-key state (kbd (car binding)) (cdr binding))))))

;;;###autoload
(defun teams4e-outbox ()
  "List scheduled messages, including held, cancelled and uncertain outcomes."
  (interactive)
  (let ((buffer (get-buffer-create "*Teams Outbox*")))
    (pop-to-buffer buffer)
    (unless (derived-mode-p 'teams4e-outbox-view-mode) (teams4e-outbox-view-mode))
    (teams4e-outbox--call
     "list" nil
     (lambda (jobs)
       (when (buffer-live-p buffer)
         (with-current-buffer buffer
           (setq tabulated-list-entries
                 (mapcar (lambda (job)
                           (list (teams4e--get job 'id)
                                 (vector (teams4e--get job 'state) (teams4e--get job 'displayTime)
                                         (or (teams4e--dig job 'draft 'target 'label) "")
                                         (concat (or (teams4e--get job 'note) "") " "
                                                 (replace-regexp-in-string "[\n\r]+" " "
                                                   (or (teams4e--dig job 'draft 'body) ""))))))
                         (teams4e--payload-list jobs)))
           (tabulated-list-print t)))))))

(defun teams4e-outbox-cancel ()
  "Cancel the selected pending message, preserving its local record."
  (interactive)
  (let ((id (or (tabulated-list-get-id) (user-error "Select a scheduled message"))))
    (teams4e-outbox--call "cancel" (list "--id" id) (lambda (_) (teams4e-outbox)))))

(defun teams4e-outbox-edit ()
  "Hold the selected message atomically, then edit without risking delivery."
  (interactive)
  (teams4e-outbox--edit-id
   (or (tabulated-list-get-id) (user-error "Select a scheduled message"))))

(defun teams4e-outbox--edit-id (id)
  "Hold and reopen ID, preserving recoverable source edits for its revision."
  (let ((existing (get-buffer (format "*Teams scheduled: %s*" id))))
    (if existing (pop-to-buffer existing)
    (teams4e-outbox--call
     "hold" (list "--id" id)
     (lambda (job)
       (let* ((file (expand-file-name (concat "scheduled-" id ".json") teams4e-draft-directory))
              (saved (and (file-readable-p file) (teams4e-compose--read-draft file)))
              (draft (if (and (equal (teams4e--get saved 'outboxId) id)
                              (equal (teams4e--get saved 'outboxRevision)
                                     (1- (teams4e--get job 'revision))))
                         saved (teams4e--get job 'draft)))
              (target (teams4e-compose--record-target (teams4e--get draft 'target)))
              (buffer (get-buffer-create (format "*Teams scheduled: %s*" id)))
              (editor (intern (teams4e--get draft 'editor))))
         (when (with-current-buffer buffer (buffer-modified-p))
           (user-error "An edited scheduled draft is already open; retained and delivery held"))
         (pop-to-buffer buffer)
         (pcase editor
           ('org (org-mode))
           ('markdown (require 'markdown-mode) (markdown-mode))
           (_ (teams4e-compose-mode)))
         (teams4e-compose-edit-mode 1)
         (setq teams4e-compose--target target teams4e-compose--editor editor
               teams4e-compose--reply-to (teams4e--get draft 'replyTo)
               teams4e-compose--mentions (teams4e--get draft 'mentions)
               teams4e-compose--content-type (teams4e--get draft 'contentType)
               teams4e-compose--outbox-id id
               teams4e-compose--outbox-revision (teams4e--get job 'revision)
               teams4e-compose--schedule
               `((sendAt . ,(teams4e--get job 'sendAt)) (displayTime . ,(teams4e--get job 'displayTime))
                 (zone . ,(teams4e--get job 'zone)))
               teams4e-compose--draft-file file)
         (erase-buffer)
         (insert (teams4e--get draft 'body))
         (teams4e-compose--save-draft)
         (teams4e-compose--update-header)
         (message "Delivery held. C-c C-c requeues; C-c C-t changes the time.")))))))

(define-key teams4e-compose-mode-map (kbd "C-c C-s") #'teams4e-compose-schedule)
(define-key teams4e-compose-mode-map (kbd "C-c C-t") #'teams4e-compose-schedule-at)
(provide 'teams4e-outbox)
;;; teams4e-outbox.el ends here
