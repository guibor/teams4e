;;; teams4e-calendar-tests.el --- Calendar workspace tests -*- lexical-binding: t; -*-
(require 'ert)
(require 'teams4e)

(defun teams4e-calendar-test-event (id start end &rest extra)
  (append `((id . ,id) (subject . ,id)
            (start (dateTime . ,start) (timeZone . "UTC"))
            (end (dateTime . ,end) (timeZone . "UTC"))) extra))

(defmacro teams4e-calendar-test (&rest body)
  (declare (indent 0))
  `(let ((process-environment (copy-sequence process-environment)))
     (setenv "TZ" "UTC")
     (set-time-zone-rule "UTC")
     (unwind-protect
         (with-temp-buffer
           (teams4e-calendar-mode)
           (setq teams4e-calendar--date (date-to-time "2026-10-04T12:00:00Z"))
           ,@body)
       (set-time-zone-rule nil))))

(ert-deftest teams4e-calendar-ranges-respect-week-start-and-month ()
  (teams4e-calendar-test
    (let ((calendar-week-start-day 1))
      (should (equal (nth 1 (teams4e-calendar--key)) "2026-09-28T00:00:00Z"))
      (setq teams4e-calendar--view 'month)
      (should (equal (cdr (teams4e-calendar--key))
                     '("2026-10-01T00:00:00Z" "2026-11-01T00:00:00Z"))))))

(ert-deftest teams4e-calendar-day-range-crosses-dst ()
  (teams4e-calendar-test
    (set-time-zone-rule "America/New_York")
    (setq teams4e-calendar--view 'day
          teams4e-calendar--date (date-to-time "2026-11-01T12:00:00-05:00"))
    (should (equal (cdr (teams4e-calendar--key))
                   '("2026-11-01T04:00:00Z" "2026-11-02T05:00:00Z")))))

(ert-deftest teams4e-calendar-all-day-end-is-exclusive ()
  (teams4e-calendar-test
    (setq teams4e-calendar--events
          (list (teams4e-calendar-test-event
                 "all-day" "2026-10-04T00:00:00Z" "2026-10-06T00:00:00Z"
                 '(isAllDay . t))))
    (should (= 1 (length (teams4e-calendar--day-events (date-to-time "2026-10-04T00:00:00Z")))))
    (should (= 1 (length (teams4e-calendar--day-events (date-to-time "2026-10-05T00:00:00Z")))))
    (should-not (teams4e-calendar--day-events (date-to-time "2026-10-06T00:00:00Z")))))

(ert-deftest teams4e-calendar-filter-is-literal-reversible-and-local ()
  (teams4e-calendar-test
    (setq teams4e-calendar--events
          (list (teams4e-calendar-test-event "Review [A]" "2026-10-04T09:00:00Z" "2026-10-04T10:00:00Z")
                (teams4e-calendar-test-event "Other" "2026-10-04T11:00:00Z" "2026-10-04T12:00:00Z"))
          teams4e-calendar--loaded-key (teams4e-calendar--key))
    (cl-letf (((symbol-function 'teams4e--run-json) (lambda (&rest _) (ert-fail "Unexpected fetch"))))
      (teams4e-calendar-filter "[a]")
      (should (string-match-p "Review" (buffer-string)))
      (should-not (string-match-p "Other" (buffer-string)))
      (teams4e-calendar-filter "")
      (should (string-match-p "Other" (buffer-string))))))

(ert-deftest teams4e-calendar-cancelled-declined-are-toggleable ()
  (teams4e-calendar-test
    (let ((event '((id . "cancelled") (isCancelled . t))))
      (should-not (teams4e-calendar--visible-p event))
      (teams4e-calendar-toggle-declined)
      (should (teams4e-calendar--visible-p event)))))

(ert-deftest teams4e-calendar-late-response-cannot-replace-new-range ()
  (teams4e-calendar-test
    (let (callbacks)
      (cl-letf (((symbol-function 'teams4e--require-online) #'ignore)
                ((symbol-function 'teams4e--run-json)
                 (lambda (_args callback &optional _err) (push callback callbacks) nil)))
        (teams4e-calendar-refresh)
        (teams4e-calendar-next-period)
        (funcall (car callbacks) '((events ((id . "new"))) (complete . t)))
        (funcall (cadr callbacks) '((events ((id . "old"))) (complete . t)))
        (should (equal "new" (teams4e--get (car teams4e-calendar--events) 'id)))))))

(ert-deftest teams4e-calendar-return-to-loaded-range-cancels-newer-request ()
  (teams4e-calendar-test
    (let ((original teams4e-calendar--date) callback)
      (setq teams4e-calendar--loaded-key (teams4e-calendar--key)
            teams4e-calendar--events '(((id . "original"))))
      (cl-letf (((symbol-function 'teams4e--require-online) #'ignore)
                ((symbol-function 'teams4e--run-json)
                 (lambda (_args fn &optional _err) (setq callback fn) nil)))
        (teams4e-calendar-next-period)
        (setq teams4e-calendar--date original)
        (teams4e-calendar--show-range)
        (funcall callback '((events ((id . "wrong"))) (complete . t)))
        (should (equal "original" (teams4e--get (car teams4e-calendar--events) 'id)))
        (should-not teams4e-calendar--loading)))))

(ert-deftest teams4e-calendar-partial-is-not-reported-as-free ()
  (teams4e-calendar-test
    (setq teams4e-calendar--loaded-key (teams4e-calendar--key)
          teams4e-calendar--error "HTTP 429: incomplete")
    (teams4e-calendar--render)
    (should (string-match-p "incomplete" (buffer-string)))
    (should-not (string-match-p "No matching events" (buffer-string)))))

(ert-deftest teams4e-calendar-occurrences-are-separate-rows ()
  (teams4e-calendar-test
    (setq teams4e-calendar--events
          (list (teams4e-calendar-test-event "first" "2026-10-04T09:00:00Z" "2026-10-04T10:00:00Z" '(seriesMasterId . "series"))
                (teams4e-calendar-test-event "second" "2026-10-05T09:00:00Z" "2026-10-05T10:00:00Z" '(seriesMasterId . "series")))
          teams4e-calendar--loaded-key (teams4e-calendar--key))
    (let ((calendar-week-start-day 0))
      (teams4e-calendar--render)
      (goto-char (point-min))
      (teams4e-calendar-next-event)
      (should (equal "first" (teams4e--get (cadr (teams4e-calendar--context)) 'id)))
      (teams4e-calendar-next-event)
      (should (equal "second" (teams4e--get (cadr (teams4e-calendar--context)) 'id)))
      (teams4e-calendar-previous-event)
      (should (equal "first" (teams4e--get (cadr (teams4e-calendar--context)) 'id))))))

(ert-deftest teams4e-calendar-open-resumes-without-fetch ()
  (save-window-excursion
    (let ((teams4e-calendar--buffer-name " *calendar test resume*") (calls 0))
      (unwind-protect
          (cl-letf (((symbol-function 'teams4e-calendar-refresh) (lambda () (cl-incf calls))))
            (teams4e-calendar)
            (teams4e-calendar)
            (should (= calls 1))
            (teams4e-calendar t)
            (should (= calls 2)))
        (when-let ((buffer (get-buffer teams4e-calendar--buffer-name))) (kill-buffer buffer))))))

(ert-deftest teams4e-calendar-detail-refers-to-owner-snapshot ()
  (teams4e-calendar-test
    (setq teams4e-calendar--loaded-key (teams4e-calendar--key)
          teams4e-calendar--events
          (list (teams4e-calendar-test-event "appointment" "2026-10-04T09:00:00Z" "2026-10-04T10:00:00Z"
                                           '(body (contentType . "text") (content . "Some details")))))
    (let ((owner (current-buffer)))
      (with-temp-buffer
        (teams4e-calendar-event-mode)
        (setq teams4e-calendar--owner owner teams4e-calendar--event-id "appointment")
        (teams4e-calendar--render-detail)
        (should (string-match-p "Some details" (buffer-string)))))))

(ert-deftest teams4e-calendar-detail-merge-retains-new-fields ()
  (teams4e-calendar-test
    (setq teams4e-calendar--events '(((id . "one") (subject . "Original"))))
    (teams4e-calendar--replace-event
     '((id . "one") (body (content . "Details"))))
    (should (equal "Details" (teams4e--dig (car teams4e-calendar--events) 'body 'content)))
    (should (equal "Original" (teams4e--get (car teams4e-calendar--events) 'subject)))))

(ert-deftest teams4e-calendar-availability-has-no-fake-chat ()
  (save-window-excursion
    (teams4e-calendar-test
      (setq teams4e-calendar--loaded-key (teams4e-calendar--key)
            teams4e-calendar--events
            (list (teams4e-calendar-test-event "invite" "2026-10-04T09:00:00Z" "2026-10-04T10:00:00Z")))
      (teams4e-calendar--render)
      (goto-char (point-min))
      (teams4e-calendar-next-event)
      (let ((teams4e--availability-buffer-name " *calendar availability test*"))
        (unwind-protect
            (cl-letf (((symbol-function 'teams4e--require-online) #'ignore)
                      ((symbol-function 'teams4e-availability--request) #'ignore))
              (teams4e-calendar-availability)
              (should (equal "invite" teams4e-availability--event-id))
              (should-not teams4e-availability--chat)
              (should (equal "invite" (teams4e-availability--title)))
              (should (eq teams4e-availability--proposal-function #'teams4e-calendar--propose)))
          (when-let ((buffer (get-buffer teams4e--availability-buffer-name))) (kill-buffer buffer)))))))

(ert-deftest teams4e-calendar-rsvp-uses-event-id-and-empty-note ()
  (teams4e-calendar-test
    (let (args)
      (setq teams4e-calendar--loaded-key (teams4e-calendar--key)
            teams4e-calendar--events
            (list (teams4e-calendar-test-event "invite" "2026-10-04T09:00:00Z" "2026-10-04T10:00:00Z"
                                             '(attendees ((emailAddress (address . "person@example.test")))))))
      (teams4e-calendar--render)
      (goto-char (point-min))
      (teams4e-calendar-next-event)
      (cl-letf (((symbol-function 'teams4e--require-online) #'ignore)
                ((symbol-function 'completing-read) (lambda (&rest _) "accepted"))
                ((symbol-function 'read-string) (lambda (&rest _) ""))
                ((symbol-function 'teams4e--run-json)
                 (lambda (command _callback &optional _err) (setq args command))))
        (teams4e-calendar-respond)
        (should (equal args '("teams" "meeting" "respond" "--eventId" "invite"
                              "--response" "accepted" "--comment" "")))))))

(ert-deftest teams4e-calendar-appointment-cannot-rsvp ()
  (teams4e-calendar-test
    (setq teams4e-calendar--loaded-key (teams4e-calendar--key)
          teams4e-calendar--events
          (list (teams4e-calendar-test-event "personal" "2026-10-04T09:00:00Z" "2026-10-04T10:00:00Z"
                                           '(isOrganizer . t))))
    (teams4e-calendar--render)
    (goto-char (point-min))
    (teams4e-calendar-next-event)
    (cl-letf (((symbol-function 'teams4e--require-online) #'ignore)
              ((symbol-function 'teams4e--run-json) (lambda (&rest _) (ert-fail "Mutation requested"))))
      (should-error (teams4e-calendar-respond) :type 'user-error))))

(ert-deftest teams4e-calendar-capture-is-metadata-not-calendar-sync ()
  (teams4e-calendar-test
    (setq teams4e-calendar--loaded-key (teams4e-calendar--key)
          teams4e-calendar--events
          (list (teams4e-calendar-test-event "event" "2026-10-04T09:00:00Z" "2026-10-04T10:00:00Z"
                                           '(webLink . "https://example.test/event")
                                           '(body (content . "Do not copy this entire body")))))
    (teams4e-calendar--render)
    (goto-char (point-min))
    (teams4e-calendar-next-event)
    (let (text)
      (cl-letf (((symbol-function 'org-capture-string)
                 (lambda (value &optional _key) (setq text value))))
        (teams4e-calendar-capture))
      (should (string-match-p "https://example.test/event" text))
      (should (string-match-p ":CALENDAR_EVENT_ID: event" text))
      (should-not (string-match-p "Do not copy" text)))))

(provide 'teams4e-calendar-tests)
;;; teams4e-calendar-tests.el ends here
