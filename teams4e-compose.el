;;; teams4e-compose.el --- Org and Markdown Teams composition -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Real authoring modes share the existing Teams draft and send pipeline.
;; Only the outgoing body is converted; the draft always remains source text.

;;; Code:

(require 'teams4e-advanced)
(require 'ox-html)

(declare-function markdown-mode "markdown-mode" ())
(declare-function evil-insert-state "evil-states" (&optional arg))
(defvar evil-local-mode)
(defvar teams4e-compose-edit-mode)

(defcustom teams4e-compose-editor 'org
  "Editor for new Teams drafts.
Org uses the built-in HTML exporter.  Markdown requires markdown-mode and
Pandoc.  Text keeps the original plain text/direct HTML composer.
Saved drafts retain their editor; drafts predating this option use text."
  :type '(choice (const org) (const markdown) (const text))
  :group 'teams4e)

(defcustom teams4e-compose-pandoc-program "pandoc"
  "Pandoc executable used to render Markdown messages to Teams HTML."
  :type 'file
  :group 'teams4e)

(defcustom teams4e-compose-window-height 0.4
  "Fraction of the reader window used for the reply editor.
The transcript remains above it.  On small frames, use normal buffer
display if there is insufficient room to split."
  :type 'float
  :group 'teams4e)

(defvar-local teams4e-compose--window nil
  "Window created for this composer, if any.")

(defvar-local teams4e-compose--command-maps nil
  "Compose commands above Org/Evil emulation maps in this draft only.")

;; A draft belongs to its buffer, not to one initialization of its editor.
;; In particular, losing schedule/reply metadata must never change delivery.
(dolist (variable '(teams4e-compose-edit-mode
                    teams4e-compose--target teams4e-compose--origin
                    teams4e-compose--reply-to teams4e-compose--attachments
                    teams4e-compose--mentions teams4e-compose--content-type
                    teams4e-compose--editor teams4e-compose--draft-file
                    teams4e-compose--draft-timer teams4e-compose--discarded
                    teams4e-compose--schedule teams4e-compose--outbox-id
                    teams4e-compose--outbox-revision teams4e-compose--outbox-busy
                    teams4e-compose--window))
  (put variable 'permanent-local t))

(defun teams4e-compose--current-editor ()
  "Return the supported authoring format of the current major mode."
  (cond ((derived-mode-p 'org-mode) 'org)
        ((derived-mode-p 'markdown-mode) 'markdown)
        ((derived-mode-p 'text-mode) 'text)))

(defun teams4e-compose--after-major-mode ()
  "Restore draft commands and hooks after the authoring mode is reinitialized."
  (when teams4e-compose-edit-mode
    (when-let ((editor (teams4e-compose--current-editor)))
      (setq teams4e-compose--editor editor))
    (teams4e-compose-edit-mode 1)
    (setq-local require-final-newline nil
                buffer-file-coding-system 'utf-8-unix)
    (visual-line-mode 1)
    (add-hook 'kill-buffer-hook #'teams4e-compose--close-window nil t)
    (when teams4e-compose--target
      (teams4e-compose--update-header))))

(put 'teams4e-compose--after-major-mode 'permanent-local-hook t)

(defun teams4e-compose--install-bindings ()
  "Install draft commands without shadowing the authoring mode's other keys."
  (add-hook 'after-change-major-mode-hook
            #'teams4e-compose--after-major-mode t t)
  (let ((map (copy-keymap teams4e-compose-mode-map))
        (commands (make-sparse-keymap)))
    (set-keymap-parent map nil)
    (define-key map (kbd "C-<return>") #'teams4e-compose-send)
    (setq-local minor-mode-overriding-map-alist
                (cons (cons 'teams4e-compose-edit-mode map)
                      (assq-delete-all 'teams4e-compose-edit-mode
                                       minor-mode-overriding-map-alist)))
    ;; Ordinary minor-mode overrides lose to Org/Evil emulation bindings.
    ;; Elevate only the draft command prefix, not text entry or Vim keys.
    (define-key commands (kbd "C-c") (lookup-key map (kbd "C-c")))
    (define-key commands (kbd "C-<return>") #'teams4e-compose-send)
    (define-key commands [remap org-ctrl-c-ctrl-c] #'teams4e-compose-send)
    (setq-local teams4e-compose--command-maps
                (list (cons 'teams4e-compose-edit-mode commands)))
    (setq-local emulation-mode-map-alists
                (cons 'teams4e-compose--command-maps
                      (remq 'teams4e-compose--command-maps emulation-mode-map-alists)))))

(define-minor-mode teams4e-compose-edit-mode
  "Teams send, draft and attachment commands over an authoring major mode."
  :lighter " Teams"
  :keymap (make-sparse-keymap)
  (if teams4e-compose-edit-mode
      (progn
        (teams4e-compose--install-bindings)
        (unless (derived-mode-p 'teams4e-compose-mode)
          (run-hooks 'teams4e-compose-mode-hook)))
    (setq-local teams4e-compose--command-maps nil
                emulation-mode-map-alists
                (remq 'teams4e-compose--command-maps emulation-mode-map-alists))
    (remove-hook 'after-change-major-mode-hook
                 #'teams4e-compose--after-major-mode t)
    (remove-hook 'after-change-functions #'teams4e-compose--schedule-draft t)
    (remove-hook 'kill-buffer-hook #'teams4e-compose--save-draft t)
    (setq minor-mode-overriding-map-alist
          (assq-delete-all 'teams4e-compose-edit-mode
                           minor-mode-overriding-map-alist))))

;;;###autoload
(defun teams4e-compose-repair ()
  "Restore Teams state and keys without changing the current draft's text.
If a mode reset erased the target, offer metadata recovery from exactly one
matching saved draft, with explicit confirmation.  Never guess a recipient,
send, replace the text, reopen the buffer, or change its major mode."
  (interactive)
  (unless teams4e-compose--target
    (teams4e-compose--recover-metadata))
  (teams4e-compose-edit-mode 1)
  (teams4e-compose--update-header)
  (message "Teams draft keys restored: C-c C-c or C-RET sends; C-c C-k aborts"))

(defun teams4e-compose--recover-metadata ()
  "Recover lost draft metadata only after matching and confirming a saved draft.
The buffer name is a lookup hint, never authority to send to a recipient.
Scheduled drafts need a fresh outbox hold and are deliberately not recovered
through this synchronous command."
  (let (matches)
    (when (and (string-prefix-p "*Teams Compose: " (buffer-name))
               (file-directory-p teams4e-draft-directory))
      (dolist (file (directory-files teams4e-draft-directory t
                                     "\\`[[:xdigit:]]\\{32\\}\\.json\\'"))
        (when-let* ((payload (teams4e-compose--read-draft file))
                    (target (teams4e-compose--record-target
                             (teams4e--get payload 'target))))
          (let ((reply (teams4e--get payload 'replyTo)))
            (when (and (equal (buffer-name)
                              (teams4e--compose-buffer-name target reply))
                       (equal (file-name-nondirectory file)
                              (concat (md5 (teams4e--compose-target-key target reply))
                                      ".json")))
              (push (list file payload target reply) matches))))))
    (unless (= (length matches) 1)
      (user-error "No unique saved Teams draft matches this buffer; text retained, no recipient guessed"))
    (pcase-let* ((`(,file ,payload ,target ,reply) (car matches))
                 (editor (pcase (teams4e--get payload 'editor)
                           ("org" 'org) ("markdown" 'markdown) (_ 'text))))
      (when (or (teams4e--get payload 'schedule)
                (teams4e--get payload 'outboxId))
        (user-error "Scheduled draft needs an outbox hold; text retained, recovery cannot enable immediate send"))
      (unless (eq editor (teams4e-compose--current-editor))
        (user-error "Saved draft uses %s; switch to that authoring mode before repair" editor))
      ;; Validate the complete destination and reply ID without sending.
      (teams4e--send-args target "" reply)
      (unless (yes-or-no-p
               (format "Restore saved destination %s [%s]%s and %d attachment(s), keeping this text? "
                       (teams4e--target-label target)
                       (teams4e--compose-target-key target)
                       (if reply (format " (reply %s)" (teams4e--get reply 'id)) "")
                       (length (teams4e--get payload 'attachments))))
        (user-error "Recovery canceled; draft unchanged"))
      (setq-local teams4e-compose--target target
                  teams4e-compose--reply-to reply
                  teams4e-compose--attachments (teams4e--get payload 'attachments)
                  teams4e-compose--mentions (teams4e--get payload 'mentions)
                  teams4e-compose--content-type
                  (or (teams4e--get payload 'contentType) "text")
                  teams4e-compose--editor editor
                  teams4e-compose--draft-file file
                  teams4e-compose--discarded nil))))

(defun teams4e-compose--start-editor (target reply-to)
  "Start the appropriate editor for TARGET and REPLY-TO, including drafts."
  (let* ((file (expand-file-name
                (concat (md5 (teams4e--compose-target-key target reply-to))
                        ".json")
                teams4e-draft-directory))
         (draft (and (file-readable-p file)
                     (teams4e-compose--read-draft file)))
         (editor (if draft
                     (pcase (teams4e--get draft 'editor)
                       ("org" 'org)
                       ("markdown" 'markdown)
                       (_ 'text))
                   teams4e-compose-editor))
         ;; Major-mode initialization clears window ownership.
         (window teams4e-compose--window))
    (pcase editor
      ('org (org-mode))
      ('markdown
       (unless (require 'markdown-mode nil t)
         (user-error "Install markdown-mode to compose Teams Markdown"))
       (unless (executable-find teams4e-compose-pandoc-program)
         (user-error "Install Pandoc to send Teams Markdown"))
       (markdown-mode))
      ('text (teams4e-compose-mode))
      (_ (user-error "Unknown Teams compose editor: %s" editor)))
    (setq-local teams4e-compose--editor editor
                teams4e-compose--window window
                require-final-newline nil
                buffer-file-coding-system 'utf-8-unix)
    (teams4e-compose-edit-mode 1)
    (visual-line-mode 1)
    (add-hook 'kill-buffer-hook #'teams4e-compose--close-window nil t)
    (when (bound-and-true-p evil-local-mode)
      (evil-insert-state))))

(defun teams4e-compose--org-html (source)
  "Render SOURCE as a Teams HTML fragment without executing Org code.
External includes, setup files, BIND/CALL directives and macros are not
supported in messages.  Refuse them rather than silently reading files
or evaluating content pasted into a draft."
  (let ((case-fold-search t))
    (when (or (string-match-p
               "^[ \t]*#\\+\\(?:INCLUDE\\|SETUPFILE\\|BIND\\|CALL\\|MACRO\\):"
               source)
              (string-match-p (regexp-quote "{{{") source))
      (user-error "Teams Org messages cannot use includes, setup files, macros or calls")))
  (let ((org-export-use-babel nil)
        (org-export-allow-bind-keywords nil)
        (org-export-global-macros nil)
        (org-export-before-processing-functions nil)
        (org-export-before-parsing-functions nil)
        (org-export-filter-final-output-functions nil)
        (org-html-htmlize-output-type nil))
    (org-export-string-as
     source 'html t
     '(:with-toc nil :section-numbers nil :with-author nil :with-date nil
       :with-title nil :with-sub-superscript nil :with-latex nil
       :html-preamble nil :html-postamble nil))))

(defun teams4e-compose--markdown-html (source)
  "Render Markdown SOURCE with Pandoc, without shell interpolation."
  (let ((program (executable-find teams4e-compose-pandoc-program)))
    (unless program (user-error "Install Pandoc to send Teams Markdown"))
    (with-temp-buffer
      (insert source)
      (let ((coding-system-for-read 'utf-8-unix)
            (coding-system-for-write 'utf-8-unix)
            (errors (make-temp-file "teams4e-pandoc-")))
        (unwind-protect
            (let ((status
                   (call-process-region
                    (point-min) (point-max) program t (list t errors) nil
                    "--from=gfm" "--to=html5" "--wrap=none")))
              (unless (eq status 0)
                (user-error "Markdown conversion failed; draft retained: %s"
                            (string-trim
                             (with-temp-buffer
                               (insert-file-contents errors)
                               (buffer-string)))))
              (buffer-string))
          (delete-file errors))))))

(defun teams4e-compose--render-body (source)
  "Return (CONTENT-TYPE . BODY) for SOURCE in the current Teams editor."
  (when (and teams4e-compose-edit-mode
             (not (teams4e-compose--current-editor)))
    (user-error "Switch this draft back to Org, Markdown or Text mode before sending"))
  (pcase teams4e-compose--editor
    ('org (cons "html" (if (string-empty-p source) ""
                        (teams4e-compose--org-html source))))
    ('markdown (cons "html" (if (string-empty-p source) ""
                             (teams4e-compose--markdown-html source))))
    (_ (cons teams4e-compose--content-type source))))

(defun teams4e-compose--close-window ()
  "Remove only the split owned by this composer, never a frame."
  (when (and (window-live-p teams4e-compose--window)
             (eq (window-buffer teams4e-compose--window) (current-buffer))
             (not (one-window-p t)))
    (condition-case nil
        (delete-window teams4e-compose--window)
      (error nil))))

(defun teams4e-compose--display (buffer origin target)
  "Show BUFFER below the matching transcript from ORIGIN for TARGET."
  (let* ((existing (get-buffer-window buffer))
         (reader
          (cond
           ((with-current-buffer origin
              (derived-mode-p 'teams4e-read-mode))
            origin)
           ((and (with-current-buffer origin
                   (derived-mode-p 'teams4e-recent-mode))
                 (teams4e--chat-id target))
            (teams4e-open-chat target)
            (get-buffer teams4e--read-buffer-name))))
         (window (and reader (get-buffer-window reader))))
    (cond
     (existing (select-window existing))
     (window
      (let ((editor-window
             (condition-case nil
                 (split-window
                  window
                  (- (max window-min-height
                          (floor (* (window-total-height window)
                                    (max 0.2 (min 0.7
                                                  teams4e-compose-window-height)))))))
               (error nil))))
        (if (not editor-window)
            (pop-to-buffer buffer)
          (set-window-buffer editor-window buffer)
          (with-selected-window window
            (goto-char (point-max))
            (recenter -1))
          (select-window editor-window)
          (with-current-buffer buffer
            (setq teams4e-compose--window editor-window)
            (add-hook 'kill-buffer-hook #'teams4e-compose--close-window nil t)))))
     (t (pop-to-buffer buffer)))))

;; Reloading this file repairs already-open Org/Markdown drafts too.
(dolist (buffer (buffer-list))
  (with-current-buffer buffer
    (when (bound-and-true-p teams4e-compose-edit-mode)
      (teams4e-compose--install-bindings))))

(provide 'teams4e-compose)
;;; teams4e-compose.el ends here
