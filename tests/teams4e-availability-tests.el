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
       (let ((context (teams4e-test-availability-context)))
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
      (let (sent)
        (cl-letf (((symbol-function 'teams4e--proposal-send)
                   (lambda (_chat _event-id slot &rest _)
                     (setq sent slot))))
          (teams4e-availability-choose))
        (should sent)
        (should (= 2700 (float-time
                         (time-subtract
                          (teams4e-availability--time sent 'end)
                          (teams4e-availability--time sent 'start)))))))
    (teams4e-availability-show-blocks)
    (should-error (teams4e-availability-choose) :type 'user-error)))

(provide 'teams4e-availability-tests)
;;; teams4e-availability-tests.el ends here
