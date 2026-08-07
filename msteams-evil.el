;;; msteams-evil.el --- Optional Evil bindings for msteams. -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Keep normal/motion behavior consistent with the package's ordinary maps.

;;; Code:

(require 'msteams-advanced)

(declare-function evil-define-key "evil-core")
(declare-function evil-set-initial-state "evil-core")

(with-eval-after-load 'evil
  (evil-set-initial-state 'msteams-compose-mode 'insert)
  (evil-define-key '(normal motion) msteams-recent-mode-map
    (kbd "RET") #'msteams-recent-open
    (kbd "l") #'msteams-recent-open
    (kbd "y") #'msteams-select-preview
    (kbd "j") #'msteams-recent-next
    (kbd "n") #'msteams-recent-next
    (kbd "k") #'msteams-recent-previous
    (kbd "p") #'msteams-recent-previous
    (kbd "]") #'msteams-recent-next-unread
    (kbd "[") #'msteams-recent-previous-unread
    (kbd "g r") #'msteams-recent-refresh
    (kbd "c") #'msteams-send
    (kbd "i") #'msteams-mark-read-later
    (kbd "C") #'msteams-send
    (kbd "r") #'msteams-mark-read-later
    (kbd "R") #'msteams-reply
    (kbd "f") #'msteams-message-forward
    (kbd "F") #'msteams-message-forward
    (kbd "s") #'msteams-filter
    (kbd "o") #'msteams-open-in-browser
    (kbd "O") #'msteams-open-in-app
    (kbd "*") #'msteams-toggle-favorite
    (kbd "M-u") #'msteams-mark-unread
    (kbd "I") #'msteams-mark-read-later
    (kbd "M") #'msteams-toggle-selection
    (kbd "T") #'msteams-toggle-visible-selections
    (kbd "X") #'msteams-bulk-action
    (kbd "!") #'msteams-mark-read-later
    (kbd "?") #'msteams-mark-unread-later
    (kbd "u") #'msteams-unmark
    (kbd "E") #'msteams-export-thread
    (kbd "Y") #'msteams-copy-thread-markdown
    (kbd "J") #'msteams-preview-scroll-down
    (kbd "K") #'msteams-preview-scroll-up
    (kbd "C-+") #'msteams-index-grow
    (kbd "C-=") #'msteams-index-grow
    (kbd "C--") #'msteams-index-shrink
    (kbd "m") msteams-mark-map
    (kbd "x") #'msteams-execute-marks
    (kbd "U") #'msteams-unmark-all
    (kbd "z") #'msteams-undo-action
    (kbd "M-U") #'msteams-undo-action
    (kbd "a") msteams-action-map
    (kbd "/") #'msteams-search
    (kbd "b") #'msteams-bookmark-jump
    (kbd "B") #'msteams-bookmark-edit
    (kbd "v") #'msteams-select-view
    (kbd "V") #'msteams-save-view
    (kbd "S") #'msteams-sort
    (kbd "H") #'teams-dispatch
    (kbd "q") #'msteams-quit)
  (evil-define-key '(normal motion) msteams-chat-mode-map
    (kbd "g r") #'msteams-chat-refresh-headers
    (kbd "M-g") #'msteams-chat-refresh
    (kbd "G") #'msteams-chat-load-all
    (kbd "L") #'msteams-chat-load-more
    (kbd "S") #'msteams-chat-run-headers-command
    (kbd "M-S") #'msteams-toggle-message-order
    (kbd "c") #'msteams-send
    (kbd "C") #'msteams-send
    (kbd "s") #'msteams-chat-run-headers-command
    (kbd "r") #'msteams-chat-run-headers-command
    (kbd "R") #'msteams-reply
    (kbd "i") #'msteams-chat-run-headers-command
    (kbd "I") #'msteams-chat-run-headers-command
    (kbd "!") #'msteams-chat-run-headers-command
    (kbd "?") #'msteams-chat-run-headers-command
    (kbd "M-u") #'msteams-chat-run-headers-command
    (kbd "*") #'msteams-chat-run-headers-command
    (kbd "f") #'msteams-chat-run-headers-command
    (kbd "M") #'msteams-chat-run-headers-command
    (kbd "T") #'msteams-chat-run-headers-command
    (kbd "X") #'msteams-chat-run-headers-command
    (kbd "u") #'msteams-chat-run-headers-command
    (kbd "U") #'msteams-chat-run-headers-command
    (kbd "x") #'msteams-chat-run-headers-command
    (kbd "z") #'msteams-chat-run-headers-command
    (kbd "M-U") #'msteams-chat-run-headers-command
    (kbd "a") msteams-action-map
    (kbd "/") #'msteams-chat-run-headers-command
    (kbd "b") #'msteams-chat-run-headers-command
    (kbd "B") #'msteams-chat-run-headers-command
    (kbd "v") #'msteams-chat-run-headers-command
    (kbd "V") #'msteams-chat-run-headers-command
    (kbd "H") #'msteams-chat-run-headers-command
    (kbd "J") #'msteams-chat-run-headers-command
    (kbd "K") #'msteams-chat-run-headers-command
    (kbd "C-+") #'msteams-chat-run-headers-command
    (kbd "C-=") #'msteams-chat-run-headers-command
    (kbd "C--") #'msteams-chat-run-headers-command
    (kbd "m") msteams-chat-mark-map
    (kbd "E") #'msteams-export-thread
    (kbd "Y") #'msteams-copy-current-thread-markdown
    (kbd "y") #'msteams-chat-back-to-inbox
    (kbd "M-y") #'msteams-copy-message
    (kbd "M-w") #'msteams-capture-message
    (kbd "o") #'msteams-open-in-browser
    (kbd "O") #'msteams-open-in-app
    (kbd "j") #'msteams-thread-next
    (kbd "k") #'msteams-thread-previous
    (kbd "n") #'msteams-chat-run-headers-command
    (kbd "p") #'msteams-chat-run-headers-command
    (kbd "]") #'msteams-chat-run-headers-command
    (kbd "[") #'msteams-chat-run-headers-command
    (kbd "M-j") #'msteams-chat-next-message
    (kbd "M-k") #'msteams-chat-previous-message
    (kbd "+") #'msteams-message-react
    (kbd "-") #'msteams-message-unreact
    (kbd "e") #'msteams-message-edit
    (kbd "d") #'msteams-message-delete
    (kbd "F") #'msteams-message-forward
    (kbd "A") #'msteams-attachment-preview
    (kbd "M-a") #'msteams-attachment-download
    (kbd "N") #'msteams-thread-next
    (kbd "P") #'msteams-thread-previous
    (kbd "M-F") #'msteams-chat-toggle-unread-filter
    (kbd "h") #'msteams-chat-back-to-inbox
    (kbd "q") #'msteams-chat-view-quit)
  (evil-define-key '(normal motion) msteams-channel-index-mode-map
    (kbd "RET") #'msteams-channel-open-thread
    (kbd "l") #'msteams-channel-open-thread
    (kbd "j") #'msteams-channel-next
    (kbd "k") #'msteams-channel-previous
    (kbd "g r") #'msteams-channel-refresh
    (kbd "c") #'msteams-channel-compose
    (kbd "E") #'msteams-channel-export-thread
    (kbd "Y") #'msteams-copy-current-thread-markdown
    (kbd "a") msteams-action-map
    (kbd "o") #'msteams-open-current-in-browser
    (kbd "O") #'msteams-open-current-in-app
    (kbd "/") #'msteams-search
    (kbd "?") #'teams-dispatch
    (kbd "q") #'msteams-quit)
  (evil-define-key '(normal motion) msteams-channel-thread-mode-map
    (kbd "g r") #'msteams-channel-thread-refresh
    (kbd "S") #'msteams-toggle-message-order
    (kbd "j") #'msteams-channel-thread-next
    (kbd "k") #'msteams-channel-thread-previous
    (kbd "M-j") #'msteams-chat-next-message
    (kbd "M-k") #'msteams-chat-previous-message
    (kbd "r") nil
    (kbd "R") #'msteams-channel-reply
    (kbd "c") #'msteams-channel-compose
    (kbd "C") #'msteams-channel-compose
    (kbd "+") #'msteams-message-react
    (kbd "-") #'msteams-message-unreact
    (kbd "e") #'msteams-message-edit
    (kbd "d") #'msteams-message-delete
    (kbd "f") #'msteams-message-forward
    (kbd "F") #'msteams-message-forward
    (kbd "a") msteams-action-map
    (kbd "A") #'msteams-attachment-preview
    (kbd "M-a") #'msteams-attachment-download
    (kbd "E") #'msteams-channel-export-thread
    (kbd "Y") #'msteams-copy-current-thread-markdown
    (kbd "o") #'msteams-open-current-in-browser
    (kbd "O") #'msteams-open-current-in-app
    (kbd "/") #'msteams-search
    (kbd "?") #'teams-dispatch
    (kbd "u") #'msteams-undo-action
    (kbd "h") #'msteams-channel-back-to-index
    (kbd "b") #'msteams-channel-back-to-index
    (kbd "q") #'msteams-channel-view-quit))

(provide 'msteams-evil)

;;; msteams-evil.el ends here
