;;; teams4e-tests.el --- Tests for the teams4e package. -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)

(defconst teams4e-test-directory
  (file-name-directory (or load-file-name buffer-file-name)))
(defconst teams4e-test-layer-directory
  (file-name-directory (directory-file-name teams4e-test-directory)))
(defconst teams4e-test-fake-backend
  (expand-file-name "fake-teams4e" teams4e-test-directory))

(add-to-list 'load-path teams4e-test-layer-directory)
(require 'teams4e)

(ert-deftest teams4e-legacy-entry-point-aliases-the-former-namespace ()
  (require 'msteams)
  (should (eq (indirect-function 'msteams-inbox)
              (indirect-function 'teams4e-inbox)))
  (should (eq (indirect-function 'msteams-status)
              (indirect-function 'teams4e-status)))
  (should (eq (indirect-function 'msteams)
              (indirect-function 'teams4e))))

(defun teams4e-test-read-json (name)
  "Read fixture NAME using the production JSON representation."
  (json-parse-string
   (with-temp-buffer
     (insert-file-contents
      (expand-file-name (concat "fixtures/" name) teams4e-test-directory))
     (buffer-string))
   :object-type 'alist
   :array-type 'list
   :null-object nil
   :false-object nil))

(defun teams4e-test-await (request)
  "Wait for asynchronous REQUEST and return after its callback has run."
  (let ((deadline (+ (float-time) 5)))
    (while (and (teams4e--request-live-p request)
                (< (float-time) deadline))
      (accept-process-output nil 0.05))
    (should-not (teams4e--request-live-p request))
    (accept-process-output nil 0.05)))

(defun teams4e-test-availability-context ()
  "Return a meeting chat and representative availability payload."
  (let* ((event
          '((id . "event-availability")
            (subject . "Architecture review")
            (start . ((dateTime . "2099-08-10T09:00:00")
                      (timeZone . "UTC")))
            (end . ((dateTime . "2099-08-10T09:45:00")
                    (timeZone . "UTC")))
            (location . ((displayName . "Video room 4")))
            (responseRequested . t)
            (responseStatus . ((response . "notResponded")))
            (allowNewTimeProposals . t)
            (isOrganizer)
            (isCancelled)
            (webLink . "https://outlook.example/event")
            (onlineMeeting . ((joinUrl . "https://teams.example/join")))))
         (chat
          `((id . "meeting-availability")
            (chatType . "meeting")
            (topic . "Architecture review")
            (onlineMeetingInfo . ((calendarEventId . "event-availability")))
            (meetingContext . ((event . ,event)))))
         (first-slot
          '((start . ((dateTime . "2099-08-11T09:00:00")
                      (timeZone . "UTC")))
            (end . ((dateTime . "2099-08-11T09:45:00")
                    (timeZone . "UTC")))))
         (second-slot
          '((start . ((dateTime . "2099-08-11T10:00:00")
                      (timeZone . "UTC")))
            (end . ((dateTime . "2099-08-11T10:45:00")
                    (timeZone . "UTC")))))
         (participants
          '(((email . "user@example.test")
             (name . "Current User")
             (isSelf . t)
             (isOrganizer)
             (response . "notResponded"))
            ((email . "ada@example.test")
             (name . "Ada Lovelace")
             (isSelf)
             (isOrganizer . t)
             (response . "accepted"))))
         (working-hours
          '((daysOfWeek . ("monday" "tuesday" "wednesday"
                           "thursday" "friday"))
            (startTime . "08:00:00")
            (endTime . "17:00:00")))
         (schedules
          `(((scheduleId . "user@example.test")
             (scheduleItems
              . (((status . "busy")
                  (isPrivate . t)
                  (subject . "Board reshuffle")
                  (location . "Secret room")
                  (start . ((dateTime . "2099-08-11T12:00:00")
                            (timeZone . "UTC")))
                  (end . ((dateTime . "2099-08-11T13:00:00")
                          (timeZone . "UTC"))))))
             (workingHours . ,working-hours))
            ((scheduleId . "ada@example.test")
             (scheduleItems
              . (((status . "busy")
                  (isPrivate)
                  (subject . "Customer review")
                  (location . "Room 12")
                  (start . ((dateTime . "2099-08-11T10:00:00")
                            (timeZone . "UTC")))
                  (end . ((dateTime . "2099-08-11T11:00:00")
                          (timeZone . "UTC"))))))
             (workingHours . ,working-hours))))
         (suggestions
          `(((confidence . 100)
             (suggestionReason . "Everyone is available")
             (organizerAvailability . "free")
             (attendeeAvailability
              . (((attendee
                   . ((emailAddress
                       . ((address . "ada@example.test")))))
                  (availability . "free"))))
             (meetingTimeSlot . ,first-slot))
            ((confidence . 50)
             (suggestionReason . "One attendee has a conflict")
             (organizerAvailability . "free")
             (attendeeAvailability
              . (((attendee
                   . ((emailAddress
                       . ((address . "ada@example.test")))))
                  (availability . "busy"))))
             (meetingTimeSlot . ,second-slot))))
         (payload
          `((event . ,event)
            (participants . ,participants)
            (schedules . ,schedules)
            (suggestions . ,suggestions)
            (proposalAllowed . t))))
    `((chat . ,chat) (payload . ,payload))))

(ert-deftest teams4e-payload-list-distinguishes-arrays-and-objects ()
  (let ((chats (teams4e-test-read-json "chats.json"))
        (status (teams4e-test-read-json "status.json")))
    (should (= 2 (length (teams4e--payload-list chats))))
    (should (= 1 (length (teams4e--payload-list status))))
    (should (equal "default" (teams4e--get status 'connectionName)))))

(ert-deftest teams4e-logged-out-status-is-valid-json-without-account ()
  (let ((teams4e--connected-as "stale@example.com") result)
    (cl-letf (((symbol-function 'teams4e--run-json)
               (lambda (_args callback &optional _error-callback)
                 (funcall callback "Logged out") 'fake-process)))
      (should (eq 'fake-process
                  (teams4e--status-request (lambda (status)
                                              (setq result status)))))
      (should (equal "Logged out" result))
      (should-not teams4e--connected-as))))

(ert-deftest teams4e-html-message-rendering-removes-markup ()
  (let* ((messages (teams4e-test-read-json "messages-chat-1.json"))
         (body (teams4e--message-body (car messages))))
    (should (string-match-p "Hello Michael" body))
    (should (string-match-p "review is ready" body))
    (should-not (string-match-p "<strong>" body))))

(ert-deftest teams4e-system-events-render-useful-meeting-summaries ()
  (let ((started
         '((messageType . "systemEventMessage")
           (body . ((contentType . "html")
                    (content . "<systemEventMessage/>")))
           (eventDetail
            . ((@odata.type
                . "#microsoft.graph.callStartedEventMessageDetail")
               (callEventType . "meeting")
               (initiator
                . ((user . ((displayName . "Ada Lovelace")))))))))
        (ended
         '((messageType . "systemEventMessage")
           (eventDetail
            . ((@odata.type
                . "#microsoft.graph.callEndedEventMessageDetail")
               (callEventType . "meeting")
               (callDuration . "PT1H2M3S"))))))
    (should (equal "Meeting started by Ada Lovelace"
                   (teams4e--message-body started)))
    (should (equal "Meeting ended (1h 2m 3s)"
                   (teams4e--message-body ended)))
    (with-temp-buffer
      (let ((teams4e-display-images nil))
        (teams4e--insert-message started))
      (should (string-match-p "Meeting started by Ada Lovelace"
                              (buffer-string)))
      (should-not (string-match-p "\\[No text\\]" (buffer-string))))))

(ert-deftest teams4e-relative-hosted-images-resolve-and-render-a-fallback ()
  (let* ((directory (make-temp-file "teams4e-image-cache-" t))
         (teams4e-image-cache-directory directory)
         (teams4e-display-images t)
         (teams4e-offline-mode t)
         (teams4e--chat '((id . "19:chat@thread.v2")))
         (message
          '((id . "message-42")
            (createdDateTime . "2026-08-02T12:00:00Z")
            (from . ((user . ((displayName . "Ada")))))
            (body
             . ((contentType . "html")
                (content
                 . "<p><img src=\"../hostedContents/image-id/$value\" alt=\"diagram\"></p>")))))
         (images (teams4e--inline-images message))
         (url (teams4e--get (car images) 'contentUrl)))
    (unwind-protect
        (progn
          (should (= 1 (length images)))
          (should
           (equal
            (format
             (concat "https://graph.microsoft.com/v1.0/chats/%s/messages/"
                     "message-42/hostedContents/image-id/$value")
             (teams4e--graph-segment "19:chat@thread.v2"))
            url))
          (with-temp-buffer
            (teams4e--insert-message message)
            (should (string-match-p "Image not cached: diagram-1.png"
                                    (buffer-string)))
            (should-not (string-match-p "\\[No text\\]" (buffer-string)))))
      (delete-directory directory t))))

(ert-deftest teams4e-image-message-downloads-through-the-mock-backend ()
  (let* ((directory (make-temp-file "teams4e-image-download-" t))
         (source (expand-file-name "pixel.gif" directory))
         (cache (expand-file-name "cache" directory))
         (state (expand-file-name "tenant.json" directory))
         (buffer (generate-new-buffer " *Teams image test*"))
         (teams4e-mock-mode t)
         (teams4e-mock-state-file state)
         (teams4e-image-cache-directory cache)
         (teams4e-display-images t)
         (teams4e-offline-mode nil)
         process)
    (unwind-protect
        (progn
          (with-temp-file source
            (set-buffer-multibyte nil)
            (insert (base64-decode-string
                     "R0lGODlhAQABAIAAAAAAAP///ywAAAAAAQABAAACAUwAOw==")))
          (with-current-buffer buffer
            (teams4e--insert-message
             `((id . "image-message")
               (createdDateTime . "2026-08-02T12:00:00Z")
               (from . ((user . ((displayName . "Ada")))))
               (body . ((contentType . "text") (content . "Screenshot")))
               (attachments
                . (((id . "pixel")
                    (name . "pixel.gif")
                    (contentType . "image/gif")
                    (contentUrl . ,(concat "file://" source)))))))
            (setq process (car teams4e--image-processes)))
          (should (processp process))
          (teams4e-test-await process)
          (with-current-buffer buffer
            (should (string-match-p "Image: pixel.gif" (buffer-string)))
            (should-not (string-match-p "Loading image" (buffer-string))))
          (should (= 1 (length (directory-files cache nil "\\.gif\\'")))))
      (when (buffer-live-p buffer) (kill-buffer buffer))
      (delete-directory directory t))))

(ert-deftest teams4e-image-download-queue-is-concurrency-bounded ()
  (let ((directory (make-temp-file "teams4e-image-queue-" t))
        (teams4e-image-download-concurrency 2)
        (started 0))
    (unwind-protect
        (with-temp-buffer
          (setq-local teams4e-image-cache-directory directory)
          (cl-letf (((symbol-function 'teams4e--run-json)
                     (lambda (_args _callback &optional _error-callback)
                       (cl-incf started)
                       nil)))
            (dotimes (index 4)
              (teams4e--queue-image
               `((name . ,(format "image-%d.png" index))
                 (contentType . "image/png")
                 (contentUrl . ,(format "file:///tmp/image-%d.png" index)))
               (copy-marker (point-min))
               (format "image-%d" index))))
          (should (= 2 started))
          (should (= 2 teams4e--image-active))
          (should (= 2 (length teams4e--image-queue))))
      (delete-directory directory t))))

(ert-deftest teams4e-quoted-reply-renders-context-not-an-attachment ()
  (let* ((reference
          '((messageId . "message-1")
            (messagePreview . "Original <strong>context</strong>")
            (messageSender . ((user . ((displayName . "Ada")))))))
         (message
          `((attachments
             . (((id . "message-1")
                 (contentType . "messageReference")
                 (content . ,(json-serialize reference))))))))
    (with-temp-buffer
      (teams4e--insert-message-reference message)
      (teams4e--insert-attachments message)
      (should (string-match-p "> Ada" (buffer-string)))
      (should (string-match-p "Original context" (buffer-string)))
      (should-not (string-match-p "Attachment:" (buffer-string))))))

(ert-deftest teams4e-chat-label-excludes-connected-account ()
  (let* ((chats (teams4e-test-read-json "chats.json"))
         (members (teams4e-test-read-json "members-chat-1.json"))
         (teams4e--connected-as "user@example.com")
         (teams4e--member-cache (make-hash-table :test #'equal)))
    (puthash "chat-1" members teams4e--member-cache)
    (should (equal "Ada Lovelace" (teams4e--chat-label (car chats))))
    (should (equal "Project Atlas" (teams4e--chat-label (cadr chats))))))

(ert-deftest teams4e-chat-label-excludes-connected-user-by-id ()
  (let* ((chat '((id . "direct") (chatType . "oneOnOne")))
         (members '(((displayName . "Alex Smith") (userId . "self-id"))
                    ((displayName . "Alex Smith") (userId . "other-id"))))
         (teams4e--connected-as nil)
         (teams4e--connected-user-id "self-id")
         (teams4e--member-cache (make-hash-table :test #'equal)))
    (puthash "direct" members teams4e--member-cache)
    (should (= 1 (length (teams4e--member-names chat))))
    (should (equal "Alex Smith" (teams4e--chat-label chat)))))

(ert-deftest teams4e-fake-backend-status-and-chat-list ()
  (let ((teams4e-backend-program teams4e-test-fake-backend)
        (teams4e--connected-as nil)
        status-result
        chats-result)
    (teams4e-test-await
     (teams4e--status-request (lambda (status) (setq status-result status))))
    (should (equal "user@example.com"
                   (teams4e--get status-result 'connectedAs)))
    (teams4e-test-await
     (teams4e--load-chats (lambda (chats) (setq chats-result chats))))
    (should (= 2 (length chats-result)))
    (should (equal "chat-1" (teams4e--chat-id (car chats-result))))))

(ert-deftest teams4e-resolver-recovers-after-live-package-upgrade ()
  (let ((teams4e-backend-program
         "/tmp/elpa/teams4e-20260101.1200/bin/teams4e-graph")
        (teams4e--package-directory teams4e-test-layer-directory))
    (should
     (equal (expand-file-name "bin/teams4e-graph"
                              teams4e-test-layer-directory)
            (teams4e--executable)))))

(ert-deftest teams4e-resolver-does-not-hide-invalid-custom-backend ()
  (let ((teams4e-backend-program "/tmp/custom-teams/backend"))
    (should-error (teams4e--executable) :type 'user-error)))

(ert-deftest teams4e-send-preserves-multiline-message-as-one-argument ()
  (let* ((teams4e-backend-program teams4e-test-fake-backend)
         (log (make-temp-file "teams4e-send-"))
         (process-environment (copy-sequence process-environment))
         (message-text "Line one\nLine two; $(not-a-shell)"))
    (unwind-protect
        (progn
          (setenv "TEAMS4E_TEST_LOG" log)
          (teams4e-test-await
           (teams4e--run
            (teams4e--send-args
             '((id . "chat-1") (topic . "Ada")) message-text)
            #'ignore))
          (let ((args (json-parse-string
                       (with-temp-buffer
                         (insert-file-contents log)
                         (buffer-string))
                       :array-type 'list)))
            (should (equal message-text
                           (nth (1+ (cl-position "--message" args
                                                :test #'equal)) args)))))
      (delete-file log))))

(ert-deftest teams4e-send-args-support-direct-email ()
  (should
   (equal
    '("teams" "chat" "message" "send"
      "--userEmails" "ada@example.com"
      "--message" "Hello" "--contentType" "text" "--output" "none")
    (teams4e--send-args
     '(:user-emails "ada@example.com" :label "Ada") "Hello"))))

(ert-deftest teams4e-reply-args-preserve-target-message-id ()
  (should
   (equal
    '("teams" "chat" "message" "send"
      "--chatId" "chat-1" "--replyToId" "message-1"
      "--message" "Reply" "--contentType" "text" "--output" "none")
    (teams4e--send-args
     '((id . "chat-1") (topic . "Ada")) "Reply" '((id . "message-1"))))))

(ert-deftest teams4e-read-override-expires-when-new-message-arrives ()
  (let* ((chat (car (teams4e-test-read-json "chats.json")))
         (teams4e--read-overrides (make-hash-table :test #'equal)))
    (puthash "chat-1" '(read . "message-2")
             teams4e--read-overrides)
    (should-not (teams4e--unread-p chat))
    (setf (alist-get 'id (alist-get 'lastMessagePreview chat)) "message-3"
          (alist-get 'createdDateTime (alist-get 'lastMessagePreview chat))
          "2026-08-02T08:00:00Z")
    (should (teams4e--unread-p chat))
    (should-not (gethash "chat-1" teams4e--read-overrides))))

(ert-deftest teams4e-chat-metadata-update-does-not-create-unread-message ()
  (let ((chat
         '((id . "meeting-stub")
           (chatType . "meeting")
           (lastUpdatedDateTime . "2026-08-09T10:00:00Z")
           (viewpoint . ((lastMessageReadDateTime
                          . "2026-08-08T10:00:00Z")))))
        (teams4e--read-overrides (make-hash-table :test #'equal)))
    (should-not (teams4e--unread-p chat))
    (setf (alist-get 'lastUpdatedDateTime chat) "2026-08-09T11:00:00Z")
    (should-not (teams4e--unread-p chat))))

(ert-deftest teams4e-favorites-and-mutes-round-trip-private-local-state ()
  (let* ((directory (make-temp-file "teams4e-state-" t))
         (teams4e-state-file (expand-file-name "teams.json" directory))
         (teams4e--favorites (make-hash-table :test #'equal))
         (teams4e--muted (make-hash-table :test #'equal))
         (teams4e--state-loaded t))
    (unwind-protect
        (progn
          (puthash "chat-1" t teams4e--favorites)
          (puthash "chat-2" t teams4e--muted)
          (teams4e--save-state)
          (should (= #o600 (file-modes teams4e-state-file)))
          (setq teams4e--state-loaded nil
                teams4e--favorites (make-hash-table :test #'equal)
                teams4e--muted (make-hash-table :test #'equal))
          (teams4e--load-state)
          (should (gethash "chat-1" teams4e--favorites))
          (should (gethash "chat-2" teams4e--muted)))
      (delete-directory directory t))))

(ert-deftest teams4e-mark-read-uses-explicit-graph-command ()
  (let* ((teams4e-backend-program teams4e-test-fake-backend)
         (log (make-temp-file "teams4e-read-"))
         (process-environment (copy-sequence process-environment))
         (teams4e--read-overrides (make-hash-table :test #'equal))
         process)
    (unwind-protect
        (with-temp-buffer
          (teams4e-chat-mode)
          (setq teams4e--chat
                '((id . "chat-1")
                  (topic . "Ada")
                  (lastUpdatedDateTime . "2026-08-02T07:30:00Z")))
          (setenv "TEAMS4E_TEST_LOG" log)
          (setq process (teams4e--set-read-state 'read t))
          (teams4e-test-await process)
          (let ((args (json-parse-string
                       (with-temp-buffer
                         (insert-file-contents log)
                         (buffer-string))
                       :array-type 'list)))
            (should (equal '("teams" "chat" "mark" "read" "--chatId" "chat-1")
                           (seq-take args 6))))
          (should (eq 'read
                      (car (gethash "chat-1"
                                    teams4e--read-overrides)))))
      (delete-file log))))

(ert-deftest teams4e-error-diagnostics-redact-message-body ()
  (should
   (equal '("teams" "send" "--message" "<content redacted>" "--debug")
          (teams4e--redacted-args
           '("teams" "send" "--message" "private body" "--debug"))))
  (should
   (equal "Graph rejected <content redacted> for policy"
          (teams4e--redacted-detail
           '("--message" "private body")
           "Graph rejected private body for policy")))
  (should
   (equal '("--comment" "<content redacted>")
          (teams4e--redacted-args
           '("--comment" "private meeting note"))))
  (should
   (equal "Rejected <content redacted>"
          (teams4e--redacted-detail
           '("--comment" "private meeting note")
           "Rejected private meeting note"))))

(ert-deftest teams4e-resolves-configured-graph-backend ()
  (let ((teams4e-backend-program teams4e-test-fake-backend))
    (should (equal teams4e-test-fake-backend (teams4e--executable)))))

(ert-deftest teams4e-transcript-renders-message-properties ()
  (let* ((chat (car (teams4e-test-read-json "chats.json")))
         (messages (teams4e-test-read-json "messages-chat-1.json"))
         (teams4e--connected-user-id "current-user-id"))
    (with-temp-buffer
      (teams4e-chat-mode)
      (setq teams4e--chat chat
            teams4e--messages messages)
      (teams4e--render-chat)
      (should (string-match-p "Ada Lovelace" (buffer-string)))
      (should (string-match-p "You" (buffer-string)))
      (should (string-match-p "review.pdf" (buffer-string)))
      (goto-char (point-min))
      (teams4e-chat-next-message)
      (should (equal "message-1"
                     (teams4e--get (teams4e-message-at-point) 'id)))
      (teams4e-chat-next-message)
      (should (equal "message-2"
                     (teams4e--get (teams4e-message-at-point) 'id)))
      (forward-line 1)
      (teams4e-chat-previous-message)
      (should (equal "message-1"
                     (teams4e--get (teams4e-message-at-point) 'id))))))

(ert-deftest teams4e-message-navigation-treats-buffer-edges-as-outside-messages ()
  (let* ((chat (car (teams4e-test-read-json "chats.json")))
         (messages (teams4e-test-read-json "messages-chat-1.json"))
         (teams4e--connected-user-id "current-user-id"))
    (with-temp-buffer
      (teams4e-chat-mode)
      (setq teams4e--chat chat
            teams4e--messages messages)
      (teams4e--render-chat)
      (should (equal "message-2"
                     (teams4e--get (teams4e-message-at-point) 'id)))
      (goto-char (point-min))
      (teams4e-chat-next-message)
      (should (equal "message-1"
                     (teams4e--get (teams4e-message-at-point) 'id))))))

(ert-deftest teams4e-explicit-chat-open-renders-at-buffer-bottom-once ()
  (let* ((chat (car (teams4e-test-read-json "chats.json")))
         (messages (teams4e-test-read-json "messages-chat-1.json"))
         (teams4e--connected-user-id "current-user-id"))
    (with-temp-buffer
      (teams4e-chat-mode)
      (setq teams4e--chat chat
            teams4e--messages messages
            teams4e--jump-to-bottom-on-render t)
      (teams4e--render-chat)
      (should (= (point) (point-max)))
      (should-not teams4e--jump-to-bottom-on-render)
      (should-not (get-text-property (point) 'teams4e-message))
      (teams4e-chat-previous-message)
      (should (equal "message-2"
                     (teams4e--get
                      (teams4e-message-at-point) 'id))))))

(ert-deftest teams4e-opening-thread-respects-read-policy ()
  (let* ((chat '((id . "chat-policy") (topic . "Policy test")))
         (buffer-name teams4e--preview-buffer-name)
         (teams4e-mark-read-on-open nil)
         marked)
    (unwind-protect
        (cl-letf (((symbol-function 'teams4e-chat-refresh) #'ignore)
                  ((symbol-function 'teams4e--display-chat-buffer) #'ignore)
                  ((symbol-function 'teams4e--set-read-state)
                   (lambda (state &optional _quiet) (setq marked state))))
          (teams4e-open-chat chat t)
          (should-not marked)
          (with-current-buffer buffer-name
            (should-not teams4e--jump-to-bottom-on-render))
          (setq teams4e-mark-read-on-open t)
          (teams4e-open-chat chat t)
          (should (eq 'read marked))
          (teams4e-open-chat chat)
          (with-current-buffer buffer-name
            (should teams4e--jump-to-bottom-on-render)))
      (when-let ((buffer (get-buffer buffer-name))) (kill-buffer buffer)))))

(ert-deftest teams4e-thread-preview-keeps-inbox-focus ()
  (let ((index (get-buffer-create teams4e--recent-buffer-name))
        (thread (generate-new-buffer " *Teams preview test*"))
        (teams4e-index-width 0.46))
    (unwind-protect
        (save-window-excursion
          (delete-other-windows)
          (switch-to-buffer index)
          (let ((index-window (selected-window)))
            (teams4e--display-chat-buffer thread t)
            (should (eq index-window (selected-window)))
            (should (get-buffer-window thread))
            (teams4e--display-chat-buffer thread nil)
            (should (eq thread (window-buffer (selected-window))))))
      (when (buffer-live-p index) (kill-buffer index))
      (when (buffer-live-p thread) (kill-buffer thread)))))

(ert-deftest teams4e-reopen-inbox-preserves-buffer-request-state ()
  (let ((buffer (get-buffer-create teams4e--recent-buffer-name)))
    (unwind-protect
        (progn
          (with-current-buffer buffer
            (teams4e-recent-mode)
            (setq teams4e--request-id 41))
          (save-current-buffer
            (cl-letf (((symbol-function 'pop-to-buffer)
                       (lambda (target &rest _args) (set-buffer target)))
                      ((symbol-function 'teams4e--with-status)
                       (lambda (_callback) nil)))
              (teams4e-recent)))
          (with-current-buffer buffer
            (should (= 41 teams4e--request-id))))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest teams4e-reopen-channel-preserves-buffer-request-state ()
  (let* ((team '((id . "team-1") (displayName . "Engineering")))
         (channel '((id . "channel-1") (displayName . "General")))
         (buffer
          (get-buffer-create
           (teams4e--channel-index-buffer-name team channel)))
         refreshed)
    (unwind-protect
        (progn
          (with-current-buffer buffer
            (teams4e-channel-index-mode)
            (setq teams4e-channel--request-id 41))
          (save-current-buffer
            (cl-letf (((symbol-function 'pop-to-buffer)
                       (lambda (target &rest _args) (set-buffer target)))
                      ((symbol-function 'teams4e-channel-refresh)
                       (lambda () (setq refreshed t))))
              (teams4e-open-channel team channel)))
          (should refreshed)
          (with-current-buffer buffer
            (should (= 41 teams4e-channel--request-id))))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest teams4e-chat-selection-callback-uses-initiating-buffer ()
  (let ((origin (generate-new-buffer " *Teams select origin*"))
        (transport (generate-new-buffer " *Teams select transport*"))
        observed)
    (unwind-protect
        (progn
          (with-current-buffer origin
            (cl-letf (((symbol-function 'teams4e--with-status)
                       (lambda (callback)
                         (with-current-buffer transport (funcall callback))))
                      ((symbol-function 'teams4e--load-chats)
                       (lambda (callback &optional _error-callback)
                         (with-current-buffer transport
                           (funcall callback '(((id . "chat-1")))))))
                      ((symbol-function 'teams4e--choose-chat)
                       (lambda (chats callback)
                         (with-current-buffer transport
                           (funcall callback (car chats))))))
              (teams4e--select-chat
               (lambda (_chat) (setq observed (current-buffer))))))
          (should (eq origin observed)))
      (when (buffer-live-p origin) (kill-buffer origin))
      (when (buffer-live-p transport) (kill-buffer transport)))))

(ert-deftest teams4e-markdown-export-preserves-structure-and-source ()
  (let* ((chat (car (teams4e-test-read-json "chats.json")))
         (messages (teams4e-test-read-json "messages-chat-1.json"))
         (history '((complete . t)
                    (pageCount . 3)
                    (messageCount . 2)
                    (oldestDateTime . "2026-08-02T08:00:00Z")
                    (newestDateTime . "2026-08-02T09:00:00Z")))
         (markdown (teams4e--thread-markdown chat messages history)))
    (should (string-match-p "# One-to-one chat" markdown))
    (should (string-match-p "## 2026-08-02" markdown))
    (should (string-match-p "Messages: 2" markdown))
    (should (string-match-p "Complete Microsoft Graph pagination (3 pages)"
                            markdown))
    (should (string-match-p "Range: 2026-08-02" markdown))
    (should (string-match-p "### [0-9][0-9]:[0-9][0-9] - " markdown))
    (should (string-match-p (regexp-quote "Hello **Michael**") markdown))
    (should (string-match-p
             (regexp-quote "[review.pdf](https://example.com/review.pdf)")
             markdown))
    (should (string-match-p "Reactions: like 2" markdown))
    (should (string-match-p "Teams chat ID: `chat-1`" markdown))))

(ert-deftest teams4e-html-to-markdown-collapses-excess-blank-lines ()
  (should
   (equal "One\n\nTwo"
          (teams4e--html-to-markdown
           "<p>One</p><br><br><p>Two</p>"))))

(ert-deftest teams4e-export-requests-unbounded-history ()
  (let ((teams4e-message-days 30)
        (teams4e-message-limit 300)
        (chat '((id . "chat-1"))))
    (should (member "--modifiedStartDateTime"
                    (teams4e--message-args chat nil)))
    (should (equal "300"
                   (cadr (member "--limit"
                                 (teams4e--message-args chat nil)))))
    (should (equal "75"
                   (cadr (member "--limit"
                                 (teams4e--message-args
                                  chat nil 75)))))
    (should-not (member "--modifiedStartDateTime"
                        (teams4e--message-args chat t)))
    (should-not (member "--limit"
                        (teams4e--message-args chat t)))))

(ert-deftest teams4e-incremental-history-keeps-limit-and-removes-date-window ()
  (let* ((teams4e-message-days 30)
         (chat '((id . "chat-1")))
         (args (teams4e--message-args chat nil 600 t)))
    (should (equal "600" (cadr (member "--limit" args))))
    (should-not (member "--modifiedStartDateTime" args))))

(ert-deftest teams4e-message-display-order-does-not-mutate-chronology ()
  (let* ((older '((id . "older")
                  (createdDateTime . "2026-08-01T09:00:00Z")))
         (newer '((id . "newer")
                  (createdDateTime . "2026-08-01T10:00:00Z")))
         (messages (list older newer))
         (teams4e-message-order 'oldest-first))
    (with-temp-buffer
      (should (equal '("older" "newer")
                     (mapcar (lambda (message)
                               (teams4e--get message 'id))
                             (teams4e--messages-for-display
                              messages))))
      (setq-local teams4e--message-order 'newest-first)
      (should (equal '("newer" "older")
                     (mapcar (lambda (message)
                               (teams4e--get message 'id))
                             (teams4e--messages-for-display
                              messages))))
      (should (equal '("older" "newer")
                     (mapcar (lambda (message)
                               (teams4e--get message 'id))
                             messages))))))

(ert-deftest teams4e-message-normalization-uses-absolute-time-and-stable-ties ()
  (let* ((messages
          '(((id . "duplicate")
             (createdDateTime . "2026-08-04T09:30:00.1000000Z")
             (body . ((content . "fresh"))))
            ((id . "same-b")
             (createdDateTime . "2026-08-04T12:00:00+03:00"))
            ((id . "same-a")
             (createdDateTime . "2026-08-04T09:00:00Z"))
            ((id . "middle")
             (createdDateTime . "2026-08-04T09:30:00.0900000Z"))
            ((id . "duplicate")
             (createdDateTime . "2026-08-04T09:30:00.1000000Z")
             (body . ((content . "stale"))))))
         (normalized (teams4e--normalize-messages messages)))
    (should
     (equal '("same-a" "same-b" "middle" "duplicate")
            (mapcar (lambda (message) (teams4e--get message 'id))
                    normalized)))
    (should
     (equal "fresh"
            (teams4e--dig (car (last normalized)) 'body 'content)))))

(ert-deftest teams4e-message-order-toggle-rerenders-and-preserves-selection ()
  (let ((chat (car (teams4e-test-read-json "chats.json")))
        (messages (teams4e-test-read-json "messages-chat-1.json"))
        (teams4e-message-order 'oldest-first)
        (teams4e-display-images nil))
    (with-temp-buffer
      (teams4e-chat-mode)
      (setq teams4e--chat chat
            teams4e--messages messages)
      (teams4e--render-chat)
      (should (teams4e--goto-message-id "message-1"))
      (teams4e-toggle-message-order)
      (should (equal "message-1"
                     (teams4e--get
                      (teams4e-message-at-point) 'id)))
      (should (equal '("message-2" "message-1")
                     (mapcar
                      (lambda (position)
                        (teams4e--get
                         (get-text-property position 'teams4e-message) 'id))
                      (teams4e--message-positions))))
      (should (string-match-p "newest first" header-line-format)))))

(ert-deftest teams4e-complete-refresh-does-not-trim-rendered-history ()
  (let ((teams4e-message-limit 2)
        (messages
         '(((id . "one") (createdDateTime . "2026-08-01T09:00:00Z"))
           ((id . "two") (createdDateTime . "2026-08-01T10:00:00Z"))
           ((id . "three") (createdDateTime . "2026-08-01T11:00:00Z")))))
    (with-temp-buffer
      (teams4e-chat-mode)
      (setq teams4e--chat '((id . "chat-1")))
      (cl-letf (((symbol-function 'teams4e--run-json)
                 (lambda (_args callback &optional _error-callback)
                   (funcall callback messages)
                   'fake-process))
                ((symbol-function 'teams4e--render-chat) #'ignore))
        (teams4e-chat-refresh t))
      (should (= 3 (length teams4e--messages)))
      (should teams4e--loaded-all))))

(ert-deftest teams4e-load-more-expands-bound-beyond-date-window ()
  (let ((teams4e-load-more-count 300)
        observed)
    (with-temp-buffer
      (teams4e-chat-mode)
      (setq teams4e--messages '(((id . "one")) ((id . "two"))))
      (cl-letf (((symbol-function 'teams4e-chat-refresh)
                 (lambda (&optional all limit ignore-date)
                   (setq observed (list all limit ignore-date)))))
        (teams4e-chat-load-more))
      (should (equal '(nil 302 t) observed))
      (setq teams4e--loaded-all t)
      (should-error (teams4e-chat-load-more) :type 'user-error))))

(ert-deftest teams4e-export-writes-private-markdown-file ()
  (let* ((directory (make-temp-file "teams4e-export-" t))
         (path (expand-file-name "nested/thread.md" directory))
         (chat (car (teams4e-test-read-json "chats.json")))
         (messages (teams4e-test-read-json "messages-chat-1.json")))
    (unwind-protect
        (progn
          (should (equal path
                         (teams4e--write-thread-export
                          path chat messages)))
          (should (= #o600 (file-modes path)))
          (with-temp-buffer
            (insert-file-contents path)
            (should (search-forward "# One-to-one chat" nil t))
            (should (search-forward "review.pdf" nil t))))
      (delete-directory directory t))))

(ert-deftest teams4e-copy-thread-fetches-complete-chronological-markdown ()
  (let* ((chat '((id . "chat-copy") (topic . "Copy test")))
         (newer '((id . "newer")
                  (createdDateTime . "2026-08-01T11:00:00Z")
                  (from . ((user . ((displayName . "Grace")))))
                  (body . ((contentType . "text") (content . "Second")))))
         (older '((id . "older")
                  (createdDateTime . "2026-08-01T10:00:00Z")
                  (from . ((user . ((displayName . "Ada")))))
                  (body . ((contentType . "text") (content . "First")))))
         captured-args
         captured-markdown
         (history '((complete . t)
                    (pageCount . 2)
                    (messageCount . 2)
                    (oldestDateTime . "2026-08-01T10:00:00Z")
                    (newestDateTime . "2026-08-01T11:00:00Z"))))
    (cl-letf (((symbol-function 'teams4e--run-json)
               (lambda (args callback &optional _error-callback)
                 (setq captured-args args)
                 (funcall callback `((value . (,newer ,older))
                                     (history . ,history)))
                 'fake-process))
              ((symbol-function 'kill-new)
               (lambda (text &optional _replace)
                 (setq captured-markdown text))))
      (teams4e--copy-chat-thread-markdown chat))
    (should (equal '("teams" "chat" "message" "export")
                   (seq-take captured-args 4)))
    (should-not (member "--limit" captured-args))
    (should-not (member "--modifiedStartDateTime" captured-args))
    (should (string-match-p "Complete Microsoft Graph pagination"
                            captured-markdown))
    (should (< (string-match "First" captured-markdown)
               (string-match "Second" captured-markdown)))))

(ert-deftest teams4e-thread-analysis-exports-full-chat-before-first-prompt ()
  (let* ((directory (make-temp-file "teams4e-agent-thread-" t))
         (path (expand-file-name "thread.md" directory))
         (chat '((id . "chat-agent") (topic . "Agent analysis")))
         (messages '(((id . "message-agent")
                      (createdDateTime . "2026-08-06T10:00:00Z")
                      (from . ((user . ((displayName . "Ada")))))
                      (body . ((contentType . "text")
                               (content . "Analyze this"))))))
         (history '((complete . t)
                    (pageCount . 1)
                    (messageCount . 1)
                    (oldestDateTime . "2026-08-06T10:00:00Z")
                    (newestDateTime . "2026-08-06T10:00:00Z")))
         (config '((:identifier . cursor)))
         request-args start-args insert-args start-directory)
    (unwind-protect
        (cl-letf (((symbol-function 'teams4e--chat-at-point)
                   (lambda () chat))
                  ((symbol-function
                    'teams4e--thread-analysis-agent-config)
                   (lambda () config))
                  ((symbol-function 'teams4e--export-path)
                   (lambda (_chat) path))
                  ((symbol-function 'teams4e--run-json)
                   (lambda (args callback &optional _error-callback)
                     (setq request-args args)
                     (funcall callback `((value . ,messages)
                                         (history . ,history)))
                     'fake-process))
                  ((symbol-function 'agent-shell-start)
                   (lambda (&rest args)
                     (setq start-args args
                           start-directory default-directory)
                     'agent-buffer))
                  ((symbol-function 'agent-shell-insert)
                   (lambda (&rest args)
                     (setq insert-args args))))
          (teams4e-analyze-current-thread)
          (should (file-exists-p path))
          (should (= #o600 (file-modes path)))
          (should (equal '("teams" "chat" "message" "export")
                         (seq-take request-args 4)))
          (should-not (member "--limit" request-args))
          (should-not (member "--modifiedStartDateTime" request-args))
          (should (equal config (plist-get start-args :config)))
          (should (equal (file-name-as-directory directory) start-directory))
          (should (eq 'agent-buffer (plist-get insert-args :shell-buffer)))
          (should (eq t (plist-get insert-args :submit)))
          (should
           (equal (format "$thread-analysis of this thread: %s" path)
                  (plist-get insert-args :text))))
      (delete-directory directory t))))

(ert-deftest teams4e-complete-export-refuses-partial-offline-cache ()
  (let ((teams4e-offline-mode t)
        (chat '((id . "chat-offline"))))
    (should-error (teams4e--full-history-args chat) :type 'user-error)))

(ert-deftest teams4e-transcript-groups-and-labels-local-time-consistently ()
  (let ((created "2026-08-02T22:30:00Z"))
    (with-temp-buffer
      (teams4e--insert-day-separator created)
      (teams4e--insert-message
       `((id . "late-message")
         (createdDateTime . ,created)
         (from . ((user . ((displayName . "Ada")))))
         (body . ((contentType . "text") (content . "Late update")))))
      (let ((rendered (buffer-string)))
        (should (string-match-p "---.*[A-Z][a-z]+.*---" rendered))
        (should-not (string-match-p "August  [0-9]" rendered))
        (should (string-match-p "Ada  [0-9][0-9]:[0-9][0-9]" rendered))
        (should (string-match-p "  Late update" rendered))
        (should-not (string-match-p "Ada  2026-" rendered))))))

(ert-deftest teams4e-thread-analysis-resolves-the-customized-agent-symbol ()
  (let ((teams4e-thread-analysis-agent 'cursor)
        (original-require (symbol-function 'require))
        observed)
    (cl-letf (((symbol-function 'require)
               (lambda (feature &optional filename noerror)
                 (if (eq feature 'agent-shell)
                     t
                   (funcall original-require feature filename noerror))))
              ((symbol-function 'agent-shell--resolve-config-designator)
               (lambda (identifier)
                 (setq observed identifier)
                 '((:identifier . cursor)))))
      (should
       (equal '((:identifier . cursor))
              (teams4e--thread-analysis-agent-config)))
      (should (eq 'cursor observed)))))

(ert-deftest teams4e-capture-appends-org-entry-with-source-properties ()
  (let* ((directory (make-temp-file "teams4e-capture-" t))
         (file (expand-file-name "inbox/teams.org" directory))
         (chat (car (teams4e-test-read-json "chats.json")))
         (message (car (teams4e-test-read-json "messages-chat-1.json")))
         marker)
    (unwind-protect
        (progn
          (setq marker (teams4e--capture-entry chat message file))
          (should (marker-buffer marker))
          (with-temp-buffer
            (insert-file-contents file)
            (should (search-forward "* Ada Lovelace: Hello Michael" nil t))
            (should (search-forward ":TEAMS_CHAT: chat-1" nil t))
            (should (search-forward ":TEAMS_MESSAGE: message-1" nil t))
            (should (search-forward "Open in Microsoft Teams" nil t))))
      (when (and marker (buffer-live-p (marker-buffer marker)))
        (kill-buffer (marker-buffer marker)))
      (delete-directory directory t))))

(ert-deftest teams4e-thread-org-capture-preserves-conversation-metadata ()
  (let* ((chat (car (teams4e-test-read-json "chats.json")))
         (messages (teams4e-test-read-json "messages-chat-1.json"))
         (context
          (teams4e--chat-capture-context chat (car messages)))
         (entry (teams4e--thread-org-entry context messages)))
    (should (string-match-p "\\* Teams: One-to-one chat" entry))
    (should (string-match-p ":TEAMS_CHAT: chat-1" entry))
    (should (string-match-p ":TEAMS_TYPE: Direct" entry))
    (should (string-match-p ":TEAMS_MESSAGE: message-1" entry))
    (should (string-match-p "Open selected item in Microsoft Teams" entry))
    (should (string-match-p "Ada Lovelace" entry))
    (should (string-match-p "Michael-David Fiszer" entry))
    (should (string-match-p "review.pdf" entry))))

(ert-deftest teams4e-summary-capture-is-compact-and-actionable ()
  (let* ((chat (car (teams4e-test-read-json "chats.json")))
         (message (car (teams4e-test-read-json "messages-chat-1.json")))
         (context (teams4e--chat-capture-context chat message))
         (entry (teams4e--summary-org-entry context message)))
    (should (string-match-p "\\* Teams: One-to-one chat" entry))
    (should (string-match-p ":TEAMS_CHAT: chat-1" entry))
    (should (string-match-p ":TEAMS_MESSAGE: message-1" entry))
    (should (string-match-p "Open in Microsoft Teams" entry))
    (should (string-match-p "Last activity" entry))
    (should (string-match-p "\\*\\* Last message" entry))
    (should (string-match-p "Hello Michael" entry))
    (should-not (string-match-p "Transcript" entry))
    (should-not (string-match-p "Michael-David Fiszer" entry))))

(ert-deftest teams4e-thread-capture-uses-editable-org-capture-target ()
  (require 'org-capture)
  (let* ((directory (make-temp-file "teams4e-thread-capture-" t))
         (file (expand-file-name "inbox/teams.org" directory))
         (teams4e-capture-file file)
         (context '((title . "Architecture review")
                    (kind . "chat")
                    (chatId . "chat-1")))
         (messages '(((id . "message-1")
                      (createdDateTime . "2026-08-02T10:00:00Z")
                      (body . ((contentType . "text")
                               (content . "Review this"))))))
         captured-string captured-key captured-templates)
    (unwind-protect
        (cl-letf (((symbol-function 'org-capture-string)
                   (lambda (string key)
                     (setq captured-string string
                           captured-key key
                           captured-templates org-capture-templates))))
          (teams4e--start-thread-org-capture context messages)
          (should (equal "T" captured-key))
          (should (string-match-p "Architecture review" captured-string))
          (should (equal `(file ,file)
                         (nth 3 (car captured-templates))))
          (should (equal "%i\n%?" (nth 4 (car captured-templates)))))
      (delete-directory directory t))))

(ert-deftest teams4e-channel-capture-context-includes-team-and-thread ()
  (let* ((team '((id . "team-1") (displayName . "Engineering")))
         (channel '((id . "channel-1") (displayName . "General")))
         (root '((id . "root-1")
                 (webUrl . "https://teams.microsoft.com/l/message/root-1")
                 (subject . "Architecture review")
                 (createdDateTime . "2026-08-02T10:00:00Z")))
         (context
          (teams4e--channel-capture-context
           team channel root root))
         (entry (teams4e--thread-org-entry context (list root))))
    (should (string-match-p ":TEAMS_TEAM_ID: team-1" entry))
    (should (string-match-p ":TEAMS_TEAM: Engineering" entry))
    (should (string-match-p ":TEAMS_CHANNEL_ID: channel-1" entry))
    (should (string-match-p ":TEAMS_CHANNEL: General" entry))
    (should (string-match-p ":TEAMS_THREAD: root-1" entry))
    (should (string-match-p "Architecture review" entry))))

(ert-deftest teams4e-app-url-uses-native-protocol-handler ()
  (should
   (equal
    "msteams://teams.microsoft.com/l/message/chat-1/message-1"
    (teams4e--app-url
     "https://teams.microsoft.com/l/message/chat-1/message-1")))
  (should
   (equal "msteams://teams.microsoft.com/l/chat/chat-1/0"
          (teams4e--app-url
           "msteams://teams.microsoft.com/l/chat/chat-1/0")))
  (should-error (teams4e--app-url "https://example.com/chat")
                :type 'user-error))

(ert-deftest teams4e-browser-url-bypasses-desktop-launcher ()
  (should
   (equal
    "https://teams.microsoft.com/#/l/chat/chat-1/0?tenantId=tenant-1"
    (teams4e--browser-url
     "https://teams.microsoft.com/l/chat/chat-1/0?tenantId=tenant-1")))
  (should
   (equal
    "https://teams.cloud.microsoft/#/l/message/chat-1/message-1"
    (teams4e--browser-url
     "https://teams.cloud.microsoft/l/message/chat-1/message-1")))
  (should
   (equal
    "https://teams.microsoft.com/#/l/chat/already-routed"
    (teams4e--browser-url
     "https://teams.microsoft.com/#/l/chat/already-routed"))))

(ert-deftest teams4e-open-commands-use-configured-argv ()
  (let ((teams4e-browser-command '("browser-program" "--new-window"))
        (teams4e-app-command '("open"))
        commands)
    (cl-letf (((symbol-function 'make-process)
               (lambda (&rest properties)
                 (push (plist-get properties :command) commands)
                 'fake-process)))
      (teams4e--open-url-in-browser
       "https://teams.microsoft.com/l/chat/chat-1/0")
      (teams4e--open-url-in-app
       "https://teams.cloud.microsoft/l/chat/chat-1/0"))
    (should
     (equal
      '(("open" "msteams://teams.cloud.microsoft/l/chat/chat-1/0")
        ("browser-program" "--new-window"
         "https://teams.microsoft.com/#/l/chat/chat-1/0"))
      commands))))

(ert-deftest teams4e-short-command-aliases-exist ()
  (dolist (command '(teams teams-inbox teams-chat teams-recent teams-send
                     teams-export-thread teams-copy-thread-markdown
                     teams-analyze-thread
                     teams-capture-action teams-capture-message
                     teams-capture-thread teams-unread-filter
                     teams-propose-new-time teams-meetings
                     teams-meeting-availability teams-meeting-respond
                     teams-meeting-join teams-meeting-open-calendar))
    (should (commandp command))))

(ert-deftest teams4e-public-export-and-capture-aliases-are-context-aware ()
  (should (eq (indirect-function 'teams-export-thread)
              (indirect-function 'teams4e-export-current-thread)))
  (should (eq (indirect-function 'teams-copy-thread-markdown)
              (indirect-function
               'teams4e-copy-current-thread-markdown)))
  (should (eq (indirect-function 'teams-analyze-thread)
              (indirect-function
               'teams4e-analyze-current-thread)))
  (should (eq (indirect-function 'teams-capture-message)
              (indirect-function 'teams4e-capture-current-message)))
  (should (eq (indirect-function 'teams-capture-action)
              (indirect-function 'teams4e-capture-current-summary)))
  (should (eq (indirect-function 'teams-capture-thread)
              (indirect-function 'teams4e-capture-current-thread))))

(ert-deftest teams4e-advanced-command-aliases-exist ()
  (dolist (command '(teams-channels teams-search teams-bookmark teams-filter
                     teams-bulk-action teams-close-inactive teams-sync
                     teams-user teams-create-chat teams-dispatch
                     teams-server-search teams-drafts teams-meeting-transcript
                     teams-propose-new-time
                     teams-handle teams-snooze teams-clear-triage
                     teams-jump-capture))
    (should (commandp command))))

(ert-deftest teams4e-channel-send-args-preserve-rich-metadata ()
  (should
   (equal
    '("teams" "channel" "message" "send"
      "--teamId" "team-1" "--channelId" "channel-1"
      "--replyToId" "root-1"
      "--message" "Hello @Ada" "--contentType" "html"
      "--attachment" "/tmp/report.pdf"
      "--mention" "ada-id|Ada"
      "--output" "none")
    (teams4e--send-args
     '(:team-id "team-1" :channel-id "channel-1" :label "General")
     "Hello @Ada"
     '((id . "root-1"))
     '("/tmp/report.pdf")
     '("ada-id|Ada")
     "html"))))

(ert-deftest teams4e-offline-args-use-credential-free-cache ()
  (let ((teams4e-offline-mode t)
        (teams4e-message-limit 42))
    (should
     (equal '("teams" "cache" "chat" "message" "list"
              "--chatId" "chat-1" "--limit" "42")
            (teams4e--message-args '((id . "chat-1")))))
    (should
     (equal '("teams" "cache" "chat" "message" "list"
              "--chatId" "chat-1" "--limit" "1000000")
            (teams4e--message-args '((id . "chat-1")) t)))))

(ert-deftest teams4e-batch-history-keeps-newest-inverse-first ()
  (let* ((older (list :kind 'read :chat-id "older"))
         (newer (list :kind 'unread :chat-id "newer"))
         (existing (list :kind 'favorite :chat-id "existing"))
         (teams4e--action-history (list existing)))
    (teams4e--record-completed-actions (list newer older))
    (should (eq newer (nth 0 teams4e--action-history)))
    (should (eq older (nth 1 teams4e--action-history)))
    (should (eq existing (nth 2 teams4e--action-history)))))

(ert-deftest teams4e-partial-sync-uses-failure-callback-and-no-success-time ()
  (let ((teams4e-offline-mode nil)
        (teams4e--last-sync nil)
        succeeded failed)
    (cl-letf (((symbol-function 'teams4e--run-json)
               (lambda (_args callback &optional _error-callback)
                 (funcall callback
                          '((errors . (((resource . "chat:1")
                                        (error . "retry me"))))))
                 'fake-process)))
      (teams4e-sync
       nil
       (lambda (_payload) (setq succeeded t))
       (lambda (status detail) (setq failed (cons status detail)))))
    (should-not succeeded)
    (should-not teams4e--last-sync)
    (should (equal "partial" (car failed)))
    (should (string-match-p "retry me" (cdr failed)))
    (should (string-match-p "partial" teams4e--mode-line))))

(ert-deftest teams4e-saved-search-views-round-trip-with-favorites ()
  (let* ((directory (make-temp-file "teams4e-views-" t))
         (teams4e-state-file (expand-file-name "state.json" directory))
         (teams4e--favorites (make-hash-table :test #'equal))
         (teams4e--saved-views (make-hash-table :test #'equal))
         (teams4e--state-loaded t))
    (unwind-protect
        (progn
          (puthash "chat-1" t teams4e--favorites)
          (puthash "Urgent" "release blocker" teams4e--saved-views)
          (teams4e--save-state)
          (setq teams4e--state-loaded nil
                teams4e--favorites (make-hash-table :test #'equal)
                teams4e--saved-views (make-hash-table :test #'equal))
          (teams4e--load-state)
          (should (gethash "chat-1" teams4e--favorites))
          (should (equal "release blocker"
                         (gethash "Urgent" teams4e--saved-views))))
      (delete-directory directory t))))

(ert-deftest teams4e-cache-search-opens-complete-chat-at-message ()
  (let ((message
         '((id . "old-message")
           (cacheContext . ((scopeKind . "chat") (scopeId . "chat-1")))))
        captured)
    (with-temp-buffer
      (teams4e-search-mode)
      (setq tabulated-list-entries
            (list (list message ["date" "sender" "chat" "body"])))
      (tabulated-list-print t)
      (goto-char (point-min))
      (cl-letf (((symbol-function 'teams4e-open-chat)
                 (lambda (&rest args) (setq captured args))))
        (teams4e-search-open)))
    (should (equal "chat-1"
                   (teams4e--chat-id (nth 0 captured))))
    (should-not (nth 1 captured))
    (should (eq t (nth 2 captured)))
    (should (equal "old-message" (nth 3 captured)))))

(ert-deftest teams4e-built-in-inbox-views-filter-chat-types-and-unread ()
  (let* ((chats (teams4e-test-read-json "chats.json"))
         (teams4e--read-overrides (make-hash-table :test #'equal))
         (teams4e--favorites (make-hash-table :test #'equal))
         (teams4e--state-loaded t))
    (let ((teams4e--active-view 'direct))
      (should (teams4e--view-chat-p (car chats)))
      (should-not (teams4e--view-chat-p (cadr chats))))
    (let ((teams4e--active-view 'group))
      (should-not (teams4e--view-chat-p (car chats)))
      (should (teams4e--view-chat-p (cadr chats))))
    (puthash "chat-1" t teams4e--favorites)
    (let ((teams4e--active-view 'favorites))
      (should (teams4e--view-chat-p (car chats))))))

(ert-deftest teams4e-message-views-hide-message-less-meeting-stubs ()
  (let* ((empty-meeting
          '((id . "empty-meeting")
            (chatType . "meeting")
            (lastUpdatedDateTime . "2026-08-08T12:00:00Z")))
         (active-meeting
          '((id . "active-meeting")
            (chatType . "meeting")
            (lastUpdatedDateTime . "2026-08-08T12:00:00Z")
            (lastMessagePreview
             . ((id . "message-1")
                (createdDateTime . "2026-08-08T11:00:00Z")))))
         (incomplete-meeting
          '((id . "incomplete-meeting")
            (chatType . "meeting")
            (lastMessagePreview
             . ((createdDateTime . "2026-08-08T11:30:00Z")))))
         (empty-group
          '((id . "empty-group")
            (chatType . "group")
            (lastUpdatedDateTime . "2026-08-08T12:00:00Z")))
         (teams4e--read-overrides (make-hash-table :test #'equal))
         (teams4e--favorites (make-hash-table :test #'equal))
         (teams4e--muted (make-hash-table :test #'equal))
         (teams4e--handled (make-hash-table :test #'equal))
         (teams4e--snoozed (make-hash-table :test #'equal))
         (teams4e--state-loaded t))
    (let ((teams4e--active-view 'inbox)
          (teams4e--active-query nil))
      (should-not (teams4e--view-chat-p empty-meeting))
      (should (teams4e--view-chat-p active-meeting))
      (should-not (teams4e--view-chat-p incomplete-meeting))
      (should (teams4e--view-chat-p empty-group)))
    (let ((teams4e--active-view 'inbox)
          (teams4e--active-query "unread"))
      (should-not (teams4e--view-chat-p empty-meeting)))
    (let ((teams4e--active-view 'inbox)
          (teams4e--active-query "type:meeting"))
      (should (teams4e--view-chat-p empty-meeting)))))

(ert-deftest teams4e-upcoming-meetings-use-calendar-status-and-start-order ()
  (let* ((later
          '((id . "later") (chatType . "meeting")
            (meetingContext
             . ((event
                 . ((start . ((dateTime . "2099-08-11T10:00:00")
                              (timeZone . "UTC")))
                    (end . ((dateTime . "2099-08-11T11:00:00")
                            (timeZone . "UTC")))
                    (isCancelled)))))))
         (sooner
          '((id . "sooner") (chatType . "meeting")
            (meetingContext
             . ((event
                 . ((start . ((dateTime . "2099-08-10T08:00:00")
                              (timeZone . "UTC")))
                    (end . ((dateTime . "2099-08-10T09:00:00")
                            (timeZone . "UTC")))
                    (responseStatus . ((response . "accepted")))))))))
         (cancelled
          '((id . "cancelled") (chatType . "meeting")
            (meetingContext
             . ((event
                 . ((start . ((dateTime . "2099-08-09T08:00:00")
                              (timeZone . "UTC")))
                    (end . ((dateTime . "2099-08-09T09:00:00")
                            (timeZone . "UTC")))
                    (isCancelled . t)))))))
         (visible (seq-filter
                   (lambda (chat)
                     (teams4e--built-in-view-chat-p chat 'upcoming))
                   (list later cancelled sooner))))
    (should (equal '("sooner" "later")
                   (mapcar #'teams4e--chat-id
                           (sort visible
                                 #'teams4e--meeting-starts-before-p))))
    (should (eq 'upcoming
                (plist-get
                 (seq-find (lambda (bookmark)
                             (eq (plist-get bookmark :key) ?m))
                           teams4e-bookmarks)
                 :query)))
    (should (equal "type:meeting"
                   (plist-get
                    (seq-find (lambda (bookmark)
                                (eq (plist-get bookmark :key) ?M))
                              teams4e-bookmarks)
                    :query)))))

(ert-deftest teams4e-message-and-meeting-views-use-distinct-order-keys ()
  (let* ((new-message-late-meeting
          '((id . "new-message") (chatType . "meeting")
            (lastUpdatedDateTime . "2099-08-30T12:00:00Z")
            (lastMessagePreview
             . ((id . "message-new")
                (createdDateTime . "2026-08-08T12:00:00Z")))
            (meetingContext
             . ((event
                 . ((start . ((dateTime . "2099-08-11T10:00:00")
                              (timeZone . "UTC")))
                    (end . ((dateTime . "2099-08-11T11:00:00")
                            (timeZone . "UTC")))))))))
         (old-message-early-meeting
          '((id . "old-message") (chatType . "meeting")
            (lastUpdatedDateTime . "2099-09-01T12:00:00Z")
            (lastMessagePreview
             . ((id . "message-old")
                (createdDateTime . "2026-08-07T12:00:00Z")))
            (meetingContext
             . ((event
                 . ((start . ((dateTime . "2099-08-10T08:00:00")
                              (timeZone . "UTC")))
                    (end . ((dateTime . "2099-08-10T09:00:00")
                            (timeZone . "UTC")))))))))
         (rows (list old-message-early-meeting new-message-late-meeting)))
    (let ((teams4e--active-view 'inbox)
          (teams4e--active-query nil))
      (should (equal '("new-message" "old-message")
                     (mapcar #'teams4e--chat-id
                             (teams4e--order-visible-chats rows)))))
    (dolist (query '(upcoming "type:meeting" "type:meeting unread"))
      (let ((teams4e--active-view 'inbox)
            (teams4e--active-query query))
        (should (teams4e--meeting-view-p))
        (should (equal '("old-message" "new-message")
                       (mapcar #'teams4e--chat-id
                               (teams4e--order-visible-chats rows))))))
    (let ((teams4e--active-view 'inbox)
          (teams4e--active-query "type:meeting | type:group"))
      (should-not (teams4e--meeting-view-p)))))

(ert-deftest teams4e-meeting-row-label-always-shows-the-time-interval ()
  (let* ((same-day
          '((id . "same-day") (chatType . "meeting")
            (meetingContext
             . ((event
                 . ((start . ((dateTime . "2099-08-10T07:30:00")
                              (timeZone . "UTC")))
                    (end . ((dateTime . "2099-08-10T08:15:00")
                            (timeZone . "UTC")))))))))
         (cross-day
          '((id . "cross-day") (chatType . "meeting")
            (meetingContext
             . ((event
                 . ((start . ((dateTime . "2099-08-10T12:00:00")
                              (timeZone . "UTC")))
                    (end . ((dateTime . "2099-08-11T12:30:00")
                            (timeZone . "UTC")))))))))
         (same-label (teams4e--meeting-row-label same-day))
         (cross-label (teams4e--meeting-row-label cross-day)))
    (should (string-match-p
             "[0-9][0-9]:[0-9][0-9]-[0-9][0-9]:[0-9][0-9]"
             same-label))
    (should (string-match-p "Aug 10.* - .*Aug 11" cross-label))))

(ert-deftest teams4e-meeting-proposal-ranks-sends-and-renders-in-one-flow ()
  (let* ((event
          '((id . "event-1")
            (start . ((dateTime . "2099-08-10T07:30:00")
                      (timeZone . "UTC")))
            (end . ((dateTime . "2099-08-10T08:15:00")
                    (timeZone . "UTC")))
            (allowNewTimeProposals . t)
            (isOrganizer)
            (organizer
             . ((emailAddress
                 . ((name . "Grace Hopper")
                    (address . "grace@example.test")))))))
         (chat
          `((id . "meeting-1")
            (chatType . "meeting")
            (topic . "Architecture review")
            (onlineMeetingInfo . ((calendarEventId . "event-1")))
            (meetingContext . ((event . ,event)))))
         (slot
          '((start . ((dateTime . "2099-08-11T09:00:00")
                      (timeZone . "UTC")))
            (end . ((dateTime . "2099-08-11T09:45:00")
                    (timeZone . "UTC")))))
         (suggestion
          `((confidence . 100)
            (organizerAvailability . "free")
            (attendeeAvailability
             . (((availability . "free")
                 (attendee
                  . ((emailAddress
                      . ((name . "Grace Hopper")
                         (address . "grace@example.test"))))))))
            (meetingTimeSlot . ,slot)))
         (sent-event
          (append '((responseStatus . ((response . "tentativelyAccepted"))))
                  event))
         requests completion-choices)
    (with-temp-buffer
      (teams4e-recent-mode)
      (cl-letf
          (((symbol-function 'teams4e--run-json)
            (lambda (args callback &optional _error-callback)
              (push args requests)
              (if (member "suggest" args)
                  (funcall callback
                           `((event . ,event)
                             (suggestions . (,suggestion))))
                (funcall callback
                         `((status . "proposed")
                           (event . ,sent-event)
                           (proposal . ,slot))))
              'fake-request))
           ((symbol-function 'completing-read)
            (lambda (_prompt collection &rest _args)
              (setq completion-choices collection)
              (car collection)))
           ((symbol-function 'read-string)
            (lambda (&rest _args) "Please move this meeting"))
           ((symbol-function 'teams4e--refresh-visible-recent) #'ignore))
        (teams4e--proposal-request-suggestions
         chat "event-1"
         (list (date-to-time "2099-08-09T00:00:00Z")
               (date-to-time "2099-08-17T00:00:00Z"))
         'work)))
    (setq requests (nreverse requests))
    (should (= 2 (length requests)))
    (should (equal '("teams" "meeting" "propose" "suggest")
                   (seq-take (car requests) 4)))
    (should (equal '("teams" "meeting" "propose" "send")
                   (seq-take (cadr requests) 4)))
    (should (equal "Please move this meeting"
                   (cadr (member "--comment" (cadr requests)))))
    (should (string-match-p "100% confidence"
                            (car completion-choices)))
    (should (string-match-p "all shown free"
                            (car completion-choices)))
    (should (member teams4e--proposal-manual-choice completion-choices))
    (should (equal "New time proposed"
                   (teams4e--meeting-status-label chat)))
    (with-temp-buffer
      (teams4e-chat-mode)
      (setq teams4e--chat chat
            teams4e--messages nil)
      (teams4e--render-chat)
      (should (string-match-p "Proposed: .*Aug 11" (buffer-string)))
      (should (string-match-p "Status: New time proposed"
                              (buffer-string))))))

(ert-deftest teams4e-meeting-proposal-manual-fallback-preserves-exact-duration ()
  (require 'org)
  (let* ((event
          '((id . "event-1")
            (start . ((dateTime . "2099-08-10T07:30:15")
                      (timeZone . "UTC")))
            (end . ((dateTime . "2099-08-10T08:15:45")
                    (timeZone . "UTC")))))
         (chat
          `((id . "meeting-1")
            (chatType . "meeting")
            (meetingContext . ((event . ,event)))))
         (manual-start (date-to-time "2099-08-12T12:00:00Z"))
         choices sent-slot)
    (cl-letf
        (((symbol-function 'completing-read)
          (lambda (_prompt collection &rest _args)
            (setq choices collection)
            (car collection)))
         ((symbol-function 'org-read-date)
          (lambda (&rest _args) manual-start))
         ((symbol-function 'teams4e--proposal-send)
          (lambda (_chat _event-id slot) (setq sent-slot slot))))
      (teams4e--proposal-choose
       chat "event-1"
       `((event . ,event)
         (suggestions)
         (suggestionError . "Microsoft Graph HTTP 403: denied"))
       (list manual-start (time-add manual-start (days-to-time 7)))
       'work))
    (should (equal teams4e--proposal-manual-choice (car choices)))
    (should-not (member teams4e--proposal-unrestricted-choice choices))
    (should (equal "2099-08-12T12:00:00"
                   (teams4e--dig sent-slot 'start 'dateTime)))
    (should (equal "2099-08-12T12:45:30"
                   (teams4e--dig sent-slot 'end 'dateTime)))))

(ert-deftest teams4e-meeting-workspace-renders-suggestions-and-private-blocks ()
  (let* ((context (teams4e-test-availability-context))
         (chat (teams4e--get context 'chat))
         (payload (teams4e--get context 'payload)))
    (with-temp-buffer
      (teams4e-availability-mode)
      (setq teams4e-availability--chat chat
            teams4e-availability--event-id "event-availability"
            teams4e-availability--payload payload
            teams4e-availability--window
            (list (date-to-time "2099-08-11T00:00:00Z")
                  (date-to-time "2099-08-12T00:00:00Z")))
      (teams4e-availability--render)
      (should (= 2 (length teams4e-availability--row-ids)))
      (should (string-match-p "Architecture review" (buffer-string)))
      (should (string-match-p "100% confidence" (buffer-string)))
      (should (string-match-p "Everyone is available" (buffer-string)))
      (should (string-match-p "Ada Lovelace" (buffer-string)))
      (teams4e-availability-next)
      (should (string-match-p "Ada Lovelace - Busy" (buffer-string)))
      (should (string-match-p "Customer review" (buffer-string)))
      (teams4e-availability-show-blocks)
      (should (string-match-p "Working hours:" (buffer-string)))
      (should (string-match-p "Private block" (buffer-string)))
      (should (string-match-p "Customer review" (buffer-string)))
      (should-not (string-match-p "Board reshuffle" (buffer-string)))
      (should-not (string-match-p "Secret room" (buffer-string)))
      (should (eq (lookup-key teams4e-availability-mode-map (kbd "v"))
                  #'teams4e-meeting-respond))
      (should (eq (lookup-key teams4e-availability-mode-map (kbd "J"))
                  #'teams4e-meeting-join)))))

(ert-deftest teams4e-meeting-conflicts-use-exact-active-event-overlap ()
  (cl-labels
      ((meeting
        (chat-id event-id start end &optional response cancelled)
        `((id . ,chat-id)
          (chatType . "meeting")
          (topic . ,chat-id)
          (meetingContext
           . ((event
               . ((id . ,event-id)
                  (start . ((dateTime . ,start) (timeZone . "UTC")))
                  (end . ((dateTime . ,end) (timeZone . "UTC")))
                  (isCancelled . ,cancelled)
                  (responseRequested . t)
                  (responseStatus
                   . ((response . ,(or response "accepted")))))))))))
    (let* ((current (meeting "current" "event-current"
                             "2099-08-11T10:00:00"
                             "2099-08-11T11:00:00" "notResponded"))
           (overlap (meeting "overlap" "event-overlap"
                             "2099-08-11T10:30:00"
                             "2099-08-11T11:30:00"))
           (boundary (meeting "boundary" "event-boundary"
                              "2099-08-11T11:00:00"
                              "2099-08-11T12:00:00"))
           (cancelled (meeting "cancelled" "event-cancelled"
                               "2099-08-11T10:15:00"
                               "2099-08-11T10:45:00" "accepted" t))
           (declined (meeting "declined" "event-declined"
                              "2099-08-11T10:15:00"
                              "2099-08-11T10:45:00" "declined"))
           (duplicate (meeting "duplicate" "event-current"
                               "2099-08-11T10:00:00"
                               "2099-08-11T11:00:00"))
           (teams4e--chats
            (list current overlap boundary cancelled declined duplicate)))
      (should (equal '("overlap")
                     (mapcar #'teams4e--chat-id
                             (teams4e--meeting-conflicts current))))
      (let ((label (teams4e--meeting-row-label current)))
        (should (string-match-p "Conflict" label))
        (should (string-match-p "Needs response" label))))))

(ert-deftest teams4e-meeting-response-sends-once-and-refreshes-canonical-event ()
  (let* ((context (teams4e-test-availability-context))
         (chat (teams4e--get context 'chat))
         (event (copy-tree (teams4e--get (teams4e--get context 'payload)
                                         'event)))
         request)
    (setf (alist-get 'responseStatus event)
          '((response . "accepted") (time . "2099-08-08T08:00:00Z")))
    (cl-letf (((symbol-function 'completing-read)
               (lambda (&rest _args) "Accept"))
              ((symbol-function 'read-string)
               (lambda (&rest _args) "Works for me"))
              ((symbol-function 'teams4e--run-json)
               (lambda (args callback &optional _error-callback)
                 (setq request args)
                 (funcall callback `((event . ,event)))
                 'fake-request))
              ((symbol-function 'teams4e--meeting-refresh-displays) #'ignore))
      (teams4e-meeting-respond chat))
    (should (equal '("teams" "meeting" "respond")
                   (seq-take request 3)))
    (should (equal "accepted" (cadr (member "--response" request))))
    (should (equal "Works for me" (cadr (member "--comment" request))))
    (should (eq 'accepted (teams4e--meeting-response chat)))))

(ert-deftest teams4e-relevant-inbox-excludes-hidden-and-locally-muted-chats ()
  (let* ((visible '((id . "visible") (chatType . "group")))
         (hidden '((id . "hidden")
                   (chatType . "group")
                   (viewpoint . ((isHidden . t)))))
         (local-mute '((id . "local-mute") (chatType . "group")))
         (teams4e--muted (make-hash-table :test #'equal))
         (teams4e--state-loaded t))
    (puthash "local-mute" t teams4e--muted)
    (should (teams4e--built-in-view-chat-p visible 'inbox))
    (should-not (teams4e--built-in-view-chat-p hidden 'inbox))
    (should-not (teams4e--built-in-view-chat-p local-mute 'inbox))
    (should (teams4e--built-in-view-chat-p hidden 'all))
    (should (teams4e--built-in-view-chat-p local-mute 'muted))
    (should (teams4e--query-chat-p hidden "muted"))
    (should (teams4e--query-chat-p visible "-muted"))
    (should (eq 'inbox
                (plist-get
                 (seq-find (lambda (bookmark)
                             (eq (plist-get bookmark :key) ?i))
                           teams4e-bookmarks)
                 :query)))
    (should (eq 'all
                (plist-get
                 (seq-find (lambda (bookmark)
                             (eq (plist-get bookmark :key) ?a))
                           teams4e-bookmarks)
                 :query)))))

(ert-deftest teams4e-inbox-and-all-bookmarks-switch-the-visible-row-set ()
  (let* ((visible '((id . "visible") (chatType . "group")))
         (hidden '((id . "hidden")
                   (chatType . "group")
                   (viewpoint . ((isHidden . t)))))
         (local-mute '((id . "local-mute") (chatType . "group")))
         (teams4e--chats (list visible hidden local-mute))
         (teams4e--muted (make-hash-table :test #'equal))
         (teams4e--favorites (make-hash-table :test #'equal))
         (teams4e--marks (make-hash-table :test #'equal))
         (teams4e--selections (make-hash-table :test #'equal))
         (teams4e--read-overrides (make-hash-table :test #'equal))
         (teams4e--state-loaded t)
         (teams4e--active-view 'all)
         (teams4e--active-query nil)
         (teams4e--active-filter-name nil))
    (puthash "local-mute" t teams4e--muted)
    (with-temp-buffer
      (teams4e-recent-mode)
      (cl-letf (((symbol-function 'read-char) (lambda (&rest _args) ?i)))
        (teams4e-bookmark-jump))
      (should (eq 'inbox teams4e--active-query))
      (should (= 1 (length tabulated-list-entries)))
      (setq teams4e--unread-filter-enabled t)
      (cl-letf (((symbol-function 'read-char) (lambda (&rest _args) ?a)))
        (teams4e-bookmark-jump))
      (should (eq 'all teams4e--active-query))
      (should-not teams4e--unread-filter-enabled)
      (should (= 3 (length tabulated-list-entries))))))

(ert-deftest teams4e-unread-filter-composes-with-active-query ()
  (let* ((chats (teams4e-test-read-json "chats.json"))
         (direct (car chats))
         (group (cadr chats))
         (teams4e--active-view 'all)
         (teams4e--active-query "type:group")
         (teams4e--active-filter-name "Groups")
         (teams4e--unread-filter-enabled nil)
         (teams4e--read-overrides (make-hash-table :test #'equal)))
    (should-not (teams4e--view-chat-p direct))
    (should (teams4e--view-chat-p group))
    (setq teams4e--unread-filter-enabled t)
    (should-not (teams4e--view-chat-p direct))
    (should-not (teams4e--view-chat-p group))
    (should (equal "Groups + unread only"
                   (teams4e--active-filter-label)))
    (should (equal "type:group" teams4e--active-query))))

(ert-deftest teams4e-unread-overlay-keeps-meeting-view-boundary ()
  (let* ((direct '((id . "direct-unread")
                   (chatType . "oneOnOne")
                   (lastMessagePreview
                    . ((id . "direct-message")
                       (createdDateTime . "2099-08-10T08:00:00Z")))))
         (meeting '((id . "meeting-unread")
                    (chatType . "meeting")
                    (lastMessagePreview
                     . ((id . "meeting-message")
                        (createdDateTime . "2099-08-10T09:00:00Z")))))
         (teams4e--active-view 'all)
         (teams4e--active-query "type:meeting")
         (teams4e--active-filter-name "Meetings")
         (teams4e--unread-filter-enabled t)
         (teams4e--read-overrides (make-hash-table :test #'equal)))
    (should-not (teams4e--view-chat-p direct))
    (should (teams4e--view-chat-p meeting))
    (should (equal "type:meeting" teams4e--active-query))))

(ert-deftest teams4e-unread-toggle-recovers-legacy-destructive-query ()
  (let ((teams4e--active-view 'meeting)
        (teams4e--active-query "unread")
        (teams4e--active-filter-name "Unread")
        (teams4e--unread-filter-enabled t))
    (cl-letf (((symbol-function 'teams4e--set-unread-filter)
               (lambda (enabled)
                 (setq teams4e--unread-filter-enabled enabled))))
      (teams4e-toggle-unread-filter))
    (should (eq teams4e--active-view 'meeting))
    (should-not teams4e--active-query)
    (should-not teams4e--active-filter-name)
    (should-not teams4e--unread-filter-enabled)))

(ert-deftest teams4e-inbox-bookmark-query-combines-terms-and-negation ()
  (let* ((chats (teams4e-test-read-json "chats.json"))
         (direct (car chats))
         (group (cadr chats))
         (teams4e--read-overrides (make-hash-table :test #'equal))
         (teams4e--favorites (make-hash-table :test #'equal))
         (teams4e--state-loaded t))
    (should (teams4e--query-chat-p direct "unread type:direct"))
    (should (teams4e--query-chat-p group
                                          "name:\"Project Atlas\" -unread"))
    (should-not (teams4e--query-chat-p group "type:direct"))
    (puthash "chat-1" t teams4e--favorites)
    (should (teams4e--query-chat-p direct "favorite"))
    (should-not (teams4e--query-chat-p direct "-favorite"))))

(ert-deftest teams4e-all-view-symbol-wins-over-compat-function ()
  (let ((chat '((id . "chat-1") (chatType . "group"))))
    (cl-letf (((symbol-function 'all)
               (lambda (_predicate _list)
                 (ert-fail "compat all function must not handle a view"))))
      (should (teams4e--query-chat-p chat 'all)))))

(ert-deftest teams4e-custom-symbol-function-remains-a-bookmark-predicate ()
  (let ((chat '((id . "chat-1") (chatType . "group"))))
    (cl-letf (((symbol-function 'teams4e-test-bookmark-predicate)
               (lambda (candidate)
                 (equal (teams4e--chat-id candidate) "chat-1"))))
      (should
       (teams4e--query-chat-p chat 'teams4e-test-bookmark-predicate)))))

(ert-deftest teams4e-bookmark-shortcut-filters-the-headers-buffer ()
  (let ((teams4e-bookmarks
         '((:name "Unread" :query "unread" :key ?u)))
        (teams4e--chats (teams4e-test-read-json "chats.json"))
        (teams4e--active-view 'all)
        (teams4e--active-query "type:direct")
        (teams4e--active-filter-name "Direct")
        (teams4e--unread-filter-enabled nil)
        (teams4e--marks (make-hash-table :test #'equal))
        (teams4e--read-overrides (make-hash-table :test #'equal))
        (teams4e--favorites (make-hash-table :test #'equal))
        (teams4e--state-loaded t))
    (with-temp-buffer
      (teams4e-recent-mode)
      (cl-letf (((symbol-function 'read-char) (lambda (&rest _args) ?u)))
        (teams4e-bookmark-jump))
      (should teams4e--unread-filter-enabled)
      (should (equal "type:direct" teams4e--active-query))
      (should (equal "Direct" teams4e--active-filter-name))
      (should (= 1 (length tabulated-list-entries)))
      (cl-letf (((symbol-function 'read-char) (lambda (&rest _args) ?u)))
        (teams4e-bookmark-jump))
      (should-not teams4e--unread-filter-enabled)
      (should (equal "type:direct" teams4e--active-query))
      (should (equal "Direct" teams4e--active-filter-name)))))

(ert-deftest teams4e-headers-map-combines-mu4e-and-tui-actions ()
  (dolist (binding
           '(("n" . teams4e-recent-next)
             ("p" . teams4e-recent-previous)
             ("]" . teams4e-recent-next-unread)
             ("[" . teams4e-recent-previous-unread)
             ("!" . teams4e-mark-read-later)
             ("i" . teams4e-mark-read-later)
             ("I" . teams4e-mark-read-later)
             ("?" . teams4e-mark-unread-later)
             ("u" . teams4e-unmark)
             ("U" . teams4e-toggle-unread-filter)
             ("M" . teams4e-toggle-selection)
             ("T" . teams4e-toggle-visible-selections)
             ("X" . teams4e-bulk-action)
             ("b" . teams4e-bookmark-jump)
             ("B" . teams4e-bookmark-edit)
             ("c" . teams4e-send)
             ("C" . teams4e-send)
             ("r" . teams4e-mark-read-later)
             ("R" . teams4e-reply)
             ("f" . teams4e-message-forward)
             ("F" . teams4e-message-forward)
             ("*" . teams4e-toggle-favorite)
             ("o" . teams4e-open-in-browser)
             ("O" . teams4e-open-in-app)
             ("E" . teams4e-export-thread)
             ("Y" . teams4e-copy-thread-markdown)
             ("S" . teams4e-sort)
             ("q" . teams4e-quit)
             ("H" . teams4e-dispatch)))
    (should (eq (lookup-key teams4e-recent-mode-map
                            (kbd (car binding)))
                (cdr binding))))
  (should (keymapp (lookup-key teams4e-recent-mode-map (kbd "a"))))
  (should (eq (lookup-key teams4e-recent-mode-map (kbd "m U"))
              #'teams4e-unmark-all))
  (dolist (binding
           '(("a a" . teams4e-capture-current-summary)
             ("a A" . teams4e-capture-current-thread)
             ("a j" . teams4e-jump-to-capture)
             ("a t" . teams4e-meeting-transcript)
             ("a p" . teams4e-meeting-availability)
             ("a v" . teams4e-meeting-respond)
             ("a J" . teams4e-meeting-join)
             ("a C" . teams4e-meeting-open-calendar)
             ("a R" . teams4e-action-reply)
             ("a i" . teams4e-mark-read)
             ("a u" . teams4e-mark-unread)
             ("a *" . teams4e-toggle-favorite)
             ("a m" . teams4e-toggle-muted)
             ("a s" . teams4e-snooze)
             ("a k" . teams4e-clear-triage)
             ("a e" . teams4e-export-current-thread)
             ("a y" . teams4e-copy-current-thread-markdown)
             ("a g" . teams4e-analyze-current-thread)))
    (should (eq (lookup-key teams4e-recent-mode-map
                            (kbd (car binding)))
                (cdr binding))))
  (should-not (lookup-key teams4e-recent-mode-map (kbd "a h")))
  (should-not (lookup-key teams4e-recent-mode-map (kbd "w"))))

(ert-deftest teams4e-refile-mark-uses-existing-handled-state-and-is-undoable ()
  (let* ((directory (make-temp-file "teams4e-refile-" t))
         (teams4e-state-file (expand-file-name "teams-state.json" directory))
         (chat '((id . "chat-refile")
                 (lastMessagePreview . ((id . "message-1")))))
         (teams4e--chats (list chat))
         (teams4e--marks (make-hash-table :test #'equal))
         (teams4e--favorites (make-hash-table :test #'equal))
         (teams4e--muted (make-hash-table :test #'equal))
         (teams4e--handled (make-hash-table :test #'equal))
         (teams4e--snoozed (make-hash-table :test #'equal))
         (teams4e--saved-views (make-hash-table :test #'equal))
         (teams4e--state-loaded t)
         (teams4e--action-history nil))
    (unwind-protect
        (progn
          (puthash "chat-refile" 'refile teams4e--marks)
          (cl-letf (((symbol-function 'teams4e--refresh-visible-recent)
                     #'ignore))
            (teams4e--execute-mark-list
             '(("chat-refile" . refile)) nil)
            (should (teams4e--handled-p chat))
            (should-not (gethash "chat-refile" teams4e--marks))
            (should (eq 'triage
                        (plist-get (car teams4e--action-history) :kind)))
            (teams4e-undo-action)
            (should-not (teams4e--handled-p chat))))
      (delete-directory directory t))))

(ert-deftest teams4e-headers-reply-uses-selected-latest-message ()
  (let* ((chat (car (teams4e-test-read-json "chats.json")))
         (teams4e--chats (list chat))
         (teams4e--active-view 'all)
         (teams4e--active-query nil)
         (teams4e--active-filter-name nil)
         (teams4e--marks (make-hash-table :test #'equal))
         (teams4e--read-overrides (make-hash-table :test #'equal))
         (teams4e--favorites (make-hash-table :test #'equal))
         (teams4e--state-loaded t)
         captured)
    (with-temp-buffer
      (teams4e-recent-mode)
      (teams4e--render-recent)
      (goto-char (point-min))
      (cl-letf (((symbol-function 'teams4e--open-compose)
                 (lambda (target &optional reply-to _initial)
                   (setq captured (list target reply-to)))))
        (teams4e-reply))
      (should (equal chat (car captured)))
      (should (equal (teams4e--get chat 'lastMessagePreview)
                     (cadr captured))))))

(ert-deftest teams4e-headers-forward-uses-selected-latest-message ()
  (let* ((chat (car (teams4e-test-read-json "chats.json")))
         (teams4e--chats (list chat))
         (teams4e--active-view 'all)
         (teams4e--active-query nil)
         (teams4e--active-filter-name nil)
         (teams4e--marks (make-hash-table :test #'equal))
         (teams4e--read-overrides (make-hash-table :test #'equal))
         (teams4e--favorites (make-hash-table :test #'equal))
         (teams4e--state-loaded t)
         callback captured)
    (with-temp-buffer
      (teams4e-recent-mode)
      (teams4e--render-recent)
      (goto-char (point-min))
      (cl-letf (((symbol-function 'teams4e--select-chat)
                 (lambda (fn) (setq callback fn))))
        (teams4e-message-forward))
      (should (functionp callback))
      (cl-letf (((symbol-function 'teams4e--open-compose)
                 (lambda (target &optional reply-to initial)
                   (setq captured (list target reply-to initial)))))
        (funcall callback '((id . "destination"))))
      (should (equal "destination"
                     (teams4e--get (car captured) 'id)))
      (should-not (cadr captured))
      (should (string-match-p "Forwarded from" (caddr captured)))
      (should (string-match-p
               (regexp-quote
                (teams4e--message-body
                 (teams4e--get chat 'lastMessagePreview)))
               (caddr captured))))))

(ert-deftest teams4e-chat-selection-supports-one-row-and-visible-set ()
  (let* ((teams4e--chats (teams4e-test-read-json "chats.json"))
         (teams4e--active-view 'all)
         (teams4e--active-query nil)
         (teams4e--active-filter-name nil)
         (teams4e--unread-filter-enabled nil)
         (teams4e--selections (make-hash-table :test #'equal))
         (teams4e--marks (make-hash-table :test #'equal))
         (teams4e--favorites (make-hash-table :test #'equal))
         (teams4e--read-overrides (make-hash-table :test #'equal))
         (teams4e--state-loaded t)
         (teams4e-preview-on-move nil))
    (with-temp-buffer
      (teams4e-recent-mode)
      (teams4e--render-recent)
      (let ((first-id (tabulated-list-get-id)))
        (teams4e-toggle-selection)
        (should (gethash first-id teams4e--selections))
        (should (equal "+"
                       (substring-no-properties
                        (aref (cadr (assoc first-id tabulated-list-entries))
                              0)))))
      (teams4e-toggle-visible-selections)
      (should (= (length teams4e--chats)
                 (hash-table-count teams4e--selections)))
      (should (string-match-p "2 selected" header-line-format))
      (teams4e-toggle-visible-selections)
      (should (= 0 (hash-table-count teams4e--selections))))))

(ert-deftest teams4e-bulk-action-queues-only-selected-chats ()
  (let* ((teams4e--chats (teams4e-test-read-json "chats.json"))
         (teams4e--selections (make-hash-table :test #'equal))
         (teams4e--marks (make-hash-table :test #'equal))
         (teams4e-confirm-apply nil)
         (teams4e-offline-mode nil)
         executed)
    (dolist (chat teams4e--chats)
      (puthash (teams4e--chat-id chat) t
               teams4e--selections))
    (with-temp-buffer
      (teams4e-recent-mode)
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (&rest _args) "Mark unread"))
                ((symbol-function 'yes-or-no-p)
                 (lambda (&rest _args)
                   (ert-fail "Bulk apply unexpectedly requested confirmation")))
                ((symbol-function 'teams4e--render-recent) #'ignore)
                ((symbol-function 'teams4e--execute-mark-list)
                 (lambda (items completed)
                   (setq executed (list items completed)))))
        (teams4e-bulk-action)))
    (should (= 0 (hash-table-count teams4e--selections)))
    (should (= 2 (hash-table-count teams4e--marks)))
    (should (seq-every-p (lambda (item) (eq (cdr item) 'unread))
                         (car executed)))
    (should-not (cadr executed))))

(ert-deftest teams4e-execute-marks-skips-confirmation-by-default ()
  (let ((teams4e--marks (make-hash-table :test #'equal))
        (teams4e-confirm-apply nil)
        (teams4e-offline-mode nil)
        executed)
    (puthash "chat-1" 'favorite-on teams4e--marks)
    (cl-letf (((symbol-function 'yes-or-no-p)
               (lambda (&rest _args)
                 (ert-fail "Deferred apply unexpectedly requested confirmation")))
              ((symbol-function 'teams4e--execute-mark-list)
               (lambda (items completed)
                 (setq executed (list items completed)))))
      (teams4e-execute-marks))
    (should (equal '(("chat-1" . favorite-on)) (car executed)))
    (should-not (cadr executed))))

(ert-deftest teams4e-execute-marks-honors-opt-in-confirmation ()
  (let ((teams4e--marks (make-hash-table :test #'equal))
        (teams4e-confirm-apply t)
        (teams4e-offline-mode nil)
        prompted
        executed)
    (puthash "chat-1" 'read teams4e--marks)
    (cl-letf (((symbol-function 'yes-or-no-p)
               (lambda (&rest _args)
                 (setq prompted t)
                 nil))
              ((symbol-function 'teams4e--execute-mark-list)
               (lambda (&rest _args) (setq executed t))))
      (teams4e-execute-marks))
    (should prompted)
    (should-not executed)))

(ert-deftest teams4e-bulk-favorite-actions-have-explicit-target-state ()
  (let* ((chat (car (teams4e-test-read-json "chats.json")))
         (chat-id (teams4e--chat-id chat))
         (teams4e--chats (list chat))
         (teams4e--marks (make-hash-table :test #'equal))
         (teams4e--favorites (make-hash-table :test #'equal))
         (teams4e--action-history nil))
    (cl-letf (((symbol-function 'teams4e--save-state) #'ignore)
              ((symbol-function 'teams4e--refresh-visible-recent)
               #'ignore))
      (puthash chat-id 'favorite-on teams4e--marks)
      (teams4e--execute-mark-list
       (list (cons chat-id 'favorite-on)) nil)
      (should (gethash chat-id teams4e--favorites))
      (should-not (plist-get (car teams4e--action-history) :enabled))
      (setq teams4e--action-history nil)
      (puthash chat-id 'favorite-off teams4e--marks)
      (teams4e--execute-mark-list
       (list (cons chat-id 'favorite-off)) nil)
      (should-not (gethash chat-id teams4e--favorites))
      (should (plist-get (car teams4e--action-history) :enabled)))))

(ert-deftest teams4e-transcript-maps-use-shared-actions-and-local-navigation ()
  (dolist (map-and-bindings
           `((,teams4e-chat-mode-map
              ("j" . teams4e-thread-next)
              ("k" . teams4e-thread-previous)
              ("M-j" . teams4e-chat-next-message)
              ("M-k" . teams4e-chat-previous-message)
              ("R" . teams4e-reply)
              ("F" . teams4e-message-forward)
              ("c" . teams4e-send)
              ("C" . teams4e-send)
              ("i" . teams4e-chat-run-headers-command)
              ("I" . teams4e-chat-run-headers-command)
              ("n" . teams4e-chat-run-headers-command)
              ("p" . teams4e-chat-run-headers-command)
              ("]" . teams4e-chat-run-headers-command)
              ("[" . teams4e-chat-run-headers-command)
              ("!" . teams4e-chat-run-headers-command)
              ("?" . teams4e-chat-run-headers-command)
              ("r" . teams4e-chat-run-headers-command)
              ("f" . teams4e-chat-run-headers-command)
              ("M" . teams4e-chat-run-headers-command)
              ("T" . teams4e-chat-run-headers-command)
              ("X" . teams4e-chat-run-headers-command)
              ("u" . teams4e-chat-run-headers-command)
              ("U" . teams4e-chat-run-headers-command)
              ("x" . teams4e-chat-run-headers-command)
              ("q" . teams4e-chat-view-quit)
              ("o" . teams4e-open-in-browser)
              ("O" . teams4e-open-in-app)
              ("L" . teams4e-chat-load-more)
              ("S" . teams4e-chat-run-headers-command)
              ("M-S" . teams4e-toggle-message-order)
              ("Y" . teams4e-copy-current-thread-markdown)
              ("M-w" . teams4e-capture-message))
             (,teams4e-channel-index-mode-map
              ("q" . teams4e-quit)
              ("o" . teams4e-open-current-in-browser)
              ("O" . teams4e-open-current-in-app)
              ("E" . teams4e-channel-export-thread)
              ("Y" . teams4e-copy-current-thread-markdown))
             (,teams4e-channel-thread-mode-map
              ("j" . teams4e-channel-thread-next)
              ("k" . teams4e-channel-thread-previous)
              ("M-j" . teams4e-chat-next-message)
              ("M-k" . teams4e-chat-previous-message)
              ("R" . teams4e-channel-reply)
              ("F" . teams4e-message-forward)
              ("M-a" . teams4e-attachment-download)
              ("c" . teams4e-channel-compose)
              ("C" . teams4e-channel-compose)
              ("q" . teams4e-channel-view-quit)
              ("o" . teams4e-open-current-in-browser)
              ("O" . teams4e-open-current-in-app)
              ("S" . teams4e-toggle-message-order)
              ("Y" . teams4e-copy-current-thread-markdown))))
    (let ((map (car map-and-bindings)))
      (dolist (binding (cdr map-and-bindings))
        (should (eq (lookup-key map (kbd (car binding)))
                    (cdr binding))))
      (should (keymapp (lookup-key map (kbd "a"))))
      (should (eq (lookup-key map (kbd "a a"))
                  #'teams4e-capture-current-summary))
      (should (eq (lookup-key map (kbd "a A"))
                  #'teams4e-capture-current-thread))
      (should-not (lookup-key map (kbd "w")))
      (should-not (lookup-key map (kbd "W"))))))

(ert-deftest teams4e-lowercase-r-marks-read-and-never-replies ()
  (should (eq (lookup-key teams4e-recent-mode-map (kbd "r"))
              #'teams4e-mark-read-later))
  (should (eq (lookup-key teams4e-mark-map (kbd "r"))
              #'teams4e-mark-read-later))
  (should (eq (lookup-key teams4e-chat-mode-map (kbd "r"))
              #'teams4e-chat-run-headers-command))
  (should-not (lookup-key teams4e-channel-thread-mode-map (kbd "r")))
  (should-not (lookup-key teams4e-action-map (kbd "r")))
  (should (eq (lookup-key teams4e-action-map (kbd "R"))
              #'teams4e-action-reply)))

(ert-deftest teams4e-chat-reader-mirrors-the-complete-headers-key-set ()
  (dolist (key teams4e--chat-header-mirror-keys)
    (should (eq (lookup-key teams4e-chat-mode-map (kbd key))
                #'teams4e-chat-run-headers-command)))
  (dolist (key '("m i" "m r" "m u" "m *" "m SPC"))
    (should (eq (lookup-key teams4e-chat-mode-map (kbd key))
                #'teams4e-chat-run-headers-command))))

(ert-deftest teams4e-unread-face-is-bold-without-warning-color ()
  (should (eq 'bold
              (face-attribute 'teams4e-unread :weight nil 'default)))
  (should (equal "unspecified-fg"
                 (face-attribute 'teams4e-unread
                                 :foreground nil 'default)))
  (should-not (face-attribute 'teams4e-unread :inherit nil 'default)))

(ert-deftest teams4e-headers-start-with-status-then-aligned-date-type-and-name ()
  (let* ((chat
          '((id . "chat-header")
            (chatType . "meeting")
            (topic . "Architecture review")
            (lastUpdatedDateTime . "2026-08-02T12:30:00Z")
            (meetingContext
             . ((event
                 . ((start . ((dateTime . "2099-08-10T07:30:00")
                              (timeZone . "UTC")))
                    (end . ((dateTime . "2099-08-10T08:15:00")
                            (timeZone . "UTC")))
                    (location . ((displayName . "Video room 4")))))))
            (lastMessagePreview
             . ((id . "meeting-message-1")
                (createdDateTime . "2026-08-01T09:15:00Z")
                (messageType . "systemEventMessage")
                (eventDetail
                 . ((@odata.type
                     . "#microsoft.graph.callStartedEventMessageDetail")
                    (callEventType . "meeting")))))))
         (teams4e--marks (make-hash-table :test #'equal))
         (teams4e--selections (make-hash-table :test #'equal))
         (teams4e--favorites (make-hash-table :test #'equal))
         (teams4e--read-overrides (make-hash-table :test #'equal))
         (teams4e--active-view 'inbox)
         (teams4e--active-query nil)
         (teams4e-status-style 'symbols)
         (teams4e--state-loaded t)
         (columns (cadr (teams4e--recent-entry-advanced chat))))
    (should (equal '("Status" "Message time" "Type" "Conversation"
                     "Star" "Last message")
                   (mapcar #'car
                           (append teams4e--recent-format nil))))
    (should (= 6 (length columns)))
    (should (equal "" (aref columns 0)))
    (should (string-prefix-p "2026-08-01"
                             (substring-no-properties (aref columns 1))))
    (should (equal "Meeting" (substring-no-properties (aref columns 2))))
    (should (equal "Architecture review"
                   (substring-no-properties (aref columns 3))))
    (should (equal "" (aref columns 4)))
    (should-not
     (string-match-p "Video room 4"
                     (mapconcat #'substring-no-properties
                                (append columns nil) " ")))
    (puthash "chat-header" 'refile teams4e--marks)
    (setq columns (cadr (teams4e--recent-entry-advanced chat)))
    (should (equal "↦" (substring-no-properties (aref columns 0))))
    (should-not (string-match-p "!" (mapconcat #'substring-no-properties
                                                (append columns nil) " ")))
    (should (memq 'teams4e-type-meeting
                  (get-text-property 0 'face (aref columns 2))))
    (should (memq 'teams4e-unread
                  (get-text-property 0 'face (aref columns 3))))
    (should (string-match-p "Meeting started"
                            (substring-no-properties (aref columns 5))))
    (with-temp-buffer
      (tabulated-list-mode)
      (setq tabulated-list-format [("Old" 1 nil)])
      (teams4e--configure-recent-format)
      (should (equal teams4e--recent-format
                     tabulated-list-format))
      (let ((teams4e--active-view 'meeting))
        (teams4e--configure-recent-format)
        (should (equal teams4e--meeting-recent-format
                       tabulated-list-format)))
      (teams4e--configure-recent-format)
      (should (equal teams4e--recent-format
                     tabulated-list-format)))
    (let* ((teams4e--active-view 'meeting)
           (meeting-columns (cadr (teams4e--recent-entry-advanced chat))))
      (should (equal '("Status" "When" "Conversation" "Response"
                       "Location" "Star" "Last message")
                     (mapcar #'car
                             (append teams4e--meeting-recent-format nil))))
      (should (= 7 (length meeting-columns)))
      (should (string-match-p
               "[0-9][0-9]:[0-9][0-9]-[0-9][0-9]:[0-9][0-9]"
               (substring-no-properties (aref meeting-columns 1))))
      (should (equal "Architecture review"
                     (substring-no-properties (aref meeting-columns 2))))
      (should (string-match-p "Video room 4"
                              (substring-no-properties
                               (aref meeting-columns 4))))
      (should (equal "" (aref meeting-columns 5)))
      (should (string-match-p "Meeting started"
                              (substring-no-properties
                               (aref meeting-columns 6)))))
    (with-temp-buffer
      (teams4e-recent-mode)
      (should (eq bidi-paragraph-direction 'left-to-right)))))

(ert-deftest teams4e-status-column-has-sober-symbol-and-letter-styles ()
  (should (eq 'symbols (default-value 'teams4e-status-style)))
  (let ((teams4e-status-style 'symbols))
    (should (equal "↦" (substring-no-properties
                         (teams4e--status-token 'refile))))
    (should (equal "≡" (substring-no-properties
                         (teams4e--status-token 'captured))))
    (should (equal "Queued: refile until a new message"
                   (get-text-property
                    0 'help-echo (teams4e--status-token 'refile)))))
  (let ((teams4e-status-style 'letters))
    (should (equal "r" (substring-no-properties
                         (teams4e--status-token 'refile))))
    (should (equal "c" (substring-no-properties
                         (teams4e--status-token 'captured))))))

(ert-deftest teams4e-send-confirmation-is-disabled-by-default ()
  (should-not (default-value 'teams4e-confirm-send)))

(ert-deftest teams4e-apply-confirmation-is-disabled-by-default ()
  (should-not (default-value 'teams4e-confirm-apply)))

(ert-deftest teams4e-inbox-preview-on-move-is-disabled-by-default ()
  (should-not (default-value 'teams4e-preview-on-move)))

(ert-deftest teams4e-inbox-preview-scheduling-is-explicitly-opt-in ()
  (let ((teams4e-preview-on-move nil)
        (teams4e-preview-delay 0.25)
        scheduled)
    (with-temp-buffer
      (insert (propertize "row" 'tabulated-list-id "chat-preview"))
      (goto-char (point-min))
      (setq-local teams4e--preview-timer nil)
      (cl-letf (((symbol-function 'run-with-idle-timer)
                 (lambda (&rest _args)
                   (setq scheduled t)
                   'fake-preview-timer)))
        (teams4e--schedule-preview)
        (should-not scheduled)
        (setq teams4e-preview-on-move t)
        (teams4e--schedule-preview)
        (should scheduled)))))

(ert-deftest teams4e-quit-never-deletes-a-spaceclient-frame ()
  (let ((teams4e--window-configurations
         (make-hash-table :test #'eq))
        deleted buried)
    (cl-letf (((symbol-function 'selected-frame) (lambda () 'teams-frame))
              ((symbol-function 'selected-window) (lambda () 'teams-window))
              ((symbol-function 'window-parent) (lambda (_window) nil))
              ((symbol-function 'teams4e--cancel-frame-preview-timers)
               #'ignore)
              ((symbol-function 'delete-frame)
               (lambda (frame) (setq deleted frame)))
              ((symbol-function 'bury-buffer)
               (lambda (&rest _args) (setq buried t))))
      (teams4e-quit))
    (should-not deleted)
    (should buried)))

(ert-deftest teams4e-reader-quit-closes-only-the-message-pane ()
  (let ((index (get-buffer-create teams4e--recent-buffer-name))
        (reader (get-buffer-create teams4e--read-buffer-name))
        deleted-frame)
    (unwind-protect
        (save-window-excursion
          (delete-other-windows)
          (switch-to-buffer index)
          (teams4e-recent-mode)
          (select-window (split-window-right))
          (switch-to-buffer reader)
          (teams4e-chat-mode)
          (cl-letf (((symbol-function 'delete-frame)
                     (lambda (&rest _args) (setq deleted-frame t))))
            (teams4e-chat-view-quit))
          (should-not deleted-frame)
          (should-not (buffer-live-p reader))
          (should (eq (current-buffer) index))
          (should (one-window-p t)))
      (when (buffer-live-p index) (kill-buffer index))
      (when (buffer-live-p reader) (kill-buffer reader)))))

(ert-deftest teams4e-tabulated-neighbor-navigation-follows-visible-rows ()
  (with-temp-buffer
    (tabulated-list-mode)
    (setq tabulated-list-format [("Chat" 20 nil)]
          tabulated-list-entries '(("chat-1" ["First"])
                                   ("chat-2" ["Second"])))
    (tabulated-list-init-header)
    (tabulated-list-print)
    (should (equal "chat-2"
                   (teams4e--tabulated-neighbor-id "chat-1" 1)))
    (should (equal "chat-1"
                   (teams4e--tabulated-neighbor-id "chat-2" -1)))))

(ert-deftest teams4e-reader-runs-commands-in-linked-headers-context ()
  (let* ((first '((id . "chat-reader-1") (topic . "First")))
         (second '((id . "chat-reader-2") (topic . "Second")))
         (teams4e--chats (list first second))
         (index (get-buffer-create teams4e--recent-buffer-name))
         (reader (get-buffer-create teams4e--read-buffer-name))
         opened selected-window-after)
    (unwind-protect
        (save-window-excursion
          (delete-other-windows)
          (switch-to-buffer index)
          (teams4e-recent-mode)
          (setq tabulated-list-entries
                (mapcar #'teams4e--recent-entry
                        teams4e--chats))
          (tabulated-list-print)
          (teams4e--recent-goto-chat-id "chat-reader-1")
          (let ((reader-window (split-window-right)))
            (select-window reader-window)
            (switch-to-buffer reader)
            (teams4e-chat-mode)
            (setq teams4e--chat first)
            (cl-letf (((symbol-function 'teams4e-open-chat)
                       (lambda (chat &rest _args) (setq opened chat))))
              (teams4e-chat-run-headers-command
               #'teams4e-recent-next))
            (setq selected-window-after (selected-window))
            (should (eq selected-window-after reader-window))))
          (with-current-buffer index
            (should (equal "chat-reader-2" (tabulated-list-get-id))))
          (should (equal "chat-reader-2"
                         (teams4e--chat-id opened))))
      (when (buffer-live-p index) (kill-buffer index))
      (when (buffer-live-p reader) (kill-buffer reader))))

(ert-deftest teams4e-visible-reader-follows-headers-movement ()
  (let* ((first '((id . "chat-follow-1") (topic . "First")))
         (second '((id . "chat-follow-2") (topic . "Second")))
         (teams4e--chats (list first second))
         (teams4e-preview-on-move nil)
         (index (get-buffer-create teams4e--recent-buffer-name))
         (reader (get-buffer-create teams4e--read-buffer-name))
         opened open-args)
    (unwind-protect
        (save-window-excursion
          (delete-other-windows)
          (switch-to-buffer index)
          (teams4e-recent-mode)
          (setq tabulated-list-entries
                (mapcar #'teams4e--recent-entry
                        teams4e--chats))
          (tabulated-list-print)
          (teams4e--recent-goto-chat-id "chat-follow-1")
          (let ((index-window (selected-window))
                (reader-window (split-window-right)))
            (with-selected-window reader-window
              (switch-to-buffer reader)
              (teams4e-chat-mode)
              (setq teams4e--chat first))
            (cl-letf (((symbol-function 'teams4e-open-chat)
                       (lambda (chat &rest args)
                         (setq opened chat
                               open-args args)
                         (with-current-buffer reader
                           (setq teams4e--chat chat)))))
              (teams4e-recent-next))
            (should (eq index-window (selected-window)))
            (should (equal "chat-follow-2" (tabulated-list-get-id)))
            (should (equal "chat-follow-2"
                           (teams4e--chat-id opened)))
            (should (equal '(t) open-args))))
      (when (buffer-live-p index) (kill-buffer index))
      (when (buffer-live-p reader) (kill-buffer reader)))))

(ert-deftest teams4e-reader-navigation-moves-visible-headers-selection ()
  (let* ((first '((id . "chat-reader-follow-1") (topic . "First")))
         (second '((id . "chat-reader-follow-2") (topic . "Second")))
         (teams4e--chats (list first second))
         (index (get-buffer-create teams4e--recent-buffer-name))
         (reader (get-buffer-create teams4e--read-buffer-name))
         opened)
    (unwind-protect
        (save-window-excursion
          (delete-other-windows)
          (switch-to-buffer index)
          (teams4e-recent-mode)
          (setq tabulated-list-entries
                (mapcar #'teams4e--recent-entry
                        teams4e--chats))
          (tabulated-list-print)
          (teams4e--recent-goto-chat-id "chat-reader-follow-1")
          (let ((index-window (selected-window))
                (reader-window (split-window-right)))
            (select-window reader-window)
            (switch-to-buffer reader)
            (teams4e-chat-mode)
            (setq teams4e--chat first)
            (cl-letf (((symbol-function 'teams4e-open-chat)
                       (lambda (chat &rest _args)
                         (setq opened chat)
                         (setq teams4e--chat chat))))
              (teams4e-thread-next))
            (should (eq reader-window (selected-window)))
            (with-selected-window index-window
              (should (equal "chat-reader-follow-2"
                             (tabulated-list-get-id))))
            (should (equal "chat-reader-follow-2"
                           (teams4e--chat-id opened)))))
      (when (buffer-live-p index) (kill-buffer index))
      (when (buffer-live-p reader) (kill-buffer reader)))))

(ert-deftest teams4e-filter-rerender-replaces-mismatched-visible-reader ()
  (let* ((first '((id . "chat-filter-follow-1") (topic . "First")))
         (second '((id . "chat-filter-follow-2") (topic . "Second")))
         (teams4e--chats (list first second))
         (teams4e--active-view 'all)
         (teams4e--active-query nil)
         (index (get-buffer-create teams4e--recent-buffer-name))
         (reader (get-buffer-create teams4e--read-buffer-name))
         opened)
    (unwind-protect
        (save-window-excursion
          (delete-other-windows)
          (switch-to-buffer index)
          (teams4e-recent-mode)
          (teams4e--render-recent)
          (teams4e--recent-goto-chat-id "chat-filter-follow-1")
          (let ((reader-window (split-window-right)))
            (with-selected-window reader-window
              (switch-to-buffer reader)
              (teams4e-chat-mode)
              (setq teams4e--chat first))
            (setq teams4e--active-query
                  (lambda (chat)
                    (equal "chat-filter-follow-2"
                           (teams4e--chat-id chat))))
            (cl-letf (((symbol-function 'teams4e-open-chat)
                       (lambda (chat &rest _args)
                         (setq opened chat)
                         (with-current-buffer reader
                           (setq teams4e--chat chat)))))
              (teams4e--render-recent))
            (should (equal "chat-filter-follow-2" (tabulated-list-get-id)))
            (should (equal "chat-filter-follow-2"
                           (teams4e--chat-id opened)))))
      (when (buffer-live-p index) (kill-buffer index))
      (when (buffer-live-p reader) (kill-buffer reader)))))

(ert-deftest teams4e-reader-filter-with-no-rows-clears-stale-thread ()
  (let* ((chat '((id . "chat-filter-empty") (topic . "Only chat")))
         (teams4e--chats (list chat))
         (teams4e--active-view 'all)
         (teams4e--active-query nil)
         (index (get-buffer-create teams4e--recent-buffer-name))
         (reader (get-buffer-create teams4e--read-buffer-name)))
    (unwind-protect
        (save-window-excursion
          (delete-other-windows)
          (switch-to-buffer index)
          (teams4e-recent-mode)
          (teams4e--render-recent)
          (let ((reader-window (split-window-right)))
            (select-window reader-window)
            (switch-to-buffer reader)
            (teams4e-chat-mode)
            (setq teams4e--chat chat)
            (cl-letf (((symbol-function 'teams4e-test-empty-chat-filter)
                       (lambda ()
                         (interactive)
                         (setq teams4e--active-query
                               (lambda (_candidate) nil))
                         (teams4e--render-recent))))
              (teams4e-chat-run-headers-command
               #'teams4e-test-empty-chat-filter))
            (should-not teams4e--chat)
            (should (string-match-p "No chats match"
                                    (buffer-string)))))
      (when (buffer-live-p index) (kill-buffer index))
      (when (buffer-live-p reader) (kill-buffer reader)))))

(ert-deftest teams4e-stale-chat-response-cannot-overwrite-reused-reader ()
  (let (first-callback second-callback rendered)
    (with-temp-buffer
      (cl-letf (((symbol-function 'teams4e--run-json)
                 (lambda (_args callback &optional _error-callback)
                   (if first-callback
                       (setq second-callback callback)
                     (setq first-callback callback))
                   nil))
                ((symbol-function 'teams4e--render-chat)
                 (lambda () (setq rendered teams4e--messages))))
        (teams4e-chat-mode)
        (setq teams4e--chat '((id . "chat-stale")))
        (teams4e-chat-refresh)
        (teams4e-channel-thread-mode)
        (teams4e-chat-mode)
        (setq teams4e--chat '((id . "chat-current")))
        (teams4e-chat-refresh)
        (funcall first-callback '(((id . "message-stale"))))
        (should-not rendered)
        (should-not teams4e--messages)
        (funcall second-callback '(((id . "message-current"))))
        (should (equal "message-current"
                       (teams4e--get (car rendered) 'id)))))))

(ert-deftest teams4e-switching-meetings-cancels-and-replaces-context-request ()
  (when-let ((existing (get-buffer teams4e--read-buffer-name)))
    (kill-buffer existing))
  (let* ((first '((id . "meeting-first") (chatType . "meeting")))
         (second '((id . "meeting-second") (chatType . "meeting")))
         (buffer (get-buffer-create teams4e--read-buffer-name))
         (process (make-pipe-process
                   :name "teams4e-stale-meeting"
                   :buffer nil
                   :noquery t))
         loaded)
    (unwind-protect
        (with-current-buffer buffer
          (teams4e-chat-mode)
          (setq teams4e--chat first
                teams4e--meeting-process process
                teams4e--meeting-request-id 7)
          (cl-letf (((symbol-function 'teams4e-chat-refresh) #'ignore)
                    ((symbol-function 'teams4e--display-chat-buffer)
                     #'ignore)
                    ((symbol-function 'teams4e--close-other-readers)
                     #'ignore)
                    ((symbol-function 'teams4e--load-meeting-context)
                     (lambda (chat) (setq loaded chat))))
            (teams4e-open-chat second))
          (should-not (process-live-p process))
          (should (equal "meeting-second"
                         (teams4e--chat-id loaded)))
          (should (= 8 teams4e--meeting-request-id)))
      (when (process-live-p process) (delete-process process))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest teams4e-stale-channel-response-cannot-overwrite-reused-reader ()
  (let (first-callback second-callback rendered)
    (with-temp-buffer
      (cl-letf (((symbol-function 'teams4e--run-json)
                 (lambda (_args callback &optional _error-callback)
                   (if first-callback
                       (setq second-callback callback)
                     (setq first-callback callback))
                   nil))
                ((symbol-function 'teams4e--render-channel-thread)
                 (lambda ()
                   (setq rendered teams4e-channel--messages))))
        (teams4e-channel-thread-mode)
        (setq teams4e-channel--team '((id . "team-stale"))
              teams4e-channel--channel '((id . "channel-stale"))
              teams4e-channel--root '((id . "root-stale")))
        (teams4e-channel-thread-refresh)
        (teams4e-chat-mode)
        (teams4e-channel-thread-mode)
        (setq teams4e-channel--team '((id . "team-current"))
              teams4e-channel--channel '((id . "channel-current"))
              teams4e-channel--root '((id . "root-current")))
        (teams4e-channel-thread-refresh)
        (funcall first-callback '(((id . "reply-stale"))))
        (should-not rendered)
        (should-not teams4e-channel--messages)
        (funcall second-callback '(((id . "reply-current"))))
        (should (equal '("reply-current" "root-current")
                       (sort (mapcar (lambda (message)
                                       (teams4e--get message 'id))
                                     rendered)
                             #'string<)))))))

(ert-deftest teams4e-thread-navigation-falls-back-without-headers-buffer ()
  (let* ((first '((id . "chat-1")))
         (second '((id . "chat-2")))
         (teams4e--chats (list first second))
         opened)
    (with-temp-buffer
      (teams4e-chat-mode)
      (setq teams4e--chat first)
      (cl-letf (((symbol-function 'teams4e--recent-buffer)
                 (lambda () nil))
                ((symbol-function 'teams4e--view-chat-p)
                 (lambda (_chat) t))
                ((symbol-function 'teams4e-open-chat)
                 (lambda (chat &optional _preview) (setq opened chat))))
        (teams4e-thread-next)))
    (should (equal "chat-2" (teams4e--chat-id opened)))))

(ert-deftest teams4e-chat-list-bounds-metadata-and-accepts-embedded-members ()
  (let ((teams4e-chat-metadata-limit 75)
        (teams4e-member-enrichment-limit 12)
        (teams4e-member-enrichment-concurrency 6)
        (teams4e-offline-mode nil)
        (teams4e--member-cache (make-hash-table :test #'equal))
        observed result)
    (cl-letf (((symbol-function 'teams4e--run-json)
               (lambda (args callback &optional _error-callback)
                 (setq observed args)
                 (funcall callback
                          '(((id . "chat-batched")
                             (membersLoaded . t)
                             (members . (((displayName . "Ada")))))))
                 'fake-process)))
      (teams4e--load-chats (lambda (chats) (setq result chats))))
    (should (equal
             '("teams" "chat" "list" "--metadataLimit" "75")
             observed))
    (should (= 1 (length result)))
    (should (equal "Ada"
                   (teams4e--get
                    (car (teams4e--chat-members (car result)))
                    'displayName)))))

(ert-deftest teams4e-member-enrichment-uses-one-asynchronous-batch ()
  (let ((chats '(((id . "chat-1") (topic))
                 ((id . "chat-2") (topic . "Named group"))))
        (teams4e-member-enrichment-limit 12)
        (teams4e-member-enrichment-concurrency 6)
        (teams4e-offline-mode nil)
        (teams4e--member-cache (make-hash-table :test #'equal))
        (teams4e--member-inflight (make-hash-table :test #'equal))
        observed)
    (cl-letf (((symbol-function 'teams4e--run-json)
               (lambda (args callback &optional _error-callback)
                 (setq observed args)
                 (funcall callback
                          '(((chatId . "chat-1")
                             (membersLoaded . t)
                             (members . (((displayName . "Ada")))))))
                 'fake-process))
              ((symbol-function 'teams4e--refresh-visible-recent)
               #'ignore))
      (teams4e--enrich-members chats))
    (should (equal
             '("teams" "chat" "member" "batch"
               "--memberConcurrency" "6" "--chatId" "chat-1")
             observed))
    (should (equal "Ada"
                   (teams4e--get
                    (car (gethash "chat-1" teams4e--member-cache))
                    'displayName)))
    (should-not (gethash "chat-1" teams4e--member-inflight))))

(ert-deftest teams4e-meeting-enrichment-uses-one-event-only-batch ()
  (let* ((meeting
          '((id . "meeting-1")
            (chatType . "meeting")
            (onlineMeetingInfo . ((calendarEventId . "event-1")))))
         (ordinary '((id . "chat-2") (chatType . "group")))
         (teams4e--chats (list meeting ordinary))
         (teams4e-meeting-enrichment-limit 12)
         (teams4e-meeting-enrichment-concurrency 3)
         (teams4e-offline-mode nil)
         (teams4e--meeting-inflight (make-hash-table :test #'equal))
         observed)
    (cl-letf (((symbol-function 'teams4e--run-json)
               (lambda (args callback &optional _error-callback)
                 (setq observed args)
                 (funcall callback
                          '(((chatId . "meeting-1")
                             (event
                              . ((start
                                  . ((dateTime . "2099-08-10T07:30:00")
                                     (timeZone . "UTC"))))))))
                 'fake-process))
              ((symbol-function 'teams4e--refresh-visible-recent)
               #'ignore))
      (teams4e--enrich-meetings teams4e--chats))
    (should (equal '("teams" "meeting" "event" "batch")
                   (seq-take observed 4)))
    (should (equal "3" (car (last observed))))
    (let ((requests
           (json-parse-string (nth 5 observed)
                              :object-type 'alist :array-type 'list)))
      (should (= 1 (length requests)))
      (should (equal "meeting-1" (teams4e--get (car requests) 'chatId)))
      (should (equal "event-1" (teams4e--get (car requests) 'eventId))))
    (should (equal "2099-08-10T07:30:00"
                   (teams4e--dig meeting 'meetingContext 'event
                                  'start 'dateTime)))
    (should-not (gethash "meeting-1" teams4e--meeting-inflight))))

(ert-deftest teams4e-meeting-view-resolves-list-rows-without-event-ids ()
  (let* ((meeting '((id . "meeting-1") (chatType . "meeting")))
         (teams4e--chats (list meeting))
         (teams4e-meeting-enrichment-limit 12)
         (teams4e-meeting-enrichment-concurrency 3)
         (teams4e-offline-mode nil)
         (teams4e--meeting-inflight (make-hash-table :test #'equal))
         observed)
    (cl-letf (((symbol-function 'teams4e--run-json)
               (lambda (args callback &optional _error-callback)
                 (setq observed args)
                 (funcall callback
                          '(((chatId . "meeting-1")
                             (onlineMeetingInfo
                              . ((calendarEventId . "event-1")))
                             (event
                              . ((id . "event-1")
                                 (start
                                  . ((dateTime . "2099-08-10T07:30:00")
                                     (timeZone . "UTC"))))))))
                 'fake-process))
              ((symbol-function 'teams4e--refresh-visible-recent)
               #'ignore))
      (teams4e--enrich-meetings teams4e--chats t))
    (let ((requests
           (json-parse-string (nth 5 observed)
                              :object-type 'alist :array-type 'list)))
      (should (= 1 (length requests)))
      (should (equal "meeting-1" (teams4e--get (car requests) 'chatId)))
      (should-not (assq 'eventId (car requests))))
    (should (equal "event-1" (teams4e--meeting-event-id meeting)))
    (should (equal "2099-08-10T07:30:00"
                   (teams4e--dig meeting 'meetingContext 'event
                                  'start 'dateTime)))
    (should-not (gethash "meeting-1" teams4e--meeting-inflight))))

(ert-deftest teams4e-meeting-enrichment-failure-is-visible-on-the-chat ()
  (let* ((meeting
          '((id . "meeting-1")
            (chatType . "meeting")
            (onlineMeetingInfo . ((calendarEventId . "event-1")))))
         (teams4e--chats (list meeting))
         (teams4e-meeting-enrichment-limit 12)
         (teams4e-offline-mode nil)
         (teams4e--meeting-inflight (make-hash-table :test #'equal))
         reported)
    (cl-letf (((symbol-function 'teams4e--run-json)
               (lambda (args _callback &optional error-callback)
                 (funcall error-callback 403 "calendar denied")
                 'fake-process))
              ((symbol-function 'teams4e--report-error)
               (lambda (args status detail)
                 (setq reported (list args status detail))))
              ((symbol-function 'teams4e--refresh-visible-recent)
               #'ignore))
      (teams4e--enrich-meetings teams4e--chats))
    (should (equal "Calendar metadata request failed (403): calendar denied"
                   (teams4e--dig meeting 'meetingContext 'eventError)))
    (let ((credentials (make-temp-file "teams4e-calendar-credentials-")))
      (unwind-protect
          (let ((teams4e-credentials-file credentials)
                (teams4e-token-command nil)
                (teams4e-mock-mode nil))
            (should (equal "Calendar permission denied"
                           (teams4e--calendar-unavailable-label meeting))))
        (delete-file credentials)))
    (should (= 403 (nth 1 reported)))
    (should-not (gethash "meeting-1" teams4e--meeting-inflight))))

(ert-deftest teams4e-utf8-safe-string-removes-invalid-codepoints ()
  (should (equal "hello"
                 (teams4e--utf8-safe-string "hello")))
  (should (equal "ab"
                 (teams4e--utf8-safe-string (concat "a\0b")))))

(ert-deftest teams4e-calendar-label-distinguishes-login-from-event-linkage ()
  (let ((teams4e-credentials-file
         (expand-file-name "missing-teams4e-credentials.json"
                           temporary-file-directory))
        (teams4e-token-command nil)
        (teams4e-mock-mode nil)
        (meeting '((meetingContext
                    . ((eventError . "No linked calendar event ID"))))))
    (should (equal "Sign in required (M-x teams4e-login)"
                   (teams4e--calendar-unavailable-label meeting)))
    (let ((credentials (make-temp-file "teams4e-calendar-credentials-")))
      (unwind-protect
          (let ((teams4e-credentials-file credentials))
            (should (equal "No linked calendar event"
                           (teams4e--calendar-unavailable-label meeting))))
        (delete-file credentials)))))

(ert-deftest teams4e-calendar-label-reports-missing-calendar-row ()
  (let ((credentials (make-temp-file "teams4e-calendar-credentials-")))
    (unwind-protect
        (let ((teams4e-credentials-file credentials)
              (teams4e-token-command nil)
              (teams4e-mock-mode nil)
              (meeting
               '((meetingContext
                  . ((eventError
                     . "No calendar event matched the meeting join URL"))))))
          (should (equal "Not on your calendar"
                         (teams4e--calendar-unavailable-label meeting))))
      (delete-file credentials))))

(ert-deftest teams4e-calendar-error-retriable-p-recognizes-join-url-fallback ()
  (should (teams4e--calendar-error-retriable-p
           "The meeting chat has no linked calendar event ID"))
  (should (teams4e--calendar-error-retriable-p
           "No calendar event matched the meeting join URL"))
  (should (teams4e--calendar-error-retriable-p
           "Microsoft Graph HTTP 404: item not found"))
  (should (teams4e--calendar-error-retriable-p
           "Calendar enrichment timed out; press g to retry"))
  (should-not (teams4e--calendar-error-retriable-p
               "Microsoft Graph HTTP 403: denied")))

(ert-deftest teams4e-meeting-enrichment-timeout-clears-inflight ()
  (let* ((meeting '((id . "meeting-1") (chatType . "meeting")))
         (teams4e--chats (list meeting))
         (teams4e--meeting-inflight (make-hash-table :test #'equal))
         (teams4e--meeting-enrichment-timeouts (make-hash-table :test #'equal)))
    (puthash "meeting-1" t teams4e--meeting-inflight)
    (teams4e--meeting-enrichment-timed-out "meeting-1")
    (should-not (gethash "meeting-1" teams4e--meeting-inflight))
    (should (teams4e--calendar-error-detail meeting))))

(ert-deftest teams4e-meeting-enrichment-makes-one-bounded-request-per-refresh ()
  (let* ((meetings
          (mapcar
           (lambda (id)
             `((id . ,id) (chatType . "meeting")))
           '("m1" "m2" "m3" "m4" "m5")))
         (teams4e--chats meetings)
         (teams4e-meeting-enrichment-limit 2)
         (teams4e-meeting-enrichment-concurrency 1)
         (teams4e-offline-mode nil)
         (teams4e--meeting-inflight (make-hash-table :test #'equal))
         (teams4e--meeting-enrichment-timeouts (make-hash-table :test #'equal))
         observed
         (calls 0))
    (cl-letf (((symbol-function 'teams4e--run-json)
               (lambda (args callback &optional _error-callback)
                 (setq calls (1+ calls))
                 (setq observed args)
                 (funcall
                  callback
                  (mapcar
                   (lambda (request)
                     `((chatId . ,(teams4e--get request 'chatId))
                       (eventError
                        . "No calendar event matched the meeting join URL")))
                   (json-parse-string
                    (nth 5 args) :object-type 'alist :array-type 'list)))
                 'fake-process))
              ((symbol-function 'teams4e--refresh-visible-recent)
               #'ignore)
              ((symbol-function 'teams4e--schedule-meeting-enrichment-timeouts)
               #'ignore))
      (teams4e--enrich-meetings teams4e--chats t))
    (should (= 1 calls))
    (let ((requests
           (json-parse-string (nth 5 observed)
                              :object-type 'alist :array-type 'list)))
      (should (= 2 (length requests))))))

(ert-deftest teams4e-enrich-meetings-retries-after-retriable-calendar-error ()
  (let* ((meeting
          '((id . "meeting-1")
            (chatType . "meeting")
            (meetingContext
             . ((eventError
                 . "The meeting chat has no linked calendar event ID")))))
         (teams4e--chats (list meeting))
         (teams4e-meeting-enrichment-limit 32)
         (teams4e-meeting-enrichment-concurrency 1)
         (teams4e-offline-mode nil)
         (teams4e--meeting-inflight (make-hash-table :test #'equal))
         observed)
    (cl-letf (((symbol-function 'teams4e--run-json)
               (lambda (args _callback &optional _error-callback)
                 (setq observed args)
                 'fake-process))
              ((symbol-function 'teams4e--refresh-visible-recent)
               (lambda () nil)))
      (teams4e--enrich-meetings teams4e--chats t))
    (should observed)
    (let ((requests
           (json-parse-string (nth 5 observed)
                              :object-type 'alist :array-type 'list)))
      (should (= 1 (length requests)))
      (should (equal "meeting-1" (teams4e--get (car requests) 'chatId))))))

(ert-deftest teams4e-upcoming-view-shows-calendar-enrichment-in-flight ()
  (let* ((meeting '((id . "meeting-1") (chatType . "meeting")))
         (teams4e--meeting-inflight (make-hash-table :test #'equal)))
    (should-not (teams4e--meeting-upcoming-p meeting))
    (puthash "meeting-1" t teams4e--meeting-inflight)
    (should (teams4e--meeting-upcoming-p meeting))))

(ert-deftest teams4e-meeting-fallback-prioritizes-recent-message-less-rows ()
  (let* ((message-meeting
          '((id . "with-message")
            (chatType . "meeting")
            (lastUpdatedDateTime . "2026-08-08T12:00:00Z")
            (lastMessagePreview
             . ((id . "message-1")
                (createdDateTime . "2026-08-08T12:00:00Z")))))
         (calendar-stub
          '((id . "calendar-stub")
            (chatType . "meeting")
            (lastUpdatedDateTime . "2026-08-08T11:00:00Z")))
         (teams4e--chats (list message-meeting calendar-stub))
         (teams4e-meeting-enrichment-limit 1)
         (teams4e-meeting-enrichment-concurrency 1)
         (teams4e-offline-mode nil)
         (teams4e--meeting-inflight (make-hash-table :test #'equal))
         observed)
    (cl-letf (((symbol-function 'teams4e--run-json)
               (lambda (args _callback &optional _error-callback)
                 (setq observed args)
                 'fake-process))
              ((symbol-function 'teams4e--refresh-visible-recent)
               #'ignore))
      (teams4e--enrich-meetings teams4e--chats t))
    (let* ((requests
            (json-parse-string (nth 5 observed)
                               :object-type 'alist :array-type 'list))
           (request (car requests)))
      (should (= 1 (length requests)))
      (should (equal "calendar-stub"
                     (teams4e--get request 'chatId))))))

(ert-deftest teams4e-known-account-skips-redundant-status-process ()
  (let ((teams4e-offline-mode nil)
        (teams4e--connected-as "user@example.com")
        status-called callback-called)
    (cl-letf (((symbol-function 'teams4e--status-request)
               (lambda (&rest _args) (setq status-called t))))
      (teams4e--with-status (lambda () (setq callback-called t))))
    (should callback-called)
    (should-not status-called)))

(ert-deftest teams4e-logged-out-status-runs-unavailable-callback-only ()
  (let ((teams4e-offline-mode nil)
        (teams4e--connected-as nil)
        success-called unavailable-called)
    (cl-letf (((symbol-function 'teams4e--status-request)
               (lambda (callback &optional _error-callback)
                 (funcall callback "Logged out"))))
      (teams4e--with-status
       (lambda () (setq success-called t))
       (lambda () (setq unavailable-called t))))
    (should unavailable-called)
    (should-not success-called)))

(ert-deftest teams4e-preview-reuses-unchanged-recent-transcript ()
  (let* ((chat '((id . "chat-cached")
                 (lastUpdatedDateTime . "2026-08-02T10:00:00Z")))
         (buffer-name teams4e--read-buffer-name)
         (teams4e-preview-cache-seconds 120)
         (refreshes 0))
    (unwind-protect
        (progn
          (with-current-buffer (get-buffer-create buffer-name)
            (teams4e-chat-mode)
            (setq teams4e--chat chat
                  teams4e--messages '(((id . "message-1")))
                  teams4e--loaded-at (float-time)
                  teams4e--loaded-update
                  "2026-08-02T10:00:00Z"))
          (cl-letf (((symbol-function 'teams4e-chat-refresh)
                     (lambda (&optional _all _limit) (cl-incf refreshes)))
                    ((symbol-function 'teams4e--display-chat-buffer)
                     #'ignore))
            (teams4e-open-chat chat t)
            (should (= 0 refreshes))
            (teams4e-open-chat chat nil)
            (should (= 1 refreshes))))
      (when-let ((buffer (get-buffer buffer-name))) (kill-buffer buffer)))))

(ert-deftest teams4e-preview-requests-lightweight-message-page ()
  (let* ((chat '((id . "chat-preview-limit")
                 (lastUpdatedDateTime . "2026-08-02T10:00:00Z")))
         (buffer-name teams4e--read-buffer-name)
         (teams4e-preview-message-limit 75)
         observed)
    (unwind-protect
        (cl-letf (((symbol-function 'teams4e-chat-refresh)
                   (lambda (&optional all limit)
                     (setq observed (list all limit))))
                  ((symbol-function 'teams4e--display-chat-buffer)
                   #'ignore))
          (teams4e-open-chat chat t)
          (should (equal '(nil 75) observed)))
      (when-let ((buffer (get-buffer buffer-name))) (kill-buffer buffer)))))

(ert-deftest teams4e-chat-preview-and-explicit-open-share-one-reader ()
  (let* ((first '((id . "chat-preview-first") (topic . "First")))
         (second '((id . "chat-preview-second") (topic . "Second"))))
    (unwind-protect
        (cl-letf (((symbol-function 'teams4e-chat-refresh) #'ignore)
                  ((symbol-function 'teams4e--display-chat-buffer)
                   #'ignore))
          (teams4e-open-chat first t)
          (teams4e-open-chat second t)
          (with-current-buffer teams4e--read-buffer-name
            (should teams4e--automatic-preview-p)
            (should (derived-mode-p 'teams4e-read-mode))
            (should (equal "chat-preview-second"
                           (teams4e--chat-id
                            teams4e--chat))))
          (teams4e-open-chat first nil)
          (with-current-buffer teams4e--read-buffer-name
            (should-not teams4e--automatic-preview-p)
            (should (equal "chat-preview-first"
                           (teams4e--chat-id
                            teams4e--chat))))
          (should-not
           (seq-find (lambda (buffer)
                       (string-prefix-p "*Teams Chat " (buffer-name buffer)))
                     (buffer-list))))
      (when-let ((buffer (get-buffer teams4e--read-buffer-name)))
        (kill-buffer buffer)))))

(ert-deftest teams4e-channel-preview-and-explicit-open-share-one-reader ()
  (let* ((team '((id . "team-preview") (displayName . "Engineering")))
         (channel '((id . "channel-preview") (displayName . "General")))
         (first '((id . "root-preview-first") (subject . "First")))
         (second '((id . "root-preview-second") (subject . "Second"))))
    (unwind-protect
        (cl-letf
            (((symbol-function 'teams4e-channel-thread-refresh) #'ignore)
             ((symbol-function 'teams4e--display-channel-thread)
              #'ignore))
          (teams4e-open-channel-thread team channel first t)
          (teams4e-open-channel-thread team channel second t)
          (with-current-buffer teams4e--read-buffer-name
            (should teams4e--automatic-preview-p)
            (should (derived-mode-p 'teams4e-read-mode))
            (should (equal "root-preview-second"
                           (teams4e--get teams4e-channel--root 'id))))
          (teams4e-open-channel-thread team channel first)
          (with-current-buffer teams4e--read-buffer-name
            (should-not teams4e--automatic-preview-p)
            (should (equal "root-preview-first"
                           (teams4e--get
                            teams4e-channel--root 'id)))))
      (when-let ((buffer (get-buffer teams4e--read-buffer-name)))
        (kill-buffer buffer)))))

(ert-deftest teams4e-chat-and-channel-replace-the-same-reader-buffer ()
  (let ((chat '((id . "chat-single-reader") (topic . "Chat")))
        (team '((id . "team-single-reader") (displayName . "Team")))
        (channel '((id . "channel-single-reader") (displayName . "General")))
        (root '((id . "root-single-reader") (subject . "Root")))
        first-buffer)
    (unwind-protect
        (cl-letf
            (((symbol-function 'teams4e-chat-refresh) #'ignore)
             ((symbol-function 'teams4e-channel-thread-refresh) #'ignore)
             ((symbol-function 'teams4e--display-chat-buffer) #'ignore)
             ((symbol-function 'teams4e--display-channel-thread)
              #'ignore))
          (teams4e-open-chat chat)
          (setq first-buffer (get-buffer teams4e--read-buffer-name))
          (teams4e-open-channel-thread team channel root)
          (should (eq first-buffer
                      (get-buffer teams4e--read-buffer-name)))
          (with-current-buffer first-buffer
            (should (derived-mode-p 'teams4e-channel-thread-mode))))
      (when-let ((buffer (get-buffer teams4e--read-buffer-name)))
        (kill-buffer buffer)))))

(ert-deftest teams4e-close-inactive-transcripts-retains-single-reader ()
  (let ((preview (get-buffer-create teams4e--read-buffer-name))
        (chat (generate-new-buffer "*Teams Chat inactive-test*"))
        (channel (generate-new-buffer "*Teams Channel Thread inactive-test*")))
    (unwind-protect
        (progn
          (with-current-buffer preview
            (teams4e-chat-mode)
            (setq teams4e--automatic-preview-p t))
          (with-current-buffer chat
            (teams4e-chat-mode))
          (with-current-buffer channel
            (teams4e-channel-thread-mode))
          (teams4e-close-inactive-transcripts)
          (should (buffer-live-p preview))
          (should-not (buffer-live-p chat))
          (should-not (buffer-live-p channel)))
      (dolist (buffer (list preview chat channel))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest teams4e-compose-draft-restores-body-metadata-and-private-mode ()
  (let* ((directory (make-temp-file "teams4e-draft-" t))
         (teams4e-draft-directory directory)
         (target '((id . "chat-draft") (topic . "Draft test")))
         (reply '((id . "message-draft")
                  (from . ((user . ((id . "ada-id")
                                    (displayName . "Ada")))))
                  (body . ((contentType . "text")
                           (content . "Original message")))))
         draft-file)
    (unwind-protect
        (progn
          (with-temp-buffer
            (teams4e-compose-mode)
            (setq teams4e-compose--target target
                  teams4e-compose--reply-to reply
                  teams4e-compose--content-type "html"
                  teams4e-compose--attachments '("/tmp/report.pdf")
                  teams4e-compose--mentions '("ada-id|Ada"))
            (teams4e-compose--initialize-draft)
            (insert "<strong>Draft</strong> @Ada")
            (teams4e-compose--save-draft)
            (setq draft-file teams4e-compose--draft-file
                  teams4e-compose--discarded t))
          (should (file-exists-p draft-file))
          (should (= #o600 (file-modes draft-file)))
          (let ((payload (teams4e-compose--read-draft draft-file)))
            (should (equal "chat-draft"
                           (teams4e--dig payload 'target 'chatId)))
            (should (equal "message-draft"
                           (teams4e--dig payload 'replyTo 'id)))
            (should (stringp (teams4e--get payload 'updatedAt))))
          (with-temp-buffer
            (teams4e-compose-mode)
            (setq teams4e-compose--target target
                  teams4e-compose--reply-to reply)
            (teams4e-compose--initialize-draft)
            (should (equal "<strong>Draft</strong> @Ada" (buffer-string)))
            (should (equal "html" teams4e-compose--content-type))
            (should (equal '("/tmp/report.pdf")
                           teams4e-compose--attachments))
            (should (equal '("ada-id|Ada")
                           teams4e-compose--mentions))
            (teams4e-compose--delete-draft)))
      (delete-directory directory t))))

(ert-deftest teams4e-compose-drafts-are-distinct-per-reply-target ()
  (with-temp-buffer
    (teams4e-compose-mode)
    (setq teams4e-compose--target '((id . "chat-1"))
          teams4e-compose--reply-to '((id . "message-1")))
    (let ((first (teams4e-compose--target-key)))
      (setq teams4e-compose--reply-to '((id . "message-2")))
      (should-not (equal first (teams4e-compose--target-key)))
      (setq teams4e-compose--reply-to nil)
      (should (equal "chat-1" (teams4e-compose--target-key))))))

(ert-deftest teams4e-compose-buffers-are-distinct-per-reply-target ()
  (let ((target '((id . "chat-1") (topic . "Draft test"))))
    (should-not
     (equal (teams4e--compose-buffer-name
             target '((id . "message-1")))
            (teams4e--compose-buffer-name
             target '((id . "message-2")))))
    (should-not
     (equal (teams4e--compose-buffer-name target)
            (teams4e--compose-buffer-name
             target '((id . "message-1")))))))

(ert-deftest teams4e-compose-reopen-preserves-live-metadata ()
  (let* ((directory (make-temp-file "teams4e-live-compose-" t))
         (teams4e-draft-directory directory)
         (target '((id . "chat-live") (topic . "Live draft")))
         (name (teams4e--compose-buffer-name target))
         buffer)
    (unwind-protect
        (save-current-buffer
          (cl-letf (((symbol-function 'pop-to-buffer)
                     (lambda (target-buffer &rest _args)
                       (setq buffer target-buffer)
                       (set-buffer target-buffer))))
            (teams4e--open-compose target)
            (insert "Existing live draft")
            (setq teams4e-compose--attachments '("/tmp/report.pdf")
                  teams4e-compose--mentions '("ada-id|Ada")
                  teams4e-compose--content-type "html")
            (teams4e--open-compose target nil "Forwarded replacement")
            (should (eq buffer (get-buffer name)))
            (should (equal "Existing live draft" (buffer-string)))
            (should (equal '("/tmp/report.pdf")
                           teams4e-compose--attachments))
            (should (equal '("ada-id|Ada")
                           teams4e-compose--mentions))
            (should (equal "html" teams4e-compose--content-type))
            (teams4e-compose--delete-draft)))
      (when (buffer-live-p buffer) (kill-buffer buffer))
      (delete-directory directory t))))

(ert-deftest teams4e-compose-restores-disk-draft-before-initial-text ()
  (let* ((directory (make-temp-file "teams4e-disk-compose-" t))
         (teams4e-draft-directory directory)
         (target '((id . "chat-disk") (topic . "Disk draft")))
         (name (teams4e--compose-buffer-name target))
         buffer)
    (unwind-protect
        (progn
          (with-temp-buffer
            (teams4e-compose-mode)
            (setq teams4e-compose--target target)
            (teams4e-compose--initialize-draft)
            (insert "Recovered disk draft")
            (teams4e-compose--save-draft)
            (setq teams4e-compose--discarded t))
          (save-current-buffer
            (cl-letf (((symbol-function 'pop-to-buffer)
                       (lambda (target-buffer &rest _args)
                         (setq buffer target-buffer)
                         (set-buffer target-buffer))))
              (teams4e--open-compose target nil "Forwarded replacement")
              (should (eq buffer (get-buffer name)))
              (should (equal "Recovered disk draft" (buffer-string)))
              (teams4e-compose--delete-draft))))
      (when (buffer-live-p buffer) (kill-buffer buffer))
      (delete-directory directory t))))

(ert-deftest teams4e-compose-failed-send-retains-private-draft ()
  (let* ((directory (make-temp-file "teams4e-failed-send-" t))
         (teams4e-draft-directory directory)
         (teams4e-confirm-send nil)
         (teams4e-offline-mode nil)
         (buffer (generate-new-buffer " *Teams failed send test*"))
         draft-file reported)
    (unwind-protect
        (with-current-buffer buffer
          (teams4e-compose-mode)
          (setq teams4e-compose--target
                '((id . "chat-failure") (topic . "Failure test")))
          (teams4e-compose--initialize-draft)
          (insert "This must survive the failed send")
          (setq draft-file teams4e-compose--draft-file)
          (cl-letf (((symbol-function 'teams4e--run)
                     (lambda (_args _callback &optional error-callback)
                       (funcall error-callback 1 "simulated failure")
                       'fake-process))
                    ((symbol-function 'teams4e--report-error)
                     (lambda (&rest _args) (setq reported t))))
            (teams4e-compose-send))
          (should (buffer-live-p buffer))
          (should reported)
          (should (string-match-p "Send to Failure test failed"
                                  header-line-format))
          (should (file-exists-p draft-file))
          (should (= #o600 (file-modes draft-file)))
          (let ((payload
                 (json-parse-string
                  (with-temp-buffer
                    (insert-file-contents draft-file)
                    (buffer-string))
                  :object-type 'alist :array-type 'list)))
            (should (equal "This must survive the failed send"
                           (teams4e--get payload 'body))))
          (teams4e-compose--delete-draft))
      (when (buffer-live-p buffer) (kill-buffer buffer))
      (delete-directory directory t))))

(ert-deftest teams4e-channel-export-refetches-complete-replies ()
  (let* ((path (make-temp-file "teams4e-channel-export-" nil ".md"))
         (root '((id . "root-1")
                 (createdDateTime . "2026-08-01T10:00:00Z")
                 (from . ((user . ((displayName . "Ada")))))
                 (body . ((contentType . "text") (content . "Root post")))))
         (reply '((id . "reply-1")
                  (createdDateTime . "2026-08-01T10:05:00Z")
                  (from . ((user . ((displayName . "Grace")))))
                  (body . ((contentType . "text")
                           (content . "Fresh complete reply")))))
         captured-args exported-path)
    (unwind-protect
        (with-temp-buffer
          (teams4e-channel-thread-mode)
          (setq teams4e-channel--team
                '((id . "team-1") (displayName . "Engineering"))
                teams4e-channel--channel
                '((id . "channel-1") (displayName . "General"))
                teams4e-channel--root root
                teams4e-channel--messages (list root))
          (cl-letf (((symbol-function 'teams4e--export-path)
                     (lambda (_chat) path))
                    ((symbol-function 'teams4e--run-json)
                     (lambda (args callback &optional _error-callback)
                       (setq captured-args args)
                       (funcall callback (list reply))
                       'fake-process)))
            (teams4e-channel-export-thread
             nil (lambda (saved-path) (setq exported-path saved-path))))
          (should
           (equal '("teams" "channel" "reply" "list"
                    "--teamId" "team-1" "--channelId" "channel-1"
                    "--messageId" "root-1")
                  captured-args))
          (should (= #o600 (file-modes path)))
          (should (equal path exported-path))
          (with-temp-buffer
            (insert-file-contents path)
            (should (search-forward "Root post" nil t))
            (should (search-forward "Fresh complete reply" nil t))))
      (when (file-exists-p path) (delete-file path)))))

(ert-deftest teams4e-channel-index-can-copy-complete-thread-markdown ()
  (let* ((root '((id . "root-copy")
                 (subject . "Copy channel thread")
                 (createdDateTime . "2026-08-01T10:00:00Z")
                 (from . ((user . ((displayName . "Ada")))))
                 (body . ((contentType . "text") (content . "Root copy")))))
         (reply '((id . "reply-copy")
                  (createdDateTime . "2026-08-01T10:05:00Z")
                  (from . ((user . ((displayName . "Grace")))))
                  (body . ((contentType . "text")
                           (content . "Reply copy")))))
         captured-args
         captured-markdown)
    (with-temp-buffer
      (teams4e-channel-index-mode)
      (setq teams4e-channel--team
            '((id . "team-1") (displayName . "Engineering"))
            teams4e-channel--channel
            '((id . "channel-1") (displayName . "General"))
            teams4e-channel--roots (list root))
      (cl-letf (((symbol-function 'teams4e-channel-root-at-point)
                 (lambda () root))
                ((symbol-function 'teams4e--run-json)
                 (lambda (args callback &optional _error-callback)
                   (setq captured-args args)
                   (funcall callback (list reply))
                   'fake-process))
                ((symbol-function 'kill-new)
                 (lambda (text &optional _replace)
                   (setq captured-markdown text))))
        (teams4e-copy-current-thread-markdown))
      (should
       (equal '("teams" "channel" "reply" "list"
                "--teamId" "team-1" "--channelId" "channel-1"
                "--messageId" "root-copy")
              captured-args))
      (should (string-match-p "Root copy" captured-markdown))
      (should (string-match-p "Reply copy" captured-markdown)))))

(ert-deftest teams4e-real-backend-mock-status-sync-and-search ()
  (let* ((directory (make-temp-file "teams4e-mock-" t))
         (teams4e-mock-mode t)
         (teams4e-mock-state-file (expand-file-name "tenant.json" directory))
         (teams4e-cache-file (expand-file-name "cache.sqlite3" directory))
         status sync-result search-result cached-chats cached-teams
         cached-roots cached-replies)
    (unwind-protect
        (progn
          (teams4e-test-await
           (teams4e--status-request (lambda (value) (setq status value))))
          (should (equal "MockTenant" (teams4e--get status 'authType)))
          (teams4e-test-await
           (teams4e--run-json
            '("teams" "sync" "--scope" "all")
            (lambda (value) (setq sync-result value))))
          (should (= 2 (teams4e--get sync-result 'teams)))
          (teams4e-test-await
           (teams4e--run-json
            '("teams" "cache" "search" "--query" "native workflow")
            (lambda (value) (setq search-result value))))
          (should search-result)
          (should (equal "channel"
                         (teams4e--dig (car search-result)
                                       'cacheContext 'scopeKind)))
          (dolist (request
                   `((cached-chats . ("teams" "cache" "chat" "list"))
                     (cached-teams . ("teams" "cache" "team" "list"))
                     (cached-roots
                      . ("teams" "cache" "channel" "message" "list"
                         "--teamId" "mock-team-engineering"
                         "--channelId" "mock-channel-general"
                         "--limit" "1000000"))
                     (cached-replies
                      . ("teams" "cache" "channel" "reply" "list"
                         "--teamId" "mock-team-engineering"
                         "--channelId" "mock-channel-general"
                         "--messageId" "mock-channel-general-1"
                         "--limit" "1000000"))))
            (let (result)
              (teams4e-test-await
               (teams4e--run-json
                (cdr request) (lambda (value) (setq result value))))
              (pcase (car request)
                ('cached-chats (setq cached-chats result))
                ('cached-teams (setq cached-teams result))
                ('cached-roots (setq cached-roots result))
                ('cached-replies (setq cached-replies result)))))
          (should (= 3 (length cached-chats)))
          (should (= 2 (length cached-teams)))
          (should (= 1 (length cached-roots)))
          (should (= 2 (length cached-replies))))
      (delete-directory directory t))))

(ert-deftest teams4e-real-backend-mock-renders-inbox-and-channel-thread ()
  (let* ((directory (make-temp-file "teams4e-mock-ui-" t))
         (teams4e-mock-mode t)
         (teams4e-mock-state-file (expand-file-name "tenant.json" directory))
         (teams4e-cache-file (expand-file-name "cache.sqlite3" directory))
         chats teams channels roots replies)
    (unwind-protect
        (progn
          (dolist (request
                   `((vars . ("teams" "chat" "list"))
                     (teams-var . ("teams" "team" "list"))
                     (channels-var . ("teams" "channel" "list"
                                      "--teamId" "mock-team-engineering"))
                     (roots-var . ("teams" "channel" "message" "list"
                                   "--teamId" "mock-team-engineering"
                                   "--channelId" "mock-channel-general"))
                     (replies-var . ("teams" "channel" "reply" "list"
                                     "--teamId" "mock-team-engineering"
                                     "--channelId" "mock-channel-general"
                                     "--messageId" "mock-channel-general-1"))))
            (let (result)
              (teams4e-test-await
               (teams4e--run-json
                (cdr request) (lambda (value) (setq result value))))
              (pcase (car request)
                ('vars (setq chats result))
                ('teams-var (setq teams result))
                ('channels-var (setq channels result))
                ('roots-var (setq roots result))
                ('replies-var (setq replies result)))))
          (should (= 3 (length chats)))
          (should (= 2 (length teams)))
          (should (= 2 (length channels)))
          (should (= 1 (length roots)))
          (should (= 2 (length replies)))
          (with-temp-buffer
            (teams4e-recent-mode)
            (setq teams4e--chats chats
                  teams4e--active-view 'all
                  teams4e--marks (make-hash-table :test #'equal)
                  teams4e--favorites (make-hash-table :test #'equal))
            (teams4e--render-recent)
            (should (string-match-p "Project Atlas" (buffer-string)))
            (should (string-match-p "MOCK" header-line-format)))
          (with-temp-buffer
            (teams4e-channel-thread-mode)
            (setq teams4e-channel--team (car teams)
                  teams4e-channel--channel (car channels)
                  teams4e-channel--root (car roots)
                  teams4e-channel--messages
                  (cons (car roots) replies))
            (teams4e--render-channel-thread)
            (should (string-match-p "Engineering / General" (buffer-string)))
            (should (string-match-p "production command contract"
                                    (buffer-string)))))
      (delete-directory directory t))))

(ert-deftest teams4e-real-backend-mock-renders-future-meeting-context ()
  (let* ((directory (make-temp-file "teams4e-mock-meeting-" t))
         (teams4e-mock-mode t)
         (teams4e-mock-state-file (expand-file-name "tenant.json" directory))
         (teams4e-cache-file (expand-file-name "cache.sqlite3" directory))
         (teams4e--connected-as "user@example.test")
         (teams4e--member-cache (make-hash-table :test #'equal))
         chats context meeting suggestions proposal)
    (unwind-protect
        (progn
          (teams4e-test-await
           (teams4e--run-json
            '("teams" "chat" "list")
            (lambda (value) (setq chats value))))
          (setq meeting
                (seq-find
                 (lambda (chat)
                   (equal "mock-chat-future-meeting"
                          (teams4e--chat-id chat)))
                 chats))
          (should meeting)
          (teams4e-test-await
           (teams4e--fetch-meeting-context
            meeting (lambda (value) (setq context value))))
          (should (equal "2026-08-10T07:30:00"
                         (teams4e--dig context 'event 'start 'dateTime)))
          (should (= 3 (length (teams4e--get context 'members))))
          (teams4e-test-await
           (teams4e--run-json
            '("teams" "meeting" "propose" "suggest"
              "--eventId" "mock-event-architecture-review"
              "--searchStart" "2026-08-09T00:00:00Z"
              "--searchEnd" "2026-08-14T00:00:00Z"
              "--activityDomain" "work")
            (lambda (value) (setq suggestions value))))
          (let ((slot (teams4e--get
                       (car (teams4e--get suggestions 'suggestions))
                       'meetingTimeSlot)))
            (should (= 100
                       (teams4e--get
                        (car (teams4e--get suggestions 'suggestions))
                        'confidence)))
            (teams4e-test-await
             (teams4e--run-json
              (list "teams" "meeting" "propose" "send"
                    "--eventId" "mock-event-architecture-review"
                    "--start" (teams4e--event-date-time slot 'start)
                    "--end" (teams4e--event-date-time slot 'end)
                    "--comment" "Move the mock meeting")
              (lambda (value) (setq proposal value))))
            (teams4e--apply-meeting-context
             meeting
             `((event . ,(teams4e--get proposal 'event)))))
          (with-temp-buffer
            (teams4e-chat-mode)
            (setq teams4e--chat meeting
                  teams4e--messages nil)
            (teams4e--render-chat)
            (should (string-match-p "Meeting details" (buffer-string)))
            (should (string-match-p "When: .*2026" (buffer-string)))
            (should (string-match-p "Where: Video room 4" (buffer-string)))
            (should (string-match-p "Proposed: .*Aug 11" (buffer-string)))
            (should (string-match-p "Status: New time proposed"
                                    (buffer-string)))
            (should (string-match-p "Participants: .*Grace Hopper"
                                    (buffer-string)))
            (should (string-match-p "Ada Lovelace" (buffer-string)))
            (should (string-match-p "Join meeting" (buffer-string)))))
      (delete-directory directory t))))

(ert-deftest teams4e-channel-thread-render-supports-message-navigation ()
  (let* ((messages (teams4e-test-read-json "messages-chat-1.json"))
         (root (car messages))
         (reply (cadr messages))
         (teams4e--connected-user-id "current-user-id"))
    (with-temp-buffer
      (teams4e-channel-thread-mode)
      (setq teams4e-channel--team
            '((id . "team-1") (displayName . "Engineering"))
            teams4e-channel--channel
            '((id . "channel-1") (displayName . "General"))
            teams4e-channel--root root
            teams4e-channel--messages (list root reply))
      (teams4e--render-channel-thread)
      (should (string-match-p "Engineering / General" (buffer-string)))
      (goto-char (point-min))
      (teams4e-chat-next-message)
      (should (equal "message-1"
                     (teams4e--get (teams4e-current-message) 'id)))
      (teams4e-chat-next-message)
      (should (equal "message-2"
                     (teams4e--get (teams4e-current-message) 'id))))))

(ert-deftest teams4e-message-context-distinguishes-chat-and-channel-reply ()
  (with-temp-buffer
    (teams4e-chat-mode)
    (setq teams4e--chat '((id . "chat-1")))
    (should (equal '("--scope" "chat" "--chatId" "chat-1"
                     "--messageId" "message-1")
                   (teams4e--message-context-args
                    '((id . "message-1"))))))
  (with-temp-buffer
    (teams4e-channel-thread-mode)
    (setq teams4e-channel--team '((id . "team-1"))
          teams4e-channel--channel '((id . "channel-1"))
          teams4e-channel--root '((id . "root-1")))
    (should (equal '("--scope" "channel" "--teamId" "team-1"
                     "--channelId" "channel-1" "--messageId" "reply-1"
                     "--rootMessageId" "root-1")
                   (teams4e--message-context-args
                    '((id . "reply-1")))))))

(ert-deftest teams4e-triage-state-expires-without-another-representation ()
  (let* ((directory (make-temp-file "teams4e-triage-" t))
         (teams4e-state-file (expand-file-name "teams-state.json" directory))
         (teams4e--favorites (make-hash-table :test #'equal))
         (teams4e--muted (make-hash-table :test #'equal))
         (teams4e--handled (make-hash-table :test #'equal))
         (teams4e--snoozed (make-hash-table :test #'equal))
         (teams4e--saved-views (make-hash-table :test #'equal))
         (teams4e--state-loaded t)
         (old '((id . "chat-triage")
                (chatType . "group")
                (lastMessagePreview . ((id . "message-1")))))
         (new '((id . "chat-triage")
                (chatType . "group")
                (lastMessagePreview . ((id . "message-2"))))))
    (unwind-protect
        (progn
          (teams4e--set-handled-local old t)
          (teams4e--save-state)
          (should (= #o600 (file-modes teams4e-state-file)))
          (setq teams4e--state-loaded nil
                teams4e--handled (make-hash-table :test #'equal)
                teams4e--snoozed (make-hash-table :test #'equal))
          (teams4e--load-state)
          (should (teams4e--handled-p old))
          (should-not (teams4e--handled-p new))
          (should-not (teams4e--built-in-view-chat-p old 'inbox))
          (should (teams4e--built-in-view-chat-p new 'inbox))
          (teams4e--set-snoozed-local
           new (format-time-string "%Y-%m-%dT%H:%M:%S%z"
                                   (time-add (current-time) (days-to-time 1))))
          (should-not (teams4e--handled-p new))
          (should (teams4e--snoozed-p new))
          (puthash "chat-triage" "2000-01-01T00:00:00+0000"
                   teams4e--snoozed)
          (should-not (teams4e--snoozed-p new)))
      (delete-directory directory t))))

(ert-deftest teams4e-attention-query-supports-simple-or-clauses ()
  (let* ((direct '((id . "direct") (chatType . "oneOnOne")))
         (important '((id . "important")
                      (chatType . "group")
                      (lastMessagePreview
                       . ((importance . "high")
                          (body . ((contentType . "text")
                                   (content . "Release")))))))
         (ordinary '((id . "ordinary") (chatType . "group")))
         (teams4e--read-overrides (make-hash-table :test #'equal))
         (teams4e--favorites (make-hash-table :test #'equal))
         (teams4e--muted (make-hash-table :test #'equal))
         (teams4e--handled (make-hash-table :test #'equal))
         (teams4e--snoozed (make-hash-table :test #'equal))
         (teams4e--state-loaded t))
    (should (teams4e--query-chat-p direct "important | type:direct"))
    (should (teams4e--query-chat-p important
                                          "important | type:direct"))
    (should-not (teams4e--query-chat-p ordinary
                                              "important | type:direct"))))

(ert-deftest teams4e-cache-first-inbox-renders-cache-then-graph ()
  (let* ((buffer (generate-new-buffer " *Teams cache-first test*"))
         (cached '(((id . "cached")
                    (lastUpdatedDateTime . "2026-08-01T09:00:00Z"))))
         (live '(((id . "live")
                  (lastUpdatedDateTime . "2026-08-02T09:00:00Z"))))
         (teams4e--connected-as "user@example.test")
         calls snapshots)
    (unwind-protect
        (with-current-buffer buffer
          (teams4e-recent-mode)
          (cl-letf (((symbol-function 'teams4e--run-json)
                     (lambda (args callback &optional _error-callback)
                       (push args calls)
                       (funcall callback
                                (if (equal (seq-take args 3)
                                           '("teams" "cache" "chat"))
                                    cached live))
                       'fake-request))
                    ((symbol-function 'teams4e--render-recent)
                     (lambda ()
                       (push (list teams4e--inbox-source-label
                                   (teams4e--chat-id
                                    (car teams4e--chats)))
                             snapshots)))
                    ((symbol-function 'teams4e--enrich-members) #'ignore)
                    ((symbol-function 'teams4e--schedule-preview) #'ignore))
            (teams4e--start-cache-first-inbox-load buffer))
          (setq calls (nreverse calls)
                snapshots (nreverse snapshots))
          (should (equal '("teams" "cache" "chat" "list") (car calls)))
          (should (equal '("teams" "chat" "list")
                         (seq-take (cadr calls) 3)))
          (should (equal '("cached, refreshing" "cached")
                         (car snapshots)))
          (should (equal '(nil "live") (car (last snapshots))))
          (should (= 2 (length snapshots))))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest teams4e-chat-normalization-reuses-canonical-object-and-context ()
  (let* ((context
          `((event . ((id . "event-one") (subject . "Old subject")))
            (teams4eFetchedAt . ,(float-time))))
         (old
          `((id . "meeting-one")
            (chatType . "meeting")
            (topic . "Old title")
            (onlineMeetingInfo . ((calendarEventId . "event-one")))
            (meetingContext . ,context)))
         (fresh
          '((id . "meeting-one")
            (chatType . "meeting")
            (topic . "Fresh title")
            (onlineMeetingInfo . ((calendarEventId . "event-one")))))
         (teams4e--chats (list old))
         (teams4e-meeting-context-cache-seconds 120)
         (normalized (teams4e--normalize-chats (list fresh))))
    (should (eq old (car normalized)))
    (should (equal "Fresh title" (teams4e--get old 'topic)))
    (should (eq context (teams4e--get old 'meetingContext)))
    (should (= 1 (plist-get (car teams4e--performance-events) :items)))
    (let ((changed
           '((id . "meeting-one")
             (chatType . "meeting")
             (topic . "Changed meeting")
             (onlineMeetingInfo . ((calendarEventId . "event-two"))))))
      (setq teams4e--chats normalized)
      (setq normalized (teams4e--normalize-chats (list changed)))
      (should (eq old (car normalized)))
      (should-not (teams4e--get old 'meetingContext)))))

(ert-deftest teams4e-expired-meeting-context-is-not-carried-forward ()
  (let* ((old
          `((id . "meeting-expired")
            (chatType . "meeting")
            (onlineMeetingInfo . ((calendarEventId . "event-expired")))
            (meetingContext
             . ((event . ((id . "event-expired")))
                (teams4eFetchedAt . ,(- (float-time) 121))))))
         (fresh
          '((id . "meeting-expired")
            (chatType . "meeting")
            (onlineMeetingInfo . ((calendarEventId . "event-expired")))))
         (teams4e--chats (list old))
         (teams4e-meeting-context-cache-seconds 120))
    (teams4e--normalize-chats (list fresh))
    (should-not (teams4e--get old 'meetingContext))))

(ert-deftest teams4e-explicit-refresh-discards-meeting-context ()
  (let* ((chat '((id . "meeting-refresh")
                 (meetingContext . ((event . ((id . "event-refresh")))))))
         (teams4e--chats (list chat))
         refreshed)
    (cl-letf (((symbol-function 'teams4e-recent)
               (lambda () (setq refreshed t))))
      (teams4e-recent-refresh))
    (should refreshed)
    (should-not (teams4e--get chat 'meetingContext))))

(ert-deftest teams4e-async-redraws-coalesce-on-one-timer ()
  (let ((buffer (get-buffer-create teams4e--recent-buffer-name))
        timer-callback timer-args
        (scheduled 0)
        (rendered 0))
    (unwind-protect
        (with-current-buffer buffer
          (teams4e-recent-mode)
          (cl-letf (((symbol-function 'run-with-timer)
                     (lambda (_delay _repeat callback &rest args)
                       (cl-incf scheduled)
                       (setq timer-callback callback
                             timer-args args)
                       'teams4e-test-timer))
                    ((symbol-function 'timerp)
                     (lambda (value) (eq value 'teams4e-test-timer)))
                    ((symbol-function 'teams4e--render-recent)
                     (lambda () (cl-incf rendered))))
            (teams4e--schedule-visible-recent-refresh)
            (teams4e--schedule-visible-recent-refresh)
            (should (= 1 scheduled))
            (apply timer-callback timer-args)
            (should (= 1 rendered))))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest teams4e-performance-events-omit-command-content-and-ids ()
  (let ((teams4e--performance-events nil)
        (teams4e-performance-history-size 10)
        (teams4e-use-persistent-backend nil)
        received)
    (cl-letf (((symbol-function 'teams4e--executable)
               (lambda () teams4e-test-fake-backend))
              ((symbol-function 'teams4e--run-json-once)
               (lambda (_args callback &optional _error-callback)
                 (funcall callback '(((id . "private-chat-id"))))
                 'fake-request)))
      (teams4e--run-json
       '("teams" "chat" "message" "list"
         "--chatId" "private-chat-id" "--message" "private body")
       (lambda (payload) (setq received payload))))
    (should received)
    (let ((printed (prin1-to-string teams4e--performance-events)))
      (should (string-match-p "Chat messages" printed))
      (should-not (string-match-p "private-chat-id" printed))
      (should-not (string-match-p "private body" printed)))))

(ert-deftest teams4e-delayed-mock-produces-useful-performance-timing ()
  (let* ((directory (make-temp-file "teams4e-perf-mock-" t))
         (teams4e-mock-mode t)
         (teams4e-mock-delay-ms 40)
         (teams4e-use-persistent-backend nil)
         (teams4e-mock-state-file (expand-file-name "tenant.json" directory))
         (teams4e-cache-file (expand-file-name "cache.sqlite3" directory))
         (teams4e--performance-events nil)
         chats)
    (unwind-protect
        (progn
          (teams4e-test-await
           (teams4e--run-json
            '("teams" "chat" "list")
            (lambda (payload) (setq chats payload))))
          (should (= 3 (length chats)))
          (let ((event (car teams4e--performance-events)))
            (should (equal "Live chat list"
                           (plist-get event :operation)))
            (should (= 3 (plist-get event :items)))
            (should (>= (plist-get event :duration-ms) 35.0))))
      (delete-directory directory t))))

(ert-deftest teams4e-cache-first-chat-renders-cache-then-graph ()
  (let ((chat '((id . "chat-fast")
                (lastUpdatedDateTime . "2026-08-06T09:00:00Z")))
        (cached '(((id . "cached-message")
                   (createdDateTime . "2026-08-06T08:00:00Z"))))
        (live '(((id . "live-message")
                 (createdDateTime . "2026-08-06T09:00:00Z"))))
        (teams4e-cache-first t)
        (teams4e-offline-mode nil)
        calls snapshots)
    (with-temp-buffer
      (teams4e-chat-mode)
      (setq teams4e--chat chat)
      (cl-letf (((symbol-function 'teams4e--run-json)
                 (lambda (args callback &optional _error-callback)
                   (push args calls)
                   (funcall callback
                            (if (equal (seq-take args 3)
                                       '("teams" "cache" "chat"))
                                cached live))
                   nil))
                ((symbol-function 'teams4e--render-chat)
                 (lambda ()
                   (push (mapcar (lambda (message)
                                   (teams4e--get message 'id))
                                 teams4e--messages)
                         snapshots))))
        (let ((teams4e--cache-first-open t))
          (teams4e-chat-refresh nil 75)))
      (should (equal '("teams" "cache" "chat" "message" "list")
                     (seq-take (cadr calls) 5)))
      (should (equal '("teams" "chat" "message" "list")
                     (seq-take (car calls) 4)))
      (should (equal '(("cached-message") ("live-message"))
                     (nreverse snapshots))))))

(ert-deftest teams4e-capture-markers-reparse-only-after-source-change ()
  (let* ((directory (make-temp-file "teams4e-capture-cache-" t))
         (file (expand-file-name "teams.org" directory))
         (teams4e-capture-file file)
         (teams4e--captured-chat-table
          (make-hash-table :test #'equal))
         (teams4e--captured-chat-signature nil)
         (teams4e--captured-chat-checked-at 0.0)
         (original-insert (symbol-function 'insert-file-contents))
         (reads 0))
    (unwind-protect
        (progn
          (with-temp-file file
            (insert "* One\n:PROPERTIES:\n:TEAMS_CHAT: chat-one\n:END:\n"))
          (cl-letf (((symbol-function 'insert-file-contents)
                     (lambda (filename &rest args)
                       (when (equal (expand-file-name filename) file)
                         (cl-incf reads))
                       (apply original-insert filename args))))
            (should (gethash "chat-one"
                             (teams4e--captured-chat-table)))
            (teams4e--captured-chat-table)
            (should (= 1 reads))
            (with-temp-file file
              (insert "* One\n:PROPERTIES:\n:TEAMS_CHAT: chat-one\n:END:\n"
                      "* Two\n:PROPERTIES:\n:TEAMS_CHAT: chat-two\n:END:\n"))
            (setq teams4e--captured-chat-checked-at 0.0)
            (should (gethash "chat-two"
                             (teams4e--captured-chat-table)))
            (should (= 2 reads))))
      (delete-directory directory t))))

(ert-deftest teams4e-meeting-context-waits-for-message-render ()
  (let ((chat '((id . "meeting-fast") (chatType . "meeting")))
        (teams4e-offline-mode nil)
        (renders 0))
    (with-temp-buffer
      (teams4e-chat-mode)
      (setq teams4e--chat chat)
      (cl-letf (((symbol-function 'teams4e--fetch-meeting-context)
                 (lambda (_chat callback &optional _error-callback)
                   (funcall callback '((members . nil)))
                   nil))
                ((symbol-function 'teams4e--render-chat)
                 (lambda () (cl-incf renders))))
        (teams4e--load-meeting-context chat)
        (should (= 0 renders))
        (setq teams4e--loaded-at (float-time))
        (teams4e--load-meeting-context chat)
        (should (= 1 renders))))))

(ert-deftest teams4e-org-linkage-prefers-message-then-conversation ()
  (let* ((directory (make-temp-file "teams4e-org-link-" t))
         (file (expand-file-name "teams.org" directory))
         (teams4e-capture-file file)
         buffer exact fallback)
    (unwind-protect
        (progn
          (with-temp-file file
            (insert "* Conversation\n:PROPERTIES:\n:TEAMS_CHAT: chat-1\n:END:\n"
                    "** Exact message\n:PROPERTIES:\n"
                    ":TEAMS_MESSAGE: message-2\n:END:\n"))
          (setq exact
                (teams4e--find-org-capture
                 '((chatId . "chat-1") (selectedMessageId . "message-2")))
                fallback
                (teams4e--find-org-capture
                 '((chatId . "chat-1") (selectedMessageId . "missing"))))
          (setq buffer (marker-buffer exact))
          (with-current-buffer buffer
            (goto-char exact)
            (should (equal "Exact message" (org-get-heading t t t t)))
            (goto-char fallback)
            (should (equal "Conversation" (org-get-heading t t t t)))))
      (when (buffer-live-p buffer) (kill-buffer buffer))
      (delete-directory directory t))))

(ert-deftest teams4e-structured-cards-render-without-shadow-message-data ()
  (let* ((adaptive
          `((name . "Deployment card")
            (contentType . "application/vnd.microsoft.card.adaptive")
            (content . ,(json-serialize
                         '((body
                            . [((type . "TextBlock")
                                (text . "Deploy <strong>ready</strong>"))
                               ((type . "FactSet")
                                (facts . [((title . "Owner")
                                           (value . "Ada"))]))])
                           (actions
                            . [((type . "Action.OpenUrl")
                                (title . "Open runbook")
                                (url . "https://example.test/runbook"))]))))))
         (snippet
          `((name . "Code")
            (contentType . "application/vnd.microsoft.card.codesnippet")
            (content . ,(json-serialize
                         '((language . "python")
                           (code . "print('one cache')")))))))
    (with-temp-buffer
      (teams4e--insert-attachments
       `((attachments . (,adaptive ,snippet))))
      (should (string-match-p "Deployment card" (buffer-string)))
      (should (string-match-p "Deploy ready" (buffer-string)))
      (should (string-match-p "Owner: Ada" (buffer-string)))
      (should (string-match-p "Open runbook" (buffer-string)))
      (should (string-match-p "print('one cache')" (buffer-string))))))

(ert-deftest teams4e-vtt-transcript-becomes-readable-speaker-text ()
  (let ((text (teams4e--vtt-to-text
               (concat "WEBVTT\n\n00:00:00.000 --> 00:00:03.000\n"
                       "<v Ada>Keep <strong>Graph</strong> authoritative.</v>\n\n"
                       "00:00:03.000 --> 00:00:05.000\nOne cache.\n"))))
    (should (string-match-p "Ada: Keep Graph authoritative" text))
    (should (string-match-p "One cache" text))
    (should-not (string-match-p "WEBVTT\|-->" text))))

(ert-deftest teams4e-server-search-is-explicit-and-ephemeral ()
  (let (captured)
    (cl-letf (((symbol-function 'teams4e--run-json)
               (lambda (args _callback &optional _error-callback)
                 (setq captured args)
                 'fake-request)))
      (should (eq 'fake-request (teams4e-search "one cache" t))))
    (should (equal '("teams" "search" "messages" "--query" "one cache"
                     "--limit" "100")
                   captured))
    (with-temp-buffer
      (teams4e-search-mode)
      (setq teams4e--search-query "repeat me"
            teams4e--search-server t)
      (cl-letf (((symbol-function 'teams4e-search)
                 (lambda (query server) (setq captured (list query server)))))
        (teams4e-search-refresh))
      (should (equal '("repeat me" t) captured)))))

(ert-deftest teams4e-persistent-transport-keeps-mutations-one-shot ()
  (let ((teams4e-use-persistent-backend t)
        (program "/tmp/teams4e-graph"))
    (should (teams4e--persistent-command-p
             program '("teams" "chat" "message" "list" "--chatId" "one")))
    (should (teams4e--persistent-command-p
             program '("teams" "search" "messages" "--query" "cache")))
    (should (teams4e--persistent-command-p
             program '("teams" "chat" "member" "list" "--chatId" "one")))
    (should (teams4e--persistent-command-p
             program '("teams" "meeting" "propose" "suggest"
                       "--eventId" "one")))
    (should (teams4e--persistent-command-p
             program '("teams" "meeting" "availability"
                       "--eventId" "one")))
    (should-not (teams4e--persistent-command-p
                 program '("teams" "meeting" "propose" "send"
                           "--eventId" "one")))
    (should-not (teams4e--persistent-command-p
                 program '("teams" "meeting" "respond"
                           "--eventId" "one")))
    (should-not (teams4e--persistent-command-p
                 program '("teams" "chat" "message" "send" "--message" "x")))
    (should-not (teams4e--persistent-command-p
                 program '("teams" "chat" "member" "add" "--chatId" "one")))
    (should-not (teams4e--persistent-command-p
                 program '("teams" "cache" "clear")))
    (should-not (teams4e--persistent-command-p
                 program '("teams" "attachment" "download" "--url" "x")))))

(ert-deftest teams4e-persistent-filter-tolerates-python-startup-stdout ()
  (let* ((server (make-pipe-process
                  :name "teams4e-protocol-noise-test"
                  :buffer nil
                  :noquery t))
         (teams4e--server-process server)
         (teams4e--server-fingerprint '(test))
         (teams4e--server-pending (make-hash-table :test #'eql))
         first-result second-result)
    (unwind-protect
        (progn
          (puthash
           7
           (list :request (teams4e--make-request 7)
                 :server server
                 :args '("status")
                 :callback (lambda (payload) (setq first-result payload)))
           teams4e--server-pending)
          (teams4e--server-filter
           server
           (concat "python startup banner\n"
                   "{\"id\":7,\"ok\":true,\"result\":{\"ready\":true}}\n"))
          (should (teams4e--get first-result 'ready))
          (should-not (gethash 7 teams4e--server-pending))
          (should (process-live-p server))

          (puthash
           8
           (list :request (teams4e--make-request 8)
                 :server server
                 :args '("status")
                 :callback (lambda (payload) (setq second-result payload)))
           teams4e--server-pending)
          (teams4e--server-filter
           server
           (concat "banner without newline"
                   "{\"id\":8,\"ok\":true,\"result\":\"ready\"}\n"))
          (should (equal "ready" second-result))
          (should-not (gethash 8 teams4e--server-pending))
          (should (process-live-p server)))
      (teams4e--stop-server))))

(ert-deftest teams4e-removing-pasted-image-deletes-private-temporary-file ()
  (let* ((root (make-temp-file "teams4e-clipboard-" t))
         (teams4e-draft-directory root)
         (directory (teams4e-compose--clipboard-directory))
         (path (expand-file-name "pasted.png" directory))
         (teams4e-compose--attachments (list path)))
    (unwind-protect
        (progn
          (make-directory directory t)
          (write-region "image" nil path nil 'silent)
          (cl-letf (((symbol-function 'completing-read)
                     (lambda (&rest _ignored) path))
                    ((symbol-function 'teams4e-compose--update-header)
                     #'ignore)
                    ((symbol-function 'teams4e-compose--schedule-draft)
                     #'ignore))
            (teams4e-compose-remove-attachment))
          (should-not teams4e-compose--attachments)
          (should-not (file-exists-p path)))
      (delete-directory root t))))

;;; teams4e-tests.el ends here
