;;; teams4e-evil.el --- Optional Evil bindings for teams4e. -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Keep normal/motion behavior consistent with the package's ordinary maps.

;;; Code:

(require 'teams4e-advanced)

(declare-function evil-define-key* "evil-core")
(declare-function evil-normalize-keymaps "evil-core")
(declare-function evil-set-initial-state "evil-core")

(defun teams4e-evil-refresh-bookmark-bindings ()
  "Repair bookmark-prefix bindings after Evil or Evil Collection reloads."
  (when (featurep 'evil)
    (evil-define-key* '(normal motion) teams4e-recent-mode-map
      (kbd "b") #'teams4e-bookmark-jump
      (kbd "B") #'teams4e-bookmark-edit
      (kbd "U") #'teams4e-toggle-unread-filter)
    (evil-define-key* '(normal motion) teams4e-chat-mode-map
      (kbd "b") #'teams4e-chat-run-headers-command
      (kbd "B") #'teams4e-chat-run-headers-command
      (kbd "U") #'teams4e-chat-run-headers-command)
    (when (derived-mode-p 'teams4e-recent-mode 'teams4e-chat-mode)
      (evil-normalize-keymaps))))

(add-hook 'teams4e-recent-mode-hook #'teams4e-evil-refresh-bookmark-bindings)
(add-hook 'teams4e-chat-mode-hook #'teams4e-evil-refresh-bookmark-bindings)

(with-eval-after-load 'evil
  (evil-set-initial-state 'teams4e-compose-mode 'insert)
  (evil-define-key* '(normal motion) teams4e-recent-mode-map
    (kbd "RET") #'teams4e-recent-open
    (kbd "l") #'teams4e-recent-open
    (kbd "y") #'teams4e-select-preview
    (kbd "j") #'teams4e-recent-next
    (kbd "n") #'teams4e-recent-next
    (kbd "k") #'teams4e-recent-previous
    (kbd "p") #'teams4e-recent-previous
    (kbd "]") #'teams4e-recent-next-unread
    (kbd "[") #'teams4e-recent-previous-unread
    (kbd "g r") #'teams4e-recent-refresh
    (kbd "c") #'teams4e-send
    (kbd "i") #'teams4e-mark-read-later
    (kbd "C") #'teams4e-send
    (kbd "r") #'teams4e-mark-read-later
    (kbd "R") #'teams4e-reply
    (kbd "f") #'teams4e-message-forward
    (kbd "F") #'teams4e-message-forward
    (kbd "s") #'teams4e-filter
    (kbd "o") #'teams4e-open-in-browser
    (kbd "O") #'teams4e-open-in-app
    (kbd "*") #'teams4e-toggle-favorite
    (kbd "M-u") #'teams4e-mark-unread
    (kbd "I") #'teams4e-mark-read-later
    (kbd "M") #'teams4e-toggle-selection
    (kbd "T") #'teams4e-toggle-visible-selections
    (kbd "X") #'teams4e-bulk-action
    (kbd "!") #'teams4e-mark-read-later
    (kbd "?") #'teams4e-mark-unread-later
    (kbd "u") #'teams4e-unmark
    (kbd "E") #'teams4e-export-thread
    (kbd "Y") #'teams4e-copy-thread-markdown
    (kbd "J") #'teams4e-preview-scroll-down
    (kbd "K") #'teams4e-preview-scroll-up
    (kbd "C-+") #'teams4e-index-grow
    (kbd "C-=") #'teams4e-index-grow
    (kbd "C--") #'teams4e-index-shrink
    (kbd "m") teams4e-mark-map
    (kbd "x") #'teams4e-execute-marks
    (kbd "U") #'teams4e-toggle-unread-filter
    (kbd "z") #'teams4e-undo-action
    (kbd "M-U") #'teams4e-undo-action
    (kbd "a") teams4e-action-map
    (kbd "/") #'teams4e-search
    (kbd "b") #'teams4e-bookmark-jump
    (kbd "B") #'teams4e-bookmark-edit
    (kbd "v") #'teams4e-select-view
    (kbd "V") #'teams4e-save-view
    (kbd "S") #'teams4e-sort
    (kbd "H") #'teams-dispatch
    (kbd "q") #'teams4e-quit)
  (evil-define-key* '(normal motion) teams4e-chat-mode-map
    (kbd "g r") #'teams4e-chat-refresh-headers
    (kbd "M-g") #'teams4e-chat-refresh
    (kbd "G") #'teams4e-chat-load-all
    (kbd "L") #'teams4e-chat-load-more
    (kbd "S") #'teams4e-chat-run-headers-command
    (kbd "M-S") #'teams4e-toggle-message-order
    (kbd "c") #'teams4e-send
    (kbd "C") #'teams4e-send
    (kbd "s") #'teams4e-chat-run-headers-command
    (kbd "r") #'teams4e-chat-run-headers-command
    (kbd "R") #'teams4e-reply
    (kbd "i") #'teams4e-chat-run-headers-command
    (kbd "I") #'teams4e-chat-run-headers-command
    (kbd "!") #'teams4e-chat-run-headers-command
    (kbd "?") #'teams4e-chat-run-headers-command
    (kbd "M-u") #'teams4e-chat-run-headers-command
    (kbd "*") #'teams4e-chat-run-headers-command
    (kbd "f") #'teams4e-chat-run-headers-command
    (kbd "M") #'teams4e-chat-run-headers-command
    (kbd "T") #'teams4e-chat-run-headers-command
    (kbd "X") #'teams4e-chat-run-headers-command
    (kbd "u") #'teams4e-chat-run-headers-command
    (kbd "U") #'teams4e-chat-run-headers-command
    (kbd "x") #'teams4e-chat-run-headers-command
    (kbd "z") #'teams4e-chat-run-headers-command
    (kbd "M-U") #'teams4e-chat-run-headers-command
    (kbd "a") teams4e-action-map
    (kbd "/") #'teams4e-chat-run-headers-command
    (kbd "b") #'teams4e-chat-run-headers-command
    (kbd "B") #'teams4e-chat-run-headers-command
    (kbd "v") #'teams4e-chat-run-headers-command
    (kbd "V") #'teams4e-chat-run-headers-command
    (kbd "H") #'teams4e-chat-run-headers-command
    (kbd "J") #'teams4e-chat-run-headers-command
    (kbd "K") #'teams4e-chat-run-headers-command
    (kbd "C-+") #'teams4e-chat-run-headers-command
    (kbd "C-=") #'teams4e-chat-run-headers-command
    (kbd "C--") #'teams4e-chat-run-headers-command
    (kbd "m") teams4e-chat-mark-map
    (kbd "E") #'teams4e-export-thread
    (kbd "Y") #'teams4e-copy-current-thread-markdown
    (kbd "y") #'teams4e-chat-back-to-inbox
    (kbd "M-y") #'teams4e-copy-message
    (kbd "M-w") #'teams4e-capture-message
    (kbd "o") #'teams4e-open-in-browser
    (kbd "O") #'teams4e-open-in-app
    (kbd "j") #'teams4e-thread-next
    (kbd "k") #'teams4e-thread-previous
    (kbd "n") #'teams4e-chat-run-headers-command
    (kbd "p") #'teams4e-chat-run-headers-command
    (kbd "]") #'teams4e-chat-run-headers-command
    (kbd "[") #'teams4e-chat-run-headers-command
    (kbd "M-j") #'teams4e-chat-next-message
    (kbd "M-k") #'teams4e-chat-previous-message
    (kbd "+") #'teams4e-message-react
    (kbd "-") #'teams4e-message-unreact
    (kbd "e") #'teams4e-message-edit
    (kbd "d") #'teams4e-message-delete
    (kbd "F") #'teams4e-message-forward
    (kbd "A") #'teams4e-attachment-preview
    (kbd "M-a") #'teams4e-attachment-download
    (kbd "N") #'teams4e-thread-next
    (kbd "P") #'teams4e-thread-previous
    (kbd "M-F") #'teams4e-chat-toggle-unread-filter
    (kbd "h") #'teams4e-chat-back-to-inbox
    (kbd "q") #'teams4e-chat-view-quit)
  (evil-define-key* '(normal motion) teams4e-channel-index-mode-map
    (kbd "RET") #'teams4e-channel-open-thread
    (kbd "l") #'teams4e-channel-open-thread
    (kbd "j") #'teams4e-channel-next
    (kbd "k") #'teams4e-channel-previous
    (kbd "g r") #'teams4e-channel-refresh
    (kbd "c") #'teams4e-channel-compose
    (kbd "E") #'teams4e-channel-export-thread
    (kbd "Y") #'teams4e-copy-current-thread-markdown
    (kbd "a") teams4e-action-map
    (kbd "o") #'teams4e-open-current-in-browser
    (kbd "O") #'teams4e-open-current-in-app
    (kbd "/") #'teams4e-search
    (kbd "?") #'teams-dispatch
    (kbd "q") #'teams4e-quit)
  (evil-define-key* '(normal motion) teams4e-channel-thread-mode-map
    (kbd "g r") #'teams4e-channel-thread-refresh
    (kbd "S") #'teams4e-toggle-message-order
    (kbd "j") #'teams4e-channel-thread-next
    (kbd "k") #'teams4e-channel-thread-previous
    (kbd "M-j") #'teams4e-chat-next-message
    (kbd "M-k") #'teams4e-chat-previous-message
    (kbd "r") nil
    (kbd "R") #'teams4e-channel-reply
    (kbd "c") #'teams4e-channel-compose
    (kbd "C") #'teams4e-channel-compose
    (kbd "+") #'teams4e-message-react
    (kbd "-") #'teams4e-message-unreact
    (kbd "e") #'teams4e-message-edit
    (kbd "d") #'teams4e-message-delete
    (kbd "f") #'teams4e-message-forward
    (kbd "F") #'teams4e-message-forward
    (kbd "a") teams4e-action-map
    (kbd "A") #'teams4e-attachment-preview
    (kbd "M-a") #'teams4e-attachment-download
    (kbd "E") #'teams4e-channel-export-thread
    (kbd "Y") #'teams4e-copy-current-thread-markdown
    (kbd "o") #'teams4e-open-current-in-browser
    (kbd "O") #'teams4e-open-current-in-app
    (kbd "/") #'teams4e-search
    (kbd "?") #'teams-dispatch
    (kbd "u") #'teams4e-undo-action
    (kbd "h") #'teams4e-channel-back-to-index
    (kbd "b") #'teams4e-channel-back-to-index
    (kbd "q") #'teams4e-channel-view-quit)
  (teams4e-evil-refresh-bookmark-bindings))

(provide 'teams4e-evil)

;;; teams4e-evil.el ends here
