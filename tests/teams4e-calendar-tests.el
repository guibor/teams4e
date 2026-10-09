;;; teams4e-calendar-tests.el --- Calendar workspace tests -*- lexical-binding: t; -*-
(require 'ert)
(require 'teams4e)
(require 'teams4e-calendar-create)

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
           (setq teams4e-calendar--date (date-to-time "2026-10-04T12:00:00Z")
                 teams4e-calendar--focus nil)
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
              (should (eq teams4e-availability--proposal-function #'teams4e-calendar--propose))
              (when (featurep 'evil)
                (evil-local-mode 1)
                (dolist (state '(normal motion))
                  (evil-change-state state)
                  (should (eq (key-binding (kbd "v")) #'teams4e-calendar-respond))
                  (should (eq (key-binding (kbd "J")) #'teams4e-calendar-join))
                  (should (eq (key-binding (kbd "o")) #'teams4e-calendar-open-outlook)))))
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

(ert-deftest teams4e-calendar-evil-keys-take-precedence ()
  (skip-unless (featurep 'evil))
  (let ((was-enabled evil-mode))
    (unwind-protect
        (progn
          (evil-mode 1)
          (teams4e-calendar-test
            (evil-local-mode 1)
            (evil-motion-state)
            (should (eq (key-binding (kbd "d")) #'teams4e-calendar-day))
            (should (eq (key-binding (kbd "m")) #'teams4e-calendar-month))
            (should (eq (key-binding (kbd "j")) #'teams4e-calendar-next-event))
            (should (eq (key-binding (kbd "J")) #'teams4e-calendar-next-event))
            (should (eq (key-binding (kbd "H")) #'teams4e-calendar-previous-day))
            (should (eq (key-binding (kbd ".")) #'teams4e-calendar-goto-date))
            (should (eq (key-binding (kbd "a")) #'teams4e-calendar-respond))))
      (unless was-enabled (evil-mode -1)))))

(ert-deftest teams4e-calendar-availability-is-not-rsvp ()
  (should (equal (teams4e-calendar--availability
                  '((showAs . "free") (responseStatus (response . "accepted"))))
                 '("Free" teams4e-calendar-free nil)))
  (should (equal (teams4e-calendar--availability
                  '((showAs . "busy") (responseStatus (response . "notResponded"))))
                 '("Busy" teams4e-calendar-busy t)))
  (should (nth 2 (teams4e-calendar--availability '((showAs . "tentative")))))
  (should (nth 2 (teams4e-calendar--availability '((showAs . "unknown")))))
  (should-not (nth 2 (teams4e-calendar--availability
                      '((showAs . "busy") (responseStatus (response . "declined")))))))

(ert-deftest teams4e-calendar-gaps-union-hidden-blocks-and-ignore-free-events ()
  (teams4e-calendar-test
    (let ((teams4e-calendar-work-days '(0)) (teams4e-calendar-work-hours '(9 . 14)))
      (setq teams4e-calendar--loaded-key (teams4e-calendar--key)
            teams4e-calendar--filter "visible"
            teams4e-calendar--events
            (list (teams4e-calendar-test-event "hidden" "2026-10-04T10:00:00Z" "2026-10-04T11:30:00Z" '(showAs . "busy"))
                  (teams4e-calendar-test-event "overlap" "2026-10-04T11:00:00Z" "2026-10-04T12:00:00Z" '(showAs . "tentative"))
                  (teams4e-calendar-test-event "visible" "2026-10-04T09:00:00Z" "2026-10-04T14:00:00Z" '(showAs . "free"))))
      (should
       (equal (mapcar (lambda (gap)
                        (mapcar (lambda (time) (format-time-string "%H:%M" time))
                                (seq-take gap 2)))
                      (teams4e-calendar--free-gaps teams4e-calendar--date))
              '(("09:00" "10:00") ("12:00" "14:00")))))))

(ert-deftest teams4e-calendar-gaps-require-complete-current-data ()
  (teams4e-calendar-test
    (let ((teams4e-calendar-work-days '(0)))
      (should-not (teams4e-calendar--free-gaps teams4e-calendar--date))
      (setq teams4e-calendar--loaded-key (teams4e-calendar--key))
      (should (teams4e-calendar--free-gaps teams4e-calendar--date))
      (let ((teams4e-calendar--loading t))
        (should-not (teams4e-calendar--free-gaps teams4e-calendar--date)))
      (let ((teams4e-calendar--error "incomplete"))
        (should-not (teams4e-calendar--free-gaps teams4e-calendar--date)))
      (let ((teams4e-calendar-free-gap-minutes nil))
        (should-not (teams4e-calendar--free-gaps teams4e-calendar--date))))))

(ert-deftest teams4e-calendar-all-day-busy-blocks-working-hours ()
  (teams4e-calendar-test
    (let ((teams4e-calendar-work-days '(0)))
      (setq teams4e-calendar--loaded-key (teams4e-calendar--key)
            teams4e-calendar--events
            (list (teams4e-calendar-test-event "OOF" "2026-10-04T00:00:00Z" "2026-10-05T00:00:00Z"
                                             '(isAllDay . t) '(showAs . "oof"))))
      (should-not (teams4e-calendar--free-gaps teams4e-calendar--date)))))

(ert-deftest teams4e-calendar-gaps-use-local-hours-across-dst ()
  (teams4e-calendar-test
    (set-time-zone-rule "America/New_York")
    (let ((teams4e-calendar-work-days '(0)) (teams4e-calendar-work-hours '(9 . 18)))
      (setq teams4e-calendar--view 'day
            teams4e-calendar--date (date-to-time "2026-11-01T12:00:00-05:00")
            teams4e-calendar--loaded-key (teams4e-calendar--key))
      (let ((gap (car (teams4e-calendar--free-gaps teams4e-calendar--date))))
        (should (equal "2026-11-01T14:00Z" (format-time-string "%Y-%m-%dT%H:%MZ" (car gap) t)))
        (should (= (* 9 3600) (- (cadr gap) (car gap))))))))

(ert-deftest teams4e-calendar-focus-now-selects-ongoing-row ()
  (teams4e-calendar-test
    (let ((teams4e-calendar-free-gap-minutes nil))
      (setq teams4e-calendar--loaded-key (teams4e-calendar--key)
            teams4e-calendar--focus (date-to-time "2026-10-04T12:15:00Z")
            teams4e-calendar--events
            (list (teams4e-calendar-test-event "all-day" "2026-10-04T00:00:00Z" "2026-10-05T00:00:00Z" '(isAllDay . t))
                  (teams4e-calendar-test-event "now" "2026-10-04T12:00:00Z" "2026-10-04T13:00:00Z")
                  (teams4e-calendar-test-event "later" "2026-10-04T15:00:00Z" "2026-10-04T16:00:00Z")))
      (teams4e-calendar--render)
      (should (equal "now" (get-text-property (point) 'teams4e-calendar-event)))
      (should-not teams4e-calendar--focus))))

(ert-deftest teams4e-calendar-focus-survives-loading-until-response ()
  (teams4e-calendar-test
    (let (callback)
      (setq teams4e-calendar--focus teams4e-calendar--date)
      (cl-letf (((symbol-function 'teams4e--require-online) #'ignore)
                ((symbol-function 'teams4e--run-json)
                 (lambda (_args fn &optional _error) (setq callback fn) nil)))
        (teams4e-calendar-refresh)
        (should teams4e-calendar--focus)
        (funcall callback
                 `((complete . t)
                   (events ,(teams4e-calendar-test-event "now" "2026-10-04T12:00:00Z" "2026-10-04T13:00:00Z"))))
        (should (equal "now" (get-text-property (point) 'teams4e-calendar-event)))
        (should-not teams4e-calendar--focus)))))

(ert-deftest teams4e-calendar-day-navigation-is-local-until-range-boundary ()
  (teams4e-calendar-test
    (let ((calendar-week-start-day 0) (calls 0))
      (setq teams4e-calendar--loaded-key (teams4e-calendar--key))
      (teams4e-calendar--render)
      (teams4e-calendar--focus-time teams4e-calendar--date)
      (cl-letf (((symbol-function 'teams4e-calendar-refresh) (lambda () (cl-incf calls))))
        (teams4e-calendar-next-day)
        (should (equal "2026-10-05" (get-text-property (point) 'teams4e-calendar-day)))
        (should (= calls 0))
        (teams4e-calendar-next-day 6)
        (should (= calls 1))
        (should (equal "2026-10-11" (format-time-string "%Y-%m-%d" teams4e-calendar--focus)))))))

(ert-deftest teams4e-calendar-event-navigation-skips-gaps-and-lands-on-title ()
  (teams4e-calendar-test
    (let ((teams4e-calendar-work-days '(0)))
      (setq teams4e-calendar--loaded-key (teams4e-calendar--key)
            teams4e-calendar--events
            (list (teams4e-calendar-test-event "one" "2026-10-04T10:00:00Z" "2026-10-04T11:00:00Z")
                  (teams4e-calendar-test-event "two" "2026-10-04T13:00:00Z" "2026-10-04T14:00:00Z")))
      (teams4e-calendar--render)
      (goto-char (point-min))
      (teams4e-calendar-next-event)
      (teams4e-calendar-next-event)
      (let ((last (point)))
        (teams4e-calendar-next-event)
        (should (= last (point))))
      (teams4e-calendar-previous-event)
      (should (get-text-property (point) 'teams4e-calendar-event-start))
      (should (equal "one" (get-text-property (point) 'teams4e-calendar-event)))
      (should (looking-at "  10:00"))
      (forward-line 1)
      (should-not (get-text-property (point) 'teams4e-calendar-event-start))
      (goto-char (point-min))
      (search-forward "Free in this calendar")
      (should-not (get-text-property (point) 'teams4e-calendar-event)))))

(ert-deftest teams4e-calendar-summary-navigation-visits-headings-and-entries ()
  (teams4e-calendar-test
    (setq-local teams4e-calendar-work-days '(0))
    (teams4e-calendar-test-conflicts)
    (let* ((day (teams4e-calendar--day-key teams4e-calendar--date))
           (summary (list 'summary day))
           (keys (list (list 'day-map day) summary (list 'summary-free summary)))
           (conflict (get-text-property (point) 'teams4e-calendar-item)))
      (setq keys (append keys (list (list 'summary-group summary "Needs response")
                                   (list 'summary-event summary "B")
                                   conflict
                                   (list 'summary-group summary "Organizing")
                                   (list 'summary-event summary "A"))))
      (goto-char (teams4e-calendar--find-item day))
      (dolist (key keys)
        (teams4e-calendar-next-event)
        (should (equal key (get-text-property (point) 'teams4e-calendar-item))))
      (dolist (key (cdr (reverse keys)))
        (teams4e-calendar-previous-event)
        (should (equal key (get-text-property (point) 'teams4e-calendar-item))))
      (goto-char (teams4e-calendar--find-item (car (last keys))))
      (teams4e-calendar-next-event)
      (should (equal (list 'event day "A")
                     (get-text-property (point) 'teams4e-calendar-item)))
      (teams4e-calendar-next-event)
      (should (equal (list 'event day "B")
                     (get-text-property (point) 'teams4e-calendar-item))))))

(ert-deftest teams4e-calendar-summary-navigation-includes-response-and-accepted ()
  (teams4e-calendar-test
    (setq teams4e-calendar--view 'day
          teams4e-calendar--loaded-key (teams4e-calendar--key)
          teams4e-calendar--events
          (list (teams4e-calendar-test-event
                 "waiting" "2026-10-04T10:00:00Z" "2026-10-04T11:00:00Z"
                 '(showAs . "busy") '(attendees . [((type . "required"))])
                 '(responseStatus (response . "notResponded")))
                (teams4e-calendar-test-event
                 "accepted" "2026-10-04T13:00:00Z" "2026-10-04T14:00:00Z"
                 '(showAs . "busy") '(responseStatus (response . "accepted")))))
    (teams4e-calendar--render)
    (let ((summary (list 'summary (teams4e-calendar--day-key teams4e-calendar--date))))
      (goto-char (teams4e-calendar--find-item (list 'summary-group summary "Needs response")))
      (teams4e-calendar-next-event)
      (should (equal "waiting" (teams4e--get (cadr (teams4e-calendar--context)) 'id)))
      (teams4e-calendar-next-event)
      (should (looking-at "    Accepted"))
      (teams4e-calendar-next-event)
      (should (equal "accepted" (teams4e--get (cadr (teams4e-calendar--context)) 'id)))
      (teams4e-calendar-previous-event)
      (should (looking-at "    Accepted")))))

(ert-deftest teams4e-calendar-summary-navigation-skips-conflict-metadata ()
  (teams4e-calendar-test
    (teams4e-calendar-test-conflicts)
    (teams4e-calendar-toggle-section)
    (teams4e-calendar-next-event)
    (should (equal "A" (get-text-property (point) 'teams4e-calendar-event)))
    (teams4e-calendar-next-event)
    (should (equal "B" (get-text-property (point) 'teams4e-calendar-event)))
    (should (get-text-property (point) 'teams4e-calendar-event-start))
    (teams4e-calendar-previous-event)
    (should (equal "A" (get-text-property (point) 'teams4e-calendar-event)))
    (teams4e-calendar-previous-event)
    (should (eq 'conflict (car (get-text-property (point) 'teams4e-calendar-item))))))

(defun teams4e-calendar-test-item-height (key)
  "Return the logical line count of rendered item KEY."
  (let ((start (teams4e-calendar--find-item key)))
    (should start)
    (count-lines start (next-single-property-change start 'teams4e-calendar-item nil (point-max)))))

(ert-deftest teams4e-calendar-duration-scaling-is-bounded-local-and-preserves-point ()
  (teams4e-calendar-test
    (setq-local teams4e-calendar-duration-scaled nil)
    (setq-local teams4e-calendar-minutes-per-row 30)
    (setq teams4e-calendar--view 'day
          teams4e-calendar--loaded-key (teams4e-calendar--key)
          teams4e-calendar--events
          (list (teams4e-calendar-test-event "short" "2026-10-04T10:00:00Z" "2026-10-04T10:30:00Z")
                (teams4e-calendar-test-event "long" "2026-10-04T12:00:00Z" "2026-10-04T15:00:00Z")
                (teams4e-calendar-test-event "huge" "2026-10-03T10:00:00Z" "2026-10-05T10:00:00Z")
                (teams4e-calendar-test-event "all" "2026-10-04T00:00:00Z" "2026-10-05T00:00:00Z"
                                            '(isAllDay . t))))
    (teams4e-calendar--render)
    (let* ((day (teams4e-calendar--day-key teams4e-calendar--date))
           (key (list 'event day "long"))
           (snapshot teams4e-calendar--events))
      (goto-char (teams4e-calendar--find-item key))
      (forward-line 1)
      (move-to-column 24)
      (cl-letf (((symbol-function 'teams4e--run-json)
                 (lambda (&rest _) (ert-fail "Display toggles must not fetch"))))
        (teams4e-calendar-toggle-duration)
        (should (eq snapshot teams4e-calendar--events))
        (should (equal key (get-text-property (point) 'teams4e-calendar-item)))
        (should (= 24 (current-column)))
        (dolist (spec '(("short" . 2) ("long" . 6) ("huge" . 12) ("all" . 2)))
          (should (= (cdr spec) (teams4e-calendar-test-item-height (list 'event day (car spec))))))
        ;; Padding is part of the canonical event; it does not add navigation stops.
        (goto-char (teams4e-calendar--find-item key))
        (forward-line 4)
        (should (equal "long" (teams4e--get (cadr (teams4e-calendar--context)) 'id)))
        (teams4e-calendar-previous-event)
        (should (equal "short" (get-text-property (point) 'teams4e-calendar-event)))
        (teams4e-calendar-toggle-duration)
        (should (= 2 (teams4e-calendar-test-item-height key)))))))

(ert-deftest teams4e-calendar-free-bands-cover-newlines-and-scaled-rows ()
  (teams4e-calendar-test
    (setq-local teams4e-calendar-work-days '(0))
    (setq-local teams4e-calendar-duration-scaled t)
    (setq-local teams4e-calendar-minutes-per-row 30)
    (setq teams4e-calendar--view 'day
          teams4e-calendar--loaded-key (teams4e-calendar--key)
          teams4e-calendar--events
          (list (teams4e-calendar-test-event "busy" "2026-10-04T10:00:00Z" "2026-10-04T11:00:00Z"
                                            '(showAs . "busy"))
                (teams4e-calendar-test-event "free invite" "2026-10-04T11:00:00Z" "2026-10-04T12:00:00Z"
                                            '(showAs . "free"))))
    (teams4e-calendar--render)
    (let* ((day (teams4e-calendar--day-key teams4e-calendar--date))
           (gap (car (teams4e-calendar--free-gaps (teams4e-calendar--midnight teams4e-calendar--date))))
           (key (list 'slot day (car gap) (cadr gap)))
           (start (teams4e-calendar--find-item key))
           (end (next-single-property-change start 'teams4e-calendar-item)))
      (should (= 2 (teams4e-calendar-test-item-height key)))
      (dotimes (i (- end start))
        (should (eq 'teams4e-calendar-free-slot (get-text-property (+ start i) 'face))))
      (goto-char (teams4e-calendar--find-item (list 'event day "free invite")))
      (should (eq 'teams4e-calendar-free (get-text-property (point) 'face))))))

(ert-deftest teams4e-calendar-summary-meta-navigation-and-scale-work-with-evil ()
  (skip-unless (featurep 'evil))
  (let ((enabled evil-mode))
    (unwind-protect
        (save-window-excursion
          (evil-mode 1)
          (teams4e-calendar-test
            (setq-local teams4e-calendar-duration-scaled nil)
            (switch-to-buffer (current-buffer))
            (teams4e-calendar-test-conflicts)
            (evil-local-mode 1)
            (let ((summary (list 'summary (teams4e-calendar--day-key teams4e-calendar--date))))
              (dolist (state '(normal motion))
                (evil-change-state state)
                (goto-char (teams4e-calendar--find-item (list 'summary-group summary "Needs response")))
                (execute-kbd-macro (kbd "M-j"))
                (should (equal "B" (get-text-property (point) 'teams4e-calendar-event)))
                (execute-kbd-macro (kbd "M-k"))
                (should (looking-at "    Needs response"))
                (execute-kbd-macro (kbd "j"))
                (should (equal "B" (get-text-property (point) 'teams4e-calendar-event)))
                (execute-kbd-macro (kbd "k"))
                (should (looking-at "    Needs response"))
                (execute-kbd-macro (kbd "S"))
                (should teams4e-calendar-duration-scaled)
                (execute-kbd-macro (kbd "S"))
                (should-not teams4e-calendar-duration-scaled)))))
      (unless enabled (evil-mode -1)))))

(ert-deftest teams4e-calendar-day-map-is-conservative-and-uses-exact-overlaps ()
  (teams4e-calendar-test
    (setq-local teams4e-calendar-work-days '(0))
    (setq-local teams4e-calendar-work-hours '(9 . 11))
    (setq teams4e-calendar--view 'day
          teams4e-calendar--loaded-key (teams4e-calendar--key)
          teams4e-calendar--filter "hidden"
          teams4e-calendar--events
          (list (teams4e-calendar-test-event "one" "2026-10-04T09:00:00Z" "2026-10-04T09:10:00Z" '(showAs . "busy"))
                (teams4e-calendar-test-event "two" "2026-10-04T09:10:00Z" "2026-10-04T09:20:00Z" '(showAs . "busy"))
                (teams4e-calendar-test-event "unknown" "2026-10-04T10:00:00Z" "2026-10-04T10:10:00Z")
                (teams4e-calendar-test-event "overlap1" "2026-10-04T10:30:00Z" "2026-10-04T10:45:00Z" '(showAs . "busy"))
                (teams4e-calendar-test-event "overlap2" "2026-10-04T10:40:00Z" "2026-10-04T11:00:00Z" '(showAs . "busy"))))
    (teams4e-calendar--render)
    (goto-char (teams4e-calendar--find-item (list 'day-map (teams4e-calendar--day-key teams4e-calendar--date))))
    (should (looking-at (regexp-quote "    09:00  ==..??!!  11:00")))
    (search-forward "==")
    (should (string-match-p "one" (get-text-property (1- (point)) 'help-echo)))
    (should-not (string-match-p "Overlapping" (get-text-property (1- (point)) 'help-echo)))
    (search-forward "..")
    (should (eq 'teams4e-calendar-free-slot (get-text-property (1- (point)) 'face)))
    (search-forward "??")
    (should (string-match-p "Unknown" (get-text-property (1- (point)) 'help-echo)))))

(ert-deftest teams4e-calendar-day-map-hides-incomplete-and-nonworking-days ()
  (teams4e-calendar-test
    (setq-local teams4e-calendar-work-days '(0))
    (setq teams4e-calendar--view 'day teams4e-calendar--loaded-key (teams4e-calendar--key))
    (let ((key (list 'day-map (teams4e-calendar--day-key teams4e-calendar--date))))
      (teams4e-calendar--render)
      (should (teams4e-calendar--find-item key))
      (dolist (variable '(teams4e-calendar--loading teams4e-calendar--error))
        (set variable t)
        (when (eq variable 'teams4e-calendar--error) (set variable "Partial"))
        (teams4e-calendar--render)
        (should-not (teams4e-calendar--find-item key))
        (set variable nil))
      (setq-local teams4e-calendar-work-days '(1))
      (teams4e-calendar--render)
      (should-not (teams4e-calendar--find-item key))
      (setq-local teams4e-calendar-work-days '(0))
      (setq-local teams4e-calendar-show-day-map nil)
      (teams4e-calendar--render)
      (should-not (teams4e-calendar--find-item key)))))

(ert-deftest teams4e-calendar-day-map-buttons-jump-without-fetching ()
  (teams4e-calendar-test
    (setq-local teams4e-calendar-work-days '(0))
    (teams4e-calendar-test-conflicts)
    (let ((key (list 'day-map (teams4e-calendar--day-key teams4e-calendar--date))))
      (goto-char (teams4e-calendar--find-item key))
      (let ((button (next-button (point))))
        (cl-letf (((symbol-function 'teams4e--run-json)
                   (lambda (&rest _) (ert-fail "The day map must not fetch"))))
          (button-activate button)))
      (should (equal "A" (get-text-property (point) 'teams4e-calendar-event))))))

(ert-deftest teams4e-calendar-free-finder-rounds-now-and-reuses-filtered-snapshot ()
  (teams4e-calendar-test
    (setq-local teams4e-calendar-work-days '(0))
    (setq teams4e-calendar--view 'day
          teams4e-calendar--loaded-key (teams4e-calendar--key)
          teams4e-calendar--filter "not shown"
          teams4e-calendar--events
          (list (teams4e-calendar-test-event "busy" "2026-10-04T10:00:00Z" "2026-10-04T11:00:00Z" '(showAs . "busy"))))
    (teams4e-calendar--render)
    (let (options)
      (cl-letf (((symbol-function 'current-time) (lambda () (date-to-time "2026-10-04T09:12:00Z")))
                ((symbol-function 'completing-read)
                 (lambda (_ choices &rest _) (setq options choices) (caar choices)))
                ((symbol-function 'teams4e--run-json) (lambda (&rest _) (ert-fail "Finding time must not fetch"))))
        (teams4e-calendar-find-free-slot 30)
        (should (= 2 (length options)))
        (should (string-match-p "09:15 - 10:00.*45 min" (caar options)))
        (should (eq 'slot (car (get-text-property (point) 'teams4e-calendar-item))))
        (teams4e-calendar-find-free-slot 60)
        (should (= 1 (length options)))
        (should (string-match-p "11:00 - 18:00" (caar options)))))))

(ert-deftest teams4e-calendar-free-finder-rejects-stale-empty-and-invalid-choices ()
  (teams4e-calendar-test
    (setq-local teams4e-calendar-work-days '(0))
    (setq teams4e-calendar--view 'day)
    (should-error (teams4e-calendar-find-free-slot 30) :type 'user-error)
    (setq teams4e-calendar--loaded-key (teams4e-calendar--key))
    (teams4e-calendar--render)
    (should-error (teams4e-calendar-find-free-slot 0) :type 'user-error)
    (cl-letf (((symbol-function 'current-time) (lambda () (date-to-time "2026-10-04T19:00:00Z"))))
      (should-error (teams4e-calendar-find-free-slot 30) :type 'user-error))
    (cl-letf (((symbol-function 'current-time) (lambda () (date-to-time "2026-10-04T09:00:00Z")))
              ((symbol-function 'completing-read)
               (lambda (_ choices &rest _)
                 ;; A refresh can finish while the minibuffer is open.
                 (setq teams4e-calendar--loading t)
                 (teams4e-calendar--render)
                 (caar choices))))
      (should-error (teams4e-calendar-find-free-slot 30) :type 'user-error))))

(ert-deftest teams4e-calendar-response-queue-wraps-skips-past-and-respects-filter ()
  (teams4e-calendar-test
    (setq teams4e-calendar--view 'day
          teams4e-calendar--loaded-key (teams4e-calendar--key)
          teams4e-calendar--events
          (cl-loop for id in '("past" "one" "two" "accepted" "free")
                   for hour from 8
                   collect (teams4e-calendar-test-event
                            id (format "2026-10-04T%02d:00:00Z" hour)
                            (format "2026-10-04T%02d:30:00Z" hour)
                            `(showAs . ,(if (equal id "free") "free" "busy"))
                            '(attendees ((emailAddress (address . "guest@example.test"))))
                            `(responseStatus (response . ,(if (equal id "accepted") "accepted" "notResponded"))))))
    (teams4e-calendar--render)
    (goto-char (point-min))
    (cl-letf (((symbol-function 'current-time) (lambda () (date-to-time "2026-10-04T08:45:00Z")))
              ((symbol-function 'teams4e--run-json) (lambda (&rest _) (ert-fail "Browsing response queue must not send"))))
      (dolist (id '("one" "two" "one"))
        (teams4e-calendar-next-response)
        (should (equal id (get-text-property (point) 'teams4e-calendar-event))))
      (teams4e-calendar-next-response t)
      (should (equal "two" (get-text-property (point) 'teams4e-calendar-event)))
      (forward-line 1)
      (teams4e-calendar-next-response t)
      (should (equal "one" (get-text-property (point) 'teams4e-calendar-event)))
      (teams4e-calendar-filter "one")
      (teams4e-calendar-next-response)
      (should (equal "one" (get-text-property (point) 'teams4e-calendar-event)))
      (teams4e-calendar-filter "accepted")
      (should-error (teams4e-calendar-next-response) :type 'user-error))))

(ert-deftest teams4e-calendar-free-slot-draft-fits-gap-even-from-padding ()
  (teams4e-calendar-test
    (setq-local teams4e-calendar-work-days '(0))
    (setq-local teams4e-calendar-duration-scaled t)
    (setq teams4e-calendar--view 'day
          teams4e-calendar--id "selected-calendar"
          teams4e-calendar--loaded-key (teams4e-calendar--key)
          teams4e-calendar--events
          (list (teams4e-calendar-test-event "busy" "2026-10-04T09:30:00Z" "2026-10-04T18:00:00Z" '(showAs . "busy"))))
    (teams4e-calendar--render)
    (goto-char (point-min))
    (search-forward "[FREE]")
    (forward-line 1)
    (let (draft)
      (unwind-protect
          (cl-letf (((symbol-function 'current-time) (lambda () (date-to-time "2026-10-04T09:12:00Z")))
                    ((symbol-function 'teams4e--run-json) (lambda (&rest _) (ert-fail "Drafting must not send")))
                    ((symbol-function 'pop-to-buffer) (lambda (buffer &rest _) (setq draft buffer))))
            (teams4e-calendar-create)
            (with-current-buffer draft
              (should (equal "2026-10-04T09:15:00+0000" (teams4e-calendar-compose--get "START_AT")))
              (should (equal "2026-10-04T09:30:00+0000" (teams4e-calendar-compose--get "END_AT")))
              (should (equal "selected-calendar" (teams4e-calendar-compose--get "CALENDAR_ID")))))
        (when (buffer-live-p draft) (kill-buffer draft))))))

(ert-deftest teams4e-calendar-free-slot-draft-rejects-expired-and-incomplete ()
  (teams4e-calendar-test
    (setq-local teams4e-calendar-work-days '(0))
    (setq teams4e-calendar--view 'day teams4e-calendar--loaded-key (teams4e-calendar--key))
    (teams4e-calendar--render)
    (goto-char (point-min))
    (search-forward "[FREE]")
    (cl-letf (((symbol-function 'current-time) (lambda () (date-to-time "2026-10-04T19:00:00Z"))))
      (should-error (teams4e-calendar-create) :type 'user-error))
    (setq teams4e-calendar--loading t)
    (should-error (teams4e-calendar-create) :type 'user-error)))

(ert-deftest teams4e-calendar-planning-keys-take-precedence-in-evil ()
  (skip-unless (featurep 'evil))
  (teams4e-calendar-test
    (evil-local-mode 1)
    (dolist (state '(normal motion))
      (evil-change-state state)
      (should (eq (key-binding (kbd "F")) #'teams4e-calendar-find-free-slot))
      (should (eq (key-binding (kbd "!")) #'teams4e-calendar-next-response)))))

(ert-deftest teams4e-calendar-jump-uses-unique-visible-occurrences-without-filter-changes ()
  (teams4e-calendar-test
    (setq teams4e-calendar--view 'day
          teams4e-calendar--filter "Same"
          teams4e-calendar--loaded-key (teams4e-calendar--key)
          teams4e-calendar--events
          (cl-loop for id in '("one" "two" "hidden")
                   collect (teams4e-calendar-test-event
                            id "2026-10-04T10:00:00Z" "2026-10-04T11:00:00Z"
                            '(isOrganizer . t))))
    (dolist (event teams4e-calendar--events)
      (unless (equal (teams4e--get event 'id) "hidden")
        (setf (alist-get 'subject event) "Same title")))
    (teams4e-calendar--render)
    (cl-letf (((symbol-function 'completing-read)
               (lambda (_ choices &rest _)
                 (should (= 2 (length choices)))
                 (should-not (equal (caar choices) (caadr choices)))
                 (caadr choices)))
              ((symbol-function 'teams4e--run-json) (lambda (&rest _) (ert-fail "Jump must not fetch"))))
      (teams4e-calendar-jump-event))
    (should (equal "two" (get-text-property (point) 'teams4e-calendar-event)))
    (should (eq 'event (car (get-text-property (point) 'teams4e-calendar-item))))
    (should (equal "Same" teams4e-calendar--filter))))

(ert-deftest teams4e-calendar-jump-handles-vanished-events ()
  (teams4e-calendar-test
    (teams4e-calendar-test-conflicts)
    (cl-letf (((symbol-function 'completing-read)
               (lambda (_ choices &rest _)
                 (setq teams4e-calendar--events nil)
                 (teams4e-calendar--render)
                 (caar choices))))
      (should-error (teams4e-calendar-jump-event) :type 'user-error))
    (should-error (teams4e-calendar-jump-event) :type 'user-error)))

(ert-deftest teams4e-calendar-conflict-cycle-opens-folded-actions-and-keeps-filter ()
  (teams4e-calendar-test
    (teams4e-calendar-test-conflicts)
    (push (teams4e-calendar-test-event "C" "2026-10-04T11:30:00Z" "2026-10-04T12:30:00Z"
                                     '(showAs . "busy")) teams4e-calendar--events)
    (setq teams4e-calendar--filter "nothing matches")
    (teams4e-calendar--render)
    (let* ((day (teams4e-calendar--midnight teams4e-calendar--date))
           (summary (list 'summary (teams4e-calendar--day-key day)))
           (keys (mapcar (lambda (segment) (teams4e-calendar--conflict-key day segment))
                         (teams4e-calendar--conflicts day))))
      (should (= 2 (length keys)))
      (goto-char (teams4e-calendar--find-item summary))
      (teams4e-calendar-toggle-section)
      (cl-letf (((symbol-function 'teams4e--run-json) (lambda (&rest _) (ert-fail "Conflict cycle must not fetch"))))
        (teams4e-calendar-next-conflict)
        (should (equal (car keys) (get-text-property (point) 'teams4e-calendar-section)))
        (should (teams4e-calendar--section-open-p summary))
        (should (teams4e-calendar--section-open-p (car keys)))
        (should (save-excursion (search-forward "Availability /" nil t)))
        (teams4e-calendar-next-conflict)
        (should (equal (cadr keys) (get-text-property (point) 'teams4e-calendar-section)))
        (teams4e-calendar-next-conflict)
        (should (equal (car keys) (get-text-property (point) 'teams4e-calendar-section)))
        (teams4e-calendar-previous-conflict)
        (should (equal (cadr keys) (get-text-property (point) 'teams4e-calendar-section))))
      (should (equal "nothing matches" teams4e-calendar--filter)))))

(ert-deftest teams4e-calendar-conflict-cycle-rejects-empty-and-incomplete ()
  (teams4e-calendar-test
    (should-error (teams4e-calendar-next-conflict) :type 'user-error)
    (setq teams4e-calendar--loaded-key (teams4e-calendar--key))
    (should-error (teams4e-calendar-next-conflict) :type 'user-error)
    (teams4e-calendar-test-conflicts)
    (setq teams4e-calendar--loading t)
    (should-error (teams4e-calendar-next-conflict) :type 'user-error)))

(ert-deftest teams4e-calendar-focus-draft-is-personal-and-does-not-change-defaults ()
  (teams4e-calendar-test
    (setq-local teams4e-calendar-work-days '(0))
    (setq teams4e-calendar--view 'day
          teams4e-calendar--id "other-calendar"
          teams4e-calendar--loaded-key (teams4e-calendar--key))
    (teams4e-calendar--render)
    (goto-char (point-min))
    (search-forward "[FREE]")
    (let ((teams4e-calendar-new-online-meeting t) draft)
      (unwind-protect
          (cl-letf (((symbol-function 'current-time) (lambda () (date-to-time "2026-10-04T09:12:00Z")))
                    ((symbol-function 'pop-to-buffer) (lambda (buffer &rest _) (setq draft buffer)))
                    ((symbol-function 'completing-read) (lambda (&rest _) (ert-fail "The current slot fits")))
                    ((symbol-function 'teams4e--run-json) (lambda (&rest _) (ert-fail "Drafts must not send"))))
            (should (eq (teams4e-calendar-block-time 45) draft))
            (should teams4e-calendar-new-online-meeting)
            (with-current-buffer draft
              (let ((payload (teams4e-calendar-compose--payload)))
                (should (equal "Focus time" (alist-get 'subject payload)))
                (should (eq :json-false (alist-get 'online payload)))
                (should (equal [] (alist-get 'required payload)))
                (should (equal [] (alist-get 'optional payload)))
                (should (equal "busy" (alist-get 'showAs payload)))
                (should (equal "2026-10-04T09:15:00Z" (alist-get 'start payload)))
                (should (equal "2026-10-04T10:00:00Z" (alist-get 'end payload))))
              (should (equal "other-calendar" (teams4e-calendar-compose--get "CALENDAR_ID")))
              (should-not teams4e-calendar-compose--pending)))
        (when (buffer-live-p draft) (kill-buffer draft))))))

(ert-deftest teams4e-calendar-focus-offers-a-fitting-slot-instead-of-spilling ()
  (teams4e-calendar-test
    (setq-local teams4e-calendar-work-days '(0))
    (setq teams4e-calendar--view 'day
          teams4e-calendar--loaded-key (teams4e-calendar--key)
          teams4e-calendar--events
          (list (teams4e-calendar-test-event "busy" "2026-10-04T10:00:00Z" "2026-10-04T11:00:00Z" '(showAs . "busy"))))
    (teams4e-calendar--render)
    (goto-char (point-min))
    (search-forward "[FREE]")
    (let (draft chosen)
      (unwind-protect
          (cl-letf (((symbol-function 'current-time) (lambda () (date-to-time "2026-10-04T09:12:00Z")))
                    ((symbol-function 'pop-to-buffer) (lambda (buffer &rest _) (setq draft buffer)))
                    ((symbol-function 'completing-read)
                     (lambda (_ choices &rest _) (setq chosen t) (caar choices)))
                    ((symbol-function 'teams4e--run-json) (lambda (&rest _) (ert-fail "Focus drafting must not send"))))
            (teams4e-calendar-block-time 60)
            (should chosen)
            (with-current-buffer draft
              (should (equal "2026-10-04T11:00:00+0000" (teams4e-calendar-compose--get "START_AT")))
              (should (equal "2026-10-04T12:00:00+0000" (teams4e-calendar-compose--get "END_AT")))))
        (when (buffer-live-p draft) (kill-buffer draft))))))

(ert-deftest teams4e-calendar-focus-rejects-invalid-stale-and-no-longer-fitting-slots ()
  (teams4e-calendar-test
    (should-error (teams4e-calendar-block-time 0) :type 'user-error)
    (should-error (teams4e-calendar-block-time 60) :type 'user-error)
    (setq-local teams4e-calendar-work-days '(0))
    (setq teams4e-calendar--view 'day teams4e-calendar--loaded-key (teams4e-calendar--key))
    (teams4e-calendar--render)
    (goto-char (point-min))
    (let ((now (date-to-time "2026-10-04T09:00:00Z")))
      (cl-letf (((symbol-function 'current-time) (lambda () now))
                ((symbol-function 'completing-read)
                 (lambda (_ choices &rest _)
                   (setq now (date-to-time "2026-10-04T17:45:00Z"))
                   (caar choices)))
                ((symbol-function 'teams4e-calendar-create) (lambda () (ert-fail "Slot no longer fits"))))
        (should-error (teams4e-calendar-block-time 60) :type 'user-error)))))

(ert-deftest teams4e-calendar-shortcut-keys-remain-customizable-in-evil ()
  (skip-unless (featurep 'evil))
  (teams4e-calendar-test
    (evil-local-mode 1)
    (dolist (state '(normal motion))
      (evil-change-state state)
      (dolist (binding '(("s" . teams4e-calendar-jump-event)
                         ("}" . teams4e-calendar-next-conflict)
                         ("{" . teams4e-calendar-previous-conflict)
                         ("B" . teams4e-calendar-block-time)))
        (should (eq (key-binding (kbd (car binding))) (cdr binding)))))
    (let ((teams4e-calendar-mode-map (copy-keymap teams4e-calendar-mode-map)))
      (define-key teams4e-calendar-mode-map (kbd "s") #'ignore)
      (teams4e-calendar--install-navigation)
      (should (eq (key-binding (kbd "s")) #'ignore)))))

(ert-deftest teams4e-calendar-redraw-preserves-multi-day-occurrence-position ()
  (teams4e-calendar-test
    (let ((calendar-week-start-day 0))
      (setq teams4e-calendar--loaded-key (teams4e-calendar--key)
            teams4e-calendar--events
            (list (teams4e-calendar-test-event "multi" "2026-10-04T00:00:00Z" "2026-10-07T00:00:00Z" '(isAllDay . t))))
      (teams4e-calendar--render)
      (goto-char (point-min))
      (teams4e-calendar-next-event)
      (teams4e-calendar-next-event)
      (teams4e-calendar--render)
      (should (equal "2026-10-05" (get-text-property (point) 'teams4e-calendar-day))))))

(ert-deftest teams4e-calendar-chat-link-preserves-case-and-does-not-scan-recents ()
  (teams4e-calendar-test
    (let ((event (teams4e-calendar-test-event
                  "invite" "2026-10-04T10:00:00Z" "2026-10-04T11:00:00Z"
                  '(onlineMeeting (joinUrl . "https://teams.microsoft.com/l/meetup-join/19%3Ameeting_AbCd%40thread.v2/0?context=demo"))))
          args opened)
      (should (equal "19:meeting_AbCd@thread.v2" (teams4e-calendar--chat-id event)))
      (cl-letf (((symbol-function 'teams4e-calendar--context) (lambda () (list (current-buffer) event)))
                ((symbol-function 'teams4e--require-online) #'ignore)
                ((symbol-function 'teams4e--run-json)
                 (lambda (command callback &optional _error)
                   (setq args command) (funcall callback '((id . "real-chat")))))
                ((symbol-function 'teams4e-open-chat) (lambda (chat) (setq opened chat))))
        (teams4e-calendar-open-chat))
      (should (equal args '("teams" "chat" "get" "--chatId" "19:meeting_AbCd@thread.v2")))
      (should (equal opened '((id . "real-chat"))))
      (should-not (teams4e-calendar--chat-id '((onlineMeetingUrl . "https://teams.microsoft.com/meet/123")))))))

(ert-deftest teams4e-calendar-default-navigation-and-action-keys ()
  (dolist (binding '(("J" . teams4e-calendar-next-event)
                      ("K" . teams4e-calendar-previous-event)
                      ("H" . teams4e-calendar-previous-day)
                      ("L" . teams4e-calendar-next-day)
                      ("." . teams4e-calendar-goto-date)
                      ("t" . teams4e-calendar-today)
                      ("N" . teams4e-calendar-next-slot)
                      ("r" . teams4e-calendar-availability)
                      ("T" . teams4e-calendar-open-chat)
                      ("v" . teams4e-calendar-join)))
    (should (eq (lookup-key teams4e-calendar-mode-map (kbd (car binding))) (cdr binding)))))

(ert-deftest teams4e-calendar-organizer-move-is-scoped-to-event-workspace ()
  (let ((teams4e-availability--payload '((rescheduleAllowed . t)))
        (teams4e-availability--source-event '((id . "owned") (isOrganizer . t)))
        (teams4e-availability--proposal-function #'teams4e-calendar--propose))
    (should (teams4e-availability--proposal-allowed-p))
    (let ((teams4e-availability--source-event nil))
      (should-not (teams4e-availability--proposal-allowed-p)))
    (let ((teams4e-availability--proposal-function nil))
      (should-not (teams4e-availability--proposal-allowed-p)))))

(ert-deftest teams4e-calendar-proposal-and-organizer-move-use-distinct-actions ()
  (dolist (organizer '(nil t))
    (teams4e-calendar-test
      (let* ((owner (current-buffer))
             (event (teams4e-calendar-test-event "event" "2026-10-04T09:00:00Z" "2026-10-04T10:00:00Z"
                                                `(isOrganizer . ,organizer)))
             args)
        (setq teams4e-calendar--events (list event)
              teams4e-calendar--loaded-key (teams4e-calendar--key))
        (with-temp-buffer
          (teams4e-availability-mode)
          (setq teams4e-calendar--owner owner teams4e-calendar--event-id "event"
                teams4e-availability--source-event event
                teams4e-availability--proposal-function #'teams4e-calendar--propose
                teams4e-availability--payload
                (if organizer '((rescheduleAllowed . t)) '((proposalAllowed . t))))
          (cl-letf (((symbol-function 'teams4e--require-online) #'ignore)
                    ((symbol-function 'read-string) (lambda (&rest _) "A note"))
                    ((symbol-function 'teams4e--run-json)
                     (lambda (command _callback &optional _error) (setq args command))))
            (teams4e-calendar--propose
             '((start (dateTime . "2026-10-04T11:00:00Z") (timeZone . "UTC"))
               (end (dateTime . "2026-10-04T12:00:00Z") (timeZone . "UTC"))))))
        (should (equal (seq-take args 4)
                       (if organizer '("teams" "calendar" "event" "reschedule")
                         '("teams" "meeting" "propose" "send"))))
        (should (eq (not (null (member "--comment" args))) (not organizer)))))))

(ert-deftest teams4e-calendar-purpose-opens-and-reuses-reader ()
  (skip-unless (featurep 'window-purpose))
  (let ((enabled purpose-mode)
        (teams4e-calendar--detail-name " *calendar purpose reader*")
        (teams4e-offline-mode t))
    (unwind-protect
        (save-window-excursion
          (purpose-mode 1)
          (teams4e-calendar-test
            (switch-to-buffer (current-buffer))
            (delete-other-windows)
            (setq teams4e-calendar--loaded-key (teams4e-calendar--key)
                  teams4e-calendar--events
                  (list (teams4e-calendar-test-event "one" "2026-10-04T09:00:00Z" "2026-10-04T10:00:00Z")))
            (teams4e-calendar--render)
            (goto-char (point-min))
            (teams4e-calendar-next-event)
            (let ((agenda (selected-window)))
              (teams4e-calendar-open-event)
              (should (derived-mode-p 'teams4e-calendar-event-mode))
              (should (window-live-p agenda))
              (should-not (eq agenda (selected-window)))
              (let ((reader (selected-window)))
                (select-window agenda)
                (teams4e-calendar-open-event)
                (should (eq reader (selected-window)))
                (should (= 2 (length (window-list))))))))
      (unless enabled (purpose-mode -1))
      (when-let ((buffer (get-buffer teams4e-calendar--detail-name))) (kill-buffer buffer)))))

(ert-deftest teams4e-calendar-visible-evil-day-keys-round-trip ()
  (skip-unless (featurep 'evil))
  (let ((enabled evil-mode)
        (purpose-enabled (and (boundp 'purpose-mode) purpose-mode)))
    (unwind-protect
        (save-window-excursion
          (evil-mode 1)
          (when (fboundp 'purpose-mode) (purpose-mode 1))
          (teams4e-calendar-test
            (switch-to-buffer (current-buffer))
            (let ((calendar-week-start-day 0))
              (setq teams4e-calendar--loaded-key (teams4e-calendar--key))
              (teams4e-calendar--render)
              (teams4e-calendar--focus-time teams4e-calendar--date)
              (evil-local-mode 1)
              (dolist (state '(motion normal))
                (evil-change-state state)
                (execute-kbd-macro (kbd "L"))
                (should (equal "2026-10-05" (get-text-property (point) 'teams4e-calendar-day)))
                (should (looking-at "Monday,"))
                (should hl-line-mode)
                (execute-kbd-macro (kbd "H"))
                (should (equal "2026-10-04" (get-text-property (point) 'teams4e-calendar-day)))))))
      (unless enabled (evil-mode -1))
      (when (and (fboundp 'purpose-mode) (not purpose-enabled)) (purpose-mode -1)))))

(ert-deftest teams4e-calendar-conflicts-are-exact-not-transitive ()
  (teams4e-calendar-test
    (setq teams4e-calendar--loaded-key (teams4e-calendar--key)
          teams4e-calendar--events
          (list (teams4e-calendar-test-event "A" "2026-10-04T09:00:00Z" "2026-10-04T11:00:00Z" '(showAs . "busy"))
                (teams4e-calendar-test-event "B" "2026-10-04T10:00:00Z" "2026-10-04T12:00:00Z" '(showAs . "busy"))
                (teams4e-calendar-test-event "C" "2026-10-04T11:00:00Z" "2026-10-04T13:00:00Z" '(showAs . "tentative"))))
    (let ((conflicts (teams4e-calendar--conflicts (teams4e-calendar--midnight teams4e-calendar--date))))
      (should (equal (mapcar (lambda (row) (mapcar (lambda (event) (teams4e--get event 'id)) (nth 2 row))) conflicts)
                     '(("A" "B") ("B" "C"))))
      (should (equal (teams4e-calendar--conflict-labels (cadr teams4e-calendar--events) conflicts) '("C1" "C2")))
      (should (equal (mapcar (lambda (row) (format-time-string "%H:%M" (car row))) conflicts) '("10:00" "11:00"))))))

(ert-deftest teams4e-calendar-conflicts-ignore-free-cancelled-declined-and-zero-duration ()
  (teams4e-calendar-test
    (setq teams4e-calendar--loaded-key (teams4e-calendar--key)
          teams4e-calendar--events
          (list (teams4e-calendar-test-event "A" "2026-10-04T09:00:00Z" "2026-10-04T10:00:00Z" '(showAs . "busy"))
                (teams4e-calendar-test-event "touching" "2026-10-04T10:00:00Z" "2026-10-04T11:00:00Z" '(showAs . "busy"))
                (teams4e-calendar-test-event "free" "2026-10-04T09:00:00Z" "2026-10-04T11:00:00Z" '(showAs . "free"))
                (teams4e-calendar-test-event "declined" "2026-10-04T09:00:00Z" "2026-10-04T11:00:00Z" '(responseStatus (response . "declined")))
                (teams4e-calendar-test-event "cancelled" "2026-10-04T09:00:00Z" "2026-10-04T11:00:00Z" '(isCancelled . t))
                (teams4e-calendar-test-event "zero" "2026-10-04T09:30:00Z" "2026-10-04T09:30:00Z")))
    (should-not (teams4e-calendar--conflicts (teams4e-calendar--midnight teams4e-calendar--date)))))

(ert-deftest teams4e-calendar-conflicts-survive-filter-and-clip-multi-day-events ()
  (teams4e-calendar-test
    (setq teams4e-calendar--loaded-key (teams4e-calendar--key)
          teams4e-calendar--events
          (list (teams4e-calendar-test-event "OOF" "2026-10-03T00:00:00Z" "2026-10-05T00:00:00Z" '(showAs . "oof") '(isAllDay . t))
                (teams4e-calendar-test-event "visible" "2026-10-03T23:00:00Z" "2026-10-04T01:00:00Z" '(showAs . "busy"))))
    (teams4e-calendar-filter "visible")
    (should (string-match-p "2 overlapping events (1 filtered out)" (buffer-string)))
    (should (string-match-p "00:00 - 01:00" (buffer-string)))
    (should (string-match-p (regexp-quote "[C1]") (buffer-string)))))

(ert-deftest teams4e-calendar-conflict-detail-button-opens-real-partner ()
  (save-window-excursion
    (let ((teams4e-calendar--detail-name " *calendar overlap reader*") (teams4e-offline-mode t))
      (unwind-protect
          (teams4e-calendar-test
            (switch-to-buffer (current-buffer))
            (setq teams4e-calendar--loaded-key (teams4e-calendar--key)
                  teams4e-calendar--events
                  (list (teams4e-calendar-test-event "A" "2026-10-04T09:00:00Z" "2026-10-04T11:00:00Z")
                        (teams4e-calendar-test-event "B" "2026-10-04T10:00:00Z" "2026-10-04T12:00:00Z")))
            (teams4e-calendar--render)
            (goto-char (point-min))
            (teams4e-calendar-next-event)
            (teams4e-calendar-open-event)
            (goto-char (point-min))
            (search-forward "Overlapping events")
            (search-forward "B [Availability")
            (search-backward "B [Availability")
            (let ((reader (selected-window))
                  (count (length (window-list))))
              (button-activate (button-at (point)))
              (should (eq reader (selected-window)))
              (should (= count (length (window-list)))))
            (should (equal "B" teams4e-calendar--event-id))
            (should (equal "B" (teams4e--get (cadr (teams4e-calendar--context)) 'id))))
        (when-let ((buffer (get-buffer teams4e-calendar--detail-name))) (kill-buffer buffer))))))

(ert-deftest teams4e-calendar-conflicts-count-simultaneous-events ()
  (teams4e-calendar-test
    (setq teams4e-calendar--loaded-key (teams4e-calendar--key)
          teams4e-calendar--events
          (list (teams4e-calendar-test-event "A" "2026-10-04T09:00:00Z" "2026-10-04T12:00:00Z")
                (teams4e-calendar-test-event "B" "2026-10-04T10:00:00Z" "2026-10-04T11:00:00Z")
                (teams4e-calendar-test-event "C" "2026-10-04T10:30:00Z" "2026-10-04T11:30:00Z")))
    (should (equal (mapcar (lambda (row) (length (nth 2 row)))
                           (teams4e-calendar--conflicts
                            (teams4e-calendar--midnight teams4e-calendar--date)))
                   '(2 3 2)))))

(ert-deftest teams4e-calendar-day-navigation-does-not-invoke-org-date-reader ()
  (teams4e-calendar-test
    (setq teams4e-calendar--loaded-key (teams4e-calendar--key))
    (teams4e-calendar--render)
    (teams4e-calendar--focus-time teams4e-calendar--date)
    (cl-letf (((symbol-function 'org-read-date)
               (lambda (&rest _) (ert-fail "Navigation must not depend on date-reader advice"))))
      (teams4e-calendar-next-day)
      (should (looking-at "Monday,"))
      (teams4e-calendar-previous-day)
      (should (looking-at "Sunday,")))))

(defun teams4e-calendar-test-conflicts ()
  "Seed two overlapping invitations and an event on the next day."
  (setq teams4e-calendar--events
        (list (teams4e-calendar-test-event
               "A" "2026-10-04T09:00:00Z" "2026-10-04T11:00:00Z"
               '(showAs . "busy") '(isOrganizer . t))
              (teams4e-calendar-test-event
               "B" "2026-10-04T10:00:00Z" "2026-10-04T12:00:00Z"
               '(showAs . "tentative")
               '(attendees ((emailAddress (address . "guest@example.test")))))
              (teams4e-calendar-test-event "Tomorrow" "2026-10-05T09:00:00Z"
                                           "2026-10-05T10:00:00Z"))
        teams4e-calendar--loaded-key (teams4e-calendar--key))
  (teams4e-calendar--render)
  (goto-char (point-min))
  (search-forward "C1 [+]")
  (beginning-of-line))

(ert-deftest teams4e-calendar-conflict-folding-is-local-and-persistent ()
  (teams4e-calendar-test
    (teams4e-calendar-test-conflicts)
    (let ((key (get-text-property (point) 'teams4e-calendar-section)))
      (cl-letf (((symbol-function 'teams4e--run-json)
                 (lambda (&rest _) (ert-fail "Folding must not fetch"))))
        (should-not (teams4e-calendar--section-open-p key))
        (teams4e-calendar-toggle-section)
        (should (teams4e-calendar--section-open-p key))
        (should (string-match-p "Availability / reschedule" (buffer-string)))
        (should (string-match-p "Availability / propose time" (buffer-string)))
        (teams4e-calendar-next-event)
        (let ((item (get-text-property (point) 'teams4e-calendar-item)))
          (teams4e-calendar--render)
          (should (equal item (get-text-property (point) 'teams4e-calendar-item))))
        (teams4e-calendar-toggle-section)
        (should (equal key (get-text-property (point) 'teams4e-calendar-item)))
        (should-not (teams4e-calendar--section-open-p key))
        (should (string-match-p "09:00 - 11:00.*A" (buffer-string)))))))

(ert-deftest teams4e-calendar-tab-outside-fold-headings-and-conflicts-does-nothing ()
  (teams4e-calendar-test
    (teams4e-calendar-test-conflicts)
    (goto-char (point-min))
    (while (not (eobp))
      (unless (get-text-property (point) 'teams4e-calendar-section)
        (let ((text (buffer-string)) (position (point))
              (state (copy-tree teams4e-calendar--fold-state)))
          (teams4e-calendar-toggle-section)
          (should (equal text (buffer-string)))
          (should (= position (point)))
          (should (equal state teams4e-calendar--fold-state))))
      (forward-line 1))))

(ert-deftest teams4e-calendar-fold-key-does-not-follow-conflict-number ()
  (teams4e-calendar-test
    (teams4e-calendar-test-conflicts)
    (let ((key (get-text-property (point) 'teams4e-calendar-section)))
      (teams4e-calendar-toggle-section)
      (setq teams4e-calendar--events
            (append (list (teams4e-calendar-test-event "early1" "2026-10-04T07:00:00Z" "2026-10-04T08:00:00Z")
                          (teams4e-calendar-test-event "early2" "2026-10-04T07:00:00Z" "2026-10-04T08:00:00Z"))
                    (reverse teams4e-calendar--events)))
      (teams4e-calendar--render)
      (should (equal key (get-text-property (point) 'teams4e-calendar-item)))
      (should (looking-at "    C2 \\[-\\]"))
      (should (string-match-p "C1 \\[[+]\\]" (buffer-string)))
      (teams4e-calendar-filter "A")
      (should (looking-at "    C2 \\[-\\]"))
      (should (string-match-p "Filtered out" (buffer-string)))
      ;; Expanding a group includes its filtered-out partner for resolution.
      (search-forward "Availability / propose time")
      (should (equal "B" (teams4e--get (cadr (teams4e-calendar--context)) 'id))))))

(ert-deftest teams4e-calendar-conflict-actions-target-canonical-events ()
  (teams4e-calendar-test
    (teams4e-calendar-test-conflicts)
    (teams4e-calendar-toggle-section)
    (let (seen)
      (cl-letf (((symbol-function 'teams4e-calendar-availability)
                 (lambda () (interactive)
                   (push (teams4e--get (cadr (teams4e-calendar--context)) 'id) seen)))
                ((symbol-function 'teams4e-calendar-respond)
                 (lambda () (interactive)
                   (push (teams4e--get (cadr (teams4e-calendar--context)) 'id) seen))))
        (dolist (label '("Availability / reschedule" "Availability / propose time" "Respond"))
          (search-forward label)
          (backward-char 1)
          (teams4e-calendar-activate)
          (forward-char 1))
        (should (equal seen '("B" "B" "A")))))))

(ert-deftest teams4e-calendar-resolving-conflict-keeps-nearby-surviving-item ()
  (teams4e-calendar-test
    (teams4e-calendar-test-conflicts)
    (teams4e-calendar-toggle-section)
    (search-forward "Availability / propose time")
    (cl-letf (((symbol-function 'teams4e--require-online) #'ignore)
              ((symbol-function 'completing-read) (lambda (&rest _) "declined"))
              ((symbol-function 'read-string) (lambda (&rest _) ""))
              ((symbol-function 'teams4e--run-json)
               (lambda (args callback &optional _error)
                 (should (member "B" args))
                 (funcall callback '((event (id . "B") (responseStatus (response . "declined"))))))))
      (teams4e-calendar-respond))
    (should-not (teams4e-calendar--conflicts (teams4e-calendar--midnight teams4e-calendar--date)))
    (should-not (string-match-p "overlapping events" (buffer-string)))
    (should (equal "2026-10-04" (get-text-property (point) 'teams4e-calendar-day)))
    (should (get-text-property (point) 'teams4e-calendar-item))))

(ert-deftest teams4e-calendar-old-day-fold-state-is-ignored ()
  (teams4e-calendar-test
    (teams4e-calendar-test-conflicts)
    (let ((day (teams4e-calendar--day-key teams4e-calendar--date)))
      (setq teams4e-calendar--fold-state (list (cons day 'closed)))
      (teams4e-calendar--render)
      (should (string-match-p "09:00 - 11:00.*A" (buffer-string)))
      (goto-char (teams4e-calendar--find-item day))
      (should-not (get-text-property (point) 'teams4e-calendar-section))
      ;; An old, not-yet-redrawn buffer may still carry day section properties.
      (let ((inhibit-read-only t))
        (put-text-property (point) (line-end-position) 'teams4e-calendar-section day))
      (let ((text (buffer-string)))
        (teams4e-calendar-toggle-section)
        (should (equal text (buffer-string))))
      (setq teams4e-calendar--focus (date-to-time "2026-10-04T09:30:00Z"))
      (teams4e-calendar--render)
      (should (equal "A" (teams4e--get (cadr (teams4e-calendar--context)) 'id))))))

(ert-deftest teams4e-calendar-fold-state-is-calendar-specific ()
  (teams4e-calendar-test
    (teams4e-calendar-test-conflicts)
    (teams4e-calendar-toggle-section)
    (setq teams4e-calendar--id "another-calendar"
          teams4e-calendar--loaded-key (teams4e-calendar--key))
    (teams4e-calendar--render)
    (should-not (string-match-p "Availability / reschedule" (buffer-string)))
    (should (string-match-p "09:00 - 11:00.*A" (buffer-string)))))

(ert-deftest teams4e-calendar-visible-tab-and-action-keys-with-evil ()
  (skip-unless (featurep 'evil))
  (let ((enabled evil-mode)
        (purpose-enabled (and (boundp 'purpose-mode) purpose-mode)))
    (unwind-protect
        (save-window-excursion
          (evil-mode 1)
          (when (fboundp 'purpose-mode) (purpose-mode 1))
          (teams4e-calendar-test
            (switch-to-buffer (current-buffer))
            (teams4e-calendar-test-conflicts)
            (evil-local-mode 1)
            (let ((key (get-text-property (point) 'teams4e-calendar-section))
                  action)
              (dolist (state '(motion normal))
                (evil-change-state state)
                (execute-kbd-macro (kbd "TAB"))
                (should (teams4e-calendar--section-open-p key))
                (search-forward "Availability / propose time")
                (backward-char 1)
                (cl-letf (((symbol-function 'teams4e-calendar-availability)
                           (lambda () (interactive)
                             (setq action (teams4e--get (cadr (teams4e-calendar--context)) 'id)))))
                  (execute-kbd-macro (kbd "RET")))
                (should (equal "B" action))
                (execute-kbd-macro (kbd "<tab>"))
                (should-not (teams4e-calendar--section-open-p key))
                (should (equal key (get-text-property (point) 'teams4e-calendar-item)))
                (teams4e-calendar--focus-time teams4e-calendar--date t)
                (let ((text (buffer-string)) (position (point)))
                  (execute-kbd-macro (kbd "TAB"))
                  (should (equal text (buffer-string)))
                  (should (= position (point))))
                (cl-letf (((symbol-function 'current-time)
                           (lambda () (date-to-time "2026-10-04T09:30:00Z")))
                          ((symbol-function 'teams4e--run-json)
                           (lambda (&rest _) (ert-fail "Centering must reuse the loaded day"))))
                  (execute-kbd-macro (kbd "t")))
                (should (equal "A" (teams4e--get (cadr (teams4e-calendar--context)) 'id)))
                (let ((summary (list 'summary (teams4e-calendar--day-key teams4e-calendar--date))))
                  (goto-char (teams4e-calendar--find-item summary))
                  (execute-kbd-macro (kbd "TAB"))
                  (should-not (teams4e-calendar--section-open-p summary))
                  (should (teams4e-calendar--find-item
                           (list 'event (teams4e-calendar--day-key teams4e-calendar--date) "A")))
                  (execute-kbd-macro (kbd "TAB"))
                  (should (teams4e-calendar--section-open-p summary)))
                (goto-char (teams4e-calendar--find-item key))))))
      (unless enabled (evil-mode -1))
      (when (and (fboundp 'purpose-mode) (not purpose-enabled)) (purpose-mode -1)))))

(ert-deftest teams4e-calendar-summary-classifies-only-attending-events ()
  (dolist (case '((nil unanswered) ("" unanswered) ("none" unanswered)
                  ("notResponded" unanswered) ("accepted" accepted)
                  ("tentativelyAccepted" tentative) ("declined" nil)
                  ("following" nil) ("follow" nil)))
    (let ((event `((showAs . "busy") (attendees ((name . "Guest")))
                   (responseStatus (response . ,(car case))))))
      (should (eq (cadr case) (teams4e-calendar--summary-group event)))))
  (should-not (teams4e-calendar--summary-group '((showAs . "busy"))))
  (should-not (teams4e-calendar--summary-group
               '((showAs . "free") (responseStatus (response . "accepted")))))
  (should-not (teams4e-calendar--summary-group
               '((showAs . "workingElsewhere") (isOrganizer . t))))
  (should-not (teams4e-calendar--summary-group
               '((isCancelled . t) (responseStatus (response . "accepted")))))
  (should (eq 'organizing (teams4e-calendar--summary-group '((isOrganizer . t))))))

(ert-deftest teams4e-calendar-summary-order-and-exclusions ()
  (teams4e-calendar-test
    (setq teams4e-calendar--view 'day
          teams4e-calendar--show-declined t
          teams4e-calendar--loaded-key (teams4e-calendar--key)
          teams4e-calendar--events
          (cl-loop for (id response hour . extra)
                   in '(("accepted" "accepted" 9)
                        ("later" "notResponded" 14)
                        ("earlier" "none" 11)
                        ("tentative" "tentativelyAccepted" 10)
                        ("rejected" "declined" 12)
                        ("following" "accepted" 13 (showAs . "free"))
                        ("cancelled" "accepted" 15 (isCancelled . t)))
                   collect
                   (apply #'teams4e-calendar-test-event id
                          (format "2026-10-04T%02d:00:00Z" hour)
                          (format "2026-10-04T%02d:30:00Z" hour)
                          `(responseStatus (response . ,response))
                          '(attendees ((name . "Guest"))) extra)))
    (teams4e-calendar--render)
    (let ((key (list 'summary (teams4e-calendar--day-key teams4e-calendar--date))))
      (should (< (teams4e-calendar--find-item (list 'summary-event key "earlier"))
                 (teams4e-calendar--find-item (list 'summary-event key "later"))))
      (should (< (teams4e-calendar--find-item (list 'summary-event key "later"))
                 (teams4e-calendar--find-item (list 'summary-event key "tentative"))))
      (should (< (teams4e-calendar--find-item (list 'summary-event key "tentative"))
                 (teams4e-calendar--find-item (list 'summary-event key "accepted"))))
      (dolist (id '("rejected" "following" "cancelled"))
        (should-not (teams4e-calendar--find-item (list 'summary-event key id))))
      ;; A summary title refers to the original event and is not a second store.
      (goto-char (teams4e-calendar--find-item (list 'summary-event key "earlier")))
      (should (eq (cadr (teams4e-calendar--context)) (nth 2 teams4e-calendar--events)))
      (should-not (get-text-property (point) 'teams4e-calendar-section))
      (should-not (get-text-property (point) 'teams4e-calendar-row-start)))))

(ert-deftest teams4e-calendar-summary-folding-keeps-timeline-and-conflict-state ()
  (teams4e-calendar-test
    (teams4e-calendar-test-conflicts)
    (let ((conflict (get-text-property (point) 'teams4e-calendar-section))
          (summary (list 'summary (teams4e-calendar--day-key teams4e-calendar--date)))
          (timeline (list 'event (teams4e-calendar--day-key teams4e-calendar--date) "A")))
      (cl-letf (((symbol-function 'teams4e--run-json)
                 (lambda (&rest _) (ert-fail "Summary folding must not fetch"))))
        (teams4e-calendar-toggle-section)
        (goto-char (teams4e-calendar--find-item summary))
        (teams4e-calendar-toggle-section)
        (should-not (teams4e-calendar--section-open-p summary))
        (should-not (teams4e-calendar--find-item conflict))
        (should (teams4e-calendar--find-item timeline))
        (teams4e-calendar--render)
        (should (equal summary (get-text-property (point) 'teams4e-calendar-item)))
        (teams4e-calendar-toggle-section)
        (should (teams4e-calendar--find-item conflict))
        (should (teams4e-calendar--section-open-p conflict))
        (should (string-match-p "Availability / reschedule" (buffer-string)))))))

(ert-deftest teams4e-calendar-free-summary-is-distinct-and-ignores-filter ()
  (teams4e-calendar-test
    (let ((teams4e-calendar-work-days '(0))
          (teams4e-calendar-work-hours '(9 . 18)))
      (setq teams4e-calendar--view 'day
            teams4e-calendar--loaded-key (teams4e-calendar--key)
            teams4e-calendar--events
            (list (teams4e-calendar-test-event "hidden" "2026-10-04T09:00:00Z" "2026-10-04T11:00:00Z"
                                              '(showAs . "busy"))
                  (teams4e-calendar-test-event "visible" "2026-10-04T13:00:00Z" "2026-10-04T14:00:00Z"
                                              '(showAs . "busy"))
                  (teams4e-calendar-test-event "free invite" "2026-10-04T15:00:00Z" "2026-10-04T16:00:00Z"
                                              '(showAs . "free"))))
      (teams4e-calendar-filter "visible")
      (should (string-match-p "FREE 6h 00m  |  11:00 - 13:00  |  14:00 - 18:00" (buffer-string)))
      (goto-char (point-min))
      (search-forward "[FREE]")
      (should (eq 'teams4e-calendar-free-slot (get-text-property (1- (point)) 'face)))
      (should (eq 'teams4e-calendar-free
                  (cadr (teams4e-calendar--availability (nth 2 teams4e-calendar--events)))))
      (let ((summary (list 'summary (teams4e-calendar--day-key teams4e-calendar--date))))
        (goto-char (teams4e-calendar--find-item summary))
        (teams4e-calendar-toggle-section)
        (should (string-match-p "FREE 6h 00m" (buffer-string))))
      (setq teams4e-calendar--fold-state nil teams4e-calendar--error "Incomplete")
      (teams4e-calendar--render)
      (should-not (string-match-p "FREE [0-9]" (buffer-string)))
      (should-not (string-match-p (regexp-quote "[FREE]") (buffer-string)))
      (should (string-match-p "Free time unavailable" (buffer-string))))))

(ert-deftest teams4e-calendar-summary-response-updates-groups ()
  (teams4e-calendar-test
    (teams4e-calendar-test-conflicts)
    (teams4e-calendar--replace-event '((id . "B") (responseStatus (response . "notResponded"))))
    (teams4e-calendar--render)
    (let* ((key (list 'summary (teams4e-calendar--day-key teams4e-calendar--date)))
           (row (list 'summary-event key "B")))
      (goto-char (teams4e-calendar--find-item row))
      (search-forward "Respond")
      (backward-char 1)
      (cl-letf (((symbol-function 'teams4e--require-online) #'ignore)
                ((symbol-function 'completing-read) (lambda (&rest _) "accepted"))
                ((symbol-function 'read-string) (lambda (&rest _) ""))
                ((symbol-function 'teams4e--run-json)
                 (lambda (args callback &optional _error)
                   (should (member "B" args))
                   (funcall callback '((event (id . "B") (responseStatus (response . "accepted"))))))))
        (teams4e-calendar-activate))
      (should (teams4e-calendar--find-item row))
      (should-not (string-match-p "Needs response (1)" (buffer-string)))
      (should (string-match-p "Accepted (1)" (buffer-string)))
      (should (equal row (get-text-property (point) 'teams4e-calendar-item))))))

(ert-deftest teams4e-calendar-accepted-markers-only-count-accepted-partners ()
  (teams4e-calendar-test
    (setq teams4e-calendar--view 'day
          teams4e-calendar--loaded-key (teams4e-calendar--key)
          teams4e-calendar--events
          (cl-loop for (id response start end)
                   in '(("A" "accepted" 9 11)
                        ("tentative" "tentativelyAccepted" 9 10)
                        ("B" "accepted" 10 12)
                        ("unanswered" "notResponded" 11 12)
                        ("C" "accepted" 12 13))
                   collect
                   (teams4e-calendar-test-event
                    id (format "2026-10-04T%02d:00:00Z" start)
                    (format "2026-10-04T%02d:00:00Z" end)
                    `(responseStatus (response . ,response))
                    '(showAs . "busy"))))
    (let ((conflicts (teams4e-calendar--conflicts (teams4e-calendar--midnight teams4e-calendar--date))))
      (dolist (index '(0 2))
        (should (equal '("C2") (teams4e-calendar--conflict-labels
                               (nth index teams4e-calendar--events) conflicts t))))
      (should-not (teams4e-calendar--conflict-labels
                   (nth 4 teams4e-calendar--events) conflicts t))
      (should (equal '("C1" "C2") (teams4e-calendar--conflict-labels
                                  (car teams4e-calendar--events) conflicts))))
    ;; Filtering out B does not erase the accepted clash with A.
    (setq teams4e-calendar--filter "A")
    (teams4e-calendar--render)
    (goto-char (teams4e-calendar--find-item
                (list 'summary-event
                      (list 'summary (teams4e-calendar--day-key teams4e-calendar--date)) "A")))
    (should (string-match-p (regexp-quote "[C2]")
                            (buffer-substring (point) (line-end-position))))))

(ert-deftest teams4e-calendar-refresh-preserves-metadata-line-and-column ()
  (teams4e-calendar-test
    (teams4e-calendar-test-conflicts)
    (goto-char (teams4e-calendar--find-item
                (list 'event (teams4e-calendar--day-key teams4e-calendar--date) "B")))
    (forward-line 1)
    (move-to-column 23)
    (let ((anchor (teams4e-calendar--position-anchor (point))))
      (teams4e-calendar--render)
      (should (equal (plist-get anchor :item)
                     (get-text-property (point) 'teams4e-calendar-item)))
      (should (= 23 (current-column)))
      (should (= 1 (plist-get (teams4e-calendar--position-anchor (point)) :line))))))

(ert-deftest teams4e-calendar-vanished-conflict-child-falls-back-to-its-event ()
  (teams4e-calendar-test
    (teams4e-calendar-test-conflicts)
    (teams4e-calendar-toggle-section)
    (search-forward "Availability / propose time")
    (teams4e-calendar--replace-event '((id . "A") (showAs . "free")))
    (teams4e-calendar--render)
    (should (equal (get-text-property (point) 'teams4e-calendar-item)
                   (list 'event (teams4e-calendar--day-key teams4e-calendar--date) "B")))))

(ert-deftest teams4e-calendar-refresh-callback-respects-movement-while-loading ()
  (teams4e-calendar-test
    (teams4e-calendar-test-conflicts)
    (let (callback)
      (cl-letf (((symbol-function 'teams4e--require-online) #'ignore)
                ((symbol-function 'teams4e--run-json)
                 (lambda (_args fn &optional _err) (setq callback fn) nil)))
        (teams4e-calendar-refresh))
      (goto-char (teams4e-calendar--find-item
                  (list 'event (teams4e-calendar--day-key teams4e-calendar--date) "B")))
      (forward-line 1)
      (move-to-column 21)
      (funcall callback `((events . ,teams4e-calendar--events) (complete . t)))
      (should (equal "B" (get-text-property (point) 'teams4e-calendar-event)))
      (should (= 21 (current-column)))
      (should (= 1 (plist-get (teams4e-calendar--position-anchor (point)) :line))))))

(ert-deftest teams4e-calendar-refresh-preserves-independent-window-positions ()
  (teams4e-calendar-test
    (teams4e-calendar-test-conflicts)
    (save-window-excursion
      (set-frame-size (selected-frame) 100 40)
      (switch-to-buffer (current-buffer))
      (delete-other-windows)
      (let* ((first (selected-window))
             (second (split-window-right))
             (day (teams4e-calendar--day-key teams4e-calendar--date))
             (a (teams4e-calendar--find-item (list 'event day "A")))
             (b (teams4e-calendar--find-item (list 'event day "B"))))
        (set-window-buffer second (current-buffer))
        (goto-char (+ a 23))
        (set-window-start first a t)
        (set-window-point second (+ b 24))
        (set-window-start second b t)
        (set-window-hscroll second 3)
        (let ((first-start (window-start first))
              (second-start (window-start second))
              (first-point (window-point first))
              (second-point (window-point second)))
          (teams4e-calendar--render)
          (should (eq first (selected-window)))
          (should (= first-start (window-start first)))
          (should (= second-start (window-start second)))
          (should (= first-point (window-point first)))
          (should (= second-point (window-point second)))
          (should (= 3 (window-hscroll second))))))))

(ert-deftest teams4e-calendar-refresh-compensates-for-inserted-wrapped-rows ()
  (teams4e-calendar-test
    (teams4e-calendar-test-conflicts)
    (teams4e-calendar--replace-event
     `((id . "A") (subject . ,(mapconcat #'identity (make-list 18 "Long title") " "))))
    (teams4e-calendar--render)
    (save-window-excursion
      (set-frame-size (selected-frame) 100 40)
      (switch-to-buffer (current-buffer))
      (delete-other-windows)
      (let* ((window (selected-window))
             (day (teams4e-calendar--day-key teams4e-calendar--date)))
        (goto-char (teams4e-calendar--find-item (list 'event day "B")))
        (move-to-column 20)
        (set-window-start window (teams4e-calendar--find-item (list 'event day "A")) t)
        (let ((row (teams4e-calendar--screen-row window)))
          (push (teams4e-calendar-test-event "New" "2026-10-04T09:30:00Z" "2026-10-04T09:45:00Z")
                teams4e-calendar--events)
          (teams4e-calendar--render)
          (should (equal "B" (get-text-property (point) 'teams4e-calendar-event)))
          (should (= 20 (current-column)))
          (should (= row (teams4e-calendar--screen-row window))))))))

(ert-deftest teams4e-calendar-next-slot-uses-ongoing-or-next-not-ended ()
  (teams4e-calendar-test
    (let ((calendar-week-start-day 0)
          (teams4e-calendar-free-gap-minutes nil))
      (teams4e-calendar-test-conflicts)
      (cl-letf (((symbol-function 'teams4e--run-json)
                 (lambda (&rest _) (ert-fail "Loaded navigation must not fetch"))))
        (dolist (now '("2026-10-04T11:30:00Z" "2026-10-04T09:59:00Z" "2026-10-04T23:30:00Z"))
          (cl-letf (((symbol-function 'current-time) (lambda () (date-to-time now))))
            (teams4e-calendar-next-slot)
            (should (equal (cond ((string-match-p "11:30" now) "B")
                                 ((string-match-p "09:59" now) "A")
                                 (t "Tomorrow"))
                           (get-text-property (point) 'teams4e-calendar-event)))))))))

(ert-deftest teams4e-calendar-next-slot-at-night-fetches-only-next-day-across-dst ()
  (teams4e-calendar-test
    (set-time-zone-rule "America/New_York")
    (setq teams4e-calendar--view 'day)
    (let (args callback)
      (cl-letf (((symbol-function 'current-time)
                 (lambda () (date-to-time "2026-10-31T23:30:00-04:00")))
                ((symbol-function 'teams4e--require-online) #'ignore)
                ((symbol-function 'teams4e--run-json)
                 (lambda (command fn &optional _err)
                   (setq args command callback fn) nil)))
        (teams4e-calendar-next-slot))
      (should (equal args '("teams" "calendar" "view" "--start" "2026-11-01T04:00:00Z"
                           "--end" "2026-11-02T05:00:00Z")))
      (funcall callback '((events) (complete . t)))
      (should (equal "2026-11-01" (get-text-property (point) 'teams4e-calendar-day))))))

(ert-deftest teams4e-calendar-next-slot-is-accessible-in-evil ()
  (skip-unless (fboundp 'evil-mode))
  (teams4e-calendar-test
    (evil-local-mode 1)
    (teams4e-calendar--install-navigation)
    (dolist (state '(normal motion))
      (evil-change-state state)
      (should (eq (key-binding (kbd "N")) #'teams4e-calendar-next-slot)))))


(ert-deftest teams4e-calendar-refresh-preserves-unkeyed-summary-and-separators ()
  (teams4e-calendar-test
    (setq-local teams4e-calendar-work-days '(0))
    (teams4e-calendar-test-conflicts)
    (dolist (search '("    FREE" "Organizing"))
      (goto-char (point-min))
      (search-forward search)
      (let ((before (point)))
        (teams4e-calendar--render)
        (should (= before (point)))))
    (goto-char (point-min))
    (forward-line 1)
    (let ((before (point)))
      (teams4e-calendar--render)
      (should (= before (point))))))


(ert-deftest teams4e-calendar-follow-links-are-only-documented-outlook-items ()
  (should (equal "https://outlook.office365.com/calendar/item/demo%2Fid%3D"
                 (teams4e-calendar--follow-url
                  '((webLink . "https://outlook.office365.com/owa/?itemid=demo%2Fid%3D&exvsurl=1&path=/calendar/item")))))
  (let ((link "https://outlook.live.com/calendar/item/demo"))
    (should (equal link (teams4e-calendar--follow-url `((webLink . ,link))))))
  (dolist (link '(nil "" "javascript:alert(1)" "http://outlook.office.com/calendar/item/demo"
                 "https://outlook.office.com.invalid/calendar/item/demo"
                 "https://user:secret@outlook.office.com/calendar/item/demo"))
    (should-error (teams4e-calendar--follow-url `((webLink . ,link))) :type 'user-error)))

(ert-deftest teams4e-calendar-follow-handoff-never-responds-or-changes-snapshot ()
  (teams4e-calendar-test
    (teams4e-calendar-test-conflicts)
    (teams4e-calendar--replace-event
     '((id . "B") (webLink . "https://outlook.office.com/calendar/item/demo")))
    (goto-char (teams4e-calendar--find-item
                (list 'event (teams4e-calendar--day-key teams4e-calendar--date) "B")))
    (let ((before (copy-tree teams4e-calendar--events))
          (teams4e-calendar-follow-browser-command 'auto)
          (teams4e-browser-command '("open" "-a" "Arc"))
          (system-type 'darwin)
          opened)
      (cl-letf (((symbol-function 'teams4e--run-json)
                 (lambda (&rest _) (ert-fail "Follow handoff must not call Graph")))
                ((symbol-function 'teams4e--open-with-command)
                 (lambda (url command _description) (setq opened (list url command)))))
        (teams4e-calendar-follow-in-outlook))
      (should (equal opened '("https://outlook.office.com/calendar/item/demo"
                              ("open" "-a" "Arc" "-g"))))
      (should (equal before teams4e-calendar--events))
      (let ((system-type 'gnu/linux)
            (teams4e-browser-command '("test-browser" "--new-tab")))
        (cl-letf (((symbol-function 'teams4e--open-with-command)
                   (lambda (_url command _description) (setq opened command))))
          (teams4e-calendar-follow-in-outlook))
        (should (equal opened '("test-browser" "--new-tab"))))
      (teams4e-calendar--replace-event '((id . "B") (isOrganizer . t)))
      (cl-letf (((symbol-function 'teams4e--open-with-command)
                 (lambda (&rest _) (ert-fail "Organizer cannot Follow"))))
        (should-error (teams4e-calendar-follow-in-outlook) :type 'user-error)))))


(defmacro teams4e-calendar-draft-test (&rest body)
  (declare (indent 0))
  `(with-temp-buffer
     (org-mode)
     (insert "* Synthetic review\n:PROPERTIES:\n:START_AT: 2026-10-06T10:00:00+0300\n"
             ":END_AT: 2026-10-06T10:30:00+0300\n:TEAMS: yes\n:SHOW_AS: busy\n"
             ":REQUIRED: guest@example.test\n:TRANSACTION_ID: 88f06b7f-f43e-42e8-8e98-a4fdc7ca0b34\n"
             ":END:\n\n*Bold agenda* and [[https://example.test][a link]].\n")
     (teams4e-calendar-compose-mode 1)
     ,@body))

(ert-deftest teams4e-calendar-create-opens-org-draft-without-any-request ()
  (teams4e-calendar-test
    (teams4e-calendar-test-conflicts)
    (goto-char (teams4e-calendar--find-item
                (list 'event (teams4e-calendar--day-key teams4e-calendar--date) "B")))
    (let (draft)
      (unwind-protect
          (cl-letf (((symbol-function 'teams4e--run-json)
                     (lambda (&rest _) (ert-fail "Opening a draft must not fetch or send")))
                    ((symbol-function 'pop-to-buffer) (lambda (buffer &rest _) (setq draft buffer))))
            (teams4e-calendar-create)
            (with-current-buffer draft
              (should (derived-mode-p 'org-mode))
              (should teams4e-calendar-compose-mode)
              (should (equal "2026-10-04T10:00:00+0000"
                             (teams4e-calendar-compose--get "START_AT")))
              (should (equal "yes" (teams4e-calendar-compose--get "TEAMS")))
              (should (teams4e-calendar-compose--get "TRANSACTION_ID"))
              (should-not teams4e-calendar-compose--pending)))
        (when (buffer-live-p draft) (kill-buffer draft))))))

(ert-deftest teams4e-calendar-draft-renders-org-without-metadata-or-evaluation ()
  (teams4e-calendar-draft-test
    (let* ((payload (teams4e-calendar-compose--payload))
           (body (alist-get 'body payload)))
      (should (equal "2026-10-06T07:00:00Z" (alist-get 'start payload)))
      (should (string-match-p "<b>Bold agenda</b>" body))
      (should-not (string-match-p "TRANSACTION_ID\\|REQUIRED\\|Synthetic review" body))
      (should (equal ["guest@example.test"] (alist-get 'required payload))))
    (goto-char (point-max))
    (insert "#+INCLUDE: \"/never-read-this\"\n")
    (should-error (teams4e-calendar-compose--payload) :type 'user-error)))

(ert-deftest teams4e-calendar-draft-rejects-bad-time-and-address-before-send ()
  (dolist (field '(("END_AT" . "2026-10-05T09:00:00Z")
                   ("START_AT" . "2026-10-06T10:00:00")
                   ("REQUIRED" . "not-an-email") ("TEAMS" . "perhaps")))
    (teams4e-calendar-draft-test
      (teams4e-calendar-compose--put (car field) (cdr field))
      (cl-letf (((symbol-function 'teams4e--require-online) #'ignore)
                ((symbol-function 'teams4e--run-json) (lambda (&rest _) (ert-fail "Invalid draft sent"))))
        (should-error (teams4e-calendar-compose-send) :type 'user-error))
      (should-not buffer-read-only))))

(ert-deftest teams4e-calendar-draft-explicit-send-prevents-double-submission ()
  (teams4e-calendar-draft-test
    (let (calls callback)
      (cl-letf (((symbol-function 'teams4e--require-online) #'ignore)
                ((symbol-function 'teams4e--run-json)
                 (lambda (args done &optional _error) (push args calls) (setq callback done))))
        (teams4e-calendar-compose-send)
        (should teams4e-calendar-compose--pending)
        (should buffer-read-only)
        (should-error (teams4e-calendar-compose-send) :type 'user-error)
        (should (= 1 (length calls)))
        (should (equal '("teams" "calendar" "event" "create") (seq-take (car calls) 4)))
        (funcall callback '((event (id . "new-event") (subject . "Synthetic review"))))
        (should-not teams4e-calendar-compose--pending)
        (should (equal "new-event" (teams4e-calendar-compose--get "CREATED_ID")))
        (should-error (teams4e-calendar-compose-send) :type 'user-error)))))

(ert-deftest teams4e-calendar-draft-failed-send-retries-identical-payload-only ()
  (teams4e-calendar-draft-test
    (goto-char (point-max))
    (insert "** Subheading with an export-generated ID\nMore body.\n")
    (let (calls fail)
      (cl-letf (((symbol-function 'teams4e--require-online) #'ignore)
                ((symbol-function 'teams4e--run-json)
                 (lambda (args _done &optional error) (push args calls) (setq fail error))))
        (teams4e-calendar-compose-send)
        (funcall fail 1 "Synthetic timeout")
        (teams4e-calendar-compose-send)
        (should (equal (car calls) (cadr calls)))
        (funcall fail 1 "Synthetic timeout")
        (goto-char (point-max))
        (insert "Changed after submission.\n")
        (should-error (teams4e-calendar-compose-send) :type 'user-error)
        (should (= 2 (length calls)))))))

(ert-deftest teams4e-calendar-draft-attendee-search-updates-draft-only ()
  (teams4e-calendar-draft-test
    (cl-letf (((symbol-function 'teams4e--search-user)
               (lambda (_query callback) (funcall callback '((mail . "optional@example.test"))))))
      (teams4e-calendar-compose-add-attendee "optional" t))
    (should (equal "optional@example.test" (teams4e-calendar-compose--get "OPTIONAL")))
    (should-not (teams4e-calendar-compose--get "SUBMITTED_HASH"))))


(provide 'teams4e-calendar-tests)
;;; teams4e-calendar-tests.el ends here
