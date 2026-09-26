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

(defun teams4e-capture-check-meeting-alignment ()
  "Check real pixel positions for short, full-width and truncated meeting rows."
  (let ((buffer (generate-new-buffer " *Teams alignment check*")))
    (unwind-protect
        (save-window-excursion
          (switch-to-buffer buffer)
          (delete-other-windows)
          (teams4e-recent-mode)
          (let ((teams4e--active-view 'upcoming)
                (teams4e--active-query nil))
            (teams4e--configure-recent-format)
            (setq header-line-format "Teams meetings: synthetic alignment check"
                  tabulated-list-entries
                  (cl-loop for length in '(8 28 80 12)
                           for index from 0
                           collect
                           (list (number-to-string index)
                                 (apply #'vector
                                        (mapcar
                                         (lambda (text)
                                           (propertize text 'face
                                                       (and (cl-oddp index)
                                                            'teams4e-unread)))
                                         (list "" "Mon Sep 28 09:30-10:00"
                                               (make-string length ?M)
                                               "Tentative" "Microsoft Teams Meeting"
                                               "" "Example: agenda ready"))))))
            (tabulated-list-print)
            (dolist (width '(180 130))
              (set-frame-size nil width 38)
              (switch-to-buffer buffer)
              (goto-char (point-min))
              (set-window-start (selected-window) (point-min))
              (teams4e-capture-frame (format "meetings-alignment-%s.png" width))
              (dolist (column '("When" "Conversation" "Response" "Location" "Last message"))
                (let (positions)
                  (save-excursion
                    (goto-char (point-min))
                    (while (not (eobp))
                      (let* ((at (text-property-any
                                  (point) (line-end-position)
                                  'tabulated-list-column-name column))
                             (position (and at (posn-at-point at (selected-window)))))
                        (unless position
                          (error "Invisible %s at %S in %S; window %S, range %s-%s; row %S"
                                 column at (buffer-name)
                                 (buffer-name (window-buffer))
                                 (window-start) (window-end nil t)
                                 (buffer-substring-no-properties
                                  (line-beginning-position) (line-end-position))))
                        (push (car (posn-x-y position)) positions))
                      (forward-line 1)))
                  (unless (<= (- (apply #'max positions) (apply #'min positions)) 1)
                    (error "Misaligned %s column at width %s: %s"
                           column width positions))))
              (teams4e-capture-frame (format "meetings-alignment-%s.png" width)))))
      (set-frame-size nil 180 38)
      (kill-buffer buffer))))

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
        (set-frame-size nil 180 38)
        (set-frame-position nil 0 0)
        (setq inhibit-startup-screen t)
        (teams4e-capture-check-meeting-alignment)
        (teams4e-inbox)
        (teams4e-capture-wait
         (lambda () (and (teams4e--find-chat "mock-chat-atlas")
                         (get-buffer-window (teams4e--recent-buffer)))))
        (unless (string-match-p "Teams:" (format-mode-line global-mode-string))
          (error "Teams status failed to render in the default mode line"))
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
        (teams4e-open-chat (teams4e--find-chat "mock-chat-future-meeting"))
        (teams4e-capture-wait
         (lambda ()
           (with-current-buffer teams4e--read-buffer-name
             (and (teams4e--meeting-time-label teams4e--chat)
                  (save-excursion
                    (goto-char (point-min))
                    (search-forward "Video room 4" nil t))))))
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
