;;; msteams-config.el --- Microsoft Teams client settings. -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Settings for the native Emacs frontend and its Graph token provider.

;;; Code:

(require 'seq)

(defgroup msteams nil
  "A keyboard-driven Microsoft Teams client for Emacs."
  :group 'applications)

(defconst msteams--package-directory
  (file-name-directory (or load-file-name buffer-file-name))
  "Directory containing the installed msteams package.")

(defcustom msteams-backend-program
  (expand-file-name "bin/msteams-graph" msteams--package-directory)
  "Bundled Microsoft Graph backend executable."
  :type 'file
  :group 'msteams)

(defcustom msteams-use-persistent-backend t
  "Reuse one backend process for Teams read, cache, search, and sync requests.

Mutations, login, sends, and file transfers remain isolated one-shot processes.
Disable this option to use the original process-per-command transport."
  :type 'boolean
  :group 'msteams)

(defcustom msteams-cache-first t
  "Render cached chat metadata before refreshing the inbox from Graph.

This reuses `msteams-cache-file'; it does not create another cache or
change Graph's authority over live conversation state."
  :type 'boolean
  :group 'msteams)

(defcustom msteams-token-command nil
  "External command that prints a short-lived Microsoft Graph token.

The value is an argv list and is executed without a shell.  Its stdout may be
the token itself or JSON containing `access_token' and optional `expires_at'.
This is the preferred integration when another program owns OAuth."
  :type '(choice (const :tag "Use credential store" nil)
                 (repeat :tag "Token command and arguments" string))
  :group 'msteams)

(defcustom msteams-credentials-file
  (expand-file-name "msteams/credentials.json"
                    (or (getenv "XDG_CONFIG_HOME")
                        (expand-file-name ".config" "~")))
  "JSON credential store used when `msteams-token-command' is nil.

The backend reads Graph access tokens from this file but never writes it."
  :type 'file
  :group 'msteams)

(defcustom msteams-bootstrap-program nil
  "Optional external owner of `msteams-credentials-file'.

When configured, the backend invokes it with `--refresh-if-needed
--credentials FILE' for stale tokens.  The package never writes refresh tokens."
  :type '(choice (const :tag "No credential refresh helper" nil) file)
  :group 'msteams)

(defcustom msteams-credential-server-name "m365"
  "Server-name selector for entries in `msteams-credentials-file'."
  :type 'string
  :group 'msteams)

(defcustom msteams-credential-server-url nil
  "Optional exact server-URL selector for the shared credential entry."
  :type '(choice (const :tag "Match server name only" nil) string)
  :group 'msteams)

(defcustom msteams-mock-mode nil
  "Use the persistent local Teams mock instead of OAuth and Microsoft Graph.

The mock implements the production backend command contract and is intended
for UI development and destructive workflow tests.  Its state is clearly
identified in status buffers and never validates tenant permissions."
  :type 'boolean
  :group 'msteams)

(defcustom msteams-mock-state-file
  (expand-file-name "msteams/mock-tenant.json"
                    (or (getenv "XDG_CACHE_HOME")
                        (expand-file-name ".cache" "~")))
  "Persistent non-secret state used when `msteams-mock-mode' is enabled."
  :type 'file
  :group 'msteams)

(defcustom msteams-cache-file
  (expand-file-name "msteams/teams.sqlite3"
                    (or (getenv "XDG_CACHE_HOME")
                        (expand-file-name ".cache" "~")))
  "Private SQLite cache used for sync, search, and offline reading."
  :type 'file
  :group 'msteams)

(defcustom msteams-offline-mode nil
  "Read chats and channels only from the SQLite cache when non-nil.

Mutation commands remain disabled until this is toggled off."
  :type 'boolean
  :group 'msteams)

(defcustom msteams-background-sync-interval 300
  "Seconds between successful background Teams synchronization runs."
  :type 'integer
  :group 'msteams)

(defcustom msteams-background-sync-max-backoff 3600
  "Maximum retry delay after repeated background synchronization failures."
  :type 'integer
  :group 'msteams)

(defcustom msteams-sync-scope "chats"
  "Default synchronization scope, either chats or all Teams content."
  :type '(choice (const "chats") (const "all"))
  :group 'msteams)

(defcustom msteams-sync-chat-limit 25
  "Maximum recent chats polled during one background sync."
  :type 'integer
  :group 'msteams)

(defcustom msteams-sync-days 7
  "Initial number of recent days populated into the local cache."
  :type 'integer
  :group 'msteams)

(defcustom msteams-notifications t
  "Show a desktop notification when background sync finds new messages."
  :type 'boolean
  :group 'msteams)

(defcustom msteams-draft-directory
  (expand-file-name "msteams/drafts"
                    (or (getenv "XDG_CACHE_HOME")
                        (expand-file-name ".cache" "~")))
  "Private directory containing recoverable native Teams compose drafts."
  :type 'directory
  :group 'msteams)

(defcustom msteams-download-directory
  (expand-file-name "Teams"
                    (or (getenv "XDG_DOWNLOAD_DIR") "~/Downloads"))
  "Default directory for downloaded Teams attachments."
  :type 'directory
  :group 'msteams)

(defcustom msteams-browser-command
  nil
  "Command and arguments used to open Teams web URLs.

The URL is appended as the final argument.  Nil delegates to `browse-url'."
  :type '(choice (const :tag "Use browse-url" nil)
                 (repeat :tag "Program and arguments" string))
  :group 'msteams)

(defcustom msteams-app-command
  (and (eq system-type 'darwin) '("open"))
  "Command and arguments used to open native Teams deep links.

The `msteams://' URL is appended as the final argument.  Nil delegates to
`browse-url'."
  :type '(choice (const :tag "Use browse-url" nil)
                 (repeat :tag "Program and arguments" string))
  :group 'msteams)

(defcustom msteams-image-cache-directory
  (expand-file-name "msteams/images"
                    (or (getenv "XDG_CACHE_HOME")
                        (expand-file-name ".cache" "~")))
  "Private cache directory for images displayed in Teams transcripts."
  :type 'directory
  :group 'msteams)

(defcustom msteams-display-images t
  "Whether Teams transcripts download and display message images inline.

Image labels remain usable in terminal frames and when Emacs lacks support for
the downloaded format."
  :type 'boolean
  :group 'msteams)

(defcustom msteams-image-max-width 720
  "Maximum pixel width of an inline Teams image.

The renderer also constrains images to the width of their transcript window."
  :type 'integer
  :group 'msteams)

(defcustom msteams-image-max-height 480
  "Maximum pixel height of an inline Teams image."
  :type 'integer
  :group 'msteams)

(defcustom msteams-image-download-concurrency 3
  "Maximum simultaneous backend downloads for transcript images."
  :type 'integer
  :group 'msteams)

(defcustom msteams-default-content-type "text"
  "Initial compose format, either plain text or direct Teams HTML."
  :type '(choice (const "text") (const "html"))
  :group 'msteams)

(defcustom msteams-message-days 30
  "Number of recent days loaded when opening a Teams chat.

Set this to nil to request the complete message history.  The `G' binding in a
chat always requests complete history for that refresh."
  :type '(choice (const :tag "Complete history" nil) integer)
  :group 'msteams)

(defcustom msteams-message-limit 300
  "Maximum number of returned messages rendered in a chat buffer.

The newest messages are retained.  Nil renders every returned message."
  :type '(choice (const :tag "No display limit" nil) integer)
  :group 'msteams)

(defcustom msteams-load-more-count 300
  "Number of additional older chat messages requested by the `L' binding."
  :type 'integer
  :group 'msteams)

(defcustom msteams-message-order 'oldest-first
  "Default visual order for chat and channel transcript messages.

This changes only transcript display.  Markdown export and capture remain
chronological regardless of this setting."
  :type '(choice (const :tag "Oldest first" oldest-first)
                 (const :tag "Newest first" newest-first))
  :group 'msteams)

(defcustom msteams-preview-message-limit 75
  "Maximum recent messages fetched for an automatic inbox preview.

Focusing a thread uses `msteams-message-limit'.  Complete-history
refresh and export remain unbounded."
  :type '(choice (const :tag "Use normal message limit" nil) integer)
  :group 'msteams)

(defcustom msteams-chat-metadata-limit 150
  "Maximum chat metadata records considered for the native inbox.

The frontend sorts this bounded set by recent activity before resolving member
names.  This mirrors efficient terminal clients and avoids walking
an unbounded Graph chat history just to draw the headers buffer."
  :type 'integer
  :group 'msteams)

(defcustom msteams-member-enrichment-limit 24
  "Maximum recent chats whose member names are resolved automatically.

Chat list responses omit members.  Resolving unnamed chats therefore needs
one additional Graph request per chat.  Set this to zero to disable it."
  :type 'integer
  :group 'msteams)

(defcustom msteams-member-enrichment-concurrency 8
  "Maximum concurrent member-list requests used to name recent chats.

Live inbox loads perform these requests inside one Python backend process.
Emacs starts that single batch asynchronously after rendering chat metadata."
  :type 'integer
  :group 'msteams)

(defcustom msteams-meeting-enrichment-limit 32
  "Maximum meeting chats whose linked calendar events are resolved per inbox load.

The enrichment attaches event metadata directly to the existing chat objects;
it does not create a second inbox or calendar cache.  Set this to zero to keep
meeting details reader-only."
  :type 'integer
  :group 'msteams)

(defcustom msteams-meeting-enrichment-concurrency 6
  "Maximum concurrent linked-calendar requests for meeting inbox metadata."
  :type 'integer
  :group 'msteams)

(defconst msteams--previous-confirm-send-standard
  (condition-case nil
      (eval (car (get 'msteams-confirm-send 'standard-value)))
    (error nil))
  "Standard send-confirmation value seen before this config load.")

(defcustom msteams-confirm-send nil
  "Whether to ask for confirmation before sending a Teams message."
  :type 'boolean
  :group 'msteams)

(defcustom msteams-confirm-apply nil
  "Whether to confirm before applying deferred or bulk inbox actions.

The action remains explicit through `msteams-execute-marks' or the
operation selected by `msteams-bulk-action'."
  :type 'boolean
  :group 'msteams)

;; A source reload otherwise retains the old uncustomized default of t.  Keep
;; explicit Customize choices intact while migrating a working session.
(when (and (eq msteams--previous-confirm-send-standard t)
           (not (get 'msteams-confirm-send 'saved-value))
           (not (get 'msteams-confirm-send 'customized-value)))
  (setq-default msteams-confirm-send nil))

(defcustom msteams-mark-read-on-open nil
  "Whether opening or previewing a chat marks it read on the server.

The default is deliberately nil: moving through the inbox and inspecting a
thread has no read-state side effect.  Use the explicit read command when a
thread is dealt with."
  :type 'boolean
  :group 'msteams)

(defcustom msteams-status-style 'symbols
  "How the first Teams inbox column displays conversation state.

`symbols' uses restrained Unicode marks with hover descriptions.  `letters'
uses compact mnemonic letters for terminals or fonts with limited coverage."
  :type '(choice (const :tag "Sober symbols" symbols)
                 (const :tag "Mnemonic letters" letters))
  :group 'msteams)

(defconst msteams--previous-preview-on-move-standard
  (condition-case nil
      (eval (car (get 'msteams-preview-on-move 'standard-value)))
    (error nil))
  "Standard preview-on-move value seen before this config load.")

(defcustom msteams-preview-on-move nil
  "Whether inbox j/k movement previews the selected thread.

Previewing never marks a thread read unless
`msteams-mark-read-on-open' is also non-nil."
  :type 'boolean
  :group 'msteams)

;; Migrate the former default in a live session while preserving Customize.
(when (and (eq msteams--previous-preview-on-move-standard t)
           (not (get 'msteams-preview-on-move 'saved-value))
           (not (get 'msteams-preview-on-move 'customized-value)))
  (setq-default msteams-preview-on-move nil))

(defcustom msteams-preview-delay 0.25
  "Idle seconds before inbox movement loads the selected preview."
  :type 'number
  :group 'msteams)

(defcustom msteams-preview-cache-seconds 120
  "Seconds an unchanged chat transcript can be reused for inbox preview.

Explicit thread refresh always contacts the backend.  The cache applies only
when moving over a chat whose last-update marker has not changed."
  :type 'number
  :group 'msteams)

(defcustom msteams-index-width 0.46
  "Fraction of the frame used by the inbox in the two-pane Teams view."
  :type 'number
  :group 'msteams)

(defcustom msteams-state-file
  (expand-file-name "msteams/teams-state.json"
                    (or (getenv "XDG_CONFIG_HOME")
                        (expand-file-name ".config" "~")))
  "Local non-secret Teams UI state for favorites, triage, and saved searches."
  :type 'file
  :group 'msteams)

(defcustom msteams-default-view 'inbox
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
  :group 'msteams)

(defcustom msteams-bookmarks
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
  :group 'msteams)

;; A source reload retains an older customized list.  Add new built-ins only
;; when their keys are free, without replacing personal bookmarks.
(dolist (bookmark '((:name "Inbox" :query inbox :key ?i)
                    (:name "Needs attention" :query attention :key ?n)
                    (:name "Handled" :query handled :key ?h)
                    (:name "Snoozed" :query snoozed :key ?s)))
  (unless (seq-find
           (lambda (existing)
             (eq (plist-get existing :key) (plist-get bookmark :key)))
           msteams-bookmarks)
    (setq msteams-bookmarks
          (append msteams-bookmarks (list bookmark)))))

;; Migrate the former built-in meeting bookmark in a live session without
;; replacing a personal bookmark that happens to use the same key.
(when-let ((meeting-bookmark
            (seq-find
             (lambda (bookmark)
               (and (eq (plist-get bookmark :key) ?m)
                    (equal (plist-get bookmark :name) "Meeting chats")
                    (equal (plist-get bookmark :query) "type:meeting")))
             msteams-bookmarks)))
  (setf (plist-get meeting-bookmark :name) "Upcoming meetings"
        (plist-get meeting-bookmark :query) 'upcoming))
(unless (seq-find (lambda (bookmark) (eq (plist-get bookmark :key) ?M))
                  msteams-bookmarks)
  (setq msteams-bookmarks
        (append msteams-bookmarks
                '((:name "All meeting chats"
                   :query "type:meeting"
                   :key ?M)))))

(defcustom msteams-export-directory
  (expand-file-name "Teams" (or (getenv "XDG_DOWNLOAD_DIR") "~/Downloads"))
  "Directory for complete Markdown thread exports."
  :type 'directory
  :group 'msteams)

(defcustom msteams-thread-analysis-agent 'codex
  "Agent-shell configuration used to analyze complete Teams threads.

The value is an `agent-shell' configuration identifier such as `codex',
`cursor', or `claude-code'.  The analysis action starts a new session only
after the complete Markdown export has been written."
  :type '(choice (const :tag "Codex" codex)
                 (const :tag "Cursor" cursor)
                 (const :tag "Claude Code" claude-code)
                 (symbol :tag "Other registered agent identifier"))
  :group 'msteams)

(defcustom msteams-capture-file nil
  "Org file used by Teams summary, message, and complete-thread capture.

When nil, the resolver uses teams.org below `org-directory' or ~/Documents."
  :type '(choice (const :tag "Use org-directory/teams.org" nil) file)
  :group 'msteams)

(provide 'msteams-config)

;;; msteams-config.el ends here
