;;; teams4e-compose-tests.el --- Authoring and reader regressions -*- lexical-binding: t; -*-

(require 'ert)
(require 'teams4e)
(when (featurep 'evil) (evil-mode 1))

(defmacro teams4e-compose-test-with-editor (editor &rest body)
  "Run BODY in a fresh Teams EDITOR with private disposable drafts."
  (declare (indent 1))
  `(let* ((teams4e-draft-directory (make-temp-file "teams4e-editor-" t))
          (teams4e-compose-editor ,editor))
     (unwind-protect
         (with-temp-buffer
           (teams4e-compose--start-editor '((id . "compose-test")) nil)
           (setq teams4e-compose--target '((id . "compose-test")))
           (teams4e-compose--initialize-draft)
           (unwind-protect (progn ,@body)
             (teams4e-compose--delete-draft)))
       (delete-directory teams4e-draft-directory t))))

(ert-deftest teams4e-compose-org-is-real-mode-with-send-keys ()
  (should (eq (default-value 'teams4e-compose-editor) 'org))
  (teams4e-compose-test-with-editor 'org
    (should (eq major-mode 'org-mode))
    (should (teams4e-compose-p))
    (should (eq (key-binding (kbd "C-c C-c")) #'teams4e-compose-send))
    (should (eq (key-binding (kbd "C-c C-k")) #'teams4e-compose-abort))
    (should (eq (key-binding (kbd "C-c C-a")) #'teams4e-compose-add-attachment))
    (should (eq (key-binding "@") #'teams4e-compose-at))
    (when (featurep 'evil) (should (eq evil-state 'insert)))
    (should (memq #'teams4e-compose--save-draft kill-buffer-hook))))

(ert-deftest teams4e-compose-org-renders-structure-without-document-wrapper ()
  (teams4e-compose-test-with-editor 'org
    (let* ((source "* Summary\n*Bold* and /italic/ and ~code~.\n\n- First\n- Second\n\n[[https://example.invalid][Link]]\n\n| A | B |\n|---+---|\n| 1 | 2 |")
           (rendered (teams4e-compose--render-body source))
           (html (cdr rendered)))
      (should (equal (car rendered) "html"))
      (dolist (fragment '("<b>Bold</b>" "<i>italic</i>" "<code>code</code>"
                          "<ul" "<table" "href=\"https://example.invalid\""))
        (should (string-match-p (regexp-quote fragment) html)))
      (should-not (string-match-p "<!DOCTYPE\\|<html\\|<body" html)))))

(ert-deftest teams4e-compose-org-does-not-execute-or-include ()
  (cl-letf (((symbol-function 'org-babel-execute-src-block)
             (lambda (&rest _) (ert-fail "Babel must not run"))))
    (should (string-match-p "dangerous-call"
              (teams4e-compose--org-html
               "#+begin_src emacs-lisp\n(dangerous-call)\n#+end_src"))))
  (dolist (source '("#+INCLUDE: /tmp/secret"
                    "#+SETUPFILE: https://example.invalid"
                    "#+BIND: org-export-use-babel t"
                    "#+CALL: dangerous()"
                    "#+MACRO: x (eval dangerous)"
                    "{{{eval(dangerous)}}}"))
    (should-error (teams4e-compose--org-html source) :type 'user-error)))

(ert-deftest teams4e-compose-markdown-renders-real-html ()
  (skip-unless (and (require 'markdown-mode nil t) (executable-find "pandoc")))
  (teams4e-compose-test-with-editor 'markdown
    (should (eq major-mode 'markdown-mode))
    (should (eq (key-binding (kbd "C-c C-c")) #'teams4e-compose-send))
    (should (eq (key-binding "@") #'teams4e-compose-at))
    (when (featurep 'evil) (should (eq evil-state 'insert)))
    (let ((html (cdr (teams4e-compose--render-body
                     "**Bold** and *italic*.\n\n- First\n- Second\n\n[Link](https://example.invalid)\n\n| A | B |\n|---|---|\n| 1 | 2 |\n\n```\ncode\n```"))))
      (dolist (fragment '("<strong>Bold</strong>" "<em>italic</em>"
                          "<ul" "<table" "<pre" "href=\"https://example.invalid\""))
        (should (string-match-p (regexp-quote fragment) html))))))

(ert-deftest teams4e-compose-markdown-conversion-failure-never-sends ()
  (teams4e-compose-test-with-editor 'org
    (setq teams4e-compose--editor 'markdown)
    (let ((teams4e-compose-pandoc-program "teams4e-missing-pandoc")
          (teams4e-offline-mode nil))
      (insert "**Keep my draft**")
      (cl-letf (((symbol-function 'teams4e--run)
                 (lambda (&rest _) (ert-fail "Must not send raw markup"))))
        (should-error (teams4e-compose-send) :type 'user-error))
      (should (equal (buffer-string) "**Keep my draft**")))))

(ert-deftest teams4e-compose-text-keeps-legacy-content-type ()
  (teams4e-compose-test-with-editor 'text
    (should (eq major-mode 'teams4e-compose-mode))
    (should (equal (teams4e-compose--render-body "*literal*")
                   '("text" . "*literal*")))
    (setq teams4e-compose--content-type "html")
    (should (equal (teams4e-compose--render-body "<b>Raw</b>")
                   '("html" . "<b>Raw</b>")))))

(ert-deftest teams4e-compose-draft-keeps-source-and-editor ()
  (teams4e-compose-test-with-editor 'org
    (insert "*Unsent* @Ada")
    (setq teams4e-compose--mentions '("ada-id|Ada")
          teams4e-compose--attachments '("/tmp/file.pdf"))
    (teams4e-compose--save-draft)
    (let ((payload (teams4e-compose--read-draft teams4e-compose--draft-file))
          (teams4e-compose-editor 'text))
      (should (equal (teams4e--get payload 'editor) "org"))
      (should (equal (teams4e--get payload 'body) "*Unsent* @Ada"))
      (with-temp-buffer
        (teams4e-compose--start-editor '((id . "compose-test")) nil)
        (setq teams4e-compose--target '((id . "compose-test")))
        (teams4e-compose--initialize-draft)
        (should (eq major-mode 'org-mode))
        (should (equal (buffer-string) "*Unsent* @Ada"))
        (should (equal teams4e-compose--mentions '("ada-id|Ada")))
        (should (equal teams4e-compose--attachments '("/tmp/file.pdf")))))))

(ert-deftest teams4e-compose-old-drafts-are-not-reinterpreted ()
  (teams4e-compose-test-with-editor 'text
    (let ((file teams4e-compose--draft-file)
          (teams4e-compose-editor 'org))
      (with-temp-file file
        (insert "{\"body\":\"*Literal*\",\"contentType\":\"text\"}"))
      (with-temp-buffer
        (teams4e-compose--start-editor '((id . "compose-test")) nil)
        (should (eq teams4e-compose--editor 'text))))))

(ert-deftest teams4e-compose-send-converts-body-and-preserves-metadata ()
  (teams4e-compose-test-with-editor 'org
    (let ((teams4e-offline-mode nil)
          (teams4e-confirm-send nil)
          args)
      (setq teams4e-compose--reply-to '((id . "reply-id"))
            teams4e-compose--mentions '("ada-id|Ada")
            teams4e-compose--attachments '("/tmp/file.pdf"))
      (insert "Hello @Ada, *thanks*.")
      (cl-letf (((symbol-function 'teams4e--run)
                 (lambda (arguments &rest _) (setq args arguments))))
        (teams4e-compose-send))
      (should (equal (cadr (member "--contentType" args)) "html"))
      (should (string-match-p "<b>thanks</b>" (cadr (member "--message" args))))
      (should (equal (cadr (member "--mention" args)) "ada-id|Ada"))
      (should (equal (cadr (member "--attachment" args)) "/tmp/file.pdf"))
      (should (equal (cadr (member "--replyToId" args)) "reply-id"))
      (should (equal (buffer-string) "Hello @Ada, *thanks*.")))))

(ert-deftest teams4e-compose-format-buttons-use-authoring-syntax ()
  (dolist (editor '(org markdown text))
    (with-temp-buffer
      (setq teams4e-compose--editor editor)
      (let ((transient-mark-mode t))
        (insert "word")
        (goto-char (point-min))
        (push-mark (point-max) t t)
        (teams4e-compose-bold)
        (should (equal (buffer-string)
                       (pcase editor
                         ('org "*word*")
                         ('markdown "**word**")
                         (_ "<strong>word</strong>"))))))))

(ert-deftest teams4e-compose-split-preserves-reader-and-closes-only-editor ()
  (save-window-excursion
    (delete-other-windows)
    (let ((reader (generate-new-buffer " *Teams test reader*"))
          (editor (generate-new-buffer " *Teams test composer*"))
          (teams4e-draft-directory (make-temp-file "teams4e-windows-" t)))
      (unwind-protect
          (progn
            (switch-to-buffer reader)
            (teams4e-chat-mode)
            (let ((inhibit-read-only t))
              (dotimes (i 50) (insert (format "Exchange %d\n" i))))
            (teams4e-compose--display editor reader '((id . "test")))
            (teams4e-compose--start-editor '((id . "test")) nil)
            (should (get-buffer-window reader))
            (should (get-buffer-window editor))
            (should (= (length (window-list)) 2))
            (should (eq (window-buffer (selected-window)) editor))
            (should (= (window-point (get-buffer-window reader))
                       (with-current-buffer reader (point-max))))
            (kill-buffer editor)
            (should (= (length (window-list)) 1))
            (should (get-buffer-window reader))
            (should (frame-live-p (selected-frame))))
        (when (buffer-live-p editor) (kill-buffer editor))
        (kill-buffer reader)
        (delete-directory teams4e-draft-directory t)))))

(ert-deftest teams4e-chat-refresh-keeps-bottom-but-respects-navigation ()
  (with-temp-buffer
    (teams4e-chat-mode)
    (setq teams4e--chat '((id . "bottom-test") (topic . "Bottom"))
          teams4e--messages
          '(((id . "one") (body . ((content . "First"))))
            ((id . "two") (body . ((content . "Second")))))
          teams4e--jump-to-bottom-on-render t)
    (let ((teams4e-message-renderer 'plain))
      (teams4e--render-chat)
      (should (= (point) (point-max)))
      ;; Network and meeting-metadata renders follow the cached first render.
      (dotimes (_ 2)
        (teams4e--render-chat)
        (should (= (point) (point-max))))
      (goto-char (point-min))
      (teams4e--goto-message-id "one")
      (teams4e--render-chat)
      (should (equal (teams4e--get (teams4e-message-at-point) 'id) "one"))
      (goto-char (point-max))
      (setq teams4e--pending-message-id "one")
      (teams4e--render-chat)
      (should (equal (teams4e--get (teams4e-message-at-point) 'id) "one")))))

;;; teams4e-compose-tests.el ends here

