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
