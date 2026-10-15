;;; teams4e-availability-tests.el --- Availability picker tests -*- lexical-binding: t; -*-
(unless (fboundp 'teams4e-test-availability-context)
  (load "teams4e-tests" nil t))

(defmacro teams4e-test-with-availability (&rest body)
  "Run BODY in a synthetic availability workspace with a three-day window."
  (declare (indent 0))
  `(let ((process-environment (copy-sequence process-environment))
         (teams4e-meeting-availability-interval 30))
     (setenv "TZ" "UTC")
     (with-temp-buffer
       (teams4e-availability-mode)
       (let ((context (copy-tree (teams4e-test-availability-context))))
         (setq teams4e-availability--chat (teams4e--get context 'chat)
               teams4e-availability--event-id "event-availability"
               teams4e-availability--payload (teams4e--get context 'payload)
               teams4e-availability--window
               (list (date-to-time "2099-08-10T00:00:00Z")
                     (date-to-time "2099-08-13T00:00:00Z"))))
       ,@body)))

(ert-deftest teams4e-availability-continuous-day-preserves-duration ()
  (teams4e-test-with-availability
    (should (eq teams4e-availability--view 'timeline))
    (let ((slots (teams4e-availability--suggestions)) previous)
      (should (= 48 (length slots)))
      (dolist (entry slots)
        (let* ((slot (teams4e--get entry 'meetingTimeSlot))
               (start (teams4e-availability--time slot 'start))
               (end (teams4e-availability--time slot 'end)))
          (should (= 2700 (float-time (time-subtract end start))))
          (when previous
            (should (= 1800 (float-time (time-subtract start previous)))))
          (setq previous start))))
    (teams4e-availability--render)
    (should (equal "09:00 - 09:45"
                   (teams4e-availability--time-label
                    (teams4e--get (teams4e-availability--selected-suggestion)
                                   'meetingTimeSlot))))
    (teams4e-availability-next)
    (should (equal teams4e-availability--selected-id
                   (get-text-property (point) 'teams4e-availability-id)))
    (should (string-match-p "09:30 - 10:15" (thing-at-point 'line t)))))

(ert-deftest teams4e-availability-day-navigation-is-local-and-reversible ()
  (teams4e-test-with-availability
    (cl-letf (((symbol-function 'teams4e--run-json)
               (lambda (&rest _) (ert-fail "Unexpected network request"))))
      (teams4e-availability-next-day)
      (should (equal "2099-08-11"
                     (format-time-string "%F" teams4e-availability--day)))
      (should (equal "09:00 - 09:45"
                     (teams4e-availability--time-label
                      (teams4e--get (teams4e-availability--selected-suggestion)
                                     'meetingTimeSlot))))
      (teams4e-availability-previous-day)
      (should (equal "2099-08-10"
                     (format-time-string "%F" teams4e-availability--day)))
      (teams4e-availability-next-day 2)
      (teams4e-availability-original-day)
      (should (equal "2099-08-10"
                     (format-time-string "%F" teams4e-availability--day))))
    (let (requested)
      (cl-letf (((symbol-function 'teams4e-availability--request)
                 (lambda () (setq requested t))))
        (teams4e-availability-previous-day)
        (should requested)
        (should (equal teams4e-availability--day
                       (car teams4e-availability--window)))))))

(ert-deftest teams4e-availability-rankings-have-different-stable-orders ()
  (teams4e-test-with-availability
    (teams4e-availability-show-proximity)
    (let* ((slots (teams4e-availability--suggestions))
           (first (teams4e--get (car slots) 'meetingTimeSlot))
           (original (teams4e-availability--original-time)))
      (should (equal original (teams4e-availability--time first 'start)))
      (let ((previous -1))
        (dolist (entry slots)
          (let ((distance
                 (abs (float-time
                       (time-subtract
                        (teams4e-availability--time
                         (teams4e--get entry 'meetingTimeSlot) 'start)
                        original)))))
            (should (>= distance previous))
            (setq previous distance)))))
    (teams4e-availability-show-suggestions)
    (let ((previous 101))
      (dolist (entry (teams4e-availability--suggestions))
        (let ((score (teams4e--get entry 'confidence)))
          (should (<= score previous))
          (setq previous score))))
    (should (string-match-p "09:00 - 09:45" (buffer-string)))
    (teams4e-availability-show-timeline)
    (should (= 48 (length teams4e-availability--row-ids)))))

(ert-deftest teams4e-availability-checks-whole-slot-and-missing-data ()
  (teams4e-test-with-availability
    (teams4e-availability-next-day)
    (let* ((participant (cadr (teams4e-availability--participants)))
           (slot (teams4e--get
                  (nth 19 (teams4e-availability--suggestions)) 'meetingTimeSlot))
           (schedule (teams4e-availability--schedule participant)))
      (nconc schedule '((error) (availabilityView)))
      ;; 09:30-10:15 overlaps the 10:00 busy block.
      (should (equal "busy" (teams4e-availability--slot-status participant slot)))
      (setf (alist-get 'error schedule) '((message . "Denied")))
      (should (equal "unknown" (teams4e-availability--slot-status participant slot)))
      (setf (alist-get 'error schedule) nil
            (alist-get 'scheduleItems schedule) nil
            (alist-get 'availabilityView schedule) (make-string 144 ?0))
      (aset (alist-get 'availabilityView schedule) (+ 48 20) ?2)
      (should (equal "busy" (teams4e-availability--slot-status participant slot)))
      (setf (alist-get 'availabilityView schedule) "0")
      (should (equal "unknown" (teams4e-availability--slot-status participant slot)))
      (setf (alist-get 'schedules teams4e-availability--payload) nil)
      (should (equal "unknown" (teams4e-availability--slot-status participant slot))))))

(ert-deftest teams4e-availability-local-days-handle-dst ()
  (let ((process-environment (copy-sequence process-environment)))
    (setenv "TZ" "America/New_York")
    (let* ((start (encode-time 0 0 0 8 3 2026))
           (end (teams4e-availability--midnight start 1)))
      (should (= (* 23 3600) (float-time (time-subtract end start)))))
    (let* ((start (encode-time 0 0 0 1 11 2026))
           (end (teams4e-availability--midnight start 1)))
      (should (= (* 25 3600) (float-time (time-subtract end start)))))))

(ert-deftest teams4e-availability-proposes-from-each-time-view ()
  (teams4e-test-with-availability
    (dolist (view '(timeline availability proximity))
      (teams4e-availability-set-view view)
      (setq teams4e-availability--submission nil)
      (when (equal (teams4e-availability--time
                    (teams4e--get (teams4e-availability--selected-suggestion) 'meetingTimeSlot) 'start)
                   (teams4e-availability--original-time))
        (teams4e-availability-next))
      (let (sent)
        (cl-letf (((symbol-function 'teams4e--proposal-send)
                   (lambda (_chat _event-id slot &rest _)
                     (setq sent slot))))
          (teams4e-availability-choose)
          (should-not sent)
          (teams4e-reschedule-submit))
        (should sent)
        (should (= 2700 (float-time
                         (time-subtract
                          (teams4e-availability--time sent 'end)
                          (teams4e-availability--time sent 'start)))))))
    (teams4e-availability-show-blocks)
    (should-error (teams4e-availability-choose) :type 'user-error)))

(ert-deftest teams4e-availability-day-context-shows-shared-blocks-and-hides-private ()
  (teams4e-test-with-availability
    (let ((slot (cadr (teams4e--get teams4e-availability--payload 'suggestions)))
          (output (generate-new-buffer " *calendar-context-test*")))
      (unwind-protect
          (progn
            (teams4e-availability--insert-day-context slot output)
            (with-current-buffer output
              (should (string-match-p "Customer review" (buffer-string)))
              (should (string-match-p "Room 12" (buffer-string)))
              (should (string-match-p "! 10:00 - 11:00" (buffer-string)))
              (should (string-match-p "Private block" (buffer-string)))
              (should-not (string-match-p "Board reshuffle\\|Secret room" (buffer-string)))
              (should (string-match-p "12:00 - 13:00" (buffer-string)))))
        (kill-buffer output)))))

(ert-deftest teams4e-availability-context-unknown-is-not-free ()
  (teams4e-test-with-availability
    (let ((output (generate-new-buffer " *calendar-context-test*")))
      (unwind-protect
          (progn
            (setf (alist-get 'schedules teams4e-availability--payload) nil)
            (teams4e-availability--insert-day-context
             (car (teams4e--get teams4e-availability--payload 'suggestions)) output)
            (with-current-buffer output
              (should (string-match-p "No event details shared" (buffer-string)))
              (should-not (string-match-p "No calendar blocks" (buffer-string)))))
        (kill-buffer output)))))

(ert-deftest teams4e-availability-context-window-follows-selection-and-closes ()
  (save-window-excursion
    (teams4e-test-with-availability
      (let ((owner (current-buffer)))
        (switch-to-buffer owner)
        (cl-letf (((symbol-function 'teams4e--run-json)
                   (lambda (&rest _) (ert-fail "Calendar pane must reuse loaded data"))))
          (teams4e-availability--render)
          (let ((pane (get-buffer teams4e-availability--context-name)))
            (should (get-buffer-window pane))
            (should (eq owner (buffer-local-value 'teams4e-availability-context--owner pane)))
            (let ((before (with-current-buffer pane (buffer-string))))
              (teams4e-availability-next)
              (should-not (equal before (with-current-buffer pane (buffer-string)))))
            (should (eq (current-buffer) owner))
            (let ((teams4e-availability--payload nil))
              (teams4e-availability--render-context)
              (should-not (buffer-live-p pane)))
            (teams4e-availability--render-context)
            (setq pane (get-buffer teams4e-availability--context-name))
            (teams4e-availability-toggle-calendar-context)
            (should-not (buffer-live-p pane))))))))

(ert-deftest teams4e-availability-context-supports-purpose-display-actions ()
  (skip-unless (fboundp 'purpose-mode))
  (let ((was-enabled purpose-mode))
    (unwind-protect
        (progn
          (purpose-mode 1)
          (save-window-excursion
            (teams4e-test-with-availability
              (switch-to-buffer (current-buffer))
              (teams4e-availability--render)
              (should (get-buffer-window teams4e-availability--context-name)))))
      (unless was-enabled (purpose-mode -1)))))

(ert-deftest teams4e-reschedule-removes-only-identified-own-occurrence ()
  (teams4e-test-with-availability
    (let* ((self (car (teams4e-availability--participants)))
           (other (cadr (teams4e-availability--participants)))
           (schedule (teams4e-availability--schedule self))
           (event (copy-tree (teams4e-availability--event)))
           (slot (copy-tree event)))
      (nconc schedule '((detailsComplete)))
      (setf (alist-get 'eventId event) teams4e-availability--event-id
            (alist-get 'status event) "busy"
            (alist-get 'detailsComplete schedule) t
            (alist-get 'scheduleItems schedule) (list event))
      (should (equal "free" (teams4e-availability--slot-status self slot)))
      (should-not (teams4e-availability--conflict-items self slot))
      (let ((different (copy-tree event)))
        (setf (alist-get 'eventId different) "another-event"
              (alist-get 'scheduleItems schedule) (list event different))
        (should (equal "busy" (teams4e-availability--slot-status self slot)))
        (should (= 1 (length (teams4e-availability--conflict-items self slot)))))
      (setf (alist-get 'scheduleItems schedule) (list event)
            (alist-get 'detailsComplete schedule) nil)
      (should (equal "busy" (teams4e-availability--slot-status self slot)))
      (nconc (teams4e-availability--schedule other) '((detailsComplete . t)))
      (setf (alist-get 'scheduleItems (teams4e-availability--schedule other)) (list event))
      (should (equal "busy" (teams4e-availability--slot-status other slot))))))

(ert-deftest teams4e-reschedule-review-manual-outside-range-is-unknown ()
  (teams4e-test-with-availability
    (require 'teams4e-reschedule)
    (let ((slot (teams4e-reschedule--slot (date-to-time "2099-08-20T09:00:00Z")
                                         (date-to-time "2099-08-20T09:45:00Z"))))
      (cl-letf (((symbol-function 'teams4e--run-json) (lambda (&rest _) (ert-fail "Review must not send"))))
        (teams4e-reschedule--review slot)
        (should (string-match-p "Review time proposal" (buffer-string)))
        (should (string-match-p "From  " (buffer-string)))
        (should (string-match-p "To    " (buffer-string)))
        (dolist (person (teams4e-availability--participants))
          (should (equal "unknown" (teams4e-availability--slot-status person slot))))
        (teams4e-reschedule-back)
        (should-not teams4e-availability--review-slot)))))

(ert-deftest teams4e-reschedule-common-free-preserves-duration-and-workdays ()
  (teams4e-test-with-availability
    (require 'teams4e-reschedule)
    (let ((teams4e-calendar-work-hours '(9 . 14))
          (teams4e-calendar-work-days '(0 1 2 3 4 5 6)))
      (setq teams4e-availability--day (date-to-time "2099-08-11T00:00:00Z"))
      (let ((runs (teams4e-reschedule--common-runs)))
        (should (= 3 (length runs)))
        (dolist (run runs)
          (should (= 2700 (float-time (time-subtract
                                      (teams4e-availability--time (nth 2 run) 'end)
                                      (teams4e-availability--time (nth 2 run) 'start))))))
        (should (equal "09:00" (format-time-string "%H:%M" (caar runs)))))
      (let ((teams4e-calendar-work-days nil))
        (should-not (teams4e-reschedule--common-runs)))
      (setf (alist-get 'schedules teams4e-availability--payload) nil)
      (should-not (teams4e-reschedule--common-runs)))))

(ert-deftest teams4e-reschedule-working-bounds-follow-dst ()
  (teams4e-test-with-availability
   (require 'teams4e-reschedule)
   (let ((process-environment (copy-sequence process-environment)))
     (setenv "TZ" "America/New_York")
     (let ((teams4e-calendar-work-hours '(0 . 24)))
       (dolist (entry '((8 3 23) (1 11 25)))
         (setq teams4e-availability--day (encode-time 0 0 0 (car entry) (cadr entry) 2026))
         (let ((bounds (teams4e-reschedule--day-bounds)))
           (should (= (* (nth 2 entry) 3600)
                      (float-time (time-subtract (cadr bounds) (car bounds)))))))))))

(ert-deftest teams4e-reschedule-default-keys-and-local-comparison ()
  (teams4e-test-with-availability
    (dolist (binding '(("D" . teams4e-reschedule-compare)
                       ("f" . teams4e-reschedule-common-free)
                       ("C-c C-c" . teams4e-reschedule-submit)
                       ("C-c C-k" . teams4e-reschedule-back)))
      (should (eq (lookup-key teams4e-availability-mode-map (kbd (car binding))) (cdr binding))))
    (cl-letf (((symbol-function 'teams4e--run-json) (lambda (&rest _) (ert-fail "Must stay local"))))
      (teams4e-reschedule-compare)
      (should (looking-at "Working-day comparison"))
      (teams4e-availability-next)
      (should (get-text-property (point) 'teams4e-availability-id)))))

(ert-deftest teams4e-reschedule-submit-is-explicit-and-not-repeatable ()
  (teams4e-test-with-availability
    (require 'teams4e-reschedule)
    (let ((slot (teams4e--get (car (teams4e--get teams4e-availability--payload 'suggestions)) 'meetingTimeSlot))
          (count 0))
      (cl-letf (((symbol-function 'teams4e--proposal-send) (lambda (&rest _) (cl-incf count))))
        (teams4e-reschedule--review slot)
        (should (= 0 count))
        (teams4e-reschedule-submit)
        (should (= 1 count))
        (should-error (teams4e-reschedule-submit) :type 'user-error)
        (should-error (teams4e-reschedule--review slot) :type 'user-error)
        (should-error (teams4e-availability--request) :type 'user-error)
        (should (= 1 count))
        (teams4e-availability--submission-failed (current-buffer) teams4e-availability--payload)
        (should (eq 'uncertain teams4e-availability--submission))
        (should-error (teams4e-reschedule-submit) :type 'user-error)))))

(ert-deftest teams4e-reschedule-grid-is-compact-and-clicking-only-reviews ()
  (teams4e-test-with-availability
    (require 'teams4e-reschedule)
    (let ((teams4e-calendar-work-hours '(9 . 18))
          (teams4e-calendar-work-days '(0 1 2 3 4 5 6))
          (inhibit-read-only t))
      (setq teams4e-availability--day (date-to-time "2099-08-11T00:00:00Z"))
      (cl-letf (((symbol-function 'window-body-width) (lambda (&rest _) 70))
                ((symbol-function 'teams4e--run-json) (lambda (&rest _) (ert-fail "Must stay local"))))
        (teams4e-reschedule--insert-day-map)
        (goto-char (point-min))
        (dotimes (_ 4)
          (should (<= (- (line-end-position) (line-beginning-position)) 70))
          (forward-line 1))
        (goto-char (point-min))
        (search-forward "You")
        (button-activate (next-button (point)))
        (should teams4e-availability--review-slot)
        (should-not teams4e-availability--submission)))))

(ert-deftest teams4e-reschedule-cancelled-note-restores-review ()
  (teams4e-test-with-availability
    (require 'teams4e-reschedule)
    (let ((slot (teams4e--get (car (teams4e--get teams4e-availability--payload 'suggestions)) 'meetingTimeSlot)))
      (teams4e-reschedule--review slot)
      (cl-letf (((symbol-function 'teams4e--proposal-send)
                 (lambda (&rest _) (signal 'quit nil))))
        (condition-case nil (teams4e-reschedule-submit) (quit nil)))
      (should-not teams4e-availability--submission)
      (should (equal slot teams4e-availability--review-slot)))))

(ert-deftest teams4e-reschedule-old-error-cannot-lock-new-workspace ()
  (teams4e-test-with-availability
    (setq teams4e-availability--submission 'sending)
    (teams4e-availability--submission-failed
     (current-buffer) (copy-tree teams4e-availability--payload))
    (should (eq 'sending teams4e-availability--submission))))

(provide 'teams4e-availability-tests)
;;; teams4e-availability-tests.el ends here
