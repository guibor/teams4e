;;; teams4e-advanced.el --- Full native Teams workflows. -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Higher-level views and mutations layered on the small process/JSON core in
;; teams4e-ui.el.  Every server operation remains an argv-only invocation.

;;; Code:

(require 'teams4e-ui)
(require 'cl-lib)
(require 'json)
(require 'seq)
(require 'subr-x)
(require 'tabulated-list)

(declare-function teams4e-transient "advanced")
(declare-function teams4e-meeting-availability "teams4e-meetings")
(declare-function agent-shell--resolve-config-designator "agent-shell"
                  (designator))
(declare-function agent-shell-insert "agent-shell" (&rest arguments))
(declare-function agent-shell-start "agent-shell" (&rest arguments))
(declare-function org-read-date "org" (&optional inactive to-time from-string prompt
                                                 default-time default-input))

(defvar teams4e-background-sync-interval)
(defvar teams4e-background-sync-max-backoff)
(defvar teams4e-bookmarks)
(defvar teams4e-confirm-apply)
(defvar teams4e-default-view)
(defvar teams4e-download-directory)
(defvar teams4e-draft-directory)
(defvar teams4e-mock-mode)
(defvar teams4e-meeting-proposal-activity-domain)
(defvar teams4e-meeting-availability-interval)
(defvar teams4e-meeting-proposal-default-comment)
(defvar teams4e-meeting-proposal-max-candidates)
(defvar teams4e-meeting-proposal-minimum-confidence)
(defvar teams4e-meeting-proposal-search-days)
(defvar teams4e-notifications)
(defvar teams4e-offline-mode)
(defvar teams4e-preview-delay)
(defvar teams4e-preview-on-move)
(defvar teams4e-sync-chat-limit)
(defvar teams4e-sync-days)
(defvar teams4e-sync-scope)
(defvar teams4e-status-style)
(defvar teams4e-thread-analysis-agent)
(defvar agent-shell-agent-configs)

(defvar teams4e--active-query nil)
(defvar teams4e--active-filter-name nil)
(defvar teams4e--unread-filter-enabled nil)
(defvar teams4e--marks (make-hash-table :test #'equal))
(defvar teams4e--selections (make-hash-table :test #'equal))
(defvar teams4e--action-history nil)
(defvar teams4e--undo-inflight nil)
(defvar teams4e--background-timer nil)
(defvar teams4e--background-failures 0)
(defvar teams4e--background-process nil)
(defvar teams4e--last-sync nil)
(defvar teams4e--mode-line " Teams: idle")
(defvar teams4e--jump-to-bottom-on-render)
(defconst teams4e--search-buffer-name "*Teams Search*")
(defconst teams4e--transcript-buffer-name "*Teams Meeting Transcript*")

(defvar-local teams4e--search-query nil)
(defvar-local teams4e--search-server nil)

(defvar-local teams4e-channel--team nil)
(defvar-local teams4e-channel--channel nil)
(defvar-local teams4e-channel--roots nil)
(defvar-local teams4e-channel--root nil)
(defvar-local teams4e-channel--messages nil)
(defvar-local teams4e-channel--request-id 0)
(defvar-local teams4e-channel--pending-message-id nil)

(defface teams4e-mark
  '((t :inherit font-lock-constant-face :weight bold))
  "Face for deferred mu4e-style action marks."
  :group 'teams4e)

(defface teams4e-channel-subject
  '((t :inherit font-lock-function-name-face :weight semi-bold))
  "Face for channel thread subjects."
  :group 'teams4e)

(defun teams4e--set-mode-line (text)
  "Set the global Teams mode-line TEXT and refresh displays."
  (setq teams4e--mode-line (concat " Teams: " text))
  (force-mode-line-update t))

(unless (member 'teams4e--mode-line global-mode-string)
  (setq global-mode-string
        (append global-mode-string '(teams4e--mode-line))))

(defun teams4e-mock-enable (&optional reset)
  "Enable the local persistent Teams mock; with RESET, restore seed state."
  (interactive "P")
  (teams4e--stop-server)
  (setq teams4e-mock-mode t
        teams4e-offline-mode nil
        teams4e--connected-as nil)
  (if reset
      (teams4e-mock-reset)
    (teams4e-status))
  (message "Teams local mock enabled%s" (if reset " and reset" "")))

(defun teams4e-mock-disable ()
  "Return the backend to shared-OAuth Microsoft Graph mode."
  (interactive)
  (teams4e--stop-server)
  (setq teams4e-mock-mode nil
        teams4e--connected-as nil)
  (message "Teams local mock disabled; live Graph mode selected"))

(defun teams4e-mock-reset ()
  "Reset the persistent local mock tenant to deterministic seed data."
  (interactive)
  (unless teams4e-mock-mode
    (user-error "Enable `teams4e-mock-mode' before resetting mock state"))
  (teams4e--run-json
   '("mock" "reset")
   (lambda (payload)
     (message "Reset Teams mock: %s chats, %s teams"
              (or (teams4e--get payload 'chats) 0)
              (or (teams4e--get payload 'teams) 0)))))

(defun teams4e-toggle-offline ()
  "Toggle credential-free cache-only reading."
  (interactive)
  (setq teams4e-offline-mode (not teams4e-offline-mode))
  (teams4e--set-mode-line
   (if teams4e-offline-mode "offline" "online"))
  (message "Teams cache-only mode %s"
           (if teams4e-offline-mode "enabled" "disabled"))
  (when (derived-mode-p 'teams4e-recent-mode)
    (teams4e-recent-refresh)))

(defun teams4e-cache-status ()
  "Display SQLite cache counts and last synchronization time."
  (interactive)
  (teams4e--run-json
   '("teams" "cache" "status")
   (lambda (payload)
     (let ((buffer (get-buffer-create "*Teams Cache*")))
       (with-current-buffer buffer
         (let ((inhibit-read-only t))
           (erase-buffer)
           (insert (format "Path: %s\n" (teams4e--get payload 'path)))
           (insert (format "Last sync: %s\n\n"
                           (or (teams4e--get payload 'lastSync) "never")))
           (insert "Resources\n---------\n")
           (dolist (item (teams4e--get payload 'resources))
             (insert (format "%s: %s\n" (car item) (cdr item))))
           (insert "\nMessages\n--------\n")
           (dolist (item (teams4e--get payload 'messages))
             (insert (format "%s: %s\n" (car item) (cdr item))))
           (special-mode)))
       (pop-to-buffer buffer)))))

(defun teams4e--sync-args (&optional all)
  "Return backend sync arguments; ALL requests channels as well as chats."
  (list "teams" "sync"
        "--scope" (if all "all" teams4e-sync-scope)
        "--chatLimit" (number-to-string teams4e-sync-chat-limit)
        "--days" (number-to-string teams4e-sync-days)))

(defun teams4e--notify-sync (payload)
  "Notify about incremental changes represented by sync PAYLOAD."
  (let ((new (or (teams4e--get payload 'newMessages) 0))
        (changed (or (teams4e--get payload 'changedMessages) 0)))
    (when (and teams4e-notifications (> new 0))
      (if (fboundp 'notifications-notify)
          (notifications-notify
           :title "Microsoft Teams"
           :body (format "%d new message%s" new (if (= new 1) "" "s"))
           :app-name "Emacs")
        (message "Teams: %d new message%s" new (if (= new 1) "" "s"))))
    (teams4e--set-mode-line
     (format "%d new, %d changed" new changed))))

(defun teams4e-sync (&optional all callback error-callback)
  "Synchronize Teams into SQLite.

With prefix ALL, include joined teams and channels.  CALLBACK receives the
summary.  ERROR-CALLBACK follows `teams4e--run-json'."
  (interactive "P")
  (teams4e--require-online)
  (teams4e--set-mode-line "syncing")
  (setq teams4e--background-process
        (teams4e--run-json
         (teams4e--sync-args all)
         (lambda (payload)
           (let ((errors (teams4e--get payload 'errors)))
             (setq teams4e--background-process nil)
             (if errors
                 (let ((detail
                        (concat
                         "Partial Teams synchronization:\n"
                         (mapconcat
                          (lambda (item)
                            (format "%s: %s"
                                    (or (teams4e--get item 'resource)
                                        "resource")
                                    (or (teams4e--get item 'error)
                                        "unknown error")))
                          errors "\n"))))
                   (teams4e--set-mode-line "sync partial")
                   (if error-callback
                       (funcall error-callback "partial" detail)
                     (teams4e--report-error
                      (teams4e--sync-args all) "partial" detail)))
               (setq teams4e--last-sync (current-time))
               (teams4e--notify-sync payload)
               (when-let ((buffer (teams4e--recent-buffer)))
                 (teams4e--load-chats
                  (lambda (chats)
                    (when (buffer-live-p buffer)
                      (with-current-buffer buffer
                        (teams4e--render-recent)))
                    (teams4e--enrich-members chats))))
               (when callback (funcall callback payload)))))
         (lambda (status detail)
           (setq teams4e--background-process nil)
           (teams4e--set-mode-line "sync failed")
           (if error-callback
               (funcall error-callback status detail)
             (teams4e--report-error
              (teams4e--sync-args all) status detail))))))

(defun teams4e--cancel-background-timer ()
  "Cancel the pending one-shot background synchronization timer."
  (when (timerp teams4e--background-timer)
    (cancel-timer teams4e--background-timer))
  (setq teams4e--background-timer nil))

(defun teams4e--schedule-background-sync (delay)
  "Schedule one background sync after DELAY seconds."
  (teams4e--cancel-background-timer)
  (setq teams4e--background-timer
        (run-at-time delay nil #'teams4e--background-sync-run)))

(defun teams4e--background-sync-run ()
  "Run one sync and schedule the next success or backed-off retry."
  (setq teams4e--background-timer nil)
  (if teams4e-offline-mode
      (teams4e--schedule-background-sync
       teams4e-background-sync-interval)
    (teams4e-sync
     nil
     (lambda (_payload)
       (setq teams4e--background-failures 0)
       (teams4e--schedule-background-sync
        teams4e-background-sync-interval))
     (lambda (status detail)
       (cl-incf teams4e--background-failures)
       (let ((delay
              (min teams4e-background-sync-max-backoff
                   (* teams4e-background-sync-interval
                      (expt 2 (1- teams4e--background-failures))))))
         (teams4e--report-error
          (teams4e--sync-args) status detail)
         (teams4e--set-mode-line (format "retry in %ds" delay))
         (teams4e--schedule-background-sync delay))))))

(define-minor-mode teams4e-background-sync-mode
  "Periodically synchronize Teams with retry/backoff and notifications."
  :global t
  :group 'teams4e
  (teams4e--cancel-background-timer)
  (if teams4e-background-sync-mode
      (progn
        (setq teams4e--background-failures 0)
        (teams4e--schedule-background-sync 1)
        (teams4e--set-mode-line "sync scheduled"))
    (teams4e--cancel-process teams4e--background-process)
    (setq teams4e--background-process nil)
    (teams4e--set-mode-line "idle")))

(defun teams4e--built-in-view-chat-p (chat view)
  "Return whether CHAT belongs to built-in inbox VIEW."
  (pcase view
    ('inbox (and (not (teams4e--muted-p chat))
                 (not (teams4e--triaged-p chat))))
    ('all t)
    ('attention (and (not (teams4e--muted-p chat))
                     (not (teams4e--triaged-p chat))
                     (teams4e--attention-p chat)))
    ('muted (teams4e--muted-p chat))
    ('unread (teams4e--unread-p chat))
    ('favorites (teams4e--favorite-p chat))
    ('handled (teams4e--handled-p chat))
    ('snoozed (teams4e--snoozed-p chat))
    ('direct (equal (teams4e--get chat 'chatType) "oneOnOne"))
    ('group (equal (teams4e--get chat 'chatType) "group"))
    ('meeting (equal (teams4e--get chat 'chatType) "meeting"))
    ('upcoming (teams4e--meeting-upcoming-p chat))
    (_ t)))

(defconst teams4e--built-in-view-symbols
  '(inbox all attention muted unread favorites handled snoozed
          direct group meeting upcoming)
  "Symbols interpreted as built-in views before function lookup.")

(defun teams4e--query-text-match-p (needle text)
  "Return non-nil when case-insensitive NEEDLE occurs in TEXT."
  (and (stringp text)
       (string-match-p (regexp-quote needle) text)))

(defun teams4e--query-term-chat-p (chat term)
  "Return whether CHAT matches one inbox query TERM."
  (let* ((case-fold-search t)
         (negated (string-prefix-p "-" term))
         (term (if negated (substring term 1) term))
         (label (teams4e--chat-label chat))
         (preview (teams4e--chat-preview chat))
         (type (teams4e--get chat 'chatType))
         (matched
          (cond
           ((member (downcase term) '("" "*" "all")) t)
           ((string-equal (downcase term) "inbox")
            (and (not (teams4e--muted-p chat))
                 (not (teams4e--triaged-p chat))))
           ((member (downcase term) '("muted" "hidden"))
            (teams4e--muted-p chat))
           ((string-equal (downcase term) "unread")
            (teams4e--unread-p chat))
           ((string-equal (downcase term) "read")
            (not (teams4e--unread-p chat)))
           ((member (downcase term) '("favorite" "favorites"))
            (teams4e--favorite-p chat))
           ((string-equal (downcase term) "handled")
            (teams4e--handled-p chat))
           ((string-equal (downcase term) "snoozed")
            (teams4e--snoozed-p chat))
           ((member (downcase term) '("attention" "important-to-me"))
            (teams4e--attention-p chat))
           ((member (downcase term) '("upcoming" "meeting:upcoming"))
            (teams4e--meeting-upcoming-p chat))
           ((member (downcase term) '("mentioned" "mention"))
            (teams4e--mentioned-user-p
             (teams4e--last-message chat)))
           ((member (downcase term) '("important" "priority"))
            (teams4e--important-p
             (teams4e--last-message chat)))
           ((member (downcase term) '("reply-to-me" "reply"))
            (teams4e--reply-to-own-p
             (teams4e--last-message chat)))
           ((member (downcase term) '("attachment" "attachments"))
            (seq-some
             (lambda (attachment)
               (not (member (teams4e--get attachment 'contentType)
                            '("messageReference"
                              "forwardedMessageReference"))))
             (teams4e--get (teams4e--last-message chat)
                            'attachments)))
           ((string-match "\\`type:\\(.+\\)\\'" term)
            (let ((wanted (downcase (match-string 1 term))))
              (equal type
                     (pcase wanted
                       ((or "direct" "oneonone") "oneOnOne")
                       (other other)))))
           ((string-match "\\`after:\\([0-9]+\\)d\\'" term)
            (let ((updated (teams4e--last-message-date-time chat)))
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
            (teams4e--query-text-match-p
             (match-string 1 term) label))
           ((string-match "\\`message:\\(.*\\)\\'" term)
            (teams4e--query-text-match-p
             (match-string 1 term) preview))
           (t
            (or (teams4e--query-text-match-p term label)
                (teams4e--query-text-match-p term preview))))))
    (if negated (not matched) matched)))

(defun teams4e--query-chat-p (chat query)
  "Return whether CHAT matches bookmark/filter QUERY."
  (cond
   ((and (symbolp query)
         (memq query teams4e--built-in-view-symbols))
    (teams4e--built-in-view-chat-p chat query))
   ((functionp query) (funcall query chat))
   ((symbolp query) (teams4e--built-in-view-chat-p chat query))
   ((stringp query)
    (seq-some
     (lambda (clause)
       (seq-every-p
        (lambda (term) (teams4e--query-term-chat-p chat term))
        (split-string-and-unquote (string-trim clause))))
     (split-string query "|" t)))
   (t t)))

(defun teams4e--view-chat-p (chat)
  "Return whether CHAT belongs to the active inbox view or query."
  (teams4e--ensure-active-view)
  (and
   (or (teams4e--meeting-view-p)
       (not (teams4e--message-less-meeting-p chat)))
   (if teams4e--active-query
       (teams4e--query-chat-p chat teams4e--active-query)
     (teams4e--built-in-view-chat-p
      chat teams4e--active-view))
   (or (not teams4e--unread-filter-enabled)
       (teams4e--unread-p chat))))

(defun teams4e--meeting-only-query-p (query)
  "Return non-nil when QUERY restricts every clause to meeting rows."
  (cond
   ((memq query '(meeting upcoming)) t)
   ((stringp query)
    (let ((clauses (split-string query "|" t)))
      (and clauses
           (seq-every-p
            (lambda (clause)
              (seq-some
               (lambda (term)
                 (member (downcase term)
                         '("type:meeting" "upcoming" "meeting:upcoming")))
               (split-string-and-unquote (string-trim clause))))
            clauses))))
   (t nil)))

(defun teams4e--meeting-view-p ()
  "Return non-nil when the active headers view contains only meetings."
  (teams4e--ensure-active-view)
  (if teams4e--active-query
      (teams4e--meeting-only-query-p teams4e--active-query)
    (memq teams4e--active-view '(meeting upcoming))))

(defun teams4e--meeting-view-header-summary (visible)
  "Return compact next-meeting, conflict, and response context for VISIBLE."
  (when (teams4e--meeting-view-p)
    (let* ((now (current-time))
           (next (seq-find
                  (lambda (chat)
                    (and (teams4e--meeting-active-event-p chat)
                         (when-let ((boundary
                                     (or (teams4e--meeting-end-time chat)
                                         (teams4e--meeting-start-time chat))))
                           (time-less-p now boundary))))
                  visible))
           (conflicts
            (seq-count (lambda (chat) (teams4e--meeting-conflicts chat))
                       visible))
           (responses
            (seq-count
             (lambda (chat)
               (equal (teams4e--meeting-status-label chat) "Needs response"))
             visible))
           (calendar-errors
            (seq-count
             (lambda (chat)
               (teams4e--dig chat 'meetingContext 'eventError))
             teams4e--chats)))
      (format " - next %s - %d conflict%s - %d to respond%s"
              (if-let ((start (and next
                                   (teams4e--meeting-start-time next))))
                  (if (and (not (time-less-p now start))
                           (when-let ((end (teams4e--meeting-end-time next)))
                             (time-less-p now end)))
                      "now"
                    (format-time-string "%a %H:%M" start))
                "none")
              conflicts (if (= conflicts 1) "" "s") responses
              (if (> calendar-errors 0)
                  (format " - %d calendar unavailable" calendar-errors)
                "")))))

(defun teams4e--order-visible-chats (chats)
  "Return a newly sorted copy of visible CHATS for the active view."
  (sort (copy-sequence chats)
        (if (teams4e--meeting-view-p)
            #'teams4e--meeting-starts-before-p
          #'teams4e--chat-updated-p)))

(defun teams4e--active-filter-label ()
  "Return the display label for the active inbox filter."
  (teams4e--ensure-active-view)
  (concat
   (or teams4e--active-filter-name
       (symbol-name teams4e--active-view))
   (if teams4e--unread-filter-enabled " + unread only" "")))

(defun teams4e--status-spec (kind)
  "Return display text and help text for inbox status KIND."
  (if (eq teams4e-status-style 'letters)
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

(defun teams4e--status-token (kind)
  "Return a styled inbox status token for KIND."
  (pcase-let ((`(,text ,help) (teams4e--status-spec kind)))
    (propertize text 'face 'teams4e-mark 'help-echo help)))

(defun teams4e--action-mark-character (action)
  "Return the compact inbox marker for deferred ACTION."
  (teams4e--status-token action))

(defun teams4e--mark-character (chat)
  "Return selection and deferred-action marks for CHAT."
  (let* ((chat-id (teams4e--chat-id chat))
         (selected (gethash chat-id teams4e--selections))
         (action (gethash chat-id teams4e--marks))
         (triage (cond ((teams4e--handled-p chat) 'handled)
                       ((teams4e--snoozed-p chat) 'snoozed)))
         (captured (teams4e--captured-p chat)))
    (mapconcat
     #'identity
     (delq nil
           (list (and selected (teams4e--status-token 'selected))
                 (and action (teams4e--action-mark-character action))
                 (and triage (teams4e--status-token triage))
                 (and captured (teams4e--status-token 'captured))))
     "")))

(defun teams4e--set-handled-local (chat enabled)
  "Set CHAT's handled-until-new state to ENABLED without persisting."
  (let ((chat-id (teams4e--chat-id chat)))
    (if enabled
        (progn
          (puthash chat-id (teams4e--chat-marker chat)
                   teams4e--handled)
          (remhash chat-id teams4e--snoozed))
      (remhash chat-id teams4e--handled))))

(defun teams4e--set-snoozed-local (chat until)
  "Snooze CHAT until ISO timestamp UNTIL without persisting."
  (let ((chat-id (teams4e--chat-id chat)))
    (if until
        (progn
          (remhash chat-id teams4e--handled)
          (puthash chat-id until teams4e--snoozed))
      (remhash chat-id teams4e--snoozed))))

(defun teams4e--clear-triage-local (chat)
  "Clear handled and snoozed state for CHAT without persisting."
  (let ((chat-id (teams4e--chat-id chat)))
    (remhash chat-id teams4e--handled)
    (remhash chat-id teams4e--snoozed)))

(defun teams4e-toggle-handled ()
  "Toggle handled-until-new state for the current Teams conversation."
  (interactive)
  (teams4e--load-state)
  (let* ((chat (or (teams4e--chat-at-point)
                   (user-error "No Teams chat here")))
         (enabled (not (teams4e--handled-p chat))))
    (teams4e--set-handled-local chat enabled)
    (teams4e--save-state)
    (teams4e--refresh-visible-recent)
    (message "%s %s"
             (if enabled "Handled until a new message:" "Returned to inbox:")
             (teams4e--chat-label chat))))

(defun teams4e--time-at-local-hour (base hour)
  "Return BASE's local calendar date at HOUR:00."
  (pcase-let ((`(,_second ,_minute ,_hour ,day ,month ,year . ,_)
               (decode-time base)))
    (encode-time 0 0 hour day month year)))

(defun teams4e--read-snooze-time ()
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
       (teams4e--time-at-local-hour
        (time-add now (days-to-time 1)) 9))
      ("Next week 09:00"
       (teams4e--time-at-local-hour
        (time-add now (days-to-time 7)) 9))
      ("Choose date/time..."
       (require 'org)
       (org-read-date nil t nil "Snooze Teams chat until: "))
      (_ nil))))

(defun teams4e-snooze ()
  "Snooze the current Teams conversation using one local expiry timestamp."
  (interactive)
  (teams4e--load-state)
  (let* ((chat (or (teams4e--chat-at-point)
                   (user-error "No Teams chat here")))
         (time (teams4e--read-snooze-time))
         (until (and time (format-time-string "%Y-%m-%dT%H:%M:%S%z" time))))
    (teams4e--set-snoozed-local chat until)
    (teams4e--save-state)
    (teams4e--refresh-visible-recent)
    (if until
        (message "Snoozed %s until %s"
                 (teams4e--chat-label chat)
                 (format-time-string "%a %H:%M" time))
      (message "Cleared snooze for %s"
               (teams4e--chat-label chat)))))

(defun teams4e-clear-triage ()
  "Clear handled and snoozed state for the current Teams conversation."
  (interactive)
  (teams4e--load-state)
  (let ((chat (or (teams4e--chat-at-point)
                  (user-error "No Teams chat here"))))
    (teams4e--clear-triage-local chat)
    (teams4e--save-state)
    (teams4e--refresh-visible-recent)
    (message "Cleared local triage for %s"
             (teams4e--chat-label chat))))

(defun teams4e--recent-entry-advanced (chat)
  "Build an inbox row for CHAT including deferred marks."
  (list (teams4e--chat-id chat)
        (teams4e--recent-columns chat (teams4e--mark-character chat))))

(defun teams4e--render-recent ()
  "Render the active saved/built-in inbox view and preserve selection."
  (teams4e--cancel-recent-redraw)
  (teams4e--captured-chat-table)
  (let* ((started (float-time))
         (selected (teams4e--recent-selected-id))
         (visible (seq-filter #'teams4e--view-chat-p
                              teams4e--chats))
         (visible (teams4e--order-visible-chats visible))
         (unread-count (seq-count #'teams4e--unread-p
                                  teams4e--chats)))
    (teams4e--configure-recent-format)
    (setq tabulated-list-entries
          (mapcar #'teams4e--recent-entry-advanced visible)
          header-line-format
          (format (concat "Teams %s - %d shown - %d unread - "
                          "%d selected - %d queued%s%s%s%s")
                  (teams4e--active-filter-label)
                  (length visible) unread-count
                  (hash-table-count teams4e--selections)
                  (hash-table-count teams4e--marks)
                  (if teams4e-offline-mode " - OFFLINE" "")
                  (if teams4e-mock-mode " - MOCK" "")
                  (teams4e--inbox-source-suffix)
                  (or (teams4e--meeting-view-header-summary visible) "")))
    (teams4e--set-mode-line
     (format "%d unread%s" unread-count
             (if teams4e-mock-mode " mock" "")))
    (tabulated-list-print t)
    (teams4e--recent-restore-selection selected)
    (teams4e--follow-selected-chat)
    (teams4e--record-performance
     "Inbox render" (* 1000.0 (- (float-time) started))
     :transport "emacs" :items (length visible))))

(defun teams4e--apply-inbox-query (query name)
  "Apply inbox QUERY under display NAME and redraw the headers buffer."
  (when (or (eq query 'all)
            (and (stringp query)
                 (string-equal (string-trim query) "all")))
    (setq teams4e--unread-filter-enabled nil))
  (setq teams4e--active-query query
        teams4e--active-filter-name name
        tabulated-list-sort-key nil)
  (when (teams4e--meeting-view-p)
    (teams4e--enrich-meetings teams4e--chats t))
  (if (derived-mode-p 'teams4e-recent-mode)
      (teams4e--render-recent)
    (teams4e-inbox)))

(defun teams4e--ask-bookmark ()
  "Read and return one entry from `teams4e-bookmarks'."
  (unless teams4e-bookmarks
    (user-error "No Teams bookmarks are configured"))
  (let* ((prompt
          (concat
           "Teams bookmark: "
           (mapconcat
            (lambda (bookmark)
              (format "[%c]%s"
                      (plist-get bookmark :key)
                      (plist-get bookmark :name)))
            teams4e-bookmarks ", ")
           " "))
         (key (read-char prompt)))
    (or (seq-find
         (lambda (bookmark) (eq key (plist-get bookmark :key)))
         teams4e-bookmarks)
        (user-error "Unknown Teams bookmark key %c" key))))

(defun teams4e-bookmark-jump (&optional edit)
  "Filter the inbox using a shortcut bookmark.

With EDIT non-nil, edit a string bookmark query before applying it, matching
the distinction between mu4e's `b' and `B' commands."
  (interactive)
  (let* ((bookmark (teams4e--ask-bookmark))
         (name (plist-get bookmark :name))
         (query (plist-get bookmark :query)))
    (when edit
      (unless (stringp query)
        (user-error "This Teams bookmark uses a function and cannot be edited"))
      (setq query (read-string (format "Edit %s query: " name) query)
            name (format "%s (edited)" name)))
    (if (and (not edit)
             (or (eq query 'unread)
                 (and (stringp query)
                      (string-equal (string-trim query) "unread"))))
        (teams4e-filter-unread)
      (teams4e--apply-inbox-query query name))))

(defun teams4e-bookmark-edit ()
  "Edit and apply a configured Teams inbox bookmark."
  (interactive)
  (teams4e-bookmark-jump t))

(defun teams4e-filter (query)
  "Apply an ad hoc mu4e-style inbox QUERY to the Teams headers buffer."
  (interactive
   (list
    (read-string
     "Teams inbox query: "
     (and (stringp teams4e--active-query)
          teams4e--active-query))))
  (teams4e--apply-inbox-query
   query (if (string-empty-p query) "all" query)))

(defun teams4e--set-unread-filter (enabled)
  "Set the independent unread-only overlay to ENABLED and redraw headers."
  (setq teams4e--unread-filter-enabled (and enabled t))
  (when-let ((buffer (if (derived-mode-p 'teams4e-recent-mode)
                          (current-buffer)
                        (teams4e--recent-buffer))))
    (with-current-buffer buffer
      (when (derived-mode-p 'teams4e-recent-mode)
        (teams4e--render-recent)))))

(defun teams4e-filter-unread ()
  "Enable unread-only filtering without replacing the active inbox filter."
  (interactive)
  (teams4e--set-unread-filter t)
  (message "Teams unread-only filter enabled for %s"
           (or teams4e--active-filter-name
               (symbol-name teams4e--active-view))))

(defun teams4e-toggle-unread-filter ()
  "Toggle an unread-only overlay without replacing the active inbox filter."
  (interactive)
  (teams4e--set-unread-filter (not teams4e--unread-filter-enabled))
  (message "Teams unread-only filter %s for %s"
           (if teams4e--unread-filter-enabled "enabled" "disabled")
           (or teams4e--active-filter-name
               (symbol-name teams4e--active-view))))

(defun teams4e-bookmark-define (query name key)
  "Define session bookmark QUERY with NAME and shortcut KEY.

This mirrors `mu4e-bookmark-define'.  Persist personal definitions by setting
`teams4e-bookmarks' in the dotfile."
  (setq teams4e-bookmarks
        (seq-remove
         (lambda (bookmark) (eq key (plist-get bookmark :key)))
         teams4e-bookmarks))
  (setq teams4e-bookmarks
        (append teams4e-bookmarks
                (list (list :name name :query query :key key)))))

(defun teams4e-select-view ()
  "Select a built-in inbox filter or run a saved search view."
  (interactive)
  (teams4e--load-state)
  (let ((built-ins '("inbox" "attention" "all" "handled" "snoozed"
                     "muted" "unread" "favorites" "direct" "group"
                     "meeting"))
        saved)
    (maphash (lambda (name _query) (push (concat "search: " name) saved))
             teams4e--saved-views)
    (let ((choice (completing-read "Teams view: "
                                   (append built-ins (sort saved #'string<))
                                   nil t)))
      (if (string-prefix-p "search: " choice)
          (teams4e-search
           (gethash (substring choice 8) teams4e--saved-views))
        (setq teams4e--active-view (intern choice)
              teams4e--active-query nil
              teams4e--active-filter-name nil
              tabulated-list-sort-key nil)
        (when (derived-mode-p 'teams4e-recent-mode)
          (teams4e--render-recent))))))

(defun teams4e-save-view (name query)
  "Persist cached search QUERY under NAME."
  (interactive
   (list (read-string "Saved Teams view name: ")
         (read-string "Cached message query: ")))
  (teams4e--load-state)
  (when (or (string-empty-p (string-trim name))
            (string-empty-p (string-trim query)))
    (user-error "Saved view name and query are required"))
  (puthash (string-trim name) (string-trim query)
           teams4e--saved-views)
  (teams4e--save-state)
  (message "Saved Teams search view %s" name))

(defun teams4e-delete-view ()
  "Delete one persisted cached search view."
  (interactive)
  (teams4e--load-state)
  (let (names)
    (maphash (lambda (name _query) (push name names))
             teams4e--saved-views)
    (let ((name (completing-read "Delete Teams view: " names nil t)))
      (remhash name teams4e--saved-views)
      (teams4e--save-state)
      (message "Deleted Teams view %s" name))))

(defun teams4e-sort ()
  "Choose the current tabulated inbox sort column."
  (interactive)
  (unless (derived-mode-p 'teams4e-recent-mode)
    (user-error "Open the Teams inbox first"))
  (let ((choice (completing-read
                 "Sort Teams inbox by: "
                 '("Message time" "Type" "Conversation" "Last message") nil t)))
    (setq tabulated-list-sort-key
          (cons choice (equal choice "Message time")))
    (tabulated-list-print t)))

(defvar teams4e-search-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map tabulated-list-mode-map)
    (define-key map (kbd "RET") #'teams4e-search-open)
    (define-key map (kbd "j") #'next-line)
    (define-key map (kbd "k") #'previous-line)
    (define-key map (kbd "g") #'teams4e-search-refresh)
    (define-key map (kbd "q") #'teams4e-quit)
    map)
  "Keymap for cached or server Teams search results.")

(define-derived-mode teams4e-search-mode tabulated-list-mode "Teams-Search"
  "Major mode for Teams cache and ephemeral server search results."
  (setq tabulated-list-format
        [("Date" 16 t) ("Sender" 20 t) ("Scope" 10 t) ("Message" 70 nil)]
        tabulated-list-padding 1)
  (tabulated-list-init-header))

(defun teams4e--search-entry (message)
  "Build one tabulated cache/server search row from MESSAGE."
  (let* ((context (or (teams4e--get message 'searchContext)
                      (teams4e--get message 'cacheContext)))
         (scope (or (teams4e--get context 'scopeKind) ""))
         (body-text (teams4e--message-body message))
         (body (replace-regexp-in-string
                "[\n\r\t ]+" " "
                (if (string-empty-p body-text)
                    (teams4e--html-to-text
                     (or (teams4e--get context 'summary) ""))
                  body-text))))
    (list message
          (vector
           (teams4e--format-date (teams4e--get message 'createdDateTime))
           (teams4e--message-sender message)
           scope
           (truncate-string-to-width body 70 nil nil "...")))))

(defun teams4e--show-search-results (payload query source)
  "Display search PAYLOAD for QUERY, labelled with SOURCE."
  (let ((buffer (get-buffer-create teams4e--search-buffer-name))
        (results (teams4e--payload-list payload)))
    (with-current-buffer buffer
      (teams4e-search-mode)
      (setq teams4e--search-query query
            teams4e--search-server (string-equal source "server"))
      (setq tabulated-list-entries
            (mapcar #'teams4e--search-entry
                    results)
            header-line-format
            (format "Teams %s search: %s - %d result%s"
                    source query (length results)
                    (if (= (length results) 1)
                        "" "s")))
      (tabulated-list-print t))
    (pop-to-buffer buffer)))

(defun teams4e-search (&optional query server)
  "Search Teams messages.

The default searches the existing private SQLite cache.  With a prefix argument
SERVER, use Microsoft Search ephemerally and hydrate a selected hit through the
normal reader without adding a second search cache."
  (interactive (list nil current-prefix-arg))
  (when (and server teams4e-offline-mode)
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
    (teams4e--run-json
   args
   (lambda (payload)
     (teams4e--show-search-results payload query source))
   (lambda (status detail)
     (let ((buffer (get-buffer-create teams4e--search-buffer-name)))
       (with-current-buffer buffer
         (teams4e-search-mode)
         (setq teams4e--search-query query
               teams4e--search-server server)
         (setq tabulated-list-entries nil
               header-line-format
               (format "Teams %s search failed - see *M365 Errors*" source))
         (tabulated-list-print t))
       (pop-to-buffer buffer))
     (teams4e--report-error args status detail)))))

(defun teams4e-search-refresh ()
  "Repeat the current Teams search against its original source."
  (interactive)
  (unless (and (stringp teams4e--search-query)
               (not (string-empty-p teams4e--search-query)))
    (user-error "This search buffer has no query to refresh"))
  (teams4e-search teams4e--search-query
                         teams4e--search-server))

(defun teams4e-server-search (&optional query)
  "Search Teams messages ephemerally through Microsoft Search."
  (interactive)
  (teams4e-search query t))

(defun teams4e-search-open ()
  "Open the source transcript for the cached search result at point."
  (interactive)
  (let* ((message (or (tabulated-list-get-id)
                      (user-error "No search result on this row")))
         (context (or (teams4e--get message 'searchContext)
                      (teams4e--get message 'cacheContext)))
         (scope (teams4e--get context 'scopeKind))
         (message-id (teams4e--get message 'id)))
    (pcase scope
      ("chat"
       (let* ((chat-id (teams4e--get context 'scopeId))
              (chat (or (teams4e--find-chat chat-id)
                        `((id . ,chat-id) (topic . "Cached chat")))))
         (teams4e-open-chat chat nil t message-id)))
      ("channel"
       (let* ((server-result (teams4e--get message 'searchContext))
              (team-id (teams4e--get context 'teamId))
              (channel-id (teams4e--get context 'channelId))
              (root-id (teams4e--get context 'rootMessageId))
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
         (teams4e--run-json
          (if server-result
              (list "teams" "channel" "message" "list"
                    "--teamId" team-id "--channelId" channel-id)
            (list "teams" "cache" "channel" "message" "list"
                  "--teamId" team-id "--channelId" channel-id
                  "--limit" "1000000"))
          (lambda (payload)
            (let* ((roots (teams4e--payload-list payload))
                   (root
                    (or (seq-find
                         (lambda (candidate)
                           (equal root-id (teams4e--get candidate 'id)))
                         roots)
                        (and (equal root-id message-id) message)
                        `((id . ,root-id)
                          (body . ((contentType . "text")
                                   (content . "Cached thread")))))))
              (teams4e-open-channel-thread team channel root)
              (with-current-buffer teams4e--read-buffer-name
                (setq teams4e-channel--pending-message-id
                      message-id)))))))
      (_ (user-error "Search result has no supported source context")))))

(defun teams4e--visible-chats ()
  "Return chats shown by the current inbox view and overlays."
  (seq-filter #'teams4e--view-chat-p teams4e--chats))

(defun teams4e--selected-chats ()
  "Return selected chats in current inbox order."
  (seq-filter
   (lambda (chat)
     (gethash (teams4e--chat-id chat) teams4e--selections))
   teams4e--chats))

(defun teams4e-toggle-selection ()
  "Toggle bulk selection for the inbox chat at point and move forward."
  (interactive)
  (unless (derived-mode-p 'teams4e-recent-mode)
    (user-error "Chat selection works in the Teams inbox"))
  (let* ((chat (teams4e--chat-at-point))
         (chat-id (teams4e--chat-id chat)))
    (if (gethash chat-id teams4e--selections)
        (remhash chat-id teams4e--selections)
      (puthash chat-id t teams4e--selections))
    (teams4e--render-recent)
    (teams4e-recent-next)))

(defun teams4e-toggle-visible-selections ()
  "Select all visible inbox chats, or clear them when all are selected."
  (interactive)
  (unless (derived-mode-p 'teams4e-recent-mode)
    (user-error "Chat selection works in the Teams inbox"))
  (let* ((visible (teams4e--visible-chats))
         (all-selected
          (and visible
               (seq-every-p
                (lambda (chat)
                  (gethash (teams4e--chat-id chat)
                           teams4e--selections))
                visible))))
    (unless visible (user-error "No visible Teams chats to select"))
    (dolist (chat visible)
      (let ((chat-id (teams4e--chat-id chat)))
        (if all-selected
            (remhash chat-id teams4e--selections)
          (puthash chat-id t teams4e--selections))))
    (teams4e--render-recent)
    (message "%s %d visible Teams chat%s"
             (if all-selected "Cleared" "Selected")
             (length visible) (if (= (length visible) 1) "" "s"))))

(defun teams4e-mark-action (action)
  "Defer ACTION for the inbox chat at point."
  (interactive)
  (unless (derived-mode-p 'teams4e-recent-mode)
    (user-error "Deferred actions work in the Teams inbox"))
  (let ((chat (teams4e--chat-at-point)))
    (puthash (teams4e--chat-id chat) action teams4e--marks)
    (teams4e--render-recent)
    (teams4e-recent-next)))

(defun teams4e-mark-read-later ()
  "Defer marking the current inbox chat read."
  (interactive)
  (teams4e-mark-action 'read))

(defun teams4e-mark-refile-later ()
  "Defer refiling the current chat until a newer message arrives."
  (interactive)
  (teams4e-mark-action 'refile))

(defun teams4e-mark-unread-later ()
  "Defer marking the current inbox chat unread."
  (interactive)
  (teams4e-mark-action 'unread))

(defun teams4e-mark-favorite-later ()
  "Defer toggling favorite state for the current inbox chat."
  (interactive)
  (teams4e-mark-action 'favorite))

(defun teams4e-unmark ()
  "Remove the deferred action and bulk selection on the current chat."
  (interactive)
  (let ((chat (teams4e--chat-at-point)))
    (remhash (teams4e--chat-id chat) teams4e--marks)
    (remhash (teams4e--chat-id chat) teams4e--selections)
    (teams4e--render-recent)))

(defun teams4e-unmark-all ()
  "Discard every deferred action and bulk selection in the Teams inbox."
  (interactive)
  (clrhash teams4e--marks)
  (clrhash teams4e--selections)
  (teams4e--refresh-visible-recent)
  (message "Cleared Teams selections and deferred actions"))

(defun teams4e--set-favorite (chat enabled)
  "Set CHAT favorite state to ENABLED and return its inverse history item."
  (let* ((chat-id (teams4e--chat-id chat))
         (was-favorite (teams4e--favorite-p chat)))
    (if enabled
        (puthash chat-id t teams4e--favorites)
      (remhash chat-id teams4e--favorites))
    (teams4e--save-state)
    (list :kind 'favorite :chat-id chat-id :enabled was-favorite)))

(defun teams4e--apply-favorite (chat)
  "Toggle local favorite state for CHAT and return its inverse history item."
  (teams4e--set-favorite
   chat (not (teams4e--favorite-p chat))))

(defun teams4e--record-completed-actions (completed)
  "Prepend inverse COMPLETED actions to the undo history."
  (when completed
    (setq teams4e--action-history
          (append completed teams4e--action-history))))

(defun teams4e--execute-mark-list (items completed)
  "Execute deferred ITEMS serially, accumulating inverse COMPLETED actions."
  (if (null items)
      (progn
        (teams4e--record-completed-actions completed)
        (setq teams4e--chats
              (sort teams4e--chats #'teams4e--chat-updated-p))
        (teams4e--refresh-visible-recent)
        (message "Executed %d Teams action%s"
                 (length completed) (if (= (length completed) 1) "" "s")))
    (pcase-let* ((`(,chat-id . ,action) (car items))
                 (chat (or (teams4e--find-chat chat-id)
                           `((id . ,chat-id))))
                 (rest (cdr items)))
      (pcase action
        ((or 'favorite 'favorite-on 'favorite-off)
         (remhash chat-id teams4e--marks)
         (teams4e--execute-mark-list
          rest
          (cons
           (if (eq action 'favorite)
               (teams4e--apply-favorite chat)
             (teams4e--set-favorite
              chat (eq action 'favorite-on)))
           completed)))
        ('refile
         (teams4e--load-state)
         (let ((undo (list :kind 'triage
                           :chat-id chat-id
                           :handled (gethash chat-id teams4e--handled)
                           :snoozed (gethash chat-id teams4e--snoozed))))
           (teams4e--set-handled-local chat t)
           (teams4e--save-state)
           (remhash chat-id teams4e--marks)
           (teams4e--execute-mark-list rest (cons undo completed))))
        ((or 'read 'unread)
         (let ((args
                (list "teams" "chat" "mark" (symbol-name action)
                      "--chatId" chat-id)))
           (teams4e--run-json
            args
            (lambda (_payload)
              (puthash chat-id
                       (cons action (teams4e--last-message-marker chat))
                       teams4e--read-overrides)
              (remhash chat-id teams4e--marks)
              (teams4e--execute-mark-list
               rest
               (cons (list :kind (if (eq action 'read) 'unread 'read)
                           :chat-id chat-id)
                     completed)))
            (lambda (status detail)
              (teams4e--record-completed-actions completed)
              (teams4e--refresh-visible-recent)
              (teams4e--report-error args status detail)))))
        (_
         (remhash chat-id teams4e--marks)
         (teams4e--execute-mark-list rest completed))))))

(defun teams4e-execute-marks ()
  "Execute all deferred inbox actions serially and make them undoable."
  (interactive)
  (let (items)
    (maphash (lambda (chat-id action) (push (cons chat-id action) items))
             teams4e--marks)
    (unless items (user-error "No deferred Teams actions"))
    (when (and teams4e-offline-mode
               (seq-some (lambda (item) (memq (cdr item) '(read unread)))
                         items))
      (user-error "Read-state marks cannot execute in offline cache mode"))
    (when (or (not teams4e-confirm-apply)
              (yes-or-no-p
               (format "Execute %d Teams action%s? "
                       (length items)
                       (if (= (length items) 1) "" "s"))))
      (teams4e--execute-mark-list (nreverse items) nil))))

(defun teams4e-bulk-action ()
  "Choose and execute one action for every bulk-selected inbox chat."
  (interactive)
  (unless (derived-mode-p 'teams4e-recent-mode)
    (user-error "Bulk actions work in the Teams inbox"))
  (let* ((chats (teams4e--selected-chats))
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
                    (cons (teams4e--chat-id chat) action))
                  chats)))
    (unless chats (user-error "No Teams chats selected"))
    (when (and teams4e-offline-mode (memq action '(read unread)))
      (user-error "Read-state actions cannot execute in offline cache mode"))
    (when (or (not teams4e-confirm-apply)
              (yes-or-no-p
               (format "%s %d selected Teams chat%s? "
                       choice (length chats)
                       (if (= (length chats) 1) "" "s"))))
      (if (memq action '(handled snooze clear-triage))
          (let* ((snooze-time (and (eq action 'snooze)
                                   (teams4e--read-snooze-time)))
                 (until (and snooze-time
                             (format-time-string
                              "%Y-%m-%dT%H:%M:%S%z" snooze-time))))
            (dolist (chat chats)
              (remhash (teams4e--chat-id chat)
                       teams4e--selections)
              (pcase action
                ('handled (teams4e--set-handled-local chat t))
                ('snooze (teams4e--set-snoozed-local chat until))
                ('clear-triage (teams4e--clear-triage-local chat))))
            (teams4e--save-state)
            (teams4e--render-recent)
            (message "%s %d Teams chat%s" choice (length chats)
                     (if (= (length chats) 1) "" "s")))
        (dolist (item items)
          (remhash (car item) teams4e--selections)
          (puthash (car item) action teams4e--marks))
        (teams4e--render-recent)
        (teams4e--execute-mark-list items nil)))))

(defun teams4e-undo-action ()
  "Undo the most recently completed read/favorite/triage/message action."
  (interactive)
  (when teams4e--undo-inflight
    (user-error "A Teams undo operation is already running"))
  (let ((item (car teams4e--action-history)))
    (unless item (user-error "No Teams action to undo"))
    (pcase (plist-get item :kind)
      ('favorite
       (setq teams4e--action-history
             (cdr teams4e--action-history))
       (let* ((chat-id (plist-get item :chat-id))
              (enabled (plist-get item :enabled)))
         (if enabled
             (puthash chat-id t teams4e--favorites)
           (remhash chat-id teams4e--favorites))
         (teams4e--save-state)
         (teams4e--refresh-visible-recent)
         (message "Undid Teams favorite action")))
      ('triage
       (setq teams4e--action-history
             (cdr teams4e--action-history))
       (let ((chat-id (plist-get item :chat-id))
             (handled (plist-get item :handled))
             (snoozed (plist-get item :snoozed)))
         (if handled
             (puthash chat-id handled teams4e--handled)
           (remhash chat-id teams4e--handled))
         (if snoozed
             (puthash chat-id snoozed teams4e--snoozed)
           (remhash chat-id teams4e--snoozed))
         (teams4e--save-state)
         (teams4e--refresh-visible-recent)
         (message "Undid Teams refile action")))
      ((or 'read 'unread)
       (teams4e--require-online)
       (let ((kind (plist-get item :kind))
             (chat-id (plist-get item :chat-id))
             args)
         (setq args
               (list "teams" "chat" "mark" (symbol-name kind)
                     "--chatId" chat-id)
               teams4e--undo-inflight t)
         (teams4e--run-json
          args
          (lambda (_payload)
            (setq teams4e--undo-inflight nil
                  teams4e--action-history
                  (delq item teams4e--action-history))
            (remhash chat-id teams4e--read-overrides)
            (teams4e--refresh-visible-recent)
            (message "Undid Teams read-state action"))
          (lambda (status detail)
            (setq teams4e--undo-inflight nil)
            (teams4e--report-error args status detail)))))
      ('backend
       (teams4e--require-online)
       (let ((args (plist-get item :args)))
         (setq teams4e--undo-inflight t)
         (teams4e--run-json
          args
          (lambda (_payload)
            (setq teams4e--undo-inflight nil
                  teams4e--action-history
                  (delq item teams4e--action-history))
            (teams4e--refresh-current-view)
            (message "Undid %s" (plist-get item :label)))
          (lambda (status detail)
            (setq teams4e--undo-inflight nil)
            (teams4e--report-error args status detail)))))
      (_ (user-error "This Teams action is not undoable")))))

;;; advanced.el continues with channels, message actions, and compose support.

(defun teams4e--team-label (team)
  "Return display label for TEAM."
  (or (teams4e--get team 'displayName)
      (teams4e--get team 'id)
      "Team"))

(defun teams4e--channel-label (channel)
  "Return display label for CHANNEL."
  (or (teams4e--get channel 'displayName)
      (teams4e--get channel 'id)
      "Channel"))

(defun teams4e--load-teams (callback)
  "Load joined teams and pass them to CALLBACK."
  (teams4e--run-json
   (if teams4e-offline-mode
       '("teams" "cache" "team" "list")
     '("teams" "team" "list"))
   (lambda (payload) (funcall callback (teams4e--payload-list payload)))))

(defun teams4e--load-channels (team callback)
  "Load channels for TEAM and pass them to CALLBACK."
  (let ((team-id (teams4e--get team 'id)))
    (teams4e--run-json
     (if teams4e-offline-mode
         (list "teams" "cache" "channel" "list" "--teamId" team-id)
       (list "teams" "channel" "list" "--teamId" team-id))
     (lambda (payload) (funcall callback (teams4e--payload-list payload))))))

(defun teams4e--choose-object (prompt objects label-function callback)
  "Complete among OBJECTS using LABEL-FUNCTION and call CALLBACK."
  (unless objects (user-error "No Teams objects are available"))
  (let* ((pairs
          (mapcar
           (lambda (object)
             (let ((id (or (teams4e--get object 'id) "unknown")))
               (cons (format "%s [%s]" (funcall label-function object)
                             (substring (md5 id) 0 8))
                     object)))
           objects))
         (choice (completing-read prompt (mapcar #'car pairs) nil t)))
    (funcall callback (cdr (assoc choice pairs)))))

(defun teams4e-channels ()
  "Select a joined team and channel, then open its native thread index."
  (interactive)
  (teams4e--with-status
   (lambda ()
     (teams4e--load-teams
      (lambda (teams)
        (teams4e--choose-object
         "Team: " teams #'teams4e--team-label
         (lambda (team)
           (teams4e--load-channels
            team
            (lambda (channels)
              (teams4e--choose-object
               "Channel: " channels #'teams4e--channel-label
               (lambda (channel)
                 (teams4e-open-channel team channel))))))))))))

(defun teams4e--channel-index-buffer-name (team channel)
  "Return stable index buffer name for TEAM and CHANNEL."
  (format "*Teams Channel %s/%s*"
          (substring (md5 (or (teams4e--get team 'id) "team")) 0 6)
          (substring (md5 (or (teams4e--get channel 'id) "channel")) 0 6)))

(defun teams4e--channel-thread-buffer-name (team channel root)
  "Return stable thread buffer name for TEAM CHANNEL ROOT."
  (format "*Teams Channel Thread %s*"
          (substring
           (md5 (concat (or (teams4e--get team 'id) "") "/"
                        (or (teams4e--get channel 'id) "") "/"
                        (or (teams4e--get root 'id) "")))
           0 8)))

(defun teams4e--channel-root-subject (root)
  "Return readable subject for channel ROOT."
  (or (let ((subject (teams4e--get root 'subject)))
        (and (stringp subject) (not (string-empty-p subject)) subject))
      (truncate-string-to-width
       (replace-regexp-in-string
        "[\n\r\t ]+" " " (teams4e--message-body root))
       54 nil nil "...")
      "Channel post"))

(defun teams4e--channel-root-entry (root)
  "Build one channel index row for ROOT."
  (list
   (teams4e--get root 'id)
   (vector
    (propertize (teams4e--channel-root-subject root)
                'face 'teams4e-channel-subject)
    (teams4e--message-sender root)
    (truncate-string-to-width
     (replace-regexp-in-string
      "[\n\r\t ]+" " " (teams4e--message-body root))
     55 nil nil "...")
    (teams4e--format-date (teams4e--get root 'createdDateTime)))))

(defun teams4e--render-channel-index ()
  "Render current channel root-message index, preserving selection."
  (let ((selected (tabulated-list-get-id)))
    (setq tabulated-list-entries
          (mapcar #'teams4e--channel-root-entry
                  teams4e-channel--roots)
          header-line-format
          (format "%s / %s - %d threads%s%s"
                  (teams4e--team-label teams4e-channel--team)
                  (teams4e--channel-label teams4e-channel--channel)
                  (length teams4e-channel--roots)
                  (if teams4e-offline-mode " - OFFLINE" "")
                  (if teams4e-mock-mode " - MOCK" "")))
    (tabulated-list-print t)
    (when selected
      (goto-char (point-min))
      (while (and (not (equal selected (tabulated-list-get-id)))
                  (not (eobp)))
        (forward-line 1)))
    (unless (tabulated-list-get-id)
      (goto-char (point-min))
      (forward-line 1))
    (teams4e--schedule-channel-preview)))

(defun teams4e-channel-root-at-point ()
  "Return channel root represented at point."
  (let ((id (tabulated-list-get-id)))
    (or (seq-find (lambda (root) (equal id (teams4e--get root 'id)))
                  teams4e-channel--roots)
        (user-error "No channel thread on this row"))))

(defvar teams4e-channel-index-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map tabulated-list-mode-map)
    (define-key map (kbd "RET") #'teams4e-channel-open-thread)
    (define-key map (kbd "l") #'teams4e-channel-open-thread)
    (define-key map (kbd "j") #'teams4e-channel-next)
    (define-key map (kbd "k") #'teams4e-channel-previous)
    (define-key map (kbd "g") #'teams4e-channel-refresh)
    (define-key map (kbd "c") #'teams4e-channel-compose)
    (define-key map (kbd "E") #'teams4e-channel-export-thread)
    (define-key map (kbd "Y")
                #'teams4e-channel-copy-thread-markdown)
    (define-key map (kbd "o") #'teams4e-open-current-in-browser)
    (define-key map (kbd "O") #'teams4e-open-current-in-app)
    (define-key map (kbd "/") #'teams4e-search)
    (define-key map (kbd "?") #'teams4e-dispatch)
    (define-key map (kbd "q") #'teams4e-quit)
    map)
  "Keymap for native Teams channel thread indexes.")

(define-derived-mode teams4e-channel-index-mode
  tabulated-list-mode "Teams-Channel"
  "Major mode for browsing root threads in one Teams channel."
  (setq tabulated-list-format
        [("Subject" 32 t) ("From" 20 t) ("Preview" 55 nil) ("Date" 16 t)]
        tabulated-list-padding 1)
  (add-hook 'kill-buffer-hook #'teams4e--cancel-buffer-process nil t)
  (tabulated-list-init-header))

(defun teams4e-open-channel (team channel)
  "Open native thread index for TEAM and CHANNEL."
  (let ((buffer
         (get-buffer-create
          (teams4e--channel-index-buffer-name team channel))))
    (pop-to-buffer buffer)
    (unless (derived-mode-p 'teams4e-channel-index-mode)
      (teams4e-channel-index-mode))
    (setq teams4e-channel--team team
          teams4e-channel--channel channel
          header-line-format "Loading channel threads...")
    (teams4e-channel-refresh)))

(defun teams4e-channel-refresh ()
  "Refresh root posts in the current Teams channel."
  (interactive)
  (unless (derived-mode-p 'teams4e-channel-index-mode)
    (user-error "Not in a Teams channel index"))
  (teams4e--cancel-process teams4e--process)
  (cl-incf teams4e-channel--request-id)
  (let ((buffer (current-buffer))
        (request-id teams4e-channel--request-id)
        (team-id (teams4e--get teams4e-channel--team 'id))
        (channel-id (teams4e--get teams4e-channel--channel 'id))
        args)
    (setq args
          (if teams4e-offline-mode
              (list "teams" "cache" "channel" "message" "list"
                    "--teamId" team-id "--channelId" channel-id
                    "--limit" "1000000")
            (list "teams" "channel" "message" "list"
                  "--teamId" team-id "--channelId" channel-id)))
    (setq header-line-format "Loading channel threads...")
    (setq
     teams4e--process
     (teams4e--run-json
      args
      (lambda (payload)
        (when (buffer-live-p buffer)
          (with-current-buffer buffer
            (when (= request-id teams4e-channel--request-id)
              (setq teams4e--process nil
                    teams4e-channel--roots
                    (teams4e--normalize-messages
                     (teams4e--payload-list payload)))
              (teams4e--render-channel-index)))))
      (lambda (status detail)
        (when (buffer-live-p buffer)
          (with-current-buffer buffer
            (when (= request-id teams4e-channel--request-id)
              (setq teams4e--process nil
                    header-line-format
                    "Teams channel load failed - see *M365 Errors*"))))
        (teams4e--report-error args status detail))))))

(defun teams4e--channel-move (delta)
  "Move DELTA channel root rows and optionally preview the selected thread."
  (let ((origin (point)))
    (forward-line delta)
    (beginning-of-line)
    (unless (tabulated-list-get-id) (goto-char origin))
    (teams4e--schedule-channel-preview)))

(defun teams4e--schedule-channel-preview ()
  "Preview the selected channel thread after the configured idle delay."
  (when (timerp teams4e--preview-timer)
    (cancel-timer teams4e--preview-timer))
  (setq teams4e--preview-timer nil)
  (when (and teams4e-preview-on-move (tabulated-list-get-id))
    (let ((buffer (current-buffer))
          (root-id (tabulated-list-get-id)))
      (setq teams4e--preview-timer
            (run-with-idle-timer
             teams4e-preview-delay nil
             (lambda ()
               (when (buffer-live-p buffer)
                 (with-current-buffer buffer
                   (setq teams4e--preview-timer nil)
                   (when (equal root-id (tabulated-list-get-id))
                     (teams4e-open-channel-thread
                      teams4e-channel--team
                      teams4e-channel--channel
                      (teams4e-channel-root-at-point) t))))))))))

(defun teams4e-channel-next ()
  "Move to and preview the next channel thread."
  (interactive)
  (teams4e--channel-move 1))

(defun teams4e-channel-previous ()
  "Move to and preview the previous channel thread."
  (interactive)
  (teams4e--channel-move -1))

(defun teams4e-channel-open-thread ()
  "Open and focus the selected channel thread."
  (interactive)
  (teams4e-open-channel-thread
   teams4e-channel--team teams4e-channel--channel
   (teams4e-channel-root-at-point)))

(defvar teams4e-channel-thread-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (define-key map (kbd "g") #'teams4e-channel-thread-refresh)
    (define-key map (kbd "S") #'teams4e-toggle-message-order)
    (define-key map (kbd "j") #'teams4e-channel-thread-next)
    (define-key map (kbd "k") #'teams4e-channel-thread-previous)
    (define-key map (kbd "M-j") #'teams4e-chat-next-message)
    (define-key map (kbd "M-k") #'teams4e-chat-previous-message)
    (define-key map (kbd "R") #'teams4e-channel-reply)
    (define-key map (kbd "c") #'teams4e-channel-compose)
    (define-key map (kbd "C") #'teams4e-channel-compose)
    (define-key map (kbd "+") #'teams4e-message-react)
    (define-key map (kbd "-") #'teams4e-message-unreact)
    (define-key map (kbd "e") #'teams4e-message-edit)
    (define-key map (kbd "d") #'teams4e-message-delete)
    (define-key map (kbd "f") #'teams4e-message-forward)
    (define-key map (kbd "F") #'teams4e-message-forward)
    (define-key map (kbd "a") #'teams4e-attachment-download)
    (define-key map (kbd "A") #'teams4e-attachment-preview)
    (define-key map (kbd "E") #'teams4e-channel-export-thread)
    (define-key map (kbd "Y")
                #'teams4e-channel-copy-thread-markdown)
    (define-key map (kbd "o") #'teams4e-open-current-in-browser)
    (define-key map (kbd "O") #'teams4e-open-current-in-app)
    (define-key map (kbd "/") #'teams4e-search)
    (define-key map (kbd "?") #'teams4e-dispatch)
    (define-key map (kbd "u") #'teams4e-undo-action)
    (define-key map (kbd "h") #'teams4e-channel-back-to-index)
    (define-key map (kbd "b") #'teams4e-channel-back-to-index)
    (define-key map (kbd "q") #'teams4e-channel-view-quit)
    map)
  "Keymap for native Teams channel thread buffers.")

(define-derived-mode teams4e-channel-thread-mode
  teams4e-read-mode "Teams-Read"
  "Major mode for reading one root post and its channel replies."
  nil)

(defun teams4e--display-channel-thread (buffer preview)
  "Display channel thread BUFFER beside its index, preserving PREVIEW focus."
  (let* ((index-buffer
          (get-buffer
           (teams4e--channel-index-buffer-name
            teams4e-channel--team teams4e-channel--channel)))
         (index-window (and index-buffer (get-buffer-window index-buffer t))))
    (if (not (window-live-p index-window))
        (if preview (display-buffer buffer) (pop-to-buffer buffer))
      (let ((right (or (get-buffer-window buffer t)
                       (window-in-direction 'right index-window)
                       (split-window index-window nil 'right))))
        (set-window-buffer right buffer)
        (unless preview (select-window right))))))

(defun teams4e-open-channel-thread (team channel root &optional preview)
  "Open ROOT and all replies from TEAM CHANNEL; keep index focus for PREVIEW."
  (let ((buffer (get-buffer-create teams4e--read-buffer-name)))
    (with-current-buffer buffer
      (unless (derived-mode-p 'teams4e-channel-thread-mode)
        (when (derived-mode-p 'teams4e-read-mode)
          (teams4e--cancel-buffer-process))
        (teams4e-channel-thread-mode))
      (let ((same-thread
             (and teams4e-channel--team
                  teams4e-channel--channel
                  teams4e-channel--root
                  (equal (teams4e--get teams4e-channel--team 'id)
                         (teams4e--get team 'id))
                  (equal (teams4e--get teams4e-channel--channel 'id)
                         (teams4e--get channel 'id))
                  (equal (teams4e--get teams4e-channel--root 'id)
                         (teams4e--get root 'id)))))
        (setq teams4e-channel--team team
              teams4e-channel--channel channel
              teams4e-channel--root root
              teams4e--automatic-preview-p (not (null preview))
              teams4e--jump-to-bottom-on-render (not preview))
        (unless same-thread
          (teams4e--cancel-image-loads)
          (setq teams4e-channel--messages nil)
          (let ((inhibit-read-only t))
            (erase-buffer)
            (insert (format "Loading %s / %s...\n"
                            (teams4e--channel-label channel)
                            (teams4e--channel-root-subject root))))))
      (teams4e-channel-thread-refresh))
    (let ((teams4e-channel--team team)
          (teams4e-channel--channel channel))
      (teams4e--display-channel-thread buffer preview))
    (teams4e--close-other-readers buffer)))

(defun teams4e--render-channel-thread ()
  "Render current channel root and replies with stable message properties."
  (let* ((inhibit-read-only t)
         (pending-message-id teams4e-channel--pending-message-id)
         (jump-to-bottom (and teams4e--jump-to-bottom-on-render
                              (not pending-message-id)))
         (message-id
          (or pending-message-id
              (unless teams4e--jump-to-bottom-on-render
                (teams4e--get (teams4e-message-at-point) 'id))))
         last-day)
    (teams4e--cancel-image-loads)
    (erase-buffer)
    (insert (propertize
             (format "%s / %s\n%s"
                     (teams4e--team-label
                      teams4e-channel--team)
                     (teams4e--channel-label
                      teams4e-channel--channel)
                     (teams4e--channel-root-subject
                      teams4e-channel--root))
             'face '(:height 1.15 :weight bold)))
    (insert "\n\n")
    (dolist (message
             (teams4e--messages-for-display
              teams4e-channel--messages))
      (let* ((created (or (teams4e--get message 'createdDateTime) ""))
             (day (car (split-string created "T"))))
        (unless (equal day last-day)
          (setq last-day day)
          (teams4e--insert-day-separator created))
        (teams4e--insert-message message)))
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
    (setq teams4e-channel--pending-message-id nil
          teams4e--jump-to-bottom-on-render nil
          header-line-format
          (format "%s / %s - %d messages - %s%s%s"
                  (teams4e--team-label teams4e-channel--team)
                  (teams4e--channel-label teams4e-channel--channel)
                  (length teams4e-channel--messages)
                  (teams4e--message-order-label)
                  (if teams4e-offline-mode " - OFFLINE" "")
                  (if teams4e-mock-mode " - MOCK" "")))))

(defun teams4e-channel-thread-refresh ()
  "Load all replies and rerender the current channel thread."
  (interactive)
  (unless (derived-mode-p 'teams4e-channel-thread-mode)
    (user-error "Not in a Teams channel thread"))
  (teams4e--cancel-process teams4e--process)
  (cl-incf teams4e-channel--request-id)
  (let ((buffer (current-buffer))
        (request-id teams4e-channel--request-id)
        (team-id (teams4e--get teams4e-channel--team 'id))
        (channel-id (teams4e--get teams4e-channel--channel 'id))
        (root-id (teams4e--get teams4e-channel--root 'id))
        args)
    (setq args
          (if teams4e-offline-mode
              (list "teams" "cache" "channel" "reply" "list"
                    "--teamId" team-id "--channelId" channel-id
                    "--messageId" root-id "--limit" "1000000")
            (list "teams" "channel" "reply" "list"
                  "--teamId" team-id "--channelId" channel-id
                  "--messageId" root-id)))
    (setq header-line-format "Loading channel replies...")
    (setq
     teams4e--process
     (teams4e--run-json
      args
      (lambda (payload)
        (when (buffer-live-p buffer)
          (with-current-buffer buffer
            (when (and (= request-id teams4e-channel--request-id)
                       (derived-mode-p
                        'teams4e-channel-thread-mode)
                       (equal team-id
                              (teams4e--get
                               teams4e-channel--team 'id))
                       (equal channel-id
                              (teams4e--get
                               teams4e-channel--channel 'id))
                       (equal root-id
                              (teams4e--get
                               teams4e-channel--root 'id)))
              (setq teams4e--process nil
                    teams4e-channel--messages
                    (teams4e--normalize-messages
                     (cons teams4e-channel--root
                           (teams4e--payload-list payload))))
              (teams4e--render-channel-thread)))))
      (lambda (status detail)
        (when (buffer-live-p buffer)
          (with-current-buffer buffer
            (when (and (= request-id teams4e-channel--request-id)
                       (derived-mode-p
                        'teams4e-channel-thread-mode)
                       (equal team-id
                              (teams4e--get
                               teams4e-channel--team 'id))
                       (equal channel-id
                              (teams4e--get
                               teams4e-channel--channel 'id))
                       (equal root-id
                              (teams4e--get
                               teams4e-channel--root 'id)))
              (setq teams4e--process nil
                    header-line-format
                    "Teams channel replies failed - see *M365 Errors*"))))
        (teams4e--report-error args status detail))))))

(defun teams4e-channel-target ()
  "Return compose target for the current channel context."
  (list :team-id (teams4e--get teams4e-channel--team 'id)
        :channel-id (teams4e--get teams4e-channel--channel 'id)
        :label (format "%s / %s"
                       (teams4e--team-label
                        teams4e-channel--team)
                       (teams4e--channel-label
                        teams4e-channel--channel))))

(defun teams4e-channel-compose ()
  "Compose a new root post in the current channel."
  (interactive)
  (teams4e--require-online)
  (teams4e--open-compose (teams4e-channel-target)))

(defun teams4e-channel-reply ()
  "Compose a reply under the current channel root."
  (interactive)
  (teams4e--require-online)
  (teams4e--open-compose
   (teams4e-channel-target) teams4e-channel--root))

(defun teams4e-channel-back-to-index ()
  "Return focus to the current channel root index."
  (interactive)
  (let ((buffer
         (get-buffer
          (teams4e--channel-index-buffer-name
           teams4e-channel--team teams4e-channel--channel))))
    (if-let ((window (and buffer (get-buffer-window buffer t))))
        (select-window window)
      (teams4e-open-channel
       teams4e-channel--team teams4e-channel--channel))))

(defun teams4e-channel-view-quit ()
  "Close the Teams channel reader pane and return to its root index."
  (interactive)
  (teams4e--close-reader-to-index
   (get-buffer
    (teams4e--channel-index-buffer-name
     teams4e-channel--team teams4e-channel--channel))))

(defun teams4e-channel-thread-relative (delta)
  "Open the channel root DELTA rows from the current thread."
  (interactive "p")
  (unless (derived-mode-p 'teams4e-channel-thread-mode)
    (user-error "Open a Teams channel thread first"))
  (let* ((team teams4e-channel--team)
         (channel teams4e-channel--channel)
         (root-id (teams4e--get teams4e-channel--root 'id))
         (index-buffer
          (get-buffer (teams4e--channel-index-buffer-name team channel)))
         target)
    (unless (buffer-live-p index-buffer)
      (user-error "Open the Teams channel index before moving between threads"))
    (with-current-buffer index-buffer
      (when-let ((target-id
                  (teams4e--tabulated-neighbor-id root-id delta)))
        (setq target
              (seq-find
               (lambda (root) (equal target-id (teams4e--get root 'id)))
               teams4e-channel--roots))))
    (unless target
      (user-error "No Teams channel thread in that direction"))
    (teams4e-open-channel-thread team channel target)))

(defun teams4e-channel-thread-next ()
  "Open the next root from the current Teams channel thread."
  (interactive)
  (teams4e-channel-thread-relative 1))

(defun teams4e-channel-thread-previous ()
  "Open the previous root from the current Teams channel thread."
  (interactive)
  (teams4e-channel-thread-relative -1))

(defun teams4e--channel-thread-context ()
  "Return complete-fetch context for the channel thread at point."
  (unless (or (derived-mode-p 'teams4e-channel-thread-mode)
              (derived-mode-p 'teams4e-channel-index-mode))
    (user-error "Open a Teams channel or channel thread first"))
  (let* ((team teams4e-channel--team)
         (channel teams4e-channel--channel)
         (root (if (derived-mode-p 'teams4e-channel-thread-mode)
                   teams4e-channel--root
                 (teams4e-channel-root-at-point)))
         (team-id (teams4e--get team 'id))
         (channel-id (teams4e--get channel 'id))
         (root-id (teams4e--get root 'id))
         (pseudo-chat
          `((id . ,(format "%s/%s/%s" team-id channel-id root-id))
            (topic . ,(format "%s - %s"
                              (teams4e--channel-label channel)
                              (teams4e--channel-root-subject root)))
            (webUrl . ,(teams4e--get root 'webUrl))))
         (args
          (if teams4e-offline-mode
              (list "teams" "cache" "channel" "reply" "list"
                    "--teamId" team-id "--channelId" channel-id
                    "--messageId" root-id "--limit" "1000000")
            (list "teams" "channel" "reply" "list"
                  "--teamId" team-id "--channelId" channel-id
                  "--messageId" root-id))))
    (list :chat pseudo-chat :root root :args args)))

(defun teams4e--fetch-channel-thread (callback)
  "Fetch the complete current channel thread and invoke CALLBACK.

CALLBACK receives a chat-like metadata object followed by chronological root
and reply messages."
  (let* ((context (teams4e--channel-thread-context))
         (chat (plist-get context :chat))
         (root (plist-get context :root))
         (args (plist-get context :args)))
    (teams4e--run-json
     args
     (lambda (payload)
       (funcall callback chat
                (teams4e--normalize-messages
                 (cons root (teams4e--payload-list payload))))))))

(defun teams4e-channel-export-thread (&optional open after-export)
  "Export complete channel thread at point; with OPEN, visit it.

Call AFTER-EXPORT with the saved path when it is non-nil."
  (interactive "P")
  (message "Exporting complete Teams channel thread...")
  (teams4e--fetch-channel-thread
   (lambda (chat messages)
     (teams4e--finish-thread-export
      chat messages open after-export))))

(defun teams4e-channel-copy-thread-markdown ()
  "Fetch and copy the complete channel thread at point as Markdown."
  (interactive)
  (message "Copying complete Teams channel thread...")
  (teams4e--fetch-channel-thread
   #'teams4e--copy-thread-markdown))

(defun teams4e-export-current-thread (&optional open after-export)
  "Export the current channel thread, or select/export a chat.

With prefix argument OPEN, visit the generated Markdown file.  Call
AFTER-EXPORT with its saved path when that callback is non-nil."
  (interactive "P")
  (if (or (derived-mode-p 'teams4e-channel-thread-mode)
          (derived-mode-p 'teams4e-channel-index-mode))
      (teams4e-channel-export-thread open after-export)
    (if-let ((chat (teams4e--chat-at-point)))
        (teams4e--export-thread chat open after-export)
      (teams4e--select-chat
       (lambda (selected)
         (teams4e--export-thread selected open after-export))))))

(defun teams4e-copy-current-thread-markdown ()
  "Copy the current channel thread, or select and copy a chat, as Markdown."
  (interactive)
  (if (or (derived-mode-p 'teams4e-channel-thread-mode)
          (derived-mode-p 'teams4e-channel-index-mode))
      (teams4e-channel-copy-thread-markdown)
    (teams4e-copy-thread-markdown)))

(defun teams4e--thread-analysis-agent-config ()
  "Resolve `teams4e-thread-analysis-agent' to an agent config."
  (unless (require 'agent-shell nil t)
    (user-error "agent-shell is unavailable; install and configure agent-shell"))
  (let* ((identifier teams4e-thread-analysis-agent)
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
       "No agent-shell config `%s'; customize teams4e-thread-analysis-agent"
       identifier))
    config))

(defun teams4e--start-thread-analysis (path config)
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

(defun teams4e-analyze-current-thread ()
  "Export the complete current Teams thread and analyze it in a new agent-shell."
  (interactive)
  (let ((config (teams4e--thread-analysis-agent-config)))
    (teams4e-export-current-thread
     nil
     (lambda (path)
       (teams4e--start-thread-analysis path config)))))

(defun teams4e--channel-capture-context
    (team channel root &optional message)
  "Build complete Org metadata for TEAM CHANNEL ROOT and selected MESSAGE."
  (let* ((team-name (teams4e--team-label team))
         (channel-name (teams4e--channel-label channel))
         (subject (teams4e--channel-root-subject root))
         (root-url (teams4e--get root 'webUrl))
         (message-url (teams4e--get message 'webUrl)))
    `((kind . "channel")
      (title . ,(format "%s / %s: %s" team-name channel-name subject))
      (conversationType . "Channel")
      (teamId . ,(teams4e--get team 'id))
      (teamName . ,team-name)
      (channelId . ,(teams4e--get channel 'id))
      (channelName . ,channel-name)
      (threadId . ,(teams4e--get root 'id))
      (conversationUrl . ,(or root-url (teams4e--get channel 'webUrl)))
      (selectedMessageId . ,(teams4e--get message 'id))
      (selectedMessageUrl . ,message-url)
      (sourceUrl . ,(or message-url root-url
                        (teams4e--get channel 'webUrl)))
      (updated . ,(or (teams4e--get root 'lastModifiedDateTime)
                      (teams4e--get root 'createdDateTime))))))

(defun teams4e-capture-channel-thread ()
  "Fetch and start Org capture for the complete channel thread at point."
  (interactive)
  (unless (or (derived-mode-p 'teams4e-channel-index-mode)
              (derived-mode-p 'teams4e-channel-thread-mode))
    (user-error "Open a Teams channel thread first"))
  (let* ((team teams4e-channel--team)
         (channel teams4e-channel--channel)
         (root (if (derived-mode-p 'teams4e-channel-index-mode)
                   (teams4e-channel-root-at-point)
                 teams4e-channel--root))
         (message (if (derived-mode-p 'teams4e-channel-thread-mode)
                      (or (teams4e-message-at-point) root)
                    root))
         (team-id (teams4e--get team 'id))
         (channel-id (teams4e--get channel 'id))
         (root-id (teams4e--get root 'id))
         (context
          (teams4e--channel-capture-context
           team channel root message))
         (args
          (if teams4e-offline-mode
              (list "teams" "cache" "channel" "reply" "list"
                    "--teamId" team-id "--channelId" channel-id
                    "--messageId" root-id "--limit" "1000000")
            (list "teams" "channel" "reply" "list"
                  "--teamId" team-id "--channelId" channel-id
                  "--messageId" root-id))))
    (message "Preparing complete Teams channel thread for Org capture...")
    (teams4e--run-json
     args
     (lambda (payload)
       (teams4e--start-thread-org-capture
        context
        (teams4e--normalize-messages
         (cons root (teams4e--payload-list payload))))))))

(defun teams4e-capture-current-thread ()
  "Capture the complete selected chat or channel thread through Org capture."
  (interactive)
  (cond
   ((or (derived-mode-p 'teams4e-channel-index-mode)
        (derived-mode-p 'teams4e-channel-thread-mode))
    (teams4e-capture-channel-thread))
   ((teams4e--chat-at-point)
    (let* ((chat (teams4e--chat-at-point))
           (message
            (if (derived-mode-p 'teams4e-chat-mode)
                (teams4e-message-at-point)
              (teams4e--get chat 'lastMessagePreview))))
      (teams4e-capture-chat-thread chat message)))
   (t
    (teams4e--select-chat
     (lambda (chat)
       (teams4e-capture-chat-thread
       chat (teams4e--get chat 'lastMessagePreview)))))))

(defun teams4e--chat-summary-message (chat)
  "Return the latest known message used for compact CHAT capture."
  (or (and (derived-mode-p 'teams4e-chat-mode)
           (car (last teams4e--messages)))
      (teams4e--get chat 'lastMessagePreview)))

(defun teams4e--capture-chat-summary-or-jump (chat message)
  "Jump to CHAT's existing Org capture, or create a summary for MESSAGE."
  (let ((context (teams4e--chat-capture-context chat message)))
    (if (teams4e--jump-to-capture-context context)
        (message "Opened the existing Teams Org capture")
      (teams4e-capture-chat-summary chat message))))

(defun teams4e--current-capture-context ()
  "Return capture context for the selected Teams conversation and message."
  (cond
   ((or (derived-mode-p 'teams4e-channel-index-mode)
        (derived-mode-p 'teams4e-channel-thread-mode))
    (let* ((root (if (derived-mode-p 'teams4e-channel-index-mode)
                     (teams4e-channel-root-at-point)
                   teams4e-channel--root))
           (message (if (derived-mode-p 'teams4e-channel-thread-mode)
                        (or (teams4e-message-at-point) root)
                      root)))
      (teams4e--channel-capture-context
       teams4e-channel--team teams4e-channel--channel
       root message)))
   ((teams4e--chat-at-point)
    (let ((chat (teams4e--chat-at-point)))
      (teams4e--chat-capture-context
       chat (teams4e--chat-summary-message chat))))))

(defun teams4e-jump-to-capture ()
  "Open the Org entry linked to the current Teams conversation or message."
  (interactive)
  (let ((context (teams4e--current-capture-context)))
    (unless context (user-error "No Teams conversation here"))
    (unless (teams4e--jump-to-capture-context context)
      (user-error "This Teams conversation has not been captured to Org"))))

(defun teams4e--vtt-to-text (content)
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
                      (teams4e--html-to-text (match-string 2 line)))
              lines))
       (t (push (teams4e--html-to-text line) lines))))
    (string-join (nreverse lines) "\n\n")))

(defun teams4e-meeting-transcript ()
  "Fetch and display the latest transcript for the current meeting chat."
  (interactive)
  (teams4e--require-online)
  (let* ((chat (or (teams4e--chat-at-point)
                   (user-error "No Teams chat here")))
         (chat-id (teams4e--chat-id chat))
         (args (list "teams" "meeting" "transcript" "--chatId" chat-id)))
    (unless (teams4e--meeting-chat-p chat)
      (user-error "The current Teams conversation is not a meeting chat"))
    (message "Loading Teams meeting transcript...")
    (teams4e--run-json
     args
     (lambda (payload)
       (let* ((buffer (get-buffer-create
                       teams4e--transcript-buffer-name))
              (event (teams4e--get payload 'event))
              (meeting (teams4e--get payload 'meeting))
              (transcript (teams4e--get payload 'transcript))
              (title (or (teams4e--get event 'subject)
                         (teams4e--get meeting 'subject)
                         (teams4e--chat-label chat)))
              (created (teams4e--get transcript 'createdDateTime))
              (body (teams4e--vtt-to-text
                     (teams4e--get payload 'content))))
         (with-current-buffer buffer
           (let ((inhibit-read-only t))
             (erase-buffer)
             (insert (propertize title 'face '(:height 1.2 :weight bold)) "\n")
             (when created
               (insert (propertize
                        (format "Transcript created %s\n"
                                (teams4e--format-date created t))
                        'face 'shadow)))
             (insert "\n" (if (string-empty-p body)
                                "[Transcript has no text]" body) "\n")
             (goto-char (point-min))
             (special-mode)
             (visual-line-mode 1)))
         (pop-to-buffer buffer)))
     (lambda (status detail)
       (teams4e--report-error args status detail)
       (message "Teams transcript unavailable; see *M365 Errors*")))))

(defconst teams4e--proposal-manual-choice "Enter a time manually")
(defconst teams4e--proposal-range-choice "Search a different date range")
(defconst teams4e--proposal-unrestricted-choice
  "Include evenings and weekends")

(defun teams4e--proposal-event-id (chat)
  "Return the linked calendar event ID available for meeting CHAT."
  (or (teams4e--meeting-event-id chat)
      (teams4e--dig (teams4e--get chat 'meetingContext)
                     'onlineMeetingInfo 'calendarEventId)
      (teams4e--get (teams4e--meeting-event chat) 'id)))

(defun teams4e--proposal-day-start (time)
  "Return local midnight on the calendar day containing TIME."
  (pcase-let ((`(,_second ,_minute ,_hour ,day ,month ,year . ,_)
               (decode-time time)))
    (encode-time 0 0 0 day month year)))

(defun teams4e--proposal-default-window (chat)
  "Return the default availability search window for meeting CHAT."
  (let* ((now (current-time))
         (meeting-start (or (teams4e--meeting-start-time chat) now))
         (day-start (teams4e--proposal-day-start meeting-start))
         (earliest (teams4e--proposal-day-start
                    (time-subtract day-start (days-to-time 1))))
         (start (if (time-less-p now earliest) earliest now))
         (end (time-add day-start
                        (days-to-time
                         (max 1 teams4e-meeting-proposal-search-days)))))
    (when (not (time-less-p start end))
      (setq end (time-add start
                          (days-to-time
                           (max 1 teams4e-meeting-proposal-search-days)))))
    (list start end)))

(defun teams4e--proposal-read-window ()
  "Read and return a custom availability search window."
  (require 'org)
  (let* ((start (org-read-date nil t nil "Search alternatives from: "))
         (end (org-read-date
               nil t nil "Search alternatives until (date/time): "
               (time-add start
                         (days-to-time
                          (max 1 teams4e-meeting-proposal-search-days))))))
    (unless (time-less-p start end)
      (user-error "The search end must be after its start"))
    (list start end)))

(defun teams4e--proposal-utc-string (time)
  "Format Emacs TIME as an ISO UTC string for the Teams backend."
  (format-time-string "%Y-%m-%dT%H:%M:%SZ" time t))

(defun teams4e--proposal-slot (start end)
  "Build one Graph-style time slot from Emacs START and END times."
  `((start . ((dateTime . ,(format-time-string
                             "%Y-%m-%dT%H:%M:%S" start t))
              (timeZone . "UTC")))
    (end . ((dateTime . ,(format-time-string
                           "%Y-%m-%dT%H:%M:%S" end t))
            (timeZone . "UTC")))))

(defun teams4e--proposal-duration-seconds (chat)
  "Return meeting CHAT's duration, falling back to thirty minutes."
  (let ((start (teams4e--meeting-start-time chat))
        (end (teams4e--meeting-end-time chat)))
    (if (and start end (time-less-p start end))
        (float-time (time-subtract end start))
      (* 30 60))))

(defun teams4e--proposal-manual-slot (chat)
  "Read a manual start and preserve the duration of meeting CHAT."
  (require 'org)
  (let* ((duration (round (teams4e--proposal-duration-seconds chat)))
         (minutes (/ duration 60.0))
         (duration-label
          (if (zerop (% duration 60))
              (format "%d min" (/ duration 60))
            (format "%.1f min" minutes)))
         (start (org-read-date
                 nil t nil
                 (format "New meeting start (duration stays %s): "
                         duration-label)))
         (end (time-add start (seconds-to-time duration))))
    (unless (time-less-p (current-time) start)
      (user-error "The proposed meeting time must be in the future"))
    (teams4e--proposal-slot start end)))

(defun teams4e--proposal-contact-name (event email)
  "Return EVENT contact name matching EMAIL, or EMAIL itself."
  (let ((wanted (and (stringp email) (downcase email)))
        (contacts
         (append (and (teams4e--get event 'organizer)
                      (list (teams4e--get event 'organizer)))
                 (teams4e--get event 'attendees))))
    (or
     (seq-some
      (lambda (contact)
        (let ((address (teams4e--dig contact 'emailAddress 'address)))
          (when (and wanted (stringp address)
                     (string-equal wanted (downcase address)))
            (or (teams4e--dig contact 'emailAddress 'name) address))))
      contacts)
     email
     "attendee")))

(defun teams4e--proposal-unavailable-label (suggestion event)
  "Return a concise unavailable-attendee label for SUGGESTION and EVENT."
  (let (unavailable)
    (let ((availability (teams4e--get suggestion 'organizerAvailability)))
      (unless (or (null availability) (equal availability "free"))
        (push (format "you %s" availability) unavailable)))
    (dolist (entry (teams4e--get suggestion 'attendeeAvailability))
      (let ((availability (teams4e--get entry 'availability)))
        (unless (or (null availability) (equal availability "free"))
          (let* ((email (teams4e--dig entry 'attendee 'emailAddress 'address))
                 (name (teams4e--proposal-contact-name event email)))
            (push (format "%s %s" name availability) unavailable)))))
    (setq unavailable (nreverse unavailable))
    (if unavailable
        (let* ((shown (seq-take unavailable 3))
               (remaining (- (length unavailable) (length shown))))
          (concat (string-join shown ", ")
                  (if (> remaining 0) (format " +%d" remaining) "")))
      "all shown free")))

(defun teams4e--proposal-suggestion-label (suggestion event index)
  "Return completion label for SUGGESTION on EVENT at INDEX."
  (let* ((slot (teams4e--get suggestion 'meetingTimeSlot))
         (time-label (or (teams4e--meeting-slot-time-label slot)
                         "Unknown time"))
         (confidence (or (teams4e--get suggestion 'confidence) 0)))
    (format "%d. %s | %s%% confidence | %s"
            index time-label confidence
            (teams4e--proposal-unavailable-label suggestion event))))

(defun teams4e--meeting-refresh-displays (chat)
  "Refresh headers and the singleton reader after changing meeting CHAT."
  (teams4e--refresh-visible-recent)
  (when-let ((reader (get-buffer teams4e--read-buffer-name)))
    (with-current-buffer reader
      (when (and (derived-mode-p 'teams4e-chat-mode)
                 teams4e--chat
                 (equal (teams4e--chat-id chat)
                        (teams4e--chat-id teams4e--chat)))
        (setq teams4e--meeting-context
              (teams4e--get chat 'meetingContext))
        (teams4e--render-chat)))))

(defalias 'teams4e--proposal-refresh-displays
  #'teams4e--meeting-refresh-displays)

(defun teams4e--proposal-send (chat event-id slot &optional after-send)
  "Send SLOT as a proposed new time for CHAT's linked EVENT-ID.

Invoke AFTER-SEND with the backend payload after a successful mutation."
  (let* ((old-label (or (teams4e--meeting-time-label chat) "current time"))
         (new-label (or (teams4e--meeting-slot-time-label slot) "new time"))
         (organizer
          (or (teams4e--dig (teams4e--meeting-event chat)
                             'organizer 'emailAddress 'name)
              "organizer"))
         (comment
          (read-string
           (format "Note to %s for %s (%s -> %s): "
                   organizer (teams4e--chat-label chat)
                   old-label new-label)
           teams4e-meeting-proposal-default-comment))
         (start (teams4e--event-date-time slot 'start))
         (end (teams4e--event-date-time slot 'end))
         (args (list "teams" "meeting" "propose" "send"
                     "--eventId" event-id
                     "--start" start
                     "--end" end
                     "--comment" comment)))
    (message "Sending new-time proposal for %s..." (teams4e--chat-label chat))
    (teams4e--run-json
     args
     (lambda (payload)
       (let ((event (teams4e--get payload 'event))
             (proposal (teams4e--get payload 'proposal)))
         (teams4e--apply-meeting-context
          chat `((event . ,event) (proposal . ,proposal)))
         (teams4e--meeting-refresh-displays chat)
         (message "Proposed %s for %s"
                  (or (teams4e--meeting-slot-time-label proposal) new-label)
                  (teams4e--chat-label chat))
         (when after-send (funcall after-send payload))))
     (lambda (status detail)
       (teams4e--report-error args status detail)
       (message "New-time proposal was not sent: %s"
                (truncate-string-to-width
                 (string-trim
                  (or (teams4e--redacted-detail args detail)
                      "unknown backend error"))
                 140 nil nil t))))))

(defun teams4e--proposal-request-suggestions
    (chat event-id window activity-domain)
  "Find alternate times for CHAT and EVENT-ID inside WINDOW and ACTIVITY-DOMAIN."
  (let* ((origin (current-buffer))
         (start (car window))
         (end (cadr window))
         (args
          (list "teams" "meeting" "propose" "suggest"
                "--eventId" event-id
                "--searchStart" (teams4e--proposal-utc-string start)
                "--searchEnd" (teams4e--proposal-utc-string end)
                "--activityDomain" (symbol-name activity-domain)
                "--maxCandidates"
                (number-to-string
                 (max 1 teams4e-meeting-proposal-max-candidates))
                "--minimumConfidence"
                (number-to-string
                 (max 0 teams4e-meeting-proposal-minimum-confidence)))))
    (message "Finding available times for %s..." (teams4e--chat-label chat))
    (teams4e--run-json
     args
     (lambda (payload)
       (when (buffer-live-p origin)
         (with-current-buffer origin
           (teams4e--proposal-choose
            chat event-id payload window activity-domain))))
     (lambda (status detail)
       (teams4e--report-error args status detail)
       (message "Cannot propose a new time for %s: %s"
                (teams4e--chat-label chat)
                (truncate-string-to-width
                 (string-trim (or detail "unknown backend error"))
                 120 nil nil t))))))

(defun teams4e--proposal-choose
    (chat event-id payload window activity-domain)
  "Choose one proposal from PAYLOAD for CHAT and EVENT-ID.

WINDOW and ACTIVITY-DOMAIN describe the request and support broadening it."
  (let* ((event (teams4e--get payload 'event))
         (suggestions (teams4e--get payload 'suggestions))
         (pairs
          (cl-loop for suggestion in suggestions
                   for index from 1
                   collect
                   (cons (teams4e--proposal-suggestion-label
                          suggestion event index)
                         suggestion)))
         (suggestion-error (teams4e--get payload 'suggestionError))
         (special
          (if suggestion-error
              (list teams4e--proposal-manual-choice
                    teams4e--proposal-range-choice)
            (append
             (unless (eq activity-domain 'unrestricted)
               (list teams4e--proposal-unrestricted-choice))
             (list teams4e--proposal-range-choice
                   teams4e--proposal-manual-choice))))
         (reason
          (or suggestion-error
              (teams4e--get payload 'emptySuggestionsReason)))
         (prompt
          (if pairs
              (format "Propose new time for %s: "
                      (teams4e--chat-label chat))
            (format "No ranked alternatives for %s%s: "
                    (teams4e--chat-label chat)
                    (if (and (stringp reason) (not (string-empty-p reason)))
                        (format " (%s)"
                                (truncate-string-to-width reason 70 nil nil t))
                      ""))))
         (choice (completing-read
                  prompt (append (mapcar #'car pairs) special) nil t)))
    (when event
      (teams4e--apply-meeting-context chat `((event . ,event))))
    (cond
     ((equal choice teams4e--proposal-manual-choice)
      (teams4e--proposal-send
       chat event-id (teams4e--proposal-manual-slot chat)))
     ((equal choice teams4e--proposal-range-choice)
      (teams4e--proposal-request-suggestions
       chat event-id (teams4e--proposal-read-window) activity-domain))
     ((equal choice teams4e--proposal-unrestricted-choice)
      (teams4e--proposal-request-suggestions
       chat event-id window 'unrestricted))
     (t
      (let ((suggestion (cdr (assoc choice pairs))))
        (unless suggestion (user-error "No meeting time selected"))
        (teams4e--proposal-send
         chat event-id (teams4e--get suggestion 'meetingTimeSlot)))))))

(defun teams4e--proposal-start (chat)
  "Start the new-time proposal flow for meeting CHAT."
  (if-let ((event-id (teams4e--proposal-event-id chat)))
      (teams4e--proposal-request-suggestions
       chat event-id (teams4e--proposal-default-window chat)
       teams4e-meeting-proposal-activity-domain)
    (message "Resolving linked calendar event for %s..."
             (teams4e--chat-label chat))
    (teams4e--fetch-meeting-context
     chat
     (lambda (_context)
       (if-let ((event-id (teams4e--proposal-event-id chat)))
           (teams4e--proposal-request-suggestions
            chat event-id (teams4e--proposal-default-window chat)
            teams4e-meeting-proposal-activity-domain)
         (message "This meeting chat has no linked calendar event")))
     (lambda (status detail)
       (teams4e--report-error
        (teams4e--meeting-context-args chat) status detail)))))

(defun teams4e-meeting-propose-new-time ()
  "Propose an availability-ranked alternate time for the meeting at point.

The selected slot preserves the current meeting duration.  Choosing a slot and
submitting the editable organizer note sends the proposal without another
confirmation prompt."
  (interactive)
  (if (fboundp 'teams4e-meeting-availability)
      (call-interactively #'teams4e-meeting-availability)
    (teams4e--require-online)
    (let ((chat (or (teams4e--chat-at-point)
                    (user-error "No Teams chat here"))))
      (unless (teams4e--meeting-chat-p chat)
        (user-error "The current Teams conversation is not a meeting chat"))
      (teams4e--proposal-start chat))))

(defun teams4e-capture-current-summary ()
  "Capture title, source, date, and last-message context without a transcript.

For meeting chats, calendar time and participants are included when Graph can
resolve the linked event.  This is the primary mu4e-style `a a' action."
  (interactive)
  (cond
   ((or (derived-mode-p 'teams4e-channel-index-mode)
        (derived-mode-p 'teams4e-channel-thread-mode))
    (let* ((root (if (derived-mode-p 'teams4e-channel-index-mode)
                     (teams4e-channel-root-at-point)
                   teams4e-channel--root))
           (message
            (if (derived-mode-p 'teams4e-channel-thread-mode)
                (or (teams4e-message-at-point) root)
              root))
           (context
            (teams4e--channel-capture-context
             teams4e-channel--team
             teams4e-channel--channel root message)))
      (if (teams4e--jump-to-capture-context context)
          (message "Opened the existing Teams Org capture")
        (teams4e--start-summary-org-capture context message))))
   ((teams4e--chat-at-point)
    (let* ((chat (teams4e--chat-at-point))
           (message (teams4e--chat-summary-message chat)))
      (teams4e--capture-chat-summary-or-jump chat message)))
   (t
    (teams4e--select-chat
     (lambda (chat)
       (teams4e--capture-chat-summary-or-jump
        chat (teams4e--get chat 'lastMessagePreview)))))))

(defun teams4e-current-message ()
  "Return the message at point in a chat or channel transcript."
  (unless (or (derived-mode-p 'teams4e-chat-mode)
              (derived-mode-p 'teams4e-channel-thread-mode))
    (user-error "Move to a Teams chat or channel transcript first"))
  (or (teams4e-message-at-point)
      (user-error "Move point onto a Teams message first")))

(defun teams4e--message-context-args (message)
  "Return backend context arguments for MESSAGE at point."
  (let ((message-id (teams4e--get message 'id)))
    (unless (stringp message-id) (user-error "Message has no Graph ID"))
    (cond
     ((derived-mode-p 'teams4e-chat-mode)
      (list "--scope" "chat"
            "--chatId" (teams4e--chat-id teams4e--chat)
            "--messageId" message-id))
     ((derived-mode-p 'teams4e-channel-thread-mode)
      (let ((root-id (teams4e--get teams4e-channel--root 'id)))
        (append
         (list "--scope" "channel"
               "--teamId" (teams4e--get teams4e-channel--team 'id)
               "--channelId"
               (teams4e--get teams4e-channel--channel 'id)
               "--messageId" message-id)
         (unless (equal message-id root-id)
           (list "--rootMessageId" root-id)))))
     (t (user-error "No Teams message context")))))

(defun teams4e--refresh-current-view ()
  "Refresh the active native Teams transcript or index."
  (cond
   ((derived-mode-p 'teams4e-chat-mode)
    (teams4e-chat-refresh))
   ((derived-mode-p 'teams4e-channel-thread-mode)
    (teams4e-channel-thread-refresh))
   ((derived-mode-p 'teams4e-channel-index-mode)
    (teams4e-channel-refresh))
   ((derived-mode-p 'teams4e-recent-mode)
    (teams4e-recent-refresh))))

(defun teams4e--run-message-action
    (action message extra inverse-action inverse-extra label)
  "Run message ACTION on MESSAGE with EXTRA arguments and record its inverse."
  (teams4e--require-online)
  (let* ((buffer (current-buffer))
         (context (teams4e--message-context-args message))
         (args (append (list "teams" "message" (symbol-name action))
                       context extra))
         (inverse
          (and inverse-action
               (append (list "teams" "message"
                             (symbol-name inverse-action))
                       context inverse-extra))))
    (teams4e--run-json
     args
     (lambda (_payload)
       (when inverse
         (push (list :kind 'backend :args inverse :label label)
               teams4e--action-history))
       (when (buffer-live-p buffer)
         (with-current-buffer buffer (teams4e--refresh-current-view)))
       (message "%s" label)))))

(defconst teams4e--reaction-choices
  '("👍" "❤️" "😂" "😮" "😢" "😡")
  "Common Unicode Graph reactions; arbitrary Unicode remains accepted.")

(defun teams4e-message-react (reaction)
  "Set REACTION on the Teams message at point."
  (interactive
   (list (completing-read "Reaction: " teams4e--reaction-choices
                          nil nil)))
  (let ((message (teams4e-current-message)))
    (teams4e--run-message-action
     'react message (list "--reaction" reaction)
     'unreact (list "--reaction" reaction)
     (format "Added Teams reaction %s" reaction))))

(defun teams4e-message-unreact (reaction)
  "Remove REACTION from the Teams message at point."
  (interactive
   (list (completing-read "Remove reaction: "
                          teams4e--reaction-choices nil nil)))
  (let ((message (teams4e-current-message)))
    (teams4e--run-message-action
     'unreact message (list "--reaction" reaction)
     'react (list "--reaction" reaction)
     (format "Removed Teams reaction %s" reaction))))

(defun teams4e-message-edit ()
  "Edit the signed-in user's Teams message at point."
  (interactive)
  (let* ((message (teams4e-current-message))
         (old (teams4e--message-body message)))
    (unless (teams4e--message-own-p message)
      (user-error "Teams only permits editing your own message"))
    (let ((new (read-string "Edit Teams message: " old)))
      (when (string-empty-p (string-trim new))
        (user-error "Edited message is empty"))
      (teams4e--run-message-action
       'edit message (list "--message" new)
       'edit (list "--message" old)
       "Edited Teams message"))))

(defun teams4e-message-delete ()
  "Soft-delete the signed-in user's Teams message at point."
  (interactive)
  (let ((message (teams4e-current-message)))
    (unless (teams4e--message-own-p message)
      (user-error "Teams only permits deleting your own message"))
    (when (yes-or-no-p "Soft-delete this Teams message? ")
      (teams4e--run-message-action
       'delete message nil 'restore nil "Deleted Teams message"))))

(defun teams4e-message-forward ()
  "Forward the selected or latest readable message into another chat."
  (interactive)
  (let* ((chat (and (derived-mode-p 'teams4e-recent-mode)
                    (teams4e--chat-at-point)))
         (message (if chat
                      (or (teams4e--get chat 'lastMessagePreview)
                          (user-error
                           "The selected chat has no loaded message to forward"))
                    (teams4e-current-message)))
         (sender (teams4e--message-sender message))
         (created (teams4e--format-date
                   (teams4e--get message 'createdDateTime) t))
         (url (teams4e--get message 'webUrl))
         (initial
          (concat (format "Forwarded from %s (%s):\n\n%s"
                          sender created
                          (teams4e--message-body message))
                  (if (stringp url) (format "\n\nSource: %s" url) ""))))
    (teams4e--select-chat
     (lambda (chat) (teams4e--open-compose chat nil initial)))))

(defun teams4e--non-reference-attachments (message)
  "Return downloadable non-quote attachments from MESSAGE."
  (append
   (seq-filter
    (lambda (attachment)
      (not (teams4e--reference-attachment-p attachment)))
    (teams4e--get message 'attachments))
   (teams4e--inline-images message)))

(defun teams4e--choose-attachment (message)
  "Prompt for one attachment in MESSAGE and return it."
  (let* ((attachments (teams4e--non-reference-attachments message))
         (pairs
          (mapcar
           (lambda (attachment)
             (cons (or (teams4e--get attachment 'name)
                       (teams4e--get attachment 'contentType)
                       "attachment")
                   attachment))
           attachments)))
    (unless pairs (user-error "This Teams message has no downloadable attachment"))
    (cdr (assoc (completing-read "Attachment: " (mapcar #'car pairs) nil t)
                pairs))))

(defun teams4e-attachment-download (&optional preview)
  "Download one attachment from the current message.

With prefix PREVIEW, visit the downloaded file, including images, in Emacs."
  (interactive "P")
  (let* ((message (teams4e-current-message))
         (attachment (teams4e--choose-attachment message))
         (url (or (teams4e--get attachment 'contentUrl)
                  (teams4e--get attachment 'webUrl)))
         (name (or (teams4e--get attachment 'name) "teams-attachment")))
    (unless (stringp url) (user-error "Attachment has no content URL"))
    (make-directory teams4e-download-directory t)
    (let ((destination
           (read-file-name "Save attachment as: "
                           teams4e-download-directory
                           (expand-file-name name
                                             teams4e-download-directory))))
      (when (and (file-exists-p destination)
                 (not (yes-or-no-p
                       (format "Overwrite %s? "
                               (abbreviate-file-name destination)))))
        (user-error "Attachment download cancelled"))
      (teams4e--run-json
       (list "teams" "attachment" "download"
             "--url" url "--destination" destination)
       (lambda (payload)
         (let ((path (or (teams4e--get payload 'path) destination)))
           (if preview
               (find-file-other-window path)
             (message "Downloaded Teams attachment to %s"
                      (abbreviate-file-name path)))))))))

(defun teams4e-attachment-preview ()
  "Download and visit an attachment, displaying images in `image-mode'."
  (interactive)
  (teams4e-attachment-download t))

(defun teams4e--current-web-url ()
  "Return the most specific Teams web URL available at point."
  (let ((message (ignore-errors (teams4e-current-message)))
        (root
         (cond
          ((derived-mode-p 'teams4e-channel-thread-mode)
           teams4e-channel--root)
          ((derived-mode-p 'teams4e-channel-index-mode)
           (ignore-errors (teams4e-channel-root-at-point))))))
    (or (teams4e--get message 'webUrl)
        (teams4e--get root 'webUrl)
        (and (or (derived-mode-p 'teams4e-channel-thread-mode)
                 (derived-mode-p 'teams4e-channel-index-mode))
             (teams4e--get teams4e-channel--channel 'webUrl))
        (teams4e--get (teams4e--chat-at-point) 'webUrl))))

(defun teams4e-open-current-in-browser ()
  "Open the current Teams item in the web browser."
  (interactive)
  (let ((url (teams4e--current-web-url)))
    (unless (stringp url) (user-error "No Teams web URL is available here"))
    (teams4e--open-url-in-browser url)))

(defun teams4e-open-current-in-app ()
  "Open the current Teams item directly in the desktop application."
  (interactive)
  (let ((url (teams4e--current-web-url)))
    (unless (stringp url) (user-error "No Teams URL is available here"))
    (teams4e--open-url-in-app url)))

(defun teams4e--capture-context-chat ()
  "Return a chat-like source object for current chat or channel context."
  (if (derived-mode-p 'teams4e-chat-mode)
      teams4e--chat
    `((id . ,(format "%s/%s"
                    (teams4e--get teams4e-channel--team 'id)
                    (teams4e--get teams4e-channel--channel 'id)))
      (chatType . "channel")
      (topic . ,(format "%s / %s"
                        (teams4e--team-label
                         teams4e-channel--team)
                        (teams4e--channel-label
                         teams4e-channel--channel)))
      (teamId . ,(teams4e--get teams4e-channel--team 'id))
      (teamName . ,(teams4e--team-label
                    teams4e-channel--team))
      (channelId . ,(teams4e--get teams4e-channel--channel 'id))
      (channelName . ,(teams4e--channel-label
                       teams4e-channel--channel))
      (threadId . ,(teams4e--get teams4e-channel--root 'id))
      (webUrl . ,(teams4e--get teams4e-channel--channel 'webUrl)))))

(defun teams4e-capture-current-message ()
  "Capture the current chat or channel message into the configured Org inbox."
  (interactive)
  (let* ((message (teams4e-current-message))
         (chat (teams4e--capture-context-chat))
         (file (teams4e--capture-file))
         (marker (teams4e--capture-entry chat message file)))
    (pop-to-buffer (marker-buffer marker))
    (goto-char marker)
    (message "Captured Teams message in %s" (abbreviate-file-name file))))

(defun teams4e--user-choice (user)
  "Return a completion label for directory USER."
  (format "%s <%s>%s"
          (or (teams4e--get user 'displayName) "Unknown")
          (or (teams4e--get user 'mail)
              (teams4e--get user 'userPrincipalName) "unknown")
          (if-let ((title (teams4e--get user 'jobTitle)))
              (format " - %s" title)
            "")))

(defun teams4e--search-user (query callback)
  "Search directory for QUERY and pass selected user to CALLBACK."
  (teams4e--require-online)
  (teams4e--run-json
   (list "teams" "user" "search" "--query" query)
   (lambda (payload)
     (let* ((users (teams4e--payload-list payload))
            (pairs (mapcar (lambda (user)
                             (cons (teams4e--user-choice user) user))
                           users)))
       (unless pairs (user-error "No Teams users match %s" query))
       (funcall callback
                (cdr (assoc (completing-read "Teams user: "
                                             (mapcar #'car pairs) nil t)
                            pairs)))))))

(defun teams4e-user (query)
  "Search for QUERY and display the selected user's profile and presence."
  (interactive (list (read-string "Teams user search: ")))
  (teams4e--search-user
   query
   (lambda (user)
     (let ((user-id (teams4e--get user 'id)))
       (teams4e--run-json
        (list "teams" "user" "presence" "--userId" user-id)
        (lambda (presence)
          (let ((buffer (get-buffer-create "*Teams Person*")))
            (with-current-buffer buffer
              (let ((inhibit-read-only t))
                (erase-buffer)
                (insert (propertize
                         (or (teams4e--get user 'displayName) "Teams user")
                         'face '(:height 1.3 :weight bold)))
                (insert "\n\n")
                (dolist (field '((mail . "Email")
                                 (userPrincipalName . "UPN")
                                 (jobTitle . "Title")
                                 (department . "Department")
                                 (officeLocation . "Office")))
                  (when-let ((value (teams4e--get user (car field))))
                    (insert (format "%-12s %s\n" (cdr field) value))))
                (insert (format "%-12s %s / %s\n"
                                "Presence"
                                (or (teams4e--get presence 'availability)
                                    "unknown")
                                (or (teams4e--get presence 'activity)
                                    "unknown")))
                (special-mode)))
            (pop-to-buffer buffer))))))))

(defun teams4e-create-chat (participants topic)
  "Create a new chat with comma-separated PARTICIPANTS and optional TOPIC."
  (interactive
   (list (read-string "Participant emails or user IDs (comma-separated): ")
         (read-string "Group topic (optional): ")))
  (teams4e--require-online)
  (let ((args (list "teams" "chat" "create"
                    "--userEmails" participants)))
    (unless (string-empty-p (string-trim topic))
      (setq args (append args (list "--topic" topic))))
    (teams4e--run-json
     args
     (lambda (chat)
       (message "Created Teams chat")
       (teams4e-open-chat chat)))))

(defun teams4e-set-topic (topic)
  "Set TOPIC for the current group chat."
  (interactive
   (list (read-string "Group chat topic: "
                      (or (teams4e--get
                           (teams4e--chat-at-point) 'topic) ""))))
  (teams4e--require-online)
  (let ((chat (or (teams4e--chat-at-point)
                  (user-error "No Teams chat here"))))
    (unless (equal (teams4e--get chat 'chatType) "group")
      (user-error "Only group chats can have a topic"))
    (teams4e--run-json
     (list "teams" "chat" "topic" "set"
           "--chatId" (teams4e--chat-id chat) "--topic" topic)
     (lambda (_payload)
       (setf (alist-get 'topic chat) topic)
       (teams4e--refresh-current-view)
       (message "Updated Teams group topic")))))

(defun teams4e-add-member (query)
  "Search QUERY and add the selected user to the current group chat."
  (interactive (list (read-string "Add Teams member search: ")))
  (teams4e--require-online)
  (let ((chat (or (teams4e--chat-at-point)
                  (user-error "No Teams chat here"))))
    (unless (equal (teams4e--get chat 'chatType) "group")
      (user-error "Members can only be added to group chats"))
    (teams4e--search-user
     query
     (lambda (user)
       (teams4e--run-json
        (list "teams" "chat" "member" "add"
              "--chatId" (teams4e--chat-id chat)
              "--userId" (teams4e--get user 'id))
        (lambda (_payload)
          (remhash (teams4e--chat-id chat)
                   teams4e--member-cache)
          (message "Added %s to Teams chat"
                   (teams4e--get user 'displayName))))))))

(defun teams4e-remove-member ()
  "Select and remove a member from the current group chat."
  (interactive)
  (teams4e--require-online)
  (let* ((chat (or (teams4e--chat-at-point)
                   (user-error "No Teams chat here")))
         (chat-id (teams4e--chat-id chat)))
    (unless (equal (teams4e--get chat 'chatType) "group")
      (user-error "Members can only be removed from group chats"))
    (teams4e--run-json
     (list "teams" "chat" "member" "list" "--chatId" chat-id)
     (lambda (payload)
       (let* ((members
               (seq-remove
                (lambda (member)
                  (equal (teams4e--get member 'userId)
                         teams4e--connected-user-id))
                (teams4e--payload-list payload)))
              (pairs
               (mapcar
                (lambda (member)
                  (cons (or (teams4e--get member 'displayName)
                            (teams4e--get member 'email)
                            (teams4e--get member 'id))
                        member))
                members))
              (choice (completing-read "Remove member: "
                                       (mapcar #'car pairs) nil t))
              (member (cdr (assoc choice pairs))))
         (when (yes-or-no-p (format "Remove %s from this chat? " choice))
           (teams4e--run-json
            (list "teams" "chat" "member" "remove"
                  "--chatId" chat-id
                  "--membershipId" (teams4e--get member 'id))
            (lambda (_result)
              (remhash chat-id teams4e--member-cache)
              (message "Removed %s from Teams chat" choice)))))))))

(defun teams4e--tabulated-neighbor-id (id delta)
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

(defun teams4e-thread-relative (delta)
  "Open the inbox chat DELTA displayed rows from the current chat."
  (interactive "p")
  (unless (derived-mode-p 'teams4e-chat-mode)
    (user-error "Open a Teams chat thread first"))
  (let* ((chat-id (teams4e--chat-id teams4e--chat))
         (index-buffer (teams4e--recent-buffer))
         (index-window
          (and (buffer-live-p index-buffer)
               (get-buffer-window index-buffer t)))
         (target
          (if (buffer-live-p index-buffer)
              (when-let ((target-id
                          (if (window-live-p index-window)
                              (with-selected-window index-window
                                (teams4e--tabulated-neighbor-id
                                 chat-id delta))
                            (with-current-buffer index-buffer
                              (teams4e--tabulated-neighbor-id
                               chat-id delta)))))
                (teams4e--find-chat target-id))
            (let* ((visible (seq-filter #'teams4e--view-chat-p
                                        teams4e--chats))
                   (index (cl-position chat-id visible
                                       :key #'teams4e--chat-id
                                       :test #'equal))
                   (target-index (and index (+ index delta))))
              (when (and target-index (>= target-index 0)
                         (< target-index (length visible)))
                (nth target-index visible))))))
    (unless target
      (user-error "No Teams thread in that direction"))
    (teams4e-open-chat target)))

(defun teams4e-thread-next ()
  "Open the next visible Teams inbox thread."
  (interactive)
  (teams4e-thread-relative 1))

(defun teams4e-thread-previous ()
  "Open the previous visible Teams inbox thread."
  (interactive)
  (teams4e-thread-relative -1))

(defvar-local teams4e-compose--discarded nil)

(defun teams4e-compose--target-key ()
  "Return stable non-secret key for the current compose target."
  (teams4e--compose-target-key
   teams4e-compose--target teams4e-compose--reply-to))

(defun teams4e-compose--path ()
  "Return private draft path for the current compose target."
  (expand-file-name
   (format "%s.json" (md5 (teams4e-compose--target-key)))
   teams4e-draft-directory))

(defun teams4e-compose--update-header ()
  "Refresh compose metadata in the header line."
  (let* ((reply teams4e-compose--reply-to)
         (reply-label
          (and reply
               (format "Reply to %s: %s - "
                       (teams4e--message-sender reply)
                       (truncate-string-to-width
                        (replace-regexp-in-string
                         "[\n\r\t ]+" " "
                         (teams4e--message-body reply))
                        70 nil nil "...")))))
    (setq header-line-format
          (format "%sTo: %s [%s] - %d attachment%s, %d mention%s - C-c C-c send"
                (or reply-label "")
                (teams4e--target-label
                 teams4e-compose--target)
                teams4e-compose--content-type
                (length teams4e-compose--attachments)
                (if (= (length teams4e-compose--attachments) 1)
                    "" "s")
                (length teams4e-compose--mentions)
                (if (= (length teams4e-compose--mentions) 1)
                    "" "s")))))

(defun teams4e-compose--draft-target-record ()
  "Return minimal reopen metadata for the current compose target."
  (let ((target teams4e-compose--target))
    (cond
     ((teams4e--chat-id target)
      `((kind . "chat")
        (chatId . ,(teams4e--chat-id target))
        (label . ,(teams4e--target-label target))))
     ((and (keywordp (car-safe target)) (plist-get target :team-id))
      `((kind . "channel")
        (teamId . ,(plist-get target :team-id))
        (channelId . ,(plist-get target :channel-id))
        (label . ,(teams4e--target-label target))))
     ((and (keywordp (car-safe target)) (plist-get target :user-emails))
      `((kind . "recipients")
        (userEmails . ,(plist-get target :user-emails))
        (label . ,(teams4e--target-label target)))))))

(defun teams4e-compose--draft-reply-record ()
  "Return minimal reopen metadata for the current quoted reply."
  (when-let ((reply teams4e-compose--reply-to))
    `((id . ,(teams4e--get reply 'id))
      (from . ((user . ((id . ,(teams4e--dig reply 'from 'user 'id))
                        (displayName
                         . ,(teams4e--message-sender reply))))))
      (body . ((contentType . "text")
               (content . ,(teams4e--message-body reply)))))))

(defun teams4e-compose--save-draft ()
  "Persist the current compose buffer as a private recoverable JSON draft."
  (when (timerp teams4e-compose--draft-timer)
    (cancel-timer teams4e-compose--draft-timer))
  (setq teams4e-compose--draft-timer nil)
  (when (and (derived-mode-p 'teams4e-compose-mode)
             teams4e-compose--target
             (not teams4e-compose--discarded))
    (let ((body (teams4e--utf8-safe-string
                 (buffer-substring-no-properties (point-min) (point-max))))
          (file (or teams4e-compose--draft-file
                    (teams4e-compose--path)))
          (content-type teams4e-compose--content-type)
          (attachments teams4e-compose--attachments)
          (mentions teams4e-compose--mentions)
          ;; Capture buffer-local metadata before `with-temp-file' changes the
          ;; current buffer.
          (target-record (teams4e-compose--draft-target-record))
          (reply-record (teams4e-compose--draft-reply-record))
          (updated-at (format-time-string "%Y-%m-%dT%H:%M:%S%z")))
      (if (and (string-empty-p body)
               (null teams4e-compose--attachments))
          (when (file-exists-p file) (delete-file file))
        (make-directory (file-name-directory file) t)
        (let ((temporary
               (make-temp-file
                (expand-file-name ".teams-draft-" (file-name-directory file)))))
          (unwind-protect
              (progn
                (let ((coding-system-for-write 'utf-8-unix))
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
                    (insert "\n")))
                (set-file-modes temporary #o600)
                (rename-file temporary file t))
            (when (file-exists-p temporary) (delete-file temporary))))))))

(defun teams4e-compose--schedule-draft (&rest _ignored)
  "Debounce automatic draft persistence after a compose edit."
  (when (timerp teams4e-compose--draft-timer)
    (cancel-timer teams4e-compose--draft-timer))
  (let ((buffer (current-buffer)))
    (setq teams4e-compose--draft-timer
          (run-with-idle-timer
           1 nil
           (lambda ()
             (when (buffer-live-p buffer)
               (with-current-buffer buffer
                 (teams4e-compose--save-draft))))))))

(defun teams4e-compose--initialize-draft ()
  "Attach automatic draft recovery to the current compose buffer."
  (setq teams4e-compose--discarded nil
        teams4e-compose--draft-file
        (teams4e-compose--path))
  (when (and (= (buffer-size) 0)
             (file-readable-p teams4e-compose--draft-file))
    (let ((draft-file teams4e-compose--draft-file))
      (condition-case error-data
          (let* ((payload
                (json-parse-string
                 (with-temp-buffer
                   (insert-file-contents draft-file)
                   (buffer-string))
                 :object-type 'alist :array-type 'list
                 :null-object nil :false-object nil))
               (body (teams4e--get payload 'body)))
          (setq teams4e-compose--content-type
                (or (teams4e--get payload 'contentType) "text")
                teams4e-compose--attachments
                (teams4e--get payload 'attachments)
                teams4e-compose--mentions
                (teams4e--get payload 'mentions))
          (when (stringp body)
            (let ((inhibit-modification-hooks t)) (insert body)))
            (message "Restored Teams draft"))
        (error
         (message "Ignoring invalid Teams draft: %s"
                  (error-message-string error-data))))))
  (teams4e-compose--update-header))

(defun teams4e-compose--delete-draft ()
  "Delete and stop recreating the current compose draft."
  (setq teams4e-compose--discarded t)
  (when (timerp teams4e-compose--draft-timer)
    (cancel-timer teams4e-compose--draft-timer))
  (setq teams4e-compose--draft-timer nil)
  (when (and teams4e-compose--draft-file
             (file-exists-p teams4e-compose--draft-file))
    (delete-file teams4e-compose--draft-file))
  (teams4e-compose--delete-clipboard-attachments))

(defun teams4e-compose--clipboard-directory ()
  "Return the private directory used for pasted compose images."
  (expand-file-name "clipboard-images" teams4e-draft-directory))

(defun teams4e-compose--delete-clipboard-attachments ()
  "Delete pasted image files owned by the current compose draft."
  (let ((directory (teams4e-compose--clipboard-directory)))
    (dolist (path teams4e-compose--attachments)
      (when (and (stringp path) (file-exists-p path)
                 (file-in-directory-p path directory))
        (delete-file path)))))

(defun teams4e-compose-add-attachment (path)
  "Add local file PATH to the current outgoing Teams message."
  (interactive "fAttach file: ")
  (unless (derived-mode-p 'teams4e-compose-mode)
    (user-error "Open a Teams compose buffer first"))
  (setq path (expand-file-name path))
  (unless (file-regular-p path) (user-error "Attachment is not a file"))
  (cl-pushnew path teams4e-compose--attachments :test #'equal)
  (teams4e-compose--update-header)
  (teams4e-compose--schedule-draft)
  (message "Attached %s" (file-name-nondirectory path)))

(defun teams4e-compose-remove-attachment ()
  "Remove one local file from the current outgoing Teams message."
  (interactive)
  (unless teams4e-compose--attachments
    (user-error "No files are attached"))
  (let ((path (completing-read "Remove attachment: "
                               teams4e-compose--attachments nil t)))
    (setq teams4e-compose--attachments
          (delete path teams4e-compose--attachments))
    (when (and (file-exists-p path)
               (file-in-directory-p
                path (teams4e-compose--clipboard-directory)))
      (delete-file path))
    (teams4e-compose--update-header)
    (teams4e-compose--schedule-draft)))

(defun teams4e-compose-paste-image ()
  "Save the macOS clipboard image and attach it to this Teams draft."
  (interactive)
  (unless (derived-mode-p 'teams4e-compose-mode)
    (user-error "Open a Teams compose buffer first"))
  (let ((program (executable-find "pngpaste")))
    (unless program
      (user-error "Install pngpaste to attach an image from the clipboard"))
    (let* ((directory (teams4e-compose--clipboard-directory))
           path)
      (make-directory directory t)
      (set-file-modes directory #o700)
      (setq path (make-temp-file
                  (expand-file-name "teams-clipboard-" directory) nil ".png"))
      (if (zerop (call-process program nil nil nil path))
          (progn
            (set-file-modes path #o600)
            (cl-pushnew path teams4e-compose--attachments :test #'equal)
            (teams4e-compose--update-header)
            (teams4e-compose--schedule-draft)
            (message "Attached clipboard image"))
        (when (file-exists-p path) (delete-file path))
        (user-error "The clipboard does not contain a PNG-compatible image")))))

(defun teams4e-compose--read-draft (file)
  "Read one Teams draft FILE, returning nil when it is invalid."
  (condition-case nil
      (json-parse-string
       (with-temp-buffer
         (insert-file-contents file)
         (buffer-string))
       :object-type 'alist :array-type 'list
       :null-object nil :false-object nil)
    (error nil)))

(defun teams4e-compose--record-target (record)
  "Reconstruct a compose target from draft RECORD."
  (pcase (teams4e--get record 'kind)
    ("chat"
     (let ((chat-id (teams4e--get record 'chatId))
           (label (teams4e--get record 'label)))
       (or (teams4e--find-chat chat-id)
           `((id . ,chat-id) (topic . ,label)))))
    ("channel"
     (list :team-id (teams4e--get record 'teamId)
           :channel-id (teams4e--get record 'channelId)
           :label (teams4e--get record 'label)))
    ("recipients"
     (list :user-emails (teams4e--get record 'userEmails)
           :label (teams4e--get record 'label)))))

(defun teams4e-compose-drafts ()
  "Choose and reopen one recoverable Teams compose draft."
  (interactive)
  (let (choices)
    (when (file-directory-p teams4e-draft-directory)
      (dolist (file (directory-files teams4e-draft-directory t
                                     "\\.json\\'"))
        (when-let* ((payload (teams4e-compose--read-draft file))
                    (target-record (teams4e--get payload 'target))
                    (target (teams4e-compose--record-target
                             target-record)))
          (push (cons (format "%s - %s"
                              (or (teams4e--get target-record 'label)
                                  "Teams draft")
                              (or (teams4e--get payload 'updatedAt)
                                  (format-time-string
                                   "%Y-%m-%d %H:%M"
                                   (file-attribute-modification-time
                                    (file-attributes file)))))
                      (list target (teams4e--get payload 'replyTo)))
                choices))))
    (unless choices (user-error "No reopenable Teams drafts"))
    (let* ((choice (completing-read "Teams draft: " (mapcar #'car choices)
                                    nil t))
           (metadata (cdr (assoc choice choices))))
      (teams4e--open-compose (car metadata) (cadr metadata)))))

(defun teams4e-compose-mention (query)
  "Search QUERY, insert a structured @mention, and retain its user ID."
  (interactive (list (read-string "Mention Teams user: ")))
  (unless (derived-mode-p 'teams4e-compose-mode)
    (user-error "Open a Teams compose buffer first"))
  (let ((buffer (current-buffer)))
    (teams4e--search-user
     query
     (lambda (user)
       (when (buffer-live-p buffer)
         (with-current-buffer buffer
           (let ((name (teams4e--get user 'displayName))
                 (user-id (teams4e--get user 'id)))
             (insert "@" name)
             (cl-pushnew (format "%s|%s" user-id name)
                         teams4e-compose--mentions :test #'equal)
             (teams4e-compose--update-header)
             (teams4e-compose--schedule-draft))))))))

(defun teams4e-compose-toggle-rich ()
  "Toggle compose between plain text and direct Teams HTML mode."
  (interactive)
  (setq teams4e-compose--content-type
        (if (equal teams4e-compose--content-type "text")
            "html" "text"))
  (teams4e-compose--update-header)
  (teams4e-compose--schedule-draft)
  (message "Teams compose format: %s"
           teams4e-compose--content-type))

(defun teams4e-compose--wrap (open close)
  "Wrap active region in OPEN and CLOSE HTML tags."
  (unless (use-region-p) (user-error "Select text to format"))
  (unless (equal teams4e-compose--content-type "html")
    (setq teams4e-compose--content-type "html"))
  (let ((end (copy-marker (region-end))))
    (goto-char (region-beginning))
    (insert open)
    (goto-char end)
    (insert close)
    (set-marker end nil))
  (deactivate-mark)
  (teams4e-compose--update-header))

(defun teams4e-compose-bold ()
  "Wrap active region in Teams HTML strong markup."
  (interactive)
  (teams4e-compose--wrap "<strong>" "</strong>"))

(defun teams4e-compose-italic ()
  "Wrap active region in Teams HTML emphasis markup."
  (interactive)
  (teams4e-compose--wrap "<em>" "</em>"))

(defun teams4e-compose-code ()
  "Wrap active region in Teams HTML code markup."
  (interactive)
  (teams4e-compose--wrap "<code>" "</code>"))

(defun teams4e-compose-link (url)
  "Wrap active region in a Teams HTML link to URL."
  (interactive "sLink URL: ")
  (teams4e-compose--wrap
   (format "<a href=\"%s\">"
           (replace-regexp-in-string "\"" "&quot;" url t t))
   "</a>"))

(defun teams4e-compose-new-frame ()
  "Show the current full Emacs compose buffer in a dedicated frame."
  (interactive)
  (let ((buffer (current-buffer))
        (frame (make-frame '((name . "Teams Compose")))))
    (set-window-buffer (frame-selected-window frame) buffer)
    (select-frame-set-input-focus frame)))

(add-hook 'teams4e-compose-mode-hook
          (lambda ()
            (add-hook 'after-change-functions
                      #'teams4e-compose--schedule-draft nil t)
            (add-hook 'kill-buffer-hook
                      #'teams4e-compose--save-draft nil t)))

(define-key teams4e-compose-mode-map
            (kbd "C-c C-a") #'teams4e-compose-add-attachment)
(define-key teams4e-compose-mode-map
            (kbd "C-c C-r") #'teams4e-compose-remove-attachment)
(define-key teams4e-compose-mode-map
            (kbd "C-c C-p") #'teams4e-compose-paste-image)
(define-key teams4e-compose-mode-map
            (kbd "C-c C-m") #'teams4e-compose-mention)
(define-key teams4e-compose-mode-map
            (kbd "C-c C-h") #'teams4e-compose-toggle-rich)
(define-key teams4e-compose-mode-map
            (kbd "C-c C-b") #'teams4e-compose-bold)
(define-key teams4e-compose-mode-map
            (kbd "C-c C-i") #'teams4e-compose-italic)
(define-key teams4e-compose-mode-map
            (kbd "C-c C-`") #'teams4e-compose-code)
(define-key teams4e-compose-mode-map
            (kbd "C-c C-l") #'teams4e-compose-link)
(define-key teams4e-compose-mode-map
            (kbd "C-c C-f") #'teams4e-compose-new-frame)

(defvar teams4e-mark-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "i") #'teams4e-mark-read-later)
    (define-key map (kbd "r") #'teams4e-mark-read-later)
    (define-key map (kbd "u") #'teams4e-mark-unread-later)
    (define-key map (kbd "*") #'teams4e-mark-favorite-later)
    (define-key map (kbd "SPC") #'teams4e-unmark)
    map)
  "Prefix map for deferred mu4e-style Teams actions.")

(defvar teams4e-chat-mark-map
  (let ((map (make-sparse-keymap)))
    (dolist (key '("i" "r" "u" "*" "SPC"))
      (define-key map (kbd key)
                  #'teams4e-chat-run-headers-command))
    map)
  "Reader prefix map that delegates deferred marks to Teams headers.")

;; `defvar' retains existing maps during a live layer reload.
(define-key teams4e-mark-map (kbd "i")
            #'teams4e-mark-read-later)
(define-key teams4e-mark-map (kbd "r")
            #'teams4e-mark-read-later)
(dolist (key '("i" "r" "u" "*" "SPC"))
  (define-key teams4e-chat-mark-map (kbd key)
              #'teams4e-chat-run-headers-command))

(defun teams4e-chat-toggle-unread-filter ()
  "Toggle the linked headers' unread filter from the Teams reader."
  (interactive)
  (teams4e-chat-run-headers-command
   #'teams4e-toggle-unread-filter))

(defun teams4e-chat-refresh-headers ()
  "Refresh the linked chat headers from the Teams reader."
  (interactive)
  (teams4e-chat-run-headers-command
   #'teams4e-recent-refresh))

(defun teams4e-action-compose ()
  "Compose in the current chat or channel context."
  (interactive)
  (call-interactively
   (if (or (derived-mode-p 'teams4e-channel-index-mode)
           (derived-mode-p 'teams4e-channel-thread-mode))
       #'teams4e-channel-compose
     #'teams4e-send)))

(defun teams4e-action-reply ()
  "Reply in the current chat or channel context."
  (interactive)
  (call-interactively
   (if (or (derived-mode-p 'teams4e-channel-index-mode)
           (derived-mode-p 'teams4e-channel-thread-mode))
       #'teams4e-channel-reply
     #'teams4e-reply)))

(defvar teams4e-action-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "a") #'teams4e-capture-current-summary)
    (define-key map (kbd "A") #'teams4e-capture-current-thread)
    (define-key map (kbd "j") #'teams4e-jump-to-capture)
    (define-key map (kbd "t") #'teams4e-meeting-transcript)
    (define-key map (kbd "p") #'teams4e-meeting-propose-new-time)
    (define-key map (kbd "c") #'teams4e-action-compose)
    (define-key map (kbd "R") #'teams4e-action-reply)
    (define-key map (kbd "f") #'teams4e-message-forward)
    (define-key map (kbd "i") #'teams4e-mark-read)
    (define-key map (kbd "u") #'teams4e-mark-unread)
    (define-key map (kbd "*") #'teams4e-toggle-favorite)
    (define-key map (kbd "m") #'teams4e-toggle-muted)
    (define-key map (kbd "s") #'teams4e-snooze)
    (define-key map (kbd "k") #'teams4e-clear-triage)
    (define-key map (kbd "e") #'teams4e-export-current-thread)
    (define-key map (kbd "y") #'teams4e-copy-current-thread-markdown)
    (define-key map (kbd "g") #'teams4e-analyze-current-thread)
    (define-key map (kbd "o") #'teams4e-open-current-in-browser)
    (define-key map (kbd "O") #'teams4e-open-current-in-app)
    (define-key map (kbd "?") #'teams4e-headers-action)
    (define-key map (kbd "x") #'teams4e-headers-action)
    map)
  "Mu4e-style prefix map for actions on the current Teams conversation.")

;; Keep source reloads useful when this prefix map already exists.
(define-key teams4e-action-map (kbd "g")
            #'teams4e-analyze-current-thread)
(define-key teams4e-action-map (kbd "r") nil)
(define-key teams4e-action-map (kbd "h") nil)
(define-key teams4e-action-map (kbd "R")
            #'teams4e-action-reply)
(define-key teams4e-action-map (kbd "p")
            #'teams4e-meeting-propose-new-time)

(defun teams4e-headers-action ()
  "Run a row action from the Teams headers buffer.

The menu combines mu4e's headers-action convention with the core row operations
shared by the terminal Teams client."
  (interactive)
  (let* ((actions
          '(("Compose in conversation" . teams4e-action-compose)
            ("Reply to latest message" . teams4e-action-reply)
            ("Forward latest message" . teams4e-message-forward)
            ("Mark read now" . teams4e-mark-read)
            ("Mark unread now" . teams4e-mark-unread)
            ("Toggle favorite" . teams4e-toggle-favorite)
            ("Toggle local inbox mute" . teams4e-toggle-muted)
            ("Toggle handled until new" . teams4e-toggle-handled)
            ("Snooze conversation" . teams4e-snooze)
            ("Clear handled/snoozed state" . teams4e-clear-triage)
            ("Toggle chat selection" . teams4e-toggle-selection)
            ("Select or clear visible chats" .
             teams4e-toggle-visible-selections)
            ("Bulk action selected chats" . teams4e-bulk-action)
            ("Toggle unread-only filter" .
             teams4e-toggle-unread-filter)
            ("Export complete Markdown" . teams4e-export-current-thread)
            ("Copy complete Markdown" .
             teams4e-copy-current-thread-markdown)
            ("Analyze complete thread with agent" .
             teams4e-analyze-current-thread)
            ("Capture compact action to Org" .
             teams4e-capture-current-summary)
            ("Jump to existing Org capture" .
             teams4e-jump-to-capture)
            ("Open latest meeting transcript" .
             teams4e-meeting-transcript)
            ("Meeting availability / propose time" .
             teams4e-meeting-availability)
            ("Respond to meeting invitation" . teams4e-meeting-respond)
            ("Join meeting" . teams4e-meeting-join)
            ("Open linked calendar event" . teams4e-meeting-open-calendar)
            ("Capture complete thread to Org" .
             teams4e-capture-current-thread)
            ("Open in Teams web" . teams4e-open-current-in-browser)
            ("Open in Teams desktop app" . teams4e-open-current-in-app)
            ("Choose bookmark" . teams4e-bookmark-jump)
            ("Filter inbox" . teams4e-filter)
            ("Search cached messages" . teams4e-search)
            ("Search Microsoft Teams server" .
             teams4e-server-search)
            ("Reopen saved compose draft" . teams4e-compose-drafts)
            ("Close inactive transcript buffers" .
             teams4e-close-inactive-transcripts)
            ("All Teams commands" . teams4e-dispatch)))
         (choice
          (completing-read "Teams headers action: "
                           (mapcar #'car actions) nil t)))
    (call-interactively (cdr (assoc choice actions)))))

(defun teams4e-install-headers-bindings ()
  "Install the complete Teams headers map, including in reloaded sessions."
  (dolist
      (binding
       '(("RET" . teams4e-recent-open)
         ("l" . teams4e-recent-open)
         ("y" . teams4e-select-preview)
         ("j" . teams4e-recent-next)
         ("n" . teams4e-recent-next)
         ("k" . teams4e-recent-previous)
         ("p" . teams4e-recent-previous)
         ("]" . teams4e-recent-next-unread)
         ("[" . teams4e-recent-previous-unread)
         ("g" . teams4e-recent-refresh)
         ("c" . teams4e-send)
         ("i" . teams4e-mark-read-later)
         ("C" . teams4e-send)
         ("r" . teams4e-mark-read-later)
         ("R" . teams4e-reply)
         ("f" . teams4e-message-forward)
         ("F" . teams4e-message-forward)
         ("o" . teams4e-open-in-browser)
         ("O" . teams4e-open-in-app)
         ("*" . teams4e-toggle-favorite)
         ("M-u" . teams4e-mark-unread)
         ("I" . teams4e-mark-read-later)
         ("M" . teams4e-toggle-selection)
         ("T" . teams4e-toggle-visible-selections)
         ("X" . teams4e-bulk-action)
         ("E" . teams4e-export-thread)
         ("Y" . teams4e-copy-thread-markdown)
         ("J" . teams4e-preview-scroll-down)
         ("K" . teams4e-preview-scroll-up)
         ("C-+" . teams4e-index-grow)
         ("C-=" . teams4e-index-grow)
         ("C--" . teams4e-index-shrink)
         ("q" . teams4e-quit)
         ("!" . teams4e-mark-read-later)
         ("?" . teams4e-mark-unread-later)
         ("u" . teams4e-unmark)
         ("x" . teams4e-execute-marks)
         ("U" . teams4e-unmark-all)
         ("z" . teams4e-undo-action)
         ("M-U" . teams4e-undo-action)
         ("/" . teams4e-search)
         ("s" . teams4e-filter)
         ("b" . teams4e-bookmark-jump)
         ("B" . teams4e-bookmark-edit)
         ("v" . teams4e-select-view)
         ("V" . teams4e-save-view)
         ("S" . teams4e-sort)
         ("H" . teams4e-dispatch)))
    (define-key teams4e-recent-mode-map
                (kbd (car binding)) (cdr binding)))
  (define-key teams4e-recent-mode-map
              (kbd "m") teams4e-mark-map)
  (define-key teams4e-recent-mode-map
              (kbd "a") teams4e-action-map)
  (define-key teams4e-recent-mode-map (kbd "w") nil))

(teams4e-install-headers-bindings)

(define-key teams4e-search-mode-map
            (kbd "q") #'teams4e-quit)

(defconst teams4e--chat-header-mirror-keys
  '("g" "n" "p" "[" "]" "i" "I" "!" "?" "r" "M-u" "*" "f"
    "M" "T" "X" "u" "U" "x" "z" "M-U" "/" "s" "b" "B"
    "v" "V" "S" "H" "J" "K" "C-+" "C-=" "C--")
  "Headers keys delegated from the singleton Teams chat reader.")

(defun teams4e-install-chat-reader-bindings ()
  "Install mu4e-style headers delegation and reader-local Teams commands."
  (dolist (key teams4e--chat-header-mirror-keys)
    (define-key teams4e-chat-mode-map (kbd key)
                #'teams4e-chat-run-headers-command))
  (define-key teams4e-chat-mode-map
              (kbd "m") teams4e-chat-mark-map)
  (define-key teams4e-chat-mode-map
              (kbd "a") teams4e-action-map)
  (dolist
      (binding
       '(("j" . teams4e-thread-next)
         ("k" . teams4e-thread-previous)
         ("N" . teams4e-thread-next)
         ("P" . teams4e-thread-previous)
         ("M-j" . teams4e-chat-next-message)
         ("M-k" . teams4e-chat-previous-message)
         ("q" . teams4e-chat-view-quit)
         ("R" . teams4e-reply)
         ("F" . teams4e-message-forward)
         ("c" . teams4e-send)
         ("C" . teams4e-send)
         ("+" . teams4e-message-react)
         ("-" . teams4e-message-unreact)
         ("e" . teams4e-message-edit)
         ("d" . teams4e-message-delete)
         ("A" . teams4e-attachment-preview)
         ("M-a" . teams4e-attachment-download)
         ("M-g" . teams4e-chat-refresh)
         ("G" . teams4e-chat-load-all)
         ("L" . teams4e-chat-load-more)
         ("M-S" . teams4e-toggle-message-order)
         ("E" . teams4e-export-thread)
         ("Y" . teams4e-copy-current-thread-markdown)
         ("y" . teams4e-chat-back-to-inbox)
         ("M-y" . teams4e-copy-message)
         ("M-w" . teams4e-capture-message)
         ("o" . teams4e-open-in-browser)
         ("O" . teams4e-open-in-app)
         ("M-F" . teams4e-chat-toggle-unread-filter)
         ("h" . teams4e-chat-back-to-inbox)))
    (define-key teams4e-chat-mode-map
                (kbd (car binding)) (cdr binding)))
  (define-key teams4e-chat-mode-map (kbd "w") nil)
  (define-key teams4e-chat-mode-map (kbd "W") nil))

(teams4e-install-chat-reader-bindings)

(dolist (binding
         '(("q" . teams4e-quit)
           ("E" . teams4e-channel-export-thread)
           ("Y" . teams4e-copy-current-thread-markdown)
           ("o" . teams4e-open-current-in-browser)
           ("O" . teams4e-open-current-in-app)))
  (define-key teams4e-channel-index-mode-map
              (kbd (car binding)) (cdr binding)))
(define-key teams4e-channel-index-mode-map
            (kbd "a") teams4e-action-map)
(define-key teams4e-channel-index-mode-map (kbd "w") nil)

(dolist (binding
         '(("j" . teams4e-channel-thread-next)
           ("k" . teams4e-channel-thread-previous)
           ("M-j" . teams4e-chat-next-message)
           ("M-k" . teams4e-chat-previous-message)
           ("q" . teams4e-channel-view-quit)
           ("R" . teams4e-channel-reply)
           ("F" . teams4e-message-forward)
           ("M-a" . teams4e-attachment-download)
           ("c" . teams4e-channel-compose)
           ("C" . teams4e-channel-compose)
           ("S" . teams4e-toggle-message-order)
           ("Y" . teams4e-copy-current-thread-markdown)
           ("o" . teams4e-open-current-in-browser)
           ("O" . teams4e-open-current-in-app)))
  (define-key teams4e-channel-thread-mode-map
              (kbd (car binding)) (cdr binding)))
(define-key teams4e-channel-thread-mode-map
            (kbd "a") teams4e-action-map)
(define-key teams4e-channel-thread-mode-map (kbd "w") nil)
(define-key teams4e-channel-thread-mode-map (kbd "W") nil)
(define-key teams4e-channel-thread-mode-map (kbd "r") nil)

(defun teams4e-dispatch ()
  "Open a completion-driven command palette for native Teams workflows."
  (interactive)
  (let* ((commands
          '(("Inbox" . teams4e-inbox)
            ("Channels" . teams4e-channels)
            ("Search cache" . teams4e-search)
            ("Search Microsoft Teams server" .
             teams4e-server-search)
            ("Synchronize chats" . teams4e-sync)
            ("Synchronize chats and channels" .
             teams4e-sync-all)
            ("Compose message" . teams4e-send)
            ("Reopen compose draft" . teams4e-compose-drafts)
            ("Create chat" . teams4e-create-chat)
            ("Find person" . teams4e-user)
            ("Choose inbox bookmark" . teams4e-bookmark-jump)
            ("Filter inbox" . teams4e-filter)
            ("Toggle unread-only inbox filter" .
             teams4e-toggle-unread-filter)
            ("Toggle current chat selection" .
             teams4e-toggle-selection)
            ("Toggle all visible chat selections" .
             teams4e-toggle-visible-selections)
            ("Bulk action selected chats" . teams4e-bulk-action)
            ("Select inbox view" . teams4e-select-view)
            ("Capture compact action to Org" .
             teams4e-capture-current-summary)
            ("Capture complete thread to Org" .
             teams4e-capture-current-thread)
            ("Jump to existing Org capture" .
             teams4e-jump-to-capture)
            ("Open latest meeting transcript" .
             teams4e-meeting-transcript)
            ("Open upcoming meetings" . teams4e-meetings)
            ("Inspect meeting availability" .
             teams4e-meeting-availability)
            ("Respond to meeting invitation" . teams4e-meeting-respond)
            ("Join meeting" . teams4e-meeting-join)
            ("Open linked calendar event" . teams4e-meeting-open-calendar)
            ("Copy complete thread as Markdown" .
             teams4e-copy-current-thread-markdown)
            ("Analyze complete thread with agent" .
             teams4e-analyze-current-thread)
            ("Undo last action" . teams4e-undo-action)
            ("Cache status" . teams4e-cache-status)
            ("Close inactive transcript buffers" .
             teams4e-close-inactive-transcripts)
            ("Toggle cache-only mode" . teams4e-toggle-offline)
            ("OAuth/mock status" . teams4e-status)
            ("Enable local mock" . teams4e-mock-enable)
            ("Disable local mock" . teams4e-mock-disable)))
         (choice (completing-read "Teams command: " (mapcar #'car commands)
                                  nil t)))
    (call-interactively (cdr (assoc choice commands)))))

(defun teams4e-sync-all ()
  "Synchronize chats, joined teams, channels, and channel messages."
  (interactive)
  (teams4e-sync t))

;; Prefer Elpa transient after startup; loading it here would pin Emacs 30's
;; built-in 0.7.x stub before package.el is ready and break chatgpt-shell.
(defun teams4e--setup-teams-transient ()
  "Define the Teams transient menu when a modern transient is available."
  (when (and (featurep 'transient) (not (fboundp 'transient--set-layout)))
    (unload-feature 'transient t))
  (when (and (require 'transient nil t)
             (fboundp 'transient--set-layout)
             (not (fboundp 'teams4e-transient)))
    (eval
     '(transient-define-prefix teams4e-transient ()
        "Native Microsoft Teams commands."
        [["Read"
          ("i" "inbox" teams4e-inbox)
          ("m" "meetings" teams4e-meetings)
          ("c" "channels" teams4e-channels)
         ("/" "search" teams4e-search)
          ("?" "server search" teams4e-server-search)
          ("b" "bookmark" teams4e-bookmark-jump)
          ("f" "filter" teams4e-filter)
          ("F" "unread only" teams4e-toggle-unread-filter)
          ("v" "view" teams4e-select-view)]
         ["Write"
          ("s" "send" teams4e-send)
          ("d" "drafts" teams4e-compose-drafts)
          ("n" "new chat" teams4e-create-chat)
          ("p" "person" teams4e-user)
          ("P" "meeting availability" teams4e-meeting-availability)
          ("V" "meeting response" teams4e-meeting-respond)
          ("J" "join meeting" teams4e-meeting-join)
          ("a" "capture action" teams4e-capture-current-summary)
          ("A" "capture full thread" teams4e-capture-current-thread)
          ("y" "copy Markdown" teams4e-copy-current-thread-markdown)
          ("l" "analyze thread" teams4e-analyze-current-thread)]
         ["State"
          ("g" "sync" teams4e-sync)
          ("G" "sync all" teams4e-sync-all)
          ("o" "offline" teams4e-toggle-offline)
          ("S" "status" teams4e-status)]
         ["Bulk"
          ("t" "toggle chat" teams4e-toggle-selection)
          ("T" "toggle visible" teams4e-toggle-visible-selections)
          ("X" "act on selected" teams4e-bulk-action)
          ("k" "close inactive" teams4e-close-inactive-transcripts)]
         ["Test"
          ("m" "mock on" teams4e-mock-enable)
          ("M" "mock off" teams4e-mock-disable)
          ("r" "mock reset" teams4e-mock-reset)]]))
    (defalias 'teams4e-dispatch #'teams4e-transient)))

(add-hook 'emacs-startup-hook #'teams4e--setup-teams-transient)

(when (fboundp 'which-key-add-keymap-based-replacements)
  (which-key-add-keymap-based-replacements
    teams4e-recent-mode-map
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
    teams4e-action-map
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
    "p" "propose meeting time"
    "e" "export Markdown"
    "y" "copy Markdown"
    "g" "analyze with agent"
    "o" "Teams web"
    "O" "Teams app"
    "?" "choose action")
  (which-key-add-keymap-based-replacements
    teams4e-chat-mode-map
    "+" "react"
    "-" "unreact"
    "a" "action"
    "L" "load older"
    "S" "toggle order"
    "Y" "copy Markdown"
    "N" "next thread"
    "P" "previous thread"))

(defalias 'teams-channels #'teams4e-channels)
(defalias 'teams-search #'teams4e-search)
(defalias 'teams-server-search #'teams4e-server-search)
(defalias 'teams-drafts #'teams4e-compose-drafts)
(defalias 'teams-meeting-transcript #'teams4e-meeting-transcript)
(defalias 'teams-propose-new-time #'teams4e-meeting-propose-new-time)
(defalias 'teams-handle #'teams4e-toggle-handled)
(defalias 'teams-snooze #'teams4e-snooze)
(defalias 'teams-clear-triage #'teams4e-clear-triage)
(defalias 'teams-jump-capture #'teams4e-jump-to-capture)
(defalias 'teams-bookmark #'teams4e-bookmark-jump)
(defalias 'teams-filter #'teams4e-filter)
(defalias 'teams-unread-filter #'teams4e-toggle-unread-filter)
(defalias 'teams-bulk-action #'teams4e-bulk-action)
(defalias 'teams-close-inactive #'teams4e-close-inactive-transcripts)
(defalias 'teams-sync #'teams4e-sync)
(defalias 'teams-user #'teams4e-user)
(defalias 'teams-create-chat #'teams4e-create-chat)
(defalias 'teams-dispatch #'teams4e-dispatch)
(defalias 'teams-export-thread #'teams4e-export-current-thread)
(defalias 'teams-copy-thread-markdown
  #'teams4e-copy-current-thread-markdown)
(defalias 'teams-analyze-thread #'teams4e-analyze-current-thread)
(defalias 'teams-capture-message #'teams4e-capture-current-message)
(defalias 'teams-capture-action #'teams4e-capture-current-summary)
(defalias 'teams-capture-thread #'teams4e-capture-current-thread)

(provide 'teams4e-advanced)

;;; teams4e-advanced.el ends here
