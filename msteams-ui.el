;;; msteams-ui.el --- Native Microsoft Teams user interface. -*- lexical-binding: t; -*-
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
(require 'msteams-config)
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
(declare-function msteams-capture-current-thread "advanced")
(declare-function msteams-bulk-action "advanced")
(declare-function msteams-toggle-selection "advanced")
(declare-function msteams-toggle-visible-selections "advanced")
(declare-function msteams-toggle-unread-filter "advanced")
(declare-function msteams--refresh-current-view "advanced")
(declare-function msteams--render-channel-thread "advanced")
(declare-function msteams-thread-next "advanced")
(declare-function msteams-thread-previous "advanced")
(declare-function msteams-mark-read-later "advanced")
(declare-function msteams-message-forward "advanced")

(defvar org-capture-templates)

;; Defined as user options in config.el; declarations keep standalone byte
;; compilation useful without duplicating defaults.
(defvar msteams-bootstrap-program)
(defvar msteams-credentials-file)
(defvar msteams-token-command)
(defvar msteams-credential-server-name)
(defvar msteams-credential-server-url)
(defvar msteams-use-persistent-backend)
(defvar msteams-mock-mode)
(defvar msteams-mock-state-file)
(defvar msteams-capture-file)
(defvar msteams-cache-file)
(defvar msteams-cache-first)
(defvar msteams-app-command)
(defvar msteams-browser-command)
(defvar msteams-chat-metadata-limit)
(defvar msteams-confirm-send)
(defvar msteams-default-content-type)
(defvar msteams-default-view)
(defvar msteams-display-images)
(defvar msteams-draft-directory)
(defvar msteams-export-directory)
(defvar msteams-image-cache-directory)
(defvar msteams-image-download-concurrency)
(defvar msteams-image-max-height)
(defvar msteams-image-max-width)
(defvar msteams-index-width)
(defvar msteams-mark-read-on-open)
(defvar msteams-member-enrichment-concurrency)
(defvar msteams-member-enrichment-limit)
(defvar msteams-meeting-enrichment-concurrency)
(defvar msteams-meeting-enrichment-limit)
(defvar msteams-load-more-count)
(defvar msteams-message-days)
(defvar msteams-message-limit)
(defvar msteams-message-order)
(defvar msteams-offline-mode)
(defvar msteams-preview-delay)
(defvar msteams-preview-cache-seconds)
(defvar msteams-preview-message-limit)
(defvar msteams-preview-on-move)
(defvar msteams-state-file)
(defvar msteams-status-style)

(defvar msteams--process-sequence 0)
(defvar msteams--server-sequence 0)
(defvar msteams--server-process nil)
(defvar msteams--server-fingerprint nil)
(defvar msteams--server-pending (make-hash-table :test #'eql))
(defconst msteams--server-stdout-noise-limit 8
  "Maximum consecutive non-protocol stdout lines tolerated from the server.")

(cl-defstruct (msteams-request
               (:constructor msteams--make-request (id)))
  "Handle for one request sent through the persistent backend transport."
  id
  cancelled)
(defvar msteams--chats nil)
(defvar msteams--active-view nil)
(defvar msteams--active-query nil)
(defvar msteams--active-filter-name nil)

(defun msteams--default-view ()
  "Return the configured default inbox view, falling back to inbox."
  (if (boundp 'msteams-default-view)
      msteams-default-view
    'inbox))

(defun msteams--ensure-active-view ()
  "Initialize `msteams--active-view' from config when unset."
  (unless msteams--active-view
    (setq msteams--active-view (msteams--default-view))))
(defvar msteams--connected-as nil)
(defvar msteams--connected-user-id nil)
(defvar msteams--member-cache (make-hash-table :test #'equal))
(defvar msteams--member-inflight (make-hash-table :test #'equal))
(defvar msteams--meeting-inflight (make-hash-table :test #'equal))
(defconst msteams--no-members 'msteams--no-members)
(defvar msteams--favorites (make-hash-table :test #'equal))
(defvar msteams--muted (make-hash-table :test #'equal))
(defvar msteams--handled (make-hash-table :test #'equal))
(defvar msteams--snoozed (make-hash-table :test #'equal))
(defvar msteams--saved-views (make-hash-table :test #'equal))
(defvar msteams--captured-chat-table (make-hash-table :test #'equal)
  "Ephemeral chat-ID snapshot derived from the configured Org capture file.")
(defvar msteams--captured-chat-signature nil
  "File signature used to invalidate the ephemeral Org capture snapshot.")
(defvar msteams--captured-chat-checked-at 0.0
  "Time when the Org capture snapshot last checked its source signature.")
(defconst msteams--captured-chat-check-seconds 5.0
  "Minimum interval between capture-file metadata checks during redraws.")
(defvar msteams--read-overrides (make-hash-table :test #'equal))
(defvar msteams--state-loaded nil)
(defvar msteams--window-configurations
  (make-hash-table :test #'eq :weakness 'key)
  "Window configurations saved before entering the Teams workspace.")
(defvar msteams--inhibit-reader-follow nil
  "Non-nil while a reader command is deliberately managing headers itself.")
(defconst msteams--recent-buffer-name "*Teams Recent*")
(defconst msteams--read-buffer-name "*Teams Read*")
(defconst msteams--preview-buffer-name msteams--read-buffer-name
  "Compatibility name for the singleton Teams reader.")
(defconst msteams--channel-preview-buffer-name
  msteams--read-buffer-name
  "Compatibility name for the singleton Teams reader.")
(defconst msteams--error-buffer-name "*M365 Errors*")
(defconst msteams--recent-format
  [("Status" 6 nil)
   ("Updated" 16 t)
   ("Type" 8 t)
   ("Conversation" 28 t)
   ("Meeting" 30 t)
   ("Star" 4 nil)
   ("Last message" 0 nil)]
  "Aligned columns used by the native Teams inbox.")

(defvar-local msteams--process nil)
(defvar-local msteams--chat nil)
(defvar-local msteams--messages nil)
(defvar-local msteams--loaded-at nil)
(defvar-local msteams--loaded-update nil)
(defvar-local msteams--loaded-all nil)
(defvar-local msteams--message-order nil)
(defvar-local msteams--request-id 0)
(defvar-local msteams--preview-timer nil)
(defvar-local msteams--inbox-source-label nil)
(defvar-local msteams--automatic-preview-p nil)
(defvar-local msteams--pending-message-id nil)
(defvar-local msteams--jump-to-bottom-on-render nil)
(defvar-local msteams--meeting-context nil)
(defvar-local msteams--meeting-process nil)
(defvar-local msteams--meeting-request-id 0)
(defvar-local msteams--image-processes nil)
(defvar-local msteams--image-queue nil)
(defvar-local msteams--image-active 0)
(defvar-local msteams-compose--target nil)
(defvar-local msteams-compose--origin nil)
(defvar-local msteams-compose--reply-to nil)
(defvar-local msteams-compose--attachments nil)
(defvar-local msteams-compose--mentions nil)
(defvar-local msteams-compose--content-type "text")
(defvar-local msteams-compose--draft-timer nil)
(defvar-local msteams-compose--draft-file nil)
(defvar msteams--cache-first-open nil
  "Dynamically bound while a newly selected chat performs its initial load.")

;; Defined by advanced.el; declarations keep the shared message renderer able
;; to resolve relative hosted-content URLs in channel thread buffers.
(defvar msteams-channel--team)
(defvar msteams-channel--channel)
(defvar msteams-channel--root)

(defface msteams-own-sender
  '((t :inherit success :weight semi-bold))
  "Face for the signed-in user's message header."
  :group 'msteams)

(defface msteams-other-sender
  '((t :inherit font-lock-keyword-face :weight semi-bold))
  "Face for another participant's message header."
  :group 'msteams)

(defface msteams-unread
  '((t :weight bold))
  "Face for unread chat rows."
  :group 'msteams)

(defface msteams-type-direct
  '((t :inherit font-lock-keyword-face :weight semi-bold))
  "Face for one-to-one Teams chat labels."
  :group 'msteams)

(defface msteams-type-group
  '((t :inherit font-lock-function-name-face :weight semi-bold))
  "Face for group Teams chat labels."
  :group 'msteams)

(defface msteams-type-meeting
  '((t :inherit font-lock-warning-face :weight semi-bold))
  "Face for meeting Teams chat labels."
  :group 'msteams)

(defface msteams-type-channel
  '((t :inherit success :weight semi-bold))
  "Face for Teams channel labels."
  :group 'msteams)

;; Recalculate existing frames when this layer is reloaded in a live session.
(face-spec-set 'msteams-unread '((t :weight bold))
               'face-defface-spec)

(defface msteams-day-separator
  '((t :inherit shadow :weight bold :overline t))
  "Face for transcript date separators."
  :group 'msteams)

(defface msteams-event
  '((t :inherit shadow :slant italic))
  "Face for readable Teams system-event summaries."
  :group 'msteams)

(defface msteams-image-label
  '((t :inherit link :weight semi-bold))
  "Face for inline Teams image labels."
  :group 'msteams)

(defun msteams--executable ()
  "Resolve the configured passive Graph backend executable."
  (let* ((configured (and (boundp 'msteams-backend-program)
                          msteams-backend-program))
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
         (concat "The msteams Graph backend is unavailable; check "
                 "`msteams-backend-program`")))))

(defun msteams--configure-process-environment ()
  "Configure the current dynamic subprocess environment for Graph access."
  (setenv "MSTEAMS_TOKEN_COMMAND"
          (and msteams-token-command (json-encode msteams-token-command)))
  (setenv "MSTEAMS_CREDENTIALS"
          (expand-file-name msteams-credentials-file))
  (setenv "MSTEAMS_BOOTSTRAP_COMMAND" msteams-bootstrap-program)
  (setenv "MSTEAMS_CREDENTIAL_SERVER_NAME" msteams-credential-server-name)
  (setenv "MSTEAMS_CREDENTIAL_SERVER_URL" msteams-credential-server-url)
  (setenv "MSTEAMS_CACHE" (expand-file-name msteams-cache-file))
  (setenv "MSTEAMS_MOCK" (if msteams-mock-mode "1" nil))
  (setenv "MSTEAMS_MOCK_STATE"
          (and msteams-mock-mode
               (expand-file-name msteams-mock-state-file))))

(defun msteams--redacted-args (args)
  "Return ARGS with message bodies hidden for diagnostics."
  (let (result redact-next)
    (dolist (arg args (nreverse result))
      (push (if redact-next "<message redacted>" arg) result)
      (setq redact-next (equal arg "--message")))))

(defun msteams--command-string (args)
  "Return a shell-quoted diagnostic command for ARGS."
  (mapconcat #'shell-quote-argument
             (cons (msteams--executable) (msteams--redacted-args args))
             " "))

(defun msteams--redacted-detail (args detail)
  "Remove the exact outgoing message in ARGS from diagnostic DETAIL."
  (let ((message-args (member "--message" args)))
    (if (and (stringp detail) (stringp (cadr message-args))
             (not (string-empty-p (cadr message-args))))
        (replace-regexp-in-string
         (regexp-quote (cadr message-args)) "<message redacted>" detail t t)
      detail)))

(defun msteams--report-error (args status detail)
  "Record a failed Teams backend invocation of ARGS with STATUS and DETAIL."
  (let ((buffer (get-buffer-create msteams--error-buffer-name)))
    (with-current-buffer buffer
      (goto-char (point-max))
      (insert (format-time-string "[%Y-%m-%d %H:%M:%S] "))
      (insert (format "exit %s: %s\n" status (msteams--command-string args)))
      (setq detail (msteams--redacted-detail args detail))
      (unless (string-empty-p (string-trim detail))
        (insert (string-trim-right detail) "\n"))
      (insert "\n"))
    (display-buffer buffer)
    (message "Teams Graph command failed; see %s" msteams--error-buffer-name)))

(defun msteams--cancel-process (process)
  "Cancel PROCESS or persistent request without reporting a failure."
  (cond
   ((and (processp process) (process-live-p process))
    (process-put process 'msteams-cancelled t)
    (delete-process process))
   ((msteams-request-p process)
    (setf (msteams-request-cancelled process) t)
    (remhash (msteams-request-id process) msteams--server-pending))))

(defun msteams--request-live-p (request)
  "Return non-nil while REQUEST can still deliver a backend callback."
  (cond
   ((processp request) (process-live-p request))
   ((msteams-request-p request)
    (and (not (msteams-request-cancelled request))
         (gethash (msteams-request-id request)
                  msteams--server-pending)))
   (t nil)))

(cl-defun msteams--run (args callback &optional error-callback)
  "Run the Teams Graph backend with ARGS asynchronously.

CALLBACK receives standard output after a successful exit.  ERROR-CALLBACK,
when non-nil, receives the exit status and combined diagnostic text."
  (let* ((program (msteams--executable))
         (sequence (cl-incf msteams--process-sequence))
         (stdout (generate-new-buffer (format " *m365-%d-out*" sequence)))
         (stderr (generate-new-buffer (format " *m365-%d-err*" sequence)))
         (process-environment (copy-sequence process-environment))
         (program-dir (file-name-directory program))
         process)
    (msteams--configure-process-environment)
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
                      (cancelled (process-get proc 'msteams-cancelled))
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
                               (msteams--report-error args status detail)))
                         (error
                          (msteams--report-error
                           args "callback"
                           (error-message-string callback-error)))))
                   (when (buffer-live-p stdout) (kill-buffer stdout))
                   (when (buffer-live-p stderr) (kill-buffer stderr))))))))
    process))

(defun msteams--args-prefix-p (prefix args)
  "Return non-nil when string list ARGS begins with PREFIX."
  (equal prefix (seq-take args (length prefix))))

(defun msteams--persistent-command-p (program args)
  "Return non-nil when PROGRAM can safely serve ARGS persistently."
  (and msteams-use-persistent-backend
       (string-equal (file-name-nondirectory program)
                     "msteams-graph")
       (or
        (msteams--args-prefix-p '("status") args)
        (and (msteams--args-prefix-p '("teams" "cache") args)
             (not (msteams--args-prefix-p
                   '("teams" "cache" "clear") args)))
        (msteams--args-prefix-p '("teams" "sync") args)
        (msteams--args-prefix-p '("teams" "search") args)
        (msteams--args-prefix-p '("teams" "meeting") args)
        (msteams--args-prefix-p '("teams" "team" "list") args)
        (msteams--args-prefix-p '("teams" "channel" "list") args)
        (msteams--args-prefix-p '("teams" "channel" "message" "list") args)
        (msteams--args-prefix-p '("teams" "channel" "reply" "list") args)
        (msteams--args-prefix-p '("teams" "user" "search") args)
        (msteams--args-prefix-p '("teams" "user" "profile") args)
        (msteams--args-prefix-p '("teams" "user" "presence") args)
        (msteams--args-prefix-p '("teams" "chat" "list") args)
        (msteams--args-prefix-p '("teams" "chat" "get") args)
        (msteams--args-prefix-p
         '("teams" "chat" "member" "batch") args)
        (msteams--args-prefix-p
         '("teams" "chat" "member" "list") args)
        (msteams--args-prefix-p '("teams" "chat" "message" "list") args))))

(defun msteams--current-server-fingerprint (program)
  "Return the non-secret configuration fingerprint for PROGRAM."
  (list (file-truename program)
        (expand-file-name msteams-credentials-file)
        msteams-bootstrap-program
        (expand-file-name msteams-cache-file)
        msteams-mock-mode
        (and msteams-mock-mode
             (expand-file-name msteams-mock-state-file))))

(defun msteams--fail-server-requests (server detail)
  "Fail pending requests owned by SERVER with DETAIL."
  (let (ids)
    (maphash
     (lambda (id pending)
       (when (eq server (plist-get pending :server))
         (push id ids)))
     msteams--server-pending)
    (dolist (id ids)
      (when-let ((pending (gethash id msteams--server-pending)))
        (remhash id msteams--server-pending)
        (let ((request (plist-get pending :request))
              (error-callback (plist-get pending :error-callback))
              (args (plist-get pending :args)))
          (unless (msteams-request-cancelled request)
            (if error-callback
                (funcall error-callback "server" detail)
              (msteams--report-error args "server" detail))))))))

(defun msteams--stop-server (&optional detail)
  "Stop the persistent backend and optionally fail requests with DETAIL."
  (when-let ((server msteams--server-process))
    (setq msteams--server-process nil
          msteams--server-fingerprint nil)
    (process-put server 'msteams-intentional-stop t)
    (when detail (msteams--fail-server-requests server detail))
    (unless detail
      (let (ids)
        (maphash
         (lambda (id pending)
           (when (eq server (plist-get pending :server)) (push id ids)))
         msteams--server-pending)
        (dolist (id ids) (remhash id msteams--server-pending))))
    (when (process-live-p server) (delete-process server))
    (when-let ((stderr (process-get server 'msteams-stderr-buffer)))
      (when (buffer-live-p stderr) (kill-buffer stderr)))))

(defun msteams--server-line-preview (line)
  "Return a bounded, token-redacted diagnostic preview of LINE."
  (let* ((redacted
          (replace-regexp-in-string
           "eyJ[[:alnum:]_.-]+" "<token redacted>" line t t))
         (quoted (prin1-to-string redacted)))
    (truncate-string-to-width quoted 240 nil nil "...")))

(defun msteams--record-server-stdout-noise (server text)
  "Record non-protocol stdout TEXT from SERVER and return whether to continue."
  (let* ((count (1+ (or (process-get server 'msteams-stdout-noise-count) 0)))
         (preview (msteams--server-line-preview text)))
    (process-put server 'msteams-stdout-noise-count count)
    (with-current-buffer (get-buffer-create msteams--error-buffer-name)
      (goto-char (point-max))
      (insert (format-time-string "[%Y-%m-%d %H:%M:%S] "))
      (insert (format "[warning] ignored persistent backend stdout: %s\n\n"
                      preview)))
    (if (> count msteams--server-stdout-noise-limit)
        (progn
          (msteams--stop-server
           (format "Persistent backend emitted too much non-JSON stdout; last line: %s"
                   preview))
          nil)
      t)))

(defun msteams--dispatch-server-line (server line)
  "Extract and dispatch one protocol response from SERVER output LINE.

Python startup hooks can write a banner before the backend owns stdout.  Ignore
and record that bounded noise; if an envelope is glued to it, retain the JSON
suffix beginning with its top-level ID field."
  (let* ((line (string-trim line))
         (response-start
          (string-match "{[[:space:]]*\"id\"[[:space:]]*:" line)))
    (if (not response-start)
        (unless (string-empty-p line)
          (msteams--record-server-stdout-noise server line))
      (let ((prefix (substring line 0 response-start)))
        (when (or (string-empty-p prefix)
                  (msteams--record-server-stdout-noise server prefix))
          (msteams--handle-server-response
           server (substring line response-start)))))))

(defun msteams--handle-server-response (server line)
  "Dispatch one persistent SERVER response encoded by LINE."
  (condition-case parse-error
      (let* ((response
              (json-parse-string line :object-type 'alist :array-type 'list
                                 :null-object nil :false-object nil))
             (id (msteams--get response 'id))
             (pending (and (integerp id)
                           (gethash id msteams--server-pending))))
        (process-put server 'msteams-stdout-noise-count 0)
        (when pending
          (remhash id msteams--server-pending)
          (let ((request (plist-get pending :request))
                (callback (plist-get pending :callback))
                (error-callback (plist-get pending :error-callback))
                (args (plist-get pending :args)))
            (unless (msteams-request-cancelled request)
              (condition-case callback-error
                  (if (msteams--get response 'ok)
                      (when callback
                        (funcall callback (msteams--get response 'result)))
                    (let ((detail (or (msteams--get response 'error)
                                      "Persistent backend request failed")))
                      (if error-callback
                          (funcall error-callback "server" detail)
                        (msteams--report-error args "server" detail))))
                (error
                 (msteams--report-error
                  args "callback" (error-message-string callback-error))))))))
    (error
     (msteams--stop-server
      (format "Invalid persistent backend JSON %s: %s"
              (msteams--server-line-preview line)
              (error-message-string parse-error))))))

(defun msteams--server-filter (server chunk)
  "Accumulate and dispatch newline-delimited responses from SERVER CHUNK."
  (let* ((data (concat (or (process-get server 'msteams-partial) "") chunk))
         (start 0))
    (while (string-match "\n" data start)
      (let ((line (substring data start (match-beginning 0)))
            (next-start (match-end 0)))
        (unless (string-empty-p (string-trim line))
          (msteams--dispatch-server-line server line))
        ;; Dispatch and user callbacks may run regexp searches of their own.
        (setq start next-start)))
    (process-put server 'msteams-partial (substring data start))))

(defun msteams--server-sentinel (server _event)
  "Handle termination of persistent backend SERVER."
  (when (memq (process-status server) '(exit signal))
    (let* ((stderr-buffer (process-get server 'msteams-stderr-buffer))
           (stderr (and (buffer-live-p stderr-buffer)
                        (with-current-buffer stderr-buffer (buffer-string))))
           (intentional (process-get server 'msteams-intentional-stop)))
      (when (eq server msteams--server-process)
        (setq msteams--server-process nil
              msteams--server-fingerprint nil))
      (unless intentional
        (msteams--fail-server-requests
         server
         (if (string-empty-p (string-trim (or stderr "")))
             "Persistent backend exited unexpectedly"
           (string-trim stderr))))
      (when (buffer-live-p stderr-buffer) (kill-buffer stderr-buffer)))))

(defun msteams--ensure-server (program)
  "Return a live persistent backend for PROGRAM and current configuration."
  (let ((fingerprint (msteams--current-server-fingerprint program)))
    (unless (and (processp msteams--server-process)
                 (process-live-p msteams--server-process)
                 (equal fingerprint msteams--server-fingerprint))
      (msteams--stop-server)
      (let* ((process-environment (copy-sequence process-environment))
             (program-dir (file-name-directory program))
             (stderr (generate-new-buffer " *m365-server-errors*")))
        (msteams--configure-process-environment)
        (setenv "PATH" (concat program-dir path-separator
                                (or (getenv "PATH") "")))
        (setq msteams--server-process
              (make-process
               :name "m365-server"
               :buffer nil
               :stderr stderr
               :command (list program "serve")
               :coding 'utf-8-unix
               :connection-type 'pipe
               :noquery t
               :filter #'msteams--server-filter
               :sentinel #'msteams--server-sentinel)
              msteams--server-fingerprint fingerprint)
        (process-put msteams--server-process
                     'msteams-stderr-buffer stderr)))
    msteams--server-process))

(defun msteams--run-json-persistent
    (program args callback &optional error-callback)
  "Send ARGS through persistent PROGRAM and invoke parsed JSON CALLBACK."
  (let* ((server (msteams--ensure-server program))
         (id (cl-incf msteams--server-sequence))
         (request (msteams--make-request id)))
    (puthash id
             (list :request request :server server :args args
                   :callback callback :error-callback error-callback)
             msteams--server-pending)
    (condition-case send-error
        (process-send-string
         server
         (concat
          (json-serialize `((id . ,id) (args . ,(vconcat args))))
          "\n"))
      (error
       (remhash id msteams--server-pending)
       (msteams--stop-server)
       (signal (car send-error) (cdr send-error))))
    request))

(defun msteams--run-json-once (args callback &optional error-callback)
  "Run one-shot backend ARGS and pass parsed JSON to CALLBACK."
  (msteams--run
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
          (msteams--report-error
           args "JSON" (error-message-string parse-error))))))
   error-callback))

(defun msteams--run-json (args callback &optional error-callback)
  "Run the Teams backend with ARGS and pass parsed JSON to CALLBACK.

ERROR-CALLBACK has the same contract as in `msteams--run'."
  (let ((json-args (if (member "--output" args)
                       args
                     (append args '("--output" "json"))))
        (program (msteams--executable)))
    (if (msteams--persistent-command-p program json-args)
        (condition-case nil
            (msteams--run-json-persistent
             program json-args callback error-callback)
          (error
           (msteams--run-json-once json-args callback error-callback)))
      (msteams--run-json-once json-args callback error-callback))))

(defun msteams--get (object key)
  "Read KEY from JSON alist OBJECT using symbol or string keys."
  (when (listp object)
    (or (alist-get key object)
        (alist-get (if (symbolp key) (symbol-name key) key)
                   object nil nil #'equal))))

(defun msteams--dig (object &rest keys)
  "Read nested KEYS from JSON alist OBJECT."
  (dolist (key keys object)
    (setq object (msteams--get object key))))

(defun msteams--payload-list (payload)
  "Normalize an array or Graph-style value wrapper in PAYLOAD."
  (cond
   ((vectorp payload) (append payload nil))
   ((msteams--get payload 'value)
    (msteams--payload-list (msteams--get payload 'value)))
   ((null payload) nil)
   ;; A JSON array parsed as a list begins with an alist, whose first item is
   ;; itself a cons.  A single JSON object begins directly with a key/value.
   ((and (listp payload) (consp (car payload)) (consp (caar payload))) payload)
   (t (list payload))))

(defun msteams--format-date (value &optional long)
  "Format ISO date VALUE for display, using LONG format when requested."
  (if (not (and (stringp value) (not (string-empty-p value))))
      ""
    (condition-case nil
        (format-time-string (if long "%Y-%m-%d %H:%M" "%b %e %H:%M")
                            (date-to-time value))
      (error value))))

(defun msteams--org-date (value)
  "Format ISO date VALUE as an inactive Org timestamp."
  (condition-case nil
      (format-time-string "[%Y-%m-%d %a %H:%M]" (date-to-time value))
    (error (format-time-string "[%Y-%m-%d %a %H:%M]"))))

(defun msteams--html-to-text (html)
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

(defun msteams--event-detail-type (message)
  "Return MESSAGE's short Graph system-event detail type."
  (when-let* ((detail (msteams--get message 'eventDetail))
              (odata-type (msteams--get detail (intern "@odata.type")))
              ((stringp odata-type)))
    (string-remove-suffix
     "EventMessageDetail"
     (car (last (split-string odata-type "\\." t))))))

(defun msteams--event-identity-name (identity)
  "Return the best display name represented by event IDENTITY."
  (or (msteams--dig identity 'user 'displayName)
      (msteams--dig identity 'application 'displayName)
      (msteams--dig identity 'device 'displayName)
      (msteams--get identity 'displayName)))

(defun msteams--event-member-names (detail)
  "Return display names from a Graph event DETAIL member collection."
  (delq nil
        (mapcar #'msteams--event-identity-name
                (msteams--payload-list
                 (msteams--get detail 'members)))))

(defun msteams--format-duration (duration)
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

(defun msteams--humanize-event-type (type)
  "Turn Graph event TYPE camel case into a readable label."
  (let ((case-fold-search nil))
    (capitalize
     (replace-regexp-in-string
      "\\([[:lower:][:digit:]]\\)\\([[:upper:]]\\)" "\\1 \\2"
      (or type "System event")))))

(defun msteams--event-summary (message)
  "Return a useful human-readable summary for a system MESSAGE."
  (let* ((detail (msteams--get message 'eventDetail))
         (type (msteams--event-detail-type message))
         (call-kind
          (pcase (msteams--get detail 'callEventType)
            ("meeting" "Meeting")
            ("screenShare" "Screen share")
            (_ "Call")))
         (initiator
          (msteams--event-identity-name
           (msteams--get detail 'initiator)))
         (members (msteams--event-member-names detail))
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
            (_ (msteams--humanize-event-type type)))))
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
                             (msteams--get detail 'callDuration))))
         (format " (%s)" (msteams--format-duration duration))
       "")
     (cond
      ((and (equal type "chatRenamed")
            (msteams--get detail 'chatDisplayName))
       (format ": %s" (msteams--get detail 'chatDisplayName)))
      ((and (equal type "channelRenamed")
            (msteams--get detail 'channelDisplayName))
       (format ": %s" (msteams--get detail 'channelDisplayName)))
      ((and (equal type "teamRenamed")
            (msteams--get detail 'teamDisplayName))
       (format ": %s" (msteams--get detail 'teamDisplayName)))
      (t "")))))

(defun msteams--system-event-p (message)
  "Return non-nil when MESSAGE represents a Teams system event."
  (or (equal (msteams--get message 'messageType) "systemEventMessage")
      (msteams--get message 'eventDetail)
      (equal (msteams--dig message 'body 'content)
             "<systemEventMessage/>")))

(defun msteams--message-body (message)
  "Return a readable body for Teams MESSAGE."
  (let ((content (msteams--dig message 'body 'content)))
    (cond
     ((msteams--get message 'deletedDateTime) "[Deleted message]")
     ((msteams--system-event-p message)
      (msteams--event-summary message))
     ((and (stringp content) (not (string-empty-p content)))
      (msteams--html-to-text content))
     ((msteams--get message 'subject))
     ((msteams--get message 'summary))
     (t ""))))

(defun msteams--message-sender (message)
  "Return a useful sender label for Teams MESSAGE."
  (or (msteams--dig message 'from 'user 'displayName)
      (msteams--dig message 'from 'application 'displayName)
      "Teams"))

(defun msteams--chat-id (chat)
  "Return CHAT's identifier."
  (unless (and (listp chat) (keywordp (car chat)))
    (msteams--get chat 'id)))

(defun msteams--short-id (chat)
  "Return a stable short identifier for CHAT."
  (substring (md5 (or (msteams--chat-id chat) "unknown")) 0 8))

(defun msteams--load-state ()
  "Load non-secret local Teams UI state once per Emacs session."
  (unless msteams--state-loaded
    (setq msteams--state-loaded t
          msteams--favorites (make-hash-table :test #'equal)
          msteams--muted (make-hash-table :test #'equal)
          msteams--handled (make-hash-table :test #'equal)
          msteams--snoozed (make-hash-table :test #'equal)
          msteams--saved-views (make-hash-table :test #'equal))
    (when (file-readable-p msteams-state-file)
      (condition-case error-data
          (let* ((payload
                  (json-parse-string
                   (with-temp-buffer
                     (insert-file-contents msteams-state-file)
                     (buffer-string))
                   :object-type 'alist :array-type 'list))
                 (favorites (msteams--get payload 'favorites))
                 (muted (msteams--get payload 'muted))
                 (handled (msteams--get payload 'handled))
                 (snoozed (msteams--get payload 'snoozed))
                 (saved-views (msteams--get payload 'savedViews)))
            (dolist (chat-id favorites)
              (when (stringp chat-id)
                (puthash chat-id t msteams--favorites)))
            (dolist (chat-id muted)
              (when (stringp chat-id)
                (puthash chat-id t msteams--muted)))
            (dolist (item handled)
              (let ((chat-id (msteams--get item 'chatId))
                    (marker (msteams--get item 'marker)))
                (when (and (stringp chat-id) (stringp marker))
                  (puthash chat-id marker msteams--handled))))
            (dolist (item snoozed)
              (let ((chat-id (msteams--get item 'chatId))
                    (until (msteams--get item 'until)))
                (when (and (stringp chat-id) (stringp until))
                  (puthash chat-id until msteams--snoozed))))
            (dolist (view saved-views)
              (let ((name (or (msteams--get view 'name)
                              (car-safe view)))
                    (query (or (msteams--get view 'query)
                               (cdr-safe view))))
                (when (and (or (symbolp name) (stringp name))
                           (stringp query))
                  (puthash (if (symbolp name) (symbol-name name) name)
                           query msteams--saved-views)))))
        (error
         (message "Ignoring invalid Teams state file: %s"
                  (error-message-string error-data)))))))

(defun msteams--save-state ()
  "Persist local Teams UI state atomically with private permissions."
  (let* ((file (expand-file-name msteams-state-file))
         (directory (file-name-directory file))
         favorites muted handled snoozed saved-views)
    (make-directory directory t)
    (let ((temporary
           (make-temp-file (expand-file-name ".teams-state-" directory))))
      (maphash (lambda (chat-id enabled)
                 (when enabled (push chat-id favorites)))
               msteams--favorites)
      (maphash (lambda (chat-id enabled)
                 (when enabled (push chat-id muted)))
               msteams--muted)
      (maphash (lambda (chat-id marker)
                 (when (and (stringp chat-id) (stringp marker))
                   (push `((chatId . ,chat-id) (marker . ,marker)) handled)))
               msteams--handled)
      (maphash (lambda (chat-id until)
                 (when (and (stringp chat-id) (stringp until))
                   (push `((chatId . ,chat-id) (until . ,until)) snoozed)))
               msteams--snoozed)
      (maphash (lambda (name query)
                 (push `((name . ,name) (query . ,query)) saved-views))
               msteams--saved-views)
      (let ((record-less-p
             (lambda (left right)
               (string< (msteams--get left 'chatId)
                        (msteams--get right 'chatId))))
            (sorted-views
             (sort saved-views
                   (lambda (left right)
                     (string< (msteams--get left 'name)
                              (msteams--get right 'name))))))
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

(defun msteams--favorite-p (chat)
  "Return non-nil when CHAT is a local favorite."
  (msteams--load-state)
  (gethash (msteams--chat-id chat) msteams--favorites))

(defun msteams--server-suppressed-p (chat)
  "Return non-nil when Graph marks CHAT hidden or muted.

Microsoft Graph documents `viewpoint.isHidden'.  The `isMuted' checks are
best-effort compatibility with tenants that include a richer viewpoint."
  (or (msteams--dig chat 'viewpoint 'isHidden)
      (msteams--dig chat 'viewpoint 'isMuted)
      (msteams--get chat 'isMuted)
      (msteams--get chat 'isHiddenForAllMembers)))

(defun msteams--muted-p (chat)
  "Return non-nil when CHAT is suppressed from the relevant inbox."
  (msteams--load-state)
  (or (gethash (msteams--chat-id chat) msteams--muted)
      (msteams--server-suppressed-p chat)))

(defun msteams--chat-marker (chat)
  "Return CHAT's current stable marker for handled-until-new state."
  (or (msteams--dig chat 'lastMessagePreview 'id)
      (msteams--get chat 'lastUpdatedDateTime)
      (msteams--chat-id chat)))

(defun msteams--handled-p (chat)
  "Return non-nil when CHAT is handled and no newer message has appeared."
  (msteams--load-state)
  (let ((stored (gethash (msteams--chat-id chat)
                         msteams--handled)))
    (and (stringp stored)
         (equal stored (msteams--chat-marker chat)))))

(defun msteams--snoozed-until (chat)
  "Return CHAT's active snooze expiry string, or nil when it has expired."
  (msteams--load-state)
  (let ((until (gethash (msteams--chat-id chat)
                        msteams--snoozed)))
    (and (stringp until)
         (condition-case nil
             (time-less-p (current-time) (date-to-time until))
           (error nil))
         until)))

(defun msteams--snoozed-p (chat)
  "Return non-nil when CHAT has an active local snooze."
  (not (null (msteams--snoozed-until chat))))

(defun msteams--triaged-p (chat)
  "Return non-nil when CHAT is locally handled or snoozed."
  (or (msteams--handled-p chat)
      (msteams--snoozed-p chat)))

(defun msteams--last-message (chat)
  "Return CHAT's last message preview object."
  (msteams--get chat 'lastMessagePreview))

(defun msteams--mentioned-user-p (message)
  "Return non-nil when MESSAGE explicitly mentions the connected user."
  (seq-some
   (lambda (mention)
     (let ((user-id (msteams--dig mention 'mentioned 'user 'id))
           (text (or (msteams--get mention 'mentionText) "")))
       (or (and (stringp user-id)
                (stringp msteams--connected-user-id)
                (equal user-id msteams--connected-user-id))
           (and (stringp msteams--connected-as)
                (string-match-p
                 (regexp-quote msteams--connected-as) text)))))
   (msteams--get message 'mentions)))

(defun msteams--reply-to-own-p (message)
  "Return non-nil when MESSAGE quotes a message sent by the connected user."
  (when-let ((reference (msteams--message-reference message)))
    (let ((sender-id (msteams--dig reference 'messageSender 'user 'id))
          (sender-name
           (msteams--dig reference 'messageSender 'user 'displayName)))
      (or (and (stringp sender-id)
               (stringp msteams--connected-user-id)
               (equal sender-id msteams--connected-user-id))
          (and (stringp sender-name)
               (stringp msteams--connected-as)
               (string-equal sender-name msteams--connected-as))))))

(defun msteams--important-p (message)
  "Return non-nil when MESSAGE has high or urgent Graph importance."
  (member (downcase (or (msteams--get message 'importance) "normal"))
          '("high" "urgent")))

(defun msteams--attention-p (chat)
  "Return non-nil when CHAT has an unread, mention, reply, or priority signal."
  (let ((message (msteams--last-message chat)))
    (or (msteams--unread-p chat)
        (msteams--mentioned-user-p message)
        (msteams--reply-to-own-p message)
        (msteams--important-p message))))

(defun msteams--message-own-p (message)
  "Return non-nil when MESSAGE was sent by the connected account."
  (let ((sender-id (msteams--dig message 'from 'user 'id))
        (sender-name (msteams--message-sender message)))
    (or (and (stringp sender-id)
             (stringp msteams--connected-user-id)
             (equal sender-id msteams--connected-user-id))
        (and (stringp msteams--connected-as)
             (stringp sender-name)
             (string-equal sender-name msteams--connected-as)))))

(defun msteams--chat-members (chat)
  "Return cached members for CHAT."
  (let ((members
         (gethash (msteams--chat-id chat)
                  msteams--member-cache)))
    (unless (eq members msteams--no-members) members)))

(defun msteams--member-names (chat)
  "Return names of CHAT members other than the connected account."
  (let* ((members (msteams--chat-members chat))
         (connected-email (and msteams--connected-as
                               (downcase msteams--connected-as)))
         (connected-id msteams--connected-user-id)
         (others
          (seq-filter
           (lambda (member)
             (let ((user-id (msteams--get member 'userId))
                   (email (msteams--get member 'email)))
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
                    (or (msteams--get member 'displayName)
                        (msteams--get member 'email)))
                  selected))))

(defun msteams--meeting-chat-p (chat)
  "Return non-nil when CHAT represents a Teams meeting conversation."
  (equal (msteams--get chat 'chatType) "meeting"))

(defun msteams--meeting-context-args (chat)
  "Return backend arguments used to resolve metadata for meeting CHAT."
  (list "teams" "meeting" "context"
        "--chatId" (msteams--chat-id chat)))

(defun msteams--apply-meeting-context (chat context)
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
  (when (msteams--get context 'membersLoaded)
    (let ((members (msteams--get context 'members)))
      (puthash (msteams--chat-id chat)
               (or members msteams--no-members)
               msteams--member-cache)))
  (msteams--get chat 'meetingContext))

(defun msteams--fetch-meeting-context
    (chat callback &optional error-callback)
  "Fetch meeting CHAT metadata, then invoke CALLBACK with its context.

The context combines calendar start/end data and chat participants.  Calendar
permission failures are returned by the backend as `eventError' while member
data remains usable.  ERROR-CALLBACK handles failures of the whole operation."
  (if (or (not (msteams--meeting-chat-p chat))
          msteams-offline-mode)
      (progn
        (funcall callback (msteams--get chat 'meetingContext))
        nil)
    (msteams--run-json
     (msteams--meeting-context-args chat)
     (lambda (context)
       (msteams--apply-meeting-context chat context)
       (funcall callback context))
     error-callback)))

(defun msteams--meeting-members (chat)
  "Return all known member records for meeting CHAT."
  (or (msteams--get (msteams--get chat 'meetingContext) 'members)
      (msteams--chat-members chat)))

(defun msteams--meeting-participant-names (chat)
  "Return de-duplicated participant names for meeting CHAT."
  (let* ((context (msteams--get chat 'meetingContext))
         (event (msteams--get context 'event))
         (members
          (delq nil
                (mapcar
                 (lambda (member)
                   (or (msteams--get member 'displayName)
                       (msteams--get member 'email)))
                 (msteams--meeting-members chat))))
         (organizer
          (or (msteams--dig event 'organizer 'emailAddress 'name)
              (msteams--dig context
                             'onlineMeetingInfo 'organizer 'user 'displayName)
              (msteams--dig chat
                             'onlineMeetingInfo 'organizer 'user 'displayName)
              (msteams--dig chat 'onlineMeetingInfo 'organizer 'displayName)))
         (attendees
          (delq nil
                (mapcar
                 (lambda (attendee)
                   (msteams--dig attendee 'emailAddress 'name))
                 (msteams--get event 'attendees)))))
    (seq-uniq (append members (and organizer (list organizer)) attendees)
              #'string-equal)))

(defun msteams--chat-label (chat)
  "Return the best available human-readable label for CHAT."
  (let ((topic (msteams--get chat 'topic))
        (members (msteams--member-names chat)))
    (cond
     ((and (stringp topic) (not (string-empty-p (string-trim topic))))
      (string-trim topic))
     (members (string-join members ", "))
     ((equal (msteams--get chat 'chatType) "meeting") "Meeting chat")
     ((equal (msteams--get chat 'chatType) "group") "Group chat")
     (t "One-to-one chat"))))

(defun msteams--chat-type-key (chat)
  "Return a normalized display type symbol for CHAT."
  (pcase (msteams--get chat 'chatType)
    ("oneOnOne" 'direct)
    ("group" 'group)
    ("meeting" 'meeting)
    ("channel" 'channel)
    (_ (if (msteams--get chat 'channelIdentity) 'channel 'other))))

(defun msteams--chat-type-label (chat)
  "Return a compact aligned type label for CHAT."
  (pcase (msteams--chat-type-key chat)
    ('direct "Direct")
    ('group "Group")
    ('meeting "Meeting")
    ('channel "Channel")
    (_ "Other")))

(defun msteams--chat-type-face (chat)
  "Return the semantic face used for CHAT's type label."
  (pcase (msteams--chat-type-key chat)
    ('direct 'msteams-type-direct)
    ('group 'msteams-type-group)
    ('meeting 'msteams-type-meeting)
    ('channel 'msteams-type-channel)))

(defun msteams--row-face (unread &optional additional-face)
  "Combine UNREAD emphasis with ADDITIONAL-FACE."
  (delq nil (list (and unread 'msteams-unread) additional-face)))

(defun msteams--chat-preview (chat)
  "Return a compact sender and message preview for CHAT."
  (let* ((preview (msteams--get chat 'lastMessagePreview))
         (sender (and preview (msteams--message-sender preview)))
         (body (and preview (msteams--message-body preview)))
         (body (and body (replace-regexp-in-string "[\n\r\t ]+" " " body))))
    (cond
     ((and (stringp body) (not (string-empty-p body)))
      (truncate-string-to-width
       (if (and sender (not (equal sender "Teams")))
           (format "%s: %s" sender body)
         body)
       72 nil nil "..."))
     (t ""))))

(defun msteams--chat-choice (chat)
  "Return a unique completion candidate for CHAT."
  (format "%s  [%s]  %s"
          (msteams--chat-label chat)
          (msteams--short-id chat)
          (msteams--format-date
           (msteams--get chat 'lastUpdatedDateTime))))

(defun msteams--chat-updated-p (left right)
  "Return non-nil when LEFT was updated after RIGHT."
  (let ((left-favorite (msteams--favorite-p left))
        (right-favorite (msteams--favorite-p right)))
    (if (eq (not (null left-favorite)) (not (null right-favorite)))
        (string> (or (msteams--get left 'lastUpdatedDateTime) "")
                 (or (msteams--get right 'lastUpdatedDateTime) ""))
      left-favorite)))

(defun msteams--parse-message-time (value)
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

(defun msteams--message-older-p (left right)
  "Return non-nil when LEFT was created before RIGHT.

Compare absolute instants rather than timestamp text, then use the Graph
message ID as a deterministic tie-breaker."
  (let* ((left-value (or (msteams--get left 'createdDateTime) ""))
         (right-value (or (msteams--get right 'createdDateTime) ""))
         (left-time (msteams--parse-message-time left-value))
         (right-time (msteams--parse-message-time right-value))
         (left-id (or (msteams--get left 'id) ""))
         (right-id (or (msteams--get right 'id) "")))
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

(defun msteams--normalize-messages (messages)
  "Return MESSAGES chronological and deduplicated by Graph message ID."
  (let ((seen (make-hash-table :test #'equal))
        unique)
    (dolist (message messages)
      (let ((id (msteams--get message 'id)))
        (when (or (not (stringp id))
                  (not (gethash id seen)))
          (when (stringp id) (puthash id t seen))
          (push message unique))))
    (sort (nreverse unique) #'msteams--message-older-p)))

(defun msteams--effective-message-order ()
  "Return the effective visual order for the current transcript buffer."
  (if (memq msteams--message-order '(oldest-first newest-first))
      msteams--message-order
    msteams-message-order))

(defun msteams--messages-for-display (messages)
  "Return MESSAGES in the current transcript's visual order.

The canonical list is never mutated because export and capture require
chronological input."
  (if (eq (msteams--effective-message-order) 'newest-first)
      (reverse (copy-sequence messages))
    messages))

(defun msteams--message-order-label ()
  "Return a concise label for the current transcript's visual order."
  (if (eq (msteams--effective-message-order) 'newest-first)
      "newest first"
    "oldest first"))

(defun msteams-toggle-message-order ()
  "Toggle visual message order in the current chat or channel transcript."
  (interactive)
  (unless (or (derived-mode-p 'msteams-chat-mode)
              (derived-mode-p 'msteams-channel-thread-mode))
    (user-error "Open a Teams transcript first"))
  (setq-local
   msteams--message-order
   (if (eq (msteams--effective-message-order) 'oldest-first)
       'newest-first
     'oldest-first))
  (if (derived-mode-p 'msteams-chat-mode)
      (msteams--render-chat)
    (msteams--render-channel-thread))
  (message "Teams transcript order: %s"
           (msteams--message-order-label)))

(defun msteams--unread-p (chat)
  "Return non-nil when CHAT appears newer than its read marker."
  (let* ((chat-id (msteams--chat-id chat))
         (override (gethash chat-id msteams--read-overrides))
         (updated (msteams--get chat 'lastUpdatedDateTime))
         (read (msteams--dig chat 'viewpoint 'lastMessageReadDateTime)))
    (when (and override (not (equal (cdr override) updated)))
      (remhash chat-id msteams--read-overrides)
      (setq override nil))
    (pcase (car-safe override)
      ('read nil)
      ('unread t)
      (_ (and (stringp updated)
              (or (not (stringp read)) (string< read updated)))))))

(defun msteams--status-request (callback &optional error-callback)
  "Fetch shared OAuth status and invoke CALLBACK with it.

ERROR-CALLBACK, when non-nil, handles backend failures."
  (msteams--run-json
   '("status")
   (lambda (status)
     (setq msteams--connected-as
           (and (listp status) (msteams--get status 'connectedAs))
           msteams--connected-user-id
           (and (listp status) (msteams--get status 'userId)))
     (funcall callback status))
   error-callback))

(defun msteams--with-status (callback)
  "Invoke CALLBACK after ensuring shared M365 credentials are present."
  (if (or msteams-offline-mode msteams--connected-as)
      (funcall callback)
    (msteams--status-request
     (lambda (_status)
       (if msteams--connected-as
           (funcall callback)
         (message "Shared M365 OAuth is unavailable; run M-x msteams-login"))))))

(defun msteams--require-online ()
  "Reject a server mutation while cache-only mode is active."
  (when msteams-offline-mode
    (user-error "Teams is in offline cache mode; toggle it off to mutate server state")))

;;;###autoload
(defun msteams-status ()
  "Show the Microsoft Graph token-provider status used by Teams."
  (interactive)
  (msteams--status-request
   (lambda (status)
     (let ((buffer (get-buffer-create "*M365 Status*")))
       (with-current-buffer buffer
         (let ((inhibit-read-only t))
           (erase-buffer)
           (if (stringp status)
               (insert (format "Status: %s\n\nRun M-x msteams-login to connect.\n"
                               status))
             (insert (format "Connection: %s\n"
                             (or (msteams--get status 'connectionName) "default")))
             (insert (format "Account:    %s\n"
                             (or (msteams--get status 'connectedAs) "unknown")))
             (insert (format "Auth type:  %s\n"
                             (or (msteams--get status 'authType) "unknown")))
             (insert (format "Tenant:     %s\n"
                             (or (msteams--get status 'appTenant) "unknown")))
             (insert (format "Graph token: %s\n"
                             (or (msteams--get status 'graphTokenStatus)
                                 "unknown")))
             (if (equal (msteams--get status 'authType) "MockTenant")
                 (insert (format "Mock state: %s\n"
                                 (or (msteams--get status 'mockStateFile)
                                     "unknown")))
               (insert (format "Credentials: %s\n"
                               (or (msteams--get status 'credentialFile)
                                   "unknown")))))
           (special-mode)))
       (pop-to-buffer buffer)))))

;;;###autoload
(defun msteams-login ()
  "Run the configured Graph credential bootstrap in a comint buffer."
  (interactive)
  (let* ((program (msteams--executable))
         (buffer (get-buffer-create "*M365 Login*"))
         (args '("login"))
         (process-environment (copy-sequence process-environment)))
    (msteams--configure-process-environment)
    (setenv "PATH" (concat (file-name-directory program) path-separator
                            (or (getenv "PATH") "")))
    (when-let ((old-process (get-buffer-process buffer)))
      (unless (yes-or-no-p "Replace the active m365 login process? ")
        (user-error "Login left running"))
      (delete-process old-process))
    (with-current-buffer buffer
      (let ((inhibit-read-only t)) (erase-buffer)))
    (apply #'make-comint-in-buffer "M365 Login" buffer program nil args)
    (setq msteams--connected-as nil)
    (pop-to-buffer buffer)))

;;;###autoload
(defun msteams-logout ()
  "Explain why msteams cannot log out an externally owned OAuth identity."
  (interactive)
  (user-error
   (concat "msteams consumes an external token provider and does not own "
           "its OAuth session; log out through that provider")))

(defun msteams--chat-list-args ()
  "Return backend arguments for one bounded native inbox refresh."
  (if msteams-offline-mode
      '("teams" "cache" "chat" "list")
    (list "teams" "chat" "list"
          "--metadataLimit"
          (number-to-string (max 1 msteams-chat-metadata-limit)))))

(defun msteams--normalize-chats (payload)
  "Normalize chat PAYLOAD, update member hints, and return sorted chats."
  (let ((chats (msteams--payload-list payload)))
    (dolist (chat chats)
      (when (msteams--get chat 'membersLoaded)
        (let ((members (msteams--get chat 'members)))
          (puthash (msteams--chat-id chat)
                   (or members msteams--no-members)
                   msteams--member-cache))))
    (sort chats #'msteams--chat-updated-p)))

(defun msteams--load-chats (callback &optional error-callback args)
  "Load recent Teams chats and invoke CALLBACK with the sorted result.

ERROR-CALLBACK receives backend status and detail.  Optional ARGS overrides the
normal online/offline command, principally for cache-first inbox opening."
  (msteams--run-json
   (or args (msteams--chat-list-args))
   (lambda (payload)
     (setq msteams--chats (msteams--normalize-chats payload))
     (funcall callback msteams--chats))
   error-callback))

(defun msteams--inbox-source-suffix ()
  "Return the transient cache/refresh label for the current inbox buffer."
  (if (and (stringp msteams--inbox-source-label)
           (not (string-empty-p msteams--inbox-source-label)))
      (concat " - " msteams--inbox-source-label)
    ""))

(defun msteams--recent-buffer ()
  "Return the recent-chat buffer when it is live."
  (get-buffer msteams--recent-buffer-name))

(defun msteams--tabulated-goto-id (id)
  "Move point to tabulated-list row ID and return non-nil when found."
  (when id
    (goto-char (point-min))
    (while (and (not (equal id (tabulated-list-get-id)))
                (not (eobp)))
      (forward-line 1))
    (when (equal id (tabulated-list-get-id))
      (beginning-of-line)
      t)))

(defun msteams--tabulated-goto-first-id ()
  "Move point to the first tabulated-list row and return its ID."
  (goto-char (point-min))
  (while (and (not (tabulated-list-get-id)) (not (eobp)))
    (forward-line 1))
  (when-let ((id (tabulated-list-get-id)))
    (beginning-of-line)
    id))

(defun msteams--recent-index-window ()
  "Return a visible window showing the current Teams headers buffer."
  (and (derived-mode-p 'msteams-recent-mode)
       (get-buffer-window (current-buffer) t)))

(defun msteams--recent-selected-id ()
  "Return the chat ID selected in the visible headers window."
  (if-let ((window (msteams--recent-index-window)))
      (with-selected-window window (tabulated-list-get-id))
    (tabulated-list-get-id)))

(defun msteams--recent-restore-selection (chat-id)
  "Restore CHAT-ID in the visible headers window, falling back to its first row."
  (let ((restore
         (lambda ()
           (unless (and chat-id
                        (msteams--tabulated-goto-id chat-id))
             (msteams--tabulated-goto-first-id)))))
    (if-let ((window (msteams--recent-index-window)))
        (with-selected-window window (funcall restore))
      (funcall restore))))

(defun msteams--visible-chat-reader-window ()
  "Return the chat reader beside the current visible headers window."
  (when-let* ((index-window (msteams--recent-index-window))
              (reader (get-buffer msteams--read-buffer-name))
              (reader-window
               (get-buffer-window reader (window-frame index-window))))
    (when (with-current-buffer reader
            (derived-mode-p 'msteams-chat-mode))
      reader-window)))

(defun msteams--cancel-preview-timer ()
  "Cancel the current headers buffer's pending transcript preview."
  (when (timerp msteams--preview-timer)
    (cancel-timer msteams--preview-timer))
  (setq msteams--preview-timer nil))

(defun msteams--clear-chat-reader (reader)
  "Clear stale conversation state from visible chat READER."
  (with-current-buffer reader
    (msteams--cancel-buffer-process)
    (setq msteams--chat nil
          msteams--messages nil
          msteams--loaded-at nil
          msteams--loaded-update nil
          msteams--loaded-all nil
          msteams--pending-message-id nil
          msteams--meeting-context nil
          msteams--automatic-preview-p nil
          header-line-format "No Teams chat selected")
    (let ((inhibit-read-only t))
      (erase-buffer)
      (insert "No chats match the current inbox view.\n"))))

(defun msteams--sync-visible-chat-reader ()
  "Make an existing chat reader match the visible headers selection.

Return non-nil when a linked reader exists, even when it already matches."
  (unless msteams--inhibit-reader-follow
    (when-let ((reader-window (msteams--visible-chat-reader-window)))
      (let* ((reader (window-buffer reader-window))
             (selected-id (msteams--recent-selected-id))
             (reader-id
              (with-current-buffer reader
                (and msteams--chat
                     (msteams--chat-id msteams--chat)))))
        (cond
         ((not selected-id)
          (when reader-id (msteams--clear-chat-reader reader)))
         ((not (equal selected-id reader-id))
          (when-let ((chat (msteams--find-chat selected-id)))
            (save-selected-window
              (msteams-open-chat chat t)))))
        t))))

(defun msteams--follow-selected-chat ()
  "Keep a visible reader synchronized, or schedule an opt-in first preview."
  (unless msteams--inhibit-reader-follow
    (if (msteams--sync-visible-chat-reader)
        (msteams--cancel-preview-timer)
      (msteams--schedule-preview))))

(defun msteams--recent-entry (chat)
  "Build one tabulated-list entry for CHAT."
  (let* ((unread (msteams--unread-p chat))
         (face (msteams--row-face unread))
         (type-face
          (msteams--row-face
           unread (msteams--chat-type-face chat))))
    (list
     (msteams--chat-id chat)
     (vector
      ""
      (propertize
       (msteams--format-date
        (msteams--get chat 'lastUpdatedDateTime) t)
       'face face)
      (propertize (msteams--chat-type-label chat) 'face type-face)
      (propertize (msteams--chat-label chat) 'face face)
      (propertize (or (msteams--meeting-row-label chat) "")
                  'face face)
      (if (msteams--favorite-p chat) "*" "")
      (propertize (msteams--chat-preview chat) 'face face)))))

(defun msteams--configure-recent-format ()
  "Install the current Teams inbox columns, including after a live reload."
  (unless (equal tabulated-list-format msteams--recent-format)
    (setq tabulated-list-format (copy-sequence msteams--recent-format))
    (tabulated-list-init-header)))

(defun msteams--render-recent ()
  "Render cached chats in the current recent-chat buffer."
  (let ((selected (msteams--recent-selected-id))
        (unread-count (seq-count #'msteams--unread-p
                                 msteams--chats)))
    (msteams--configure-recent-format)
    (setq tabulated-list-entries
          (mapcar #'msteams--recent-entry msteams--chats)
          header-line-format
          (format "Teams inbox - %d unread%s%s"
                  unread-count
                  (if msteams--connected-as
                      (format " - %s" msteams--connected-as)
                    "")
                  (msteams--inbox-source-suffix)))
    (tabulated-list-print t)
    (msteams--recent-restore-selection selected)
    (msteams--follow-selected-chat)))

(defun msteams--refresh-visible-recent ()
  "Refresh the recent-chat buffer after cached labels change."
  (when-let ((buffer (msteams--recent-buffer)))
    (with-current-buffer buffer
      (when (derived-mode-p 'msteams-recent-mode)
        (msteams--render-recent)))))

(defun msteams--enrich-members (chats)
  "Resolve names for bounded unnamed CHATS in one asynchronous backend batch."
  (let* ((limit (max 0 msteams-member-enrichment-limit))
         (selected
          (seq-take
           (seq-filter
            (lambda (chat)
              (let ((id (msteams--chat-id chat))
                    (topic (msteams--get chat 'topic)))
                (and id
                     (not (and (stringp topic)
                               (not (string-empty-p (string-trim topic)))))
                     (not (gethash id msteams--member-cache))
                     (not (gethash id msteams--member-inflight)))))
            chats)
           limit))
         (ids (mapcar #'msteams--chat-id selected)))
    (when (and ids (not msteams-offline-mode))
      (dolist (id ids) (puthash id t msteams--member-inflight))
      (let ((args
             (append
              (list "teams" "chat" "member" "batch"
                    "--memberConcurrency"
                    (number-to-string
                     (max 1 msteams-member-enrichment-concurrency)))
              (apply #'append
                     (mapcar (lambda (id) (list "--chatId" id)) ids)))))
        (msteams--run-json
         args
         (lambda (payload)
           (dolist (record (msteams--payload-list payload))
             (let ((id (msteams--get record 'chatId)))
               (when id
                 (remhash id msteams--member-inflight)
                 (when (msteams--get record 'membersLoaded)
                   (let ((members (msteams--get record 'members)))
                     (puthash id (or members msteams--no-members)
                              msteams--member-cache))))))
           (dolist (id ids) (remhash id msteams--member-inflight))
           (msteams--refresh-visible-recent))
         (lambda (_status _detail)
           ;; Member labels are optional; topic/type fallbacks remain usable.
           (dolist (id ids) (remhash id msteams--member-inflight))))))))

(defun msteams--meeting-event-id (chat)
  "Return CHAT's linked calendar event identifier, when available."
  (msteams--dig chat 'onlineMeetingInfo 'calendarEventId))

(defun msteams--meeting-event-batch-args (chats)
  "Return one backend request for the linked calendar events of CHATS."
  (list
   "teams" "meeting" "event" "batch"
   "--meetings"
   (json-encode
    (mapcar
     (lambda (chat)
       `((chatId . ,(msteams--chat-id chat))
         (eventId . ,(msteams--meeting-event-id chat))))
     chats))
   "--meetingConcurrency"
   (number-to-string
    (max 1 msteams-meeting-enrichment-concurrency))))

(defun msteams--enrich-meetings (chats)
  "Resolve linked calendar events for a bounded subset of meeting CHATS.

Results are merged into the existing chat alists.  The inbox therefore has
one conversation representation even while meeting metadata arrives later."
  (let* ((limit (max 0 msteams-meeting-enrichment-limit))
         (selected
          (seq-take
           (seq-filter
            (lambda (chat)
              (let* ((id (msteams--chat-id chat))
                     (context (msteams--get chat 'meetingContext)))
                (and id
                     (msteams--meeting-chat-p chat)
                     (msteams--meeting-event-id chat)
                     (not (msteams--get context 'event))
                     (not (msteams--get context 'eventError))
                     (not (gethash id msteams--meeting-inflight)))))
            chats)
           limit))
         (ids (mapcar #'msteams--chat-id selected)))
    (when (and ids (not msteams-offline-mode))
      (dolist (id ids) (puthash id t msteams--meeting-inflight))
      (let ((args (msteams--meeting-event-batch-args selected)))
        (msteams--run-json
         args
         (lambda (payload)
           (dolist (record (msteams--payload-list payload))
             (when-let* ((id (msteams--get record 'chatId))
                         (chat (msteams--find-chat id)))
               (remhash id msteams--meeting-inflight)
               (msteams--apply-meeting-context chat record)))
           (dolist (id ids) (remhash id msteams--meeting-inflight))
           (msteams--refresh-visible-recent))
         (lambda (_status _detail)
           ;; Calendar permission is optional; chat and member data stay useful.
           (dolist (id ids)
             (remhash id msteams--meeting-inflight))))))))

(defvar msteams-recent-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map tabulated-list-mode-map)
    (define-key map (kbd "RET") #'msteams-recent-open)
    (define-key map (kbd "l") #'msteams-recent-open)
    (define-key map (kbd "y") #'msteams-select-preview)
    (define-key map (kbd "j") #'msteams-recent-next)
    (define-key map (kbd "n") #'msteams-recent-next)
    (define-key map (kbd "k") #'msteams-recent-previous)
    (define-key map (kbd "p") #'msteams-recent-previous)
    (define-key map (kbd "]") #'msteams-recent-next-unread)
    (define-key map (kbd "[") #'msteams-recent-previous-unread)
    (define-key map (kbd "g") #'msteams-recent-refresh)
    (define-key map (kbd "c") #'msteams-send)
    (define-key map (kbd "i") #'msteams-mark-read-later)
    (define-key map (kbd "C") #'msteams-send)
    (define-key map (kbd "r") #'msteams-mark-read-later)
    (define-key map (kbd "R") #'msteams-reply)
    (define-key map (kbd "f") #'msteams-message-forward)
    (define-key map (kbd "F") #'msteams-message-forward)
    (define-key map (kbd "o") #'msteams-open-in-browser)
    (define-key map (kbd "O") #'msteams-open-in-app)
    (define-key map (kbd "*") #'msteams-toggle-favorite)
    (define-key map (kbd "M-u") #'msteams-mark-unread)
    (define-key map (kbd "I") #'msteams-mark-read-later)
    (define-key map (kbd "M") #'msteams-toggle-selection)
    (define-key map (kbd "T") #'msteams-toggle-visible-selections)
    (define-key map (kbd "X") #'msteams-bulk-action)
    (define-key map (kbd "E") #'msteams-export-thread)
    (define-key map (kbd "Y") #'msteams-copy-thread-markdown)
    (define-key map (kbd "J") #'msteams-preview-scroll-down)
    (define-key map (kbd "K") #'msteams-preview-scroll-up)
    (define-key map (kbd "C-+") #'msteams-index-grow)
    (define-key map (kbd "C-=") #'msteams-index-grow)
    (define-key map (kbd "C--") #'msteams-index-shrink)
    (define-key map (kbd "q") #'msteams-quit)
    map)
  "Keymap for `msteams-recent-mode'.")

(define-derived-mode msteams-recent-mode tabulated-list-mode "Teams-Recent"
  "Major mode for recent Microsoft Teams chats."
  (setq tabulated-list-format (copy-sequence msteams--recent-format))
  (setq tabulated-list-padding 1
        tabulated-list-sort-key nil)
  (add-hook 'kill-buffer-hook #'msteams--cancel-buffer-process nil t)
  (add-hook 'post-command-hook #'msteams--follow-selected-chat nil t)
  (tabulated-list-init-header))

;;;###autoload
(defun msteams--start-live-inbox-refresh (buffer cached-shown)
  "Refresh BUFFER from Graph, retaining cached rows when CACHED-SHOWN is set."
  (msteams--with-status
   (lambda ()
     (when (buffer-live-p buffer)
       (with-current-buffer buffer
         (setq msteams--inbox-source-label
               (and cached-shown "cached, refreshing"))
         (when cached-shown (msteams--render-recent))
         (msteams--cancel-process msteams--process)
         (setq
          msteams--process
          (msteams--load-chats
           (lambda (chats)
             (when (buffer-live-p buffer)
               (with-current-buffer buffer
                 (setq msteams--process nil
                       msteams--inbox-source-label nil)
                 (msteams--render-recent)
                 (msteams--schedule-preview)))
             (msteams--enrich-members chats)
             (msteams--enrich-meetings chats))
           (lambda (status detail)
             (when (buffer-live-p buffer)
               (with-current-buffer buffer
                 (setq msteams--process nil
                       msteams--inbox-source-label
                       (if cached-shown
                           "cached; live refresh failed"
                         "load failed - see *M365 Errors*"))
                 (if cached-shown
                     (msteams--render-recent)
                   (setq header-line-format
                         "Teams inbox load failed - see *M365 Errors*"))))
             (msteams--report-error
              (msteams--chat-list-args) status detail)))))))))

(defun msteams--start-cache-first-inbox-load (buffer)
  "Render BUFFER from the existing SQLite cache, then refresh it from Graph."
  (with-current-buffer buffer
    (msteams--cancel-process msteams--process)
    (setq msteams--inbox-source-label "loading cache"
          msteams--process
          (msteams--run-json
           '("teams" "cache" "chat" "list")
           (lambda (payload)
             (let ((cached (msteams--normalize-chats payload)))
               (when (buffer-live-p buffer)
                 (with-current-buffer buffer
                   (setq msteams--process nil)
                   (when cached
                     (setq msteams--chats cached
                           msteams--inbox-source-label
                           "cached, refreshing")
                     (msteams--render-recent)))
                 (msteams--start-live-inbox-refresh
                  buffer (not (null cached))))))
           (lambda (_status _detail)
             ;; A missing or corrupt cache must not block a normal live inbox.
             (when (buffer-live-p buffer)
               (with-current-buffer buffer
                 (setq msteams--process nil
                       msteams--inbox-source-label nil))
               (msteams--start-live-inbox-refresh buffer nil)))))))

;;;###autoload
(defun msteams-recent ()
  "Open a native recent-chat inbox backed by Microsoft Graph."
  (interactive)
  (msteams--load-state)
  (let* ((existing (get-buffer msteams--recent-buffer-name))
         (buffer (get-buffer-create msteams--recent-buffer-name)))
    (unless existing
      (msteams--ensure-active-view)
      (setq msteams--active-query nil
            msteams--active-filter-name nil))
    (pop-to-buffer buffer)
    (unless (derived-mode-p 'msteams-recent-mode)
      (msteams-recent-mode))
    (setq header-line-format "Loading Teams chats..."
          msteams--inbox-source-label nil)
    (cond
     (msteams-offline-mode
      (with-current-buffer buffer
        (setq msteams--process
              (msteams--load-chats
               (lambda (_chats)
                 (when (buffer-live-p buffer)
                   (with-current-buffer buffer
                     (setq msteams--process nil
                           msteams--inbox-source-label "offline cache")
                     (msteams--render-recent))))))))
     (msteams-cache-first
      (msteams--start-cache-first-inbox-load buffer))
     (t
      (msteams--start-live-inbox-refresh buffer nil)))))

;;;###autoload
(defun msteams-inbox ()
  "Open the Teams inbox, saving the current frame layout for `q'."
  (interactive)
  (unless (derived-mode-p 'msteams-recent-mode
                          'msteams-chat-mode
                          'msteams-search-mode
                          'msteams-channel-index-mode
                          'msteams-channel-thread-mode)
    (puthash (selected-frame) (current-window-configuration)
             msteams--window-configurations))
  (msteams-recent)
  (delete-other-windows))

(defun msteams--cancel-frame-preview-timers (frame)
  "Cancel pending Teams preview timers visible on FRAME."
  (dolist (window (window-list frame 'no-minibuf))
    (with-current-buffer (window-buffer window)
      (when (and (local-variable-p 'msteams--preview-timer)
                 (timerp msteams--preview-timer))
        (cancel-timer msteams--preview-timer)
        (setq msteams--preview-timer nil)))))

(defun msteams-quit ()
  "Leave Teams without deleting the current Emacs frame."
  (interactive)
  (let* ((frame (selected-frame))
         (configuration (gethash frame msteams--window-configurations)))
    (msteams--cancel-frame-preview-timers frame)
    (remhash frame msteams--window-configurations)
    (cond
     ((and (window-configuration-p configuration)
           (eq frame (window-configuration-frame configuration)))
      (set-window-configuration configuration))
     ((window-parent (selected-window))
      (quit-window t))
     (t
      (bury-buffer)))))

(defun msteams--close-reader-to-index (index-buffer)
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

(defun msteams-chat-view-quit ()
  "Close the Teams chat reader pane and return to the chat headers."
  (interactive)
  (msteams--close-reader-to-index
   (msteams--recent-buffer)))

(defun msteams-recent-refresh ()
  "Refresh the recent Teams chat inbox."
  (interactive)
  (msteams-recent))

(defun msteams--find-chat (id)
  "Return cached chat with ID."
  (seq-find (lambda (chat) (equal id (msteams--chat-id chat)))
            msteams--chats))

(defun msteams--chat-at-point ()
  "Return the Teams chat represented at point or by the current buffer."
  (cond
   ((derived-mode-p 'msteams-chat-mode) msteams--chat)
   ((derived-mode-p 'msteams-recent-mode)
    (or (msteams--find-chat (tabulated-list-get-id))
        (user-error "No chat on this row")))
   (t nil)))

(defun msteams-recent-open ()
  "Open the chat on the current recent-chat row."
  (interactive)
  (msteams-open-chat (msteams--chat-at-point)))

(defun msteams--schedule-preview ()
  "Preview the selected inbox row after the configured idle delay."
  (msteams--cancel-preview-timer)
  (when (and msteams-preview-on-move (tabulated-list-get-id))
    (let ((buffer (current-buffer))
          (chat-id (tabulated-list-get-id)))
      (setq msteams--preview-timer
            (run-with-idle-timer
             msteams-preview-delay nil
             (lambda ()
               (when (buffer-live-p buffer)
                 (with-current-buffer buffer
                   (setq msteams--preview-timer nil)
                   (when (equal chat-id (tabulated-list-get-id))
                     (when-let ((chat (msteams--find-chat chat-id)))
                       (msteams-open-chat chat t)))))))))))

(defun msteams--recent-move (delta)
  "Move DELTA inbox rows and keep an existing reader synchronized."
  (let ((origin (point)))
    (forward-line delta)
    (beginning-of-line)
    (unless (tabulated-list-get-id)
      (goto-char origin))
    (msteams--follow-selected-chat)))

(defun msteams-recent-next ()
  "Move to the next chat without changing its server read state."
  (interactive)
  (msteams--recent-move 1))

(defun msteams-recent-previous ()
  "Move to the previous chat without changing its server read state."
  (interactive)
  (msteams--recent-move -1))

(defun msteams--recent-move-to (direction predicate description)
  "Move DIRECTION to the next chat matching PREDICATE.

DESCRIPTION names the match in user-facing errors."
  (let ((origin (point)) found finished)
    (while (not finished)
      (let ((before (point)))
        (forward-line direction)
        (if (= before (point))
            (setq finished t)
          (when-let* ((id (tabulated-list-get-id))
                      (chat (msteams--find-chat id)))
            (when (funcall predicate chat)
              (setq found t finished t))))))
    (if found
        (progn
          (beginning-of-line)
          (msteams--follow-selected-chat))
      (goto-char origin)
      (user-error "No %s chat in that direction" description))))

(defun msteams-recent-next-unread ()
  "Move to the next unread chat, as `mu4e-headers-next-unread' does."
  (interactive)
  (msteams--recent-move-to
   1 #'msteams--unread-p "unread"))

(defun msteams-recent-previous-unread ()
  "Move to the previous unread chat, as `mu4e-headers-prev-unread' does."
  (interactive)
  (msteams--recent-move-to
   -1 #'msteams--unread-p "unread"))

(defun msteams--recent-goto-chat-id (chat-id)
  "Move the current Teams headers buffer to CHAT-ID and return non-nil."
  (msteams--tabulated-goto-id chat-id))

(defun msteams-chat-run-headers-command (&optional command)
  "Run the current key's Teams headers COMMAND from the chat reader.

The linked headers row is selected temporarily, as in mu4e view mode.  Reader
focus is retained, and a command that advances the headers replaces the one
singleton Teams reader with the newly selected chat."
  (interactive)
  (unless (derived-mode-p 'msteams-chat-mode)
    (user-error "Open a Teams chat in the reader first"))
  (let* ((reader-buffer (current-buffer))
         (reader-window (selected-window))
         (chat-id (msteams--chat-id msteams--chat))
         (index-buffer (msteams--recent-buffer))
         (index-window
          (and (buffer-live-p index-buffer)
               (get-buffer-window index-buffer)))
         (resolved
          (or command
              (lookup-key msteams-recent-mode-map
                          (this-command-keys-vector))))
         selected-id)
    (unless (window-live-p index-window)
      (user-error "The Teams chat headers are not visible"))
    (unless (commandp resolved)
      (user-error "No Teams headers command for this key"))
    (with-selected-window index-window
      (with-current-buffer index-buffer
        (unless (msteams--recent-goto-chat-id chat-id)
          (user-error "The open Teams chat is not in the current headers")))
      (let ((msteams--inhibit-reader-follow t))
        (call-interactively resolved))
      (when (buffer-live-p index-buffer)
        (with-current-buffer index-buffer
          (when (derived-mode-p 'msteams-recent-mode)
            (setq selected-id (tabulated-list-get-id))))))
    (when (and (buffer-live-p reader-buffer)
               (window-live-p reader-window)
               (eq (window-buffer reader-window) reader-buffer))
      (if (not selected-id)
          (msteams--clear-chat-reader reader-buffer)
        (when (not (equal selected-id chat-id))
          (when-let ((chat (msteams--find-chat selected-id)))
            (with-selected-window reader-window
              (msteams-open-chat chat))))))))

(defun msteams--preview-window ()
  "Return the visible native Teams chat transcript window, if any."
  (or (when-let ((buffer (get-buffer msteams--read-buffer-name)))
        (get-buffer-window buffer t))
      (seq-find
       (lambda (window)
         (with-current-buffer (window-buffer window)
           (derived-mode-p 'msteams-chat-mode)))
       (window-list nil 'nomini))))

(defun msteams-select-preview ()
  "Select the transcript pane, matching mu4e's other-view command."
  (interactive)
  (if-let ((window (msteams--preview-window)))
      (select-window window)
    (msteams-recent-open)))

(defun msteams--preview-scroll (direction)
  "Scroll the transcript pane in DIRECTION without selecting it."
  (let ((window (or (msteams--preview-window)
                    (progn
                      (msteams-open-chat
                       (msteams--chat-at-point) t)
                      (msteams--preview-window)))))
    (unless (window-live-p window)
      (user-error "No Teams transcript preview is visible"))
    (with-selected-window window
      (condition-case nil
          (if (> direction 0)
              (scroll-up-command)
            (scroll-down-command))
        ((beginning-of-buffer end-of-buffer) nil)))))

(defun msteams-preview-scroll-down ()
  "Scroll the transcript forward, matching teams-tui-go's J action."
  (interactive)
  (msteams--preview-scroll 1))

(defun msteams-preview-scroll-up ()
  "Scroll the transcript backward, matching teams-tui-go's K action."
  (interactive)
  (msteams--preview-scroll -1))

(defun msteams--resize-index (columns)
  "Resize the Teams index window horizontally by COLUMNS."
  (unless (msteams--preview-window)
    (user-error "Open a Teams transcript preview before resizing the index"))
  (window-resize (selected-window) columns t))

(defun msteams-index-grow ()
  "Grow the Teams headers pane by five columns."
  (interactive)
  (msteams--resize-index 5))

(defun msteams-index-shrink ()
  "Shrink the Teams headers pane by five columns."
  (interactive)
  (msteams--resize-index -5))

(defun msteams-toggle-favorite ()
  "Toggle the current chat in the local favorites section."
  (interactive)
  (msteams--load-state)
  (let* ((chat (or (msteams--chat-at-point)
                   (user-error "No Teams chat here")))
         (chat-id (msteams--chat-id chat))
         (enabled (not (msteams--favorite-p chat))))
    (if enabled
        (puthash chat-id t msteams--favorites)
      (remhash chat-id msteams--favorites))
    (msteams--save-state)
    (setq msteams--chats
          (sort msteams--chats #'msteams--chat-updated-p))
    (msteams--refresh-visible-recent)
    (message "%s %s"
             (if enabled "Favorited" "Removed favorite")
             (msteams--chat-label chat))))

(defun msteams-toggle-muted ()
  "Toggle local inbox suppression for the current Teams chat.

This does not change Teams notification settings.  Microsoft Graph does not
document a chat mute mutation, so the private state only controls the Emacs
`inbox' view; `all' continues to show the conversation."
  (interactive)
  (msteams--load-state)
  (let* ((chat (or (msteams--chat-at-point)
                   (user-error "No Teams chat here")))
         (chat-id (msteams--chat-id chat))
         (locally-muted (gethash chat-id msteams--muted))
         (enabled (not locally-muted)))
    (if enabled
        (puthash chat-id t msteams--muted)
      (remhash chat-id msteams--muted))
    (msteams--save-state)
    (msteams--refresh-visible-recent)
    (message "%s %s in the Teams inbox"
             (if enabled "Muted" "Unmuted")
             (msteams--chat-label chat))))

(defun msteams--set-read-state (state &optional quiet)
  "Set the current chat read STATE through Graph.

STATE is the symbol `read' or `unread'.  QUIET suppresses success messages."
  (msteams--require-online)
  (let* ((chat (or (msteams--chat-at-point)
                   (user-error "No Teams chat here")))
         (chat-id (msteams--chat-id chat))
         (label (msteams--chat-label chat)))
    (msteams--run-json
     (list "teams" "chat" "mark" (symbol-name state) "--chatId" chat-id)
     (lambda (_payload)
       (puthash chat-id
                (cons state (msteams--get chat 'lastUpdatedDateTime))
                msteams--read-overrides)
       (msteams--refresh-visible-recent)
       (unless quiet (message "Marked %s %s" label state))))))

(defun msteams-mark-read ()
  "Explicitly mark the current chat read."
  (interactive)
  (msteams--set-read-state 'read))

(defun msteams-mark-unread ()
  "Explicitly mark the current chat unread from its newest message."
  (interactive)
  (msteams--set-read-state 'unread))

(defun msteams--message-args
    (chat &optional all request-limit ignore-date)
  "Return Graph-backend arguments to load CHAT messages.

ALL non-nil suppresses the date and item bounds.  REQUEST-LIMIT overrides the
normal on-screen limit, primarily for automatic previews.  IGNORE-DATE keeps
the item bound while allowing older pages to be loaded."
  (let ((limit (and (not all)
                    (or request-limit msteams-message-limit))))
    (if msteams-offline-mode
        (list "teams" "cache" "chat" "message" "list"
              "--chatId" (msteams--chat-id chat)
              "--limit" (if all
                            "1000000"
                          (number-to-string (or limit 1000))))
      (append
       (list "teams" "chat" "message" "list"
             "--chatId" (msteams--chat-id chat))
       (when limit (list "--limit" (number-to-string limit)))
       (unless (or all ignore-date (not msteams-message-days))
         (list "--modifiedStartDateTime"
               (format-time-string
                "%Y-%m-%dT%H:%M:%SZ"
                (time-subtract nil (days-to-time msteams-message-days))
                t)))))))

(defun msteams--reaction-summary (message)
  "Return a compact reaction summary for MESSAGE."
  (let ((reactions (msteams--get message 'reactions)))
    (when (listp reactions)
      (let ((counts (make-hash-table :test #'equal)))
        (dolist (reaction reactions)
          (let ((kind (or (msteams--get reaction 'reactionType) "reaction")))
            (puthash kind (1+ (gethash kind counts 0)) counts)))
        (let (parts)
          (maphash (lambda (kind count)
                     (push (format "%s %d" kind count) parts))
                   counts)
          (string-join (sort parts #'string<) ", "))))))

(defun msteams--graph-segment (value)
  "Encode opaque Graph path segment VALUE."
  (url-hexify-string (format "%s" value)))

(defun msteams--absolute-inline-image-url (message source)
  "Resolve MESSAGE image SOURCE to an authenticated absolute URL."
  (let* ((source (and (stringp source) (string-trim source)))
         (message-id (msteams--get message 'id))
         (chat-id
          (or (msteams--get message 'chatId)
              (and msteams--chat
                   (msteams--chat-id msteams--chat))))
         (team-id
          (or (msteams--dig message 'channelIdentity 'teamId)
              (and (boundp 'msteams-channel--team)
                   (msteams--get msteams-channel--team 'id))))
         (channel-id
          (or (msteams--dig message 'channelIdentity 'channelId)
              (and (boundp 'msteams-channel--channel)
                   (msteams--get msteams-channel--channel 'id))))
         (reply-to-id (msteams--get message 'replyToId))
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
       (msteams--graph-segment chat-id)
       (msteams--graph-segment message-id)
       hosted-id))
     ((and hosted-id team-id channel-id message-id)
      (if reply-to-id
          (format
           (concat "https://graph.microsoft.com/v1.0/teams/%s/channels/%s/"
                   "messages/%s/replies/%s/hostedContents/%s/$value")
           (msteams--graph-segment team-id)
           (msteams--graph-segment channel-id)
           (msteams--graph-segment reply-to-id)
           (msteams--graph-segment message-id)
           hosted-id)
        (format
         (concat "https://graph.microsoft.com/v1.0/teams/%s/channels/%s/"
                 "messages/%s/hostedContents/%s/$value")
         (msteams--graph-segment team-id)
         (msteams--graph-segment channel-id)
         (msteams--graph-segment message-id)
         hosted-id)))
     (t nil))))

(defun msteams--inline-images (message)
  "Return synthetic attachment objects for inline images in MESSAGE HTML."
  (let ((content (msteams--dig message 'body 'content)) images)
    (when (and (stringp content) (string-match-p "<img[ >]" content))
      (condition-case nil
          (with-temp-buffer
            (insert "<html><body>" content "</body></html>")
            (let ((document (libxml-parse-html-region (point-min) (point-max)))
                  (index 0))
              (dolist (node (dom-by-tag document 'img))
                (when-let* ((source (dom-attr node 'src))
                            (url (msteams--absolute-inline-image-url
                                  message source)))
                  (cl-incf index)
                  (push
                   (list
                    (cons 'id (format "inline-%s-%d"
                                      (or (msteams--get message 'id) "image")
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

(defun msteams--image-attachment-p (attachment)
  "Return non-nil when ATTACHMENT represents a displayable image."
  (let ((content-type (downcase
                       (or (msteams--get attachment 'contentType) "")))
        (name (downcase (or (msteams--get attachment 'name) ""))))
    (or (string-prefix-p "image/" content-type)
        (equal content-type "hostedimage")
        (string-match-p "\\.\\(png\\|jpe?g\\|gif\\|webp\\|bmp\\|tiff?\\)\\'"
                        name))))

(defun msteams--message-images (message)
  "Return unique inline and attached images represented by MESSAGE."
  (let ((seen (make-hash-table :test #'equal)) images)
    (dolist (attachment
             (append (msteams--get message 'attachments)
                     (msteams--inline-images message)))
      (let ((url (or (msteams--get attachment 'contentUrl)
                     (msteams--get attachment 'webUrl))))
        (when (and (msteams--image-attachment-p attachment)
                   (stringp url) (not (gethash url seen)))
          (puthash url t seen)
          (push attachment images))))
    (nreverse images)))

(defun msteams--image-extension (attachment)
  "Return a conservative filename extension for ATTACHMENT."
  (let* ((name (or (msteams--get attachment 'name) ""))
         (extension (downcase (or (file-name-extension name) "")))
         (content-type (downcase
                        (or (msteams--get attachment 'contentType) ""))))
    (cond
     ((member extension '("png" "jpg" "jpeg" "gif" "webp" "bmp" "tif" "tiff"))
      extension)
     ((string-match "image/\\(jpeg\\|png\\|gif\\|webp\\|bmp\\|tiff\\)"
                    content-type)
      (if (equal (match-string 1 content-type) "jpeg")
          "jpg"
        (match-string 1 content-type)))
     (t "png"))))

(defun msteams--image-cache-path (attachment)
  "Return the private cache path for ATTACHMENT."
  (let ((url (or (msteams--get attachment 'contentUrl)
                 (msteams--get attachment 'webUrl))))
    (expand-file-name
     (format "%s.%s" (secure-hash 'sha256 (or url "missing-image-url"))
             (msteams--image-extension attachment))
     msteams-image-cache-directory)))

(defun msteams--image-cache-ready-p (path)
  "Return non-nil when PATH contains a usable cached image."
  (when (file-readable-p path)
    (when-let ((attributes (file-attributes path)))
      (> (file-attribute-size attributes) 0))))

(defun msteams--insert-loaded-image (path name)
  "Insert cached Teams image PATH with a clickable NAME label."
  (insert "  ")
  (insert-text-button
   (format "Image: %s" name)
   'action (lambda (_button) (find-file-other-window path))
   'follow-link t
   'face 'msteams-image-label
   'help-echo "Open image in another window")
  (insert "\n")
  (when (and (display-images-p) (file-readable-p path))
    (condition-case nil
        (let* ((window (get-buffer-window (current-buffer) t))
               (window-width (and window (window-body-width window t)))
               (max-width
                (if (and (numberp window-width) (> window-width 0))
                    (min msteams-image-max-width
                         (max 120 (- window-width 32)))
                  msteams-image-max-width))
               (image (create-image path nil nil
                                    :max-width max-width
                                    :max-height msteams-image-max-height)))
          (when image
            (insert "  ")
            (insert-image image (format "[Image: %s]" name))
            (insert "\n")))
      (error nil))))

(defun msteams--replace-image-slot
    (buffer marker token path name &optional failure)
  "Replace an image placeholder in BUFFER at MARKER matching TOKEN.

PATH and NAME describe the cached image.  With FAILURE non-nil, render a
nonfatal unavailable label instead."
  (when (and (buffer-live-p buffer) (marker-position marker))
    (with-current-buffer buffer
      (save-excursion
        (let ((inhibit-read-only t)
              (position (marker-position marker)))
          (when (equal token (get-text-property position 'msteams-image-token))
            (let ((end (next-single-property-change
                        position 'msteams-image-token nil (point-max)))
                  (message (get-text-property position 'msteams-message)))
              (delete-region position end)
              (goto-char position)
              (if failure
                  (insert (propertize (format "  Image unavailable: %s\n" name)
                                      'face 'shadow))
                (msteams--insert-loaded-image path name))
              (when message
                (add-text-properties position (point)
                                     (list 'msteams-message message
                                           'rear-nonsticky
                                           '(msteams-message))))))))))
  (set-marker marker nil))

(defun msteams--finish-image-process (buffer process)
  "Retire PROCESS from BUFFER and start its next queued image."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq msteams--image-processes
            (delq process msteams--image-processes)
            msteams--image-active
            (max 0 (1- msteams--image-active)))
      (msteams--pump-image-queue))))

(defun msteams--start-image-job (job)
  "Start one queued image download JOB in the current buffer."
  (pcase-let* ((`(,attachment ,marker ,token) job)
               (buffer (current-buffer))
               (url (or (msteams--get attachment 'contentUrl)
                        (msteams--get attachment 'webUrl)))
               (name (or (msteams--get attachment 'name) "image"))
               (path (msteams--image-cache-path attachment))
               (process nil))
    (make-directory msteams-image-cache-directory t)
    (set-file-modes msteams-image-cache-directory #o700)
    (setq process
          (msteams--run-json
           (list "teams" "attachment" "download"
                 "--url" url "--destination" path)
           (lambda (payload)
             (let ((downloaded (or (msteams--get payload 'path) path)))
               (msteams--replace-image-slot
                buffer marker token downloaded name
                (not (msteams--image-cache-ready-p downloaded))))
             (msteams--finish-image-process buffer process))
           (lambda (_status _detail)
             (msteams--replace-image-slot
              buffer marker token path name t)
             (msteams--finish-image-process buffer process))))
    (push process msteams--image-processes)))

(defun msteams--pump-image-queue ()
  "Start queued transcript images up to the configured concurrency bound."
  (let ((limit (max 1 msteams-image-download-concurrency)))
    (while (and msteams--image-queue
                (< msteams--image-active limit))
      (let ((job (pop msteams--image-queue)))
        (cl-incf msteams--image-active)
        (condition-case nil
            (msteams--start-image-job job)
          (error
           (cl-decf msteams--image-active)
           (pcase-let ((`(,attachment ,marker ,token) job))
             (msteams--replace-image-slot
              (current-buffer) marker token
              (msteams--image-cache-path attachment)
              (or (msteams--get attachment 'name) "image") t))))))))

(defun msteams--queue-image (attachment marker token)
  "Queue ATTACHMENT for the placeholder at MARKER matching TOKEN."
  (setq msteams--image-queue
        (nconc msteams--image-queue
               (list (list attachment marker token))))
  (msteams--pump-image-queue))

(defun msteams--insert-message-images (message &optional images)
  "Insert and asynchronously load MESSAGE IMAGES."
  (when msteams-display-images
    (dolist (attachment (or images (msteams--message-images message)))
      (let* ((name (or (msteams--get attachment 'name) "image"))
             (path (msteams--image-cache-path attachment))
             (token (format "%s:%s"
                            (or (msteams--get message 'id) "message")
                            (secure-hash 'sha256
                                         (or (msteams--get attachment 'contentUrl)
                                             name))))
             (start (point)))
        (cond
         ((msteams--image-cache-ready-p path)
          (msteams--insert-loaded-image path name))
         (msteams-offline-mode
          (insert (propertize (format "  Image not cached: %s\n" name)
                              'face 'shadow)))
         (t
          (insert (propertize (format "  Loading image: %s\n" name)
                              'face 'shadow
                              'msteams-image-token token))
          (msteams--queue-image attachment
                                         (copy-marker start) token)))))))

(defun msteams--reference-attachment-p (attachment)
  "Return non-nil when ATTACHMENT is a quoted or forwarded message reference."
  (member (msteams--get attachment 'contentType)
          '("messageReference" "forwardedMessageReference")))

(defun msteams--attachment-content-object (attachment)
  "Parse ATTACHMENT's structured content, returning nil for invalid content."
  (let ((content (msteams--get attachment 'content)))
    (cond
     ((listp content) content)
     ((stringp content)
      (condition-case nil
          (json-parse-string content :object-type 'alist :array-type 'list
                             :null-object nil :false-object nil)
        (error nil))))))

(defun msteams--insert-card-link (label url indent)
  "Insert a card link with LABEL, URL, and string INDENT."
  (when (and (stringp url) (not (string-empty-p url)))
    (insert indent)
    (insert-text-button (or label url)
                        'action (lambda (_button) (browse-url url))
                        'follow-link t)
    (insert "\n")))

(defun msteams--insert-card-actions (actions indent)
  "Insert supported card ACTIONS using string INDENT."
  (dolist (action (msteams--payload-list actions))
    (let ((type (or (msteams--get action 'type) ""))
          (title (or (msteams--get action 'title) "Open"))
          (url (or (msteams--get action 'url)
                   (msteams--get action 'target))))
      (when (or (string-match-p "OpenUrl\\'" type) (stringp url))
        (msteams--insert-card-link title url indent)))))

(defun msteams--insert-card-elements (elements indent)
  "Insert Adaptive Card ELEMENTS using string INDENT."
  (dolist (element (msteams--payload-list elements))
    (let ((type (or (msteams--get element 'type) "")))
      (pcase type
        ((or "TextBlock" "RichTextBlock")
         (when-let ((text (or (msteams--get element 'text)
                              (msteams--get element 'altText))))
           (insert indent (msteams--html-to-text text) "\n")))
        ("FactSet"
         (dolist (fact (msteams--payload-list
                        (msteams--get element 'facts)))
           (insert indent
                   (or (msteams--get fact 'title) "")
                   (if (msteams--get fact 'title) ": " "")
                   (msteams--html-to-text
                    (or (msteams--get fact 'value) ""))
                   "\n")))
        ((or "Container" "Column")
         (msteams--insert-card-elements
          (msteams--get element 'items) indent))
        ("ColumnSet"
         (dolist (column (msteams--payload-list
                          (msteams--get element 'columns)))
           (msteams--insert-card-elements
            (msteams--get column 'items) indent)))
        ("Image"
         (msteams--insert-card-link
          (or (msteams--get element 'altText) "Card image")
          (msteams--get element 'url) indent))
        ("ActionSet"
         (msteams--insert-card-actions
          (msteams--get element 'actions) indent))
        (_
         (when-let ((text (or (msteams--get element 'text)
                              (msteams--get element 'title))))
           (insert indent (msteams--html-to-text text) "\n")))))))

(defun msteams--insert-rich-attachment (attachment)
  "Render structured ATTACHMENT and return non-nil when it is a Teams card."
  (let ((content-type (or (msteams--get attachment 'contentType) "")))
    (when (string-match-p
           "\\`application/vnd\\.microsoft\\.card\\." content-type)
      (let* ((content (msteams--attachment-content-object attachment))
             (name (or (msteams--get attachment 'name)
                       (and content (msteams--get content 'title))
                       "Teams card")))
        (insert (propertize (format "  %s\n" name) 'face 'bold))
        (cond
         ((string-match-p "codesnippet\\'" content-type)
          (let ((language (and content (msteams--get content 'language)))
                (code (and content (msteams--get content 'code))))
            (when language (insert (propertize (format "  %s\n" language)
                                               'face 'shadow)))
            (when (stringp code)
              (dolist (line (string-lines code))
                (insert (propertize (concat "    " line "\n")
                                    'face 'fixed-pitch))))))
         (content
          (dolist (key '(subtitle subTitle text summary))
            (when-let ((text (msteams--get content key)))
              (when (stringp text)
                (insert "  " (msteams--html-to-text text) "\n"))))
          (msteams--insert-card-elements
           (msteams--get content 'body) "  ")
          (msteams--insert-card-actions
           (msteams--get content 'actions) "  "))
         (t (insert (propertize "  Card content is unavailable\n"
                                'face 'shadow))))
        t))))

(defun msteams--insert-attachments (message)
  "Insert attachment links and structured cards from MESSAGE."
  (dolist (attachment (msteams--get message 'attachments))
    (unless (or (msteams--reference-attachment-p attachment)
                (and msteams-display-images
                     (msteams--image-attachment-p attachment)))
      (unless (msteams--insert-rich-attachment attachment)
        (let ((name (or (msteams--get attachment 'name)
                        (msteams--get attachment 'contentType)
                        "attachment"))
              (url (or (msteams--get attachment 'contentUrl)
                       (msteams--get attachment 'webUrl))))
          (insert "  Attachment: ")
          (if (and (stringp url) (not (string-empty-p url)))
              (insert-text-button name
                                  'action (lambda (_button) (browse-url url))
                                  'follow-link t)
            (insert name))
          (insert "\n"))))))

(defun msteams--message-reference (message)
  "Return the first parsed quoted or forwarded reference in MESSAGE."
  (seq-some
   (lambda (attachment)
     (when (msteams--reference-attachment-p attachment)
       (let ((content (msteams--get attachment 'content)))
         (cond
          ((listp content) content)
          ((stringp content)
           (condition-case nil
               (json-parse-string content :object-type 'alist
                                  :array-type 'list :null-object nil)
             (error nil)))))))
   (msteams--get message 'attachments)))

(defun msteams--insert-message-reference (message)
  "Insert MESSAGE's quoted-reply reference when present."
  (when-let* ((reference (msteams--message-reference message))
              (preview (msteams--get reference 'messagePreview)))
    (let ((sender (or (msteams--dig reference 'messageSender 'user 'displayName)
                      "Quoted message")))
      (insert (propertize (format "  > %s\n" sender) 'face 'shadow))
      (dolist (line (string-lines (msteams--html-to-text preview)))
        (insert (propertize (format "  > %s\n" line) 'face 'shadow))))))

(defun msteams--insert-day-separator (created)
  "Insert a day separator for ISO timestamp CREATED."
  (let ((label
         (condition-case nil
             (format-time-string "%A, %B %e, %Y" (date-to-time created))
           (error created))))
    (insert (propertize (format "\n%s\n\n" label)
                        'face 'msteams-day-separator))))

(defun msteams--insert-message (message)
  "Insert one Teams MESSAGE into the current transcript."
  (let ((start (point))
        (sender (msteams--message-sender message))
        (created (msteams--get message 'createdDateTime))
        (body (msteams--message-body message))
        (images (msteams--message-images message))
        (reactions (msteams--reaction-summary message))
        (own (msteams--message-own-p message)))
    (insert (propertize (if own "You" sender)
                        'face (if own
                                  'msteams-own-sender
                                'msteams-other-sender)))
    (insert (propertize (format "  %s" (msteams--format-date created t))
                        'face 'shadow))
    (when (msteams--get message 'lastEditedDateTime)
      (insert (propertize "  edited" 'face 'shadow)))
    (insert "\n")
    (msteams--insert-message-reference message)
    (cond
     ((not (string-empty-p body))
      (insert (if (msteams--system-event-p message)
                  (propertize body 'face 'msteams-event)
                body)
              "\n"))
     ((and (null images)
           (null (seq-remove
                  #'msteams--reference-attachment-p
                  (msteams--get message 'attachments))))
      (insert (propertize "[Empty message]\n" 'face 'shadow))))
    (msteams--insert-message-images message images)
    (msteams--insert-attachments message)
    (when (and reactions (not (string-empty-p reactions)))
      (insert (propertize (format "  Reactions: %s\n" reactions) 'face 'shadow)))
    (insert "\n")
    (add-text-properties start (point)
                         (list 'msteams-message message
                               'rear-nonsticky '(msteams-message)))))

(defun msteams--event-date-time (event field)
  "Return EVENT's UTC dateTime string for FIELD."
  (when-let ((value (msteams--dig event field 'dateTime)))
    (let ((zone (msteams--dig event field 'timeZone)))
      (if (and (stringp zone)
               (string-equal (downcase zone) "utc")
               (not (string-match-p "\\(?:[zZ]\\|[+-][0-9][0-9]:[0-9][0-9]\\)\\'"
                                    value)))
          (concat value "Z")
        value))))

(defun msteams--format-meeting-time (value &optional date-only)
  "Format Graph date-time VALUE in the local Emacs timezone.

When DATE-ONLY is non-nil, omit the time of day."
  (when (stringp value)
    (condition-case nil
        (format-time-string (if date-only "%a, %b %e, %Y" "%a, %b %e, %Y %H:%M")
                            (date-to-time value))
      (error value))))

(defun msteams--meeting-event (chat)
  "Return the linked calendar event attached to meeting CHAT."
  (msteams--get (msteams--get chat 'meetingContext) 'event))

(defun msteams--meeting-start-time (chat)
  "Return meeting CHAT's start as an Emacs time value."
  (when-let ((value (msteams--event-date-time
                     (msteams--meeting-event chat) 'start)))
    (ignore-errors (date-to-time value))))

(defun msteams--meeting-end-time (chat)
  "Return meeting CHAT's end as an Emacs time value."
  (when-let ((value (msteams--event-date-time
                     (msteams--meeting-event chat) 'end)))
    (ignore-errors (date-to-time value))))

(defun msteams--meeting-location-label (chat)
  "Return a de-duplicated human-readable location for meeting CHAT."
  (let* ((event (msteams--meeting-event chat))
         (primary (msteams--dig event 'location 'displayName))
         (locations
          (delq nil
                (mapcar
                 (lambda (location)
                   (msteams--get location 'displayName))
                 (msteams--get event 'locations))))
         (labels
          (seq-uniq
           (seq-filter
            (lambda (label)
              (and (stringp label)
                   (not (string-empty-p (string-trim label)))))
            (append (and primary (list primary)) locations))
           #'string-equal)))
    (when labels (string-join labels ", "))))

(defun msteams--meeting-response (chat)
  "Return the signed-in user's calendar response symbol for meeting CHAT."
  (when-let ((response
              (msteams--dig (msteams--meeting-event chat)
                             'responseStatus 'response)))
    (intern (downcase response))))

(defun msteams--meeting-status-label (chat)
  "Return a concise calendar status label for meeting CHAT."
  (let* ((event (msteams--meeting-event chat))
         (start (msteams--meeting-start-time chat))
         (end (msteams--meeting-end-time chat))
         (now (current-time)))
    (cond
     ((msteams--get event 'isCancelled) "Cancelled")
     ((eq (msteams--meeting-response chat) 'declined) "Declined")
     ((and start end
           (not (time-less-p now start))
           (time-less-p now end))
      "In progress")
     ((eq (msteams--meeting-response chat) 'tentativelyaccepted)
      "Tentative")
     (t nil))))

(defun msteams--meeting-upcoming-p (chat)
  "Return non-nil when meeting CHAT is upcoming or currently in progress."
  (let* ((event (msteams--meeting-event chat))
         (start (msteams--meeting-start-time chat))
         (end (msteams--meeting-end-time chat))
         (boundary (or end start)))
    (and (msteams--meeting-chat-p chat)
         event boundary
         (not (msteams--get event 'isCancelled))
         (not (eq (msteams--meeting-response chat) 'declined))
         (time-less-p (current-time) boundary))))

(defun msteams--meeting-starts-before-p (left right)
  "Return non-nil when meeting chat LEFT starts before RIGHT."
  (let ((left-time (msteams--meeting-start-time left))
        (right-time (msteams--meeting-start-time right)))
    (cond
     ((and left-time right-time)
      (if (time-equal-p left-time right-time)
          (msteams--chat-updated-p left right)
        (time-less-p left-time right-time)))
     (left-time t)
     (right-time nil)
     (t (msteams--chat-updated-p left right)))))

(defun msteams--meeting-row-label (chat)
  "Return compact local schedule and location text for meeting CHAT."
  (when (msteams--meeting-chat-p chat)
    (let* ((event (msteams--meeting-event chat))
           (start (msteams--meeting-start-time chat))
           (end (msteams--meeting-end-time chat))
           (all-day (msteams--get event 'isAllDay))
           (status (msteams--meeting-status-label chat))
           (location (msteams--meeting-location-label chat))
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
             (start (format-time-string "%a %b %e %H:%M" start))
             ((gethash (msteams--chat-id chat)
                       msteams--meeting-inflight)
              "Loading calendar...")
             ((msteams--get (msteams--get chat 'meetingContext) 'eventError)
              "Calendar unavailable"))))
      (string-join (delq nil (list status schedule location)) " | "))))

(defun msteams--meeting-time-label (chat)
  "Return a readable local start/end label for meeting CHAT."
  (let* ((event (msteams--meeting-event chat))
         (start-value (msteams--event-date-time event 'start))
         (end-value (msteams--event-date-time event 'end))
         (start-time (and start-value
                          (ignore-errors (date-to-time start-value))))
         (end-time (and end-value (ignore-errors (date-to-time end-value))))
         (all-day (msteams--get event 'isAllDay)))
    (cond
     ((and all-day start-value)
      (concat (msteams--format-meeting-time start-value t) " (all day)"))
     ((and start-time end-time
           (equal (format-time-string "%Y-%m-%d" start-time)
                  (format-time-string "%Y-%m-%d" end-time)))
      (format "%s-%s"
              (msteams--format-meeting-time start-value)
              (format-time-string "%H:%M" end-time)))
     (start-value
      (concat (msteams--format-meeting-time start-value)
              (when end-value
                (concat " - "
                        (msteams--format-meeting-time end-value)))))
     (t nil))))

(defun msteams--insert-meeting-banner ()
  "Insert time, place, status, participants, and join data for the meeting chat."
  (when (msteams--meeting-chat-p msteams--chat)
    (let* ((context (msteams--get msteams--chat 'meetingContext))
           (participants
            (msteams--meeting-participant-names msteams--chat))
           (when-label
            (or (msteams--meeting-time-label msteams--chat)
                (if (msteams--request-live-p
                     msteams--meeting-process)
                    "Loading calendar details..."
                  "Unavailable from the linked calendar")))
           (where-label
            (msteams--meeting-location-label msteams--chat))
           (status-label
            (msteams--meeting-status-label msteams--chat))
           (join-url
            (or (msteams--dig context 'event 'onlineMeeting 'joinUrl)
                (msteams--dig context 'onlineMeetingInfo 'joinWebUrl)
                (msteams--dig msteams--chat
                               'onlineMeetingInfo 'joinWebUrl))))
      (insert (propertize "Meeting details\n" 'face 'bold))
      (insert (format "When: %s\n" when-label))
      (when where-label (insert (format "Where: %s\n" where-label)))
      (when status-label (insert (format "Status: %s\n" status-label)))
      (insert (format "Participants: %s\n"
                      (if participants
                          (string-join participants ", ")
                        (if (msteams--request-live-p
                             msteams--meeting-process)
                            "Loading..."
                          "Unavailable"))))
      (when (stringp join-url)
        (insert-text-button "Join meeting"
                            'action (lambda (_button)
                                      (msteams--open-url-in-browser
                                       join-url))
                            'follow-link t)
        (insert "\n"))
      (insert "\n"))))

(defun msteams--load-meeting-context (chat)
  "Load calendar and participant context for meeting CHAT in this reader."
  (when (and (msteams--meeting-chat-p chat)
             (not msteams-offline-mode))
    (msteams--cancel-process msteams--meeting-process)
    (cl-incf msteams--meeting-request-id)
    (let ((buffer (current-buffer))
          (chat-id (msteams--chat-id chat))
          (request-id msteams--meeting-request-id))
      (setq
       msteams--meeting-process
       (msteams--fetch-meeting-context
        chat
        (lambda (context)
          (when (buffer-live-p buffer)
            (with-current-buffer buffer
              (when (and (= request-id msteams--meeting-request-id)
                         (derived-mode-p 'msteams-chat-mode)
                         (equal chat-id
                                (msteams--chat-id
                                 msteams--chat)))
                (setq msteams--meeting-process nil
                      msteams--meeting-context context)
                ;; If messages are still loading, their callback will render
                ;; once with this context instead of rebuilding the buffer twice.
                (when msteams--loaded-at
                  (msteams--render-chat))))))
        (lambda (status detail)
          (when (buffer-live-p buffer)
            (with-current-buffer buffer
              (when (= request-id msteams--meeting-request-id)
                (setq msteams--meeting-process nil))))
          (msteams--report-error
           (msteams--meeting-context-args chat) status detail)))))))

(defun msteams--goto-reader-bottom ()
  "Move the current reader and every visible window showing it to the bottom."
  (goto-char (point-max))
  (dolist (window (get-buffer-window-list (current-buffer) nil t))
    (set-window-point window (point-max))))

(defun msteams--render-chat ()
  "Render the current chat and its cached messages."
  (let ((inhibit-read-only t)
        (jump-to-bottom msteams--jump-to-bottom-on-render)
        (message-id
         (unless msteams--jump-to-bottom-on-render
           (or msteams--pending-message-id
               (msteams--get
                (msteams-message-at-point) 'id))))
        last-day)
    (msteams--cancel-image-loads)
    (erase-buffer)
    (insert (propertize (msteams--chat-label msteams--chat)
                        'face '(:height 1.25 :weight bold)))
    (insert "  ")
    (when (msteams--get msteams--chat 'webUrl)
      (insert-text-button "Open in Teams"
                          'action (lambda (_button)
                                    (msteams-open-in-browser))
                          'follow-link t))
    (insert "\n\n")
    (msteams--insert-meeting-banner)
    (if msteams--messages
        (dolist (message
                 (msteams--messages-for-display
                  msteams--messages))
          (let* ((created (or (msteams--get message 'createdDateTime) ""))
                 (day (car (split-string created "T"))))
            (unless (equal day last-day)
              (setq last-day day)
              (msteams--insert-day-separator created))
            (msteams--insert-message message)))
      (insert (propertize "No messages in the selected time window.\n" 'face 'shadow)))
    (setq msteams--pending-message-id nil)
    (cond
     (message-id
      (goto-char (point-min))
      (msteams--goto-message-id message-id))
     (jump-to-bottom
      (msteams--goto-reader-bottom))
     ((eq (msteams--effective-message-order) 'newest-first)
      (goto-char (point-min))
      (msteams-chat-next-message))
     (t
      (goto-char (point-max))
      (msteams-chat-previous-message)))
    (setq msteams--jump-to-bottom-on-render nil
          header-line-format
          (format "%s - %d messages - %s%s"
                  (msteams--chat-label msteams--chat)
                  (length msteams--messages)
                  (msteams--message-order-label)
                  (if msteams--loaded-all " - complete" "")))))

(define-derived-mode msteams-read-mode special-mode "Teams-Read"
  "Base mode for the singleton mu4e-style Teams message reader."
  (visual-line-mode 1)
  (add-hook 'kill-buffer-hook #'msteams--cancel-buffer-process nil t)
  (setq-local truncate-lines nil))

(defvar msteams-chat-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (define-key map (kbd "g") #'msteams-chat-run-headers-command)
    (define-key map (kbd "M-g") #'msteams-chat-refresh)
    (define-key map (kbd "G") #'msteams-chat-load-all)
    (define-key map (kbd "L") #'msteams-chat-load-more)
    (define-key map (kbd "S") #'msteams-chat-run-headers-command)
    (define-key map (kbd "M-S") #'msteams-toggle-message-order)
    (define-key map (kbd "c") #'msteams-send)
    (define-key map (kbd "C") #'msteams-send)
    (define-key map (kbd "s") #'msteams-chat-run-headers-command)
    (define-key map (kbd "r") #'msteams-chat-run-headers-command)
    (define-key map (kbd "R") #'msteams-reply)
    (define-key map (kbd "i") #'msteams-chat-run-headers-command)
    (define-key map (kbd "I") #'msteams-chat-run-headers-command)
    (define-key map (kbd "U") #'msteams-chat-run-headers-command)
    (define-key map (kbd "!") #'msteams-chat-run-headers-command)
    (define-key map (kbd "?") #'msteams-chat-run-headers-command)
    (define-key map (kbd "*") #'msteams-chat-run-headers-command)
    (define-key map (kbd "f") #'msteams-chat-run-headers-command)
    (define-key map (kbd "E") #'msteams-export-thread)
    (define-key map (kbd "Y") #'msteams-copy-thread-markdown)
    (define-key map (kbd "y") #'msteams-chat-back-to-inbox)
    (define-key map (kbd "M-y") #'msteams-copy-message)
    (define-key map (kbd "M-w") #'msteams-capture-message)
    (define-key map (kbd "o") #'msteams-open-in-browser)
    (define-key map (kbd "O") #'msteams-open-in-app)
    (define-key map (kbd "F") #'msteams-message-forward)
    (define-key map (kbd "M-F") #'msteams-chat-run-headers-command)
    (define-key map (kbd "n") #'msteams-chat-run-headers-command)
    (define-key map (kbd "p") #'msteams-chat-run-headers-command)
    (define-key map (kbd "j") #'msteams-thread-next)
    (define-key map (kbd "k") #'msteams-thread-previous)
    (define-key map (kbd "N") #'msteams-thread-next)
    (define-key map (kbd "P") #'msteams-thread-previous)
    (define-key map (kbd "]") #'msteams-chat-run-headers-command)
    (define-key map (kbd "[") #'msteams-chat-run-headers-command)
    (define-key map (kbd "M-j") #'msteams-chat-next-message)
    (define-key map (kbd "M-k") #'msteams-chat-previous-message)
    (define-key map (kbd "M-u") #'msteams-chat-run-headers-command)
    (define-key map (kbd "M") #'msteams-chat-run-headers-command)
    (define-key map (kbd "T") #'msteams-chat-run-headers-command)
    (define-key map (kbd "X") #'msteams-chat-run-headers-command)
    (define-key map (kbd "u") #'msteams-chat-run-headers-command)
    (define-key map (kbd "x") #'msteams-chat-run-headers-command)
    (define-key map (kbd "z") #'msteams-chat-run-headers-command)
    (define-key map (kbd "M-U") #'msteams-chat-run-headers-command)
    (define-key map (kbd "a") #'msteams-chat-run-headers-command)
    (define-key map (kbd "/") #'msteams-chat-run-headers-command)
    (define-key map (kbd "b") #'msteams-chat-run-headers-command)
    (define-key map (kbd "B") #'msteams-chat-run-headers-command)
    (define-key map (kbd "v") #'msteams-chat-run-headers-command)
    (define-key map (kbd "V") #'msteams-chat-run-headers-command)
    (define-key map (kbd "H") #'msteams-chat-run-headers-command)
    (define-key map (kbd "J") #'msteams-chat-run-headers-command)
    (define-key map (kbd "K") #'msteams-chat-run-headers-command)
    (define-key map (kbd "C-+") #'msteams-chat-run-headers-command)
    (define-key map (kbd "C-=") #'msteams-chat-run-headers-command)
    (define-key map (kbd "C--") #'msteams-chat-run-headers-command)
    (define-key map (kbd "q") #'msteams-chat-view-quit)
    (define-key map (kbd "h") #'msteams-chat-back-to-inbox)
    map)
  "Keymap for `msteams-chat-mode'.")

(define-derived-mode msteams-chat-mode msteams-read-mode
  "Teams-Read"
  "Major mode for reading a Microsoft Teams chat."
  nil)

(defun msteams--cancel-buffer-process ()
  "Cancel the current Teams buffer's pending Graph request."
  (when (timerp msteams--preview-timer)
    (cancel-timer msteams--preview-timer))
  (setq msteams--preview-timer nil)
  (msteams--cancel-process msteams--process)
  (msteams--cancel-process msteams--meeting-process)
  (cl-incf msteams--meeting-request-id)
  (setq msteams--process nil
        msteams--meeting-process nil)
  (msteams--cancel-image-loads))

(defun msteams--cancel-image-loads ()
  "Cancel image downloads owned by the current Teams transcript buffer."
  (dolist (process msteams--image-processes)
    (msteams--cancel-process process))
  (dolist (job msteams--image-queue)
    (set-marker (cadr job) nil))
  (setq msteams--image-processes nil
        msteams--image-queue nil
        msteams--image-active 0))

(defun msteams--display-chat-buffer (buffer preview)
  "Display thread BUFFER beside the inbox, preserving focus for PREVIEW."
  (let* ((index-buffer (msteams--recent-buffer))
         (index-window (and index-buffer (get-buffer-window index-buffer t))))
    (if (not (window-live-p index-window))
        (if preview (display-buffer buffer) (pop-to-buffer buffer))
      (let* ((existing (get-buffer-window buffer t))
             (available (window-total-width index-window))
             (index-size
              (max window-min-width
                   (min (- available window-min-width)
                        (floor (* (frame-width)
                                  msteams-index-width)))))
             (right (or existing
                        (window-in-direction 'right index-window)
                        (split-window index-window index-size 'right))))
        (set-window-buffer right buffer)
        (unless preview (select-window right))))))

(defun msteams--close-other-readers (keep-buffer)
  "Kill every Teams message reader except KEEP-BUFFER."
  (dolist (buffer (buffer-list))
    (unless (eq buffer keep-buffer)
      (with-current-buffer buffer
        (when (memq major-mode
                    '(msteams-read-mode
                      msteams-chat-mode
                      msteams-channel-thread-mode))
          (kill-buffer buffer))))))

(defun msteams--preview-cache-valid-p (chat)
  "Return non-nil when the current buffer can preview CHAT without a request."
  (and msteams--loaded-at
       (> msteams-preview-cache-seconds 0)
       (< (- (float-time) msteams--loaded-at)
          msteams-preview-cache-seconds)
       (equal msteams--loaded-update
              (msteams--get chat 'lastUpdatedDateTime))))

(defun msteams-open-chat (chat &optional preview all message-id)
  "Open native transcript buffer for CHAT.

When PREVIEW is non-nil, retain focus in the inbox window.  ALL requests
complete history, and MESSAGE-ID is selected after that history renders."
  (unless (msteams--chat-id chat)
    (user-error "The selected chat has no identifier"))
  (let ((buffer (get-buffer-create msteams--read-buffer-name)))
    (with-current-buffer buffer
      (unless (derived-mode-p 'msteams-chat-mode)
        (when (derived-mode-p 'msteams-read-mode)
          (msteams--cancel-buffer-process))
        (msteams-chat-mode))
      (let* ((previous-id
              (and msteams--chat
                   (msteams--chat-id msteams--chat)))
             (same-chat
              (equal previous-id (msteams--chat-id chat)))
             (reuse-preview
              (and preview same-chat (not all) (not message-id)
                   (msteams--preview-cache-valid-p chat)))
             (same-request-running
              (and preview same-chat
                   (msteams--request-live-p msteams--process))))
        (setq msteams--chat chat
              msteams--automatic-preview-p (not (null preview))
              msteams--pending-message-id message-id
              msteams--jump-to-bottom-on-render
              (and (not preview) (not message-id)))
        (unless same-chat
          (msteams--cancel-process msteams--meeting-process)
          (cl-incf msteams--meeting-request-id)
          (setq msteams--meeting-process nil)
          (msteams--cancel-image-loads)
          (setq msteams--messages nil
                msteams--loaded-at nil
                msteams--loaded-update nil
                msteams--loaded-all nil
                msteams--meeting-context
                (msteams--get chat 'meetingContext))
          (let ((inhibit-read-only t))
            (erase-buffer)
            (insert (format "Loading %s...\n"
                            (msteams--chat-label chat)))))
        (unless (or reuse-preview same-request-running)
          (let ((msteams--cache-first-open (not same-chat)))
            (msteams-chat-refresh
             all (and preview msteams-preview-message-limit))))
        (when (and (msteams--meeting-chat-p chat)
                   (not (msteams--get chat 'meetingContext))
                   (not (msteams--request-live-p
                         msteams--meeting-process)))
          (msteams--load-meeting-context chat))))
    (msteams--display-chat-buffer buffer preview)
    (msteams--close-other-readers buffer)
    (when (and msteams-mark-read-on-open
               (not msteams-offline-mode))
      (with-current-buffer buffer
        (msteams--set-read-state 'read t)))))

(defun msteams-close-inactive-transcripts ()
  "Close legacy hidden Teams transcripts while retaining the singleton reader."
  (interactive)
  (let (targets)
    (dolist (buffer (buffer-list))
      (with-current-buffer buffer
        (when (and (memq major-mode
                         '(msteams-chat-mode
                           msteams-channel-thread-mode))
                   (not (equal (buffer-name)
                               msteams--read-buffer-name))
                   (not (get-buffer-window buffer t)))
          (push buffer targets))))
    (dolist (buffer targets)
      (kill-buffer buffer))
    (message "Closed %d inactive Teams transcript%s"
             (length targets) (if (= (length targets) 1) "" "s"))))

(defun msteams-chat-back-to-inbox ()
  "Return focus to the native Teams inbox."
  (interactive)
  (if-let* ((buffer (msteams--recent-buffer))
            (window (get-buffer-window buffer t)))
      (select-window window)
    (msteams-inbox)))

(defun msteams--chat-refresh-cache-first (all request-limit)
  "Render cached messages, then refresh them from Graph.

This reads the existing SQLite cache and never creates another message store."
  (msteams--cancel-process msteams--process)
  (cl-incf msteams--request-id)
  (let* ((buffer (current-buffer))
         (request-id msteams--request-id)
         (chat msteams--chat)
         (chat-id (msteams--chat-id chat))
         (limit (or request-limit
                    msteams-preview-message-limit
                    msteams-message-limit
                    300))
         (args (list "teams" "cache" "chat" "message" "list"
                     "--chatId" chat-id
                     "--limit" (number-to-string limit)))
         request)
    (setq header-line-format "Loading cached Teams messages...")
    (setq
     request
     (msteams--run-json
      args
      (lambda (payload)
        (when (and (buffer-live-p buffer)
                   (= request-id msteams--request-id))
          (with-current-buffer buffer
            (when (and (derived-mode-p 'msteams-chat-mode)
                       (equal chat-id
                              (msteams--chat-id
                               msteams--chat)))
              (setq msteams--process nil)
              (let ((messages
                     (msteams--normalize-messages
                      (msteams--payload-list payload))))
                (when messages
                  (setq msteams--messages messages
                        msteams--loaded-all nil)
                  (let ((msteams-display-images nil))
                    (msteams--render-chat))))
              (let ((msteams--cache-first-open nil))
                (msteams-chat-refresh all request-limit))))))
      (lambda (_status _detail)
        (when (and (buffer-live-p buffer)
                   (= request-id msteams--request-id))
          (with-current-buffer buffer
            (setq msteams--process nil)
            (let ((msteams--cache-first-open nil))
              (msteams-chat-refresh all request-limit)))))))
    ;; Synchronous test backends can advance the generation in CALLBACK.
    (when (= request-id msteams--request-id)
      (setq msteams--process request))
    request))

(defun msteams-chat-refresh
    (&optional all request-limit ignore-date)
  "Refresh the current Teams chat.

With ALL non-nil, request complete history rather than the configured window.
REQUEST-LIMIT is an internal item bound.  IGNORE-DATE suppresses the normal
date window while retaining that bound, which supports incremental loading."
  (interactive "P")
  (unless (derived-mode-p 'msteams-chat-mode)
    (user-error "Not in a Teams chat buffer"))
  (if (and msteams--cache-first-open
           msteams-cache-first
           (not msteams-offline-mode)
           (not all)
           (not ignore-date))
      (msteams--chat-refresh-cache-first all request-limit)
    (msteams--cancel-process msteams--process)
    (cl-incf msteams--request-id)
    (let ((buffer (current-buffer))
          (request-id msteams--request-id)
          (chat msteams--chat))
      (setq header-line-format
            (if msteams--messages
                "Refreshing Teams messages..."
              "Loading Teams messages..."))
      (setq
       msteams--process
       (msteams--run-json
        (msteams--message-args chat all request-limit ignore-date)
        (lambda (payload)
          (when (buffer-live-p buffer)
            (with-current-buffer buffer
              (when (and (= request-id msteams--request-id)
                         (derived-mode-p 'msteams-chat-mode)
                         (equal (msteams--chat-id chat)
                                (and msteams--chat
                                     (msteams--chat-id
                                      msteams--chat))))
                (let* ((messages
                        (msteams--normalize-messages
                         (msteams--payload-list payload)))
                       (limit (and (not all)
                                   (or request-limit
                                       msteams-message-limit))))
                  (when (and limit (> (length messages) limit))
                    (setq messages (last messages limit)))
                  (setq msteams--messages messages
                        msteams--process nil
                        msteams--loaded-at (float-time)
                        msteams--loaded-update
                        (msteams--get chat 'lastUpdatedDateTime)
                        msteams--loaded-all
                        (or (not (null all))
                            (and ignore-date request-limit
                                 (< (length messages) request-limit))))
                  (msteams--render-chat))))))
        (lambda (status detail)
          (when (buffer-live-p buffer)
            (with-current-buffer buffer
              (when (and (= request-id msteams--request-id)
                         (derived-mode-p 'msteams-chat-mode)
                         (equal (msteams--chat-id chat)
                                (and msteams--chat
                                     (msteams--chat-id
                                      msteams--chat))))
                (setq msteams--process nil
                      header-line-format
                      (if msteams--messages
                          (concat "Showing cached Teams messages; live refresh "
                                  "failed - see *M365 Errors*")
                        "Teams thread load failed - see *M365 Errors*")))))
          (msteams--report-error
           (msteams--message-args
            chat all request-limit ignore-date)
           status detail)))))))

(defun msteams-chat-load-all ()
  "Refresh the current chat with complete history."
  (interactive)
  (msteams-chat-refresh t))

(defun msteams-chat-load-more (&optional count)
  "Load COUNT additional older messages into the current chat.

Without a prefix argument, use `msteams-load-more-count'.  This expands
the newest-message bound without applying the normal date window."
  (interactive "P")
  (unless (derived-mode-p 'msteams-chat-mode)
    (user-error "Not in a Teams chat buffer"))
  (when msteams--loaded-all
    (user-error "The complete Teams chat is already loaded"))
  (let ((step (if count
                  (prefix-numeric-value count)
                msteams-load-more-count)))
    (unless (> step 0)
      (user-error "Message increment must be positive"))
    (msteams-chat-refresh
     nil (+ (length msteams--messages) step) t)))

(defun msteams-message-at-point ()
  "Return the Teams message represented at point."
  (or (get-text-property (point) 'msteams-message)
      (and (> (point) (point-min))
           (get-text-property (1- (point)) 'msteams-message))))

(defun msteams--message-positions ()
  "Return starts of every rendered message region in the current buffer."
  (let ((position (point-min)) result)
    (while (< position (point-max))
      (let ((message (get-text-property position 'msteams-message))
            (next (next-single-property-change
                   position 'msteams-message nil (point-max))))
        (when message (push position result))
        (setq position (max (1+ position) next))))
    (nreverse result)))

(defun msteams--message-position-index (positions)
  "Return the index in POSITIONS of the message containing point."
  (when-let* ((message (get-text-property (point) 'msteams-message))
              (message-id (msteams--get message 'id)))
    (cl-position
     message-id positions
     :key (lambda (position)
            (msteams--get
             (get-text-property position 'msteams-message) 'id))
     :test #'equal)))

(defun msteams--message-relative-position (delta)
  "Return the rendered message position DELTA messages from point."
  (let* ((positions (msteams--message-positions))
         (index (msteams--message-position-index positions))
         (target-index (and index (+ index delta))))
    (if index
        (when (and (>= target-index 0) (< target-index (length positions)))
          (nth target-index positions))
      (if (> delta 0)
          (seq-find (lambda (candidate) (> candidate (point))) positions)
        (car (last (seq-take-while
                    (lambda (candidate) (< candidate (point))) positions)))))))

(defun msteams--goto-message-id (message-id)
  "Move to rendered MESSAGE-ID and return non-nil when found."
  (let ((position
         (seq-find
          (lambda (candidate)
            (equal message-id
                   (msteams--get
                    (get-text-property candidate 'msteams-message) 'id)))
          (msteams--message-positions))))
    (when position (goto-char position) t)))

(defun msteams-chat-next-message ()
  "Move point to the next message block in the current transcript."
  (interactive)
  (let ((position (msteams--message-relative-position 1)))
    (when position (goto-char position))))

(defun msteams-chat-previous-message ()
  "Move point to the previous message block in the current transcript."
  (interactive)
  (let ((position (msteams--message-relative-position -1)))
    (when position (goto-char position))))

(defconst msteams--participant-choice
  "Find one-to-one chat by participant email..."
  "Special completion choice for resolving a direct chat.")

(defun msteams--resolve-participant (callback)
  "Prompt for a participant email and pass the matching chat to CALLBACK."
  (let ((email (string-trim (read-string "Teams participant email: "))))
    (when (string-empty-p email) (user-error "Email is required"))
    (msteams--run-json
     (list "teams" "chat" "get" "--participants" email)
     callback)))

(defun msteams--choose-chat (chats callback)
  "Prompt for one of CHATS and invoke CALLBACK with it."
  (let* ((pairs (mapcar (lambda (chat)
                          (cons (msteams--chat-choice chat) chat))
                        chats))
         (choice (completing-read
                  "Teams chat: "
                  (cons msteams--participant-choice (mapcar #'car pairs))
                  nil t)))
    (if (equal choice msteams--participant-choice)
        (msteams--resolve-participant callback)
      (funcall callback (cdr (assoc choice pairs))))))

(defun msteams--select-chat (callback)
  "Load, prompt for, and pass a Teams chat to CALLBACK."
  (let ((origin (current-buffer)))
    (msteams--with-status
     (lambda ()
       (msteams--load-chats
        (lambda (chats)
          (msteams--choose-chat
           chats
           (lambda (chat)
             (if (buffer-live-p origin)
                 (with-current-buffer origin (funcall callback chat))
               (funcall callback chat))))))))))

;;;###autoload
(defun msteams-chat (&optional participant)
  "Select and open a Teams chat.

With PARTICIPANT non-nil, resolve a one-to-one chat by participant email."
  (interactive "P")
  (if participant
      (msteams--with-status
       (lambda ()
         (msteams--resolve-participant #'msteams-open-chat)))
    (msteams--select-chat #'msteams-open-chat)))

(defvar msteams-compose-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map text-mode-map)
    (define-key map (kbd "C-c C-c") #'msteams-compose-send)
    (define-key map (kbd "C-c C-k") #'msteams-compose-abort)
    map)
  "Keymap for `msteams-compose-mode'.")

(define-derived-mode msteams-compose-mode text-mode "Teams-Compose"
  "Major mode for composing a Microsoft Teams chat message."
  (visual-line-mode 1)
  (setq-local require-final-newline nil))

(defun msteams--target-label (target)
  "Return a human-readable label for message TARGET."
  (or (and (keywordp (car-safe target)) (plist-get target :label))
      (and (msteams--chat-id target)
           (msteams--chat-label target))
      "Teams"))

(defun msteams--compose-target-key (target &optional reply-to)
  "Return stable non-secret key for TARGET and optional REPLY-TO message."
  (let* ((base
          (or (msteams--chat-id target)
              (and (keywordp (car-safe target))
                   (or (and (plist-get target :team-id)
                            (format "%s/%s"
                                    (plist-get target :team-id)
                                    (plist-get target :channel-id)))
                       (plist-get target :user-emails)))
              "unknown"))
         (reply-id (msteams--get reply-to 'id)))
    (if (and (stringp reply-id) (not (string-empty-p reply-id)))
        (format "%s/reply/%s" base reply-id)
      base)))

(defun msteams--compose-buffer-name (target &optional reply-to)
  "Return stable compose buffer name for TARGET and optional REPLY-TO."
  (format "*Teams Compose: %s [%s]*"
          (msteams--target-label target)
          (substring (md5 (msteams--compose-target-key target reply-to))
                     0 6)))

(defun msteams--open-compose (target &optional reply-to initial)
  "Open a multiline compose buffer for TARGET, optionally replying to REPLY-TO.

INITIAL, when non-nil, is inserted into an otherwise empty compose buffer."
  (let* ((origin (current-buffer))
         (label (msteams--target-label target))
         (name (msteams--compose-buffer-name target reply-to))
         (existing (get-buffer name))
         (buffer
          (get-buffer-create name))
         (fresh (not existing)))
    (pop-to-buffer buffer)
    (unless (derived-mode-p 'msteams-compose-mode)
      (msteams-compose-mode)
      (setq fresh t))
    (setq msteams-compose--target target
          msteams-compose--origin origin
          msteams-compose--reply-to reply-to)
    (when fresh
      (setq msteams-compose--attachments nil
            msteams-compose--mentions nil
            msteams-compose--content-type
            msteams-default-content-type)
      (when (fboundp 'msteams-compose--initialize-draft)
        (msteams-compose--initialize-draft))
      (when (and initial (= (buffer-size) 0))
        (insert initial)))
    (if (fboundp 'msteams-compose--update-header)
        (msteams-compose--update-header)
      (setq header-line-format
            (format "%s: %s [%s]    C-c C-c send    C-c C-k abort"
                    (if reply-to
                        (format "Reply to %s"
                                (msteams--message-sender reply-to))
                      "To")
                    label msteams-compose--content-type)))
    (goto-char (point-max))))

;;;###autoload
(defun msteams-send (&optional participant)
  "Compose a Teams message for the current or selected chat.

With PARTICIPANT non-nil, prompt for recipient email instead of selecting an
existing chat."
  (interactive "P")
  (cond
   (participant
    (let ((email (string-trim (read-string "Teams recipient email: "))))
      (when (string-empty-p email) (user-error "Email is required"))
      (msteams--open-compose
       (list :user-emails email :label email))))
   ((msteams--chat-at-point)
    (msteams--open-compose (msteams--chat-at-point)))
   (t
    (msteams--select-chat #'msteams--open-compose))))

(defun msteams-reply ()
  "Reply to the message at point or the selected chat's latest preview."
  (interactive)
  (let* ((chat (msteams--chat-at-point))
         (message
          (cond
           ((derived-mode-p 'msteams-chat-mode)
            (msteams-message-at-point))
           ((derived-mode-p 'msteams-recent-mode)
            (msteams--get chat 'lastMessagePreview)))))
    (unless chat (user-error "Move to a Teams chat or inbox row first"))
    (unless message
      (user-error "The selected chat has no loaded message to reply to"))
    (msteams--open-compose chat message)))

(defun msteams--send-args
    (target message &optional reply-to attachments mentions content-type)
  "Build Graph-backend arguments to send MESSAGE to TARGET.

REPLY-TO, when non-nil, is the source message for a native quoted reply."
  (let ((chat-id (msteams--chat-id target))
        (emails (and (keywordp (car-safe target))
                     (plist-get target :user-emails)))
        (team-id (and (keywordp (car-safe target))
                      (plist-get target :team-id)))
        (channel-id (and (keywordp (car-safe target))
                         (plist-get target :channel-id)))
        (reply-id (and reply-to (msteams--get reply-to 'id))))
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

(defun msteams-compose-send ()
  "Send the current compose buffer through Microsoft Graph."
  (interactive)
  (msteams--require-online)
  (unless (derived-mode-p 'msteams-compose-mode)
    (user-error "Not in a Teams compose buffer"))
  (let* ((buffer (current-buffer))
         (target msteams-compose--target)
         (reply-to msteams-compose--reply-to)
         (attachments msteams-compose--attachments)
         (mentions msteams-compose--mentions)
         (content-type msteams-compose--content-type)
         (origin msteams-compose--origin)
         (message-text (string-trim (buffer-substring-no-properties
                                     (point-min) (point-max))))
         (label (msteams--target-label target))
         args)
    (when (and (string-empty-p message-text) (null attachments))
      (user-error "Message and attachment list are empty"))
    (setq args
          (msteams--send-args
           target message-text reply-to attachments mentions content-type))
    (when (or (not msteams-confirm-send)
              (yes-or-no-p (format "Send this message to %s? " label)))
      (setq header-line-format (format "Sending to %s..." label))
      (msteams--run
       args
       (lambda (_output)
         (when (and (buffer-live-p buffer)
                    (fboundp 'msteams-compose--delete-draft))
           (with-current-buffer buffer
             (msteams-compose--delete-draft)))
         (when (buffer-live-p buffer) (kill-buffer buffer))
         (message "Teams message sent to %s" label)
         (when (buffer-live-p origin)
           (with-current-buffer origin
             (cond
              ((derived-mode-p 'msteams-chat-mode)
               (msteams-chat-refresh))
              ((derived-mode-p 'msteams-recent-mode)
               (msteams-recent-refresh))
              ((and (fboundp 'msteams-channel-thread-refresh)
                    (derived-mode-p 'msteams-channel-thread-mode))
               (msteams-channel-thread-refresh))
              ((and (fboundp 'msteams-channel-refresh)
                    (derived-mode-p 'msteams-channel-index-mode))
               (msteams-channel-refresh))))))
       (lambda (status detail)
         (when (buffer-live-p buffer)
           (with-current-buffer buffer
             (setq header-line-format
                   (format "Send to %s failed - see *M365 Errors*" label))
             (when (fboundp 'msteams-compose--save-draft)
               (msteams-compose--save-draft))))
         (msteams--report-error args status detail))))))

(defun msteams-compose-abort ()
  "Discard the current Teams compose buffer after confirmation."
  (interactive)
  (when (or (= (buffer-size) 0)
            (yes-or-no-p "Discard this Teams draft? "))
    (when (fboundp 'msteams-compose--delete-draft)
      (msteams-compose--delete-draft))
    (kill-buffer (current-buffer))))

(defconst msteams--web-host-regexp
  "\\(?:teams\\.microsoft\\.com\\|teams\\.cloud\\.microsoft\\)"
  "Official Teams web hosts accepted for web and desktop deep links.")

(defun msteams--browser-url (url)
  "Return URL routed directly to Teams web instead of its app launcher."
  (if (and
       (stringp url)
       (string-match
        (concat "\\`https://\\(" msteams--web-host-regexp
                "\\)\\(/l/[^#]*\\)\\'")
        url))
      (format "https://%s/#%s"
              (match-string 1 url) (match-string 2 url))
    url))

(defun msteams--open-with-command (url command description)
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
         :name (format "msteams-open-%s"
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

(defun msteams--open-url-in-browser (url)
  "Open Teams URL in the configured web browser command."
  (msteams--open-with-command
   (msteams--browser-url url)
   msteams-browser-command
   "Teams web"))

;;;###autoload
(defun msteams-open-in-browser ()
  "Open the current chat or message in the official Teams web interface."
  (interactive)
  (let* ((message (and (derived-mode-p 'msteams-chat-mode)
                       (msteams-message-at-point)))
         (chat (msteams--chat-at-point))
         (url (or (msteams--get message 'webUrl)
                  (msteams--get chat 'webUrl))))
    (unless (and (stringp url) (not (string-empty-p url)))
      (user-error "No Teams web URL is available here"))
    (msteams--open-url-in-browser url)))

(defun msteams--app-url (url)
  "Return the native Teams deep link corresponding to HTTPS URL."
  (cond
   ((and (stringp url) (string-prefix-p "msteams://" url)) url)
   ((and (stringp url)
         (string-match
          (concat "\\`https://\\(" msteams--web-host-regexp
                  "/.*\\)\\'")
          url))
    (concat "msteams://" (match-string 1 url)))
   (t (user-error "This item does not provide a native Teams deep link"))))

(defun msteams--open-url-in-app (url)
  "Open Teams HTTPS URL directly in the installed desktop application."
  (msteams--open-with-command
   (msteams--app-url url)
   msteams-app-command
   "Teams app"))

;;;###autoload
(defun msteams-open-in-app ()
  "Open the current chat or message directly in the Teams desktop app."
  (interactive)
  (let* ((message (and (derived-mode-p 'msteams-chat-mode)
                       (msteams-message-at-point)))
         (chat (msteams--chat-at-point))
         (url (or (msteams--get message 'webUrl)
                  (msteams--get chat 'webUrl))))
    (unless (and (stringp url) (not (string-empty-p url)))
      (user-error "No Teams URL is available here"))
    (msteams--open-url-in-app url)))

(defun msteams-copy-message ()
  "Copy the readable body of the Teams message at point."
  (interactive)
  (let ((message (msteams-message-at-point)))
    (unless message (user-error "Move point onto a Teams message first"))
    (kill-new (msteams--message-body message))
    (message "Copied Teams message")))

(defun msteams--dom-children-to-markdown (node)
  "Convert NODE's children to Markdown."
  (mapconcat #'msteams--dom-to-markdown (dom-children node) ""))

(defun msteams--dom-to-markdown (node)
  "Convert a libxml DOM NODE into conservative Markdown."
  (cond
   ((stringp node) (replace-regexp-in-string "\u00a0" " " node))
   ((not (consp node)) "")
   (t
    (let* ((tag (dom-tag node))
           (children (msteams--dom-children-to-markdown node))
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

(defun msteams--html-to-markdown (html)
  "Convert Teams HTML fragment HTML into readable Markdown."
  (if (not (and (stringp html) (string-match-p "<[^>]+>" html)))
      (string-trim (or html ""))
    (condition-case nil
        (with-temp-buffer
          (insert "<html><body>" html "</body></html>")
          (let* ((dom (libxml-parse-html-region (point-min) (point-max)))
                 (markdown (msteams--dom-to-markdown dom)))
            (string-trim
             (replace-regexp-in-string "\n\\{3,\\}" "\n\n" markdown))))
      (error (msteams--html-to-text html)))))

(defun msteams--message-markdown (message)
  "Return one complete Teams MESSAGE as Markdown."
  (let* ((sender (msteams--message-sender message))
         (created (msteams--get message 'createdDateTime))
         (content (msteams--dig message 'body 'content))
         (body (if (msteams--get message 'deletedDateTime)
                   "*[Deleted message]*"
                 (if (msteams--system-event-p message)
                     (format "*%s*" (msteams--event-summary message))
                   (msteams--html-to-markdown content))))
         (reference (msteams--message-reference message))
         (reactions (msteams--reaction-summary message))
         attachments)
    (dolist (attachment (msteams--get message 'attachments))
      (unless (msteams--reference-attachment-p attachment)
        (let ((name (or (msteams--get attachment 'name) "Attachment"))
              (url (or (msteams--get attachment 'contentUrl)
                       (msteams--get attachment 'webUrl))))
          (push (if (stringp url) (format "[%s](%s)" name url) name)
                attachments))))
    (concat
     (format "### %s - %s\n\n" sender (msteams--format-date created t))
     (when reference
       (let ((quoted-sender
              (or (msteams--dig reference 'messageSender 'user 'displayName)
                  "Quoted message"))
             (preview (or (msteams--get reference 'messagePreview) "")))
         (concat (format "> **%s**\n" quoted-sender)
                 (mapconcat (lambda (line) (concat "> " line))
                            (string-lines (msteams--html-to-text preview)) "\n")
                 "\n\n")))
     (if (string-empty-p body) "*[Empty message]*" body)
     "\n\n"
     (when attachments
       (format "**Attachments:** %s\n\n"
               (string-join (nreverse attachments) ", ")))
     (when (and reactions (not (string-empty-p reactions)))
       (format "*Reactions: %s*\n\n" reactions)))))

(defun msteams--thread-markdown (chat messages)
  "Return complete CHAT MESSAGES as a portable Markdown document."
  (let ((title (msteams--chat-label chat))
        (url (msteams--get chat 'webUrl))
        (last-day nil))
    (concat
     "# " title "\n\n"
     (format "- Exported: %s\n" (format-time-string "%Y-%m-%d %H:%M %Z"))
     (format "- Teams chat ID: `%s`\n" (msteams--chat-id chat))
     (when (stringp url) (format "- [Open in Microsoft Teams](%s)\n" url))
     "\n"
     (mapconcat
      (lambda (message)
        (let* ((created (or (msteams--get message 'createdDateTime) ""))
               (day (car (split-string created "T")))
               (heading (unless (equal day last-day)
                          (setq last-day day)
                          (format "## %s\n\n" day))))
          (concat heading (msteams--message-markdown message))))
      (msteams--normalize-messages messages)
      ""))))

(defun msteams--export-path (chat)
  "Return the deterministic Markdown export path for CHAT."
  (let* ((label (downcase (msteams--chat-label chat)))
         (slug (replace-regexp-in-string "[^[:alnum:]]+" "-" label))
         (slug (truncate-string-to-width (string-trim slug "-+" "-+") 80))
         (slug (string-trim-right slug "-+")))
    (expand-file-name
     (format "%s-%s-%s.md"
             (format-time-string "%Y-%m-%d")
             (if (string-empty-p slug) "teams-thread" slug)
             (msteams--short-id chat))
     msteams-export-directory)))

(defun msteams--write-thread-export (path chat messages)
  "Write CHAT MESSAGES to Markdown PATH with private permissions."
  (make-directory (file-name-directory path) t)
  (with-temp-file path
    (insert (msteams--thread-markdown chat messages)))
  (set-file-modes path #o600)
  path)

(defun msteams--finish-thread-export
    (chat messages open &optional after-export)
  "Write complete CHAT MESSAGES and finish the export operation.

When OPEN is non-nil, visit the file.  When AFTER-EXPORT is non-nil, call it
with the absolute saved path after the mode-0600 file has been written."
  (let* ((path (msteams--export-path chat))
         (saved-path
          (msteams--write-thread-export path chat messages)))
    (cond
     (after-export
      (funcall after-export saved-path))
     (open
      (find-file-other-window saved-path))
     (t
      (message "Exported Teams thread to %s"
               (abbreviate-file-name saved-path))))
    saved-path))

(defun msteams--copy-thread-markdown (chat messages)
  "Copy complete CHAT MESSAGES to the kill ring as Markdown."
  (let ((markdown (msteams--thread-markdown chat messages)))
    (kill-new markdown)
    (message "Copied complete Teams thread as Markdown (%d messages)"
             (length messages))
    markdown))

(defun msteams--copy-chat-thread-markdown (chat)
  "Fetch and copy complete CHAT history as Markdown."
  (message "Copying complete Teams history for %s..."
           (msteams--chat-label chat))
  (msteams--run-json
   (msteams--message-args chat t)
   (lambda (payload)
     (msteams--copy-thread-markdown
      chat (msteams--payload-list payload)))))

(defun msteams--export-thread (chat open &optional after-export)
  "Export complete CHAT history, visiting the output when OPEN is non-nil.

Call AFTER-EXPORT with the saved path when it is non-nil."
  (message "Exporting complete Teams history for %s..."
           (msteams--chat-label chat))
  (msteams--run-json
   (msteams--message-args chat t)
   (lambda (payload)
     (msteams--finish-thread-export
      chat (msteams--payload-list payload) open after-export))))

(defun msteams-export-thread (&optional open)
  "Download a complete Teams thread as Markdown.

Use the chat at point or current thread; otherwise prompt for a chat.  With
prefix argument OPEN, visit the exported file after writing it."
  (interactive "P")
  (if-let ((chat (msteams--chat-at-point)))
      (msteams--export-thread chat open)
    (msteams--select-chat
     (lambda (selected) (msteams--export-thread selected open)))))

(defun msteams-copy-thread-markdown ()
  "Fetch and copy a complete Teams chat as Markdown.

Use the chat at point or current thread; otherwise prompt for a chat."
  (interactive)
  (if-let ((chat (msteams--chat-at-point)))
      (msteams--copy-chat-thread-markdown chat)
    (msteams--select-chat
     #'msteams--copy-chat-thread-markdown)))

(defun msteams--capture-file ()
  "Resolve the local Org capture file for Teams messages and threads."
  (expand-file-name
   (or msteams-capture-file
       (expand-file-name
        "teams.org"
        (or (and (boundp 'org-directory) org-directory)
            (expand-file-name "Documents" "~"))))))

(defun msteams--capture-property (property)
  "Return inherited Org PROPERTY at point as a nonempty string."
  (let ((value (org-entry-get nil property t)))
    (and (stringp value) (not (string-empty-p value)) value)))

(defun msteams--capture-context-match-p (context)
  "Return non-nil when the Org entry at point represents CONTEXT."
  (let ((chat-id (msteams--get context 'chatId))
        (team-id (msteams--get context 'teamId))
        (channel-id (msteams--get context 'channelId))
        (thread-id (msteams--get context 'threadId)))
    (if (stringp chat-id)
        (equal chat-id (msteams--capture-property "TEAMS_CHAT"))
      (and (stringp team-id) (stringp channel-id) (stringp thread-id)
           (equal team-id
                  (msteams--capture-property "TEAMS_TEAM_ID"))
           (equal channel-id
                  (msteams--capture-property "TEAMS_CHANNEL_ID"))
           (equal thread-id
                  (msteams--capture-property "TEAMS_THREAD"))))))

(defun msteams--find-org-capture (context)
  "Return the best existing Org marker for Teams capture CONTEXT.

An exact message property wins; otherwise the conversation heading is used.
The Org file itself is authoritative, so no secondary linkage index is kept."
  (let ((file (msteams--capture-file))
        (message-id (msteams--get context 'selectedMessageId))
        message-marker conversation-marker)
    (when (file-readable-p file)
      (require 'org)
      (let ((buffer (find-file-noselect file)))
        (with-current-buffer buffer
          (save-restriction
           (widen)
           (org-map-entries
            (lambda ()
              (when (msteams--capture-context-match-p context)
                (unless conversation-marker
                  (setq conversation-marker (copy-marker (point))))
                (when (and (stringp message-id)
                           (equal message-id
                                  (msteams--capture-property
                                   "TEAMS_MESSAGE")))
                  (setq message-marker (copy-marker (point))))))
            nil 'file)))))
    (or message-marker conversation-marker)))

(defun msteams--jump-to-capture-context (context)
  "Visit the existing Org capture for CONTEXT and return non-nil when found."
  (when-let ((marker (msteams--find-org-capture context)))
    (pop-to-buffer (marker-buffer marker))
    (goto-char marker)
    (org-show-context)
    (org-reveal)
    t))

(defun msteams--captured-chat-table ()
  "Return chat IDs derived from the Org capture file.

Reuse one in-memory snapshot while the source path, size, and modification time
are unchanged.  No index is written to disk."
  (when (>= (- (float-time) msteams--captured-chat-checked-at)
            msteams--captured-chat-check-seconds)
    (setq msteams--captured-chat-checked-at (float-time))
    (let* ((file (msteams--capture-file))
           (attributes (file-attributes file 'string))
           (signature
            (list file
                  (and attributes (file-attribute-size attributes))
                  (and attributes
                       (file-attribute-modification-time attributes)))))
      (unless (equal signature msteams--captured-chat-signature)
        (let ((table (make-hash-table :test #'equal)))
          (when (and attributes (file-readable-p file))
            (require 'org)
            (with-temp-buffer
              (insert-file-contents file)
              (delay-mode-hooks (org-mode))
              (org-map-entries
               (lambda ()
                 (when-let ((chat-id
                             (msteams--capture-property "TEAMS_CHAT")))
                   (puthash chat-id t table)))
               nil nil)))
          (setq msteams--captured-chat-signature signature
                msteams--captured-chat-table table)))))
  msteams--captured-chat-table)

(defun msteams--captured-p (chat)
  "Return non-nil when CHAT appears in the current transient capture table."
  (and (hash-table-p msteams--captured-chat-table)
       (gethash (msteams--chat-id chat)
                msteams--captured-chat-table)))

(defun msteams--capture-one-line (value)
  "Return VALUE as a single trimmed line suitable for Org metadata."
  (when value
    (string-trim
     (replace-regexp-in-string "[\n\r\t ]+" " " (format "%s" value)))))

(defun msteams--capture-context-property (context key)
  "Return CONTEXT value for KEY as a nonempty single line."
  (let ((value (msteams--capture-one-line
                (msteams--get context key))))
    (and value (not (string-empty-p value)) value)))

(defun msteams--chat-capture-context (chat &optional message)
  "Build complete Org capture metadata for CHAT and selected MESSAGE."
  (let* ((chat-url (msteams--get chat 'webUrl))
         (message-url (msteams--get message 'webUrl))
         (meeting-context (msteams--get chat 'meetingContext))
         (meeting-event (msteams--get meeting-context 'event))
         (channel-p (equal (msteams--get chat 'chatType) "channel")))
    `((kind . ,(if channel-p "channel" "chat"))
      (title . ,(msteams--chat-label chat))
      (conversationType . ,(msteams--chat-type-label chat))
      (chatId . ,(unless channel-p (msteams--chat-id chat)))
      (teamId . ,(msteams--get chat 'teamId))
      (teamName . ,(msteams--get chat 'teamName))
      (channelId . ,(msteams--get chat 'channelId))
      (channelName . ,(msteams--get chat 'channelName))
      (threadId . ,(msteams--get chat 'threadId))
      (conversationUrl . ,chat-url)
      (selectedMessageId . ,(msteams--get message 'id))
      (selectedMessageUrl . ,message-url)
      (sourceUrl . ,(or message-url chat-url))
      (updated . ,(or (msteams--get message 'createdDateTime)
                      (msteams--get chat 'lastUpdatedDateTime)))
      (meetingStart . ,(msteams--event-date-time meeting-event 'start))
      (meetingEnd . ,(msteams--event-date-time meeting-event 'end))
      (participants
       . ,(when-let ((names (and (msteams--meeting-chat-p chat)
                                 (msteams--meeting-participant-names chat))))
            (string-join names ", "))))))

(defconst msteams--capture-property-map
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

(defun msteams--org-link (url description)
  "Return an Org link for URL with readable DESCRIPTION."
  (when (and (stringp url) (not (string-empty-p url)))
    (format "[[%s][%s]]"
            (replace-regexp-in-string "\\]" "%5D" url t t)
            (replace-regexp-in-string "\\]" "\\\\]"
                                      (or description "Microsoft Teams") t t))))

(defun msteams--org-indent-text (text)
  "Indent plain TEXT so message content cannot become Org headings."
  (mapconcat (lambda (line) (concat "  " line))
             (string-lines (or text "")) "\n"))

(defun msteams--message-org (message)
  "Return MESSAGE as a source-linked Org subtree."
  (let* ((sender (msteams--message-sender message))
         (created (or (msteams--get message 'createdDateTime) "Unknown time"))
         (body (msteams--message-body message))
         (url (msteams--get message 'webUrl))
         (message-id (msteams--get message 'id))
         (reference (msteams--message-reference message))
         (reactions (msteams--reaction-summary message))
         attachments)
    (dolist (attachment (msteams--get message 'attachments))
      (unless (msteams--reference-attachment-p attachment)
        (let ((name (or (msteams--get attachment 'name) "Attachment"))
              (attachment-url
               (or (msteams--get attachment 'contentUrl)
                   (msteams--get attachment 'webUrl))))
          (push (or (msteams--org-link attachment-url name) name)
                attachments))))
    (concat
     (format "*** %s - %s\n" (msteams--format-date created t) sender)
     (when (or message-id url)
       (concat ":PROPERTIES:\n"
               (when message-id
                 (format ":TEAMS_MESSAGE: %s\n"
                         (msteams--capture-one-line message-id)))
               (when url (format ":TEAMS_URL: %s\n" url))
               ":END:\n"))
     (when url
       (concat (msteams--org-link url "Open this message") "\n\n"))
     (when reference
       (let ((quoted-sender
              (or (msteams--dig reference 'messageSender 'user 'displayName)
                  "Quoted message"))
             (preview (or (msteams--get reference 'messagePreview) "")))
         (concat "Quoted from " quoted-sender ":\n"
                 (msteams--org-indent-text
                  (msteams--html-to-text preview))
                 "\n\n")))
     (msteams--org-indent-text
      (if (string-empty-p body) "[Empty message]" body))
     "\n"
     (when attachments
       (concat "\nAttachments: " (string-join (nreverse attachments) ", ")
               "\n"))
     (when (and reactions (not (string-empty-p reactions)))
       (format "\nReactions: %s\n" reactions))
     "\n")))

(defun msteams--summary-org-entry (context &optional message)
  "Return a compact, actionable Org capture for CONTEXT and last MESSAGE."
  (let* ((title (or (msteams--capture-context-property context 'title)
                    "Teams conversation"))
         (type (msteams--capture-context-property
                context 'conversationType))
         (source-url (msteams--capture-context-property context 'sourceUrl))
         (updated (msteams--capture-context-property context 'updated))
         (participants
          (msteams--capture-context-property context 'participants))
         (meeting-start
          (msteams--capture-context-property context 'meetingStart))
         (meeting-end
          (msteams--capture-context-property context 'meetingEnd))
         (sender (and message (msteams--message-sender message)))
         (body (and message (msteams--message-body message)))
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
                    (msteams--capture-context-property
                     context (cdr mapping))))
          (format ":%s: %s\n" (car mapping) value)))
      msteams--capture-property-map "")
     ":END:\n\n"
     (when source-url
       (concat (msteams--org-link source-url "Open in Microsoft Teams")
               "\n\n"))
     (when type (format "- Type :: %s\n" type))
     (when updated
       (format "- Last activity :: %s\n"
               (or (msteams--format-meeting-time updated) updated)))
     (when meeting-start
       (format "- Meeting :: %s%s\n"
               (or (msteams--format-meeting-time meeting-start)
                   meeting-start)
               (if meeting-end
                   (format " - %s"
                           (or (msteams--format-meeting-time meeting-end)
                               meeting-end))
                 "")))
     (when participants (format "- Participants :: %s\n" participants))
     (when (or sender (and preview (not (string-empty-p preview))))
       (concat "\n** Last message\n"
               (when sender
                 (format "%s%s\n" sender
                         (if updated
                             (format " - %s"
                                     (or (msteams--format-meeting-time
                                          updated)
                                         updated))
                           "")))
               (when (and preview (not (string-empty-p preview)))
                 (concat preview "\n")))))))

(defun msteams--start-summary-org-capture (context &optional message)
  "Start an editable compact Org capture for CONTEXT and last MESSAGE."
  (require 'org-capture)
  (let* ((file (msteams--capture-file))
         (entry (msteams--summary-org-entry context message))
         (org-capture-templates
          `(("A" "Teams action" entry (file ,file) "%i\n%?"
             :empty-lines 1))))
    (make-directory (file-name-directory file) t)
    (org-capture-string entry "A")
    (message "Teams action ready to capture in %s"
             (abbreviate-file-name file))))

(defun msteams-capture-chat-summary (chat &optional message)
  "Capture compact CHAT metadata and its last or selected MESSAGE.

Meeting chats first resolve calendar time and participants when possible.  No
message-history request is made."
  (let ((message (or message (msteams--get chat 'lastMessagePreview))))
    (if (and (msteams--meeting-chat-p chat)
             (not (msteams--get chat 'meetingContext))
             (not msteams-offline-mode))
        (progn
          (message "Loading Teams meeting details for capture...")
          (msteams--fetch-meeting-context
           chat
           (lambda (_context)
             (msteams--start-summary-org-capture
              (msteams--chat-capture-context chat message) message))))
      (msteams--start-summary-org-capture
       (msteams--chat-capture-context chat message) message))))

(defun msteams--thread-org-entry (context messages)
  "Return complete CONTEXT and MESSAGES as one editable Org entry."
  (let* ((title (or (msteams--capture-context-property context 'title)
                    "Teams conversation"))
         (source-url
          (msteams--capture-context-property context 'sourceUrl))
         (conversation-url
          (msteams--capture-context-property context 'conversationUrl))
         (type
          (msteams--capture-context-property context 'conversationType))
         (team (msteams--capture-context-property context 'teamName))
         (channel
          (msteams--capture-context-property context 'channelName)))
    (concat
     "* Teams: " title "\n"
     ":PROPERTIES:\n"
     (format ":CAPTURED: %s\n" (format-time-string "[%Y-%m-%d %a %H:%M]"))
     (mapconcat
      (lambda (mapping)
        (when-let ((value
                    (msteams--capture-context-property
                     context (cdr mapping))))
          (format ":%s: %s\n" (car mapping) value)))
      msteams--capture-property-map "")
     ":END:\n\n"
     (when source-url
       (concat (msteams--org-link
                source-url "Open selected item in Microsoft Teams")
               "\n"))
     (when (and conversation-url (not (equal source-url conversation-url)))
       (concat (msteams--org-link
                conversation-url "Open the conversation")
               "\n"))
     "\n"
     "- Conversation :: " title "\n"
     (when type (format "- Type :: %s\n" type))
     (when team (format "- Team :: %s\n" team))
     (when channel (format "- Channel :: %s\n" channel))
     (when-let ((updated
                 (msteams--capture-context-property context 'updated)))
       (format "- Last updated :: %s\n" updated))
     "\n** Transcript\n\n"
     (mapconcat #'msteams--message-org
                (msteams--normalize-messages messages) ""))))

(defun msteams--start-thread-org-capture (context messages)
  "Start an editable Org capture for complete CONTEXT MESSAGES."
  (require 'org-capture)
  (let* ((file (msteams--capture-file))
         (entry (msteams--thread-org-entry context messages))
         (org-capture-templates
          `(("T" "Teams thread" entry (file ,file) "%i\n%?"
             :empty-lines 1))))
    (make-directory (file-name-directory file) t)
    (org-capture-string entry "T")
    (message "Complete Teams thread ready to capture in %s"
             (abbreviate-file-name file))))

(defun msteams-capture-chat-thread (chat &optional message)
  "Fetch and start Org capture for complete CHAT around selected MESSAGE."
  (let ((context (msteams--chat-capture-context chat message)))
    (message "Preparing complete Teams thread for Org capture...")
    (msteams--run-json
     (msteams--message-args chat t)
     (lambda (payload)
       (msteams--start-thread-org-capture
        context (msteams--payload-list payload))))))

(defun msteams--capture-title (message)
  "Build a concise Org heading title from MESSAGE."
  (let* ((sender (msteams--message-sender message))
         (body (replace-regexp-in-string
                "[\n\r\t ]+" " " (msteams--message-body message)))
         (summary (truncate-string-to-width body 72 nil nil "...")))
    (if (string-empty-p summary) sender (format "%s: %s" sender summary))))

(defun msteams--capture-entry (chat message file)
  "Append CHAT MESSAGE as an Org entry to FILE and return its marker."
  (require 'org)
  (make-directory (file-name-directory file) t)
  (let* ((buffer (find-file-noselect file))
         (context (msteams--chat-capture-context chat message))
         (chat-url (or (msteams--get message 'webUrl)
                       (msteams--get chat 'webUrl)))
         marker)
    (with-current-buffer buffer
      (unless (derived-mode-p 'org-mode) (org-mode))
      (goto-char (point-max))
      (unless (bolp) (insert "\n"))
      (unless (= (point-min) (point-max)) (insert "\n"))
      (setq marker (copy-marker (point)))
      (insert "* " (msteams--capture-title message) "\n")
      (org-entry-put nil "CAPTURED"
                     (msteams--org-date
                      (or (msteams--get message 'createdDateTime) "")))
      (org-entry-put nil "TEAMS_CREATED"
                     (msteams--capture-one-line
                      (or (msteams--get message 'createdDateTime) "")))
      (org-entry-put nil "TEAMS_SENDER"
                     (msteams--message-sender message))
      (dolist (mapping msteams--capture-property-map)
        (when-let ((value
                    (msteams--capture-context-property
                     context (cdr mapping))))
          (org-entry-put nil (car mapping) value)))
      (when chat-url (org-entry-put nil "TEAMS_URL" chat-url))
      (org-end-of-meta-data t)
      (insert (msteams--message-body message) "\n")
      (when chat-url
        (insert "\n[[" chat-url "][Open in Microsoft Teams]]\n"))
      (save-buffer))
    marker))

;;;###autoload
(defun msteams-capture-message ()
  "Capture the Teams message at point into the configured Org inbox."
  (interactive)
  (unless (derived-mode-p 'msteams-chat-mode)
    (user-error "Capture works from a Teams chat transcript"))
  (let ((message (msteams-message-at-point))
        (chat msteams--chat)
        (file (msteams--capture-file)))
    (unless message (user-error "Move point onto a Teams message first"))
    (let ((marker (msteams--capture-entry chat message file)))
      (pop-to-buffer (marker-buffer marker))
      (goto-char marker)
      (message "Captured Teams message in %s" (abbreviate-file-name file)))))

;; Short command names requested for day-to-day use.
(defalias 'teams #'msteams-inbox)
(defalias 'teams-inbox #'msteams-inbox)
(defalias 'teams-chat #'msteams-chat)
(defalias 'teams-recent #'msteams-recent)
(defalias 'teams-send #'msteams-send)
(defalias 'teams-export-thread #'msteams-export-thread)
(defalias 'teams-copy-thread-markdown
  #'msteams-copy-thread-markdown)
(defalias 'teams-capture-message #'msteams-capture-message)

(provide 'msteams-ui)

;;; msteams-ui.el ends here
