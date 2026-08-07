;;; msteams-advanced.el --- Full native Teams workflows. -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Higher-level views and mutations layered on the small process/JSON core in
;; msteams-ui.el.  Every server operation remains an argv-only invocation.

;;; Code:

(require 'msteams-ui)
(require 'cl-lib)
(require 'json)
(require 'seq)
(require 'subr-x)
(require 'tabulated-list)

(declare-function msteams-transient "advanced")
(declare-function agent-shell--resolve-config-designator "agent-shell"
                  (designator))
(declare-function agent-shell-insert "agent-shell" (&rest arguments))
(declare-function agent-shell-start "agent-shell" (&rest arguments))
(declare-function org-read-date "org" (&optional inactive to-time from-string prompt
                                                 default-time default-input))

(defvar msteams-background-sync-interval)
(defvar msteams-background-sync-max-backoff)
(defvar msteams-bookmarks)
(defvar msteams-confirm-apply)
(defvar msteams-default-view)
(defvar msteams-download-directory)
(defvar msteams-draft-directory)
(defvar msteams-mock-mode)
(defvar msteams-notifications)
(defvar msteams-offline-mode)
(defvar msteams-preview-delay)
(defvar msteams-preview-on-move)
(defvar msteams-sync-chat-limit)
(defvar msteams-sync-days)
(defvar msteams-sync-scope)
(defvar msteams-status-style)
(defvar msteams-thread-analysis-agent)
(defvar agent-shell-agent-configs)

(defvar msteams--active-query nil)
(defvar msteams--active-filter-name nil)
(defvar msteams--unread-filter-enabled nil)
(defvar msteams--marks (make-hash-table :test #'equal))
(defvar msteams--selections (make-hash-table :test #'equal))
(defvar msteams--action-history nil)
(defvar msteams--undo-inflight nil)
(defvar msteams--background-timer nil)
(defvar msteams--background-failures 0)
(defvar msteams--background-process nil)
(defvar msteams--last-sync nil)
(defvar msteams--mode-line " Teams: idle")
(defvar msteams--jump-to-bottom-on-render)
(defconst msteams--search-buffer-name "*Teams Search*")
(defconst msteams--transcript-buffer-name "*Teams Meeting Transcript*")

(defvar-local msteams--search-query nil)
(defvar-local msteams--search-server nil)

(defvar-local msteams-channel--team nil)
(defvar-local msteams-channel--channel nil)
(defvar-local msteams-channel--roots nil)
(defvar-local msteams-channel--root nil)
(defvar-local msteams-channel--messages nil)
(defvar-local msteams-channel--request-id 0)
(defvar-local msteams-channel--pending-message-id nil)

(defface msteams-mark
  '((t :inherit font-lock-constant-face :weight bold))
  "Face for deferred mu4e-style action marks."
  :group 'msteams)

(defface msteams-channel-subject
  '((t :inherit font-lock-function-name-face :weight semi-bold))
  "Face for channel thread subjects."
  :group 'msteams)

(defun msteams--set-mode-line (text)
  "Set the global Teams mode-line TEXT and refresh displays."
  (setq msteams--mode-line (concat " Teams: " text))
  (force-mode-line-update t))

(unless (member 'msteams--mode-line global-mode-string)
  (setq global-mode-string
        (append global-mode-string '(msteams--mode-line))))

(defun msteams-mock-enable (&optional reset)
  "Enable the local persistent Teams mock; with RESET, restore seed state."
  (interactive "P")
  (msteams--stop-server)
  (setq msteams-mock-mode t
        msteams-offline-mode nil
        msteams--connected-as nil)
  (if reset
      (msteams-mock-reset)
    (msteams-status))
  (message "Teams local mock enabled%s" (if reset " and reset" "")))

(defun msteams-mock-disable ()
  "Return the backend to shared-OAuth Microsoft Graph mode."
  (interactive)
  (msteams--stop-server)
  (setq msteams-mock-mode nil
        msteams--connected-as nil)
  (message "Teams local mock disabled; live Graph mode selected"))

(defun msteams-mock-reset ()
  "Reset the persistent local mock tenant to deterministic seed data."
  (interactive)
  (unless msteams-mock-mode
    (user-error "Enable `msteams-mock-mode' before resetting mock state"))
  (msteams--run-json
   '("mock" "reset")
   (lambda (payload)
     (message "Reset Teams mock: %s chats, %s teams"
              (or (msteams--get payload 'chats) 0)
              (or (msteams--get payload 'teams) 0)))))

(defun msteams-toggle-offline ()
  "Toggle credential-free cache-only reading."
  (interactive)
  (setq msteams-offline-mode (not msteams-offline-mode))
  (msteams--set-mode-line
   (if msteams-offline-mode "offline" "online"))
  (message "Teams cache-only mode %s"
           (if msteams-offline-mode "enabled" "disabled"))
  (when (derived-mode-p 'msteams-recent-mode)
    (msteams-recent-refresh)))

(defun msteams-cache-status ()
  "Display SQLite cache counts and last synchronization time."
  (interactive)
  (msteams--run-json
   '("teams" "cache" "status")
   (lambda (payload)
     (let ((buffer (get-buffer-create "*Teams Cache*")))
       (with-current-buffer buffer
         (let ((inhibit-read-only t))
           (erase-buffer)
           (insert (format "Path: %s\n" (msteams--get payload 'path)))
           (insert (format "Last sync: %s\n\n"
                           (or (msteams--get payload 'lastSync) "never")))
           (insert "Resources\n---------\n")
           (dolist (item (msteams--get payload 'resources))
             (insert (format "%s: %s\n" (car item) (cdr item))))
           (insert "\nMessages\n--------\n")
           (dolist (item (msteams--get payload 'messages))
             (insert (format "%s: %s\n" (car item) (cdr item))))
           (special-mode)))
       (pop-to-buffer buffer)))))

(defun msteams--sync-args (&optional all)
  "Return backend sync arguments; ALL requests channels as well as chats."
  (list "teams" "sync"
        "--scope" (if all "all" msteams-sync-scope)
        "--chatLimit" (number-to-string msteams-sync-chat-limit)
        "--days" (number-to-string msteams-sync-days)))

(defun msteams--notify-sync (payload)
  "Notify about incremental changes represented by sync PAYLOAD."
  (let ((new (or (msteams--get payload 'newMessages) 0))
        (changed (or (msteams--get payload 'changedMessages) 0)))
    (when (and msteams-notifications (> new 0))
      (if (fboundp 'notifications-notify)
          (notifications-notify
           :title "Microsoft Teams"
           :body (format "%d new message%s" new (if (= new 1) "" "s"))
           :app-name "Emacs")
        (message "Teams: %d new message%s" new (if (= new 1) "" "s"))))
    (msteams--set-mode-line
     (format "%d new, %d changed" new changed))))

(defun msteams-sync (&optional all callback error-callback)
  "Synchronize Teams into SQLite.

With prefix ALL, include joined teams and channels.  CALLBACK receives the
summary.  ERROR-CALLBACK follows `msteams--run-json'."
  (interactive "P")
  (msteams--require-online)
  (msteams--set-mode-line "syncing")
  (setq msteams--background-process
        (msteams--run-json
         (msteams--sync-args all)
         (lambda (payload)
           (let ((errors (msteams--get payload 'errors)))
             (setq msteams--background-process nil)
             (if errors
                 (let ((detail
                        (concat
                         "Partial Teams synchronization:\n"
                         (mapconcat
                          (lambda (item)
                            (format "%s: %s"
                                    (or (msteams--get item 'resource)
                                        "resource")
                                    (or (msteams--get item 'error)
                                        "unknown error")))
                          errors "\n"))))
                   (msteams--set-mode-line "sync partial")
                   (if error-callback
                       (funcall error-callback "partial" detail)
                     (msteams--report-error
                      (msteams--sync-args all) "partial" detail)))
               (setq msteams--last-sync (current-time))
               (msteams--notify-sync payload)
               (when-let ((buffer (msteams--recent-buffer)))
                 (msteams--load-chats
                  (lambda (chats)
                    (when (buffer-live-p buffer)
                      (with-current-buffer buffer
                        (msteams--render-recent)))
                    (msteams--enrich-members chats))))
               (when callback (funcall callback payload)))))
         (lambda (status detail)
           (setq msteams--background-process nil)
           (msteams--set-mode-line "sync failed")
           (if error-callback
               (funcall error-callback status detail)
             (msteams--report-error
              (msteams--sync-args all) status detail))))))

(defun msteams--cancel-background-timer ()
  "Cancel the pending one-shot background synchronization timer."
  (when (timerp msteams--background-timer)
    (cancel-timer msteams--background-timer))
  (setq msteams--background-timer nil))

(defun msteams--schedule-background-sync (delay)
  "Schedule one background sync after DELAY seconds."
  (msteams--cancel-background-timer)
  (setq msteams--background-timer
        (run-at-time delay nil #'msteams--background-sync-run)))

(defun msteams--background-sync-run ()
  "Run one sync and schedule the next success or backed-off retry."
  (setq msteams--background-timer nil)
  (if msteams-offline-mode
      (msteams--schedule-background-sync
       msteams-background-sync-interval)
    (msteams-sync
     nil
     (lambda (_payload)
       (setq msteams--background-failures 0)
       (msteams--schedule-background-sync
        msteams-background-sync-interval))
     (lambda (status detail)
       (cl-incf msteams--background-failures)
       (let ((delay
              (min msteams-background-sync-max-backoff
                   (* msteams-background-sync-interval
                      (expt 2 (1- msteams--background-failures))))))
         (msteams--report-error
          (msteams--sync-args) status detail)
         (msteams--set-mode-line (format "retry in %ds" delay))
         (msteams--schedule-background-sync delay))))))

(define-minor-mode msteams-background-sync-mode
  "Periodically synchronize Teams with retry/backoff and notifications."
  :global t
  :group 'msteams
  (msteams--cancel-background-timer)
  (if msteams-background-sync-mode
      (progn
        (setq msteams--background-failures 0)
        (msteams--schedule-background-sync 1)
        (msteams--set-mode-line "sync scheduled"))
    (msteams--cancel-process msteams--background-process)
    (setq msteams--background-process nil)
    (msteams--set-mode-line "idle")))

(defun msteams--built-in-view-chat-p (chat view)
  "Return whether CHAT belongs to built-in inbox VIEW."
  (pcase view
    ('inbox (and (not (msteams--muted-p chat))
                 (not (msteams--triaged-p chat))))
    ('all t)
    ('attention (and (not (msteams--muted-p chat))
                     (not (msteams--triaged-p chat))
                     (msteams--attention-p chat)))
    ('muted (msteams--muted-p chat))
    ('unread (msteams--unread-p chat))
    ('favorites (msteams--favorite-p chat))
    ('handled (msteams--handled-p chat))
    ('snoozed (msteams--snoozed-p chat))
    ('direct (equal (msteams--get chat 'chatType) "oneOnOne"))
    ('group (equal (msteams--get chat 'chatType) "group"))
    ('meeting (equal (msteams--get chat 'chatType) "meeting"))
    ('upcoming (msteams--meeting-upcoming-p chat))
    (_ t)))

(defun msteams--query-text-match-p (needle text)
  "Return non-nil when case-insensitive NEEDLE occurs in TEXT."
  (and (stringp text)
       (string-match-p (regexp-quote needle) text)))

(defun msteams--query-term-chat-p (chat term)
  "Return whether CHAT matches one inbox query TERM."
  (let* ((case-fold-search t)
         (negated (string-prefix-p "-" term))
         (term (if negated (substring term 1) term))
         (label (msteams--chat-label chat))
         (preview (msteams--chat-preview chat))
         (type (msteams--get chat 'chatType))
         (matched
          (cond
           ((member (downcase term) '("" "*" "all")) t)
           ((string-equal (downcase term) "inbox")
            (and (not (msteams--muted-p chat))
                 (not (msteams--triaged-p chat))))
           ((member (downcase term) '("muted" "hidden"))
            (msteams--muted-p chat))
           ((string-equal (downcase term) "unread")
            (msteams--unread-p chat))
           ((string-equal (downcase term) "read")
            (not (msteams--unread-p chat)))
           ((member (downcase term) '("favorite" "favorites"))
            (msteams--favorite-p chat))
           ((string-equal (downcase term) "handled")
            (msteams--handled-p chat))
           ((string-equal (downcase term) "snoozed")
            (msteams--snoozed-p chat))
           ((member (downcase term) '("attention" "important-to-me"))
            (msteams--attention-p chat))
           ((member (downcase term) '("upcoming" "meeting:upcoming"))
            (msteams--meeting-upcoming-p chat))
           ((member (downcase term) '("mentioned" "mention"))
            (msteams--mentioned-user-p
             (msteams--last-message chat)))
           ((member (downcase term) '("important" "priority"))
            (msteams--important-p
             (msteams--last-message chat)))
           ((member (downcase term) '("reply-to-me" "reply"))
            (msteams--reply-to-own-p
             (msteams--last-message chat)))
           ((member (downcase term) '("attachment" "attachments"))
            (seq-some
             (lambda (attachment)
               (not (member (msteams--get attachment 'contentType)
                            '("messageReference"
                              "forwardedMessageReference"))))
             (msteams--get (msteams--last-message chat)
                            'attachments)))
           ((string-match "\\`type:\\(.+\\)\\'" term)
            (let ((wanted (downcase (match-string 1 term))))
              (equal type
                     (pcase wanted
                       ((or "direct" "oneonone") "oneOnOne")
                       (other other)))))
           ((string-match "\\`after:\\([0-9]+\\)d\\'" term)
            (let ((updated (msteams--get chat 'lastUpdatedDateTime)))
              (and (stringp updated)
                   (condition-case nil
                       (time-less-p
                        (time-subtract
                         (current-time)
                         (days-to-time
                          (string-to-number (match-string 1 term))))
                        (date-to-time updated))
                     (error nil)))))
           ((string-match "\\`name:\\(.*\\)\\'" term)
            (msteams--query-text-match-p
             (match-string 1 term) label))
           ((string-match "\\`message:\\(.*\\)\\'" term)
            (msteams--query-text-match-p
             (match-string 1 term) preview))
           (t
            (or (msteams--query-text-match-p term label)
                (msteams--query-text-match-p term preview))))))
    (if negated (not matched) matched)))

(defun msteams--query-chat-p (chat query)
  "Return whether CHAT matches bookmark/filter QUERY."
  (cond
   ((functionp query) (funcall query chat))
   ((symbolp query) (msteams--built-in-view-chat-p chat query))
   ((stringp query)
    (seq-some
     (lambda (clause)
       (seq-every-p
        (lambda (term) (msteams--query-term-chat-p chat term))
        (split-string-and-unquote (string-trim clause))))
     (split-string query "|" t)))
   (t t)))

(defun msteams--view-chat-p (chat)
  "Return whether CHAT belongs to the active inbox view or query."
  (msteams--ensure-active-view)
  (and
   (if msteams--active-query
       (msteams--query-chat-p chat msteams--active-query)
     (msteams--built-in-view-chat-p
      chat msteams--active-view))
   (or (not msteams--unread-filter-enabled)
       (msteams--unread-p chat))))

(defun msteams--active-filter-label ()
  "Return the display label for the active inbox filter."
  (msteams--ensure-active-view)
  (concat
   (or msteams--active-filter-name
       (symbol-name msteams--active-view))
   (if msteams--unread-filter-enabled " + unread only" "")))

(defun msteams--status-spec (kind)
  "Return display text and help text for inbox status KIND."
  (if (eq msteams-status-style 'letters)
      (pcase kind
        ('selected '("+" "Selected for a bulk action"))
        ('read '("i" "Queued: mark read"))
        ('unread '("u" "Queued: mark unread"))
        ('refile '("r" "Queued: refile until a new message"))
        ('favorite '("*" "Queued: toggle favorite"))
        ('favorite-on '("+*" "Queued: add favorite"))
        ('favorite-off '("-*" "Queued: remove favorite"))
        ('handled '("h" "Refiled until a new message"))
        ('snoozed '("z" "Snoozed"))
        ('captured '("c" "Captured in Org"))
        (_ '("?" "Unknown status")))
    (pcase kind
      ('selected '("+" "Selected for a bulk action"))
      ('read '("✓" "Queued: mark read"))
      ('unread '("○" "Queued: mark unread"))
      ('refile '("↦" "Queued: refile until a new message"))
      ('favorite '("★" "Queued: toggle favorite"))
      ('favorite-on '("+★" "Queued: add favorite"))
      ('favorite-off '("−★" "Queued: remove favorite"))
      ('handled '("↦" "Refiled until a new message"))
      ('snoozed '("◷" "Snoozed"))
      ('captured '("≡" "Captured in Org"))
      (_ '("?" "Unknown status")))))

(defun msteams--status-token (kind)
  "Return a styled inbox status token for KIND."
  (pcase-let ((`(,text ,help) (msteams--status-spec kind)))
    (propertize text 'face 'msteams-mark 'help-echo help)))

(defun msteams--action-mark-character (action)
  "Return the compact inbox marker for deferred ACTION."
  (msteams--status-token action))

(defun msteams--mark-character (chat)
  "Return selection and deferred-action marks for CHAT."
  (let* ((chat-id (msteams--chat-id chat))
         (selected (gethash chat-id msteams--selections))
         (action (gethash chat-id msteams--marks))
         (triage (cond ((msteams--handled-p chat) 'handled)
                       ((msteams--snoozed-p chat) 'snoozed)))
         (captured (msteams--captured-p chat)))
    (mapconcat
     #'identity
     (delq nil
           (list (and selected (msteams--status-token 'selected))
                 (and action (msteams--action-mark-character action))
                 (and triage (msteams--status-token triage))
                 (and captured (msteams--status-token 'captured))))
     "")))

(defun msteams--set-handled-local (chat enabled)
  "Set CHAT's handled-until-new state to ENABLED without persisting."
  (let ((chat-id (msteams--chat-id chat)))
    (if enabled
        (progn
          (puthash chat-id (msteams--chat-marker chat)
                   msteams--handled)
          (remhash chat-id msteams--snoozed))
      (remhash chat-id msteams--handled))))

(defun msteams--set-snoozed-local (chat until)
  "Snooze CHAT until ISO timestamp UNTIL without persisting."
  (let ((chat-id (msteams--chat-id chat)))
    (if until
        (progn
          (remhash chat-id msteams--handled)
          (puthash chat-id until msteams--snoozed))
      (remhash chat-id msteams--snoozed))))

(defun msteams--clear-triage-local (chat)
  "Clear handled and snoozed state for CHAT without persisting."
  (let ((chat-id (msteams--chat-id chat)))
    (remhash chat-id msteams--handled)
    (remhash chat-id msteams--snoozed)))

(defun msteams-toggle-handled ()
  "Toggle handled-until-new state for the current Teams conversation."
  (interactive)
  (msteams--load-state)
  (let* ((chat (or (msteams--chat-at-point)
                   (user-error "No Teams chat here")))
         (enabled (not (msteams--handled-p chat))))
    (msteams--set-handled-local chat enabled)
    (msteams--save-state)
    (msteams--refresh-visible-recent)
    (message "%s %s"
             (if enabled "Handled until a new message:" "Returned to inbox:")
             (msteams--chat-label chat))))

(defun msteams--time-at-local-hour (base hour)
  "Return BASE's local calendar date at HOUR:00."
  (pcase-let ((`(,_second ,_minute ,_hour ,day ,month ,year . ,_)
               (decode-time base)))
    (encode-time 0 0 hour day month year)))

(defun msteams--read-snooze-time ()
  "Prompt for a snooze expiry and return a time value or nil to clear it."
  (let* ((choice
          (completing-read
           "Snooze Teams chat until: "
           '("1 hour" "Tomorrow 09:00" "Next week 09:00"
             "Choose date/time..." "Clear snooze")
           nil t))
         (now (current-time)))
    (pcase choice
      ("1 hour" (time-add now (seconds-to-time 3600)))
      ("Tomorrow 09:00"
       (msteams--time-at-local-hour
        (time-add now (days-to-time 1)) 9))
      ("Next week 09:00"
       (msteams--time-at-local-hour
        (time-add now (days-to-time 7)) 9))
      ("Choose date/time..."
       (require 'org)
       (org-read-date nil t nil "Snooze Teams chat until: "))
      (_ nil))))

(defun msteams-snooze ()
  "Snooze the current Teams conversation using one local expiry timestamp."
  (interactive)
  (msteams--load-state)
  (let* ((chat (or (msteams--chat-at-point)
                   (user-error "No Teams chat here")))
         (time (msteams--read-snooze-time))
         (until (and time (format-time-string "%Y-%m-%dT%H:%M:%S%z" time))))
    (msteams--set-snoozed-local chat until)
    (msteams--save-state)
    (msteams--refresh-visible-recent)
    (if until
        (message "Snoozed %s until %s"
                 (msteams--chat-label chat)
                 (format-time-string "%a %H:%M" time))
      (message "Cleared snooze for %s"
               (msteams--chat-label chat)))))

(defun msteams-clear-triage ()
  "Clear handled and snoozed state for the current Teams conversation."
  (interactive)
  (msteams--load-state)
  (let ((chat (or (msteams--chat-at-point)
                  (user-error "No Teams chat here"))))
    (msteams--clear-triage-local chat)
    (msteams--save-state)
    (msteams--refresh-visible-recent)
    (message "Cleared local triage for %s"
             (msteams--chat-label chat))))

(defun msteams--recent-entry-advanced (chat)
  "Build an inbox row for CHAT including deferred marks."
  (let* ((unread (msteams--unread-p chat))
         (face (msteams--row-face unread))
         (type-face
          (msteams--row-face
           unread (msteams--chat-type-face chat))))
    (list
     (msteams--chat-id chat)
     (vector
      (msteams--mark-character chat)
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

(defun msteams--render-recent ()
  "Render the active saved/built-in inbox view and preserve selection."
  (msteams--captured-chat-table)
  (let* ((selected (msteams--recent-selected-id))
         (visible (seq-filter #'msteams--view-chat-p
                              msteams--chats))
         (visible
          (if (or (eq msteams--active-view 'upcoming)
                  (eq msteams--active-query 'upcoming))
              (sort (copy-sequence visible)
                    #'msteams--meeting-starts-before-p)
            visible))
         (unread-count (seq-count #'msteams--unread-p
                                  msteams--chats)))
    (msteams--configure-recent-format)
    (setq tabulated-list-entries
          (mapcar #'msteams--recent-entry-advanced visible)
          header-line-format
          (format (concat "Teams %s - %d shown - %d unread - "
                          "%d selected - %d queued%s%s%s")
                  (msteams--active-filter-label)
                  (length visible) unread-count
                  (hash-table-count msteams--selections)
                  (hash-table-count msteams--marks)
                  (if msteams-offline-mode " - OFFLINE" "")
                  (if msteams-mock-mode " - MOCK" "")
                  (msteams--inbox-source-suffix)))
    (msteams--set-mode-line
     (format "%d unread%s" unread-count
             (if msteams-mock-mode " mock" "")))
    (tabulated-list-print t)
    (msteams--recent-restore-selection selected)
    (msteams--follow-selected-chat)))

(defun msteams--apply-inbox-query (query name)
  "Apply inbox QUERY under display NAME and redraw the headers buffer."
  (setq msteams--active-query query
        msteams--active-filter-name name)
  (if (derived-mode-p 'msteams-recent-mode)
      (msteams--render-recent)
    (msteams-inbox)))

(defun msteams--ask-bookmark ()
  "Read and return one entry from `msteams-bookmarks'."
  (unless msteams-bookmarks
    (user-error "No Teams bookmarks are configured"))
  (let* ((prompt
          (concat
           "Teams bookmark: "
           (mapconcat
            (lambda (bookmark)
              (format "[%c]%s"
                      (plist-get bookmark :key)
                      (plist-get bookmark :name)))
            msteams-bookmarks ", ")
           " "))
         (key (read-char prompt)))
    (or (seq-find
         (lambda (bookmark) (eq key (plist-get bookmark :key)))
         msteams-bookmarks)
        (user-error "Unknown Teams bookmark key %c" key))))

(defun msteams-bookmark-jump (&optional edit)
  "Filter the inbox using a shortcut bookmark.

With EDIT non-nil, edit a string bookmark query before applying it, matching
the distinction between mu4e's `b' and `B' commands."
  (interactive)
  (let* ((bookmark (msteams--ask-bookmark))
         (name (plist-get bookmark :name))
         (query (plist-get bookmark :query)))
    (when edit
      (unless (stringp query)
        (user-error "This Teams bookmark uses a function and cannot be edited"))
      (setq query (read-string (format "Edit %s query: " name) query)
            name (format "%s (edited)" name)))
    (msteams--apply-inbox-query query name)))

(defun msteams-bookmark-edit ()
  "Edit and apply a configured Teams inbox bookmark."
  (interactive)
  (msteams-bookmark-jump t))

(defun msteams-filter (query)
  "Apply an ad hoc mu4e-style inbox QUERY to the Teams headers buffer."
  (interactive
   (list
    (read-string
     "Teams inbox query: "
     (and (stringp msteams--active-query)
          msteams--active-query))))
  (msteams--apply-inbox-query
   query (if (string-empty-p query) "all" query)))

(defun msteams-toggle-unread-filter ()
  "Toggle an unread-only overlay without replacing the active inbox filter."
  (interactive)
  (setq msteams--unread-filter-enabled
        (not msteams--unread-filter-enabled))
  (when-let ((buffer (msteams--recent-buffer)))
    (with-current-buffer buffer
      (when (derived-mode-p 'msteams-recent-mode)
        (msteams--render-recent))))
  (message "Teams unread-only filter %s for %s"
           (if msteams--unread-filter-enabled "enabled" "disabled")
           (or msteams--active-filter-name
               (symbol-name msteams--active-view))))

(defun msteams-bookmark-define (query name key)
  "Define session bookmark QUERY with NAME and shortcut KEY.

This mirrors `mu4e-bookmark-define'.  Persist personal definitions by setting
`msteams-bookmarks' in the dotfile."
  (setq msteams-bookmarks
        (seq-remove
         (lambda (bookmark) (eq key (plist-get bookmark :key)))
         msteams-bookmarks))
  (setq msteams-bookmarks
        (append msteams-bookmarks
                (list (list :name name :query query :key key)))))

(defun msteams-select-view ()
  "Select a built-in inbox filter or run a saved search view."
  (interactive)
  (msteams--load-state)
  (let ((built-ins '("inbox" "attention" "all" "handled" "snoozed"
                     "muted" "unread" "favorites" "direct" "group"
                     "meeting"))
        saved)
    (maphash (lambda (name _query) (push (concat "search: " name) saved))
             msteams--saved-views)
    (let ((choice (completing-read "Teams view: "
                                   (append built-ins (sort saved #'string<))
                                   nil t)))
      (if (string-prefix-p "search: " choice)
          (msteams-search
           (gethash (substring choice 8) msteams--saved-views))
        (setq msteams--active-view (intern choice)
              msteams--active-query nil
              msteams--active-filter-name nil)
        (when (derived-mode-p 'msteams-recent-mode)
          (msteams--render-recent))))))

(defun msteams-save-view (name query)
  "Persist cached search QUERY under NAME."
  (interactive
   (list (read-string "Saved Teams view name: ")
         (read-string "Cached message query: ")))
  (msteams--load-state)
  (when (or (string-empty-p (string-trim name))
            (string-empty-p (string-trim query)))
    (user-error "Saved view name and query are required"))
  (puthash (string-trim name) (string-trim query)
           msteams--saved-views)
  (msteams--save-state)
  (message "Saved Teams search view %s" name))

(defun msteams-delete-view ()
  "Delete one persisted cached search view."
  (interactive)
  (msteams--load-state)
  (let (names)
    (maphash (lambda (name _query) (push name names))
             msteams--saved-views)
    (let ((name (completing-read "Delete Teams view: " names nil t)))
      (remhash name msteams--saved-views)
      (msteams--save-state)
      (message "Deleted Teams view %s" name))))

(defun msteams-sort ()
  "Choose the current tabulated inbox sort column."
  (interactive)
  (unless (derived-mode-p 'msteams-recent-mode)
    (user-error "Open the Teams inbox first"))
  (let ((choice (completing-read
                 "Sort Teams inbox by: "
                 '("Updated" "Type" "Conversation" "Last message") nil t)))
    (setq tabulated-list-sort-key (cons choice (equal choice "Updated")))
    (tabulated-list-print t)))

(defvar msteams-search-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map tabulated-list-mode-map)
    (define-key map (kbd "RET") #'msteams-search-open)
    (define-key map (kbd "j") #'next-line)
    (define-key map (kbd "k") #'previous-line)
    (define-key map (kbd "g") #'msteams-search-refresh)
    (define-key map (kbd "q") #'msteams-quit)
    map)
  "Keymap for cached or server Teams search results.")

(define-derived-mode msteams-search-mode tabulated-list-mode "Teams-Search"
  "Major mode for Teams cache and ephemeral server search results."
  (setq tabulated-list-format
        [("Date" 16 t) ("Sender" 20 t) ("Scope" 10 t) ("Message" 70 nil)]
        tabulated-list-padding 1)
  (tabulated-list-init-header))

(defun msteams--search-entry (message)
  "Build one tabulated cache/server search row from MESSAGE."
  (let* ((context (or (msteams--get message 'searchContext)
                      (msteams--get message 'cacheContext)))
         (scope (or (msteams--get context 'scopeKind) ""))
         (body-text (msteams--message-body message))
         (body (replace-regexp-in-string
                "[\n\r\t ]+" " "
                (if (string-empty-p body-text)
                    (msteams--html-to-text
                     (or (msteams--get context 'summary) ""))
                  body-text))))
    (list message
          (vector
           (msteams--format-date (msteams--get message 'createdDateTime))
           (msteams--message-sender message)
           scope
           (truncate-string-to-width body 70 nil nil "...")))))

(defun msteams--show-search-results (payload query source)
  "Display search PAYLOAD for QUERY, labelled with SOURCE."
  (let ((buffer (get-buffer-create msteams--search-buffer-name))
        (results (msteams--payload-list payload)))
    (with-current-buffer buffer
      (msteams-search-mode)
      (setq msteams--search-query query
            msteams--search-server (string-equal source "server"))
      (setq tabulated-list-entries
            (mapcar #'msteams--search-entry
                    results)
            header-line-format
            (format "Teams %s search: %s - %d result%s"
                    source query (length results)
                    (if (= (length results) 1)
                        "" "s")))
      (tabulated-list-print t))
    (pop-to-buffer buffer)))

(defun msteams-search (&optional query server)
  "Search Teams messages.

The default searches the existing private SQLite cache.  With a prefix argument
SERVER, use Microsoft Search ephemerally and hydrate a selected hit through the
normal reader without adding a second search cache."
  (interactive (list nil current-prefix-arg))
  (when (and server msteams-offline-mode)
    (user-error "Server search is unavailable in Teams offline mode"))
  (setq query (or query (read-string
                         (if server
                             "Search Teams on Microsoft Graph: "
                           "Search cached Teams messages: "))))
  (when (string-empty-p (string-trim query))
    (user-error "Search query is empty"))
  (let ((args (if server
                  (list "teams" "search" "messages" "--query" query
                        "--limit" "100")
                (list "teams" "cache" "search" "--query" query
                      "--limit" "250")))
        (source (if server "server" "cache")))
    (msteams--run-json
   args
   (lambda (payload)
     (msteams--show-search-results payload query source))
   (lambda (status detail)
     (let ((buffer (get-buffer-create msteams--search-buffer-name)))
       (with-current-buffer buffer
         (msteams-search-mode)
         (setq msteams--search-query query
               msteams--search-server server)
         (setq tabulated-list-entries nil
               header-line-format
               (format "Teams %s search failed - see *M365 Errors*" source))
         (tabulated-list-print t))
       (pop-to-buffer buffer))
     (msteams--report-error args status detail)))))

(defun msteams-search-refresh ()
  "Repeat the current Teams search against its original source."
  (interactive)
  (unless (and (stringp msteams--search-query)
               (not (string-empty-p msteams--search-query)))
    (user-error "This search buffer has no query to refresh"))
  (msteams-search msteams--search-query
                         msteams--search-server))

(defun msteams-server-search (&optional query)
  "Search Teams messages ephemerally through Microsoft Search."
  (interactive)
  (msteams-search query t))

(defun msteams-search-open ()
  "Open the source transcript for the cached search result at point."
  (interactive)
  (let* ((message (or (tabulated-list-get-id)
                      (user-error "No search result on this row")))
         (context (or (msteams--get message 'searchContext)
                      (msteams--get message 'cacheContext)))
         (scope (msteams--get context 'scopeKind))
         (message-id (msteams--get message 'id)))
    (pcase scope
      ("chat"
       (let* ((chat-id (msteams--get context 'scopeId))
              (chat (or (msteams--find-chat chat-id)
                        `((id . ,chat-id) (topic . "Cached chat")))))
         (msteams-open-chat chat nil t message-id)))
      ("channel"
       (let* ((server-result (msteams--get message 'searchContext))
              (team-id (msteams--get context 'teamId))
              (channel-id (msteams--get context 'channelId))
              (root-id (msteams--get context 'rootMessageId))
              (root-id (if (and (stringp root-id)
                                (not (string-empty-p root-id)))
                           root-id
                         message-id))
              (team `((id . ,team-id)
                      (displayName . ,(if server-result
                                          "Search result team"
                                        "Cached team"))))
              (channel `((id . ,channel-id)
                         (displayName . ,(if server-result
                                            "Search result channel"
                                          "Cached channel")))))
         (msteams--run-json
          (if server-result
              (list "teams" "channel" "message" "list"
                    "--teamId" team-id "--channelId" channel-id)
            (list "teams" "cache" "channel" "message" "list"
                  "--teamId" team-id "--channelId" channel-id
                  "--limit" "1000000"))
          (lambda (payload)
            (let* ((roots (msteams--payload-list payload))
                   (root
                    (or (seq-find
                         (lambda (candidate)
                           (equal root-id (msteams--get candidate 'id)))
                         roots)
                        (and (equal root-id message-id) message)
                        `((id . ,root-id)
                          (body . ((contentType . "text")
                                   (content . "Cached thread")))))))
              (msteams-open-channel-thread team channel root)
              (with-current-buffer msteams--read-buffer-name
                (setq msteams-channel--pending-message-id
                      message-id)))))))
      (_ (user-error "Search result has no supported source context")))))

(defun msteams--visible-chats ()
  "Return chats shown by the current inbox view and overlays."
  (seq-filter #'msteams--view-chat-p msteams--chats))

(defun msteams--selected-chats ()
  "Return selected chats in current inbox order."
  (seq-filter
   (lambda (chat)
     (gethash (msteams--chat-id chat) msteams--selections))
   msteams--chats))

(defun msteams-toggle-selection ()
  "Toggle bulk selection for the inbox chat at point and move forward."
  (interactive)
  (unless (derived-mode-p 'msteams-recent-mode)
    (user-error "Chat selection works in the Teams inbox"))
  (let* ((chat (msteams--chat-at-point))
         (chat-id (msteams--chat-id chat)))
    (if (gethash chat-id msteams--selections)
        (remhash chat-id msteams--selections)
      (puthash chat-id t msteams--selections))
    (msteams--render-recent)
    (msteams-recent-next)))

(defun msteams-toggle-visible-selections ()
  "Select all visible inbox chats, or clear them when all are selected."
  (interactive)
  (unless (derived-mode-p 'msteams-recent-mode)
    (user-error "Chat selection works in the Teams inbox"))
  (let* ((visible (msteams--visible-chats))
         (all-selected
          (and visible
               (seq-every-p
                (lambda (chat)
                  (gethash (msteams--chat-id chat)
                           msteams--selections))
                visible))))
    (unless visible (user-error "No visible Teams chats to select"))
    (dolist (chat visible)
      (let ((chat-id (msteams--chat-id chat)))
        (if all-selected
            (remhash chat-id msteams--selections)
          (puthash chat-id t msteams--selections))))
    (msteams--render-recent)
    (message "%s %d visible Teams chat%s"
             (if all-selected "Cleared" "Selected")
             (length visible) (if (= (length visible) 1) "" "s"))))

(defun msteams-mark-action (action)
  "Defer ACTION for the inbox chat at point."
  (interactive)
  (unless (derived-mode-p 'msteams-recent-mode)
    (user-error "Deferred actions work in the Teams inbox"))
  (let ((chat (msteams--chat-at-point)))
    (puthash (msteams--chat-id chat) action msteams--marks)
    (msteams--render-recent)
    (msteams-recent-next)))

(defun msteams-mark-read-later ()
  "Defer marking the current inbox chat read."
  (interactive)
  (msteams-mark-action 'read))

(defun msteams-mark-refile-later ()
  "Defer refiling the current chat until a newer message arrives."
  (interactive)
  (msteams-mark-action 'refile))

(defun msteams-mark-unread-later ()
  "Defer marking the current inbox chat unread."
  (interactive)
  (msteams-mark-action 'unread))

(defun msteams-mark-favorite-later ()
  "Defer toggling favorite state for the current inbox chat."
  (interactive)
  (msteams-mark-action 'favorite))

(defun msteams-unmark ()
  "Remove the deferred action and bulk selection on the current chat."
  (interactive)
  (let ((chat (msteams--chat-at-point)))
    (remhash (msteams--chat-id chat) msteams--marks)
    (remhash (msteams--chat-id chat) msteams--selections)
    (msteams--render-recent)))

(defun msteams-unmark-all ()
  "Discard every deferred action and bulk selection in the Teams inbox."
  (interactive)
  (clrhash msteams--marks)
  (clrhash msteams--selections)
  (msteams--refresh-visible-recent)
  (message "Cleared Teams selections and deferred actions"))

(defun msteams--set-favorite (chat enabled)
  "Set CHAT favorite state to ENABLED and return its inverse history item."
  (let* ((chat-id (msteams--chat-id chat))
         (was-favorite (msteams--favorite-p chat)))
    (if enabled
        (puthash chat-id t msteams--favorites)
      (remhash chat-id msteams--favorites))
    (msteams--save-state)
    (list :kind 'favorite :chat-id chat-id :enabled was-favorite)))

(defun msteams--apply-favorite (chat)
  "Toggle local favorite state for CHAT and return its inverse history item."
  (msteams--set-favorite
   chat (not (msteams--favorite-p chat))))

(defun msteams--record-completed-actions (completed)
  "Prepend inverse COMPLETED actions to the undo history."
  (when completed
    (setq msteams--action-history
          (append completed msteams--action-history))))

(defun msteams--execute-mark-list (items completed)
  "Execute deferred ITEMS serially, accumulating inverse COMPLETED actions."
  (if (null items)
      (progn
        (msteams--record-completed-actions completed)
        (setq msteams--chats
              (sort msteams--chats #'msteams--chat-updated-p))
        (msteams--refresh-visible-recent)
        (message "Executed %d Teams action%s"
                 (length completed) (if (= (length completed) 1) "" "s")))
    (pcase-let* ((`(,chat-id . ,action) (car items))
                 (chat (or (msteams--find-chat chat-id)
                           `((id . ,chat-id))))
                 (rest (cdr items)))
      (pcase action
        ((or 'favorite 'favorite-on 'favorite-off)
         (remhash chat-id msteams--marks)
         (msteams--execute-mark-list
          rest
          (cons
           (if (eq action 'favorite)
               (msteams--apply-favorite chat)
             (msteams--set-favorite
              chat (eq action 'favorite-on)))
           completed)))
        ('refile
         (msteams--load-state)
         (let ((undo (list :kind 'triage
                           :chat-id chat-id
                           :handled (gethash chat-id msteams--handled)
                           :snoozed (gethash chat-id msteams--snoozed))))
           (msteams--set-handled-local chat t)
           (msteams--save-state)
           (remhash chat-id msteams--marks)
           (msteams--execute-mark-list rest (cons undo completed))))
        ((or 'read 'unread)
         (let ((args
                (list "teams" "chat" "mark" (symbol-name action)
                      "--chatId" chat-id)))
           (msteams--run-json
            args
            (lambda (_payload)
              (puthash chat-id
                       (cons action (msteams--get chat 'lastUpdatedDateTime))
                       msteams--read-overrides)
              (remhash chat-id msteams--marks)
              (msteams--execute-mark-list
               rest
               (cons (list :kind (if (eq action 'read) 'unread 'read)
                           :chat-id chat-id)
                     completed)))
            (lambda (status detail)
              (msteams--record-completed-actions completed)
              (msteams--refresh-visible-recent)
              (msteams--report-error args status detail)))))
        (_
         (remhash chat-id msteams--marks)
         (msteams--execute-mark-list rest completed))))))

(defun msteams-execute-marks ()
  "Execute all deferred inbox actions serially and make them undoable."
  (interactive)
  (let (items)
    (maphash (lambda (chat-id action) (push (cons chat-id action) items))
             msteams--marks)
    (unless items (user-error "No deferred Teams actions"))
    (when (and msteams-offline-mode
               (seq-some (lambda (item) (memq (cdr item) '(read unread)))
                         items))
      (user-error "Read-state marks cannot execute in offline cache mode"))
    (when (or (not msteams-confirm-apply)
              (yes-or-no-p
               (format "Execute %d Teams action%s? "
                       (length items)
                       (if (= (length items) 1) "" "s"))))
      (msteams--execute-mark-list (nreverse items) nil))))

(defun msteams-bulk-action ()
  "Choose and execute one action for every bulk-selected inbox chat."
  (interactive)
  (unless (derived-mode-p 'msteams-recent-mode)
    (user-error "Bulk actions work in the Teams inbox"))
  (let* ((chats (msteams--selected-chats))
         (choices '(("Mark read" . read)
                    ("Mark unread" . unread)
                    ("Add favorite" . favorite-on)
                    ("Remove favorite" . favorite-off)
                    ("Handle until new" . handled)
                    ("Snooze" . snooze)
                    ("Clear local triage" . clear-triage)))
         (choice (and chats
                      (completing-read "Bulk Teams action: "
                                       (mapcar #'car choices) nil t)))
         (action (cdr (assoc choice choices)))
         (items
          (mapcar (lambda (chat)
                    (cons (msteams--chat-id chat) action))
                  chats)))
    (unless chats (user-error "No Teams chats selected"))
    (when (and msteams-offline-mode (memq action '(read unread)))
      (user-error "Read-state actions cannot execute in offline cache mode"))
    (when (or (not msteams-confirm-apply)
              (yes-or-no-p
               (format "%s %d selected Teams chat%s? "
                       choice (length chats)
                       (if (= (length chats) 1) "" "s"))))
      (if (memq action '(handled snooze clear-triage))
          (let* ((snooze-time (and (eq action 'snooze)
                                   (msteams--read-snooze-time)))
                 (until (and snooze-time
                             (format-time-string
                              "%Y-%m-%dT%H:%M:%S%z" snooze-time))))
            (dolist (chat chats)
              (remhash (msteams--chat-id chat)
                       msteams--selections)
              (pcase action
                ('handled (msteams--set-handled-local chat t))
                ('snooze (msteams--set-snoozed-local chat until))
                ('clear-triage (msteams--clear-triage-local chat))))
            (msteams--save-state)
            (msteams--render-recent)
            (message "%s %d Teams chat%s" choice (length chats)
                     (if (= (length chats) 1) "" "s")))
        (dolist (item items)
          (remhash (car item) msteams--selections)
          (puthash (car item) action msteams--marks))
        (msteams--render-recent)
        (msteams--execute-mark-list items nil)))))

(defun msteams-undo-action ()
  "Undo the most recently completed read/favorite/triage/message action."
  (interactive)
  (when msteams--undo-inflight
    (user-error "A Teams undo operation is already running"))
  (let ((item (car msteams--action-history)))
    (unless item (user-error "No Teams action to undo"))
    (pcase (plist-get item :kind)
      ('favorite
       (setq msteams--action-history
             (cdr msteams--action-history))
       (let* ((chat-id (plist-get item :chat-id))
              (enabled (plist-get item :enabled)))
         (if enabled
             (puthash chat-id t msteams--favorites)
           (remhash chat-id msteams--favorites))
         (msteams--save-state)
         (msteams--refresh-visible-recent)
         (message "Undid Teams favorite action")))
      ('triage
       (setq msteams--action-history
             (cdr msteams--action-history))
       (let ((chat-id (plist-get item :chat-id))
             (handled (plist-get item :handled))
             (snoozed (plist-get item :snoozed)))
         (if handled
             (puthash chat-id handled msteams--handled)
           (remhash chat-id msteams--handled))
         (if snoozed
             (puthash chat-id snoozed msteams--snoozed)
           (remhash chat-id msteams--snoozed))
         (msteams--save-state)
         (msteams--refresh-visible-recent)
         (message "Undid Teams refile action")))
      ((or 'read 'unread)
       (msteams--require-online)
       (let ((kind (plist-get item :kind))
             (chat-id (plist-get item :chat-id))
             args)
         (setq args
               (list "teams" "chat" "mark" (symbol-name kind)
                     "--chatId" chat-id)
               msteams--undo-inflight t)
         (msteams--run-json
          args
          (lambda (_payload)
            (setq msteams--undo-inflight nil
                  msteams--action-history
                  (delq item msteams--action-history))
            (remhash chat-id msteams--read-overrides)
            (msteams--refresh-visible-recent)
            (message "Undid Teams read-state action"))
          (lambda (status detail)
            (setq msteams--undo-inflight nil)
            (msteams--report-error args status detail)))))
      ('backend
       (msteams--require-online)
       (let ((args (plist-get item :args)))
         (setq msteams--undo-inflight t)
         (msteams--run-json
          args
          (lambda (_payload)
            (setq msteams--undo-inflight nil
                  msteams--action-history
                  (delq item msteams--action-history))
            (msteams--refresh-current-view)
            (message "Undid %s" (plist-get item :label)))
          (lambda (status detail)
            (setq msteams--undo-inflight nil)
            (msteams--report-error args status detail)))))
      (_ (user-error "This Teams action is not undoable")))))

;;; advanced.el continues with channels, message actions, and compose support.

(defun msteams--team-label (team)
  "Return display label for TEAM."
  (or (msteams--get team 'displayName)
      (msteams--get team 'id)
      "Team"))

(defun msteams--channel-label (channel)
  "Return display label for CHANNEL."
  (or (msteams--get channel 'displayName)
      (msteams--get channel 'id)
      "Channel"))

(defun msteams--load-teams (callback)
  "Load joined teams and pass them to CALLBACK."
  (msteams--run-json
   (if msteams-offline-mode
       '("teams" "cache" "team" "list")
     '("teams" "team" "list"))
   (lambda (payload) (funcall callback (msteams--payload-list payload)))))

(defun msteams--load-channels (team callback)
  "Load channels for TEAM and pass them to CALLBACK."
  (let ((team-id (msteams--get team 'id)))
    (msteams--run-json
     (if msteams-offline-mode
         (list "teams" "cache" "channel" "list" "--teamId" team-id)
       (list "teams" "channel" "list" "--teamId" team-id))
     (lambda (payload) (funcall callback (msteams--payload-list payload))))))

(defun msteams--choose-object (prompt objects label-function callback)
  "Complete among OBJECTS using LABEL-FUNCTION and call CALLBACK."
  (unless objects (user-error "No Teams objects are available"))
  (let* ((pairs
          (mapcar
           (lambda (object)
             (let ((id (or (msteams--get object 'id) "unknown")))
               (cons (format "%s [%s]" (funcall label-function object)
                             (substring (md5 id) 0 8))
                     object)))
           objects))
         (choice (completing-read prompt (mapcar #'car pairs) nil t)))
    (funcall callback (cdr (assoc choice pairs)))))

(defun msteams-channels ()
  "Select a joined team and channel, then open its native thread index."
  (interactive)
  (msteams--with-status
   (lambda ()
     (msteams--load-teams
      (lambda (teams)
        (msteams--choose-object
         "Team: " teams #'msteams--team-label
         (lambda (team)
           (msteams--load-channels
            team
            (lambda (channels)
              (msteams--choose-object
               "Channel: " channels #'msteams--channel-label
               (lambda (channel)
                 (msteams-open-channel team channel))))))))))))

(defun msteams--channel-index-buffer-name (team channel)
  "Return stable index buffer name for TEAM and CHANNEL."
  (format "*Teams Channel %s/%s*"
          (substring (md5 (or (msteams--get team 'id) "team")) 0 6)
          (substring (md5 (or (msteams--get channel 'id) "channel")) 0 6)))

(defun msteams--channel-thread-buffer-name (team channel root)
  "Return stable thread buffer name for TEAM CHANNEL ROOT."
  (format "*Teams Channel Thread %s*"
          (substring
           (md5 (concat (or (msteams--get team 'id) "") "/"
                        (or (msteams--get channel 'id) "") "/"
                        (or (msteams--get root 'id) "")))
           0 8)))

(defun msteams--channel-root-subject (root)
  "Return readable subject for channel ROOT."
  (or (let ((subject (msteams--get root 'subject)))
        (and (stringp subject) (not (string-empty-p subject)) subject))
      (truncate-string-to-width
       (replace-regexp-in-string
        "[\n\r\t ]+" " " (msteams--message-body root))
       54 nil nil "...")
      "Channel post"))

(defun msteams--channel-root-entry (root)
  "Build one channel index row for ROOT."
  (list
   (msteams--get root 'id)
   (vector
    (propertize (msteams--channel-root-subject root)
                'face 'msteams-channel-subject)
    (msteams--message-sender root)
    (truncate-string-to-width
     (replace-regexp-in-string
      "[\n\r\t ]+" " " (msteams--message-body root))
     55 nil nil "...")
    (msteams--format-date (msteams--get root 'createdDateTime)))))

(defun msteams--render-channel-index ()
  "Render current channel root-message index, preserving selection."
  (let ((selected (tabulated-list-get-id)))
    (setq tabulated-list-entries
          (mapcar #'msteams--channel-root-entry
                  msteams-channel--roots)
          header-line-format
          (format "%s / %s - %d threads%s%s"
                  (msteams--team-label msteams-channel--team)
                  (msteams--channel-label msteams-channel--channel)
                  (length msteams-channel--roots)
                  (if msteams-offline-mode " - OFFLINE" "")
                  (if msteams-mock-mode " - MOCK" "")))
    (tabulated-list-print t)
    (when selected
      (goto-char (point-min))
      (while (and (not (equal selected (tabulated-list-get-id)))
                  (not (eobp)))
        (forward-line 1)))
    (unless (tabulated-list-get-id)
      (goto-char (point-min))
      (forward-line 1))
    (msteams--schedule-channel-preview)))

(defun msteams-channel-root-at-point ()
  "Return channel root represented at point."
  (let ((id (tabulated-list-get-id)))
    (or (seq-find (lambda (root) (equal id (msteams--get root 'id)))
                  msteams-channel--roots)
        (user-error "No channel thread on this row"))))

(defvar msteams-channel-index-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map tabulated-list-mode-map)
    (define-key map (kbd "RET") #'msteams-channel-open-thread)
    (define-key map (kbd "l") #'msteams-channel-open-thread)
    (define-key map (kbd "j") #'msteams-channel-next)
    (define-key map (kbd "k") #'msteams-channel-previous)
    (define-key map (kbd "g") #'msteams-channel-refresh)
    (define-key map (kbd "c") #'msteams-channel-compose)
    (define-key map (kbd "E") #'msteams-channel-export-thread)
    (define-key map (kbd "Y")
                #'msteams-channel-copy-thread-markdown)
    (define-key map (kbd "o") #'msteams-open-current-in-browser)
    (define-key map (kbd "O") #'msteams-open-current-in-app)
    (define-key map (kbd "/") #'msteams-search)
    (define-key map (kbd "?") #'msteams-dispatch)
    (define-key map (kbd "q") #'msteams-quit)
    map)
  "Keymap for native Teams channel thread indexes.")

(define-derived-mode msteams-channel-index-mode
  tabulated-list-mode "Teams-Channel"
  "Major mode for browsing root threads in one Teams channel."
  (setq tabulated-list-format
        [("Subject" 32 t) ("From" 20 t) ("Preview" 55 nil) ("Date" 16 t)]
        tabulated-list-padding 1)
  (add-hook 'kill-buffer-hook #'msteams--cancel-buffer-process nil t)
  (tabulated-list-init-header))

(defun msteams-open-channel (team channel)
  "Open native thread index for TEAM and CHANNEL."
  (let ((buffer
         (get-buffer-create
          (msteams--channel-index-buffer-name team channel))))
    (pop-to-buffer buffer)
    (unless (derived-mode-p 'msteams-channel-index-mode)
      (msteams-channel-index-mode))
    (setq msteams-channel--team team
          msteams-channel--channel channel
          header-line-format "Loading channel threads...")
    (msteams-channel-refresh)))

(defun msteams-channel-refresh ()
  "Refresh root posts in the current Teams channel."
  (interactive)
  (unless (derived-mode-p 'msteams-channel-index-mode)
    (user-error "Not in a Teams channel index"))
  (msteams--cancel-process msteams--process)
  (cl-incf msteams-channel--request-id)
  (let ((buffer (current-buffer))
        (request-id msteams-channel--request-id)
        (team-id (msteams--get msteams-channel--team 'id))
        (channel-id (msteams--get msteams-channel--channel 'id))
        args)
    (setq args
          (if msteams-offline-mode
              (list "teams" "cache" "channel" "message" "list"
                    "--teamId" team-id "--channelId" channel-id
                    "--limit" "1000000")
            (list "teams" "channel" "message" "list"
                  "--teamId" team-id "--channelId" channel-id)))
    (setq header-line-format "Loading channel threads...")
    (setq
     msteams--process
     (msteams--run-json
      args
      (lambda (payload)
        (when (buffer-live-p buffer)
          (with-current-buffer buffer
            (when (= request-id msteams-channel--request-id)
              (setq msteams--process nil
                    msteams-channel--roots
                    (msteams--normalize-messages
                     (msteams--payload-list payload)))
              (msteams--render-channel-index)))))
      (lambda (status detail)
        (when (buffer-live-p buffer)
          (with-current-buffer buffer
            (when (= request-id msteams-channel--request-id)
              (setq msteams--process nil
                    header-line-format
                    "Teams channel load failed - see *M365 Errors*"))))
        (msteams--report-error args status detail))))))

(defun msteams--channel-move (delta)
  "Move DELTA channel root rows and optionally preview the selected thread."
  (let ((origin (point)))
    (forward-line delta)
    (beginning-of-line)
    (unless (tabulated-list-get-id) (goto-char origin))
    (msteams--schedule-channel-preview)))

(defun msteams--schedule-channel-preview ()
  "Preview the selected channel thread after the configured idle delay."
  (when (timerp msteams--preview-timer)
    (cancel-timer msteams--preview-timer))
  (setq msteams--preview-timer nil)
  (when (and msteams-preview-on-move (tabulated-list-get-id))
    (let ((buffer (current-buffer))
          (root-id (tabulated-list-get-id)))
      (setq msteams--preview-timer
            (run-with-idle-timer
             msteams-preview-delay nil
             (lambda ()
               (when (buffer-live-p buffer)
                 (with-current-buffer buffer
                   (setq msteams--preview-timer nil)
                   (when (equal root-id (tabulated-list-get-id))
                     (msteams-open-channel-thread
                      msteams-channel--team
                      msteams-channel--channel
                      (msteams-channel-root-at-point) t))))))))))

(defun msteams-channel-next ()
  "Move to and preview the next channel thread."
  (interactive)
  (msteams--channel-move 1))

(defun msteams-channel-previous ()
  "Move to and preview the previous channel thread."
  (interactive)
  (msteams--channel-move -1))

(defun msteams-channel-open-thread ()
  "Open and focus the selected channel thread."
  (interactive)
  (msteams-open-channel-thread
   msteams-channel--team msteams-channel--channel
   (msteams-channel-root-at-point)))

(defvar msteams-channel-thread-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (define-key map (kbd "g") #'msteams-channel-thread-refresh)
    (define-key map (kbd "S") #'msteams-toggle-message-order)
    (define-key map (kbd "j") #'msteams-channel-thread-next)
    (define-key map (kbd "k") #'msteams-channel-thread-previous)
    (define-key map (kbd "M-j") #'msteams-chat-next-message)
    (define-key map (kbd "M-k") #'msteams-chat-previous-message)
    (define-key map (kbd "R") #'msteams-channel-reply)
    (define-key map (kbd "c") #'msteams-channel-compose)
    (define-key map (kbd "C") #'msteams-channel-compose)
    (define-key map (kbd "+") #'msteams-message-react)
    (define-key map (kbd "-") #'msteams-message-unreact)
    (define-key map (kbd "e") #'msteams-message-edit)
    (define-key map (kbd "d") #'msteams-message-delete)
    (define-key map (kbd "f") #'msteams-message-forward)
    (define-key map (kbd "F") #'msteams-message-forward)
    (define-key map (kbd "a") #'msteams-attachment-download)
    (define-key map (kbd "A") #'msteams-attachment-preview)
    (define-key map (kbd "E") #'msteams-channel-export-thread)
    (define-key map (kbd "Y")
                #'msteams-channel-copy-thread-markdown)
    (define-key map (kbd "o") #'msteams-open-current-in-browser)
    (define-key map (kbd "O") #'msteams-open-current-in-app)
    (define-key map (kbd "/") #'msteams-search)
    (define-key map (kbd "?") #'msteams-dispatch)
    (define-key map (kbd "u") #'msteams-undo-action)
    (define-key map (kbd "h") #'msteams-channel-back-to-index)
    (define-key map (kbd "b") #'msteams-channel-back-to-index)
    (define-key map (kbd "q") #'msteams-channel-view-quit)
    map)
  "Keymap for native Teams channel thread buffers.")

(define-derived-mode msteams-channel-thread-mode
  msteams-read-mode "Teams-Read"
  "Major mode for reading one root post and its channel replies."
  nil)

(defun msteams--display-channel-thread (buffer preview)
  "Display channel thread BUFFER beside its index, preserving PREVIEW focus."
  (let* ((index-buffer
          (get-buffer
           (msteams--channel-index-buffer-name
            msteams-channel--team msteams-channel--channel)))
         (index-window (and index-buffer (get-buffer-window index-buffer t))))
    (if (not (window-live-p index-window))
        (if preview (display-buffer buffer) (pop-to-buffer buffer))
      (let ((right (or (get-buffer-window buffer t)
                       (window-in-direction 'right index-window)
                       (split-window index-window nil 'right))))
        (set-window-buffer right buffer)
        (unless preview (select-window right))))))

(defun msteams-open-channel-thread (team channel root &optional preview)
  "Open ROOT and all replies from TEAM CHANNEL; keep index focus for PREVIEW."
  (let ((buffer (get-buffer-create msteams--read-buffer-name)))
    (with-current-buffer buffer
      (unless (derived-mode-p 'msteams-channel-thread-mode)
        (when (derived-mode-p 'msteams-read-mode)
          (msteams--cancel-buffer-process))
        (msteams-channel-thread-mode))
      (let ((same-thread
             (and msteams-channel--team
                  msteams-channel--channel
                  msteams-channel--root
                  (equal (msteams--get msteams-channel--team 'id)
                         (msteams--get team 'id))
                  (equal (msteams--get msteams-channel--channel 'id)
                         (msteams--get channel 'id))
                  (equal (msteams--get msteams-channel--root 'id)
                         (msteams--get root 'id)))))
        (setq msteams-channel--team team
              msteams-channel--channel channel
              msteams-channel--root root
              msteams--automatic-preview-p (not (null preview))
              msteams--jump-to-bottom-on-render (not preview))
        (unless same-thread
          (msteams--cancel-image-loads)
          (setq msteams-channel--messages nil)
          (let ((inhibit-read-only t))
            (erase-buffer)
            (insert (format "Loading %s / %s...\n"
                            (msteams--channel-label channel)
                            (msteams--channel-root-subject root))))))
      (msteams-channel-thread-refresh))
    (let ((msteams-channel--team team)
          (msteams-channel--channel channel))
      (msteams--display-channel-thread buffer preview))
    (msteams--close-other-readers buffer)))

(defun msteams--render-channel-thread ()
  "Render current channel root and replies with stable message properties."
  (let* ((inhibit-read-only t)
         (pending-message-id msteams-channel--pending-message-id)
         (jump-to-bottom (and msteams--jump-to-bottom-on-render
                              (not pending-message-id)))
         (message-id
          (or pending-message-id
              (unless msteams--jump-to-bottom-on-render
                (msteams--get (msteams-message-at-point) 'id))))
         last-day)
    (msteams--cancel-image-loads)
    (erase-buffer)
    (insert (propertize
             (format "%s / %s\n%s"
                     (msteams--team-label
                      msteams-channel--team)
                     (msteams--channel-label
                      msteams-channel--channel)
                     (msteams--channel-root-subject
                      msteams-channel--root))
             'face '(:height 1.15 :weight bold)))
    (insert "\n\n")
    (dolist (message
             (msteams--messages-for-display
              msteams-channel--messages))
      (let* ((created (or (msteams--get message 'createdDateTime) ""))
             (day (car (split-string created "T"))))
        (unless (equal day last-day)
          (setq last-day day)
          (msteams--insert-day-separator created))
        (msteams--insert-message message)))
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
    (setq msteams-channel--pending-message-id nil
          msteams--jump-to-bottom-on-render nil
          header-line-format
          (format "%s / %s - %d messages - %s%s%s"
                  (msteams--team-label msteams-channel--team)
                  (msteams--channel-label msteams-channel--channel)
                  (length msteams-channel--messages)
                  (msteams--message-order-label)
                  (if msteams-offline-mode " - OFFLINE" "")
                  (if msteams-mock-mode " - MOCK" "")))))

(defun msteams-channel-thread-refresh ()
  "Load all replies and rerender the current channel thread."
  (interactive)
  (unless (derived-mode-p 'msteams-channel-thread-mode)
    (user-error "Not in a Teams channel thread"))
  (msteams--cancel-process msteams--process)
  (cl-incf msteams-channel--request-id)
  (let ((buffer (current-buffer))
        (request-id msteams-channel--request-id)
        (team-id (msteams--get msteams-channel--team 'id))
        (channel-id (msteams--get msteams-channel--channel 'id))
        (root-id (msteams--get msteams-channel--root 'id))
        args)
    (setq args
          (if msteams-offline-mode
              (list "teams" "cache" "channel" "reply" "list"
                    "--teamId" team-id "--channelId" channel-id
                    "--messageId" root-id "--limit" "1000000")
            (list "teams" "channel" "reply" "list"
                  "--teamId" team-id "--channelId" channel-id
                  "--messageId" root-id)))
    (setq header-line-format "Loading channel replies...")
    (setq
     msteams--process
     (msteams--run-json
      args
      (lambda (payload)
        (when (buffer-live-p buffer)
          (with-current-buffer buffer
            (when (and (= request-id msteams-channel--request-id)
                       (derived-mode-p
                        'msteams-channel-thread-mode)
                       (equal team-id
                              (msteams--get
                               msteams-channel--team 'id))
                       (equal channel-id
                              (msteams--get
                               msteams-channel--channel 'id))
                       (equal root-id
                              (msteams--get
                               msteams-channel--root 'id)))
              (setq msteams--process nil
                    msteams-channel--messages
                    (msteams--normalize-messages
                     (cons msteams-channel--root
                           (msteams--payload-list payload))))
              (msteams--render-channel-thread)))))
      (lambda (status detail)
        (when (buffer-live-p buffer)
          (with-current-buffer buffer
            (when (and (= request-id msteams-channel--request-id)
                       (derived-mode-p
                        'msteams-channel-thread-mode)
                       (equal team-id
                              (msteams--get
                               msteams-channel--team 'id))
                       (equal channel-id
                              (msteams--get
                               msteams-channel--channel 'id))
                       (equal root-id
                              (msteams--get
                               msteams-channel--root 'id)))
              (setq msteams--process nil
                    header-line-format
                    "Teams channel replies failed - see *M365 Errors*"))))
        (msteams--report-error args status detail))))))

(defun msteams-channel-target ()
  "Return compose target for the current channel context."
  (list :team-id (msteams--get msteams-channel--team 'id)
        :channel-id (msteams--get msteams-channel--channel 'id)
        :label (format "%s / %s"
                       (msteams--team-label
                        msteams-channel--team)
                       (msteams--channel-label
                        msteams-channel--channel))))

(defun msteams-channel-compose ()
  "Compose a new root post in the current channel."
  (interactive)
  (msteams--require-online)
  (msteams--open-compose (msteams-channel-target)))

(defun msteams-channel-reply ()
  "Compose a reply under the current channel root."
  (interactive)
  (msteams--require-online)
  (msteams--open-compose
   (msteams-channel-target) msteams-channel--root))

(defun msteams-channel-back-to-index ()
  "Return focus to the current channel root index."
  (interactive)
  (let ((buffer
         (get-buffer
          (msteams--channel-index-buffer-name
           msteams-channel--team msteams-channel--channel))))
    (if-let ((window (and buffer (get-buffer-window buffer t))))
        (select-window window)
      (msteams-open-channel
       msteams-channel--team msteams-channel--channel))))

(defun msteams-channel-view-quit ()
  "Close the Teams channel reader pane and return to its root index."
  (interactive)
  (msteams--close-reader-to-index
   (get-buffer
    (msteams--channel-index-buffer-name
     msteams-channel--team msteams-channel--channel))))

(defun msteams-channel-thread-relative (delta)
  "Open the channel root DELTA rows from the current thread."
  (interactive "p")
  (unless (derived-mode-p 'msteams-channel-thread-mode)
    (user-error "Open a Teams channel thread first"))
  (let* ((team msteams-channel--team)
         (channel msteams-channel--channel)
         (root-id (msteams--get msteams-channel--root 'id))
         (index-buffer
          (get-buffer (msteams--channel-index-buffer-name team channel)))
         target)
    (unless (buffer-live-p index-buffer)
      (user-error "Open the Teams channel index before moving between threads"))
    (with-current-buffer index-buffer
      (when-let ((target-id
                  (msteams--tabulated-neighbor-id root-id delta)))
        (setq target
              (seq-find
               (lambda (root) (equal target-id (msteams--get root 'id)))
               msteams-channel--roots))))
    (unless target
      (user-error "No Teams channel thread in that direction"))
    (msteams-open-channel-thread team channel target)))

(defun msteams-channel-thread-next ()
  "Open the next root from the current Teams channel thread."
  (interactive)
  (msteams-channel-thread-relative 1))

(defun msteams-channel-thread-previous ()
  "Open the previous root from the current Teams channel thread."
  (interactive)
  (msteams-channel-thread-relative -1))

(defun msteams--channel-thread-context ()
  "Return complete-fetch context for the channel thread at point."
  (unless (or (derived-mode-p 'msteams-channel-thread-mode)
              (derived-mode-p 'msteams-channel-index-mode))
    (user-error "Open a Teams channel or channel thread first"))
  (let* ((team msteams-channel--team)
         (channel msteams-channel--channel)
         (root (if (derived-mode-p 'msteams-channel-thread-mode)
                   msteams-channel--root
                 (msteams-channel-root-at-point)))
         (team-id (msteams--get team 'id))
         (channel-id (msteams--get channel 'id))
         (root-id (msteams--get root 'id))
         (pseudo-chat
          `((id . ,(format "%s/%s/%s" team-id channel-id root-id))
            (topic . ,(format "%s - %s"
                              (msteams--channel-label channel)
                              (msteams--channel-root-subject root)))
            (webUrl . ,(msteams--get root 'webUrl))))
         (args
          (if msteams-offline-mode
              (list "teams" "cache" "channel" "reply" "list"
                    "--teamId" team-id "--channelId" channel-id
                    "--messageId" root-id "--limit" "1000000")
            (list "teams" "channel" "reply" "list"
                  "--teamId" team-id "--channelId" channel-id
                  "--messageId" root-id))))
    (list :chat pseudo-chat :root root :args args)))

(defun msteams--fetch-channel-thread (callback)
  "Fetch the complete current channel thread and invoke CALLBACK.

CALLBACK receives a chat-like metadata object followed by chronological root
and reply messages."
  (let* ((context (msteams--channel-thread-context))
         (chat (plist-get context :chat))
         (root (plist-get context :root))
         (args (plist-get context :args)))
    (msteams--run-json
     args
     (lambda (payload)
       (funcall callback chat
                (msteams--normalize-messages
                 (cons root (msteams--payload-list payload))))))))

(defun msteams-channel-export-thread (&optional open after-export)
  "Export complete channel thread at point; with OPEN, visit it.

Call AFTER-EXPORT with the saved path when it is non-nil."
  (interactive "P")
  (message "Exporting complete Teams channel thread...")
  (msteams--fetch-channel-thread
   (lambda (chat messages)
     (msteams--finish-thread-export
      chat messages open after-export))))

(defun msteams-channel-copy-thread-markdown ()
  "Fetch and copy the complete channel thread at point as Markdown."
  (interactive)
  (message "Copying complete Teams channel thread...")
  (msteams--fetch-channel-thread
   #'msteams--copy-thread-markdown))

(defun msteams-export-current-thread (&optional open after-export)
  "Export the current channel thread, or select/export a chat.

With prefix argument OPEN, visit the generated Markdown file.  Call
AFTER-EXPORT with its saved path when that callback is non-nil."
  (interactive "P")
  (if (or (derived-mode-p 'msteams-channel-thread-mode)
          (derived-mode-p 'msteams-channel-index-mode))
      (msteams-channel-export-thread open after-export)
    (if-let ((chat (msteams--chat-at-point)))
        (msteams--export-thread chat open after-export)
      (msteams--select-chat
       (lambda (selected)
         (msteams--export-thread selected open after-export))))))

(defun msteams-copy-current-thread-markdown ()
  "Copy the current channel thread, or select and copy a chat, as Markdown."
  (interactive)
  (if (or (derived-mode-p 'msteams-channel-thread-mode)
          (derived-mode-p 'msteams-channel-index-mode))
      (msteams-channel-copy-thread-markdown)
    (msteams-copy-thread-markdown)))

(defun msteams--thread-analysis-agent-config ()
  "Resolve `msteams-thread-analysis-agent' to an agent config."
  (unless (require 'agent-shell nil t)
    (user-error "agent-shell is unavailable; install and configure agent-shell"))
  (let* ((identifier msteams-thread-analysis-agent)
         (config
          (cond
           ((fboundp 'agent-shell--resolve-config-designator)
            (agent-shell--resolve-config-designator identifier))
           ((boundp 'agent-shell-agent-configs)
            (seq-find
             (lambda (candidate)
               (eq (map-elt candidate :identifier) identifier))
             (mapcar (lambda (entry)
                       (if (functionp entry) (funcall entry) entry))
                     agent-shell-agent-configs))))))
    (unless config
      (user-error
       "No agent-shell config `%s'; customize msteams-thread-analysis-agent"
       identifier))
    config))

(defun msteams--start-thread-analysis (path config)
  "Start a new agent-shell with CONFIG and submit an analysis prompt for PATH."
  (let* ((absolute-path (expand-file-name path))
         (default-directory
          (file-name-as-directory (file-name-directory absolute-path)))
         (shell-buffer (agent-shell-start :config config))
         (prompt
          (format "$thread-analysis of this thread: %s" absolute-path)))
    ;; agent-shell queues this submission until its first ACP prompt is ready.
    (agent-shell-insert :text prompt :submit t :shell-buffer shell-buffer)
    (message "Started Teams thread analysis with %s"
             (map-elt config :identifier))
    shell-buffer))

(defun msteams-analyze-current-thread ()
  "Export the complete current Teams thread and analyze it in a new agent-shell."
  (interactive)
  (let ((config (msteams--thread-analysis-agent-config)))
    (msteams-export-current-thread
     nil
     (lambda (path)
       (msteams--start-thread-analysis path config)))))

(defun msteams--channel-capture-context
    (team channel root &optional message)
  "Build complete Org metadata for TEAM CHANNEL ROOT and selected MESSAGE."
  (let* ((team-name (msteams--team-label team))
         (channel-name (msteams--channel-label channel))
         (subject (msteams--channel-root-subject root))
         (root-url (msteams--get root 'webUrl))
         (message-url (msteams--get message 'webUrl)))
    `((kind . "channel")
      (title . ,(format "%s / %s: %s" team-name channel-name subject))
      (conversationType . "Channel")
      (teamId . ,(msteams--get team 'id))
      (teamName . ,team-name)
      (channelId . ,(msteams--get channel 'id))
      (channelName . ,channel-name)
      (threadId . ,(msteams--get root 'id))
      (conversationUrl . ,(or root-url (msteams--get channel 'webUrl)))
      (selectedMessageId . ,(msteams--get message 'id))
      (selectedMessageUrl . ,message-url)
      (sourceUrl . ,(or message-url root-url
                        (msteams--get channel 'webUrl)))
      (updated . ,(or (msteams--get root 'lastModifiedDateTime)
                      (msteams--get root 'createdDateTime))))))

(defun msteams-capture-channel-thread ()
  "Fetch and start Org capture for the complete channel thread at point."
  (interactive)
  (unless (or (derived-mode-p 'msteams-channel-index-mode)
              (derived-mode-p 'msteams-channel-thread-mode))
    (user-error "Open a Teams channel thread first"))
  (let* ((team msteams-channel--team)
         (channel msteams-channel--channel)
         (root (if (derived-mode-p 'msteams-channel-index-mode)
                   (msteams-channel-root-at-point)
                 msteams-channel--root))
         (message (if (derived-mode-p 'msteams-channel-thread-mode)
                      (or (msteams-message-at-point) root)
                    root))
         (team-id (msteams--get team 'id))
         (channel-id (msteams--get channel 'id))
         (root-id (msteams--get root 'id))
         (context
          (msteams--channel-capture-context
           team channel root message))
         (args
          (if msteams-offline-mode
              (list "teams" "cache" "channel" "reply" "list"
                    "--teamId" team-id "--channelId" channel-id
                    "--messageId" root-id "--limit" "1000000")
            (list "teams" "channel" "reply" "list"
                  "--teamId" team-id "--channelId" channel-id
                  "--messageId" root-id))))
    (message "Preparing complete Teams channel thread for Org capture...")
    (msteams--run-json
     args
     (lambda (payload)
       (msteams--start-thread-org-capture
        context
        (msteams--normalize-messages
         (cons root (msteams--payload-list payload))))))))

(defun msteams-capture-current-thread ()
  "Capture the complete selected chat or channel thread through Org capture."
  (interactive)
  (cond
   ((or (derived-mode-p 'msteams-channel-index-mode)
        (derived-mode-p 'msteams-channel-thread-mode))
    (msteams-capture-channel-thread))
   ((msteams--chat-at-point)
    (let* ((chat (msteams--chat-at-point))
           (message
            (if (derived-mode-p 'msteams-chat-mode)
                (msteams-message-at-point)
              (msteams--get chat 'lastMessagePreview))))
      (msteams-capture-chat-thread chat message)))
   (t
    (msteams--select-chat
     (lambda (chat)
       (msteams-capture-chat-thread
       chat (msteams--get chat 'lastMessagePreview)))))))

(defun msteams--chat-summary-message (chat)
  "Return the latest known message used for compact CHAT capture."
  (or (and (derived-mode-p 'msteams-chat-mode)
           (car (last msteams--messages)))
      (msteams--get chat 'lastMessagePreview)))

(defun msteams--capture-chat-summary-or-jump (chat message)
  "Jump to CHAT's existing Org capture, or create a summary for MESSAGE."
  (let ((context (msteams--chat-capture-context chat message)))
    (if (msteams--jump-to-capture-context context)
        (message "Opened the existing Teams Org capture")
      (msteams-capture-chat-summary chat message))))

(defun msteams--current-capture-context ()
  "Return capture context for the selected Teams conversation and message."
  (cond
   ((or (derived-mode-p 'msteams-channel-index-mode)
        (derived-mode-p 'msteams-channel-thread-mode))
    (let* ((root (if (derived-mode-p 'msteams-channel-index-mode)
                     (msteams-channel-root-at-point)
                   msteams-channel--root))
           (message (if (derived-mode-p 'msteams-channel-thread-mode)
                        (or (msteams-message-at-point) root)
                      root)))
      (msteams--channel-capture-context
       msteams-channel--team msteams-channel--channel
       root message)))
   ((msteams--chat-at-point)
    (let ((chat (msteams--chat-at-point)))
      (msteams--chat-capture-context
       chat (msteams--chat-summary-message chat))))))

(defun msteams-jump-to-capture ()
  "Open the Org entry linked to the current Teams conversation or message."
  (interactive)
  (let ((context (msteams--current-capture-context)))
    (unless context (user-error "No Teams conversation here"))
    (unless (msteams--jump-to-capture-context context)
      (user-error "This Teams conversation has not been captured to Org"))))

(defun msteams--vtt-to-text (content)
  "Convert WebVTT transcript CONTENT into readable speaker paragraphs."
  (let (lines)
    (dolist (line (string-lines (or content "")))
      (setq line (string-trim line))
      (cond
       ((or (string-empty-p line)
            (string-equal line "WEBVTT")
            (string-prefix-p "NOTE" line)
            (string-match-p
             "\\`[0-9:.]+[ \t]+-->[ \t]+[0-9:.]+" line)
            (string-match-p "\\`[0-9]+\\'" line)))
       ((string-match "\\`<v \\([^>]+\\)>\\(.*\\)</v>\\'" line)
        (push (format "%s: %s"
                      (match-string 1 line)
                      (msteams--html-to-text (match-string 2 line)))
              lines))
       (t (push (msteams--html-to-text line) lines))))
    (string-join (nreverse lines) "\n\n")))

(defun msteams-meeting-transcript ()
  "Fetch and display the latest transcript for the current meeting chat."
  (interactive)
  (msteams--require-online)
  (let* ((chat (or (msteams--chat-at-point)
                   (user-error "No Teams chat here")))
         (chat-id (msteams--chat-id chat))
         (args (list "teams" "meeting" "transcript" "--chatId" chat-id)))
    (unless (msteams--meeting-chat-p chat)
      (user-error "The current Teams conversation is not a meeting chat"))
    (message "Loading Teams meeting transcript...")
    (msteams--run-json
     args
     (lambda (payload)
       (let* ((buffer (get-buffer-create
                       msteams--transcript-buffer-name))
              (event (msteams--get payload 'event))
              (meeting (msteams--get payload 'meeting))
              (transcript (msteams--get payload 'transcript))
              (title (or (msteams--get event 'subject)
                         (msteams--get meeting 'subject)
                         (msteams--chat-label chat)))
              (created (msteams--get transcript 'createdDateTime))
              (body (msteams--vtt-to-text
                     (msteams--get payload 'content))))
         (with-current-buffer buffer
           (let ((inhibit-read-only t))
             (erase-buffer)
             (insert (propertize title 'face '(:height 1.2 :weight bold)) "\n")
             (when created
               (insert (propertize
                        (format "Transcript created %s\n"
                                (msteams--format-date created t))
                        'face 'shadow)))
             (insert "\n" (if (string-empty-p body)
                                "[Transcript has no text]" body) "\n")
             (goto-char (point-min))
             (special-mode)
             (visual-line-mode 1)))
         (pop-to-buffer buffer)))
     (lambda (status detail)
       (msteams--report-error args status detail)
       (message "Teams transcript unavailable; see *M365 Errors*")))))

(defun msteams-capture-current-summary ()
  "Capture title, source, date, and last-message context without a transcript.

For meeting chats, calendar time and participants are included when Graph can
resolve the linked event.  This is the primary mu4e-style `a a' action."
  (interactive)
  (cond
   ((or (derived-mode-p 'msteams-channel-index-mode)
        (derived-mode-p 'msteams-channel-thread-mode))
    (let* ((root (if (derived-mode-p 'msteams-channel-index-mode)
                     (msteams-channel-root-at-point)
                   msteams-channel--root))
           (message
            (if (derived-mode-p 'msteams-channel-thread-mode)
                (or (msteams-message-at-point) root)
              root))
           (context
            (msteams--channel-capture-context
             msteams-channel--team
             msteams-channel--channel root message)))
      (if (msteams--jump-to-capture-context context)
          (message "Opened the existing Teams Org capture")
        (msteams--start-summary-org-capture context message))))
   ((msteams--chat-at-point)
    (let* ((chat (msteams--chat-at-point))
           (message (msteams--chat-summary-message chat)))
      (msteams--capture-chat-summary-or-jump chat message)))
   (t
    (msteams--select-chat
     (lambda (chat)
       (msteams--capture-chat-summary-or-jump
        chat (msteams--get chat 'lastMessagePreview)))))))

(defun msteams-current-message ()
  "Return the message at point in a chat or channel transcript."
  (unless (or (derived-mode-p 'msteams-chat-mode)
              (derived-mode-p 'msteams-channel-thread-mode))
    (user-error "Move to a Teams chat or channel transcript first"))
  (or (msteams-message-at-point)
      (user-error "Move point onto a Teams message first")))

(defun msteams--message-context-args (message)
  "Return backend context arguments for MESSAGE at point."
  (let ((message-id (msteams--get message 'id)))
    (unless (stringp message-id) (user-error "Message has no Graph ID"))
    (cond
     ((derived-mode-p 'msteams-chat-mode)
      (list "--scope" "chat"
            "--chatId" (msteams--chat-id msteams--chat)
            "--messageId" message-id))
     ((derived-mode-p 'msteams-channel-thread-mode)
      (let ((root-id (msteams--get msteams-channel--root 'id)))
        (append
         (list "--scope" "channel"
               "--teamId" (msteams--get msteams-channel--team 'id)
               "--channelId"
               (msteams--get msteams-channel--channel 'id)
               "--messageId" message-id)
         (unless (equal message-id root-id)
           (list "--rootMessageId" root-id)))))
     (t (user-error "No Teams message context")))))

(defun msteams--refresh-current-view ()
  "Refresh the active native Teams transcript or index."
  (cond
   ((derived-mode-p 'msteams-chat-mode)
    (msteams-chat-refresh))
   ((derived-mode-p 'msteams-channel-thread-mode)
    (msteams-channel-thread-refresh))
   ((derived-mode-p 'msteams-channel-index-mode)
    (msteams-channel-refresh))
   ((derived-mode-p 'msteams-recent-mode)
    (msteams-recent-refresh))))

(defun msteams--run-message-action
    (action message extra inverse-action inverse-extra label)
  "Run message ACTION on MESSAGE with EXTRA arguments and record its inverse."
  (msteams--require-online)
  (let* ((buffer (current-buffer))
         (context (msteams--message-context-args message))
         (args (append (list "teams" "message" (symbol-name action))
                       context extra))
         (inverse
          (and inverse-action
               (append (list "teams" "message"
                             (symbol-name inverse-action))
                       context inverse-extra))))
    (msteams--run-json
     args
     (lambda (_payload)
       (when inverse
         (push (list :kind 'backend :args inverse :label label)
               msteams--action-history))
       (when (buffer-live-p buffer)
         (with-current-buffer buffer (msteams--refresh-current-view)))
       (message "%s" label)))))

(defconst msteams--reaction-choices
  '("👍" "❤️" "😂" "😮" "😢" "😡")
  "Common Unicode Graph reactions; arbitrary Unicode remains accepted.")

(defun msteams-message-react (reaction)
  "Set REACTION on the Teams message at point."
  (interactive
   (list (completing-read "Reaction: " msteams--reaction-choices
                          nil nil)))
  (let ((message (msteams-current-message)))
    (msteams--run-message-action
     'react message (list "--reaction" reaction)
     'unreact (list "--reaction" reaction)
     (format "Added Teams reaction %s" reaction))))

(defun msteams-message-unreact (reaction)
  "Remove REACTION from the Teams message at point."
  (interactive
   (list (completing-read "Remove reaction: "
                          msteams--reaction-choices nil nil)))
  (let ((message (msteams-current-message)))
    (msteams--run-message-action
     'unreact message (list "--reaction" reaction)
     'react (list "--reaction" reaction)
     (format "Removed Teams reaction %s" reaction))))

(defun msteams-message-edit ()
  "Edit the signed-in user's Teams message at point."
  (interactive)
  (let* ((message (msteams-current-message))
         (old (msteams--message-body message)))
    (unless (msteams--message-own-p message)
      (user-error "Teams only permits editing your own message"))
    (let ((new (read-string "Edit Teams message: " old)))
      (when (string-empty-p (string-trim new))
        (user-error "Edited message is empty"))
      (msteams--run-message-action
       'edit message (list "--message" new)
       'edit (list "--message" old)
       "Edited Teams message"))))

(defun msteams-message-delete ()
  "Soft-delete the signed-in user's Teams message at point."
  (interactive)
  (let ((message (msteams-current-message)))
    (unless (msteams--message-own-p message)
      (user-error "Teams only permits deleting your own message"))
    (when (yes-or-no-p "Soft-delete this Teams message? ")
      (msteams--run-message-action
       'delete message nil 'restore nil "Deleted Teams message"))))

(defun msteams-message-forward ()
  "Forward the selected or latest readable message into another chat."
  (interactive)
  (let* ((chat (and (derived-mode-p 'msteams-recent-mode)
                    (msteams--chat-at-point)))
         (message (if chat
                      (or (msteams--get chat 'lastMessagePreview)
                          (user-error
                           "The selected chat has no loaded message to forward"))
                    (msteams-current-message)))
         (sender (msteams--message-sender message))
         (created (msteams--format-date
                   (msteams--get message 'createdDateTime) t))
         (url (msteams--get message 'webUrl))
         (initial
          (concat (format "Forwarded from %s (%s):\n\n%s"
                          sender created
                          (msteams--message-body message))
                  (if (stringp url) (format "\n\nSource: %s" url) ""))))
    (msteams--select-chat
     (lambda (chat) (msteams--open-compose chat nil initial)))))

(defun msteams--non-reference-attachments (message)
  "Return downloadable non-quote attachments from MESSAGE."
  (append
   (seq-filter
    (lambda (attachment)
      (not (msteams--reference-attachment-p attachment)))
    (msteams--get message 'attachments))
   (msteams--inline-images message)))

(defun msteams--choose-attachment (message)
  "Prompt for one attachment in MESSAGE and return it."
  (let* ((attachments (msteams--non-reference-attachments message))
         (pairs
          (mapcar
           (lambda (attachment)
             (cons (or (msteams--get attachment 'name)
                       (msteams--get attachment 'contentType)
                       "attachment")
                   attachment))
           attachments)))
    (unless pairs (user-error "This Teams message has no downloadable attachment"))
    (cdr (assoc (completing-read "Attachment: " (mapcar #'car pairs) nil t)
                pairs))))

(defun msteams-attachment-download (&optional preview)
  "Download one attachment from the current message.

With prefix PREVIEW, visit the downloaded file, including images, in Emacs."
  (interactive "P")
  (let* ((message (msteams-current-message))
         (attachment (msteams--choose-attachment message))
         (url (or (msteams--get attachment 'contentUrl)
                  (msteams--get attachment 'webUrl)))
         (name (or (msteams--get attachment 'name) "teams-attachment")))
    (unless (stringp url) (user-error "Attachment has no content URL"))
    (make-directory msteams-download-directory t)
    (let ((destination
           (read-file-name "Save attachment as: "
                           msteams-download-directory
                           (expand-file-name name
                                             msteams-download-directory))))
      (when (and (file-exists-p destination)
                 (not (yes-or-no-p
                       (format "Overwrite %s? "
                               (abbreviate-file-name destination)))))
        (user-error "Attachment download cancelled"))
      (msteams--run-json
       (list "teams" "attachment" "download"
             "--url" url "--destination" destination)
       (lambda (payload)
         (let ((path (or (msteams--get payload 'path) destination)))
           (if preview
               (find-file-other-window path)
             (message "Downloaded Teams attachment to %s"
                      (abbreviate-file-name path)))))))))

(defun msteams-attachment-preview ()
  "Download and visit an attachment, displaying images in `image-mode'."
  (interactive)
  (msteams-attachment-download t))

(defun msteams--current-web-url ()
  "Return the most specific Teams web URL available at point."
  (let ((message (ignore-errors (msteams-current-message)))
        (root
         (cond
          ((derived-mode-p 'msteams-channel-thread-mode)
           msteams-channel--root)
          ((derived-mode-p 'msteams-channel-index-mode)
           (ignore-errors (msteams-channel-root-at-point))))))
    (or (msteams--get message 'webUrl)
        (msteams--get root 'webUrl)
        (and (or (derived-mode-p 'msteams-channel-thread-mode)
                 (derived-mode-p 'msteams-channel-index-mode))
             (msteams--get msteams-channel--channel 'webUrl))
        (msteams--get (msteams--chat-at-point) 'webUrl))))

(defun msteams-open-current-in-browser ()
  "Open the current Teams item in the web browser."
  (interactive)
  (let ((url (msteams--current-web-url)))
    (unless (stringp url) (user-error "No Teams web URL is available here"))
    (msteams--open-url-in-browser url)))

(defun msteams-open-current-in-app ()
  "Open the current Teams item directly in the desktop application."
  (interactive)
  (let ((url (msteams--current-web-url)))
    (unless (stringp url) (user-error "No Teams URL is available here"))
    (msteams--open-url-in-app url)))

(defun msteams--capture-context-chat ()
  "Return a chat-like source object for current chat or channel context."
  (if (derived-mode-p 'msteams-chat-mode)
      msteams--chat
    `((id . ,(format "%s/%s"
                    (msteams--get msteams-channel--team 'id)
                    (msteams--get msteams-channel--channel 'id)))
      (chatType . "channel")
      (topic . ,(format "%s / %s"
                        (msteams--team-label
                         msteams-channel--team)
                        (msteams--channel-label
                         msteams-channel--channel)))
      (teamId . ,(msteams--get msteams-channel--team 'id))
      (teamName . ,(msteams--team-label
                    msteams-channel--team))
      (channelId . ,(msteams--get msteams-channel--channel 'id))
      (channelName . ,(msteams--channel-label
                       msteams-channel--channel))
      (threadId . ,(msteams--get msteams-channel--root 'id))
      (webUrl . ,(msteams--get msteams-channel--channel 'webUrl)))))

(defun msteams-capture-current-message ()
  "Capture the current chat or channel message into the configured Org inbox."
  (interactive)
  (let* ((message (msteams-current-message))
         (chat (msteams--capture-context-chat))
         (file (msteams--capture-file))
         (marker (msteams--capture-entry chat message file)))
    (pop-to-buffer (marker-buffer marker))
    (goto-char marker)
    (message "Captured Teams message in %s" (abbreviate-file-name file))))

(defun msteams--user-choice (user)
  "Return a completion label for directory USER."
  (format "%s <%s>%s"
          (or (msteams--get user 'displayName) "Unknown")
          (or (msteams--get user 'mail)
              (msteams--get user 'userPrincipalName) "unknown")
          (if-let ((title (msteams--get user 'jobTitle)))
              (format " - %s" title)
            "")))

(defun msteams--search-user (query callback)
  "Search directory for QUERY and pass selected user to CALLBACK."
  (msteams--require-online)
  (msteams--run-json
   (list "teams" "user" "search" "--query" query)
   (lambda (payload)
     (let* ((users (msteams--payload-list payload))
            (pairs (mapcar (lambda (user)
                             (cons (msteams--user-choice user) user))
                           users)))
       (unless pairs (user-error "No Teams users match %s" query))
       (funcall callback
                (cdr (assoc (completing-read "Teams user: "
                                             (mapcar #'car pairs) nil t)
                            pairs)))))))

(defun msteams-user (query)
  "Search for QUERY and display the selected user's profile and presence."
  (interactive (list (read-string "Teams user search: ")))
  (msteams--search-user
   query
   (lambda (user)
     (let ((user-id (msteams--get user 'id)))
       (msteams--run-json
        (list "teams" "user" "presence" "--userId" user-id)
        (lambda (presence)
          (let ((buffer (get-buffer-create "*Teams Person*")))
            (with-current-buffer buffer
              (let ((inhibit-read-only t))
                (erase-buffer)
                (insert (propertize
                         (or (msteams--get user 'displayName) "Teams user")
                         'face '(:height 1.3 :weight bold)))
                (insert "\n\n")
                (dolist (field '((mail . "Email")
                                 (userPrincipalName . "UPN")
                                 (jobTitle . "Title")
                                 (department . "Department")
                                 (officeLocation . "Office")))
                  (when-let ((value (msteams--get user (car field))))
                    (insert (format "%-12s %s\n" (cdr field) value))))
                (insert (format "%-12s %s / %s\n"
                                "Presence"
                                (or (msteams--get presence 'availability)
                                    "unknown")
                                (or (msteams--get presence 'activity)
                                    "unknown")))
                (special-mode)))
            (pop-to-buffer buffer))))))))

(defun msteams-create-chat (participants topic)
  "Create a new chat with comma-separated PARTICIPANTS and optional TOPIC."
  (interactive
   (list (read-string "Participant emails or user IDs (comma-separated): ")
         (read-string "Group topic (optional): ")))
  (msteams--require-online)
  (let ((args (list "teams" "chat" "create"
                    "--userEmails" participants)))
    (unless (string-empty-p (string-trim topic))
      (setq args (append args (list "--topic" topic))))
    (msteams--run-json
     args
     (lambda (chat)
       (message "Created Teams chat")
       (msteams-open-chat chat)))))

(defun msteams-set-topic (topic)
  "Set TOPIC for the current group chat."
  (interactive
   (list (read-string "Group chat topic: "
                      (or (msteams--get
                           (msteams--chat-at-point) 'topic) ""))))
  (msteams--require-online)
  (let ((chat (or (msteams--chat-at-point)
                  (user-error "No Teams chat here"))))
    (unless (equal (msteams--get chat 'chatType) "group")
      (user-error "Only group chats can have a topic"))
    (msteams--run-json
     (list "teams" "chat" "topic" "set"
           "--chatId" (msteams--chat-id chat) "--topic" topic)
     (lambda (_payload)
       (setf (alist-get 'topic chat) topic)
       (msteams--refresh-current-view)
       (message "Updated Teams group topic")))))

(defun msteams-add-member (query)
  "Search QUERY and add the selected user to the current group chat."
  (interactive (list (read-string "Add Teams member search: ")))
  (msteams--require-online)
  (let ((chat (or (msteams--chat-at-point)
                  (user-error "No Teams chat here"))))
    (unless (equal (msteams--get chat 'chatType) "group")
      (user-error "Members can only be added to group chats"))
    (msteams--search-user
     query
     (lambda (user)
       (msteams--run-json
        (list "teams" "chat" "member" "add"
              "--chatId" (msteams--chat-id chat)
              "--userId" (msteams--get user 'id))
        (lambda (_payload)
          (remhash (msteams--chat-id chat)
                   msteams--member-cache)
          (message "Added %s to Teams chat"
                   (msteams--get user 'displayName))))))))

(defun msteams-remove-member ()
  "Select and remove a member from the current group chat."
  (interactive)
  (msteams--require-online)
  (let* ((chat (or (msteams--chat-at-point)
                   (user-error "No Teams chat here")))
         (chat-id (msteams--chat-id chat)))
    (unless (equal (msteams--get chat 'chatType) "group")
      (user-error "Members can only be removed from group chats"))
    (msteams--run-json
     (list "teams" "chat" "member" "list" "--chatId" chat-id)
     (lambda (payload)
       (let* ((members
               (seq-remove
                (lambda (member)
                  (equal (msteams--get member 'userId)
                         msteams--connected-user-id))
                (msteams--payload-list payload)))
              (pairs
               (mapcar
                (lambda (member)
                  (cons (or (msteams--get member 'displayName)
                            (msteams--get member 'email)
                            (msteams--get member 'id))
                        member))
                members))
              (choice (completing-read "Remove member: "
                                       (mapcar #'car pairs) nil t))
              (member (cdr (assoc choice pairs))))
         (when (yes-or-no-p (format "Remove %s from this chat? " choice))
           (msteams--run-json
            (list "teams" "chat" "member" "remove"
                  "--chatId" chat-id
                  "--membershipId" (msteams--get member 'id))
            (lambda (_result)
              (remhash chat-id msteams--member-cache)
              (message "Removed %s from Teams chat" choice)))))))))

(defun msteams--tabulated-neighbor-id (id delta)
  "Move from tabulated ID by DELTA rows and return the destination ID."
  (let ((origin (point)) target-id)
    (goto-char (point-min))
    (while (and (not (equal id (tabulated-list-get-id))) (not (eobp)))
      (forward-line 1))
    (when (and (equal id (tabulated-list-get-id))
               (= 0 (forward-line delta)))
      (beginning-of-line)
      (let ((candidate (tabulated-list-get-id)))
        (unless (equal candidate id) (setq target-id candidate))))
    (unless target-id (goto-char origin))
    target-id))

(defun msteams-thread-relative (delta)
  "Open the inbox chat DELTA displayed rows from the current chat."
  (interactive "p")
  (unless (derived-mode-p 'msteams-chat-mode)
    (user-error "Open a Teams chat thread first"))
  (let* ((chat-id (msteams--chat-id msteams--chat))
         (index-buffer (msteams--recent-buffer))
         (index-window
          (and (buffer-live-p index-buffer)
               (get-buffer-window index-buffer t)))
         (target
          (if (buffer-live-p index-buffer)
              (when-let ((target-id
                          (if (window-live-p index-window)
                              (with-selected-window index-window
                                (msteams--tabulated-neighbor-id
                                 chat-id delta))
                            (with-current-buffer index-buffer
                              (msteams--tabulated-neighbor-id
                               chat-id delta)))))
                (msteams--find-chat target-id))
            (let* ((visible (seq-filter #'msteams--view-chat-p
                                        msteams--chats))
                   (index (cl-position chat-id visible
                                       :key #'msteams--chat-id
                                       :test #'equal))
                   (target-index (and index (+ index delta))))
              (when (and target-index (>= target-index 0)
                         (< target-index (length visible)))
                (nth target-index visible))))))
    (unless target
      (user-error "No Teams thread in that direction"))
    (msteams-open-chat target)))

(defun msteams-thread-next ()
  "Open the next visible Teams inbox thread."
  (interactive)
  (msteams-thread-relative 1))

(defun msteams-thread-previous ()
  "Open the previous visible Teams inbox thread."
  (interactive)
  (msteams-thread-relative -1))

(defvar-local msteams-compose--discarded nil)

(defun msteams-compose--target-key ()
  "Return stable non-secret key for the current compose target."
  (msteams--compose-target-key
   msteams-compose--target msteams-compose--reply-to))

(defun msteams-compose--path ()
  "Return private draft path for the current compose target."
  (expand-file-name
   (format "%s.json" (md5 (msteams-compose--target-key)))
   msteams-draft-directory))

(defun msteams-compose--update-header ()
  "Refresh compose metadata in the header line."
  (let* ((reply msteams-compose--reply-to)
         (reply-label
          (and reply
               (format "Reply to %s: %s - "
                       (msteams--message-sender reply)
                       (truncate-string-to-width
                        (replace-regexp-in-string
                         "[\n\r\t ]+" " "
                         (msteams--message-body reply))
                        70 nil nil "...")))))
    (setq header-line-format
          (format "%sTo: %s [%s] - %d attachment%s, %d mention%s - C-c C-c send"
                (or reply-label "")
                (msteams--target-label
                 msteams-compose--target)
                msteams-compose--content-type
                (length msteams-compose--attachments)
                (if (= (length msteams-compose--attachments) 1)
                    "" "s")
                (length msteams-compose--mentions)
                (if (= (length msteams-compose--mentions) 1)
                    "" "s")))))

(defun msteams-compose--draft-target-record ()
  "Return minimal reopen metadata for the current compose target."
  (let ((target msteams-compose--target))
    (cond
     ((msteams--chat-id target)
      `((kind . "chat")
        (chatId . ,(msteams--chat-id target))
        (label . ,(msteams--target-label target))))
     ((and (keywordp (car-safe target)) (plist-get target :team-id))
      `((kind . "channel")
        (teamId . ,(plist-get target :team-id))
        (channelId . ,(plist-get target :channel-id))
        (label . ,(msteams--target-label target))))
     ((and (keywordp (car-safe target)) (plist-get target :user-emails))
      `((kind . "recipients")
        (userEmails . ,(plist-get target :user-emails))
        (label . ,(msteams--target-label target)))))))

(defun msteams-compose--draft-reply-record ()
  "Return minimal reopen metadata for the current quoted reply."
  (when-let ((reply msteams-compose--reply-to))
    `((id . ,(msteams--get reply 'id))
      (from . ((user . ((id . ,(msteams--dig reply 'from 'user 'id))
                        (displayName
                         . ,(msteams--message-sender reply))))))
      (body . ((contentType . "text")
               (content . ,(msteams--message-body reply)))))))

(defun msteams-compose--save-draft ()
  "Persist the current compose buffer as a private recoverable JSON draft."
  (when (timerp msteams-compose--draft-timer)
    (cancel-timer msteams-compose--draft-timer))
  (setq msteams-compose--draft-timer nil)
  (when (and (derived-mode-p 'msteams-compose-mode)
             msteams-compose--target
             (not msteams-compose--discarded))
    (let ((body (buffer-substring-no-properties (point-min) (point-max)))
          (file (or msteams-compose--draft-file
                    (msteams-compose--path)))
          (content-type msteams-compose--content-type)
          (attachments msteams-compose--attachments)
          (mentions msteams-compose--mentions)
          ;; Capture buffer-local metadata before `with-temp-file' changes the
          ;; current buffer.
          (target-record (msteams-compose--draft-target-record))
          (reply-record (msteams-compose--draft-reply-record))
          (updated-at (format-time-string "%Y-%m-%dT%H:%M:%S%z")))
      (if (and (string-empty-p body)
               (null msteams-compose--attachments))
          (when (file-exists-p file) (delete-file file))
        (make-directory (file-name-directory file) t)
        (let ((temporary
               (make-temp-file
                (expand-file-name ".teams-draft-" (file-name-directory file)))))
          (unwind-protect
              (progn
                (with-temp-file temporary
                  (insert
                   (json-serialize
                    `((body . ,body)
                      (contentType . ,content-type)
                      (attachments . ,(vconcat attachments))
                      (mentions . ,(vconcat mentions))
                      (target . ,target-record)
                      (replyTo . ,reply-record)
                      (updatedAt . ,updated-at))))
                  (insert "\n"))
                (set-file-modes temporary #o600)
                (rename-file temporary file t))
            (when (file-exists-p temporary) (delete-file temporary))))))))

(defun msteams-compose--schedule-draft (&rest _ignored)
  "Debounce automatic draft persistence after a compose edit."
  (when (timerp msteams-compose--draft-timer)
    (cancel-timer msteams-compose--draft-timer))
  (let ((buffer (current-buffer)))
    (setq msteams-compose--draft-timer
          (run-with-idle-timer
           1 nil
           (lambda ()
             (when (buffer-live-p buffer)
               (with-current-buffer buffer
                 (msteams-compose--save-draft))))))))

(defun msteams-compose--initialize-draft ()
  "Attach automatic draft recovery to the current compose buffer."
  (setq msteams-compose--discarded nil
        msteams-compose--draft-file
        (msteams-compose--path))
  (when (and (= (buffer-size) 0)
             (file-readable-p msteams-compose--draft-file))
    (let ((draft-file msteams-compose--draft-file))
      (condition-case error-data
          (let* ((payload
                (json-parse-string
                 (with-temp-buffer
                   (insert-file-contents draft-file)
                   (buffer-string))
                 :object-type 'alist :array-type 'list
                 :null-object nil :false-object nil))
               (body (msteams--get payload 'body)))
          (setq msteams-compose--content-type
                (or (msteams--get payload 'contentType) "text")
                msteams-compose--attachments
                (msteams--get payload 'attachments)
                msteams-compose--mentions
                (msteams--get payload 'mentions))
          (when (stringp body)
            (let ((inhibit-modification-hooks t)) (insert body)))
            (message "Restored Teams draft"))
        (error
         (message "Ignoring invalid Teams draft: %s"
                  (error-message-string error-data))))))
  (msteams-compose--update-header))

(defun msteams-compose--delete-draft ()
  "Delete and stop recreating the current compose draft."
  (setq msteams-compose--discarded t)
  (when (timerp msteams-compose--draft-timer)
    (cancel-timer msteams-compose--draft-timer))
  (setq msteams-compose--draft-timer nil)
  (when (and msteams-compose--draft-file
             (file-exists-p msteams-compose--draft-file))
    (delete-file msteams-compose--draft-file))
  (msteams-compose--delete-clipboard-attachments))

(defun msteams-compose--clipboard-directory ()
  "Return the private directory used for pasted compose images."
  (expand-file-name "clipboard-images" msteams-draft-directory))

(defun msteams-compose--delete-clipboard-attachments ()
  "Delete pasted image files owned by the current compose draft."
  (let ((directory (msteams-compose--clipboard-directory)))
    (dolist (path msteams-compose--attachments)
      (when (and (stringp path) (file-exists-p path)
                 (file-in-directory-p path directory))
        (delete-file path)))))

(defun msteams-compose-add-attachment (path)
  "Add local file PATH to the current outgoing Teams message."
  (interactive "fAttach file: ")
  (unless (derived-mode-p 'msteams-compose-mode)
    (user-error "Open a Teams compose buffer first"))
  (setq path (expand-file-name path))
  (unless (file-regular-p path) (user-error "Attachment is not a file"))
  (cl-pushnew path msteams-compose--attachments :test #'equal)
  (msteams-compose--update-header)
  (msteams-compose--schedule-draft)
  (message "Attached %s" (file-name-nondirectory path)))

(defun msteams-compose-remove-attachment ()
  "Remove one local file from the current outgoing Teams message."
  (interactive)
  (unless msteams-compose--attachments
    (user-error "No files are attached"))
  (let ((path (completing-read "Remove attachment: "
                               msteams-compose--attachments nil t)))
    (setq msteams-compose--attachments
          (delete path msteams-compose--attachments))
    (when (and (file-exists-p path)
               (file-in-directory-p
                path (msteams-compose--clipboard-directory)))
      (delete-file path))
    (msteams-compose--update-header)
    (msteams-compose--schedule-draft)))

(defun msteams-compose-paste-image ()
  "Save the macOS clipboard image and attach it to this Teams draft."
  (interactive)
  (unless (derived-mode-p 'msteams-compose-mode)
    (user-error "Open a Teams compose buffer first"))
  (let ((program (executable-find "pngpaste")))
    (unless program
      (user-error "Install pngpaste to attach an image from the clipboard"))
    (let* ((directory (msteams-compose--clipboard-directory))
           path)
      (make-directory directory t)
      (set-file-modes directory #o700)
      (setq path (make-temp-file
                  (expand-file-name "teams-clipboard-" directory) nil ".png"))
      (if (zerop (call-process program nil nil nil path))
          (progn
            (set-file-modes path #o600)
            (cl-pushnew path msteams-compose--attachments :test #'equal)
            (msteams-compose--update-header)
            (msteams-compose--schedule-draft)
            (message "Attached clipboard image"))
        (when (file-exists-p path) (delete-file path))
        (user-error "The clipboard does not contain a PNG-compatible image")))))

(defun msteams-compose--read-draft (file)
  "Read one Teams draft FILE, returning nil when it is invalid."
  (condition-case nil
      (json-parse-string
       (with-temp-buffer
         (insert-file-contents file)
         (buffer-string))
       :object-type 'alist :array-type 'list
       :null-object nil :false-object nil)
    (error nil)))

(defun msteams-compose--record-target (record)
  "Reconstruct a compose target from draft RECORD."
  (pcase (msteams--get record 'kind)
    ("chat"
     (let ((chat-id (msteams--get record 'chatId))
           (label (msteams--get record 'label)))
       (or (msteams--find-chat chat-id)
           `((id . ,chat-id) (topic . ,label)))))
    ("channel"
     (list :team-id (msteams--get record 'teamId)
           :channel-id (msteams--get record 'channelId)
           :label (msteams--get record 'label)))
    ("recipients"
     (list :user-emails (msteams--get record 'userEmails)
           :label (msteams--get record 'label)))))

(defun msteams-compose-drafts ()
  "Choose and reopen one recoverable Teams compose draft."
  (interactive)
  (let (choices)
    (when (file-directory-p msteams-draft-directory)
      (dolist (file (directory-files msteams-draft-directory t
                                     "\\.json\\'"))
        (when-let* ((payload (msteams-compose--read-draft file))
                    (target-record (msteams--get payload 'target))
                    (target (msteams-compose--record-target
                             target-record)))
          (push (cons (format "%s - %s"
                              (or (msteams--get target-record 'label)
                                  "Teams draft")
                              (or (msteams--get payload 'updatedAt)
                                  (format-time-string
                                   "%Y-%m-%d %H:%M"
                                   (file-attribute-modification-time
                                    (file-attributes file)))))
                      (list target (msteams--get payload 'replyTo)))
                choices))))
    (unless choices (user-error "No reopenable Teams drafts"))
    (let* ((choice (completing-read "Teams draft: " (mapcar #'car choices)
                                    nil t))
           (metadata (cdr (assoc choice choices))))
      (msteams--open-compose (car metadata) (cadr metadata)))))

(defun msteams-compose-mention (query)
  "Search QUERY, insert a structured @mention, and retain its user ID."
  (interactive (list (read-string "Mention Teams user: ")))
  (unless (derived-mode-p 'msteams-compose-mode)
    (user-error "Open a Teams compose buffer first"))
  (let ((buffer (current-buffer)))
    (msteams--search-user
     query
     (lambda (user)
       (when (buffer-live-p buffer)
         (with-current-buffer buffer
           (let ((name (msteams--get user 'displayName))
                 (user-id (msteams--get user 'id)))
             (insert "@" name)
             (cl-pushnew (format "%s|%s" user-id name)
                         msteams-compose--mentions :test #'equal)
             (msteams-compose--update-header)
             (msteams-compose--schedule-draft))))))))

(defun msteams-compose-toggle-rich ()
  "Toggle compose between plain text and direct Teams HTML mode."
  (interactive)
  (setq msteams-compose--content-type
        (if (equal msteams-compose--content-type "text")
            "html" "text"))
  (msteams-compose--update-header)
  (msteams-compose--schedule-draft)
  (message "Teams compose format: %s"
           msteams-compose--content-type))

(defun msteams-compose--wrap (open close)
  "Wrap active region in OPEN and CLOSE HTML tags."
  (unless (use-region-p) (user-error "Select text to format"))
  (unless (equal msteams-compose--content-type "html")
    (setq msteams-compose--content-type "html"))
  (let ((end (copy-marker (region-end))))
    (goto-char (region-beginning))
    (insert open)
    (goto-char end)
    (insert close)
    (set-marker end nil))
  (deactivate-mark)
  (msteams-compose--update-header))

(defun msteams-compose-bold ()
  "Wrap active region in Teams HTML strong markup."
  (interactive)
  (msteams-compose--wrap "<strong>" "</strong>"))

(defun msteams-compose-italic ()
  "Wrap active region in Teams HTML emphasis markup."
  (interactive)
  (msteams-compose--wrap "<em>" "</em>"))

(defun msteams-compose-code ()
  "Wrap active region in Teams HTML code markup."
  (interactive)
  (msteams-compose--wrap "<code>" "</code>"))

(defun msteams-compose-link (url)
  "Wrap active region in a Teams HTML link to URL."
  (interactive "sLink URL: ")
  (msteams-compose--wrap
   (format "<a href=\"%s\">"
           (replace-regexp-in-string "\"" "&quot;" url t t))
   "</a>"))

(defun msteams-compose-new-frame ()
  "Show the current full Emacs compose buffer in a dedicated frame."
  (interactive)
  (let ((buffer (current-buffer))
        (frame (make-frame '((name . "Teams Compose")))))
    (set-window-buffer (frame-selected-window frame) buffer)
    (select-frame-set-input-focus frame)))

(add-hook 'msteams-compose-mode-hook
          (lambda ()
            (add-hook 'after-change-functions
                      #'msteams-compose--schedule-draft nil t)
            (add-hook 'kill-buffer-hook
                      #'msteams-compose--save-draft nil t)))

(define-key msteams-compose-mode-map
            (kbd "C-c C-a") #'msteams-compose-add-attachment)
(define-key msteams-compose-mode-map
            (kbd "C-c C-r") #'msteams-compose-remove-attachment)
(define-key msteams-compose-mode-map
            (kbd "C-c C-p") #'msteams-compose-paste-image)
(define-key msteams-compose-mode-map
            (kbd "C-c C-m") #'msteams-compose-mention)
(define-key msteams-compose-mode-map
            (kbd "C-c C-h") #'msteams-compose-toggle-rich)
(define-key msteams-compose-mode-map
            (kbd "C-c C-b") #'msteams-compose-bold)
(define-key msteams-compose-mode-map
            (kbd "C-c C-i") #'msteams-compose-italic)
(define-key msteams-compose-mode-map
            (kbd "C-c C-`") #'msteams-compose-code)
(define-key msteams-compose-mode-map
            (kbd "C-c C-l") #'msteams-compose-link)
(define-key msteams-compose-mode-map
            (kbd "C-c C-f") #'msteams-compose-new-frame)

(defvar msteams-mark-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "i") #'msteams-mark-read-later)
    (define-key map (kbd "r") #'msteams-mark-read-later)
    (define-key map (kbd "u") #'msteams-mark-unread-later)
    (define-key map (kbd "*") #'msteams-mark-favorite-later)
    (define-key map (kbd "SPC") #'msteams-unmark)
    map)
  "Prefix map for deferred mu4e-style Teams actions.")

(defvar msteams-chat-mark-map
  (let ((map (make-sparse-keymap)))
    (dolist (key '("i" "r" "u" "*" "SPC"))
      (define-key map (kbd key)
                  #'msteams-chat-run-headers-command))
    map)
  "Reader prefix map that delegates deferred marks to Teams headers.")

;; `defvar' retains existing maps during a live layer reload.
(define-key msteams-mark-map (kbd "i")
            #'msteams-mark-read-later)
(define-key msteams-mark-map (kbd "r")
            #'msteams-mark-read-later)
(dolist (key '("i" "r" "u" "*" "SPC"))
  (define-key msteams-chat-mark-map (kbd key)
              #'msteams-chat-run-headers-command))

(defun msteams-chat-toggle-unread-filter ()
  "Toggle the linked headers' unread filter from the Teams reader."
  (interactive)
  (msteams-chat-run-headers-command
   #'msteams-toggle-unread-filter))

(defun msteams-chat-refresh-headers ()
  "Refresh the linked chat headers from the Teams reader."
  (interactive)
  (msteams-chat-run-headers-command
   #'msteams-recent-refresh))

(defun msteams-action-compose ()
  "Compose in the current chat or channel context."
  (interactive)
  (call-interactively
   (if (or (derived-mode-p 'msteams-channel-index-mode)
           (derived-mode-p 'msteams-channel-thread-mode))
       #'msteams-channel-compose
     #'msteams-send)))

(defun msteams-action-reply ()
  "Reply in the current chat or channel context."
  (interactive)
  (call-interactively
   (if (or (derived-mode-p 'msteams-channel-index-mode)
           (derived-mode-p 'msteams-channel-thread-mode))
       #'msteams-channel-reply
     #'msteams-reply)))

(defvar msteams-action-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "a") #'msteams-capture-current-summary)
    (define-key map (kbd "A") #'msteams-capture-current-thread)
    (define-key map (kbd "j") #'msteams-jump-to-capture)
    (define-key map (kbd "t") #'msteams-meeting-transcript)
    (define-key map (kbd "c") #'msteams-action-compose)
    (define-key map (kbd "R") #'msteams-action-reply)
    (define-key map (kbd "f") #'msteams-message-forward)
    (define-key map (kbd "i") #'msteams-mark-read)
    (define-key map (kbd "u") #'msteams-mark-unread)
    (define-key map (kbd "*") #'msteams-toggle-favorite)
    (define-key map (kbd "m") #'msteams-toggle-muted)
    (define-key map (kbd "s") #'msteams-snooze)
    (define-key map (kbd "k") #'msteams-clear-triage)
    (define-key map (kbd "e") #'msteams-export-current-thread)
    (define-key map (kbd "y") #'msteams-copy-current-thread-markdown)
    (define-key map (kbd "g") #'msteams-analyze-current-thread)
    (define-key map (kbd "o") #'msteams-open-current-in-browser)
    (define-key map (kbd "O") #'msteams-open-current-in-app)
    (define-key map (kbd "?") #'msteams-headers-action)
    (define-key map (kbd "x") #'msteams-headers-action)
    map)
  "Mu4e-style prefix map for actions on the current Teams conversation.")

;; Keep source reloads useful when this prefix map already exists.
(define-key msteams-action-map (kbd "g")
            #'msteams-analyze-current-thread)
(define-key msteams-action-map (kbd "r") nil)
(define-key msteams-action-map (kbd "h") nil)
(define-key msteams-action-map (kbd "R")
            #'msteams-action-reply)

(defun msteams-headers-action ()
  "Run a row action from the Teams headers buffer.

The menu combines mu4e's headers-action convention with the core row operations
shared by the terminal Teams client."
  (interactive)
  (let* ((actions
          '(("Compose in conversation" . msteams-action-compose)
            ("Reply to latest message" . msteams-action-reply)
            ("Forward latest message" . msteams-message-forward)
            ("Mark read now" . msteams-mark-read)
            ("Mark unread now" . msteams-mark-unread)
            ("Toggle favorite" . msteams-toggle-favorite)
            ("Toggle local inbox mute" . msteams-toggle-muted)
            ("Toggle handled until new" . msteams-toggle-handled)
            ("Snooze conversation" . msteams-snooze)
            ("Clear handled/snoozed state" . msteams-clear-triage)
            ("Toggle chat selection" . msteams-toggle-selection)
            ("Select or clear visible chats" .
             msteams-toggle-visible-selections)
            ("Bulk action selected chats" . msteams-bulk-action)
            ("Toggle unread-only filter" .
             msteams-toggle-unread-filter)
            ("Export complete Markdown" . msteams-export-current-thread)
            ("Copy complete Markdown" .
             msteams-copy-current-thread-markdown)
            ("Analyze complete thread with agent" .
             msteams-analyze-current-thread)
            ("Capture compact action to Org" .
             msteams-capture-current-summary)
            ("Jump to existing Org capture" .
             msteams-jump-to-capture)
            ("Open latest meeting transcript" .
             msteams-meeting-transcript)
            ("Capture complete thread to Org" .
             msteams-capture-current-thread)
            ("Open in Teams web" . msteams-open-current-in-browser)
            ("Open in Teams desktop app" . msteams-open-current-in-app)
            ("Choose bookmark" . msteams-bookmark-jump)
            ("Filter inbox" . msteams-filter)
            ("Search cached messages" . msteams-search)
            ("Search Microsoft Teams server" .
             msteams-server-search)
            ("Reopen saved compose draft" . msteams-compose-drafts)
            ("Close inactive transcript buffers" .
             msteams-close-inactive-transcripts)
            ("All Teams commands" . msteams-dispatch)))
         (choice
          (completing-read "Teams headers action: "
                           (mapcar #'car actions) nil t)))
    (call-interactively (cdr (assoc choice actions)))))

(defun msteams-install-headers-bindings ()
  "Install the complete Teams headers map, including in reloaded sessions."
  (dolist
      (binding
       '(("RET" . msteams-recent-open)
         ("l" . msteams-recent-open)
         ("y" . msteams-select-preview)
         ("j" . msteams-recent-next)
         ("n" . msteams-recent-next)
         ("k" . msteams-recent-previous)
         ("p" . msteams-recent-previous)
         ("]" . msteams-recent-next-unread)
         ("[" . msteams-recent-previous-unread)
         ("g" . msteams-recent-refresh)
         ("c" . msteams-send)
         ("i" . msteams-mark-read-later)
         ("C" . msteams-send)
         ("r" . msteams-mark-read-later)
         ("R" . msteams-reply)
         ("f" . msteams-message-forward)
         ("F" . msteams-message-forward)
         ("o" . msteams-open-in-browser)
         ("O" . msteams-open-in-app)
         ("*" . msteams-toggle-favorite)
         ("M-u" . msteams-mark-unread)
         ("I" . msteams-mark-read-later)
         ("M" . msteams-toggle-selection)
         ("T" . msteams-toggle-visible-selections)
         ("X" . msteams-bulk-action)
         ("E" . msteams-export-thread)
         ("Y" . msteams-copy-thread-markdown)
         ("J" . msteams-preview-scroll-down)
         ("K" . msteams-preview-scroll-up)
         ("C-+" . msteams-index-grow)
         ("C-=" . msteams-index-grow)
         ("C--" . msteams-index-shrink)
         ("q" . msteams-quit)
         ("!" . msteams-mark-read-later)
         ("?" . msteams-mark-unread-later)
         ("u" . msteams-unmark)
         ("x" . msteams-execute-marks)
         ("U" . msteams-unmark-all)
         ("z" . msteams-undo-action)
         ("M-U" . msteams-undo-action)
         ("/" . msteams-search)
         ("s" . msteams-filter)
         ("b" . msteams-bookmark-jump)
         ("B" . msteams-bookmark-edit)
         ("v" . msteams-select-view)
         ("V" . msteams-save-view)
         ("S" . msteams-sort)
         ("H" . msteams-dispatch)))
    (define-key msteams-recent-mode-map
                (kbd (car binding)) (cdr binding)))
  (define-key msteams-recent-mode-map
              (kbd "m") msteams-mark-map)
  (define-key msteams-recent-mode-map
              (kbd "a") msteams-action-map)
  (define-key msteams-recent-mode-map (kbd "w") nil))

(msteams-install-headers-bindings)

(define-key msteams-search-mode-map
            (kbd "q") #'msteams-quit)

(defconst msteams--chat-header-mirror-keys
  '("g" "n" "p" "[" "]" "i" "I" "!" "?" "r" "M-u" "*" "f"
    "M" "T" "X" "u" "U" "x" "z" "M-U" "/" "s" "b" "B"
    "v" "V" "S" "H" "J" "K" "C-+" "C-=" "C--")
  "Headers keys delegated from the singleton Teams chat reader.")

(defun msteams-install-chat-reader-bindings ()
  "Install mu4e-style headers delegation and reader-local Teams commands."
  (dolist (key msteams--chat-header-mirror-keys)
    (define-key msteams-chat-mode-map (kbd key)
                #'msteams-chat-run-headers-command))
  (define-key msteams-chat-mode-map
              (kbd "m") msteams-chat-mark-map)
  (define-key msteams-chat-mode-map
              (kbd "a") msteams-action-map)
  (dolist
      (binding
       '(("j" . msteams-thread-next)
         ("k" . msteams-thread-previous)
         ("N" . msteams-thread-next)
         ("P" . msteams-thread-previous)
         ("M-j" . msteams-chat-next-message)
         ("M-k" . msteams-chat-previous-message)
         ("q" . msteams-chat-view-quit)
         ("R" . msteams-reply)
         ("F" . msteams-message-forward)
         ("c" . msteams-send)
         ("C" . msteams-send)
         ("+" . msteams-message-react)
         ("-" . msteams-message-unreact)
         ("e" . msteams-message-edit)
         ("d" . msteams-message-delete)
         ("A" . msteams-attachment-preview)
         ("M-a" . msteams-attachment-download)
         ("M-g" . msteams-chat-refresh)
         ("G" . msteams-chat-load-all)
         ("L" . msteams-chat-load-more)
         ("M-S" . msteams-toggle-message-order)
         ("E" . msteams-export-thread)
         ("Y" . msteams-copy-current-thread-markdown)
         ("y" . msteams-chat-back-to-inbox)
         ("M-y" . msteams-copy-message)
         ("M-w" . msteams-capture-message)
         ("o" . msteams-open-in-browser)
         ("O" . msteams-open-in-app)
         ("M-F" . msteams-chat-toggle-unread-filter)
         ("h" . msteams-chat-back-to-inbox)))
    (define-key msteams-chat-mode-map
                (kbd (car binding)) (cdr binding)))
  (define-key msteams-chat-mode-map (kbd "w") nil)
  (define-key msteams-chat-mode-map (kbd "W") nil))

(msteams-install-chat-reader-bindings)

(dolist (binding
         '(("q" . msteams-quit)
           ("E" . msteams-channel-export-thread)
           ("Y" . msteams-copy-current-thread-markdown)
           ("o" . msteams-open-current-in-browser)
           ("O" . msteams-open-current-in-app)))
  (define-key msteams-channel-index-mode-map
              (kbd (car binding)) (cdr binding)))
(define-key msteams-channel-index-mode-map
            (kbd "a") msteams-action-map)
(define-key msteams-channel-index-mode-map (kbd "w") nil)

(dolist (binding
         '(("j" . msteams-channel-thread-next)
           ("k" . msteams-channel-thread-previous)
           ("M-j" . msteams-chat-next-message)
           ("M-k" . msteams-chat-previous-message)
           ("q" . msteams-channel-view-quit)
           ("R" . msteams-channel-reply)
           ("F" . msteams-message-forward)
           ("M-a" . msteams-attachment-download)
           ("c" . msteams-channel-compose)
           ("C" . msteams-channel-compose)
           ("S" . msteams-toggle-message-order)
           ("Y" . msteams-copy-current-thread-markdown)
           ("o" . msteams-open-current-in-browser)
           ("O" . msteams-open-current-in-app)))
  (define-key msteams-channel-thread-mode-map
              (kbd (car binding)) (cdr binding)))
(define-key msteams-channel-thread-mode-map
            (kbd "a") msteams-action-map)
(define-key msteams-channel-thread-mode-map (kbd "w") nil)
(define-key msteams-channel-thread-mode-map (kbd "W") nil)
(define-key msteams-channel-thread-mode-map (kbd "r") nil)

(defun msteams-dispatch ()
  "Open a completion-driven command palette for native Teams workflows."
  (interactive)
  (let* ((commands
          '(("Inbox" . msteams-inbox)
            ("Channels" . msteams-channels)
            ("Search cache" . msteams-search)
            ("Search Microsoft Teams server" .
             msteams-server-search)
            ("Synchronize chats" . msteams-sync)
            ("Synchronize chats and channels" .
             msteams-sync-all)
            ("Compose message" . msteams-send)
            ("Reopen compose draft" . msteams-compose-drafts)
            ("Create chat" . msteams-create-chat)
            ("Find person" . msteams-user)
            ("Choose inbox bookmark" . msteams-bookmark-jump)
            ("Filter inbox" . msteams-filter)
            ("Toggle unread-only inbox filter" .
             msteams-toggle-unread-filter)
            ("Toggle current chat selection" .
             msteams-toggle-selection)
            ("Toggle all visible chat selections" .
             msteams-toggle-visible-selections)
            ("Bulk action selected chats" . msteams-bulk-action)
            ("Select inbox view" . msteams-select-view)
            ("Capture compact action to Org" .
             msteams-capture-current-summary)
            ("Capture complete thread to Org" .
             msteams-capture-current-thread)
            ("Jump to existing Org capture" .
             msteams-jump-to-capture)
            ("Open latest meeting transcript" .
             msteams-meeting-transcript)
            ("Copy complete thread as Markdown" .
             msteams-copy-current-thread-markdown)
            ("Analyze complete thread with agent" .
             msteams-analyze-current-thread)
            ("Undo last action" . msteams-undo-action)
            ("Cache status" . msteams-cache-status)
            ("Close inactive transcript buffers" .
             msteams-close-inactive-transcripts)
            ("Toggle cache-only mode" . msteams-toggle-offline)
            ("OAuth/mock status" . msteams-status)
            ("Enable local mock" . msteams-mock-enable)
            ("Disable local mock" . msteams-mock-disable)))
         (choice (completing-read "Teams command: " (mapcar #'car commands)
                                  nil t)))
    (call-interactively (cdr (assoc choice commands)))))

(defun msteams-sync-all ()
  "Synchronize chats, joined teams, channels, and channel messages."
  (interactive)
  (msteams-sync t))

;; Prefer Elpa transient after startup; loading it here would pin Emacs 30's
;; built-in 0.7.x stub before package.el is ready and break chatgpt-shell.
(defun msteams--setup-teams-transient ()
  "Define the Teams transient menu when a modern transient is available."
  (when (and (featurep 'transient) (not (fboundp 'transient--set-layout)))
    (unload-feature 'transient t))
  (when (and (require 'transient nil t)
             (fboundp 'transient--set-layout)
             (not (fboundp 'msteams-transient)))
    (eval
     '(transient-define-prefix msteams-transient ()
        "Native Microsoft Teams commands."
        [["Read"
          ("i" "inbox" msteams-inbox)
          ("c" "channels" msteams-channels)
         ("/" "search" msteams-search)
          ("?" "server search" msteams-server-search)
          ("b" "bookmark" msteams-bookmark-jump)
          ("f" "filter" msteams-filter)
          ("F" "unread only" msteams-toggle-unread-filter)
          ("v" "view" msteams-select-view)]
         ["Write"
          ("s" "send" msteams-send)
          ("d" "drafts" msteams-compose-drafts)
          ("n" "new chat" msteams-create-chat)
          ("p" "person" msteams-user)
          ("a" "capture action" msteams-capture-current-summary)
          ("A" "capture full thread" msteams-capture-current-thread)
          ("y" "copy Markdown" msteams-copy-current-thread-markdown)
          ("l" "analyze thread" msteams-analyze-current-thread)]
         ["State"
          ("g" "sync" msteams-sync)
          ("G" "sync all" msteams-sync-all)
          ("o" "offline" msteams-toggle-offline)
          ("S" "status" msteams-status)]
         ["Bulk"
          ("t" "toggle chat" msteams-toggle-selection)
          ("T" "toggle visible" msteams-toggle-visible-selections)
          ("X" "act on selected" msteams-bulk-action)
          ("k" "close inactive" msteams-close-inactive-transcripts)]
         ["Test"
          ("m" "mock on" msteams-mock-enable)
          ("M" "mock off" msteams-mock-disable)
          ("r" "mock reset" msteams-mock-reset)]]))
    (defalias 'msteams-dispatch #'msteams-transient)))

(add-hook 'emacs-startup-hook #'msteams--setup-teams-transient)

(when (fboundp 'which-key-add-keymap-based-replacements)
  (which-key-add-keymap-based-replacements
    msteams-recent-mode-map
    "m" "mark"
    "a" "action"
    "b" "bookmark"
    "v" "view"
    "F" "unread only"
    "M" "select chat"
    "i" "mark read"
    "I" "mark read"
    "r" "mark read"
    "T" "select visible"
    "X" "bulk action"
    "Y" "copy Markdown"
    "O" "Teams app"
    "/" "cache/server search"
    "x" "execute marks"
    "U" "unmark all"
    "z" "undo"
    "H" "help")
  (which-key-add-keymap-based-replacements
    msteams-action-map
    "a" "capture action"
    "A" "capture full thread"
    "c" "compose"
    "R" "reply"
    "f" "forward"
    "i" "mark read now"
    "u" "mark unread now"
    "*" "favorite"
    "m" "mute locally"
    "s" "snooze"
    "k" "clear triage"
    "j" "jump to capture"
    "t" "meeting transcript"
    "e" "export Markdown"
    "y" "copy Markdown"
    "g" "analyze with agent"
    "o" "Teams web"
    "O" "Teams app"
    "?" "choose action")
  (which-key-add-keymap-based-replacements
    msteams-chat-mode-map
    "+" "react"
    "-" "unreact"
    "a" "action"
    "L" "load older"
    "S" "toggle order"
    "Y" "copy Markdown"
    "N" "next thread"
    "P" "previous thread"))

(defalias 'teams-channels #'msteams-channels)
(defalias 'teams-search #'msteams-search)
(defalias 'teams-server-search #'msteams-server-search)
(defalias 'teams-drafts #'msteams-compose-drafts)
(defalias 'teams-meeting-transcript #'msteams-meeting-transcript)
(defalias 'teams-handle #'msteams-toggle-handled)
(defalias 'teams-snooze #'msteams-snooze)
(defalias 'teams-clear-triage #'msteams-clear-triage)
(defalias 'teams-jump-capture #'msteams-jump-to-capture)
(defalias 'teams-bookmark #'msteams-bookmark-jump)
(defalias 'teams-filter #'msteams-filter)
(defalias 'teams-unread-filter #'msteams-toggle-unread-filter)
(defalias 'teams-bulk-action #'msteams-bulk-action)
(defalias 'teams-close-inactive #'msteams-close-inactive-transcripts)
(defalias 'teams-sync #'msteams-sync)
(defalias 'teams-user #'msteams-user)
(defalias 'teams-create-chat #'msteams-create-chat)
(defalias 'teams-dispatch #'msteams-dispatch)
(defalias 'teams-export-thread #'msteams-export-current-thread)
(defalias 'teams-copy-thread-markdown
  #'msteams-copy-current-thread-markdown)
(defalias 'teams-analyze-thread #'msteams-analyze-current-thread)
(defalias 'teams-capture-message #'msteams-capture-current-message)
(defalias 'teams-capture-action #'msteams-capture-current-summary)
(defalias 'teams-capture-thread #'msteams-capture-current-thread)

(provide 'msteams-advanced)

;;; msteams-advanced.el ends here
