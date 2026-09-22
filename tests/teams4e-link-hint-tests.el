;;; teams4e-link-hint-tests.el --- Optional link-hint integration tests -*- lexical-binding: t; -*-

(require 'ert)
(require 'teams4e)
(require 'link-hint)

(defun teams4e-test-hint-link (position url)
  "Check link-hint discovers, opens, and copies URL at POSITION."
  (let* ((link-hint-types (link-hint--valid-types :open))
         (links (link-hint--collect (point-min) (point-max)
                                    'link-hint-shr-url))
         opened copied)
    (should (seq-some (lambda (link)
                        (and (= position (plist-get link :pos))
                             (equal url (plist-get link :args))))
                      links))
    (goto-char position)
    (cl-letf (((symbol-function 'browse-url)
               (lambda (target &rest _) (setq opened target)))
              ((symbol-function 'kill-new)
               (lambda (target &rest _) (setq copied target))))
      (link-hint-open-link-at-point)
      (link-hint-copy-link-at-point))
    (should (equal url opened))
    (should (equal url copied))))

(ert-deftest teams4e-link-hint-rich-message ()
  (dolist (target-property '(agent-shell-markdown-url help-echo))
    (with-temp-buffer
      (teams4e-chat-mode)
      (let ((inhibit-read-only t)
            (url "https://example.invalid/design"))
        (insert "Message\n")
        (let ((start (point)))
          (cl-letf (((symbol-function 'agent-shell-markdown-replace-markup)
                     (lambda (&rest _args)
                       (delete-region (point-min) (point-max))
                       (insert (propertize "Design" target-property url
                                           'keymap (make-sparse-keymap))))))
            (teams4e--insert-rendered-markdown "[Design](ignored)"))
          (teams4e-test-hint-link start url))))))

(ert-deftest teams4e-link-hint-card-and-attachment ()
  (with-temp-buffer
    (teams4e-chat-mode)
    (let ((inhibit-read-only t))
      (teams4e--insert-card-link "Design" "https://example.invalid/design" "")
      (teams4e--insert-attachments
       '((attachments . (((name . "Plan.pdf")
                           (contentUrl . "https://example.invalid/plan"))))))
      (goto-char (point-min))
      (teams4e-test-hint-link (point) "https://example.invalid/design")
      (search-forward "Plan.pdf")
      (teams4e-test-hint-link (- (point) (length "Plan.pdf"))
                              "https://example.invalid/plan"))))

(ert-deftest teams4e-link-hint-plain-renderer-html-link ()
  (skip-unless (libxml-available-p))
  (with-temp-buffer
    (teams4e-chat-mode)
    (let ((inhibit-read-only t)
          (teams4e-message-renderer 'plain))
      (teams4e--insert-message
       '((id . "message-link")
         (body . ((contentType . "html")
                  (content . "<p>See <a href=\"https://example.invalid/docs\">Docs</a></p>")))))
      (goto-char (point-min))
      (search-forward "Docs")
      (teams4e-test-hint-link (- (point) 4) "https://example.invalid/docs"))))

;;; teams4e-link-hint-tests.el ends here
