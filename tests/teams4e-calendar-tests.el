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

(ert-deftest teams4e-calendar-folding-is-local-nested-and-persistent ()
  (teams4e-calendar-test
    (let ((calendar-week-start-day 0))
      (teams4e-calendar-test-conflicts)
      (let ((key (get-text-property (point) 'teams4e-calendar-section)))
        (cl-letf (((symbol-function 'teams4e--run-json)
                   (lambda (&rest _) (ert-fail "Folding must not fetch"))))
          (should-not (teams4e-calendar--section-open-p key))
          (should-not (string-match-p "Availability / reschedule" (buffer-string)))
          (teams4e-calendar-toggle-section)
          (should (teams4e-calendar--section-open-p key))
          (should (string-match-p "Availability / reschedule" (buffer-string)))
          (should (string-match-p "Availability / propose time" (buffer-string)))
          (teams4e-calendar--focus-time teams4e-calendar--date t)
          (teams4e-calendar-toggle-section)
          (should (looking-at "Sunday,.*\\[[+]\\]"))
          (should-not (string-match-p "C1 \\[" (buffer-string)))
          (should (string-match-p "1 conflict" (buffer-string)))
          (teams4e-calendar-next-event)
          (should (equal "Tomorrow" (teams4e--get (cadr (teams4e-calendar--context)) 'id)))
          (teams4e-calendar-previous-day)
          (teams4e-calendar-toggle-section)
          (should (teams4e-calendar--section-open-p key))
          (should (string-match-p "C1 \\[-\\]" (buffer-string)))
          (goto-char (teams4e-calendar--find-item key))
          (teams4e-calendar-next-event)
          (let ((item (get-text-property (point) 'teams4e-calendar-item)))
            (teams4e-calendar--render)
            (should (equal item (get-text-property (point) 'teams4e-calendar-item))))
          ;; TAB from inside a group closes that group, not the entire day.
          (teams4e-calendar-toggle-section)
          (should (equal key (get-text-property (point) 'teams4e-calendar-item)))
          (should-not (teams4e-calendar--section-open-p key))
          (should (string-match-p "09:00 - 11:00.*A" (buffer-string))))))))

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
      (should (looking-at "  C2 \\[-\\]"))
      (should (string-match-p "C1 \\[[+]\\]" (buffer-string)))
      (teams4e-calendar-filter "A")
      (should (looking-at "  C2 \\[-\\]"))
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

(ert-deftest teams4e-calendar-resolving-conflict-removes-group-and-keeps-day ()
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
    (should (looking-at "Sunday,"))))

(ert-deftest teams4e-calendar-focus-reopens-day-but-navigation-does-not ()
  (teams4e-calendar-test
    (let ((calendar-week-start-day 0))
      (teams4e-calendar-test-conflicts)
      (teams4e-calendar--focus-time teams4e-calendar--date t)
      (teams4e-calendar-toggle-section)
      (teams4e-calendar-next-day)
      (teams4e-calendar-previous-day)
      (should (looking-at "Sunday,.*\\[[+]\\]"))
      (setq teams4e-calendar--focus (date-to-time "2026-10-04T09:30:00Z"))
      (teams4e-calendar--render)
      (should (equal "A" (teams4e--get (cadr (teams4e-calendar--context)) 'id)))
      (should (teams4e-calendar--section-open-p (teams4e-calendar--day-key teams4e-calendar--date))))))

(ert-deftest teams4e-calendar-fold-state-is-calendar-specific ()
  (teams4e-calendar-test
    (teams4e-calendar-test-conflicts)
    (teams4e-calendar--focus-time teams4e-calendar--date t)
    (teams4e-calendar-toggle-section)
    (setq teams4e-calendar--id "another-calendar"
          teams4e-calendar--loaded-key (teams4e-calendar--key))
    (teams4e-calendar--render)
    (should (string-match-p "C1 \\[[+]\\]" (buffer-string)))
    (should (teams4e-calendar--section-open-p (teams4e-calendar--day-key teams4e-calendar--date)))))

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
                (execute-kbd-macro (kbd "TAB"))
                (cl-letf (((symbol-function 'current-time)
                           (lambda () (date-to-time "2026-10-04T09:30:00Z")))
                          ((symbol-function 'teams4e--run-json)
                           (lambda (&rest _) (ert-fail "Centering must reuse the loaded day"))))
                  (execute-kbd-macro (kbd "t")))
                (should (equal "A" (teams4e--get (cadr (teams4e-calendar--context)) 'id)))
                (goto-char (teams4e-calendar--find-item key))))))
      (unless enabled (evil-mode -1))
      (when (and (fboundp 'purpose-mode) (not purpose-enabled)) (purpose-mode -1)))))

(provide 'teams4e-calendar-tests)
;;; teams4e-calendar-tests.el ends here
