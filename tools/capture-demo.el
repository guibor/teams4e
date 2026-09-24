;;; capture-demo.el --- Capture actual graphical teams4e buffers -*- lexical-binding: t; -*-
;; Run in an isolated graphical Emacs, not the user's current session.
;; See .github/workflows/capture.yml for pinned theme, font, and renderer.
(require 'cl-lib)
(require 'json)
(require 'teams4e)
(require 'moe-theme)
(require 'agent-shell-markdown)

(defconst teams4e-capture-output
  (expand-file-name ".tmp/capture" teams4e--package-directory))
(defconst teams4e-capture-data (make-temp-file "teams4e-capture-" t))

(defun teams4e-capture-wait (predicate)
  "Wait for real asynchronous state to satisfy PREDICATE, or fail."
  (let ((deadline (+ (float-time) 30)))
    (while (and (not (funcall predicate)) (< (float-time) deadline))
      (accept-process-output nil 0.05))
    (unless (funcall predicate) (error "Capture timed out waiting for Teams"))))

(defun teams4e-capture-settle ()
  "Let backend callbacks, window hooks, and fontification finish."
  (let ((until (+ (float-time) 1.0)))
    (while (< (float-time) until) (accept-process-output nil 0.05)))
  (dolist (window (window-list))
    (with-current-buffer (window-buffer window) (font-lock-ensure)))
  (message nil)
  (redisplay t)
  (sit-for 0.2))

(defun teams4e-capture-frame (name)
  "Save NAME as an unmodified PNG exported by graphical Emacs itself."
  (teams4e-capture-settle)
  (unless (and (display-graphic-p) (memq 'moe-dark custom-enabled-themes))
    (error "Capture requires a graphical frame and the real Moe Dark theme"))
  (let ((coding-system-for-write 'no-conversion))
    (write-region (x-export-frames nil 'png) nil
                  (expand-file-name name teams4e-capture-output) nil 'silent)))

(defun teams4e-capture-run ()
  "Exercise the real mock backend and photograph real UI states."
  (condition-case err
      (progn
        (make-directory teams4e-capture-output t)
        (setq teams4e-mock-mode t
              teams4e-mock-state-file (expand-file-name "mock.json" teams4e-capture-data)
              teams4e-cache-file (expand-file-name "cache.sqlite3" teams4e-capture-data)
              teams4e-state-file (expand-file-name "state.json" teams4e-capture-data)
              teams4e-draft-directory (expand-file-name "drafts" teams4e-capture-data)
              teams4e-image-cache-directory (expand-file-name "images" teams4e-capture-data)
              teams4e-credentials-file (expand-file-name "no-credentials.json" teams4e-capture-data)
              teams4e-token-command nil
              teams4e-bootstrap-program nil
              teams4e-preview-on-move nil
              teams4e-mark-read-on-open nil
              teams4e-cache-first nil
              teams4e-message-renderer 'agent-shell-markdown
              teams4e-use-persistent-backend nil
              teams4e-compose-editor 'org)
        (unless (zerop (call-process
                       "python3" nil "*Capture seed*" nil
                       (expand-file-name "tools/seed-demo.py" teams4e--package-directory)
                       teams4e-mock-state-file))
          (error "Cannot initialize synthetic tenant"))
        (unless (find-font (font-spec :family "Iosevka"))
          (error "Iosevka is required; do not substitute another font silently"))
        (let ((moe-theme--need-reload-theme t)) (moe-dark))
        (menu-bar-mode -1)
        (tool-bar-mode -1)
        (scroll-bar-mode -1)
        (blink-cursor-mode -1)
        (set-frame-font "Iosevka-12" nil t)
        (set-frame-size nil 180 46)
        (set-frame-position nil 0 0)
        (setq inhibit-startup-screen t)
        (teams4e-inbox)
        (teams4e-capture-wait
         (lambda () (and (teams4e--find-chat "mock-chat-atlas")
                         (get-buffer-window (teams4e--recent-buffer)))))
        (teams4e-capture-frame "inbox.png")
        (let ((chat (teams4e--find-chat "mock-chat-atlas")))
          (teams4e-open-chat chat)
          (teams4e-capture-wait
           (lambda ()
             (with-current-buffer teams4e--read-buffer-name
               (= (length teams4e--messages) 6))))
          (teams4e-capture-frame "thread.png")
          (teams4e-reply)
          (insert "Thanks, *Grace*. The remaining checks look good.\n\n"
                  "- [X] Pagination and offline cache\n"
                  "- [ ] Review keyboard navigation with Ada\n"
                  "- [ ] Add the draft-recovery test\n\n"
                  "I'll update the [[https://example.test/review][review notes]] before tomorrow.")
          (teams4e-capture-frame "reply.png")
          (teams4e-compose--delete-draft)
          (kill-buffer (current-buffer)))
        (switch-to-buffer (teams4e--recent-buffer))
        (delete-other-windows)
        (teams4e-meetings)
        (teams4e-capture-wait
         (lambda ()
           (and (eq teams4e--active-view 'upcoming)
                (with-current-buffer (teams4e--recent-buffer)
                  (>= (length tabulated-list-entries) 3)))))
        (teams4e-capture-frame "meetings.png")
        (with-temp-file (expand-file-name "capture.json" teams4e-capture-output)
          (insert (json-serialize
                   `((emacs . ,emacs-version)
                     (theme . "moe-dark") (font . "Iosevka-12")
                     (source . ,(or (getenv "GITHUB_SHA") "local checkout"))
                     (mock . t) (renderer . "agent-shell-markdown")
                     (method . "x-export-frames; no overlays or restyling")))))
        (kill-emacs 0))
    (error
     (with-temp-file (expand-file-name "error.txt" teams4e-capture-output)
       (insert (error-message-string err) "\n")
       (when (get-buffer "*Messages*")
         (insert (with-current-buffer "*Messages*" (buffer-string))))
       (when (get-buffer "*M365 Errors*")
         (insert (with-current-buffer "*M365 Errors*" (buffer-string)))))
     (kill-emacs 1))))

(run-with-timer 1 nil #'teams4e-capture-run)
;;; capture-demo.el ends here
