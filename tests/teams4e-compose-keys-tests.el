;;; teams4e-compose-keys-tests.el --- Compose key precedence -*- lexical-binding: t; -*-
(require 'ert)
(require 'teams4e)

(defvar teams4e-test-org-active nil)
(defvar teams4e-test-org-maps nil)

(defmacro teams4e-test-with-org-interception (&rest body)
  (declare (indent 0))
  `(let* ((map (make-sparse-keymap))
          (teams4e-test-org-active t)
          (teams4e-test-org-maps (list (cons 'teams4e-test-org-active map)))
          (emulation-mode-map-alists (cons 'teams4e-test-org-maps emulation-mode-map-alists)))
     (define-key map (kbd "C-c C-c") #'org-ctrl-c-ctrl-c)
     (define-key map (kbd "C-c C-k") #'ignore)
     ,@body))

(defmacro teams4e-test-with-key-draft (editor &rest body)
  (declare (indent 1))
  `(let ((teams4e-compose-editor ,editor)
         (teams4e-draft-directory (make-temp-file "teams4e-send-keys-" t)))
     (unwind-protect
         (with-temp-buffer
           (teams4e-compose--start-editor '((id . "synthetic-chat")) nil)
           (setq teams4e-compose--target '((id . "synthetic-chat")))
           ,@body)
       (delete-directory teams4e-draft-directory t))))

(ert-deftest teams4e-compose-send-beats-org-emulation-keymap ()
  (teams4e-test-with-org-interception
    (teams4e-test-with-key-draft 'org
      (should (eq major-mode 'org-mode))
      (should teams4e-compose-edit-mode)
      (should (eq (key-binding (kbd "C-c C-c")) #'teams4e-compose-send))
      (should (eq (key-binding (kbd "C-c C-k")) #'teams4e-compose-abort)))))

(ert-deftest teams4e-compose-send-key-submits-written-body-once ()
  (teams4e-test-with-org-interception
    (teams4e-test-with-key-draft 'org
      (let ((teams4e-offline-mode nil) (teams4e-confirm-send nil) calls)
        (insert "Hello, *synthetic* message.")
        (cl-letf (((symbol-function 'teams4e--run)
                   (lambda (args &rest _) (push args calls))))
          (call-interactively (key-binding (kbd "C-c C-c"))))
        (should (= (length calls) 1))
        (should (equal (cadr (member "--chatId" (car calls))) "synthetic-chat"))
        (should (equal (cadr (member "--contentType" (car calls))) "html"))
        (should (string-match-p "<b>synthetic</b>" (cadr (member "--message" (car calls)))))
        (should (equal (buffer-string) "Hello, *synthetic* message."))))))

(ert-deftest teams4e-compose-bindings-do-not-leak-or-hijack-org-navigation ()
  (teams4e-test-with-org-interception
    (teams4e-test-with-key-draft 'org
      (should (eq (key-binding (kbd "C-c C-o")) #'org-open-at-point))
      (teams4e-compose-edit-mode -1)
      (should (eq (key-binding (kbd "C-c C-c")) #'org-ctrl-c-ctrl-c)))
    (with-temp-buffer
      (org-mode)
      (should (eq (key-binding (kbd "C-c C-c")) #'org-ctrl-c-ctrl-c)))))

(ert-deftest teams4e-compose-repair-preserves-existing-draft ()
  (teams4e-test-with-key-draft 'org
    (insert "Unsent source")
    (setq teams4e-compose--attachments '("/tmp/synthetic.pdf")
          teams4e-compose--reply-to '((id . "parent-message")))
    (teams4e-compose-edit-mode -1)
    (teams4e-compose-repair)
    (should (eq major-mode 'org-mode))
    (should (equal (buffer-string) "Unsent source"))
    (should (equal teams4e-compose--attachments '("/tmp/synthetic.pdf")))
    (should (equal teams4e-compose--reply-to '((id . "parent-message"))))
    (should (eq (key-binding (kbd "C-c C-c")) #'teams4e-compose-send))
    (should (eq (key-binding (kbd "C-<return>")) #'teams4e-compose-send))))

(ert-deftest teams4e-compose-repair-refuses-an-unrelated-org-buffer ()
  (with-temp-buffer
    (org-mode)
    (should-error (teams4e-compose-repair) :type 'user-error)
    (should-not (bound-and-true-p teams4e-compose-edit-mode))))

(ert-deftest teams4e-compose-send-binding-survives-evil-states ()
  (skip-unless (require 'evil nil t))
  (evil-mode 1)
  (teams4e-test-with-org-interception
    (teams4e-test-with-key-draft 'org
      (dolist (state '(normal insert visual emacs))
        (evil-change-state state)
        (should (eq (key-binding (kbd "C-c C-c")) #'teams4e-compose-send))))))

(ert-deftest teams4e-compose-reload-repairs-open-draft-without-sending ()
  (teams4e-test-with-org-interception
    (teams4e-test-with-key-draft 'org
      (insert "Keep this existing draft")
      (setq-local teams4e-compose--command-maps nil)
      (should (eq (key-binding (kbd "C-c C-c")) #'org-ctrl-c-ctrl-c))
      (cl-letf (((symbol-function 'teams4e--run)
                 (lambda (&rest _) (ert-fail "Reload must never send"))))
        (load (locate-library "teams4e-compose") nil t))
      (should (eq (key-binding (kbd "C-c C-c")) #'teams4e-compose-send))
      (should (equal (buffer-string) "Keep this existing draft"))
      (should (equal teams4e-compose--target '((id . "synthetic-chat")))))))

(ert-deftest teams4e-compose-org-reinitialization-preserves-draft-state ()
  (teams4e-test-with-key-draft 'org
    (insert "Keep my *unsent* text")
    (setq teams4e-compose--reply-to '((id . "parent-message"))
          teams4e-compose--attachments '("/tmp/synthetic.pdf")
          teams4e-compose--mentions '("synthetic-user|Ada")
          teams4e-compose--draft-file
          (expand-file-name "fixture.json" teams4e-draft-directory))
    (let ((file teams4e-compose--draft-file))
      (dotimes (_ 3)
        (org-mode)
        (should (teams4e-compose-p))
        (should (equal teams4e-compose--target '((id . "synthetic-chat"))))
        (should (equal teams4e-compose--reply-to '((id . "parent-message"))))
        (should (equal teams4e-compose--attachments '("/tmp/synthetic.pdf")))
        (should (equal teams4e-compose--mentions '("synthetic-user|Ada")))
        (should (equal teams4e-compose--draft-file file))
        (should (eq teams4e-compose--editor 'org))
        (should (eq (key-binding (kbd "C-c C-c")) #'teams4e-compose-send))
        (should (memq #'teams4e-compose--save-draft kill-buffer-hook))
        (should (memq #'teams4e-compose--schedule-draft after-change-functions))
        (should (string-match-p "synthetic-chat\\|Teams" header-line-format))
        (should (equal (buffer-string) "Keep my *unsent* text"))))))

(ert-deftest teams4e-compose-send-after-mode-reset-submits-original-target ()
  (teams4e-test-with-key-draft 'org
    (let ((teams4e-offline-mode nil) (teams4e-confirm-send nil) calls)
      (insert "Hello, *still here*.")
      (org-mode)
      (cl-letf (((symbol-function 'teams4e--run)
                 (lambda (args &rest _) (push args calls))))
        (call-interactively (key-binding (kbd "C-c C-c"))))
      (should (= (length calls) 1))
      (should (equal (cadr (member "--chatId" (car calls))) "synthetic-chat"))
      (should (string-match-p "<b>still here</b>"
                             (cadr (member "--message" (car calls))))))))

(ert-deftest teams4e-compose-mode-reset-preserves-scheduled-send-guard ()
  (teams4e-test-with-key-draft 'org
    (setq teams4e-compose--schedule '((sendAt . "2099-01-01T12:00:00Z"))
          teams4e-compose--outbox-id "synthetic-outbox"
          teams4e-compose--outbox-revision 3
          teams4e-compose--outbox-busy t)
    (org-mode)
    (should teams4e-compose--schedule)
    (should (equal teams4e-compose--outbox-id "synthetic-outbox"))
    (should (equal teams4e-compose--outbox-revision 3))
    (should teams4e-compose--outbox-busy)
    (cl-letf (((symbol-function 'teams4e--run)
               (lambda (&rest _) (ert-fail "Must not send while scheduling"))))
      (should-error (teams4e-compose-send) :type 'user-error))))

(ert-deftest teams4e-compose-explicit-disable-survives-mode-reset ()
  (teams4e-test-with-key-draft 'org
    (teams4e-compose-edit-mode -1)
    (org-mode)
    (should-not teams4e-compose-edit-mode)
    (should (eq (key-binding (kbd "C-c C-c")) #'org-ctrl-c-ctrl-c))))

(ert-deftest teams4e-compose-mode-reset-with-evil-keeps-send-keys ()
  (skip-unless (require 'evil nil t))
  (evil-mode 1)
  (teams4e-test-with-key-draft 'org
    (dolist (state '(normal insert visual emacs))
      (org-mode)
      (evil-change-state state)
      (should (teams4e-compose-p))
      (should (eq (key-binding (kbd "C-c C-c")) #'teams4e-compose-send)))))

(defmacro teams4e-test-with-orphan-draft (&rest body)
  "Simulate a saved draft whose state was erased by an older package."
  (declare (indent 0))
  `(teams4e-test-with-key-draft 'org
     (setq teams4e-compose--reply-to '((id . "parent-message"))
           teams4e-compose--attachments '("/tmp/synthetic.pdf")
           teams4e-compose--mentions '("synthetic-user|Ada"))
     (rename-buffer (teams4e--compose-buffer-name
                     teams4e-compose--target teams4e-compose--reply-to))
     (teams4e-compose--initialize-draft)
     (insert "Older saved body")
     (teams4e-compose--save-draft)
     (let ((inhibit-modification-hooks t))
       (erase-buffer)
       (insert "Newer *unsent* body"))
     (dolist (variable '(teams4e-compose-edit-mode teams4e-compose--target
                         teams4e-compose--reply-to teams4e-compose--attachments
                         teams4e-compose--mentions teams4e-compose--editor
                         teams4e-compose--draft-file))
       (kill-local-variable variable))
     (org-mode)
     (should (equal (list major-mode teams4e-compose-edit-mode
                         teams4e-compose--target (key-binding (kbd "C-c C-c")))
                    '(org-mode nil nil org-ctrl-c-ctrl-c)))
     ,@body))

(ert-deftest teams4e-compose-repair-recovers-confirmed-metadata-not-old-body ()
  (teams4e-test-with-orphan-draft
    (let (confirmation)
      (cl-letf (((symbol-function 'yes-or-no-p)
                 (lambda (prompt) (setq confirmation prompt) t))
                ((symbol-function 'teams4e--run)
                 (lambda (&rest _) (ert-fail "Repair must never send"))))
        (teams4e-compose-repair))
      (should (string-match-p "synthetic-chat" confirmation))
      (should (string-match-p "parent-message" confirmation))
      (should (equal (buffer-string) "Newer *unsent* body"))
      (should (equal (teams4e--chat-id teams4e-compose--target) "synthetic-chat"))
      (should (equal (teams4e--get teams4e-compose--reply-to 'id) "parent-message"))
      (should (equal teams4e-compose--attachments '("/tmp/synthetic.pdf")))
      (should (equal teams4e-compose--mentions '("synthetic-user|Ada")))
      (should (eq teams4e-compose--editor 'org))
      (should (eq (key-binding (kbd "C-c C-c")) #'teams4e-compose-send))
      (org-mode)
      (should (teams4e-compose-p))
      (should (equal (teams4e--chat-id teams4e-compose--target) "synthetic-chat")))))

(ert-deftest teams4e-compose-repair-declined-recovery-leaves-buffer-alone ()
  (teams4e-test-with-orphan-draft
    (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) nil)))
      (should-error (teams4e-compose-repair) :type 'user-error))
    (should-not teams4e-compose-edit-mode)
    (should-not teams4e-compose--target)
    (should (equal (buffer-string) "Newer *unsent* body"))
    (should (eq (key-binding (kbd "C-c C-c")) #'org-ctrl-c-ctrl-c))))

(ert-deftest teams4e-compose-repair-does-not-guess-a-different-draft ()
  (teams4e-test-with-orphan-draft
    (rename-buffer "*Teams Compose: other [123456]*")
    (cl-letf (((symbol-function 'yes-or-no-p)
               (lambda (&rest _) (ert-fail "No matching target to confirm"))))
      (should-error (teams4e-compose-repair) :type 'user-error))
    (should-not teams4e-compose--target)
    (should (equal (buffer-string) "Newer *unsent* body"))))

(ert-deftest teams4e-compose-repair-rejects-a-mismatched-draft-file ()
  (teams4e-test-with-orphan-draft
    (rename-file (car (directory-files teams4e-draft-directory t "\\.json\\'"))
                 (expand-file-name "00000000000000000000000000000000.json"
                                   teams4e-draft-directory))
    (should-error (teams4e-compose-repair) :type 'user-error)
    (should-not teams4e-compose--target)))

(ert-deftest teams4e-compose-repair-does-not-turn-a-schedule-into-send-now ()
  (teams4e-test-with-orphan-draft
    (let* ((file (car (directory-files teams4e-draft-directory t "\\.json\\'")))
           (payload (teams4e-compose--read-draft file)))
      (setf (alist-get 'outboxId payload) "synthetic-outbox")
      (setf (alist-get 'attachments payload) [])
      (setf (alist-get 'mentions payload) [])
      (with-temp-file file (insert (json-serialize payload))))
    (cl-letf (((symbol-function 'yes-or-no-p)
               (lambda (&rest _) (ert-fail "Must not recover a stale schedule"))))
      (should-error (teams4e-compose-repair) :type 'user-error))
    (should-not teams4e-compose--target)
    (should (equal (buffer-string) "Newer *unsent* body"))))

(ert-deftest teams4e-compose-format-follows-supported-authoring-mode-changes ()
  (teams4e-test-with-key-draft 'org
    (text-mode)
    (should (eq teams4e-compose--editor 'text))
    (should (eq (key-binding (kbd "C-c C-c")) #'teams4e-compose-send))
    (org-mode)
    (should (eq teams4e-compose--editor 'org))
    (fundamental-mode)
    (should teams4e-compose--target)
    (should-error (teams4e-compose--render-body "Not safe to interpret")
                  :type 'user-error)
    (org-mode)
    (should (teams4e-compose-p))))

(ert-deftest teams4e-compose-markdown-mode-reset-keeps-metadata-and-send-keys ()
  (skip-unless (and (require 'markdown-mode nil t) (executable-find "pandoc")))
  (teams4e-test-with-key-draft 'markdown
    (insert "**Keep Markdown**")
    (markdown-mode)
    (should (eq teams4e-compose--editor 'markdown))
    (should (equal teams4e-compose--target '((id . "synthetic-chat"))))
    (should (eq (key-binding (kbd "C-c C-c")) #'teams4e-compose-send))
    (should (equal (buffer-string) "**Keep Markdown**"))))
