;;; teams4e-ui.el --- Native Microsoft Teams user interface. -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; This file provides the asynchronous Teams UI.  A bundled Python adapter
;; consumes short-lived Graph tokens; Emacs owns selection, rendering,
;; composition, and capture.

;;; Code:

(require 'button)
(require 'browse-url)
(require 'cl-lib)
(require 'comint)
(require 'dom)
(require 'json)
(require 'teams4e-config)
(require 'shr)
(require 'subr-x)
(require 'tabulated-list)
(require 'time-date)
(require 'url-util)

(declare-function org-end-of-meta-data "org" (&optional full))
(declare-function org-entry-put "org" (pom property value))
(declare-function org-entry-get "org" (pom property &optional inherit literal-nil))
(declare-function org-map-entries "org" (func &optional match scope &rest skip))
(declare-function org-reveal "org")
(declare-function org-show-context "org" (&optional key))
(declare-function org-capture-string "org-capture" (string &optional keys))
(declare-function teams4e-capture-current-thread "advanced")
(declare-function teams4e-bulk-action "advanced")
(declare-function teams4e-toggle-selection "advanced")
(declare-function teams4e-toggle-visible-selections "advanced")
(declare-function teams4e-toggle-unread-filter "advanced")
(declare-function teams4e--refresh-current-view "advanced")
(declare-function teams4e--meeting-view-p "advanced")
(declare-function teams4e--render-channel-thread "advanced")
(declare-function teams4e-thread-next "advanced")
(declare-function teams4e-thread-previous "advanced")
(declare-function teams4e-mark-read-later "advanced")
(declare-function teams4e-message-forward "advanced")

(defvar org-capture-templates)

;; Defined as user options in config.el; declarations keep standalone byte
;; compilation useful without duplicating defaults.
(defvar teams4e-bootstrap-program)
(defvar teams4e-credentials-file)
(defvar teams4e-token-command)
(defvar teams4e-credential-server-name)
(defvar teams4e-credential-server-url)
(defvar teams4e-use-persistent-backend)
(defvar teams4e-mock-mode)
(defvar teams4e-mock-state-file)
(defvar teams4e-capture-file)
(defvar teams4e-cache-file)
(defvar teams4e-cache-first)
(defvar teams4e-app-command)
(defvar teams4e-browser-command)
(defvar teams4e-chat-metadata-limit)
(defvar teams4e-confirm-send)
(defvar teams4e-default-content-type)
(defvar teams4e-default-view)
(defvar teams4e-display-images)
(defvar teams4e-draft-directory)
(defvar teams4e-export-directory)
(defvar teams4e-image-cache-directory)
(defvar teams4e-image-download-concurrency)
(defvar teams4e-image-max-height)
(defvar teams4e-image-max-width)
(defvar teams4e-index-width)
(defvar teams4e-mark-read-on-open)
(defvar teams4e-member-enrichment-concurrency)
(defvar teams4e-member-enrichment-limit)
(defvar teams4e-meeting-enrichment-concurrency)
(defvar teams4e-meeting-enrichment-limit)
(defvar teams4e-load-more-count)
(defvar teams4e-message-days)
(defvar teams4e-message-limit)
(defvar teams4e-message-order)
(defvar teams4e-offline-mode)
(defvar teams4e-preview-delay)
(defvar teams4e-preview-cache-seconds)
(defvar teams4e-preview-message-limit)
(defvar teams4e-preview-on-move)
(defvar teams4e-state-file)
(defvar teams4e-status-style)

(defvar teams4e--process-sequence 0)
(defvar teams4e--server-sequence 0)
(defvar teams4e--server-process nil)
(defvar teams4e--server-fingerprint nil)
(defvar teams4e--server-pending (make-hash-table :test #'eql))
(defconst teams4e--server-stdout-noise-limit 8
  "Maximum consecutive non-protocol stdout lines tolerated from the server.")

(cl-defstruct (teams4e-request
               (:constructor teams4e--make-request (id)))
  "Handle for one request sent through the persistent backend transport."
  id
  cancelled)
(defvar teams4e--chats nil)
(defvar teams4e--active-view nil)
(defvar teams4e--active-query nil)
(defvar teams4e--active-filter-name nil)

(defun teams4e--default-view ()
  "Return the configured default inbox view, falling back to inbox."
  (if (boundp 'teams4e-default-view)
      teams4e-default-view
    'inbox))

(defun teams4e--ensure-active-view ()
  "Initialize `teams4e--active-view' from config when unset."
  (unless teams4e--active-view
    (setq teams4e--active-view (teams4e--default-view))))
(defvar teams4e--connected-as nil)
(defvar teams4e--connected-user-id nil)
(defvar teams4e--member-cache (make-hash-table :test #'equal))
(defvar teams4e--member-inflight (make-hash-table :test #'equal))
(defvar teams4e--meeting-inflight (make-hash-table :test #'equal))
(defconst teams4e--no-members 'teams4e--no-members)
(defvar teams4e--favorites (make-hash-table :test #'equal))
(defvar teams4e--muted (make-hash-table :test #'equal))
(defvar teams4e--handled (make-hash-table :test #'equal))
(defvar teams4e--snoozed (make-hash-table :test #'equal))
(defvar teams4e--saved-views (make-hash-table :test #'equal))
(defvar teams4e--captured-chat-table (make-hash-table :test #'equal)
  "Ephemeral chat-ID snapshot derived from the configured Org capture file.")
(defvar teams4e--captured-chat-signature nil
  "File signature used to invalidate the ephemeral Org capture snapshot.")
(defvar teams4e--captured-chat-checked-at 0.0
  "Time when the Org capture snapshot last checked its source signature.")
(defconst teams4e--captured-chat-check-seconds 5.0
  "Minimum interval between capture-file metadata checks during redraws.")
(defvar teams4e--read-overrides (make-hash-table :test #'equal))
(defvar teams4e--state-loaded nil)
(defvar teams4e--window-configurations
  (make-hash-table :test #'eq :weakness 'key)
  "Window configurations saved before entering the Teams workspace.")
(defvar teams4e--inhibit-reader-follow nil
  "Non-nil while a reader command is deliberately managing headers itself.")
(defconst teams4e--recent-buffer-name "*Teams Recent*")
(defconst teams4e--read-buffer-name "*Teams Read*")
(defconst teams4e--preview-buffer-name teams4e--read-buffer-name
  "Compatibility name for the singleton Teams reader.")
(defconst teams4e--channel-preview-buffer-name
  teams4e--read-buffer-name
  "Compatibility name for the singleton Teams reader.")
(defconst teams4e--error-buffer-name "*M365 Errors*")
(defconst teams4e--recent-format
  [("Status" 6 nil)
   ("Message time" 16 t)
   ("Type" 8 t)
   ("Conversation" 28 t)
   ("Star" 4 nil)
   ("Last message" 0 nil)]
  "Aligned columns used by message-oriented Teams views.")
(defconst teams4e--meeting-recent-format
  [("Status" 6 nil)
   ("Message time" 16 t)
   ("Type" 8 t)
   ("Conversation" 28 t)
   ("Meeting" 38 t)
   ("Star" 4 nil)
   ("Last message" 0 nil)]
  "Aligned columns used by meeting-only Teams views.")

(defvar-local teams4e--process nil)
(defvar-local teams4e--chat nil)
(defvar-local teams4e--messages nil)
(defvar-local teams4e--loaded-at nil)
(defvar-local teams4e--loaded-update nil)
(defvar-local teams4e--loaded-all nil)
(defvar-local teams4e--message-order nil)
(defvar-local teams4e--request-id 0)
(defvar-local teams4e--preview-timer nil)
(defvar-local teams4e--inbox-source-label nil)
(defvar-local teams4e--automatic-preview-p nil)
(defvar-local teams4e--pending-message-id nil)
(defvar-local teams4e--jump-to-bottom-on-render nil)
(defvar-local teams4e--meeting-context nil)
(defvar-local teams4e--meeting-process nil)
(defvar-local teams4e--meeting-request-id 0)
(defvar-local teams4e--image-processes nil)
(defvar-local teams4e--image-queue nil)
(defvar-local teams4e--image-active 0)
(defvar-local teams4e-compose--target nil)
(defvar-local teams4e-compose--origin nil)
(defvar-local teams4e-compose--reply-to nil)
(defvar-local teams4e-compose--attachments nil)
(defvar-local teams4e-compose--mentions nil)
(defvar-local teams4e-compose--content-type "text")
(defvar-local teams4e-compose--draft-timer nil)
(defvar-local teams4e-compose--draft-file nil)
(defvar teams4e--cache-first-open nil
  "Dynamically bound while a newly selected chat performs its initial load.")

;; Defined by advanced.el; declarations keep the shared message renderer able
;; to resolve relative hosted-content URLs in channel thread buffers.
(defvar teams4e-channel--team)
(defvar teams4e-channel--channel)
(defvar teams4e-channel--root)

(defface teams4e-own-sender
  '((t :inherit success :weight semi-bold))
  "Face for the signed-in user's message header."
  :group 'teams4e)

(defface teams4e-other-sender
  '((t :inherit font-lock-keyword-face :weight semi-bold))
  "Face for another participant's message header."
  :group 'teams4e)

(defface teams4e-unread
  '((t :weight bold))
  "Face for unread chat rows."
  :group 'teams4e)

(defface teams4e-type-direct
  '((t :inherit font-lock-keyword-face :weight semi-bold))
  "Face for one-to-one Teams chat labels."
  :group 'teams4e)

(defface teams4e-type-group
  '((t :inherit font-lock-function-name-face :weight semi-bold))
  "Face for group Teams chat labels."
  :group 'teams4e)

(defface teams4e-type-meeting
  '((t :inherit font-lock-warning-face :weight semi-bold))
  "Face for meeting Teams chat labels."
  :group 'teams4e)

(defface teams4e-type-channel
  '((t :inherit success :weight semi-bold))
  "Face for Teams channel labels."
  :group 'teams4e)

;; Recalculate existing frames when this layer is reloaded in a live session.
(face-spec-set 'teams4e-unread '((t :weight bold))
               'face-defface-spec)

(defface teams4e-day-separator
  '((t :inherit shadow :weight bold :overline t))
  "Face for transcript date separators."
  :group 'teams4e)

(defface teams4e-event
  '((t :inherit shadow :slant italic))
  "Face for readable Teams system-event summaries."
  :group 'teams4e)

(defface teams4e-image-label
  '((t :inherit link :weight semi-bold))
  "Face for inline Teams image labels."
  :group 'teams4e)

(defun teams4e--executable ()
  "Resolve the configured passive Graph backend executable."
  (let* ((configured (and (boundp 'teams4e-backend-program)
                          teams4e-backend-program))
         (explicit (and configured
                        (string-match-p "/" configured)
                        (expand-file-name configured)))
         (candidates
          (append
           (and explicit (list explicit))
           (and configured (list (executable-find configured))))))
    (or (seq-find (lambda (path)
                    (and (stringp path) (file-executable-p path)))
                  candidates)
        (user-error
         (concat "The teams4e Graph backend is unavailable; check "
                 "`teams4e-backend-program`")))))

(defun teams4e--configure-process-environment ()
  "Configure the current dynamic subprocess environment for Graph access."
  (setenv "TEAMS4E_TOKEN_COMMAND"
          (and teams4e-token-command (json-encode teams4e-token-command)))
  (setenv "TEAMS4E_CREDENTIALS"
          (expand-file-name teams4e-credentials-file))
  (setenv "TEAMS4E_BOOTSTRAP_COMMAND" teams4e-bootstrap-program)
  (setenv "TEAMS4E_CREDENTIAL_SERVER_NAME" teams4e-credential-server-name)
  (setenv "TEAMS4E_CREDENTIAL_SERVER_URL" teams4e-credential-server-url)
  (setenv "TEAMS4E_CACHE" (expand-file-name teams4e-cache-file))
  (setenv "TEAMS4E_MOCK" (if teams4e-mock-mode "1" nil))
  (setenv "TEAMS4E_MOCK_STATE"
          (and teams4e-mock-mode
               (expand-file-name teams4e-mock-state-file))))

(defun teams4e--redacted-args (args)
  "Return ARGS with private outgoing content hidden for diagnostics."
  (let (result redact-next)
    (dolist (arg args (nreverse result))
      (push (if redact-next "<content redacted>" arg) result)
      (setq redact-next (member arg '("--message" "--comment"))))))

(defun teams4e--command-string (args)
  "Return a shell-quoted diagnostic command for ARGS."
  (mapconcat #'shell-quote-argument
             (cons (teams4e--executable) (teams4e--redacted-args args))
             " "))

(defun teams4e--redacted-detail (args detail)
  "Remove exact outgoing message or comment values from diagnostic DETAIL."
  (let ((redacted detail))
    (dolist (option '("--message" "--comment") redacted)
      (let ((value (cadr (member option args))))
        (when (and (stringp redacted) (stringp value)
                   (not (string-empty-p value)))
          (setq redacted
                (replace-regexp-in-string
                 (regexp-quote value) "<content redacted>" redacted t t)))))))

(defun teams4e--report-error (args status detail)
  "Record a failed Teams backend invocation of ARGS with STATUS and DETAIL."
  (let ((buffer (get-buffer-create teams4e--error-buffer-name)))
    (with-current-buffer buffer
      (goto-char (point-max))
      (insert (format-time-string "[%Y-%m-%d %H:%M:%S] "))
      (insert (format "exit %s: %s\n" status (teams4e--command-string args)))
      (setq detail (teams4e--redacted-detail args detail))
      (unless (string-empty-p (string-trim detail))
        (insert (string-trim-right detail) "\n"))
      (insert "\n"))
    (display-buffer buffer)
    (message "Teams Graph command failed; see %s" teams4e--error-buffer-name)))

(defun teams4e--cancel-process (process)
  "Cancel PROCESS or persistent request without reporting a failure."
  (cond
   ((and (processp process) (process-live-p process))
    (process-put process 'teams4e-cancelled t)
    (delete-process process))
   ((teams4e-request-p process)
    (setf (teams4e-request-cancelled process) t)
    (remhash (teams4e-request-id process) teams4e--server-pending))))

(defun teams4e--request-live-p (request)
  "Return non-nil while REQUEST can still deliver a backend callback."
  (cond
   ((processp request) (process-live-p request))
   ((teams4e-request-p request)
    (and (not (teams4e-request-cancelled request))
         (gethash (teams4e-request-id request)
                  teams4e--server-pending)))
   (t nil)))

(cl-defun teams4e--run (args callback &optional error-callback)
  "Run the Teams Graph backend with ARGS asynchronously.

CALLBACK receives standard output after a successful exit.  ERROR-CALLBACK,
when non-nil, receives the exit status and combined diagnostic text."
  (let* ((program (teams4e--executable))
         (sequence (cl-incf teams4e--process-sequence))
         (stdout (generate-new-buffer (format " *m365-%d-out*" sequence)))
         (stderr (generate-new-buffer (format " *m365-%d-err*" sequence)))
         (process-environment (copy-sequence process-environment))
         (program-dir (file-name-directory program))
         process)
    (teams4e--configure-process-environment)
    (setenv "PATH" (concat program-dir path-separator (or (getenv "PATH") "")))
    (setq process
          (make-process
           :name (format "m365-%d" sequence)
           :buffer stdout
           :stderr stderr
           :command (cons program args)
           :coding 'utf-8-unix
           :connection-type 'pipe
           :noquery t
           :sentinel
           (lambda (proc _event)
             (when (memq (process-status proc) '(exit signal))
               (let* ((status (process-exit-status proc))
                      (cancelled (process-get proc 'teams4e-cancelled))
                      (out (when (buffer-live-p stdout)
                             (with-current-buffer stdout (buffer-string))))
                      (err (when (buffer-live-p stderr)
                             (with-current-buffer stderr (buffer-string))))
                      (detail (concat (or err "") (or out ""))))
                 (unwind-protect
                     (unless cancelled
                       (condition-case callback-error
                           (if (zerop status)
                               (when callback (funcall callback (or out "")))
                             (if error-callback
                                 (funcall error-callback status detail)
                               (teams4e--report-error args status detail)))
                         (error
                          (teams4e--report-error
                           args "callback"
                           (error-message-string callback-error)))))
                   (when (buffer-live-p stdout) (kill-buffer stdout))
                   (when (buffer-live-p stderr) (kill-buffer stderr))))))))
    process))

(defun teams4e--args-prefix-p (prefix args)
  "Return non-nil when string list ARGS begins with PREFIX."
  (equal prefix (seq-take args (length prefix))))

(defun teams4e--persistent-command-p (program args)
  "Return non-nil when PROGRAM can safely serve ARGS persistently."
  (and teams4e-use-persistent-backend
       (string-equal (file-name-nondirectory program)
                     "teams4e-graph")
       (or
        (teams4e--args-prefix-p '("status") args)
        (and (teams4e--args-prefix-p '("teams" "cache") args)
             (not (teams4e--args-prefix-p
                   '("teams" "cache" "clear") args)))
        (teams4e--args-prefix-p '("teams" "sync") args)
        (teams4e--args-prefix-p '("teams" "search") args)
        (and (teams4e--args-prefix-p '("teams" "meeting") args)
             (not (teams4e--args-prefix-p
                   '("teams" "meeting" "propose" "send") args)))
        (teams4e--args-prefix-p '("teams" "team" "list") args)
        (teams4e--args-prefix-p '("teams" "channel" "list") args)
        (teams4e--args-prefix-p '("teams" "channel" "message" "list") args)
        (teams4e--args-prefix-p '("teams" "channel" "reply" "list") args)
        (teams4e--args-prefix-p '("teams" "user" "search") args)
        (teams4e--args-prefix-p '("teams" "user" "profile") args)
        (teams4e--args-prefix-p '("teams" "user" "presence") args)
        (teams4e--args-prefix-p '("teams" "chat" "list") args)
        (teams4e--args-prefix-p '("teams" "chat" "get") args)
        (teams4e--args-prefix-p
         '("teams" "chat" "member" "batch") args)
        (teams4e--args-prefix-p
         '("teams" "chat" "member" "list") args)
        (teams4e--args-prefix-p '("teams" "chat" "message" "list") args))))

(defun teams4e--current-server-fingerprint (program)
  "Return the non-secret configuration fingerprint for PROGRAM."
  (list (file-truename program)
        (expand-file-name teams4e-credentials-file)
        teams4e-bootstrap-program
        (expand-file-name teams4e-cache-file)
        teams4e-mock-mode
        (and teams4e-mock-mode
             (expand-file-name teams4e-mock-state-file))))

(defun teams4e--fail-server-requests (server detail)
  "Fail pending requests owned by SERVER with DETAIL."
  (let (ids)
    (maphash
     (lambda (id pending)
       (when (eq server (plist-get pending :server))
         (push id ids)))
     teams4e--server-pending)
    (dolist (id ids)
      (when-let ((pending (gethash id teams4e--server-pending)))
        (remhash id teams4e--server-pending)
        (let ((request (plist-get pending :request))
              (error-callback (plist-get pending :error-callback))
              (args (plist-get pending :args)))
          (unless (teams4e-request-cancelled request)
            (if error-callback
                (funcall error-callback "server" detail)
              (teams4e--report-error args "server" detail))))))))

(defun teams4e--stop-server (&optional detail)
  "Stop the persistent backend and optionally fail requests with DETAIL."
  (when-let ((server teams4e--server-process))
    (setq teams4e--server-process nil
          teams4e--server-fingerprint nil)
    (process-put server 'teams4e-intentional-stop t)
    (when detail (teams4e--fail-server-requests server detail))
    (unless detail
      (let (ids)
        (maphash
         (lambda (id pending)
           (when (eq server (plist-get pending :server)) (push id ids)))
         teams4e--server-pending)
        (dolist (id ids) (remhash id teams4e--server-pending))))
    (when (process-live-p server) (delete-process server))
    (when-let ((stderr (process-get server 'teams4e-stderr-buffer)))
      (when (buffer-live-p stderr) (kill-buffer stderr)))))

(defun teams4e--server-line-preview (line)
  "Return a bounded, token-redacted diagnostic preview of LINE."
  (let* ((redacted
          (replace-regexp-in-string
           "eyJ[[:alnum:]_.-]+" "<token redacted>" line t t))
         (quoted (prin1-to-string redacted)))
    (truncate-string-to-width quoted 240 nil nil "...")))

(defun teams4e--record-server-stdout-noise (server text)
  "Record non-protocol stdout TEXT from SERVER and return whether to continue."
  (let* ((count (1+ (or (process-get server 'teams4e-stdout-noise-count) 0)))
         (preview (teams4e--server-line-preview text)))
    (process-put server 'teams4e-stdout-noise-count count)
    (with-current-buffer (get-buffer-create teams4e--error-buffer-name)
      (goto-char (point-max))
      (insert (format-time-string "[%Y-%m-%d %H:%M:%S] "))
      (insert (format "[warning] ignored persistent backend stdout: %s\n\n"
                      preview)))
    (if (> count teams4e--server-stdout-noise-limit)
        (progn
          (teams4e--stop-server
           (format "Persistent backend emitted too much non-JSON stdout; last line: %s"
                   preview))
          nil)
      t)))

(defun teams4e--dispatch-server-line (server line)
  "Extract and dispatch one protocol response from SERVER output LINE.

Python startup hooks can write a banner before the backend owns stdout.  Ignore
and record that bounded noise; if an envelope is glued to it, retain the JSON
suffix beginning with its top-level ID field."
  (let* ((line (string-trim line))
         (response-start
          (string-match "{[[:space:]]*\"id\"[[:space:]]*:" line)))
    (if (not response-start)
        (unless (string-empty-p line)
          (teams4e--record-server-stdout-noise server line))
      (let ((prefix (substring line 0 response-start)))
        (when (or (string-empty-p prefix)
                  (teams4e--record-server-stdout-noise server prefix))
          (teams4e--handle-server-response
           server (substring line response-start)))))))

(defun teams4e--handle-server-response (server line)
  "Dispatch one persistent SERVER response encoded by LINE."
  (condition-case parse-error
      (let* ((response
              (json-parse-string line :object-type 'alist :array-type 'list
                                 :null-object nil :false-object nil))
             (id (teams4e--get response 'id))
             (pending (and (integerp id)
                           (gethash id teams4e--server-pending))))
        (process-put server 'teams4e-stdout-noise-count 0)
        (when pending
          (remhash id teams4e--server-pending)
          (let ((request (plist-get pending :request))
                (callback (plist-get pending :callback))
                (error-callback (plist-get pending :error-callback))
                (args (plist-get pending :args)))
            (unless (teams4e-request-cancelled request)
              (condition-case callback-error
                  (if (teams4e--get response 'ok)
                      (when callback
                        (funcall callback (teams4e--get response 'result)))
                    (let ((detail (or (teams4e--get response 'error)
                                      "Persistent backend request failed")))
                      (if error-callback
                          (funcall error-callback "server" detail)
                        (teams4e--report-error args "server" detail))))
                (error
                 (teams4e--report-error
                  args "callback" (error-message-string callback-error))))))))
    (error
     (teams4e--stop-server
      (format "Invalid persistent backend JSON %s: %s"
              (teams4e--server-line-preview line)
              (error-message-string parse-error))))))

(defun teams4e--server-filter (server chunk)
  "Accumulate and dispatch newline-delimited responses from SERVER CHUNK."
  (let* ((data (concat (or (process-get server 'teams4e-partial) "") chunk))
         (start 0))
    (while (string-match "\n" data start)
      (let ((line (substring data start (match-beginning 0)))
            (next-start (match-end 0)))
        (unless (string-empty-p (string-trim line))
          (teams4e--dispatch-server-line server line))
        ;; Dispatch and user callbacks may run regexp searches of their own.
        (setq start next-start)))
    (process-put server 'teams4e-partial (substring data start))))

(defun teams4e--server-sentinel (server _event)
  "Handle termination of persistent backend SERVER."
  (when (memq (process-status server) '(exit signal))
    (let* ((stderr-buffer (process-get server 'teams4e-stderr-buffer))
           (stderr (and (buffer-live-p stderr-buffer)
                        (with-current-buffer stderr-buffer (buffer-string))))
           (intentional (process-get server 'teams4e-intentional-stop)))
      (when (eq server teams4e--server-process)
        (setq teams4e--server-process nil
              teams4e--server-fingerprint nil))
      (unless intentional
        (teams4e--fail-server-requests
         server
         (if (string-empty-p (string-trim (or stderr "")))
             "Persistent backend exited unexpectedly"
           (string-trim stderr))))
      (when (buffer-live-p stderr-buffer) (kill-buffer stderr-buffer)))))

(defun teams4e--ensure-server (program)
  "Return a live persistent backend for PROGRAM and current configuration."
  (let ((fingerprint (teams4e--current-server-fingerprint program)))
    (unless (and (processp teams4e--server-process)
                 (process-live-p teams4e--server-process)
                 (equal fingerprint teams4e--server-fingerprint))
      (teams4e--stop-server)
      (let* ((process-environment (copy-sequence process-environment))
             (program-dir (file-name-directory program))
             (stderr (generate-new-buffer " *m365-server-errors*")))
        (teams4e--configure-process-environment)
        (setenv "PATH" (concat program-dir path-separator
                                (or (getenv "PATH") "")))
        (setq teams4e--server-process
              (make-process
               :name "m365-server"
               :buffer nil
               :stderr stderr
               :command (list program "serve")
               :coding 'utf-8-unix
               :connection-type 'pipe
               :noquery t
               :filter #'teams4e--server-filter
               :sentinel #'teams4e--server-sentinel)
              teams4e--server-fingerprint fingerprint)
        (process-put teams4e--server-process
                     'teams4e-stderr-buffer stderr)))
    teams4e--server-process))

(defun teams4e--run-json-persistent
    (program args callback &optional error-callback)
  "Send ARGS through persistent PROGRAM and invoke parsed JSON CALLBACK."
  (let* ((server (teams4e--ensure-server program))
         (id (cl-incf teams4e--server-sequence))
         (request (teams4e--make-request id)))
    (puthash id
             (list :request request :server server :args args
                   :callback callback :error-callback error-callback)
             teams4e--server-pending)
    (condition-case send-error
        (process-send-string
         server
         (concat
          (json-serialize `((id . ,id) (args . ,(vconcat args))))
          "\n"))
      (error
       (remhash id teams4e--server-pending)
       (teams4e--stop-server)
       (signal (car send-error) (cdr send-error))))
    request))

(defun teams4e--run-json-once (args callback &optional error-callback)
  "Run one-shot backend ARGS and pass parsed JSON to CALLBACK."
  (teams4e--run
   args
   (lambda (output)
     (condition-case parse-error
         (funcall callback
                  (json-parse-string
                   (string-trim output)
                   :object-type 'alist
                   :array-type 'list
                   :null-object nil
                   :false-object nil))
       (error
        (if error-callback
            (funcall error-callback
                     "JSON"
                     (format "%s\nOutput:\n%s"
                             (error-message-string parse-error) output))
          (teams4e--report-error
           args "JSON" (error-message-string parse-error))))))
   error-callback))

(defun teams4e--run-json (args callback &optional error-callback)
  "Run the Teams backend with ARGS and pass parsed JSON to CALLBACK.

ERROR-CALLBACK has the same contract as in `teams4e--run'."
  (let ((json-args (if (member "--output" args)
                       args
                     (append args '("--output" "json"))))
        (program (teams4e--executable)))
    (if (teams4e--persistent-command-p program json-args)
        (condition-case nil
            (teams4e--run-json-persistent
             program json-args callback error-callback)
          (error
           (teams4e--run-json-once json-args callback error-callback)))
      (teams4e--run-json-once json-args callback error-callback))))

(defun teams4e--get (object key)
  "Read KEY from JSON alist OBJECT using symbol or string keys."
  (when (listp object)
    (or (alist-get key object)
        (alist-get (if (symbolp key) (symbol-name key) key)
                   object nil nil #'equal))))

(defun teams4e--dig (object &rest keys)
  "Read nested KEYS from JSON alist OBJECT."
  (dolist (key keys object)
    (setq object (teams4e--get object key))))

(defun teams4e--payload-list (payload)
  "Normalize an array or Graph-style value wrapper in PAYLOAD."
  (cond
   ((vectorp payload) (append payload nil))
   ((teams4e--get payload 'value)
    (teams4e--payload-list (teams4e--get payload 'value)))
   ((null payload) nil)
   ;; A JSON array parsed as a list begins with an alist, whose first item is
   ;; itself a cons.  A single JSON object begins directly with a key/value.
   ((and (listp payload) (consp (car payload)) (consp (caar payload))) payload)
   (t (list payload))))

(defun teams4e--format-date (value &optional long)
  "Format ISO date VALUE for display, using LONG format when requested."
  (if (not (and (stringp value) (not (string-empty-p value))))
      ""
    (condition-case nil
        (format-time-string (if long "%Y-%m-%d %H:%M" "%b %e %H:%M")
                            (date-to-time value))
      (error value))))

(defun teams4e--org-date (value)
  "Format ISO date VALUE as an inactive Org timestamp."
  (condition-case nil
      (format-time-string "[%Y-%m-%d %a %H:%M]" (date-to-time value))
    (error (format-time-string "[%Y-%m-%d %a %H:%M]"))))

(defun teams4e--html-to-text (html)
  "Render Teams HTML fragment HTML as readable plain text."
  (if (not (and (stringp html) (string-match-p "<[^>]+>" html)))
      (string-trim (or html ""))
    (condition-case nil
        (with-temp-buffer
          (insert "<html><body>" html "</body></html>")
          (let ((dom (libxml-parse-html-region (point-min) (point-max)))
                (shr-inhibit-images t)
                (shr-use-colors nil)
                (shr-use-fonts nil))
            (erase-buffer)
            (shr-insert-document dom)
            (string-trim (buffer-string))))
      (error
       (string-trim
        (replace-regexp-in-string "<[^>]+>" " " (or html "")))))))

(defun teams4e--event-detail-type (message)
  "Return MESSAGE's short Graph system-event detail type."
  (when-let* ((detail (teams4e--get message 'eventDetail))
              (odata-type (teams4e--get detail (intern "@odata.type")))
              ((stringp odata-type)))
    (string-remove-suffix
     "EventMessageDetail"
     (car (last (split-string odata-type "\\." t))))))

(defun teams4e--event-identity-name (identity)
  "Return the best display name represented by event IDENTITY."
  (or (teams4e--dig identity 'user 'displayName)
      (teams4e--dig identity 'application 'displayName)
      (teams4e--dig identity 'device 'displayName)
      (teams4e--get identity 'displayName)))

(defun teams4e--event-member-names (detail)
  "Return display names from a Graph event DETAIL member collection."
  (delq nil
        (mapcar #'teams4e--event-identity-name
                (teams4e--payload-list
                 (teams4e--get detail 'members)))))

(defun teams4e--format-duration (duration)
  "Format ISO 8601 DURATION compactly for a transcript."
  (if (not (and (stringp duration)
                (string-match
                 (concat "\\`P\\(?:\\([0-9]+\\)D\\)?T"
                         "\\(?:\\([0-9]+\\)H\\)?"
                         "\\(?:\\([0-9]+\\)M\\)?"
                         "\\(?:\\([0-9.]+\\)S\\)?\\'")
                 duration)))
      duration
    (let ((values (list (match-string 1 duration)
                        (match-string 2 duration)
                        (match-string 3 duration)
                        (match-string 4 duration)))
          (suffixes '("d" "h" "m" "s"))
          parts)
      (cl-mapc (lambda (value suffix)
                 (when value (push (concat value suffix) parts)))
               values suffixes)
      (if parts (string-join (nreverse parts) " ") duration))))

(defun teams4e--humanize-event-type (type)
  "Turn Graph event TYPE camel case into a readable label."
  (let ((case-fold-search nil))
    (capitalize
     (replace-regexp-in-string
      "\\([[:lower:][:digit:]]\\)\\([[:upper:]]\\)" "\\1 \\2"
      (or type "System event")))))

(defun teams4e--event-summary (message)
  "Return a useful human-readable summary for a system MESSAGE."
  (let* ((detail (teams4e--get message 'eventDetail))
         (type (teams4e--event-detail-type message))
         (call-kind
          (pcase (teams4e--get detail 'callEventType)
            ("meeting" "Meeting")
            ("screenShare" "Screen share")
            (_ "Call")))
         (initiator
          (teams4e--event-identity-name
           (teams4e--get detail 'initiator)))
         (members (teams4e--event-member-names detail))
         (base
          (pcase type
            ("callStarted" (format "%s started" call-kind))
            ("callEnded" (format "%s ended" call-kind))
            ("callRecording" (format "%s recording available" call-kind))
            ("callTranscript" (format "%s transcript available" call-kind))
            ("chatRenamed" "Chat renamed")
            ("channelRenamed" "Channel renamed")
            ("teamRenamed" "Team renamed")
            ("membersAdded" "Members added")
            ("membersDeleted" "Members removed")
            ("membersJoined" "Members joined")
            ("membersLeft" "Members left")
            ("messagePinned" "Message pinned")
            ("messageUnpinned" "Message unpinned")
            (_ (teams4e--humanize-event-type type)))))
    (concat
     base
     (cond
      ((and members (member type '("membersAdded" "membersDeleted"
                                   "membersJoined" "membersLeft")))
       (format ": %s" (string-join members ", ")))
      ((and initiator (member type '("callStarted" "chatRenamed"
                                     "channelRenamed" "teamRenamed")))
       (format " by %s" initiator))
      (t ""))
     (if-let ((duration (and (equal type "callEnded")
                             (teams4e--get detail 'callDuration))))
         (format " (%s)" (teams4e--format-duration duration))
       "")
     (cond
      ((and (equal type "chatRenamed")
            (teams4e--get detail 'chatDisplayName))
       (format ": %s" (teams4e--get detail 'chatDisplayName)))
      ((and (equal type "channelRenamed")
            (teams4e--get detail 'channelDisplayName))
       (format ": %s" (teams4e--get detail 'channelDisplayName)))
      ((and (equal type "teamRenamed")
            (teams4e--get detail 'teamDisplayName))
       (format ": %s" (teams4e--get detail 'teamDisplayName)))
      (t "")))))

(defun teams4e--system-event-p (message)
  "Return non-nil when MESSAGE represents a Teams system event."
  (or (equal (teams4e--get message 'messageType) "systemEventMessage")
      (teams4e--get message 'eventDetail)
      (equal (teams4e--dig message 'body 'content)
             "<systemEventMessage/>")))

(defun teams4e--message-body (message)
  "Return a readable body for Teams MESSAGE."
  (let ((content (teams4e--dig message 'body 'content)))
    (cond
     ((teams4e--get message 'deletedDateTime) "[Deleted message]")
     ((teams4e--system-event-p message)
      (teams4e--event-summary message))
     ((and (stringp content) (not (string-empty-p content)))
      (teams4e--html-to-text content))
     ((teams4e--get message 'subject))
     ((teams4e--get message 'summary))
     (t ""))))

(defun teams4e--message-sender (message)
  "Return a useful sender label for Teams MESSAGE."
  (or (teams4e--dig message 'from 'user 'displayName)
      (teams4e--dig message 'from 'application 'displayName)
      "Teams"))

(defun teams4e--chat-id (chat)
  "Return CHAT's identifier."
  (unless (and (listp chat) (keywordp (car chat)))
    (teams4e--get chat 'id)))

(defun teams4e--short-id (chat)
  "Return a stable short identifier for CHAT."
  (substring (md5 (or (teams4e--chat-id chat) "unknown")) 0 8))

(defun teams4e--load-state ()
  "Load non-secret local Teams UI state once per Emacs session."
  (unless teams4e--state-loaded
    (setq teams4e--state-loaded t
          teams4e--favorites (make-hash-table :test #'equal)
          teams4e--muted (make-hash-table :test #'equal)
          teams4e--handled (make-hash-table :test #'equal)
          teams4e--snoozed (make-hash-table :test #'equal)
          teams4e--saved-views (make-hash-table :test #'equal))
    (when (file-readable-p teams4e-state-file)
      (condition-case error-data
          (let* ((payload
                  (json-parse-string
                   (with-temp-buffer
                     (insert-file-contents teams4e-state-file)
                     (buffer-string))
                   :object-type 'alist :array-type 'list))
                 (favorites (teams4e--get payload 'favorites))
                 (muted (teams4e--get payload 'muted))
                 (handled (teams4e--get payload 'handled))
                 (snoozed (teams4e--get payload 'snoozed))
                 (saved-views (teams4e--get payload 'savedViews)))
            (dolist (chat-id favorites)
              (when (stringp chat-id)
                (puthash chat-id t teams4e--favorites)))
            (dolist (chat-id muted)
              (when (stringp chat-id)
                (puthash chat-id t teams4e--muted)))
            (dolist (item handled)
              (let ((chat-id (teams4e--get item 'chatId))
                    (marker (teams4e--get item 'marker)))
                (when (and (stringp chat-id) (stringp marker))
                  (puthash chat-id marker teams4e--handled))))
            (dolist (item snoozed)
              (let ((chat-id (teams4e--get item 'chatId))
                    (until (teams4e--get item 'until)))
                (when (and (stringp chat-id) (stringp until))
                  (puthash chat-id until teams4e--snoozed))))
            (dolist (view saved-views)
              (let ((name (or (teams4e--get view 'name)
                              (car-safe view)))
                    (query (or (teams4e--get view 'query)
                               (cdr-safe view))))
                (when (and (or (symbolp name) (stringp name))
                           (stringp query))
                  (puthash (if (symbolp name) (symbol-name name) name)
                           query teams4e--saved-views)))))
        (error
         (message "Ignoring invalid Teams state file: %s"
                  (error-message-string error-data)))))))

(defun teams4e--save-state ()
  "Persist local Teams UI state atomically with private permissions."
  (let* ((file (expand-file-name teams4e-state-file))
         (directory (file-name-directory file))
         favorites muted handled snoozed saved-views)
    (make-directory directory t)
    (let ((temporary
           (make-temp-file (expand-file-name ".teams-state-" directory))))
      (maphash (lambda (chat-id enabled)
                 (when enabled (push chat-id favorites)))
               teams4e--favorites)
      (maphash (lambda (chat-id enabled)
                 (when enabled (push chat-id muted)))
               teams4e--muted)
      (maphash (lambda (chat-id marker)
                 (when (and (stringp chat-id) (stringp marker))
                   (push `((chatId . ,chat-id) (marker . ,marker)) handled)))
               teams4e--handled)
      (maphash (lambda (chat-id until)
                 (when (and (stringp chat-id) (stringp until))
                   (push `((chatId . ,chat-id) (until . ,until)) snoozed)))
               teams4e--snoozed)
      (maphash (lambda (name query)
                 (push `((name . ,name) (query . ,query)) saved-views))
               teams4e--saved-views)
      (let ((record-less-p
             (lambda (left right)
               (string< (teams4e--get left 'chatId)
                        (teams4e--get right 'chatId))))
            (sorted-views
             (sort saved-views
                   (lambda (left right)
                     (string< (teams4e--get left 'name)
                              (teams4e--get right 'name))))))
        (unwind-protect
            (progn
              (with-temp-file temporary
                (insert
                 (json-serialize
                  `((favorites . ,(vconcat (sort favorites #'string<)))
                    (muted . ,(vconcat (sort muted #'string<)))
                    (handled . ,(vconcat (sort handled record-less-p)))
                    (snoozed . ,(vconcat (sort snoozed record-less-p)))
                    (savedViews . ,(vconcat sorted-views)))))
                (insert "\n"))
              (set-file-modes temporary #o600)
              (rename-file temporary file t))
          (when (file-exists-p temporary) (delete-file temporary)))))))

(defun teams4e--favorite-p (chat)
  "Return non-nil when CHAT is a local favorite."
  (teams4e--load-state)
  (gethash (teams4e--chat-id chat) teams4e--favorites))

(defun teams4e--server-suppressed-p (chat)
  "Return non-nil when Graph marks CHAT hidden or muted.

Microsoft Graph documents `viewpoint.isHidden'.  The `isMuted' checks are
best-effort compatibility with tenants that include a richer viewpoint."
  (or (teams4e--dig chat 'viewpoint 'isHidden)
      (teams4e--dig chat 'viewpoint 'isMuted)
      (teams4e--get chat 'isMuted)
      (teams4e--get chat 'isHiddenForAllMembers)))

(defun teams4e--muted-p (chat)
  "Return non-nil when CHAT is suppressed from the relevant inbox."
  (teams4e--load-state)
  (or (gethash (teams4e--chat-id chat) teams4e--muted)
      (teams4e--server-suppressed-p chat)))

(defun teams4e--chat-marker (chat)
  "Return CHAT's current stable marker for handled-until-new state."
  (or (teams4e--dig chat 'lastMessagePreview 'id)
      (teams4e--get chat 'lastUpdatedDateTime)
      (teams4e--chat-id chat)))

(defun teams4e--handled-p (chat)
  "Return non-nil when CHAT is handled and no newer message has appeared."
  (teams4e--load-state)
  (let ((stored (gethash (teams4e--chat-id chat)
                         teams4e--handled)))
    (and (stringp stored)
         (equal stored (teams4e--chat-marker chat)))))

(defun teams4e--snoozed-until (chat)
  "Return CHAT's active snooze expiry string, or nil when it has expired."
  (teams4e--load-state)
  (let ((until (gethash (teams4e--chat-id chat)
                        teams4e--snoozed)))
    (and (stringp until)
         (condition-case nil
             (time-less-p (current-time) (date-to-time until))
           (error nil))
         until)))

(defun teams4e--snoozed-p (chat)
  "Return non-nil when CHAT has an active local snooze."
  (not (null (teams4e--snoozed-until chat))))

(defun teams4e--triaged-p (chat)
  "Return non-nil when CHAT is locally handled or snoozed."
  (or (teams4e--handled-p chat)
      (teams4e--snoozed-p chat)))

(defun teams4e--last-message (chat)
  "Return CHAT's last message preview object."
  (teams4e--get chat 'lastMessagePreview))

(defun teams4e--last-message-date-time (chat)
  "Return CHAT's last-message timestamp, without using chat metadata time.

Calendar and membership changes can update a chat independently of message
activity.  Message-oriented views therefore use only the preview timestamp."
  (let ((message (teams4e--last-message chat)))
    (or (teams4e--get message 'createdDateTime)
        (teams4e--get message 'lastModifiedDateTime))))

(defun teams4e--mentioned-user-p (message)
  "Return non-nil when MESSAGE explicitly mentions the connected user."
  (seq-some
   (lambda (mention)
     (let ((user-id (teams4e--dig mention 'mentioned 'user 'id))
           (text (or (teams4e--get mention 'mentionText) "")))
       (or (and (stringp user-id)
                (stringp teams4e--connected-user-id)
                (equal user-id teams4e--connected-user-id))
           (and (stringp teams4e--connected-as)
                (string-match-p
                 (regexp-quote teams4e--connected-as) text)))))
   (teams4e--get message 'mentions)))

(defun teams4e--reply-to-own-p (message)
  "Return non-nil when MESSAGE quotes a message sent by the connected user."
  (when-let ((reference (teams4e--message-reference message)))
    (let ((sender-id (teams4e--dig reference 'messageSender 'user 'id))
          (sender-name
           (teams4e--dig reference 'messageSender 'user 'displayName)))
      (or (and (stringp sender-id)
               (stringp teams4e--connected-user-id)
               (equal sender-id teams4e--connected-user-id))
          (and (stringp sender-name)
               (stringp teams4e--connected-as)
               (string-equal sender-name teams4e--connected-as))))))

(defun teams4e--important-p (message)
  "Return non-nil when MESSAGE has high or urgent Graph importance."
  (member (downcase (or (teams4e--get message 'importance) "normal"))
          '("high" "urgent")))

(defun teams4e--attention-p (chat)
  "Return non-nil when CHAT has an unread, mention, reply, or priority signal."
  (let ((message (teams4e--last-message chat)))
    (or (teams4e--unread-p chat)
        (teams4e--mentioned-user-p message)
        (teams4e--reply-to-own-p message)
        (teams4e--important-p message))))

(defun teams4e--message-own-p (message)
  "Return non-nil when MESSAGE was sent by the connected account."
  (let ((sender-id (teams4e--dig message 'from 'user 'id))
        (sender-name (teams4e--message-sender message)))
    (or (and (stringp sender-id)
             (stringp teams4e--connected-user-id)
             (equal sender-id teams4e--connected-user-id))
        (and (stringp teams4e--connected-as)
             (stringp sender-name)
             (string-equal sender-name teams4e--connected-as)))))

(defun teams4e--chat-members (chat)
  "Return cached members for CHAT."
  (let ((members
         (gethash (teams4e--chat-id chat)
                  teams4e--member-cache)))
    (unless (eq members teams4e--no-members) members)))

(defun teams4e--member-names (chat)
  "Return names of CHAT members other than the connected account."
  (let* ((members (teams4e--chat-members chat))
         (connected-email (and teams4e--connected-as
                               (downcase teams4e--connected-as)))
         (connected-id teams4e--connected-user-id)
         (others
          (seq-filter
           (lambda (member)
             (let ((user-id (teams4e--get member 'userId))
                   (email (teams4e--get member 'email)))
               (not
                (or (and (stringp connected-id)
                         (stringp user-id)
                         (string-equal connected-id user-id))
                    (and (stringp connected-email)
                         (stringp email)
                         (string-equal connected-email
                                       (downcase email)))))))
           members))
         (selected (if (or (stringp connected-id)
                           (stringp connected-email))
                       others
                     members)))
    (delq nil
          (mapcar (lambda (member)
                    (or (teams4e--get member 'displayName)
                        (teams4e--get member 'email)))
                  selected))))

(defun teams4e--meeting-chat-p (chat)
  "Return non-nil when CHAT represents a Teams meeting conversation."
  (equal (teams4e--get chat 'chatType) "meeting"))

(defun teams4e--meeting-context-args (chat)
  "Return backend arguments used to resolve metadata for meeting CHAT."
  (list "teams" "meeting" "context"
        "--chatId" (teams4e--chat-id chat)))

(defun teams4e--apply-meeting-context (chat context)
  "Attach CONTEXT to meeting CHAT and update its member cache."
  (let* ((cell (assq 'meetingContext chat))
         (existing (and cell (cdr cell)))
         (target (or existing context)))
    (when existing
      (dolist (entry context)
        (if-let ((old (assq (car entry) existing)))
            (setcdr old (cdr entry))
          (push (cons (car entry) (cdr entry)) existing)))
      (setq target existing))
    (if cell
        (setcdr cell target)
      ;; CHAT is shared with the inbox.  Add the new key destructively so the
      ;; reader and capture callbacks see it through their existing reference.
      (setcdr chat (cons (cons 'meetingContext target) (cdr chat)))))
  (when (teams4e--get context 'membersLoaded)
    (let ((members (teams4e--get context 'members)))
      (puthash (teams4e--chat-id chat)
               (or members teams4e--no-members)
               teams4e--member-cache)))
  (teams4e--get chat 'meetingContext))

(defun teams4e--fetch-meeting-context
    (chat callback &optional error-callback)
  "Fetch meeting CHAT metadata, then invoke CALLBACK with its context.

The context combines calendar start/end data and chat participants.  Calendar
permission failures are returned by the backend as `eventError' while member
data remains usable.  ERROR-CALLBACK handles failures of the whole operation."
  (if (or (not (teams4e--meeting-chat-p chat))
          teams4e-offline-mode)
      (progn
        (funcall callback (teams4e--get chat 'meetingContext))
        nil)
    (teams4e--run-json
     (teams4e--meeting-context-args chat)
     (lambda (context)
       (teams4e--apply-meeting-context chat context)
       (funcall callback context))
     error-callback)))

(defun teams4e--meeting-members (chat)
  "Return all known member records for meeting CHAT."
  (or (teams4e--get (teams4e--get chat 'meetingContext) 'members)
      (teams4e--chat-members chat)))

(defun teams4e--meeting-participant-names (chat)
  "Return de-duplicated participant names for meeting CHAT."
  (let* ((context (teams4e--get chat 'meetingContext))
         (event (teams4e--get context 'event))
         (members
          (delq nil
                (mapcar
                 (lambda (member)
                   (or (teams4e--get member 'displayName)
                       (teams4e--get member 'email)))
                 (teams4e--meeting-members chat))))
         (organizer
          (or (teams4e--dig event 'organizer 'emailAddress 'name)
              (teams4e--dig context
                             'onlineMeetingInfo 'organizer 'user 'displayName)
              (teams4e--dig chat
                             'onlineMeetingInfo 'organizer 'user 'displayName)
              (teams4e--dig chat 'onlineMeetingInfo 'organizer 'displayName)))
         (attendees
          (delq nil
                (mapcar
                 (lambda (attendee)
                   (teams4e--dig attendee 'emailAddress 'name))
                 (teams4e--get event 'attendees)))))
    (seq-uniq (append members (and organizer (list organizer)) attendees)
              #'string-equal)))

(defun teams4e--chat-label (chat)
  "Return the best available human-readable label for CHAT."
  (let ((topic (teams4e--get chat 'topic))
        (members (teams4e--member-names chat)))
    (cond
     ((and (stringp topic) (not (string-empty-p (string-trim topic))))
      (string-trim topic))
     (members (string-join members ", "))
     ((equal (teams4e--get chat 'chatType) "meeting") "Meeting chat")
     ((equal (teams4e--get chat 'chatType) "group") "Group chat")
     (t "One-to-one chat"))))

(defun teams4e--chat-type-key (chat)
  "Return a normalized display type symbol for CHAT."
  (pcase (teams4e--get chat 'chatType)
    ("oneOnOne" 'direct)
    ("group" 'group)
    ("meeting" 'meeting)
    ("channel" 'channel)
    (_ (if (teams4e--get chat 'channelIdentity) 'channel 'other))))

(defun teams4e--chat-type-label (chat)
  "Return a compact aligned type label for CHAT."
  (pcase (teams4e--chat-type-key chat)
    ('direct "Direct")
    ('group "Group")
    ('meeting "Meeting")
    ('channel "Channel")
    (_ "Other")))

(defun teams4e--chat-type-face (chat)
  "Return the semantic face used for CHAT's type label."
  (pcase (teams4e--chat-type-key chat)
    ('direct 'teams4e-type-direct)
    ('group 'teams4e-type-group)
    ('meeting 'teams4e-type-meeting)
    ('channel 'teams4e-type-channel)))

(defun teams4e--row-face (unread &optional additional-face)
  "Combine UNREAD emphasis with ADDITIONAL-FACE."
  (delq nil (list (and unread 'teams4e-unread) additional-face)))

(defun teams4e--chat-preview (chat)
  "Return a compact sender and message preview for CHAT."
  (let* ((preview (teams4e--get chat 'lastMessagePreview))
         (sender (and preview (teams4e--message-sender preview)))
         (body (and preview (teams4e--message-body preview)))
         (body (and body (replace-regexp-in-string "[\n\r\t ]+" " " body))))
    (cond
     ((and (stringp body) (not (string-empty-p body)))
      (truncate-string-to-width
       (if (and sender (not (equal sender "Teams")))
           (format "%s: %s" sender body)
         body)
       72 nil nil "..."))
     (t ""))))

(defun teams4e--chat-choice (chat)
  "Return a unique completion candidate for CHAT."
  (format "%s  [%s]  %s"
          (teams4e--chat-label chat)
          (teams4e--short-id chat)
          (teams4e--format-date
           (teams4e--get chat 'lastUpdatedDateTime))))

(defun teams4e--chat-updated-p (left right)
  "Return non-nil when LEFT's last message is newer than RIGHT's.

Rows without a message sort after rows with one.  Chat ids break equal-time
ties so asynchronous enrichment cannot make rows jump unpredictably."
  (let ((left-time (teams4e--last-message-date-time left))
        (right-time (teams4e--last-message-date-time right)))
    (cond
     ((and left-time right-time)
      (if (equal left-time right-time)
          (string< (teams4e--chat-id left) (teams4e--chat-id right))
        (string> left-time right-time)))
     (left-time t)
     (right-time nil)
     (t (string< (teams4e--chat-id left) (teams4e--chat-id right))))))

(defun teams4e--parse-message-time (value)
  "Parse Graph timestamp VALUE without discarding fractional seconds."
  (when (stringp value)
    (condition-case nil
        (if (string-match
             (concat "\\`\\(.*T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]\\)"
                     "\\.\\([0-9]+\\)"
                     "\\([zZ]\\|[+-][0-9][0-9]:[0-9][0-9]\\)\\'")
             value)
            (let ((base (concat (match-string 1 value)
                                (match-string 3 value)))
                  (fraction (match-string 2 value)))
              (time-add
               (date-to-time base)
               (seconds-to-time
                (string-to-number (concat "0." fraction)))))
          (date-to-time value))
      (error nil))))

(defun teams4e--message-older-p (left right)
  "Return non-nil when LEFT was created before RIGHT.

Compare absolute instants rather than timestamp text, then use the Graph
message ID as a deterministic tie-breaker."
  (let* ((left-value (or (teams4e--get left 'createdDateTime) ""))
         (right-value (or (teams4e--get right 'createdDateTime) ""))
         (left-time (teams4e--parse-message-time left-value))
         (right-time (teams4e--parse-message-time right-value))
         (left-id (or (teams4e--get left 'id) ""))
         (right-id (or (teams4e--get right 'id) "")))
    (cond
     ((and left-time right-time)
      (or (time-less-p left-time right-time)
          (and (time-equal-p left-time right-time)
               (string< left-id right-id))))
     (left-time t)
     (right-time nil)
     ((not (equal left-value right-value))
      (string< left-value right-value))
     (t (string< left-id right-id)))))

(defun teams4e--normalize-messages (messages)
  "Return MESSAGES chronological and deduplicated by Graph message ID."
  (let ((seen (make-hash-table :test #'equal))
        unique)
    (dolist (message messages)
      (let ((id (teams4e--get message 'id)))
        (when (or (not (stringp id))
                  (not (gethash id seen)))
          (when (stringp id) (puthash id t seen))
          (push message unique))))
    (sort (nreverse unique) #'teams4e--message-older-p)))

(defun teams4e--effective-message-order ()
  "Return the effective visual order for the current transcript buffer."
  (if (memq teams4e--message-order '(oldest-first newest-first))
      teams4e--message-order
    teams4e-message-order))

(defun teams4e--messages-for-display (messages)
  "Return MESSAGES in the current transcript's visual order.

The canonical list is never mutated because export and capture require
chronological input."
  (if (eq (teams4e--effective-message-order) 'newest-first)
      (reverse (copy-sequence messages))
    messages))

(defun teams4e--message-order-label ()
  "Return a concise label for the current transcript's visual order."
  (if (eq (teams4e--effective-message-order) 'newest-first)
      "newest first"
    "oldest first"))

(defun teams4e-toggle-message-order ()
  "Toggle visual message order in the current chat or channel transcript."
  (interactive)
  (unless (or (derived-mode-p 'teams4e-chat-mode)
              (derived-mode-p 'teams4e-channel-thread-mode))
    (user-error "Open a Teams transcript first"))
  (setq-local
   teams4e--message-order
   (if (eq (teams4e--effective-message-order) 'oldest-first)
       'newest-first
     'oldest-first))
  (if (derived-mode-p 'teams4e-chat-mode)
      (teams4e--render-chat)
    (teams4e--render-channel-thread))
  (message "Teams transcript order: %s"
           (teams4e--message-order-label)))

(defun teams4e--unread-p (chat)
  "Return non-nil when CHAT appears newer than its read marker."
  (let* ((chat-id (teams4e--chat-id chat))
         (override (gethash chat-id teams4e--read-overrides))
         (updated (teams4e--get chat 'lastUpdatedDateTime))
         (read (teams4e--dig chat 'viewpoint 'lastMessageReadDateTime)))
    (when (and override (not (equal (cdr override) updated)))
      (remhash chat-id teams4e--read-overrides)
      (setq override nil))
    (pcase (car-safe override)
      ('read nil)
      ('unread t)
      (_ (and (stringp updated)
              (or (not (stringp read)) (string< read updated)))))))

(defun teams4e--status-request (callback &optional error-callback)
  "Fetch shared OAuth status and invoke CALLBACK with it.

ERROR-CALLBACK, when non-nil, handles backend failures."
  (teams4e--run-json
   '("status")
   (lambda (status)
     (setq teams4e--connected-as
           (and (listp status) (teams4e--get status 'connectedAs))
           teams4e--connected-user-id
           (and (listp status) (teams4e--get status 'userId)))
     (funcall callback status))
   error-callback))

(defun teams4e--with-status (callback)
  "Invoke CALLBACK after ensuring shared M365 credentials are present."
  (if (or teams4e-offline-mode teams4e--connected-as)
      (funcall callback)
    (teams4e--status-request
     (lambda (_status)
       (if teams4e--connected-as
           (funcall callback)
         (message "Shared M365 OAuth is unavailable; run M-x teams4e-login"))))))

(defun teams4e--require-online ()
  "Reject a server mutation while cache-only mode is active."
  (when teams4e-offline-mode
    (user-error "Teams is in offline cache mode; toggle it off to mutate server state")))

;;;###autoload
(defun teams4e-status ()
  "Show the Microsoft Graph token-provider status used by Teams."
  (interactive)
  (teams4e--status-request
   (lambda (status)
     (let ((buffer (get-buffer-create "*M365 Status*")))
       (with-current-buffer buffer
         (let ((inhibit-read-only t))
           (erase-buffer)
           (if (stringp status)
               (insert (format "Status: %s\n\nRun M-x teams4e-login to connect.\n"
                               status))
             (insert (format "Connection: %s\n"
                             (or (teams4e--get status 'connectionName) "default")))
             (insert (format "Account:    %s\n"
                             (or (teams4e--get status 'connectedAs) "unknown")))
             (insert (format "Auth type:  %s\n"
                             (or (teams4e--get status 'authType) "unknown")))
             (insert (format "Tenant:     %s\n"
                             (or (teams4e--get status 'appTenant) "unknown")))
             (insert (format "Graph token: %s\n"
                             (or (teams4e--get status 'graphTokenStatus)
                                 "unknown")))
             (if (equal (teams4e--get status 'authType) "MockTenant")
                 (insert (format "Mock state: %s\n"
                                 (or (teams4e--get status 'mockStateFile)
                                     "unknown")))
               (insert (format "Credentials: %s\n"
                               (or (teams4e--get status 'credentialFile)
                                   "unknown")))))
           (special-mode)))
       (pop-to-buffer buffer)))))

;;;###autoload
(defun teams4e-login ()
  "Run the configured Graph credential bootstrap in a comint buffer."
  (interactive)
  (let* ((program (teams4e--executable))
         (buffer (get-buffer-create "*M365 Login*"))
         (args '("login"))
         (process-environment (copy-sequence process-environment)))
    (teams4e--configure-process-environment)
    (setenv "PATH" (concat (file-name-directory program) path-separator
                            (or (getenv "PATH") "")))
    (when-let ((old-process (get-buffer-process buffer)))
      (unless (yes-or-no-p "Replace the active m365 login process? ")
        (user-error "Login left running"))
      (delete-process old-process))
    (with-current-buffer buffer
      (let ((inhibit-read-only t)) (erase-buffer)))
    (apply #'make-comint-in-buffer "M365 Login" buffer program nil args)
    (setq teams4e--connected-as nil)
    (pop-to-buffer buffer)))

;;;###autoload
(defun teams4e-logout ()
  "Explain why teams4e cannot log out an externally owned OAuth identity."
  (interactive)
  (user-error
   (concat "teams4e consumes an external token provider and does not own "
           "its OAuth session; log out through that provider")))

(defun teams4e--chat-list-args ()
  "Return backend arguments for one bounded native inbox refresh."
  (if teams4e-offline-mode
      '("teams" "cache" "chat" "list")
    (list "teams" "chat" "list"
          "--metadataLimit"
          (number-to-string (max 1 teams4e-chat-metadata-limit)))))

(defun teams4e--normalize-chats (payload)
  "Normalize chat PAYLOAD, update member hints, and return sorted chats."
  (let ((chats (teams4e--payload-list payload)))
    (dolist (chat chats)
      (when (teams4e--get chat 'membersLoaded)
        (let ((members (teams4e--get chat 'members)))
          (puthash (teams4e--chat-id chat)
                   (or members teams4e--no-members)
                   teams4e--member-cache))))
    (sort chats #'teams4e--chat-updated-p)))

(defun teams4e--load-chats (callback &optional error-callback args)
  "Load recent Teams chats and invoke CALLBACK with the sorted result.

ERROR-CALLBACK receives backend status and detail.  Optional ARGS overrides the
normal online/offline command, principally for cache-first inbox opening."
  (teams4e--run-json
   (or args (teams4e--chat-list-args))
   (lambda (payload)
     (setq teams4e--chats (teams4e--normalize-chats payload))
     (funcall callback teams4e--chats))
   error-callback))

(defun teams4e--inbox-source-suffix ()
  "Return the transient cache/refresh label for the current inbox buffer."
  (if (and (stringp teams4e--inbox-source-label)
           (not (string-empty-p teams4e--inbox-source-label)))
      (concat " - " teams4e--inbox-source-label)
    ""))

(defun teams4e--recent-buffer ()
  "Return the recent-chat buffer when it is live."
  (get-buffer teams4e--recent-buffer-name))

(defun teams4e--tabulated-goto-id (id)
  "Move point to tabulated-list row ID and return non-nil when found."
  (when id
    (goto-char (point-min))
    (while (and (not (equal id (tabulated-list-get-id)))
                (not (eobp)))
      (forward-line 1))
    (when (equal id (tabulated-list-get-id))
      (beginning-of-line)
      t)))

(defun teams4e--tabulated-goto-first-id ()
  "Move point to the first tabulated-list row and return its ID."
  (goto-char (point-min))
  (while (and (not (tabulated-list-get-id)) (not (eobp)))
    (forward-line 1))
  (when-let ((id (tabulated-list-get-id)))
    (beginning-of-line)
    id))

(defun teams4e--recent-index-window ()
  "Return a visible window showing the current Teams headers buffer."
  (and (derived-mode-p 'teams4e-recent-mode)
       (get-buffer-window (current-buffer) t)))

(defun teams4e--recent-selected-id ()
  "Return the chat ID selected in the visible headers window."
  (if-let ((window (teams4e--recent-index-window)))
      (with-selected-window window (tabulated-list-get-id))
    (tabulated-list-get-id)))

(defun teams4e--recent-restore-selection (chat-id)
  "Restore CHAT-ID in the visible headers window, falling back to its first row."
  (let ((restore
         (lambda ()
           (unless (and chat-id
                        (teams4e--tabulated-goto-id chat-id))
             (teams4e--tabulated-goto-first-id)))))
    (if-let ((window (teams4e--recent-index-window)))
        (with-selected-window window (funcall restore))
      (funcall restore))))

(defun teams4e--visible-chat-reader-window ()
  "Return the chat reader beside the current visible headers window."
  (when-let* ((index-window (teams4e--recent-index-window))
              (reader (get-buffer teams4e--read-buffer-name))
              (reader-window
               (get-buffer-window reader (window-frame index-window))))
    (when (with-current-buffer reader
            (derived-mode-p 'teams4e-chat-mode))
      reader-window)))

(defun teams4e--cancel-preview-timer ()
  "Cancel the current headers buffer's pending transcript preview."
  (when (timerp teams4e--preview-timer)
    (cancel-timer teams4e--preview-timer))
  (setq teams4e--preview-timer nil))

(defun teams4e--clear-chat-reader (reader)
  "Clear stale conversation state from visible chat READER."
  (with-current-buffer reader
    (teams4e--cancel-buffer-process)
    (setq teams4e--chat nil
          teams4e--messages nil
          teams4e--loaded-at nil
          teams4e--loaded-update nil
          teams4e--loaded-all nil
          teams4e--pending-message-id nil
          teams4e--meeting-context nil
          teams4e--automatic-preview-p nil
          header-line-format "No Teams chat selected")
    (let ((inhibit-read-only t))
      (erase-buffer)
      (insert "No chats match the current inbox view.\n"))))

(defun teams4e--sync-visible-chat-reader ()
  "Make an existing chat reader match the visible headers selection.

Return non-nil when a linked reader exists, even when it already matches."
  (unless teams4e--inhibit-reader-follow
    (when-let ((reader-window (teams4e--visible-chat-reader-window)))
      (let* ((reader (window-buffer reader-window))
             (selected-id (teams4e--recent-selected-id))
             (reader-id
              (with-current-buffer reader
                (and teams4e--chat
                     (teams4e--chat-id teams4e--chat)))))
        (cond
         ((not selected-id)
          (when reader-id (teams4e--clear-chat-reader reader)))
         ((not (equal selected-id reader-id))
          (when-let ((chat (teams4e--find-chat selected-id)))
            (save-selected-window
              (teams4e-open-chat chat t)))))
        t))))

(defun teams4e--follow-selected-chat ()
  "Keep a visible reader synchronized, or schedule an opt-in first preview."
  (unless teams4e--inhibit-reader-follow
    (if (teams4e--sync-visible-chat-reader)
        (teams4e--cancel-preview-timer)
      (teams4e--schedule-preview))))

(defun teams4e--meeting-column-visible-p ()
  "Return non-nil when the active headers view is meeting-only."
  (and (fboundp 'teams4e--meeting-view-p)
       (teams4e--meeting-view-p)))

(defun teams4e--current-recent-format ()
  "Return the headers format appropriate for the active Teams view."
  (if (teams4e--meeting-column-visible-p)
      teams4e--meeting-recent-format
    teams4e--recent-format))

(defun teams4e--recent-columns (chat status)
  "Build the view-sensitive headers columns for CHAT with STATUS."
  (let* ((unread (teams4e--unread-p chat))
         (face (teams4e--row-face unread))
         (type-face
          (teams4e--row-face
           unread (teams4e--chat-type-face chat)))
         (date
          (propertize
           (teams4e--format-date
            (teams4e--last-message-date-time chat) t)
           'face face))
         (type (propertize (teams4e--chat-type-label chat) 'face type-face))
         (label (propertize (teams4e--chat-label chat) 'face face))
         (star (if (teams4e--favorite-p chat) "*" ""))
         (preview (propertize (teams4e--chat-preview chat) 'face face)))
    (if (teams4e--meeting-column-visible-p)
        (vector status date type label
                (propertize (or (teams4e--meeting-row-label chat) "")
                            'face face)
                star preview)
      (vector status date type label star preview))))

(defun teams4e--recent-entry (chat)
  "Build one tabulated-list entry for CHAT."
  (list (teams4e--chat-id chat)
        (teams4e--recent-columns chat "")))

(defun teams4e--configure-recent-format ()
  "Install the current Teams inbox columns, including after a live reload."
  (let ((format (teams4e--current-recent-format)))
    (unless (equal tabulated-list-format format)
      (setq tabulated-list-format (copy-sequence format))
      (tabulated-list-init-header))))

(defun teams4e--render-recent ()
  "Render cached chats in the current recent-chat buffer."
  (let ((selected (teams4e--recent-selected-id))
        (unread-count (seq-count #'teams4e--unread-p
                                 teams4e--chats)))
    (teams4e--configure-recent-format)
    (setq tabulated-list-entries
          (mapcar #'teams4e--recent-entry teams4e--chats)
          header-line-format
          (format "Teams inbox - %d unread%s%s"
                  unread-count
                  (if teams4e--connected-as
                      (format " - %s" teams4e--connected-as)
                    "")
                  (teams4e--inbox-source-suffix)))
    (tabulated-list-print t)
    (teams4e--recent-restore-selection selected)
    (teams4e--follow-selected-chat)))

(defun teams4e--refresh-visible-recent ()
  "Refresh the recent-chat buffer after cached labels change."
  (when-let ((buffer (teams4e--recent-buffer)))
    (with-current-buffer buffer
      (when (derived-mode-p 'teams4e-recent-mode)
        (teams4e--render-recent)))))

(defun teams4e--enrich-members (chats)
  "Resolve names for bounded unnamed CHATS in one asynchronous backend batch."
  (let* ((limit (max 0 teams4e-member-enrichment-limit))
         (selected
          (seq-take
           (seq-filter
            (lambda (chat)
              (let ((id (teams4e--chat-id chat))
                    (topic (teams4e--get chat 'topic)))
                (and id
                     (not (and (stringp topic)
                               (not (string-empty-p (string-trim topic)))))
                     (not (gethash id teams4e--member-cache))
                     (not (gethash id teams4e--member-inflight)))))
            chats)
           limit))
         (ids (mapcar #'teams4e--chat-id selected)))
    (when (and ids (not teams4e-offline-mode))
      (dolist (id ids) (puthash id t teams4e--member-inflight))
      (let ((args
             (append
              (list "teams" "chat" "member" "batch"
                    "--memberConcurrency"
                    (number-to-string
                     (max 1 teams4e-member-enrichment-concurrency)))
              (apply #'append
                     (mapcar (lambda (id) (list "--chatId" id)) ids)))))
        (teams4e--run-json
         args
         (lambda (payload)
           (dolist (record (teams4e--payload-list payload))
             (let ((id (teams4e--get record 'chatId)))
               (when id
                 (remhash id teams4e--member-inflight)
                 (when (teams4e--get record 'membersLoaded)
                   (let ((members (teams4e--get record 'members)))
                     (puthash id (or members teams4e--no-members)
                              teams4e--member-cache))))))
           (dolist (id ids) (remhash id teams4e--member-inflight))
           (teams4e--refresh-visible-recent))
         (lambda (_status _detail)
           ;; Member labels are optional; topic/type fallbacks remain usable.
           (dolist (id ids) (remhash id teams4e--member-inflight))))))))

(defun teams4e--meeting-event-id (chat)
  "Return CHAT's linked calendar event identifier, when available."
  (teams4e--dig chat 'onlineMeetingInfo 'calendarEventId))

(defun teams4e--meeting-event-batch-args (chats)
  "Return one backend request for the linked calendar events of CHATS."
  (list
   "teams" "meeting" "event" "batch"
   "--meetings"
   (json-encode
    (mapcar
     (lambda (chat)
       `((chatId . ,(teams4e--chat-id chat))
         (eventId . ,(teams4e--meeting-event-id chat))))
     chats))
   "--meetingConcurrency"
   (number-to-string
    (max 1 teams4e-meeting-enrichment-concurrency))))

(defun teams4e--enrich-meetings (chats)
  "Resolve linked calendar events for a bounded subset of meeting CHATS.

Results are merged into the existing chat alists.  The inbox therefore has
one conversation representation even while meeting metadata arrives later."
  (let* ((limit (max 0 teams4e-meeting-enrichment-limit))
         (selected
          (seq-take
           (seq-filter
            (lambda (chat)
              (let* ((id (teams4e--chat-id chat))
                     (context (teams4e--get chat 'meetingContext)))
                (and id
                     (teams4e--meeting-chat-p chat)
                     (teams4e--meeting-event-id chat)
                     (not (teams4e--get context 'event))
                     (not (teams4e--get context 'eventError))
                     (not (gethash id teams4e--meeting-inflight)))))
            chats)
           limit))
         (ids (mapcar #'teams4e--chat-id selected)))
    (when (and ids (not teams4e-offline-mode))
      (dolist (id ids) (puthash id t teams4e--meeting-inflight))
      (let ((args (teams4e--meeting-event-batch-args selected)))
        (teams4e--run-json
         args
         (lambda (payload)
           (dolist (record (teams4e--payload-list payload))
             (when-let* ((id (teams4e--get record 'chatId))
                         (chat (teams4e--find-chat id)))
               (remhash id teams4e--meeting-inflight)
               (teams4e--apply-meeting-context chat record)))
           (dolist (id ids) (remhash id teams4e--meeting-inflight))
           (teams4e--refresh-visible-recent))
         (lambda (_status _detail)
           ;; Calendar permission is optional; chat and member data stay useful.
           (dolist (id ids)
             (remhash id teams4e--meeting-inflight))))))))

(defvar teams4e-recent-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map tabulated-list-mode-map)
    (define-key map (kbd "RET") #'teams4e-recent-open)
    (define-key map (kbd "l") #'teams4e-recent-open)
    (define-key map (kbd "y") #'teams4e-select-preview)
    (define-key map (kbd "j") #'teams4e-recent-next)
    (define-key map (kbd "n") #'teams4e-recent-next)
    (define-key map (kbd "k") #'teams4e-recent-previous)
    (define-key map (kbd "p") #'teams4e-recent-previous)
    (define-key map (kbd "]") #'teams4e-recent-next-unread)
    (define-key map (kbd "[") #'teams4e-recent-previous-unread)
    (define-key map (kbd "g") #'teams4e-recent-refresh)
    (define-key map (kbd "c") #'teams4e-send)
    (define-key map (kbd "i") #'teams4e-mark-read-later)
    (define-key map (kbd "C") #'teams4e-send)
    (define-key map (kbd "r") #'teams4e-mark-read-later)
    (define-key map (kbd "R") #'teams4e-reply)
    (define-key map (kbd "f") #'teams4e-message-forward)
    (define-key map (kbd "F") #'teams4e-message-forward)
    (define-key map (kbd "o") #'teams4e-open-in-browser)
    (define-key map (kbd "O") #'teams4e-open-in-app)
    (define-key map (kbd "*") #'teams4e-toggle-favorite)
    (define-key map (kbd "M-u") #'teams4e-mark-unread)
    (define-key map (kbd "I") #'teams4e-mark-read-later)
    (define-key map (kbd "M") #'teams4e-toggle-selection)
    (define-key map (kbd "T") #'teams4e-toggle-visible-selections)
    (define-key map (kbd "X") #'teams4e-bulk-action)
    (define-key map (kbd "E") #'teams4e-export-thread)
    (define-key map (kbd "Y") #'teams4e-copy-thread-markdown)
    (define-key map (kbd "J") #'teams4e-preview-scroll-down)
    (define-key map (kbd "K") #'teams4e-preview-scroll-up)
    (define-key map (kbd "C-+") #'teams4e-index-grow)
    (define-key map (kbd "C-=") #'teams4e-index-grow)
    (define-key map (kbd "C--") #'teams4e-index-shrink)
    (define-key map (kbd "q") #'teams4e-quit)
    map)
  "Keymap for `teams4e-recent-mode'.")

(define-derived-mode teams4e-recent-mode tabulated-list-mode "Teams-Recent"
  "Major mode for recent Microsoft Teams chats."
  (setq tabulated-list-format
        (copy-sequence (teams4e--current-recent-format)))
  (setq tabulated-list-padding 1
        tabulated-list-sort-key nil)
  (add-hook 'kill-buffer-hook #'teams4e--cancel-buffer-process nil t)
  (add-hook 'post-command-hook #'teams4e--follow-selected-chat nil t)
  (tabulated-list-init-header))

;;;###autoload
(defun teams4e--start-live-inbox-refresh (buffer cached-shown)
  "Refresh BUFFER from Graph, retaining cached rows when CACHED-SHOWN is set."
  (teams4e--with-status
   (lambda ()
     (when (buffer-live-p buffer)
       (with-current-buffer buffer
         (setq teams4e--inbox-source-label
               (and cached-shown "cached, refreshing"))
         (when cached-shown (teams4e--render-recent))
         (teams4e--cancel-process teams4e--process)
         (setq
          teams4e--process
          (teams4e--load-chats
           (lambda (chats)
             (when (buffer-live-p buffer)
               (with-current-buffer buffer
                 (setq teams4e--process nil
                       teams4e--inbox-source-label nil)
                 (teams4e--render-recent)
                 (teams4e--schedule-preview)))
             (teams4e--enrich-members chats)
             (teams4e--enrich-meetings chats))
           (lambda (status detail)
             (when (buffer-live-p buffer)
               (with-current-buffer buffer
                 (setq teams4e--process nil
                       teams4e--inbox-source-label
                       (if cached-shown
                           "cached; live refresh failed"
                         "load failed - see *M365 Errors*"))
                 (if cached-shown
                     (teams4e--render-recent)
                   (setq header-line-format
                         "Teams inbox load failed - see *M365 Errors*"))))
             (teams4e--report-error
              (teams4e--chat-list-args) status detail)))))))))

(defun teams4e--start-cache-first-inbox-load (buffer)
  "Render BUFFER from the existing SQLite cache, then refresh it from Graph."
  (with-current-buffer buffer
    (teams4e--cancel-process teams4e--process)
    (setq teams4e--inbox-source-label "loading cache"
          teams4e--process
          (teams4e--run-json
           '("teams" "cache" "chat" "list")
           (lambda (payload)
             (let ((cached (teams4e--normalize-chats payload)))
               (when (buffer-live-p buffer)
                 (with-current-buffer buffer
                   (setq teams4e--process nil)
                   (when cached
                     (setq teams4e--chats cached
                           teams4e--inbox-source-label
                           "cached, refreshing")
                     (teams4e--render-recent)))
                 (teams4e--start-live-inbox-refresh
                  buffer (not (null cached))))))
           (lambda (_status _detail)
             ;; A missing or corrupt cache must not block a normal live inbox.
             (when (buffer-live-p buffer)
               (with-current-buffer buffer
                 (setq teams4e--process nil
                       teams4e--inbox-source-label nil))
               (teams4e--start-live-inbox-refresh buffer nil)))))))

;;;###autoload
(defun teams4e-recent ()
  "Open a native recent-chat inbox backed by Microsoft Graph."
  (interactive)
  (teams4e--load-state)
  (let* ((existing (get-buffer teams4e--recent-buffer-name))
         (buffer (get-buffer-create teams4e--recent-buffer-name)))
    (unless existing
      (teams4e--ensure-active-view)
      (setq teams4e--active-query nil
            teams4e--active-filter-name nil))
    (pop-to-buffer buffer)
    (unless (derived-mode-p 'teams4e-recent-mode)
      (teams4e-recent-mode))
    (setq header-line-format "Loading Teams chats..."
          teams4e--inbox-source-label nil)
    (cond
     (teams4e-offline-mode
      (with-current-buffer buffer
        (setq teams4e--process
              (teams4e--load-chats
               (lambda (_chats)
                 (when (buffer-live-p buffer)
                   (with-current-buffer buffer
                     (setq teams4e--process nil
                           teams4e--inbox-source-label "offline cache")
                     (teams4e--render-recent))))))))
     (teams4e-cache-first
      (teams4e--start-cache-first-inbox-load buffer))
     (t
      (teams4e--start-live-inbox-refresh buffer nil)))))

;;;###autoload
(defun teams4e-inbox ()
  "Open the Teams inbox, saving the current frame layout for `q'."
  (interactive)
  (unless (derived-mode-p 'teams4e-recent-mode
                          'teams4e-chat-mode
                          'teams4e-search-mode
                          'teams4e-channel-index-mode
                          'teams4e-channel-thread-mode)
    (puthash (selected-frame) (current-window-configuration)
             teams4e--window-configurations))
  (teams4e-recent)
  (delete-other-windows))

(defun teams4e--cancel-frame-preview-timers (frame)
  "Cancel pending Teams preview timers visible on FRAME."
  (dolist (window (window-list frame 'no-minibuf))
    (with-current-buffer (window-buffer window)
      (when (and (local-variable-p 'teams4e--preview-timer)
                 (timerp teams4e--preview-timer))
        (cancel-timer teams4e--preview-timer)
        (setq teams4e--preview-timer nil)))))

(defun teams4e-quit ()
  "Leave Teams without deleting the current Emacs frame."
  (interactive)
  (let* ((frame (selected-frame))
         (configuration (gethash frame teams4e--window-configurations)))
    (teams4e--cancel-frame-preview-timers frame)
    (remhash frame teams4e--window-configurations)
    (cond
     ((and (window-configuration-p configuration)
           (eq frame (window-configuration-frame configuration)))
      (set-window-configuration configuration))
     ((window-parent (selected-window))
      (quit-window t))
     (t
      (bury-buffer)))))

(defun teams4e--close-reader-to-index (index-buffer)
  "Close the selected Teams reader and return to INDEX-BUFFER.

This command deletes only the reader pane and buffer, never its Emacs frame."
  (let* ((reader-buffer (current-buffer))
         (reader-window (selected-window))
         (index-window
          (and (buffer-live-p index-buffer)
               (get-buffer-window index-buffer))))
    (cond
     ((and (window-live-p index-window)
           (not (eq reader-window index-window)))
      (when (window-parent reader-window)
        (delete-window reader-window))
      (when (buffer-live-p reader-buffer)
        (kill-buffer reader-buffer))
      (select-window index-window))
     ((buffer-live-p index-buffer)
      (switch-to-buffer index-buffer)
      (when (buffer-live-p reader-buffer)
        (kill-buffer reader-buffer)))
     (t
      (if (window-parent reader-window)
          (delete-window reader-window)
        (bury-buffer))
      (when (buffer-live-p reader-buffer)
        (kill-buffer reader-buffer))))))

(defun teams4e-chat-view-quit ()
  "Close the Teams chat reader pane and return to the chat headers."
  (interactive)
  (teams4e--close-reader-to-index
   (teams4e--recent-buffer)))

(defun teams4e-recent-refresh ()
  "Refresh the recent Teams chat inbox."
  (interactive)
  (teams4e-recent))

(defun teams4e--find-chat (id)
  "Return cached chat with ID."
  (seq-find (lambda (chat) (equal id (teams4e--chat-id chat)))
            teams4e--chats))

(defun teams4e--chat-at-point ()
  "Return the Teams chat represented at point or by the current buffer."
  (cond
   ((derived-mode-p 'teams4e-chat-mode) teams4e--chat)
   ((derived-mode-p 'teams4e-recent-mode)
    (or (teams4e--find-chat (tabulated-list-get-id))
        (user-error "No chat on this row")))
   (t nil)))

(defun teams4e-recent-open ()
  "Open the chat on the current recent-chat row."
  (interactive)
  (teams4e-open-chat (teams4e--chat-at-point)))

(defun teams4e--schedule-preview ()
  "Preview the selected inbox row after the configured idle delay."
  (teams4e--cancel-preview-timer)
  (when (and teams4e-preview-on-move (tabulated-list-get-id))
    (let ((buffer (current-buffer))
          (chat-id (tabulated-list-get-id)))
      (setq teams4e--preview-timer
            (run-with-idle-timer
             teams4e-preview-delay nil
             (lambda ()
               (when (buffer-live-p buffer)
                 (with-current-buffer buffer
                   (setq teams4e--preview-timer nil)
                   (when (equal chat-id (tabulated-list-get-id))
                     (when-let ((chat (teams4e--find-chat chat-id)))
                       (teams4e-open-chat chat t)))))))))))

(defun teams4e--recent-move (delta)
  "Move DELTA inbox rows and keep an existing reader synchronized."
  (let ((origin (point)))
    (forward-line delta)
    (beginning-of-line)
    (unless (tabulated-list-get-id)
      (goto-char origin))
    (teams4e--follow-selected-chat)))

(defun teams4e-recent-next ()
  "Move to the next chat without changing its server read state."
  (interactive)
  (teams4e--recent-move 1))

(defun teams4e-recent-previous ()
  "Move to the previous chat without changing its server read state."
  (interactive)
  (teams4e--recent-move -1))

(defun teams4e--recent-move-to (direction predicate description)
  "Move DIRECTION to the next chat matching PREDICATE.

DESCRIPTION names the match in user-facing errors."
  (let ((origin (point)) found finished)
    (while (not finished)
      (let ((before (point)))
        (forward-line direction)
        (if (= before (point))
            (setq finished t)
          (when-let* ((id (tabulated-list-get-id))
                      (chat (teams4e--find-chat id)))
            (when (funcall predicate chat)
              (setq found t finished t))))))
    (if found
        (progn
          (beginning-of-line)
          (teams4e--follow-selected-chat))
      (goto-char origin)
      (user-error "No %s chat in that direction" description))))

(defun teams4e-recent-next-unread ()
  "Move to the next unread chat, as `mu4e-headers-next-unread' does."
  (interactive)
  (teams4e--recent-move-to
   1 #'teams4e--unread-p "unread"))

(defun teams4e-recent-previous-unread ()
  "Move to the previous unread chat, as `mu4e-headers-prev-unread' does."
  (interactive)
  (teams4e--recent-move-to
   -1 #'teams4e--unread-p "unread"))

(defun teams4e--recent-goto-chat-id (chat-id)
  "Move the current Teams headers buffer to CHAT-ID and return non-nil."
  (teams4e--tabulated-goto-id chat-id))

(defun teams4e-chat-run-headers-command (&optional command)
  "Run the current key's Teams headers COMMAND from the chat reader.

The linked headers row is selected temporarily, as in mu4e view mode.  Reader
focus is retained, and a command that advances the headers replaces the one
singleton Teams reader with the newly selected chat."
  (interactive)
  (unless (derived-mode-p 'teams4e-chat-mode)
    (user-error "Open a Teams chat in the reader first"))
  (let* ((reader-buffer (current-buffer))
         (reader-window (selected-window))
         (chat-id (teams4e--chat-id teams4e--chat))
         (index-buffer (teams4e--recent-buffer))
         (index-window
          (and (buffer-live-p index-buffer)
               (get-buffer-window index-buffer)))
         (resolved
          (or command
              (lookup-key teams4e-recent-mode-map
                          (this-command-keys-vector))))
         selected-id)
    (unless (window-live-p index-window)
      (user-error "The Teams chat headers are not visible"))
    (unless (commandp resolved)
      (user-error "No Teams headers command for this key"))
    (with-selected-window index-window
      (with-current-buffer index-buffer
        (unless (teams4e--recent-goto-chat-id chat-id)
          (user-error "The open Teams chat is not in the current headers")))
      (let ((teams4e--inhibit-reader-follow t))
        (call-interactively resolved))
      (when (buffer-live-p index-buffer)
        (with-current-buffer index-buffer
          (when (derived-mode-p 'teams4e-recent-mode)
            (setq selected-id (tabulated-list-get-id))))))
    (when (and (buffer-live-p reader-buffer)
               (window-live-p reader-window)
               (eq (window-buffer reader-window) reader-buffer))
      (if (not selected-id)
          (teams4e--clear-chat-reader reader-buffer)
        (when (not (equal selected-id chat-id))
          (when-let ((chat (teams4e--find-chat selected-id)))
            (with-selected-window reader-window
              (teams4e-open-chat chat))))))))

(defun teams4e--preview-window ()
  "Return the visible native Teams chat transcript window, if any."
  (or (when-let ((buffer (get-buffer teams4e--read-buffer-name)))
        (get-buffer-window buffer t))
      (seq-find
       (lambda (window)
         (with-current-buffer (window-buffer window)
           (derived-mode-p 'teams4e-chat-mode)))
       (window-list nil 'nomini))))

(defun teams4e-select-preview ()
  "Select the transcript pane, matching mu4e's other-view command."
  (interactive)
  (if-let ((window (teams4e--preview-window)))
      (select-window window)
    (teams4e-recent-open)))

(defun teams4e--preview-scroll (direction)
  "Scroll the transcript pane in DIRECTION without selecting it."
  (let ((window (or (teams4e--preview-window)
                    (progn
                      (teams4e-open-chat
                       (teams4e--chat-at-point) t)
                      (teams4e--preview-window)))))
    (unless (window-live-p window)
      (user-error "No Teams transcript preview is visible"))
    (with-selected-window window
      (condition-case nil
          (if (> direction 0)
              (scroll-up-command)
            (scroll-down-command))
        ((beginning-of-buffer end-of-buffer) nil)))))

(defun teams4e-preview-scroll-down ()
  "Scroll the transcript forward, matching teams-tui-go's J action."
  (interactive)
  (teams4e--preview-scroll 1))

(defun teams4e-preview-scroll-up ()
  "Scroll the transcript backward, matching teams-tui-go's K action."
  (interactive)
  (teams4e--preview-scroll -1))

(defun teams4e--resize-index (columns)
  "Resize the Teams index window horizontally by COLUMNS."
  (unless (teams4e--preview-window)
    (user-error "Open a Teams transcript preview before resizing the index"))
  (window-resize (selected-window) columns t))

(defun teams4e-index-grow ()
  "Grow the Teams headers pane by five columns."
  (interactive)
  (teams4e--resize-index 5))

(defun teams4e-index-shrink ()
  "Shrink the Teams headers pane by five columns."
  (interactive)
  (teams4e--resize-index -5))

(defun teams4e-toggle-favorite ()
  "Toggle the current chat in the local favorites section."
  (interactive)
  (teams4e--load-state)
  (let* ((chat (or (teams4e--chat-at-point)
                   (user-error "No Teams chat here")))
         (chat-id (teams4e--chat-id chat))
         (enabled (not (teams4e--favorite-p chat))))
    (if enabled
        (puthash chat-id t teams4e--favorites)
      (remhash chat-id teams4e--favorites))
    (teams4e--save-state)
    (setq teams4e--chats
          (sort teams4e--chats #'teams4e--chat-updated-p))
    (teams4e--refresh-visible-recent)
    (message "%s %s"
             (if enabled "Favorited" "Removed favorite")
             (teams4e--chat-label chat))))

(defun teams4e-toggle-muted ()
  "Toggle local inbox suppression for the current Teams chat.

This does not change Teams notification settings.  Microsoft Graph does not
document a chat mute mutation, so the private state only controls the Emacs
`inbox' view; `all' continues to show the conversation."
  (interactive)
  (teams4e--load-state)
  (let* ((chat (or (teams4e--chat-at-point)
                   (user-error "No Teams chat here")))
         (chat-id (teams4e--chat-id chat))
         (locally-muted (gethash chat-id teams4e--muted))
         (enabled (not locally-muted)))
    (if enabled
        (puthash chat-id t teams4e--muted)
      (remhash chat-id teams4e--muted))
    (teams4e--save-state)
    (teams4e--refresh-visible-recent)
    (message "%s %s in the Teams inbox"
             (if enabled "Muted" "Unmuted")
             (teams4e--chat-label chat))))

(defun teams4e--set-read-state (state &optional quiet)
  "Set the current chat read STATE through Graph.

STATE is the symbol `read' or `unread'.  QUIET suppresses success messages."
  (teams4e--require-online)
  (let* ((chat (or (teams4e--chat-at-point)
                   (user-error "No Teams chat here")))
         (chat-id (teams4e--chat-id chat))
         (label (teams4e--chat-label chat)))
    (teams4e--run-json
     (list "teams" "chat" "mark" (symbol-name state) "--chatId" chat-id)
     (lambda (_payload)
       (puthash chat-id
                (cons state (teams4e--get chat 'lastUpdatedDateTime))
                teams4e--read-overrides)
       (teams4e--refresh-visible-recent)
       (unless quiet (message "Marked %s %s" label state))))))

(defun teams4e-mark-read ()
  "Explicitly mark the current chat read."
  (interactive)
  (teams4e--set-read-state 'read))

(defun teams4e-mark-unread ()
  "Explicitly mark the current chat unread from its newest message."
  (interactive)
  (teams4e--set-read-state 'unread))

(defun teams4e--message-args
    (chat &optional all request-limit ignore-date)
  "Return Graph-backend arguments to load CHAT messages.

ALL non-nil suppresses the date and item bounds.  REQUEST-LIMIT overrides the
normal on-screen limit, primarily for automatic previews.  IGNORE-DATE keeps
the item bound while allowing older pages to be loaded."
  (let ((limit (and (not all)
                    (or request-limit teams4e-message-limit))))
    (if teams4e-offline-mode
        (list "teams" "cache" "chat" "message" "list"
              "--chatId" (teams4e--chat-id chat)
              "--limit" (if all
                            "1000000"
                          (number-to-string (or limit 1000))))
      (append
       (list "teams" "chat" "message" "list"
             "--chatId" (teams4e--chat-id chat))
       (when limit (list "--limit" (number-to-string limit)))
       (unless (or all ignore-date (not teams4e-message-days))
         (list "--modifiedStartDateTime"
               (format-time-string
                "%Y-%m-%dT%H:%M:%SZ"
                (time-subtract nil (days-to-time teams4e-message-days))
                t)))))))

(defun teams4e--reaction-summary (message)
  "Return a compact reaction summary for MESSAGE."
  (let ((reactions (teams4e--get message 'reactions)))
    (when (listp reactions)
      (let ((counts (make-hash-table :test #'equal)))
        (dolist (reaction reactions)
          (let ((kind (or (teams4e--get reaction 'reactionType) "reaction")))
            (puthash kind (1+ (gethash kind counts 0)) counts)))
        (let (parts)
          (maphash (lambda (kind count)
                     (push (format "%s %d" kind count) parts))
                   counts)
          (string-join (sort parts #'string<) ", "))))))

(defun teams4e--graph-segment (value)
  "Encode opaque Graph path segment VALUE."
  (url-hexify-string (format "%s" value)))

(defun teams4e--absolute-inline-image-url (message source)
  "Resolve MESSAGE image SOURCE to an authenticated absolute URL."
  (let* ((source (and (stringp source) (string-trim source)))
         (message-id (teams4e--get message 'id))
         (chat-id
          (or (teams4e--get message 'chatId)
              (and teams4e--chat
                   (teams4e--chat-id teams4e--chat))))
         (team-id
          (or (teams4e--dig message 'channelIdentity 'teamId)
              (and (boundp 'teams4e-channel--team)
                   (teams4e--get teams4e-channel--team 'id))))
         (channel-id
          (or (teams4e--dig message 'channelIdentity 'channelId)
              (and (boundp 'teams4e-channel--channel)
                   (teams4e--get teams4e-channel--channel 'id))))
         (reply-to-id (teams4e--get message 'replyToId))
         (hosted-id
          (and source
               (string-match "hostedContents/\\([^/?]+\\)/\\$value" source)
               (match-string 1 source))))
    (cond
     ((not (and source (not (string-empty-p source)))) nil)
     ((or (string-prefix-p "https://" source)
          (string-prefix-p "file://" source))
      source)
     ((string-prefix-p "//graph.microsoft.com/" source)
      (concat "https:" source))
     ((or (string-prefix-p "/v1.0/" source)
          (string-prefix-p "/beta/" source))
      (concat "https://graph.microsoft.com" source))
     ((or (string-prefix-p "/chats/" source)
          (string-prefix-p "/teams/" source))
      (concat "https://graph.microsoft.com/v1.0" source))
     ((and hosted-id chat-id message-id)
      (format
       "https://graph.microsoft.com/v1.0/chats/%s/messages/%s/hostedContents/%s/$value"
       (teams4e--graph-segment chat-id)
       (teams4e--graph-segment message-id)
       hosted-id))
     ((and hosted-id team-id channel-id message-id)
      (if reply-to-id
          (format
           (concat "https://graph.microsoft.com/v1.0/teams/%s/channels/%s/"
                   "messages/%s/replies/%s/hostedContents/%s/$value")
           (teams4e--graph-segment team-id)
           (teams4e--graph-segment channel-id)
           (teams4e--graph-segment reply-to-id)
           (teams4e--graph-segment message-id)
           hosted-id)
        (format
         (concat "https://graph.microsoft.com/v1.0/teams/%s/channels/%s/"
                 "messages/%s/hostedContents/%s/$value")
         (teams4e--graph-segment team-id)
         (teams4e--graph-segment channel-id)
         (teams4e--graph-segment message-id)
         hosted-id)))
     (t nil))))

(defun teams4e--inline-images (message)
  "Return synthetic attachment objects for inline images in MESSAGE HTML."
  (let ((content (teams4e--dig message 'body 'content)) images)
    (when (and (stringp content) (string-match-p "<img[ >]" content))
      (condition-case nil
          (with-temp-buffer
            (insert "<html><body>" content "</body></html>")
            (let ((document (libxml-parse-html-region (point-min) (point-max)))
                  (index 0))
              (dolist (node (dom-by-tag document 'img))
                (when-let* ((source (dom-attr node 'src))
                            (url (teams4e--absolute-inline-image-url
                                  message source)))
                  (cl-incf index)
                  (push
                   (list
                    (cons 'id (format "inline-%s-%d"
                                      (or (teams4e--get message 'id) "image")
                                      index))
                    (cons 'contentType "hostedImage")
                    (cons 'contentUrl url)
                    (cons 'name
                          (format "%s-%d.png"
                                  (or (dom-attr node 'alt) "inline-image")
                                  index)))
                   images)))))
        (error nil)))
    (nreverse images)))

(defun teams4e--image-attachment-p (attachment)
  "Return non-nil when ATTACHMENT represents a displayable image."
  (let ((content-type (downcase
                       (or (teams4e--get attachment 'contentType) "")))
        (name (downcase (or (teams4e--get attachment 'name) ""))))
    (or (string-prefix-p "image/" content-type)
        (equal content-type "hostedimage")
        (string-match-p "\\.\\(png\\|jpe?g\\|gif\\|webp\\|bmp\\|tiff?\\)\\'"
                        name))))

(defun teams4e--message-images (message)
  "Return unique inline and attached images represented by MESSAGE."
  (let ((seen (make-hash-table :test #'equal)) images)
    (dolist (attachment
             (append (teams4e--get message 'attachments)
                     (teams4e--inline-images message)))
      (let ((url (or (teams4e--get attachment 'contentUrl)
                     (teams4e--get attachment 'webUrl))))
        (when (and (teams4e--image-attachment-p attachment)
                   (stringp url) (not (gethash url seen)))
          (puthash url t seen)
          (push attachment images))))
    (nreverse images)))

(defun teams4e--image-extension (attachment)
  "Return a conservative filename extension for ATTACHMENT."
  (let* ((name (or (teams4e--get attachment 'name) ""))
         (extension (downcase (or (file-name-extension name) "")))
         (content-type (downcase
                        (or (teams4e--get attachment 'contentType) ""))))
    (cond
     ((member extension '("png" "jpg" "jpeg" "gif" "webp" "bmp" "tif" "tiff"))
      extension)
     ((string-match "image/\\(jpeg\\|png\\|gif\\|webp\\|bmp\\|tiff\\)"
                    content-type)
      (if (equal (match-string 1 content-type) "jpeg")
          "jpg"
        (match-string 1 content-type)))
     (t "png"))))

(defun teams4e--image-cache-path (attachment)
  "Return the private cache path for ATTACHMENT."
  (let ((url (or (teams4e--get attachment 'contentUrl)
                 (teams4e--get attachment 'webUrl))))
    (expand-file-name
     (format "%s.%s" (secure-hash 'sha256 (or url "missing-image-url"))
             (teams4e--image-extension attachment))
     teams4e-image-cache-directory)))

(defun teams4e--image-cache-ready-p (path)
  "Return non-nil when PATH contains a usable cached image."
  (when (file-readable-p path)
    (when-let ((attributes (file-attributes path)))
      (> (file-attribute-size attributes) 0))))

(defun teams4e--insert-loaded-image (path name)
  "Insert cached Teams image PATH with a clickable NAME label."
  (insert "  ")
  (insert-text-button
   (format "Image: %s" name)
   'action (lambda (_button) (find-file-other-window path))
   'follow-link t
   'face 'teams4e-image-label
   'help-echo "Open image in another window")
  (insert "\n")
  (when (and (display-images-p) (file-readable-p path))
    (condition-case nil
        (let* ((window (get-buffer-window (current-buffer) t))
               (window-width (and window (window-body-width window t)))
               (max-width
                (if (and (numberp window-width) (> window-width 0))
                    (min teams4e-image-max-width
                         (max 120 (- window-width 32)))
                  teams4e-image-max-width))
               (image (create-image path nil nil
                                    :max-width max-width
                                    :max-height teams4e-image-max-height)))
          (when image
            (insert "  ")
            (insert-image image (format "[Image: %s]" name))
            (insert "\n")))
      (error nil))))

(defun teams4e--replace-image-slot
    (buffer marker token path name &optional failure)
  "Replace an image placeholder in BUFFER at MARKER matching TOKEN.

PATH and NAME describe the cached image.  With FAILURE non-nil, render a
nonfatal unavailable label instead."
  (when (and (buffer-live-p buffer) (marker-position marker))
    (with-current-buffer buffer
      (save-excursion
        (let ((inhibit-read-only t)
              (position (marker-position marker)))
          (when (equal token (get-text-property position 'teams4e-image-token))
            (let ((end (next-single-property-change
                        position 'teams4e-image-token nil (point-max)))
                  (message (get-text-property position 'teams4e-message)))
              (delete-region position end)
              (goto-char position)
              (if failure
                  (insert (propertize (format "  Image unavailable: %s\n" name)
                                      'face 'shadow))
                (teams4e--insert-loaded-image path name))
              (when message
                (add-text-properties position (point)
                                     (list 'teams4e-message message
                                           'rear-nonsticky
                                           '(teams4e-message))))))))))
  (set-marker marker nil))

(defun teams4e--finish-image-process (buffer process)
  "Retire PROCESS from BUFFER and start its next queued image."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq teams4e--image-processes
            (delq process teams4e--image-processes)
            teams4e--image-active
            (max 0 (1- teams4e--image-active)))
      (teams4e--pump-image-queue))))

(defun teams4e--start-image-job (job)
  "Start one queued image download JOB in the current buffer."
  (pcase-let* ((`(,attachment ,marker ,token) job)
               (buffer (current-buffer))
               (url (or (teams4e--get attachment 'contentUrl)
                        (teams4e--get attachment 'webUrl)))
               (name (or (teams4e--get attachment 'name) "image"))
               (path (teams4e--image-cache-path attachment))
               (process nil))
    (make-directory teams4e-image-cache-directory t)
    (set-file-modes teams4e-image-cache-directory #o700)
    (setq process
          (teams4e--run-json
           (list "teams" "attachment" "download"
                 "--url" url "--destination" path)
           (lambda (payload)
             (let ((downloaded (or (teams4e--get payload 'path) path)))
               (teams4e--replace-image-slot
                buffer marker token downloaded name
                (not (teams4e--image-cache-ready-p downloaded))))
             (teams4e--finish-image-process buffer process))
           (lambda (_status _detail)
             (teams4e--replace-image-slot
              buffer marker token path name t)
             (teams4e--finish-image-process buffer process))))
    (push process teams4e--image-processes)))

(defun teams4e--pump-image-queue ()
  "Start queued transcript images up to the configured concurrency bound."
  (let ((limit (max 1 teams4e-image-download-concurrency)))
    (while (and teams4e--image-queue
                (< teams4e--image-active limit))
      (let ((job (pop teams4e--image-queue)))
        (cl-incf teams4e--image-active)
        (condition-case nil
            (teams4e--start-image-job job)
          (error
           (cl-decf teams4e--image-active)
           (pcase-let ((`(,attachment ,marker ,token) job))
             (teams4e--replace-image-slot
              (current-buffer) marker token
              (teams4e--image-cache-path attachment)
              (or (teams4e--get attachment 'name) "image") t))))))))

(defun teams4e--queue-image (attachment marker token)
  "Queue ATTACHMENT for the placeholder at MARKER matching TOKEN."
  (setq teams4e--image-queue
        (nconc teams4e--image-queue
               (list (list attachment marker token))))
  (teams4e--pump-image-queue))

(defun teams4e--insert-message-images (message &optional images)
  "Insert and asynchronously load MESSAGE IMAGES."
  (when teams4e-display-images
    (dolist (attachment (or images (teams4e--message-images message)))
      (let* ((name (or (teams4e--get attachment 'name) "image"))
             (path (teams4e--image-cache-path attachment))
             (token (format "%s:%s"
                            (or (teams4e--get message 'id) "message")
                            (secure-hash 'sha256
                                         (or (teams4e--get attachment 'contentUrl)
                                             name))))
             (start (point)))
        (cond
         ((teams4e--image-cache-ready-p path)
          (teams4e--insert-loaded-image path name))
         (teams4e-offline-mode
          (insert (propertize (format "  Image not cached: %s\n" name)
                              'face 'shadow)))
         (t
          (insert (propertize (format "  Loading image: %s\n" name)
                              'face 'shadow
                              'teams4e-image-token token))
          (teams4e--queue-image attachment
                                         (copy-marker start) token)))))))

(defun teams4e--reference-attachment-p (attachment)
  "Return non-nil when ATTACHMENT is a quoted or forwarded message reference."
  (member (teams4e--get attachment 'contentType)
          '("messageReference" "forwardedMessageReference")))

(defun teams4e--attachment-content-object (attachment)
  "Parse ATTACHMENT's structured content, returning nil for invalid content."
  (let ((content (teams4e--get attachment 'content)))
    (cond
     ((listp content) content)
     ((stringp content)
      (condition-case nil
          (json-parse-string content :object-type 'alist :array-type 'list
                             :null-object nil :false-object nil)
        (error nil))))))

(defun teams4e--insert-card-link (label url indent)
  "Insert a card link with LABEL, URL, and string INDENT."
  (when (and (stringp url) (not (string-empty-p url)))
    (insert indent)
    (insert-text-button (or label url)
                        'action (lambda (_button) (browse-url url))
                        'follow-link t)
    (insert "\n")))

(defun teams4e--insert-card-actions (actions indent)
  "Insert supported card ACTIONS using string INDENT."
  (dolist (action (teams4e--payload-list actions))
    (let ((type (or (teams4e--get action 'type) ""))
          (title (or (teams4e--get action 'title) "Open"))
          (url (or (teams4e--get action 'url)
                   (teams4e--get action 'target))))
      (when (or (string-match-p "OpenUrl\\'" type) (stringp url))
        (teams4e--insert-card-link title url indent)))))

(defun teams4e--insert-card-elements (elements indent)
  "Insert Adaptive Card ELEMENTS using string INDENT."
  (dolist (element (teams4e--payload-list elements))
    (let ((type (or (teams4e--get element 'type) "")))
      (pcase type
        ((or "TextBlock" "RichTextBlock")
         (when-let ((text (or (teams4e--get element 'text)
                              (teams4e--get element 'altText))))
           (insert indent (teams4e--html-to-text text) "\n")))
        ("FactSet"
         (dolist (fact (teams4e--payload-list
                        (teams4e--get element 'facts)))
           (insert indent
                   (or (teams4e--get fact 'title) "")
                   (if (teams4e--get fact 'title) ": " "")
                   (teams4e--html-to-text
                    (or (teams4e--get fact 'value) ""))
                   "\n")))
        ((or "Container" "Column")
         (teams4e--insert-card-elements
          (teams4e--get element 'items) indent))
        ("ColumnSet"
         (dolist (column (teams4e--payload-list
                          (teams4e--get element 'columns)))
           (teams4e--insert-card-elements
            (teams4e--get column 'items) indent)))
        ("Image"
         (teams4e--insert-card-link
          (or (teams4e--get element 'altText) "Card image")
          (teams4e--get element 'url) indent))
        ("ActionSet"
         (teams4e--insert-card-actions
          (teams4e--get element 'actions) indent))
        (_
         (when-let ((text (or (teams4e--get element 'text)
                              (teams4e--get element 'title))))
           (insert indent (teams4e--html-to-text text) "\n")))))))

(defun teams4e--insert-rich-attachment (attachment)
  "Render structured ATTACHMENT and return non-nil when it is a Teams card."
  (let ((content-type (or (teams4e--get attachment 'contentType) "")))
    (when (string-match-p
           "\\`application/vnd\\.microsoft\\.card\\." content-type)
      (let* ((content (teams4e--attachment-content-object attachment))
             (name (or (teams4e--get attachment 'name)
                       (and content (teams4e--get content 'title))
                       "Teams card")))
        (insert (propertize (format "  %s\n" name) 'face 'bold))
        (cond
         ((string-match-p "codesnippet\\'" content-type)
          (let ((language (and content (teams4e--get content 'language)))
                (code (and content (teams4e--get content 'code))))
            (when language (insert (propertize (format "  %s\n" language)
                                               'face 'shadow)))
            (when (stringp code)
              (dolist (line (string-lines code))
                (insert (propertize (concat "    " line "\n")
                                    'face 'fixed-pitch))))))
         (content
          (dolist (key '(subtitle subTitle text summary))
            (when-let ((text (teams4e--get content key)))
              (when (stringp text)
                (insert "  " (teams4e--html-to-text text) "\n"))))
          (teams4e--insert-card-elements
           (teams4e--get content 'body) "  ")
          (teams4e--insert-card-actions
           (teams4e--get content 'actions) "  "))
         (t (insert (propertize "  Card content is unavailable\n"
                                'face 'shadow))))
        t))))

(defun teams4e--insert-attachments (message)
  "Insert attachment links and structured cards from MESSAGE."
  (dolist (attachment (teams4e--get message 'attachments))
    (unless (or (teams4e--reference-attachment-p attachment)
                (and teams4e-display-images
                     (teams4e--image-attachment-p attachment)))
      (unless (teams4e--insert-rich-attachment attachment)
        (let ((name (or (teams4e--get attachment 'name)
                        (teams4e--get attachment 'contentType)
                        "attachment"))
              (url (or (teams4e--get attachment 'contentUrl)
                       (teams4e--get attachment 'webUrl))))
          (insert "  Attachment: ")
          (if (and (stringp url) (not (string-empty-p url)))
              (insert-text-button name
                                  'action (lambda (_button) (browse-url url))
                                  'follow-link t)
            (insert name))
          (insert "\n"))))))

(defun teams4e--message-reference (message)
  "Return the first parsed quoted or forwarded reference in MESSAGE."
  (seq-some
   (lambda (attachment)
     (when (teams4e--reference-attachment-p attachment)
       (let ((content (teams4e--get attachment 'content)))
         (cond
          ((listp content) content)
          ((stringp content)
           (condition-case nil
               (json-parse-string content :object-type 'alist
                                  :array-type 'list :null-object nil)
             (error nil)))))))
   (teams4e--get message 'attachments)))

(defun teams4e--insert-message-reference (message)
  "Insert MESSAGE's quoted-reply reference when present."
  (when-let* ((reference (teams4e--message-reference message))
              (preview (teams4e--get reference 'messagePreview)))
    (let ((sender (or (teams4e--dig reference 'messageSender 'user 'displayName)
                      "Quoted message")))
      (insert (propertize (format "  > %s\n" sender) 'face 'shadow))
      (dolist (line (string-lines (teams4e--html-to-text preview)))
        (insert (propertize (format "  > %s\n" line) 'face 'shadow))))))

(defun teams4e--insert-day-separator (created)
  "Insert a day separator for ISO timestamp CREATED."
  (let ((label
         (condition-case nil
             (format-time-string "%A, %B %e, %Y" (date-to-time created))
           (error created))))
    (insert (propertize (format "\n%s\n\n" label)
                        'face 'teams4e-day-separator))))

(defun teams4e--insert-message (message)
  "Insert one Teams MESSAGE into the current transcript."
  (let ((start (point))
        (sender (teams4e--message-sender message))
        (created (teams4e--get message 'createdDateTime))
        (body (teams4e--message-body message))
        (images (teams4e--message-images message))
        (reactions (teams4e--reaction-summary message))
        (own (teams4e--message-own-p message)))
    (insert (propertize (if own "You" sender)
                        'face (if own
                                  'teams4e-own-sender
                                'teams4e-other-sender)))
    (insert (propertize (format "  %s" (teams4e--format-date created t))
                        'face 'shadow))
    (when (teams4e--get message 'lastEditedDateTime)
      (insert (propertize "  edited" 'face 'shadow)))
    (insert "\n")
    (teams4e--insert-message-reference message)
    (cond
     ((not (string-empty-p body))
      (insert (if (teams4e--system-event-p message)
                  (propertize body 'face 'teams4e-event)
                body)
              "\n"))
     ((and (null images)
           (null (seq-remove
                  #'teams4e--reference-attachment-p
                  (teams4e--get message 'attachments))))
      (insert (propertize "[Empty message]\n" 'face 'shadow))))
    (teams4e--insert-message-images message images)
    (teams4e--insert-attachments message)
    (when (and reactions (not (string-empty-p reactions)))
      (insert (propertize (format "  Reactions: %s\n" reactions) 'face 'shadow)))
    (insert "\n")
    (add-text-properties start (point)
                         (list 'teams4e-message message
                               'rear-nonsticky '(teams4e-message)))))

(defun teams4e--event-date-time (event field)
  "Return EVENT's UTC dateTime string for FIELD."
  (when-let ((value (teams4e--dig event field 'dateTime)))
    (let ((zone (teams4e--dig event field 'timeZone)))
      (if (and (stringp zone)
               (string-equal (downcase zone) "utc")
               (not (string-match-p "\\(?:[zZ]\\|[+-][0-9][0-9]:[0-9][0-9]\\)\\'"
                                    value)))
          (concat value "Z")
        value))))

(defun teams4e--format-meeting-time (value &optional date-only)
  "Format Graph date-time VALUE in the local Emacs timezone.

When DATE-ONLY is non-nil, omit the time of day."
  (when (stringp value)
    (condition-case nil
        (format-time-string (if date-only "%a, %b %e, %Y" "%a, %b %e, %Y %H:%M")
                            (date-to-time value))
      (error value))))

(defun teams4e--meeting-event (chat)
  "Return the linked calendar event attached to meeting CHAT."
  (teams4e--get (teams4e--get chat 'meetingContext) 'event))

(defun teams4e--meeting-start-time (chat)
  "Return meeting CHAT's start as an Emacs time value."
  (when-let ((value (teams4e--event-date-time
                     (teams4e--meeting-event chat) 'start)))
    (ignore-errors (date-to-time value))))

(defun teams4e--meeting-end-time (chat)
  "Return meeting CHAT's end as an Emacs time value."
  (when-let ((value (teams4e--event-date-time
                     (teams4e--meeting-event chat) 'end)))
    (ignore-errors (date-to-time value))))

(defun teams4e--meeting-location-label (chat)
  "Return a de-duplicated human-readable location for meeting CHAT."
  (let* ((event (teams4e--meeting-event chat))
         (primary (teams4e--dig event 'location 'displayName))
         (locations
          (delq nil
                (mapcar
                 (lambda (location)
                   (teams4e--get location 'displayName))
                 (teams4e--get event 'locations))))
         (labels
          (seq-uniq
           (seq-filter
            (lambda (label)
              (and (stringp label)
                   (not (string-empty-p (string-trim label)))))
            (append (and primary (list primary)) locations))
           #'string-equal)))
    (when labels (string-join labels ", "))))

(defun teams4e--meeting-response (chat)
  "Return the signed-in user's calendar response symbol for meeting CHAT."
  (when-let ((response
              (teams4e--dig (teams4e--meeting-event chat)
                             'responseStatus 'response)))
    (intern (downcase response))))

(defun teams4e--meeting-proposal (chat)
  "Return the new-time proposal attached to meeting CHAT in this session."
  (teams4e--get (teams4e--get chat 'meetingContext) 'proposal))

(defun teams4e--meeting-status-label (chat)
  "Return a concise calendar status label for meeting CHAT."
  (let* ((event (teams4e--meeting-event chat))
         (start (teams4e--meeting-start-time chat))
         (end (teams4e--meeting-end-time chat))
         (now (current-time)))
    (cond
     ((teams4e--get event 'isCancelled) "Cancelled")
     ((eq (teams4e--meeting-response chat) 'declined) "Declined")
     ((teams4e--meeting-proposal chat) "New time proposed")
     ((and start end
           (not (time-less-p now start))
           (time-less-p now end))
      "In progress")
     ((eq (teams4e--meeting-response chat) 'tentativelyaccepted)
      "Tentative")
     (t nil))))

(defun teams4e--meeting-upcoming-p (chat)
  "Return non-nil when meeting CHAT is upcoming or currently in progress."
  (let* ((event (teams4e--meeting-event chat))
         (start (teams4e--meeting-start-time chat))
         (end (teams4e--meeting-end-time chat))
         (boundary (or end start)))
    (and (teams4e--meeting-chat-p chat)
         event boundary
         (not (teams4e--get event 'isCancelled))
         (not (eq (teams4e--meeting-response chat) 'declined))
         (time-less-p (current-time) boundary))))

(defun teams4e--meeting-starts-before-p (left right)
  "Return non-nil when meeting chat LEFT starts before RIGHT."
  (let ((left-time (teams4e--meeting-start-time left))
        (right-time (teams4e--meeting-start-time right)))
    (cond
     ((and left-time right-time)
      (if (time-equal-p left-time right-time)
          (teams4e--chat-updated-p left right)
        (time-less-p left-time right-time)))
     (left-time t)
     (right-time nil)
     (t (teams4e--chat-updated-p left right)))))

(defun teams4e--meeting-row-label (chat)
  "Return compact local schedule and location text for meeting CHAT."
  (when (teams4e--meeting-chat-p chat)
    (let* ((event (teams4e--meeting-event chat))
           (start (teams4e--meeting-start-time chat))
           (end (teams4e--meeting-end-time chat))
           (all-day (teams4e--get event 'isAllDay))
           (status (teams4e--meeting-status-label chat))
           (location (teams4e--meeting-location-label chat))
           (schedule
            (cond
             ((and all-day start)
              (format-time-string "%a %b %e, all day" start))
             ((and start end
                   (equal (format-time-string "%Y-%m-%d" start)
                          (format-time-string "%Y-%m-%d" end)))
              (format "%s-%s"
                      (format-time-string "%a %b %e %H:%M" start)
                      (format-time-string "%H:%M" end)))
             ((and start end)
              (format "%s - %s"
                      (format-time-string "%a %b %e %H:%M" start)
                      (format-time-string "%a %b %e %H:%M" end)))
             (start (format-time-string "%a %b %e %H:%M" start))
             ((gethash (teams4e--chat-id chat)
                       teams4e--meeting-inflight)
              "Loading calendar...")
             ((teams4e--get (teams4e--get chat 'meetingContext) 'eventError)
              "Calendar unavailable"))))
      (string-join (delq nil (list schedule status location)) " | "))))

(defun teams4e--meeting-time-label (chat)
  "Return a readable local start/end label for meeting CHAT."
  (let* ((event (teams4e--meeting-event chat))
         (start-value (teams4e--event-date-time event 'start))
         (end-value (teams4e--event-date-time event 'end))
         (start-time (and start-value
                          (ignore-errors (date-to-time start-value))))
         (end-time (and end-value (ignore-errors (date-to-time end-value))))
         (all-day (teams4e--get event 'isAllDay)))
    (cond
     ((and all-day start-value)
      (concat (teams4e--format-meeting-time start-value t) " (all day)"))
     ((and start-time end-time
           (equal (format-time-string "%Y-%m-%d" start-time)
                  (format-time-string "%Y-%m-%d" end-time)))
      (format "%s-%s"
              (teams4e--format-meeting-time start-value)
              (format-time-string "%H:%M" end-time)))
     (start-value
      (concat (teams4e--format-meeting-time start-value)
              (when end-value
                (concat " - "
                        (teams4e--format-meeting-time end-value)))))
     (t nil))))

(defun teams4e--meeting-slot-time-label (slot)
  "Return a readable local start/end label for Graph time SLOT."
  (let* ((start-value (teams4e--event-date-time slot 'start))
         (end-value (teams4e--event-date-time slot 'end))
         (start-time (and start-value
                          (ignore-errors (date-to-time start-value))))
         (end-time (and end-value (ignore-errors (date-to-time end-value)))))
    (cond
     ((and start-time end-time
           (equal (format-time-string "%Y-%m-%d" start-time)
                  (format-time-string "%Y-%m-%d" end-time)))
      (format "%s-%s"
              (teams4e--format-meeting-time start-value)
              (format-time-string "%H:%M" end-time)))
     (start-value
      (concat (teams4e--format-meeting-time start-value)
              (when end-value
                (concat " - " (teams4e--format-meeting-time end-value)))))
     (t nil))))

(defun teams4e--insert-meeting-banner ()
  "Insert time, place, status, participants, and join data for the meeting chat."
  (when (teams4e--meeting-chat-p teams4e--chat)
    (let* ((context (teams4e--get teams4e--chat 'meetingContext))
           (participants
            (teams4e--meeting-participant-names teams4e--chat))
           (when-label
            (or (teams4e--meeting-time-label teams4e--chat)
                (if (teams4e--request-live-p
                     teams4e--meeting-process)
                    "Loading calendar details..."
                  "Unavailable from the linked calendar")))
           (where-label
            (teams4e--meeting-location-label teams4e--chat))
           (status-label
            (teams4e--meeting-status-label teams4e--chat))
           (proposal-label
            (when-let ((proposal
                        (teams4e--meeting-proposal teams4e--chat)))
              (teams4e--meeting-slot-time-label proposal)))
           (join-url
            (or (teams4e--dig context 'event 'onlineMeeting 'joinUrl)
                (teams4e--dig context 'onlineMeetingInfo 'joinWebUrl)
                (teams4e--dig teams4e--chat
                               'onlineMeetingInfo 'joinWebUrl))))
      (insert (propertize "Meeting details\n" 'face 'bold))
      (insert (format "When: %s\n" when-label))
      (when proposal-label
        (insert (format "Proposed: %s\n" proposal-label)))
      (when where-label (insert (format "Where: %s\n" where-label)))
      (when status-label (insert (format "Status: %s\n" status-label)))
      (insert (format "Participants: %s\n"
                      (if participants
                          (string-join participants ", ")
                        (if (teams4e--request-live-p
                             teams4e--meeting-process)
                            "Loading..."
                          "Unavailable"))))
      (when (stringp join-url)
        (insert-text-button "Join meeting"
                            'action (lambda (_button)
                                      (teams4e--open-url-in-browser
                                       join-url))
                            'follow-link t)
        (insert "\n"))
      (insert "\n"))))

(defun teams4e--load-meeting-context (chat)
  "Load calendar and participant context for meeting CHAT in this reader."
  (when (and (teams4e--meeting-chat-p chat)
             (not teams4e-offline-mode))
    (teams4e--cancel-process teams4e--meeting-process)
    (cl-incf teams4e--meeting-request-id)
    (let ((buffer (current-buffer))
          (chat-id (teams4e--chat-id chat))
          (request-id teams4e--meeting-request-id))
      (setq
       teams4e--meeting-process
       (teams4e--fetch-meeting-context
        chat
        (lambda (context)
          (when (buffer-live-p buffer)
            (with-current-buffer buffer
              (when (and (= request-id teams4e--meeting-request-id)
                         (derived-mode-p 'teams4e-chat-mode)
                         (equal chat-id
                                (teams4e--chat-id
                                 teams4e--chat)))
                (setq teams4e--meeting-process nil
                      teams4e--meeting-context context)
                ;; If messages are still loading, their callback will render
                ;; once with this context instead of rebuilding the buffer twice.
                (when teams4e--loaded-at
                  (teams4e--render-chat))))))
        (lambda (status detail)
          (when (buffer-live-p buffer)
            (with-current-buffer buffer
              (when (= request-id teams4e--meeting-request-id)
                (setq teams4e--meeting-process nil))))
          (teams4e--report-error
           (teams4e--meeting-context-args chat) status detail)))))))

(defun teams4e--goto-reader-bottom ()
  "Move the current reader and every visible window showing it to the bottom."
  (goto-char (point-max))
  (dolist (window (get-buffer-window-list (current-buffer) nil t))
    (set-window-point window (point-max))))

(defun teams4e--render-chat ()
  "Render the current chat and its cached messages."
  (let ((inhibit-read-only t)
        (jump-to-bottom teams4e--jump-to-bottom-on-render)
        (message-id
         (unless teams4e--jump-to-bottom-on-render
           (or teams4e--pending-message-id
               (teams4e--get
                (teams4e-message-at-point) 'id))))
        last-day)
    (teams4e--cancel-image-loads)
    (erase-buffer)
    (insert (propertize (teams4e--chat-label teams4e--chat)
                        'face '(:height 1.25 :weight bold)))
    (insert "  ")
    (when (teams4e--get teams4e--chat 'webUrl)
      (insert-text-button "Open in Teams"
                          'action (lambda (_button)
                                    (teams4e-open-in-browser))
                          'follow-link t))
    (insert "\n\n")
    (teams4e--insert-meeting-banner)
    (if teams4e--messages
        (dolist (message
                 (teams4e--messages-for-display
                  teams4e--messages))
          (let* ((created (or (teams4e--get message 'createdDateTime) ""))
                 (day (car (split-string created "T"))))
            (unless (equal day last-day)
              (setq last-day day)
              (teams4e--insert-day-separator created))
            (teams4e--insert-message message)))
      (insert (propertize "No messages in the selected time window.\n" 'face 'shadow)))
    (setq teams4e--pending-message-id nil)
    (cond
     (message-id
      (goto-char (point-min))
      (teams4e--goto-message-id message-id))
     (jump-to-bottom
      (teams4e--goto-reader-bottom))
     ((eq (teams4e--effective-message-order) 'newest-first)
      (goto-char (point-min))
      (teams4e-chat-next-message))
     (t
      (goto-char (point-max))
      (teams4e-chat-previous-message)))
    (setq teams4e--jump-to-bottom-on-render nil
          header-line-format
          (format "%s - %d messages - %s%s"
                  (teams4e--chat-label teams4e--chat)
                  (length teams4e--messages)
                  (teams4e--message-order-label)
                  (if teams4e--loaded-all " - complete" "")))))

(define-derived-mode teams4e-read-mode special-mode "Teams-Read"
  "Base mode for the singleton mu4e-style Teams message reader."
  (visual-line-mode 1)
  (add-hook 'kill-buffer-hook #'teams4e--cancel-buffer-process nil t)
  (setq-local truncate-lines nil))

(defvar teams4e-chat-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (define-key map (kbd "g") #'teams4e-chat-run-headers-command)
    (define-key map (kbd "M-g") #'teams4e-chat-refresh)
    (define-key map (kbd "G") #'teams4e-chat-load-all)
    (define-key map (kbd "L") #'teams4e-chat-load-more)
    (define-key map (kbd "S") #'teams4e-chat-run-headers-command)
    (define-key map (kbd "M-S") #'teams4e-toggle-message-order)
    (define-key map (kbd "c") #'teams4e-send)
    (define-key map (kbd "C") #'teams4e-send)
    (define-key map (kbd "s") #'teams4e-chat-run-headers-command)
    (define-key map (kbd "r") #'teams4e-chat-run-headers-command)
    (define-key map (kbd "R") #'teams4e-reply)
    (define-key map (kbd "i") #'teams4e-chat-run-headers-command)
    (define-key map (kbd "I") #'teams4e-chat-run-headers-command)
    (define-key map (kbd "U") #'teams4e-chat-run-headers-command)
    (define-key map (kbd "!") #'teams4e-chat-run-headers-command)
    (define-key map (kbd "?") #'teams4e-chat-run-headers-command)
    (define-key map (kbd "*") #'teams4e-chat-run-headers-command)
    (define-key map (kbd "f") #'teams4e-chat-run-headers-command)
    (define-key map (kbd "E") #'teams4e-export-thread)
    (define-key map (kbd "Y") #'teams4e-copy-thread-markdown)
    (define-key map (kbd "y") #'teams4e-chat-back-to-inbox)
    (define-key map (kbd "M-y") #'teams4e-copy-message)
    (define-key map (kbd "M-w") #'teams4e-capture-message)
    (define-key map (kbd "o") #'teams4e-open-in-browser)
    (define-key map (kbd "O") #'teams4e-open-in-app)
    (define-key map (kbd "F") #'teams4e-message-forward)
    (define-key map (kbd "M-F") #'teams4e-chat-run-headers-command)
    (define-key map (kbd "n") #'teams4e-chat-run-headers-command)
    (define-key map (kbd "p") #'teams4e-chat-run-headers-command)
    (define-key map (kbd "j") #'teams4e-thread-next)
    (define-key map (kbd "k") #'teams4e-thread-previous)
    (define-key map (kbd "N") #'teams4e-thread-next)
    (define-key map (kbd "P") #'teams4e-thread-previous)
    (define-key map (kbd "]") #'teams4e-chat-run-headers-command)
    (define-key map (kbd "[") #'teams4e-chat-run-headers-command)
    (define-key map (kbd "M-j") #'teams4e-chat-next-message)
    (define-key map (kbd "M-k") #'teams4e-chat-previous-message)
    (define-key map (kbd "M-u") #'teams4e-chat-run-headers-command)
    (define-key map (kbd "M") #'teams4e-chat-run-headers-command)
    (define-key map (kbd "T") #'teams4e-chat-run-headers-command)
    (define-key map (kbd "X") #'teams4e-chat-run-headers-command)
    (define-key map (kbd "u") #'teams4e-chat-run-headers-command)
    (define-key map (kbd "x") #'teams4e-chat-run-headers-command)
    (define-key map (kbd "z") #'teams4e-chat-run-headers-command)
    (define-key map (kbd "M-U") #'teams4e-chat-run-headers-command)
    (define-key map (kbd "a") #'teams4e-chat-run-headers-command)
    (define-key map (kbd "/") #'teams4e-chat-run-headers-command)
    (define-key map (kbd "b") #'teams4e-chat-run-headers-command)
    (define-key map (kbd "B") #'teams4e-chat-run-headers-command)
    (define-key map (kbd "v") #'teams4e-chat-run-headers-command)
    (define-key map (kbd "V") #'teams4e-chat-run-headers-command)
    (define-key map (kbd "H") #'teams4e-chat-run-headers-command)
    (define-key map (kbd "J") #'teams4e-chat-run-headers-command)
    (define-key map (kbd "K") #'teams4e-chat-run-headers-command)
    (define-key map (kbd "C-+") #'teams4e-chat-run-headers-command)
    (define-key map (kbd "C-=") #'teams4e-chat-run-headers-command)
    (define-key map (kbd "C--") #'teams4e-chat-run-headers-command)
    (define-key map (kbd "q") #'teams4e-chat-view-quit)
    (define-key map (kbd "h") #'teams4e-chat-back-to-inbox)
    map)
  "Keymap for `teams4e-chat-mode'.")

(define-derived-mode teams4e-chat-mode teams4e-read-mode
  "Teams-Read"
  "Major mode for reading a Microsoft Teams chat."
  nil)

(defun teams4e--cancel-buffer-process ()
  "Cancel the current Teams buffer's pending Graph request."
  (when (timerp teams4e--preview-timer)
    (cancel-timer teams4e--preview-timer))
  (setq teams4e--preview-timer nil)
  (teams4e--cancel-process teams4e--process)
  (teams4e--cancel-process teams4e--meeting-process)
  (cl-incf teams4e--meeting-request-id)
  (setq teams4e--process nil
        teams4e--meeting-process nil)
  (teams4e--cancel-image-loads))

(defun teams4e--cancel-image-loads ()
  "Cancel image downloads owned by the current Teams transcript buffer."
  (dolist (process teams4e--image-processes)
    (teams4e--cancel-process process))
  (dolist (job teams4e--image-queue)
    (set-marker (cadr job) nil))
  (setq teams4e--image-processes nil
        teams4e--image-queue nil
        teams4e--image-active 0))

(defun teams4e--display-chat-buffer (buffer preview)
  "Display thread BUFFER beside the inbox, preserving focus for PREVIEW."
  (let* ((index-buffer (teams4e--recent-buffer))
         (index-window (and index-buffer (get-buffer-window index-buffer t))))
    (if (not (window-live-p index-window))
        (if preview (display-buffer buffer) (pop-to-buffer buffer))
      (let* ((existing (get-buffer-window buffer t))
             (available (window-total-width index-window))
             (index-size
              (max window-min-width
                   (min (- available window-min-width)
                        (floor (* (frame-width)
                                  teams4e-index-width)))))
             (right (or existing
                        (window-in-direction 'right index-window)
                        (split-window index-window index-size 'right))))
        (set-window-buffer right buffer)
        (unless preview (select-window right))))))

(defun teams4e--close-other-readers (keep-buffer)
  "Kill every Teams message reader except KEEP-BUFFER."
  (dolist (buffer (buffer-list))
    (unless (eq buffer keep-buffer)
      (with-current-buffer buffer
        (when (memq major-mode
                    '(teams4e-read-mode
                      teams4e-chat-mode
                      teams4e-channel-thread-mode))
          (kill-buffer buffer))))))

(defun teams4e--preview-cache-valid-p (chat)
  "Return non-nil when the current buffer can preview CHAT without a request."
  (and teams4e--loaded-at
       (> teams4e-preview-cache-seconds 0)
       (< (- (float-time) teams4e--loaded-at)
          teams4e-preview-cache-seconds)
       (equal teams4e--loaded-update
              (teams4e--get chat 'lastUpdatedDateTime))))

(defun teams4e-open-chat (chat &optional preview all message-id)
  "Open native transcript buffer for CHAT.

When PREVIEW is non-nil, retain focus in the inbox window.  ALL requests
complete history, and MESSAGE-ID is selected after that history renders."
  (unless (teams4e--chat-id chat)
    (user-error "The selected chat has no identifier"))
  (let ((buffer (get-buffer-create teams4e--read-buffer-name)))
    (with-current-buffer buffer
      (unless (derived-mode-p 'teams4e-chat-mode)
        (when (derived-mode-p 'teams4e-read-mode)
          (teams4e--cancel-buffer-process))
        (teams4e-chat-mode))
      (let* ((previous-id
              (and teams4e--chat
                   (teams4e--chat-id teams4e--chat)))
             (same-chat
              (equal previous-id (teams4e--chat-id chat)))
             (reuse-preview
              (and preview same-chat (not all) (not message-id)
                   (teams4e--preview-cache-valid-p chat)))
             (same-request-running
              (and preview same-chat
                   (teams4e--request-live-p teams4e--process))))
        (setq teams4e--chat chat
              teams4e--automatic-preview-p (not (null preview))
              teams4e--pending-message-id message-id
              teams4e--jump-to-bottom-on-render
              (and (not preview) (not message-id)))
        (unless same-chat
          (teams4e--cancel-process teams4e--meeting-process)
          (cl-incf teams4e--meeting-request-id)
          (setq teams4e--meeting-process nil)
          (teams4e--cancel-image-loads)
          (setq teams4e--messages nil
                teams4e--loaded-at nil
                teams4e--loaded-update nil
                teams4e--loaded-all nil
                teams4e--meeting-context
                (teams4e--get chat 'meetingContext))
          (let ((inhibit-read-only t))
            (erase-buffer)
            (insert (format "Loading %s...\n"
                            (teams4e--chat-label chat)))))
        (unless (or reuse-preview same-request-running)
          (let ((teams4e--cache-first-open (not same-chat)))
            (teams4e-chat-refresh
             all (and preview teams4e-preview-message-limit))))
        (when (and (teams4e--meeting-chat-p chat)
                   (not (teams4e--get chat 'meetingContext))
                   (not (teams4e--request-live-p
                         teams4e--meeting-process)))
          (teams4e--load-meeting-context chat))))
    (teams4e--display-chat-buffer buffer preview)
    (teams4e--close-other-readers buffer)
    (when (and teams4e-mark-read-on-open
               (not teams4e-offline-mode))
      (with-current-buffer buffer
        (teams4e--set-read-state 'read t)))))

(defun teams4e-close-inactive-transcripts ()
  "Close legacy hidden Teams transcripts while retaining the singleton reader."
  (interactive)
  (let (targets)
    (dolist (buffer (buffer-list))
      (with-current-buffer buffer
        (when (and (memq major-mode
                         '(teams4e-chat-mode
                           teams4e-channel-thread-mode))
                   (not (equal (buffer-name)
                               teams4e--read-buffer-name))
                   (not (get-buffer-window buffer t)))
          (push buffer targets))))
    (dolist (buffer targets)
      (kill-buffer buffer))
    (message "Closed %d inactive Teams transcript%s"
             (length targets) (if (= (length targets) 1) "" "s"))))

(defun teams4e-chat-back-to-inbox ()
  "Return focus to the native Teams inbox."
  (interactive)
  (if-let* ((buffer (teams4e--recent-buffer))
            (window (get-buffer-window buffer t)))
      (select-window window)
    (teams4e-inbox)))

(defun teams4e--chat-refresh-cache-first (all request-limit)
  "Render cached messages, then refresh them from Graph.

This reads the existing SQLite cache and never creates another message store."
  (teams4e--cancel-process teams4e--process)
  (cl-incf teams4e--request-id)
  (let* ((buffer (current-buffer))
         (request-id teams4e--request-id)
         (chat teams4e--chat)
         (chat-id (teams4e--chat-id chat))
         (limit (or request-limit
                    teams4e-preview-message-limit
                    teams4e-message-limit
                    300))
         (args (list "teams" "cache" "chat" "message" "list"
                     "--chatId" chat-id
                     "--limit" (number-to-string limit)))
         request)
    (setq header-line-format "Loading cached Teams messages...")
    (setq
     request
     (teams4e--run-json
      args
      (lambda (payload)
        (when (and (buffer-live-p buffer)
                   (= request-id teams4e--request-id))
          (with-current-buffer buffer
            (when (and (derived-mode-p 'teams4e-chat-mode)
                       (equal chat-id
                              (teams4e--chat-id
                               teams4e--chat)))
              (setq teams4e--process nil)
              (let ((messages
                     (teams4e--normalize-messages
                      (teams4e--payload-list payload))))
                (when messages
                  (setq teams4e--messages messages
                        teams4e--loaded-all nil)
                  (let ((teams4e-display-images nil))
                    (teams4e--render-chat))))
              (let ((teams4e--cache-first-open nil))
                (teams4e-chat-refresh all request-limit))))))
      (lambda (_status _detail)
        (when (and (buffer-live-p buffer)
                   (= request-id teams4e--request-id))
          (with-current-buffer buffer
            (setq teams4e--process nil)
            (let ((teams4e--cache-first-open nil))
              (teams4e-chat-refresh all request-limit)))))))
    ;; Synchronous test backends can advance the generation in CALLBACK.
    (when (= request-id teams4e--request-id)
      (setq teams4e--process request))
    request))

(defun teams4e-chat-refresh
    (&optional all request-limit ignore-date)
  "Refresh the current Teams chat.

With ALL non-nil, request complete history rather than the configured window.
REQUEST-LIMIT is an internal item bound.  IGNORE-DATE suppresses the normal
date window while retaining that bound, which supports incremental loading."
  (interactive "P")
  (unless (derived-mode-p 'teams4e-chat-mode)
    (user-error "Not in a Teams chat buffer"))
  (if (and teams4e--cache-first-open
           teams4e-cache-first
           (not teams4e-offline-mode)
           (not all)
           (not ignore-date))
      (teams4e--chat-refresh-cache-first all request-limit)
    (teams4e--cancel-process teams4e--process)
    (cl-incf teams4e--request-id)
    (let ((buffer (current-buffer))
          (request-id teams4e--request-id)
          (chat teams4e--chat))
      (setq header-line-format
            (if teams4e--messages
                "Refreshing Teams messages..."
              "Loading Teams messages..."))
      (setq
       teams4e--process
       (teams4e--run-json
        (teams4e--message-args chat all request-limit ignore-date)
        (lambda (payload)
          (when (buffer-live-p buffer)
            (with-current-buffer buffer
              (when (and (= request-id teams4e--request-id)
                         (derived-mode-p 'teams4e-chat-mode)
                         (equal (teams4e--chat-id chat)
                                (and teams4e--chat
                                     (teams4e--chat-id
                                      teams4e--chat))))
                (let* ((messages
                        (teams4e--normalize-messages
                         (teams4e--payload-list payload)))
                       (limit (and (not all)
                                   (or request-limit
                                       teams4e-message-limit))))
                  (when (and limit (> (length messages) limit))
                    (setq messages (last messages limit)))
                  (setq teams4e--messages messages
                        teams4e--process nil
                        teams4e--loaded-at (float-time)
                        teams4e--loaded-update
                        (teams4e--get chat 'lastUpdatedDateTime)
                        teams4e--loaded-all
                        (or (not (null all))
                            (and ignore-date request-limit
                                 (< (length messages) request-limit))))
                  (teams4e--render-chat))))))
        (lambda (status detail)
          (when (buffer-live-p buffer)
            (with-current-buffer buffer
              (when (and (= request-id teams4e--request-id)
                         (derived-mode-p 'teams4e-chat-mode)
                         (equal (teams4e--chat-id chat)
                                (and teams4e--chat
                                     (teams4e--chat-id
                                      teams4e--chat))))
                (setq teams4e--process nil
                      header-line-format
                      (if teams4e--messages
                          (concat "Showing cached Teams messages; live refresh "
                                  "failed - see *M365 Errors*")
                        "Teams thread load failed - see *M365 Errors*")))))
          (teams4e--report-error
           (teams4e--message-args
            chat all request-limit ignore-date)
           status detail)))))))

(defun teams4e-chat-load-all ()
  "Refresh the current chat with complete history."
  (interactive)
  (teams4e-chat-refresh t))

(defun teams4e-chat-load-more (&optional count)
  "Load COUNT additional older messages into the current chat.

Without a prefix argument, use `teams4e-load-more-count'.  This expands
the newest-message bound without applying the normal date window."
  (interactive "P")
  (unless (derived-mode-p 'teams4e-chat-mode)
    (user-error "Not in a Teams chat buffer"))
  (when teams4e--loaded-all
    (user-error "The complete Teams chat is already loaded"))
  (let ((step (if count
                  (prefix-numeric-value count)
                teams4e-load-more-count)))
    (unless (> step 0)
      (user-error "Message increment must be positive"))
    (teams4e-chat-refresh
     nil (+ (length teams4e--messages) step) t)))

(defun teams4e-message-at-point ()
  "Return the Teams message represented at point."
  (or (get-text-property (point) 'teams4e-message)
      (and (> (point) (point-min))
           (get-text-property (1- (point)) 'teams4e-message))))

(defun teams4e--message-positions ()
  "Return starts of every rendered message region in the current buffer."
  (let ((position (point-min)) result)
    (while (< position (point-max))
      (let ((message (get-text-property position 'teams4e-message))
            (next (next-single-property-change
                   position 'teams4e-message nil (point-max))))
        (when message (push position result))
        (setq position (max (1+ position) next))))
    (nreverse result)))

(defun teams4e--message-position-index (positions)
  "Return the index in POSITIONS of the message containing point."
  (when-let* ((message (get-text-property (point) 'teams4e-message))
              (message-id (teams4e--get message 'id)))
    (cl-position
     message-id positions
     :key (lambda (position)
            (teams4e--get
             (get-text-property position 'teams4e-message) 'id))
     :test #'equal)))

(defun teams4e--message-relative-position (delta)
  "Return the rendered message position DELTA messages from point."
  (let* ((positions (teams4e--message-positions))
         (index (teams4e--message-position-index positions))
         (target-index (and index (+ index delta))))
    (if index
        (when (and (>= target-index 0) (< target-index (length positions)))
          (nth target-index positions))
      (if (> delta 0)
          (seq-find (lambda (candidate) (> candidate (point))) positions)
        (car (last (seq-take-while
                    (lambda (candidate) (< candidate (point))) positions)))))))

(defun teams4e--goto-message-id (message-id)
  "Move to rendered MESSAGE-ID and return non-nil when found."
  (let ((position
         (seq-find
          (lambda (candidate)
            (equal message-id
                   (teams4e--get
                    (get-text-property candidate 'teams4e-message) 'id)))
          (teams4e--message-positions))))
    (when position (goto-char position) t)))

(defun teams4e-chat-next-message ()
  "Move point to the next message block in the current transcript."
  (interactive)
  (let ((position (teams4e--message-relative-position 1)))
    (when position (goto-char position))))

(defun teams4e-chat-previous-message ()
  "Move point to the previous message block in the current transcript."
  (interactive)
  (let ((position (teams4e--message-relative-position -1)))
    (when position (goto-char position))))

(defconst teams4e--participant-choice
  "Find one-to-one chat by participant email..."
  "Special completion choice for resolving a direct chat.")

(defun teams4e--resolve-participant (callback)
  "Prompt for a participant email and pass the matching chat to CALLBACK."
  (let ((email (string-trim (read-string "Teams participant email: "))))
    (when (string-empty-p email) (user-error "Email is required"))
    (teams4e--run-json
     (list "teams" "chat" "get" "--participants" email)
     callback)))

(defun teams4e--choose-chat (chats callback)
  "Prompt for one of CHATS and invoke CALLBACK with it."
  (let* ((pairs (mapcar (lambda (chat)
                          (cons (teams4e--chat-choice chat) chat))
                        chats))
         (choice (completing-read
                  "Teams chat: "
                  (cons teams4e--participant-choice (mapcar #'car pairs))
                  nil t)))
    (if (equal choice teams4e--participant-choice)
        (teams4e--resolve-participant callback)
      (funcall callback (cdr (assoc choice pairs))))))

(defun teams4e--select-chat (callback)
  "Load, prompt for, and pass a Teams chat to CALLBACK."
  (let ((origin (current-buffer)))
    (teams4e--with-status
     (lambda ()
       (teams4e--load-chats
        (lambda (chats)
          (teams4e--choose-chat
           chats
           (lambda (chat)
             (if (buffer-live-p origin)
                 (with-current-buffer origin (funcall callback chat))
               (funcall callback chat))))))))))

;;;###autoload
(defun teams4e-chat (&optional participant)
  "Select and open a Teams chat.

With PARTICIPANT non-nil, resolve a one-to-one chat by participant email."
  (interactive "P")
  (if participant
      (teams4e--with-status
       (lambda ()
         (teams4e--resolve-participant #'teams4e-open-chat)))
    (teams4e--select-chat #'teams4e-open-chat)))

(defvar teams4e-compose-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map text-mode-map)
    (define-key map (kbd "C-c C-c") #'teams4e-compose-send)
    (define-key map (kbd "C-c C-k") #'teams4e-compose-abort)
    map)
  "Keymap for `teams4e-compose-mode'.")

(define-derived-mode teams4e-compose-mode text-mode "Teams-Compose"
  "Major mode for composing a Microsoft Teams chat message."
  (visual-line-mode 1)
  (setq-local require-final-newline nil))

(defun teams4e--target-label (target)
  "Return a human-readable label for message TARGET."
  (or (and (keywordp (car-safe target)) (plist-get target :label))
      (and (teams4e--chat-id target)
           (teams4e--chat-label target))
      "Teams"))

(defun teams4e--compose-target-key (target &optional reply-to)
  "Return stable non-secret key for TARGET and optional REPLY-TO message."
  (let* ((base
          (or (teams4e--chat-id target)
              (and (keywordp (car-safe target))
                   (or (and (plist-get target :team-id)
                            (format "%s/%s"
                                    (plist-get target :team-id)
                                    (plist-get target :channel-id)))
                       (plist-get target :user-emails)))
              "unknown"))
         (reply-id (teams4e--get reply-to 'id)))
    (if (and (stringp reply-id) (not (string-empty-p reply-id)))
        (format "%s/reply/%s" base reply-id)
      base)))

(defun teams4e--compose-buffer-name (target &optional reply-to)
  "Return stable compose buffer name for TARGET and optional REPLY-TO."
  (format "*Teams Compose: %s [%s]*"
          (teams4e--target-label target)
          (substring (md5 (teams4e--compose-target-key target reply-to))
                     0 6)))

(defun teams4e--open-compose (target &optional reply-to initial)
  "Open a multiline compose buffer for TARGET, optionally replying to REPLY-TO.

INITIAL, when non-nil, is inserted into an otherwise empty compose buffer."
  (let* ((origin (current-buffer))
         (label (teams4e--target-label target))
         (name (teams4e--compose-buffer-name target reply-to))
         (existing (get-buffer name))
         (buffer
          (get-buffer-create name))
         (fresh (not existing)))
    (pop-to-buffer buffer)
    (unless (derived-mode-p 'teams4e-compose-mode)
      (teams4e-compose-mode)
      (setq fresh t))
    (setq teams4e-compose--target target
          teams4e-compose--origin origin
          teams4e-compose--reply-to reply-to)
    (when fresh
      (setq teams4e-compose--attachments nil
            teams4e-compose--mentions nil
            teams4e-compose--content-type
            teams4e-default-content-type)
      (when (fboundp 'teams4e-compose--initialize-draft)
        (teams4e-compose--initialize-draft))
      (when (and initial (= (buffer-size) 0))
        (insert initial)))
    (if (fboundp 'teams4e-compose--update-header)
        (teams4e-compose--update-header)
      (setq header-line-format
            (format "%s: %s [%s]    C-c C-c send    C-c C-k abort"
                    (if reply-to
                        (format "Reply to %s"
                                (teams4e--message-sender reply-to))
                      "To")
                    label teams4e-compose--content-type)))
    (goto-char (point-max))))

;;;###autoload
(defun teams4e-send (&optional participant)
  "Compose a Teams message for the current or selected chat.

With PARTICIPANT non-nil, prompt for recipient email instead of selecting an
existing chat."
  (interactive "P")
  (cond
   (participant
    (let ((email (string-trim (read-string "Teams recipient email: "))))
      (when (string-empty-p email) (user-error "Email is required"))
      (teams4e--open-compose
       (list :user-emails email :label email))))
   ((teams4e--chat-at-point)
    (teams4e--open-compose (teams4e--chat-at-point)))
   (t
    (teams4e--select-chat #'teams4e--open-compose))))

(defun teams4e-reply ()
  "Reply to the message at point or the selected chat's latest preview."
  (interactive)
  (let* ((chat (teams4e--chat-at-point))
         (message
          (cond
           ((derived-mode-p 'teams4e-chat-mode)
            (teams4e-message-at-point))
           ((derived-mode-p 'teams4e-recent-mode)
            (teams4e--get chat 'lastMessagePreview)))))
    (unless chat (user-error "Move to a Teams chat or inbox row first"))
    (unless message
      (user-error "The selected chat has no loaded message to reply to"))
    (teams4e--open-compose chat message)))

(defun teams4e--send-args
    (target message &optional reply-to attachments mentions content-type)
  "Build Graph-backend arguments to send MESSAGE to TARGET.

REPLY-TO, when non-nil, is the source message for a native quoted reply."
  (let ((chat-id (teams4e--chat-id target))
        (emails (and (keywordp (car-safe target))
                     (plist-get target :user-emails)))
        (team-id (and (keywordp (car-safe target))
                      (plist-get target :team-id)))
        (channel-id (and (keywordp (car-safe target))
                         (plist-get target :channel-id)))
        (reply-id (and reply-to (teams4e--get reply-to 'id))))
    (unless (or chat-id emails (and team-id channel-id))
      (user-error "Compose target is invalid"))
    (when (and reply-to (not (and (stringp reply-id)
                                  (not (string-empty-p reply-id)))))
      (user-error "Reply target has no message ID"))
    (append
     (if (and team-id channel-id)
         '("teams" "channel" "message" "send")
       '("teams" "chat" "message" "send"))
     (cond
      ((and team-id channel-id)
       (list "--teamId" team-id "--channelId" channel-id))
      (chat-id (list "--chatId" chat-id))
      (t (list "--userEmails" emails)))
     (when reply-id (list "--replyToId" reply-id))
     (list "--message" message
           "--contentType" (or content-type "text"))
     (apply #'append
            (mapcar (lambda (path) (list "--attachment" path)) attachments))
     (apply #'append
            (mapcar (lambda (mention) (list "--mention" mention)) mentions))
     '("--output" "none"))))

(defun teams4e-compose-send ()
  "Send the current compose buffer through Microsoft Graph."
  (interactive)
  (teams4e--require-online)
  (unless (derived-mode-p 'teams4e-compose-mode)
    (user-error "Not in a Teams compose buffer"))
  (let* ((buffer (current-buffer))
         (target teams4e-compose--target)
         (reply-to teams4e-compose--reply-to)
         (attachments teams4e-compose--attachments)
         (mentions teams4e-compose--mentions)
         (content-type teams4e-compose--content-type)
         (origin teams4e-compose--origin)
         (message-text (string-trim (buffer-substring-no-properties
                                     (point-min) (point-max))))
         (label (teams4e--target-label target))
         args)
    (when (and (string-empty-p message-text) (null attachments))
      (user-error "Message and attachment list are empty"))
    (setq args
          (teams4e--send-args
           target message-text reply-to attachments mentions content-type))
    (when (or (not teams4e-confirm-send)
              (yes-or-no-p (format "Send this message to %s? " label)))
      (setq header-line-format (format "Sending to %s..." label))
      (teams4e--run
       args
       (lambda (_output)
         (when (and (buffer-live-p buffer)
                    (fboundp 'teams4e-compose--delete-draft))
           (with-current-buffer buffer
             (teams4e-compose--delete-draft)))
         (when (buffer-live-p buffer) (kill-buffer buffer))
         (message "Teams message sent to %s" label)
         (when (buffer-live-p origin)
           (with-current-buffer origin
             (cond
              ((derived-mode-p 'teams4e-chat-mode)
               (teams4e-chat-refresh))
              ((derived-mode-p 'teams4e-recent-mode)
               (teams4e-recent-refresh))
              ((and (fboundp 'teams4e-channel-thread-refresh)
                    (derived-mode-p 'teams4e-channel-thread-mode))
               (teams4e-channel-thread-refresh))
              ((and (fboundp 'teams4e-channel-refresh)
                    (derived-mode-p 'teams4e-channel-index-mode))
               (teams4e-channel-refresh))))))
       (lambda (status detail)
         (when (buffer-live-p buffer)
           (with-current-buffer buffer
             (setq header-line-format
                   (format "Send to %s failed - see *M365 Errors*" label))
             (when (fboundp 'teams4e-compose--save-draft)
               (teams4e-compose--save-draft))))
         (teams4e--report-error args status detail))))))

(defun teams4e-compose-abort ()
  "Discard the current Teams compose buffer after confirmation."
  (interactive)
  (when (or (= (buffer-size) 0)
            (yes-or-no-p "Discard this Teams draft? "))
    (when (fboundp 'teams4e-compose--delete-draft)
      (teams4e-compose--delete-draft))
    (kill-buffer (current-buffer))))

(defconst teams4e--web-host-regexp
  "\\(?:teams\\.microsoft\\.com\\|teams\\.cloud\\.microsoft\\)"
  "Official Teams web hosts accepted for web and desktop deep links.")

(defun teams4e--browser-url (url)
  "Return URL routed directly to Teams web instead of its app launcher."
  (if (and
       (stringp url)
       (string-match
        (concat "\\`https://\\(" teams4e--web-host-regexp
                "\\)\\(/l/[^#]*\\)\\'")
        url))
      (format "https://%s/#%s"
              (match-string 1 url) (match-string 2 url))
    url))

(defun teams4e--open-with-command (url command description)
  "Open URL with argv COMMAND and report failures using DESCRIPTION.

When COMMAND is nil, delegate to `browse-url'."
  (if (null command)
      (browse-url url)
    (unless (and (listp command)
                 (stringp (car command))
                 (not (string-empty-p (car command))))
      (user-error "%s command is not configured correctly" description))
    (condition-case error-data
        (make-process
         :name (format "teams4e-open-%s"
                       (replace-regexp-in-string "[^[:alnum:]]+" "-"
                                                 (downcase description)))
         :buffer nil
         :command (append command (list url))
         :noquery t
         :sentinel
         (lambda (process _event)
           (when (and (memq (process-status process) '(exit signal))
                      (not (zerop (process-exit-status process))))
             (message "Could not open %s with %s"
                      description (car command)))))
      (file-error
       (user-error "Could not start %s command: %s"
                   description (error-message-string error-data))))))

(defun teams4e--open-url-in-browser (url)
  "Open Teams URL in the configured web browser command."
  (teams4e--open-with-command
   (teams4e--browser-url url)
   teams4e-browser-command
   "Teams web"))

;;;###autoload
(defun teams4e-open-in-browser ()
  "Open the current chat or message in the official Teams web interface."
  (interactive)
  (let* ((message (and (derived-mode-p 'teams4e-chat-mode)
                       (teams4e-message-at-point)))
         (chat (teams4e--chat-at-point))
         (url (or (teams4e--get message 'webUrl)
                  (teams4e--get chat 'webUrl))))
    (unless (and (stringp url) (not (string-empty-p url)))
      (user-error "No Teams web URL is available here"))
    (teams4e--open-url-in-browser url)))

(defun teams4e--app-url (url)
  "Return the native Teams deep link corresponding to HTTPS URL."
  (cond
   ((and (stringp url) (string-prefix-p "msteams://" url)) url)
   ((and (stringp url)
         (string-match
          (concat "\\`https://\\(" teams4e--web-host-regexp
                  "/.*\\)\\'")
          url))
    (concat "msteams://" (match-string 1 url)))
   (t (user-error "This item does not provide a native Teams deep link"))))

(defun teams4e--open-url-in-app (url)
  "Open Teams HTTPS URL directly in the installed desktop application."
  (teams4e--open-with-command
   (teams4e--app-url url)
   teams4e-app-command
   "Teams app"))

;;;###autoload
(defun teams4e-open-in-app ()
  "Open the current chat or message directly in the Teams desktop app."
  (interactive)
  (let* ((message (and (derived-mode-p 'teams4e-chat-mode)
                       (teams4e-message-at-point)))
         (chat (teams4e--chat-at-point))
         (url (or (teams4e--get message 'webUrl)
                  (teams4e--get chat 'webUrl))))
    (unless (and (stringp url) (not (string-empty-p url)))
      (user-error "No Teams URL is available here"))
    (teams4e--open-url-in-app url)))

(defun teams4e-copy-message ()
  "Copy the readable body of the Teams message at point."
  (interactive)
  (let ((message (teams4e-message-at-point)))
    (unless message (user-error "Move point onto a Teams message first"))
    (kill-new (teams4e--message-body message))
    (message "Copied Teams message")))

(defun teams4e--dom-children-to-markdown (node)
  "Convert NODE's children to Markdown."
  (mapconcat #'teams4e--dom-to-markdown (dom-children node) ""))

(defun teams4e--dom-to-markdown (node)
  "Convert a libxml DOM NODE into conservative Markdown."
  (cond
   ((stringp node) (replace-regexp-in-string "\u00a0" " " node))
   ((not (consp node)) "")
   (t
    (let* ((tag (dom-tag node))
           (children (teams4e--dom-children-to-markdown node))
           (trimmed (string-trim children)))
      (pcase tag
        ((or 'html 'body 'span) children)
        ((or 'p 'div) (concat trimmed "\n\n"))
        ('br "\n")
        ((or 'strong 'b) (if (string-empty-p trimmed) "" (format "**%s**" trimmed)))
        ((or 'em 'i) (if (string-empty-p trimmed) "" (format "*%s*" trimmed)))
        ('code
         (if (string-match-p "`" children)
             (format "``%s``" children)
           (format "`%s`" children)))
        ('pre (format "\n```\n%s\n```\n\n" (string-trim-right children)))
        ('a
         (let ((url (dom-attr node 'href)))
           (cond
            ((not (stringp url)) children)
            ((string-empty-p trimmed) (format "<%s>" url))
            (t (format "[%s](%s)" trimmed url)))))
        ('img
         (let ((url (dom-attr node 'src))
               (alt (or (dom-attr node 'alt) "image")))
           (if (stringp url) (format "![%s](%s)" alt url) "")))
        ('li (format "- %s\n" trimmed))
        ((or 'ul 'ol) (concat "\n" children "\n"))
        ('blockquote
         (concat
          (mapconcat (lambda (line) (concat "> " line))
                     (string-lines trimmed) "\n")
          "\n\n"))
        ((or 'h1 'h2 'h3 'h4 'h5 'h6)
         (let ((level (string-to-number (substring (symbol-name tag) 1))))
           (format "%s %s\n\n" (make-string level ?#) trimmed)))
        ('attachment "")
        (_ children))))))

(defun teams4e--html-to-markdown (html)
  "Convert Teams HTML fragment HTML into readable Markdown."
  (if (not (and (stringp html) (string-match-p "<[^>]+>" html)))
      (string-trim (or html ""))
    (condition-case nil
        (with-temp-buffer
          (insert "<html><body>" html "</body></html>")
          (let* ((dom (libxml-parse-html-region (point-min) (point-max)))
                 (markdown (teams4e--dom-to-markdown dom)))
            (string-trim
             (replace-regexp-in-string "\n\\{3,\\}" "\n\n" markdown))))
      (error (teams4e--html-to-text html)))))

(defun teams4e--message-markdown (message)
  "Return one complete Teams MESSAGE as Markdown."
  (let* ((sender (teams4e--message-sender message))
         (created (teams4e--get message 'createdDateTime))
         (content (teams4e--dig message 'body 'content))
         (body (if (teams4e--get message 'deletedDateTime)
                   "*[Deleted message]*"
                 (if (teams4e--system-event-p message)
                     (format "*%s*" (teams4e--event-summary message))
                   (teams4e--html-to-markdown content))))
         (reference (teams4e--message-reference message))
         (reactions (teams4e--reaction-summary message))
         attachments)
    (dolist (attachment (teams4e--get message 'attachments))
      (unless (teams4e--reference-attachment-p attachment)
        (let ((name (or (teams4e--get attachment 'name) "Attachment"))
              (url (or (teams4e--get attachment 'contentUrl)
                       (teams4e--get attachment 'webUrl))))
          (push (if (stringp url) (format "[%s](%s)" name url) name)
                attachments))))
    (concat
     (format "### %s - %s\n\n" sender (teams4e--format-date created t))
     (when reference
       (let ((quoted-sender
              (or (teams4e--dig reference 'messageSender 'user 'displayName)
                  "Quoted message"))
             (preview (or (teams4e--get reference 'messagePreview) "")))
         (concat (format "> **%s**\n" quoted-sender)
                 (mapconcat (lambda (line) (concat "> " line))
                            (string-lines (teams4e--html-to-text preview)) "\n")
                 "\n\n")))
     (if (string-empty-p body) "*[Empty message]*" body)
     "\n\n"
     (when attachments
       (format "**Attachments:** %s\n\n"
               (string-join (nreverse attachments) ", ")))
     (when (and reactions (not (string-empty-p reactions)))
       (format "*Reactions: %s*\n\n" reactions)))))

(defun teams4e--thread-markdown (chat messages)
  "Return complete CHAT MESSAGES as a portable Markdown document."
  (let ((title (teams4e--chat-label chat))
        (url (teams4e--get chat 'webUrl))
        (last-day nil))
    (concat
     "# " title "\n\n"
     (format "- Exported: %s\n" (format-time-string "%Y-%m-%d %H:%M %Z"))
     (format "- Teams chat ID: `%s`\n" (teams4e--chat-id chat))
     (when (stringp url) (format "- [Open in Microsoft Teams](%s)\n" url))
     "\n"
     (mapconcat
      (lambda (message)
        (let* ((created (or (teams4e--get message 'createdDateTime) ""))
               (day (car (split-string created "T")))
               (heading (unless (equal day last-day)
                          (setq last-day day)
                          (format "## %s\n\n" day))))
          (concat heading (teams4e--message-markdown message))))
      (teams4e--normalize-messages messages)
      ""))))

(defun teams4e--export-path (chat)
  "Return the deterministic Markdown export path for CHAT."
  (let* ((label (downcase (teams4e--chat-label chat)))
         (slug (replace-regexp-in-string "[^[:alnum:]]+" "-" label))
         (slug (truncate-string-to-width (string-trim slug "-+" "-+") 80))
         (slug (string-trim-right slug "-+")))
    (expand-file-name
     (format "%s-%s-%s.md"
             (format-time-string "%Y-%m-%d")
             (if (string-empty-p slug) "teams-thread" slug)
             (teams4e--short-id chat))
     teams4e-export-directory)))

(defun teams4e--write-thread-export (path chat messages)
  "Write CHAT MESSAGES to Markdown PATH with private permissions."
  (make-directory (file-name-directory path) t)
  (with-temp-file path
    (insert (teams4e--thread-markdown chat messages)))
  (set-file-modes path #o600)
  path)

(defun teams4e--finish-thread-export
    (chat messages open &optional after-export)
  "Write complete CHAT MESSAGES and finish the export operation.

When OPEN is non-nil, visit the file.  When AFTER-EXPORT is non-nil, call it
with the absolute saved path after the mode-0600 file has been written."
  (let* ((path (teams4e--export-path chat))
         (saved-path
          (teams4e--write-thread-export path chat messages)))
    (cond
     (after-export
      (funcall after-export saved-path))
     (open
      (find-file-other-window saved-path))
     (t
      (message "Exported Teams thread to %s"
               (abbreviate-file-name saved-path))))
    saved-path))

(defun teams4e--copy-thread-markdown (chat messages)
  "Copy complete CHAT MESSAGES to the kill ring as Markdown."
  (let ((markdown (teams4e--thread-markdown chat messages)))
    (kill-new markdown)
    (message "Copied complete Teams thread as Markdown (%d messages)"
             (length messages))
    markdown))

(defun teams4e--copy-chat-thread-markdown (chat)
  "Fetch and copy complete CHAT history as Markdown."
  (message "Copying complete Teams history for %s..."
           (teams4e--chat-label chat))
  (teams4e--run-json
   (teams4e--message-args chat t)
   (lambda (payload)
     (teams4e--copy-thread-markdown
      chat (teams4e--payload-list payload)))))

(defun teams4e--export-thread (chat open &optional after-export)
  "Export complete CHAT history, visiting the output when OPEN is non-nil.

Call AFTER-EXPORT with the saved path when it is non-nil."
  (message "Exporting complete Teams history for %s..."
           (teams4e--chat-label chat))
  (teams4e--run-json
   (teams4e--message-args chat t)
   (lambda (payload)
     (teams4e--finish-thread-export
      chat (teams4e--payload-list payload) open after-export))))

(defun teams4e-export-thread (&optional open)
  "Download a complete Teams thread as Markdown.

Use the chat at point or current thread; otherwise prompt for a chat.  With
prefix argument OPEN, visit the exported file after writing it."
  (interactive "P")
  (if-let ((chat (teams4e--chat-at-point)))
      (teams4e--export-thread chat open)
    (teams4e--select-chat
     (lambda (selected) (teams4e--export-thread selected open)))))

(defun teams4e-copy-thread-markdown ()
  "Fetch and copy a complete Teams chat as Markdown.

Use the chat at point or current thread; otherwise prompt for a chat."
  (interactive)
  (if-let ((chat (teams4e--chat-at-point)))
      (teams4e--copy-chat-thread-markdown chat)
    (teams4e--select-chat
     #'teams4e--copy-chat-thread-markdown)))

(defun teams4e--capture-file ()
  "Resolve the local Org capture file for Teams messages and threads."
  (expand-file-name
   (or teams4e-capture-file
       (expand-file-name
        "teams.org"
        (or (and (boundp 'org-directory) org-directory)
            (expand-file-name "Documents" "~"))))))

(defun teams4e--capture-property (property)
  "Return inherited Org PROPERTY at point as a nonempty string."
  (let ((value (org-entry-get nil property t)))
    (and (stringp value) (not (string-empty-p value)) value)))

(defun teams4e--capture-context-match-p (context)
  "Return non-nil when the Org entry at point represents CONTEXT."
  (let ((chat-id (teams4e--get context 'chatId))
        (team-id (teams4e--get context 'teamId))
        (channel-id (teams4e--get context 'channelId))
        (thread-id (teams4e--get context 'threadId)))
    (if (stringp chat-id)
        (equal chat-id (teams4e--capture-property "TEAMS_CHAT"))
      (and (stringp team-id) (stringp channel-id) (stringp thread-id)
           (equal team-id
                  (teams4e--capture-property "TEAMS_TEAM_ID"))
           (equal channel-id
                  (teams4e--capture-property "TEAMS_CHANNEL_ID"))
           (equal thread-id
                  (teams4e--capture-property "TEAMS_THREAD"))))))

(defun teams4e--find-org-capture (context)
  "Return the best existing Org marker for Teams capture CONTEXT.

An exact message property wins; otherwise the conversation heading is used.
The Org file itself is authoritative, so no secondary linkage index is kept."
  (let ((file (teams4e--capture-file))
        (message-id (teams4e--get context 'selectedMessageId))
        message-marker conversation-marker)
    (when (file-readable-p file)
      (require 'org)
      (let ((buffer (find-file-noselect file)))
        (with-current-buffer buffer
          (save-restriction
           (widen)
           (org-map-entries
            (lambda ()
              (when (teams4e--capture-context-match-p context)
                (unless conversation-marker
                  (setq conversation-marker (copy-marker (point))))
                (when (and (stringp message-id)
                           (equal message-id
                                  (teams4e--capture-property
                                   "TEAMS_MESSAGE")))
                  (setq message-marker (copy-marker (point))))))
            nil 'file)))))
    (or message-marker conversation-marker)))

(defun teams4e--jump-to-capture-context (context)
  "Visit the existing Org capture for CONTEXT and return non-nil when found."
  (when-let ((marker (teams4e--find-org-capture context)))
    (pop-to-buffer (marker-buffer marker))
    (goto-char marker)
    (org-show-context)
    (org-reveal)
    t))

(defun teams4e--captured-chat-table ()
  "Return chat IDs derived from the Org capture file.

Reuse one in-memory snapshot while the source path, size, and modification time
are unchanged.  No index is written to disk."
  (when (>= (- (float-time) teams4e--captured-chat-checked-at)
            teams4e--captured-chat-check-seconds)
    (setq teams4e--captured-chat-checked-at (float-time))
    (let* ((file (teams4e--capture-file))
           (attributes (file-attributes file 'string))
           (signature
            (list file
                  (and attributes (file-attribute-size attributes))
                  (and attributes
                       (file-attribute-modification-time attributes)))))
      (unless (equal signature teams4e--captured-chat-signature)
        (let ((table (make-hash-table :test #'equal)))
          (when (and attributes (file-readable-p file))
            (require 'org)
            (with-temp-buffer
              (insert-file-contents file)
              (delay-mode-hooks (org-mode))
              (org-map-entries
               (lambda ()
                 (when-let ((chat-id
                             (teams4e--capture-property "TEAMS_CHAT")))
                   (puthash chat-id t table)))
               nil nil)))
          (setq teams4e--captured-chat-signature signature
                teams4e--captured-chat-table table)))))
  teams4e--captured-chat-table)

(defun teams4e--captured-p (chat)
  "Return non-nil when CHAT appears in the current transient capture table."
  (and (hash-table-p teams4e--captured-chat-table)
       (gethash (teams4e--chat-id chat)
                teams4e--captured-chat-table)))

(defun teams4e--capture-one-line (value)
  "Return VALUE as a single trimmed line suitable for Org metadata."
  (when value
    (string-trim
     (replace-regexp-in-string "[\n\r\t ]+" " " (format "%s" value)))))

(defun teams4e--capture-context-property (context key)
  "Return CONTEXT value for KEY as a nonempty single line."
  (let ((value (teams4e--capture-one-line
                (teams4e--get context key))))
    (and value (not (string-empty-p value)) value)))

(defun teams4e--chat-capture-context (chat &optional message)
  "Build complete Org capture metadata for CHAT and selected MESSAGE."
  (let* ((chat-url (teams4e--get chat 'webUrl))
         (message-url (teams4e--get message 'webUrl))
         (meeting-context (teams4e--get chat 'meetingContext))
         (meeting-event (teams4e--get meeting-context 'event))
         (channel-p (equal (teams4e--get chat 'chatType) "channel")))
    `((kind . ,(if channel-p "channel" "chat"))
      (title . ,(teams4e--chat-label chat))
      (conversationType . ,(teams4e--chat-type-label chat))
      (chatId . ,(unless channel-p (teams4e--chat-id chat)))
      (teamId . ,(teams4e--get chat 'teamId))
      (teamName . ,(teams4e--get chat 'teamName))
      (channelId . ,(teams4e--get chat 'channelId))
      (channelName . ,(teams4e--get chat 'channelName))
      (threadId . ,(teams4e--get chat 'threadId))
      (conversationUrl . ,chat-url)
      (selectedMessageId . ,(teams4e--get message 'id))
      (selectedMessageUrl . ,message-url)
      (sourceUrl . ,(or message-url chat-url))
      (updated . ,(or (teams4e--get message 'createdDateTime)
                      (teams4e--get chat 'lastUpdatedDateTime)))
      (meetingStart . ,(teams4e--event-date-time meeting-event 'start))
      (meetingEnd . ,(teams4e--event-date-time meeting-event 'end))
      (participants
       . ,(when-let ((names (and (teams4e--meeting-chat-p chat)
                                 (teams4e--meeting-participant-names chat))))
            (string-join names ", "))))))

(defconst teams4e--capture-property-map
  '(("TEAMS_KIND" . kind)
    ("TEAMS_TITLE" . title)
    ("TEAMS_CHAT" . chatId)
    ("TEAMS_TYPE" . conversationType)
    ("TEAMS_TEAM_ID" . teamId)
    ("TEAMS_TEAM" . teamName)
    ("TEAMS_CHANNEL_ID" . channelId)
    ("TEAMS_CHANNEL" . channelName)
    ("TEAMS_THREAD" . threadId)
    ("TEAMS_MESSAGE" . selectedMessageId)
    ("TEAMS_MEETING_START" . meetingStart)
    ("TEAMS_MEETING_END" . meetingEnd)
    ("TEAMS_PARTICIPANTS" . participants)
    ("TEAMS_URL" . sourceUrl))
  "Org properties copied from a Teams capture context.")

(defun teams4e--org-link (url description)
  "Return an Org link for URL with readable DESCRIPTION."
  (when (and (stringp url) (not (string-empty-p url)))
    (format "[[%s][%s]]"
            (replace-regexp-in-string "\\]" "%5D" url t t)
            (replace-regexp-in-string "\\]" "\\\\]"
                                      (or description "Microsoft Teams") t t))))

(defun teams4e--org-indent-text (text)
  "Indent plain TEXT so message content cannot become Org headings."
  (mapconcat (lambda (line) (concat "  " line))
             (string-lines (or text "")) "\n"))

(defun teams4e--message-org (message)
  "Return MESSAGE as a source-linked Org subtree."
  (let* ((sender (teams4e--message-sender message))
         (created (or (teams4e--get message 'createdDateTime) "Unknown time"))
         (body (teams4e--message-body message))
         (url (teams4e--get message 'webUrl))
         (message-id (teams4e--get message 'id))
         (reference (teams4e--message-reference message))
         (reactions (teams4e--reaction-summary message))
         attachments)
    (dolist (attachment (teams4e--get message 'attachments))
      (unless (teams4e--reference-attachment-p attachment)
        (let ((name (or (teams4e--get attachment 'name) "Attachment"))
              (attachment-url
               (or (teams4e--get attachment 'contentUrl)
                   (teams4e--get attachment 'webUrl))))
          (push (or (teams4e--org-link attachment-url name) name)
                attachments))))
    (concat
     (format "*** %s - %s\n" (teams4e--format-date created t) sender)
     (when (or message-id url)
       (concat ":PROPERTIES:\n"
               (when message-id
                 (format ":TEAMS_MESSAGE: %s\n"
                         (teams4e--capture-one-line message-id)))
               (when url (format ":TEAMS_URL: %s\n" url))
               ":END:\n"))
     (when url
       (concat (teams4e--org-link url "Open this message") "\n\n"))
     (when reference
       (let ((quoted-sender
              (or (teams4e--dig reference 'messageSender 'user 'displayName)
                  "Quoted message"))
             (preview (or (teams4e--get reference 'messagePreview) "")))
         (concat "Quoted from " quoted-sender ":\n"
                 (teams4e--org-indent-text
                  (teams4e--html-to-text preview))
                 "\n\n")))
     (teams4e--org-indent-text
      (if (string-empty-p body) "[Empty message]" body))
     "\n"
     (when attachments
       (concat "\nAttachments: " (string-join (nreverse attachments) ", ")
               "\n"))
     (when (and reactions (not (string-empty-p reactions)))
       (format "\nReactions: %s\n" reactions))
     "\n")))

(defun teams4e--summary-org-entry (context &optional message)
  "Return a compact, actionable Org capture for CONTEXT and last MESSAGE."
  (let* ((title (or (teams4e--capture-context-property context 'title)
                    "Teams conversation"))
         (type (teams4e--capture-context-property
                context 'conversationType))
         (source-url (teams4e--capture-context-property context 'sourceUrl))
         (updated (teams4e--capture-context-property context 'updated))
         (participants
          (teams4e--capture-context-property context 'participants))
         (meeting-start
          (teams4e--capture-context-property context 'meetingStart))
         (meeting-end
          (teams4e--capture-context-property context 'meetingEnd))
         (sender (and message (teams4e--message-sender message)))
         (body (and message (teams4e--message-body message)))
         (preview
          (and (stringp body)
               (truncate-string-to-width
                (replace-regexp-in-string "[\n\r\t ]+" " " body)
                800 nil nil "..."))))
    (concat
     "* Teams: " title "\n"
     ":PROPERTIES:\n"
     (format ":CAPTURED: %s\n" (format-time-string "[%Y-%m-%d %a %H:%M]"))
     (mapconcat
      (lambda (mapping)
        (when-let ((value
                    (teams4e--capture-context-property
                     context (cdr mapping))))
          (format ":%s: %s\n" (car mapping) value)))
      teams4e--capture-property-map "")
     ":END:\n\n"
     (when source-url
       (concat (teams4e--org-link source-url "Open in Microsoft Teams")
               "\n\n"))
     (when type (format "- Type :: %s\n" type))
     (when updated
       (format "- Last activity :: %s\n"
               (or (teams4e--format-meeting-time updated) updated)))
     (when meeting-start
       (format "- Meeting :: %s%s\n"
               (or (teams4e--format-meeting-time meeting-start)
                   meeting-start)
               (if meeting-end
                   (format " - %s"
                           (or (teams4e--format-meeting-time meeting-end)
                               meeting-end))
                 "")))
     (when participants (format "- Participants :: %s\n" participants))
     (when (or sender (and preview (not (string-empty-p preview))))
       (concat "\n** Last message\n"
               (when sender
                 (format "%s%s\n" sender
                         (if updated
                             (format " - %s"
                                     (or (teams4e--format-meeting-time
                                          updated)
                                         updated))
                           "")))
               (when (and preview (not (string-empty-p preview)))
                 (concat preview "\n")))))))

(defun teams4e--start-summary-org-capture (context &optional message)
  "Start an editable compact Org capture for CONTEXT and last MESSAGE."
  (require 'org-capture)
  (let* ((file (teams4e--capture-file))
         (entry (teams4e--summary-org-entry context message))
         (org-capture-templates
          `(("A" "Teams action" entry (file ,file) "%i\n%?"
             :empty-lines 1))))
    (make-directory (file-name-directory file) t)
    (org-capture-string entry "A")
    (message "Teams action ready to capture in %s"
             (abbreviate-file-name file))))

(defun teams4e-capture-chat-summary (chat &optional message)
  "Capture compact CHAT metadata and its last or selected MESSAGE.

Meeting chats first resolve calendar time and participants when possible.  No
message-history request is made."
  (let ((message (or message (teams4e--get chat 'lastMessagePreview))))
    (if (and (teams4e--meeting-chat-p chat)
             (not (teams4e--get chat 'meetingContext))
             (not teams4e-offline-mode))
        (progn
          (message "Loading Teams meeting details for capture...")
          (teams4e--fetch-meeting-context
           chat
           (lambda (_context)
             (teams4e--start-summary-org-capture
              (teams4e--chat-capture-context chat message) message))))
      (teams4e--start-summary-org-capture
       (teams4e--chat-capture-context chat message) message))))

(defun teams4e--thread-org-entry (context messages)
  "Return complete CONTEXT and MESSAGES as one editable Org entry."
  (let* ((title (or (teams4e--capture-context-property context 'title)
                    "Teams conversation"))
         (source-url
          (teams4e--capture-context-property context 'sourceUrl))
         (conversation-url
          (teams4e--capture-context-property context 'conversationUrl))
         (type
          (teams4e--capture-context-property context 'conversationType))
         (team (teams4e--capture-context-property context 'teamName))
         (channel
          (teams4e--capture-context-property context 'channelName)))
    (concat
     "* Teams: " title "\n"
     ":PROPERTIES:\n"
     (format ":CAPTURED: %s\n" (format-time-string "[%Y-%m-%d %a %H:%M]"))
     (mapconcat
      (lambda (mapping)
        (when-let ((value
                    (teams4e--capture-context-property
                     context (cdr mapping))))
          (format ":%s: %s\n" (car mapping) value)))
      teams4e--capture-property-map "")
     ":END:\n\n"
     (when source-url
       (concat (teams4e--org-link
                source-url "Open selected item in Microsoft Teams")
               "\n"))
     (when (and conversation-url (not (equal source-url conversation-url)))
       (concat (teams4e--org-link
                conversation-url "Open the conversation")
               "\n"))
     "\n"
     "- Conversation :: " title "\n"
     (when type (format "- Type :: %s\n" type))
     (when team (format "- Team :: %s\n" team))
     (when channel (format "- Channel :: %s\n" channel))
     (when-let ((updated
                 (teams4e--capture-context-property context 'updated)))
       (format "- Last updated :: %s\n" updated))
     "\n** Transcript\n\n"
     (mapconcat #'teams4e--message-org
                (teams4e--normalize-messages messages) ""))))

(defun teams4e--start-thread-org-capture (context messages)
  "Start an editable Org capture for complete CONTEXT MESSAGES."
  (require 'org-capture)
  (let* ((file (teams4e--capture-file))
         (entry (teams4e--thread-org-entry context messages))
         (org-capture-templates
          `(("T" "Teams thread" entry (file ,file) "%i\n%?"
             :empty-lines 1))))
    (make-directory (file-name-directory file) t)
    (org-capture-string entry "T")
    (message "Complete Teams thread ready to capture in %s"
             (abbreviate-file-name file))))

(defun teams4e-capture-chat-thread (chat &optional message)
  "Fetch and start Org capture for complete CHAT around selected MESSAGE."
  (let ((context (teams4e--chat-capture-context chat message)))
    (message "Preparing complete Teams thread for Org capture...")
    (teams4e--run-json
     (teams4e--message-args chat t)
     (lambda (payload)
       (teams4e--start-thread-org-capture
        context (teams4e--payload-list payload))))))

(defun teams4e--capture-title (message)
  "Build a concise Org heading title from MESSAGE."
  (let* ((sender (teams4e--message-sender message))
         (body (replace-regexp-in-string
                "[\n\r\t ]+" " " (teams4e--message-body message)))
         (summary (truncate-string-to-width body 72 nil nil "...")))
    (if (string-empty-p summary) sender (format "%s: %s" sender summary))))

(defun teams4e--capture-entry (chat message file)
  "Append CHAT MESSAGE as an Org entry to FILE and return its marker."
  (require 'org)
  (make-directory (file-name-directory file) t)
  (let* ((buffer (find-file-noselect file))
         (context (teams4e--chat-capture-context chat message))
         (chat-url (or (teams4e--get message 'webUrl)
                       (teams4e--get chat 'webUrl)))
         marker)
    (with-current-buffer buffer
      (unless (derived-mode-p 'org-mode) (org-mode))
      (goto-char (point-max))
      (unless (bolp) (insert "\n"))
      (unless (= (point-min) (point-max)) (insert "\n"))
      (setq marker (copy-marker (point)))
      (insert "* " (teams4e--capture-title message) "\n")
      (org-entry-put nil "CAPTURED"
                     (teams4e--org-date
                      (or (teams4e--get message 'createdDateTime) "")))
      (org-entry-put nil "TEAMS_CREATED"
                     (teams4e--capture-one-line
                      (or (teams4e--get message 'createdDateTime) "")))
      (org-entry-put nil "TEAMS_SENDER"
                     (teams4e--message-sender message))
      (dolist (mapping teams4e--capture-property-map)
        (when-let ((value
                    (teams4e--capture-context-property
                     context (cdr mapping))))
          (org-entry-put nil (car mapping) value)))
      (when chat-url (org-entry-put nil "TEAMS_URL" chat-url))
      (org-end-of-meta-data t)
      (insert (teams4e--message-body message) "\n")
      (when chat-url
        (insert "\n[[" chat-url "][Open in Microsoft Teams]]\n"))
      (save-buffer))
    marker))

;;;###autoload
(defun teams4e-capture-message ()
  "Capture the Teams message at point into the configured Org inbox."
  (interactive)
  (unless (derived-mode-p 'teams4e-chat-mode)
    (user-error "Capture works from a Teams chat transcript"))
  (let ((message (teams4e-message-at-point))
        (chat teams4e--chat)
        (file (teams4e--capture-file)))
    (unless message (user-error "Move point onto a Teams message first"))
    (let ((marker (teams4e--capture-entry chat message file)))
      (pop-to-buffer (marker-buffer marker))
      (goto-char marker)
      (message "Captured Teams message in %s" (abbreviate-file-name file)))))

;; Short command names requested for day-to-day use.
(defalias 'teams #'teams4e-inbox)
(defalias 'teams-inbox #'teams4e-inbox)
(defalias 'teams-chat #'teams4e-chat)
(defalias 'teams-recent #'teams4e-recent)
(defalias 'teams-send #'teams4e-send)
(defalias 'teams-export-thread #'teams4e-export-thread)
(defalias 'teams-copy-thread-markdown
  #'teams4e-copy-thread-markdown)
(defalias 'teams-capture-message #'teams4e-capture-message)

(provide 'teams4e-ui)

;;; teams4e-ui.el ends here
