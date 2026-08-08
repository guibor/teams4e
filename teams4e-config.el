;;; teams4e-config.el --- Microsoft Teams client settings. -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Settings for the native Emacs frontend and its Graph token provider.

;;; Code:

(require 'seq)

(defgroup teams4e nil
  "A keyboard-driven Microsoft Teams client for Emacs."
  :group 'applications)

(defconst teams4e--package-directory
  (file-name-directory (or load-file-name buffer-file-name))
  "Directory containing the installed teams4e package.")

(defcustom teams4e-backend-program
  (expand-file-name "bin/teams4e-graph" teams4e--package-directory)
  "Bundled Microsoft Graph backend executable."
  :type 'file
  :group 'teams4e)

(defcustom teams4e-use-persistent-backend t
  "Reuse one backend process for Teams read, cache, search, and sync requests.

Mutations, login, sends, and file transfers remain isolated one-shot processes.
Disable this option to use the original process-per-command transport."
  :type 'boolean
  :group 'teams4e)

(defcustom teams4e-cache-first t
  "Render cached chat metadata before refreshing the inbox from Graph.

This reuses `teams4e-cache-file'; it does not create another cache or
change Graph's authority over live conversation state."
  :type 'boolean
  :group 'teams4e)

(defcustom teams4e-token-command nil
  "External command that prints a short-lived Microsoft Graph token.

The value is an argv list and is executed without a shell.  Its stdout may be
the token itself or JSON containing `access_token' and optional `expires_at'.
This is the preferred integration when another program owns OAuth."
  :type '(choice (const :tag "Use credential store" nil)
                 (repeat :tag "Token command and arguments" string))
  :group 'teams4e)

(defcustom teams4e-credentials-file
  (expand-file-name "teams4e/credentials.json"
                    (or (getenv "XDG_CONFIG_HOME")
                        (expand-file-name ".config" "~")))
  "JSON credential store used when `teams4e-token-command' is nil.

The backend reads Graph access tokens from this file but never writes it."
  :type 'file
  :group 'teams4e)

(defcustom teams4e-bootstrap-program nil
  "Optional external owner of `teams4e-credentials-file'.

When configured, the backend invokes it with `--refresh-if-needed
--credentials FILE' for stale tokens.  The package never writes refresh tokens."
  :type '(choice (const :tag "No credential refresh helper" nil) file)
  :group 'teams4e)

(defcustom teams4e-credential-server-name "m365"
  "Server-name selector for entries in `teams4e-credentials-file'."
  :type 'string
  :group 'teams4e)

(defcustom teams4e-credential-server-url nil
  "Optional exact server-URL selector for the shared credential entry."
  :type '(choice (const :tag "Match server name only" nil) string)
  :group 'teams4e)

(defcustom teams4e-mock-mode nil
  "Use the persistent local Teams mock instead of OAuth and Microsoft Graph.

The mock implements the production backend command contract and is intended
for UI development and destructive workflow tests.  Its state is clearly
identified in status buffers and never validates tenant permissions."
  :type 'boolean
  :group 'teams4e)

(defcustom teams4e-mock-state-file
  (expand-file-name "teams4e/mock-tenant.json"
                    (or (getenv "XDG_CACHE_HOME")
                        (expand-file-name ".cache" "~")))
  "Persistent non-secret state used when `teams4e-mock-mode' is enabled."
  :type 'file
  :group 'teams4e)

(defcustom teams4e-cache-file
  (expand-file-name "teams4e/teams.sqlite3"
                    (or (getenv "XDG_CACHE_HOME")
                        (expand-file-name ".cache" "~")))
  "Private SQLite cache used for sync, search, and offline reading."
  :type 'file
  :group 'teams4e)

(defcustom teams4e-offline-mode nil
  "Read chats and channels only from the SQLite cache when non-nil.

Mutation commands remain disabled until this is toggled off."
  :type 'boolean
  :group 'teams4e)

(defcustom teams4e-background-sync-interval 300
  "Seconds between successful background Teams synchronization runs."
  :type 'integer
  :group 'teams4e)

(defcustom teams4e-background-sync-max-backoff 3600
  "Maximum retry delay after repeated background synchronization failures."
  :type 'integer
  :group 'teams4e)

(defcustom teams4e-sync-scope "chats"
  "Default synchronization scope, either chats or all Teams content."
  :type '(choice (const "chats") (const "all"))
  :group 'teams4e)

(defcustom teams4e-sync-chat-limit 25
  "Maximum recent chats polled during one background sync."
  :type 'integer
  :group 'teams4e)

(defcustom teams4e-sync-days 7
  "Initial number of recent days populated into the local cache."
  :type 'integer
  :group 'teams4e)

(defcustom teams4e-notifications t
  "Show a desktop notification when background sync finds new messages."
  :type 'boolean
  :group 'teams4e)

(defcustom teams4e-draft-directory
  (expand-file-name "teams4e/drafts"
                    (or (getenv "XDG_CACHE_HOME")
                        (expand-file-name ".cache" "~")))
  "Private directory containing recoverable native Teams compose drafts."
  :type 'directory
  :group 'teams4e)

(defcustom teams4e-download-directory
  (expand-file-name "Teams"
                    (or (getenv "XDG_DOWNLOAD_DIR") "~/Downloads"))
  "Default directory for downloaded Teams attachments."
  :type 'directory
  :group 'teams4e)

(defcustom teams4e-browser-command
  nil
  "Command and arguments used to open Teams web URLs.

The URL is appended as the final argument.  Nil delegates to `browse-url'."
  :type '(choice (const :tag "Use browse-url" nil)
                 (repeat :tag "Program and arguments" string))
  :group 'teams4e)

(defcustom teams4e-app-command
  (and (eq system-type 'darwin) '("open"))
  "Command and arguments used to open native Teams deep links.

The `msteams://' URL is appended as the final argument.  Nil delegates to
`browse-url'."
  :type '(choice (const :tag "Use browse-url" nil)
                 (repeat :tag "Program and arguments" string))
  :group 'teams4e)

(defcustom teams4e-image-cache-directory
  (expand-file-name "teams4e/images"
                    (or (getenv "XDG_CACHE_HOME")
                        (expand-file-name ".cache" "~")))
  "Private cache directory for images displayed in Teams transcripts."
  :type 'directory
  :group 'teams4e)

(defcustom teams4e-display-images t
  "Whether Teams transcripts download and display message images inline.

Image labels remain usable in terminal frames and when Emacs lacks support for
the downloaded format."
  :type 'boolean
  :group 'teams4e)

(defcustom teams4e-image-max-width 720
  "Maximum pixel width of an inline Teams image.

The renderer also constrains images to the width of their transcript window."
  :type 'integer
  :group 'teams4e)

(defcustom teams4e-image-max-height 480
  "Maximum pixel height of an inline Teams image."
  :type 'integer
  :group 'teams4e)

(defcustom teams4e-image-download-concurrency 3
  "Maximum simultaneous backend downloads for transcript images."
  :type 'integer
  :group 'teams4e)

(defcustom teams4e-default-content-type "text"
  "Initial compose format, either plain text or direct Teams HTML."
  :type '(choice (const "text") (const "html"))
  :group 'teams4e)

(defcustom teams4e-message-days 30
  "Number of recent days loaded when opening a Teams chat.

Set this to nil to request the complete message history.  The `G' binding in a
chat always requests complete history for that refresh."
  :type '(choice (const :tag "Complete history" nil) integer)
  :group 'teams4e)

(defcustom teams4e-message-limit 300
  "Maximum number of returned messages rendered in a chat buffer.

The newest messages are retained.  Nil renders every returned message."
  :type '(choice (const :tag "No display limit" nil) integer)
  :group 'teams4e)

(defcustom teams4e-load-more-count 300
  "Number of additional older chat messages requested by the `L' binding."
  :type 'integer
  :group 'teams4e)

(defcustom teams4e-message-order 'oldest-first
  "Default visual order for chat and channel transcript messages.

This changes only transcript display.  Markdown export and capture remain
chronological regardless of this setting."
  :type '(choice (const :tag "Oldest first" oldest-first)
                 (const :tag "Newest first" newest-first))
  :group 'teams4e)

(defcustom teams4e-preview-message-limit 75
  "Maximum recent messages fetched for an automatic inbox preview.

Focusing a thread uses `teams4e-message-limit'.  Complete-history
refresh and export remain unbounded."
  :type '(choice (const :tag "Use normal message limit" nil) integer)
  :group 'teams4e)

(defcustom teams4e-chat-metadata-limit 150
  "Maximum chat metadata records considered for the native inbox.

The frontend sorts this bounded set by recent activity before resolving member
names.  This mirrors efficient terminal clients and avoids walking
an unbounded Graph chat history just to draw the headers buffer."
  :type 'integer
  :group 'teams4e)

(defcustom teams4e-member-enrichment-limit 24
  "Maximum recent chats whose member names are resolved automatically.

Chat list responses omit members.  Resolving unnamed chats therefore needs
one additional Graph request per chat.  Set this to zero to disable it."
  :type 'integer
  :group 'teams4e)

(defcustom teams4e-member-enrichment-concurrency 8
  "Maximum concurrent member-list requests used to name recent chats.

Live inbox loads perform these requests inside one Python backend process.
Emacs starts that single batch asynchronously after rendering chat metadata."
  :type 'integer
  :group 'teams4e)

(defcustom teams4e-meeting-enrichment-limit 32
  "Maximum meeting chats whose linked calendar events are resolved per inbox load.

The enrichment attaches event metadata directly to the existing chat objects;
it does not create a second inbox or calendar cache.  Set this to zero to keep
meeting details reader-only.  Explicit meeting views spend this bound on
recent message-less meeting stubs first, then other meeting chats."
  :type 'integer
  :group 'teams4e)

(defcustom teams4e-meeting-enrichment-concurrency 6
  "Maximum concurrent linked-calendar requests for meeting inbox metadata."
  :type 'integer
  :group 'teams4e)

(defcustom teams4e-meeting-proposal-search-days 7
  "Calendar days searched around a meeting for alternate work-hour slots.

The default search starts up to one day before the original meeting, never in
the past, and extends this many days beyond its date."
  :type 'integer
  :group 'teams4e)

(defcustom teams4e-meeting-proposal-max-candidates 8
  "Maximum availability-ranked alternatives shown by the proposal flow."
  :type 'integer
  :group 'teams4e)

(defcustom teams4e-meeting-proposal-minimum-confidence 50
  "Lowest Graph availability confidence accepted for a suggested time."
  :type 'integer
  :group 'teams4e)

(defcustom teams4e-meeting-proposal-activity-domain 'work
  "Hours considered when finding alternate meeting times.

`work' respects mailbox work hours.  `personal' also considers weekends, and
`unrestricted' considers every hour in the selected date range."
  :type '(choice (const :tag "Mailbox work hours" work)
                 (const :tag "Work hours plus weekends" personal)
                 (const :tag "Any hour" unrestricted))
  :group 'teams4e)

(defcustom teams4e-meeting-proposal-default-comment
  "Could we move this meeting to the proposed time?"
  "Default organizer note offered before sending a new-time proposal.

The prompt remains editable and accepts an empty comment."
  :type 'string
  :group 'teams4e)

(defcustom teams4e-meeting-availability-interval 30
  "Free/busy interval in minutes requested for the availability workspace.

Microsoft Graph accepts values from 5 through 1440.  Calendar blocks retain
their exact start and end times; this value controls the merged availability
view returned beside them."
  :type 'integer
  :group 'teams4e)

(defconst teams4e--previous-confirm-send-standard
  (condition-case nil
      (eval (car (get 'teams4e-confirm-send 'standard-value)))
    (error nil))
  "Standard send-confirmation value seen before this config load.")

(defcustom teams4e-confirm-send nil
  "Whether to ask for confirmation before sending a Teams message."
  :type 'boolean
  :group 'teams4e)

(defcustom teams4e-confirm-apply nil
  "Whether to confirm before applying deferred or bulk inbox actions.

The action remains explicit through `teams4e-execute-marks' or the
operation selected by `teams4e-bulk-action'."
  :type 'boolean
  :group 'teams4e)

;; A source reload otherwise retains the old uncustomized default of t.  Keep
;; explicit Customize choices intact while migrating a working session.
(when (and (eq teams4e--previous-confirm-send-standard t)
           (not (get 'teams4e-confirm-send 'saved-value))
           (not (get 'teams4e-confirm-send 'customized-value)))
  (setq-default teams4e-confirm-send nil))

(defcustom teams4e-mark-read-on-open nil
  "Whether opening or previewing a chat marks it read on the server.

The default is deliberately nil: moving through the inbox and inspecting a
thread has no read-state side effect.  Use the explicit read command when a
thread is dealt with."
  :type 'boolean
  :group 'teams4e)

(defcustom teams4e-status-style 'symbols
  "How the first Teams inbox column displays conversation state.

`symbols' uses restrained Unicode marks with hover descriptions.  `letters'
uses compact mnemonic letters for terminals or fonts with limited coverage."
  :type '(choice (const :tag "Sober symbols" symbols)
                 (const :tag "Mnemonic letters" letters))
  :group 'teams4e)

(defconst teams4e--previous-preview-on-move-standard
  (condition-case nil
      (eval (car (get 'teams4e-preview-on-move 'standard-value)))
    (error nil))
  "Standard preview-on-move value seen before this config load.")

(defcustom teams4e-preview-on-move nil
  "Whether inbox j/k movement previews the selected thread.

Previewing never marks a thread read unless
`teams4e-mark-read-on-open' is also non-nil."
  :type 'boolean
  :group 'teams4e)

;; Migrate the former default in a live session while preserving Customize.
(when (and (eq teams4e--previous-preview-on-move-standard t)
           (not (get 'teams4e-preview-on-move 'saved-value))
           (not (get 'teams4e-preview-on-move 'customized-value)))
  (setq-default teams4e-preview-on-move nil))

(defcustom teams4e-preview-delay 0.25
  "Idle seconds before inbox movement loads the selected preview."
  :type 'number
  :group 'teams4e)

(defcustom teams4e-preview-cache-seconds 120
  "Seconds an unchanged chat transcript can be reused for inbox preview.

Explicit thread refresh always contacts the backend.  The cache applies only
when moving over a chat whose last-update marker has not changed."
  :type 'number
  :group 'teams4e)

(defcustom teams4e-index-width 0.46
  "Fraction of the frame used by the inbox in the two-pane Teams view."
  :type 'number
  :group 'teams4e)

(defcustom teams4e-state-file
  (expand-file-name "teams4e/teams-state.json"
                    (or (getenv "XDG_CONFIG_HOME")
                        (expand-file-name ".config" "~")))
  "Local non-secret Teams UI state for favorites, triage, and saved searches."
  :type 'file
  :group 'teams4e)

(defcustom teams4e-default-view 'inbox
  "Built-in view selected when a new Teams inbox buffer is created.

  The `inbox' view excludes muted, handled-current, and actively snoozed chats.
  The `all' view bypasses that local triage suppression."
  :type '(choice (const :tag "Relevant inbox" inbox)
                 (const :tag "All chats" all)
                 (const :tag "Needs attention" attention)
                 (const :tag "Unread" unread)
                 (const :tag "Favorites" favorites)
                 (const :tag "Handled" handled)
                 (const :tag "Snoozed" snoozed)
                 (const :tag "Muted" muted)
                 (const :tag "Direct chats" direct)
                 (const :tag "Group chats" group)
                 (const :tag "Meeting chats" meeting)
                 (const :tag "Upcoming meetings" upcoming))
  :group 'teams4e)

(defcustom teams4e-bookmarks
  '((:name "Inbox" :query inbox :key ?i)
    (:name "All chats" :query all :key ?a)
    (:name "Needs attention" :query attention :key ?n)
    (:name "Unread chats" :query "unread" :key ?u)
    (:name "Favorites" :query "favorite" :key ?f)
    (:name "Handled" :query "handled" :key ?h)
    (:name "Snoozed" :query "snoozed" :key ?s)
    (:name "Direct chats" :query "type:direct" :key ?d)
    (:name "Group chats" :query "type:group" :key ?g)
    (:name "Upcoming meetings" :query upcoming :key ?m)
    (:name "All meeting chats" :query "type:meeting" :key ?M)
    (:name "Updated today" :query "after:1d" :key ?t)
    (:name "Updated this week" :query "after:7d" :key ?w))
  "Mu4e-style shortcut bookmarks for the Teams headers buffer.

Each plist has `:name', `:query', and a character `:key'.  A query can be a
function accepting one chat, a built-in view symbol, or a string.  Space-
separated terms are ANDed; `|' separates simple OR clauses.  Terms include
inbox, all, muted, unread, read, favorite, handled, snoozed, attention,
mentioned, important, reply-to-me, attachment, type:TYPE, after:Nd, name:TEXT,
message:TEXT, and ordinary name/preview text.  Prefix a term with - to negate
it."
  :type '(repeat plist)
  :group 'teams4e)

;; A source reload retains an older customized list.  Add new built-ins only
;; when their keys are free, without replacing personal bookmarks.
(dolist (bookmark '((:name "Inbox" :query inbox :key ?i)
                    (:name "Needs attention" :query attention :key ?n)
                    (:name "Handled" :query handled :key ?h)
                    (:name "Snoozed" :query snoozed :key ?s)))
  (unless (seq-find
           (lambda (existing)
             (eq (plist-get existing :key) (plist-get bookmark :key)))
           teams4e-bookmarks)
    (setq teams4e-bookmarks
          (append teams4e-bookmarks (list bookmark)))))

;; Migrate the former built-in meeting bookmark in a live session without
;; replacing a personal bookmark that happens to use the same key.
(when-let ((meeting-bookmark
            (seq-find
             (lambda (bookmark)
               (and (eq (plist-get bookmark :key) ?m)
                    (equal (plist-get bookmark :name) "Meeting chats")
                    (equal (plist-get bookmark :query) "type:meeting")))
             teams4e-bookmarks)))
  (setf (plist-get meeting-bookmark :name) "Upcoming meetings"
        (plist-get meeting-bookmark :query) 'upcoming))
(unless (seq-find (lambda (bookmark) (eq (plist-get bookmark :key) ?M))
                  teams4e-bookmarks)
  (setq teams4e-bookmarks
        (append teams4e-bookmarks
                '((:name "All meeting chats"
                   :query "type:meeting"
                   :key ?M)))))

(defcustom teams4e-export-directory
  (expand-file-name "Teams" (or (getenv "XDG_DOWNLOAD_DIR") "~/Downloads"))
  "Directory for complete Markdown thread exports."
  :type 'directory
  :group 'teams4e)

(defcustom teams4e-thread-analysis-agent 'codex
  "Agent-shell configuration used to analyze complete Teams threads.

The value is an `agent-shell' configuration identifier such as `codex',
`cursor', or `claude-code'.  The analysis action starts a new session only
after the complete Markdown export has been written."
  :type '(choice (const :tag "Codex" codex)
                 (const :tag "Cursor" cursor)
                 (const :tag "Claude Code" claude-code)
                 (symbol :tag "Other registered agent identifier"))
  :group 'teams4e)

(defcustom teams4e-capture-file nil
  "Org file used by Teams summary, message, and complete-thread capture.

When nil, the resolver uses teams.org below `org-directory' or ~/Documents."
  :type '(choice (const :tag "Use org-directory/teams.org" nil) file)
  :group 'teams4e)

(provide 'teams4e-config)

;;; teams4e-config.el ends here
