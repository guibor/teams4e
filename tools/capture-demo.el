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
    (unless (funcall predicate)
      (error "Capture timed out: view=%S query=%S rows=%S reader=%S"
             teams4e--active-view teams4e--active-query
             (with-current-buffer (teams4e--recent-buffer)
               (mapcar #'car tabulated-list-entries))
             (when (get-buffer teams4e--read-buffer-name)
               (with-current-buffer teams4e--read-buffer-name
                 (buffer-substring-no-properties (point-min) (point-max))))))))

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
              (dolist (column (mapcar (lambda (index)
                                        (car (aref tabulated-list-format index)))
                                      '(1 2 3 4 6)))
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
              ;; This timer-driven capture opens readers programmatically;
              ;; asynchronous headers redraws must not replace the chosen scene.
              teams4e--inhibit-reader-follow t
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
        ;; Select the row as a real RET command would, so headers-follow does
        ;; not replace this programmatically opened reader during async redraws.
        (switch-to-buffer (teams4e--recent-buffer))
        (teams4e--recent-goto-chat-id "mock-chat-future-meeting")
        (teams4e-open-chat (teams4e--find-chat "mock-chat-future-meeting"))
        (teams4e-capture-wait
         (lambda ()
           (with-current-buffer teams4e--read-buffer-name
             (and (teams4e--meeting-time-label teams4e--chat)
                  (save-excursion
                    (goto-char (point-min))
                    (search-forward "Video room 4" nil t))))))
        (teams4e-capture-frame "meetings.png")
        (teams4e-meeting-availability
         (teams4e--find-chat "mock-chat-future-meeting"))
        (teams4e-capture-wait
         (lambda ()
           (with-current-buffer teams4e--availability-buffer-name
             teams4e-availability--payload)))
        (switch-to-buffer teams4e--availability-buffer-name)
        ;; Keep seven synthetic participants visible to exercise a crowded matrix.
        (cl-loop for name in '("Katherine Johnson" "Alan Turing"
                               "Margaret Hamilton" "Edsger Dijkstra"
                               "Barbara Liskov" "Donald Knuth")
                 for index from 0
                 while (< (length (teams4e-availability--participants)) 7)
                 do
                 (let ((email (format "capture-%s@example.test" index)))
                   (setf (alist-get 'participants teams4e-availability--payload)
                         (append (teams4e-availability--participants)
                                 (list `((email . ,email) (name . ,name))))
                         (alist-get 'schedules teams4e-availability--payload)
                         (append (teams4e-availability--schedules)
                                 (list `((scheduleId . ,email) (scheduleItems)))))))
        (dolist (width '(180 130))
          (set-frame-size nil width 44)
          (dolist (view '(timeline availability proximity))
            (teams4e-availability-set-view view)
            (unless (> (length teams4e-availability--row-ids) 20)
              (error "Availability matrix has no continuous slots"))
            (teams4e-capture-frame
             (format "availability-%s-%s.png" view width))))
        (delete-other-windows)
        (when (require 'window-purpose nil t) (purpose-mode 1))
        (teams4e-calendar t)
        (teams4e-capture-wait
         (lambda ()
           (with-current-buffer teams4e-calendar--buffer-name
             (and (not teams4e-calendar--loading)
                  (not teams4e-calendar--error)
                  (seq-find (lambda (event)
                              (equal (teams4e--get event 'subject) "Focus: design review"))
                            teams4e-calendar--events)))))
        (switch-to-buffer teams4e-calendar--buffer-name)
        (delete-other-windows)
        (teams4e-capture-frame "calendar.png")
        (goto-char (point-min))
        (search-forward "C1 [+]")
        (beginning-of-line)
        (execute-kbd-macro (kbd "TAB"))
        (unless (save-excursion (search-forward "Availability /" nil t))
          (error "Expanded calendar conflict has no actions"))
        (recenter 2)
        (teams4e-capture-frame "calendar-folds.png")
        (execute-kbd-macro (kbd "TAB"))
        (goto-char (point-min))
        (search-forward "Focus: design review")
        (teams4e-calendar-open-event)
        (teams4e-capture-wait
         (lambda ()
           (with-current-buffer teams4e-calendar--detail-name
             (string-match-p "synthetic calendar event" (buffer-string)))))
        (teams4e-capture-frame "calendar-detail.png")
        (switch-to-buffer teams4e-calendar--buffer-name)
        (delete-other-windows)
        (goto-char (point-min))
        (search-forward "Planning")
        (teams4e-calendar-open-event)
        (unless (string-match-p "Overlapping events" (buffer-string))
          (error "Calendar conflict detail is missing"))
        (teams4e-capture-frame "calendar-conflicts.png")
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
