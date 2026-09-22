;;; teams4e-selection-tests.el --- Selection integration tests -*- lexical-binding: t; -*-

(require 'ert)
(require 'teams4e)
(require 'expand-region)
(require 'evil)

(ert-deftest teams4e-expand-region-stops-at-message-before-buffer ()
  (dolist (mode '(teams4e-chat-mode teams4e-channel-thread-mode))
    (with-temp-buffer
      (funcall mode)
      (let ((inhibit-read-only t)
            (transient-mark-mode t)
            (expand-region-smart-cursor nil)
            (teams4e-message-renderer 'plain))
        (insert "Day separator\n")
        (let ((start (point)))
          (teams4e--insert-message
           '((id . "first")
             (body . ((content . "<p>Alpha words</p><p>Beta paragraph</p>")))))
          (let ((end (point)))
            (insert "Another day\n")
            (teams4e--insert-message
             '((id . "second") (body . ((content . "Other message")))))
            (goto-char start)
            (search-forward "Alpha")
            (backward-char 2)
            (er--prepare-expanding)
            (let ((steps 0))
              (while (and (< steps 15)
                          (not (and (use-region-p)
                                    (= start (region-beginning))
                                    (= end (region-end)))))
                (er--expand-region-1)
                (cl-incf steps))
              (should (< steps 15)))
            (should (= start (region-beginning)))
            (should (= end (region-end)))
            (er/contract-region 1)
            (should (< (- (region-end) (region-beginning)) (- end start)))))))))

(ert-deftest teams4e-evil-region-copy-remains-standard ()
  (save-window-excursion
    (dolist (mode '(teams4e-chat-mode teams4e-channel-thread-mode))
      (with-temp-buffer
        (set-window-buffer (selected-window) (current-buffer))
        (funcall mode)
        (let ((inhibit-read-only t)) (insert "Alpha Beta"))
        (evil-local-mode 1)
        (dolist (state '(normal motion visual))
          (evil-change-state state)
          (evil-normalize-keymaps)
          (should (eq #'kill-ring-save (key-binding (kbd "M-w"))))
          (should (eq #'teams4e-mark-message (key-binding (kbd "M-h"))))
          (let ((transient-mark-mode t)
                (kill-ring nil))
            (goto-char (point-min))
            (push-mark (+ (point-min) 5) t t)
            (call-interactively (key-binding (kbd "M-w")))
            (should (equal "Alpha" (car kill-ring)))))))))

(ert-deftest teams4e-expand-region-does-not-change-unrelated-buffers ()
  (with-temp-buffer
    (text-mode)
    (should-not (memq #'teams4e-mark-message er/try-expand-list))))

;;; teams4e-selection-tests.el ends here
