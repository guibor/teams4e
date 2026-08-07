;;; msteams-tests.el --- Tests for the msteams package. -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)

(defconst msteams-test-directory
  (file-name-directory (or load-file-name buffer-file-name)))
(defconst msteams-test-layer-directory
  (file-name-directory (directory-file-name msteams-test-directory)))
(defconst msteams-test-fake-backend
  (expand-file-name "fake-msteams" msteams-test-directory))

(add-to-list 'load-path msteams-test-layer-directory)
(require 'msteams)

(defun msteams-test-read-json (name)
  "Read fixture NAME using the production JSON representation."
  (json-parse-string
   (with-temp-buffer
     (insert-file-contents
      (expand-file-name (concat "fixtures/" name) msteams-test-directory))
     (buffer-string))
   :object-type 'alist
   :array-type 'list
   :null-object nil
   :false-object nil))

(defun msteams-test-await (request)
  "Wait for asynchronous REQUEST and return after its callback has run."
  (let ((deadline (+ (float-time) 5)))
    (while (and (msteams--request-live-p request)
                (< (float-time) deadline))
      (accept-process-output nil 0.05))
    (should-not (msteams--request-live-p request))
    (accept-process-output nil 0.05)))

(ert-deftest msteams-payload-list-distinguishes-arrays-and-objects ()
  (let ((chats (msteams-test-read-json "chats.json"))
        (status (msteams-test-read-json "status.json")))
    (should (= 2 (length (msteams--payload-list chats))))
    (should (= 1 (length (msteams--payload-list status))))
    (should (equal "default" (msteams--get status 'connectionName)))))

(ert-deftest msteams-logged-out-status-is-valid-json-without-account ()
  (let ((msteams--connected-as "stale@example.com") result)
    (cl-letf (((symbol-function 'msteams--run-json)
               (lambda (_args callback &optional _error-callback)
                 (funcall callback "Logged out") 'fake-process)))
      (should (eq 'fake-process
                  (msteams--status-request (lambda (status)
                                              (setq result status)))))
      (should (equal "Logged out" result))
      (should-not msteams--connected-as))))

(ert-deftest msteams-html-message-rendering-removes-markup ()
  (let* ((messages (msteams-test-read-json "messages-chat-1.json"))
         (body (msteams--message-body (car messages))))
    (should (string-match-p "Hello Michael" body))
    (should (string-match-p "review is ready" body))
    (should-not (string-match-p "<strong>" body))))

(ert-deftest msteams-system-events-render-useful-meeting-summaries ()
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
                   (msteams--message-body started)))
    (should (equal "Meeting ended (1h 2m 3s)"
                   (msteams--message-body ended)))
    (with-temp-buffer
      (let ((msteams-display-images nil))
        (msteams--insert-message started))
      (should (string-match-p "Meeting started by Ada Lovelace"
                              (buffer-string)))
      (should-not (string-match-p "\\[No text\\]" (buffer-string))))))

(ert-deftest msteams-relative-hosted-images-resolve-and-render-a-fallback ()
  (let* ((directory (make-temp-file "msteams-image-cache-" t))
         (msteams-image-cache-directory directory)
         (msteams-display-images t)
         (msteams-offline-mode t)
         (msteams--chat '((id . "19:chat@thread.v2")))
         (message
          '((id . "message-42")
            (createdDateTime . "2026-08-02T12:00:00Z")
            (from . ((user . ((displayName . "Ada")))))
            (body
             . ((contentType . "html")
                (content
                 . "<p><img src=\"../hostedContents/image-id/$value\" alt=\"diagram\"></p>")))))
         (images (msteams--inline-images message))
         (url (msteams--get (car images) 'contentUrl)))
    (unwind-protect
        (progn
          (should (= 1 (length images)))
          (should
           (equal
            (format
             (concat "https://graph.microsoft.com/v1.0/chats/%s/messages/"
                     "message-42/hostedContents/image-id/$value")
             (msteams--graph-segment "19:chat@thread.v2"))
            url))
          (with-temp-buffer
            (msteams--insert-message message)
            (should (string-match-p "Image not cached: diagram-1.png"
                                    (buffer-string)))
            (should-not (string-match-p "\\[No text\\]" (buffer-string)))))
      (delete-directory directory t))))

(ert-deftest msteams-image-message-downloads-through-the-mock-backend ()
  (let* ((directory (make-temp-file "msteams-image-download-" t))
         (source (expand-file-name "pixel.gif" directory))
         (cache (expand-file-name "cache" directory))
         (state (expand-file-name "tenant.json" directory))
         (buffer (generate-new-buffer " *Teams image test*"))
         (msteams-mock-mode t)
         (msteams-mock-state-file state)
         (msteams-image-cache-directory cache)
         (msteams-display-images t)
         (msteams-offline-mode nil)
         process)
    (unwind-protect
        (progn
          (with-temp-file source
            (set-buffer-multibyte nil)
            (insert (base64-decode-string
                     "R0lGODlhAQABAIAAAAAAAP///ywAAAAAAQABAAACAUwAOw==")))
          (with-current-buffer buffer
            (msteams--insert-message
             `((id . "image-message")
               (createdDateTime . "2026-08-02T12:00:00Z")
               (from . ((user . ((displayName . "Ada")))))
               (body . ((contentType . "text") (content . "Screenshot")))
               (attachments
                . (((id . "pixel")
                    (name . "pixel.gif")
                    (contentType . "image/gif")
                    (contentUrl . ,(concat "file://" source)))))))
            (setq process (car msteams--image-processes)))
          (should (processp process))
          (msteams-test-await process)
          (with-current-buffer buffer
            (should (string-match-p "Image: pixel.gif" (buffer-string)))
            (should-not (string-match-p "Loading image" (buffer-string))))
          (should (= 1 (length (directory-files cache nil "\\.gif\\'")))))
      (when (buffer-live-p buffer) (kill-buffer buffer))
      (delete-directory directory t))))

(ert-deftest msteams-image-download-queue-is-concurrency-bounded ()
  (let ((directory (make-temp-file "msteams-image-queue-" t))
        (msteams-image-download-concurrency 2)
        (started 0))
    (unwind-protect
        (with-temp-buffer
          (setq-local msteams-image-cache-directory directory)
          (cl-letf (((symbol-function 'msteams--run-json)
                     (lambda (_args _callback &optional _error-callback)
                       (cl-incf started)
                       nil)))
            (dotimes (index 4)
              (msteams--queue-image
               `((name . ,(format "image-%d.png" index))
                 (contentType . "image/png")
                 (contentUrl . ,(format "file:///tmp/image-%d.png" index)))
               (copy-marker (point-min))
               (format "image-%d" index))))
          (should (= 2 started))
          (should (= 2 msteams--image-active))
          (should (= 2 (length msteams--image-queue))))
      (delete-directory directory t))))

(ert-deftest msteams-quoted-reply-renders-context-not-an-attachment ()
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
      (msteams--insert-message-reference message)
      (msteams--insert-attachments message)
      (should (string-match-p "> Ada" (buffer-string)))
      (should (string-match-p "Original context" (buffer-string)))
      (should-not (string-match-p "Attachment:" (buffer-string))))))

(ert-deftest msteams-chat-label-excludes-connected-account ()
  (let* ((chats (msteams-test-read-json "chats.json"))
         (members (msteams-test-read-json "members-chat-1.json"))
         (msteams--connected-as "user@example.com")
         (msteams--member-cache (make-hash-table :test #'equal)))
    (puthash "chat-1" members msteams--member-cache)
    (should (equal "Ada Lovelace" (msteams--chat-label (car chats))))
    (should (equal "Project Atlas" (msteams--chat-label (cadr chats))))))

(ert-deftest msteams-chat-label-excludes-connected-user-by-id ()
  (let* ((chat '((id . "direct") (chatType . "oneOnOne")))
         (members '(((displayName . "Alex Smith") (userId . "self-id"))
                    ((displayName . "Alex Smith") (userId . "other-id"))))
         (msteams--connected-as nil)
         (msteams--connected-user-id "self-id")
         (msteams--member-cache (make-hash-table :test #'equal)))
    (puthash "direct" members msteams--member-cache)
    (should (= 1 (length (msteams--member-names chat))))
    (should (equal "Alex Smith" (msteams--chat-label chat)))))

(ert-deftest msteams-fake-backend-status-and-chat-list ()
  (let ((msteams-backend-program msteams-test-fake-backend)
        (msteams--connected-as nil)
        status-result
        chats-result)
    (msteams-test-await
     (msteams--status-request (lambda (status) (setq status-result status))))
    (should (equal "user@example.com"
                   (msteams--get status-result 'connectedAs)))
    (msteams-test-await
     (msteams--load-chats (lambda (chats) (setq chats-result chats))))
    (should (= 2 (length chats-result)))
    (should (equal "chat-1" (msteams--chat-id (car chats-result))))))

(ert-deftest msteams-send-preserves-multiline-message-as-one-argument ()
  (let* ((msteams-backend-program msteams-test-fake-backend)
         (log (make-temp-file "msteams-send-"))
         (process-environment (copy-sequence process-environment))
         (message-text "Line one\nLine two; $(not-a-shell)"))
    (unwind-protect
        (progn
          (setenv "MSTEAMS_TEST_LOG" log)
          (msteams-test-await
           (msteams--run
            (msteams--send-args
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

(ert-deftest msteams-send-args-support-direct-email ()
  (should
   (equal
    '("teams" "chat" "message" "send"
      "--userEmails" "ada@example.com"
      "--message" "Hello" "--contentType" "text" "--output" "none")
    (msteams--send-args
     '(:user-emails "ada@example.com" :label "Ada") "Hello"))))

(ert-deftest msteams-reply-args-preserve-target-message-id ()
  (should
   (equal
    '("teams" "chat" "message" "send"
      "--chatId" "chat-1" "--replyToId" "message-1"
      "--message" "Reply" "--contentType" "text" "--output" "none")
    (msteams--send-args
     '((id . "chat-1") (topic . "Ada")) "Reply" '((id . "message-1"))))))

(ert-deftest msteams-read-override-expires-when-new-message-arrives ()
  (let* ((chat (car (msteams-test-read-json "chats.json")))
         (msteams--read-overrides (make-hash-table :test #'equal)))
    (puthash "chat-1" '(read . "2026-08-02T07:30:00Z")
             msteams--read-overrides)
    (should-not (msteams--unread-p chat))
    (setf (alist-get 'lastUpdatedDateTime chat) "2026-08-02T08:00:00Z")
    (should (msteams--unread-p chat))
    (should-not (gethash "chat-1" msteams--read-overrides))))

(ert-deftest msteams-favorites-and-mutes-round-trip-private-local-state ()
  (let* ((directory (make-temp-file "msteams-state-" t))
         (msteams-state-file (expand-file-name "teams.json" directory))
         (msteams--favorites (make-hash-table :test #'equal))
         (msteams--muted (make-hash-table :test #'equal))
         (msteams--state-loaded t))
    (unwind-protect
        (progn
          (puthash "chat-1" t msteams--favorites)
          (puthash "chat-2" t msteams--muted)
          (msteams--save-state)
          (should (= #o600 (file-modes msteams-state-file)))
          (setq msteams--state-loaded nil
                msteams--favorites (make-hash-table :test #'equal)
                msteams--muted (make-hash-table :test #'equal))
          (msteams--load-state)
          (should (gethash "chat-1" msteams--favorites))
          (should (gethash "chat-2" msteams--muted)))
      (delete-directory directory t))))

(ert-deftest msteams-mark-read-uses-explicit-graph-command ()
  (let* ((msteams-backend-program msteams-test-fake-backend)
         (log (make-temp-file "msteams-read-"))
         (process-environment (copy-sequence process-environment))
         (msteams--read-overrides (make-hash-table :test #'equal))
         process)
    (unwind-protect
        (with-temp-buffer
          (msteams-chat-mode)
          (setq msteams--chat
                '((id . "chat-1")
                  (topic . "Ada")
                  (lastUpdatedDateTime . "2026-08-02T07:30:00Z")))
          (setenv "MSTEAMS_TEST_LOG" log)
          (setq process (msteams--set-read-state 'read t))
          (msteams-test-await process)
          (let ((args (json-parse-string
                       (with-temp-buffer
                         (insert-file-contents log)
                         (buffer-string))
                       :array-type 'list)))
            (should (equal '("teams" "chat" "mark" "read" "--chatId" "chat-1")
                           (seq-take args 6))))
          (should (eq 'read
                      (car (gethash "chat-1"
                                    msteams--read-overrides)))))
      (delete-file log))))

(ert-deftest msteams-error-diagnostics-redact-message-body ()
  (should
   (equal '("teams" "send" "--message" "<message redacted>" "--debug")
          (msteams--redacted-args
           '("teams" "send" "--message" "private body" "--debug"))))
  (should
   (equal "Graph rejected <message redacted> for policy"
          (msteams--redacted-detail
           '("--message" "private body")
           "Graph rejected private body for policy"))))

(ert-deftest msteams-resolves-configured-graph-backend ()
  (let ((msteams-backend-program msteams-test-fake-backend))
    (should (equal msteams-test-fake-backend (msteams--executable)))))

(ert-deftest msteams-transcript-renders-message-properties ()
  (let* ((chat (car (msteams-test-read-json "chats.json")))
         (messages (msteams-test-read-json "messages-chat-1.json"))
         (msteams--connected-user-id "current-user-id"))
    (with-temp-buffer
      (msteams-chat-mode)
      (setq msteams--chat chat
            msteams--messages messages)
      (msteams--render-chat)
      (should (string-match-p "Ada Lovelace" (buffer-string)))
      (should (string-match-p "You" (buffer-string)))
      (should (string-match-p "review.pdf" (buffer-string)))
      (goto-char (point-min))
      (msteams-chat-next-message)
      (should (equal "message-1"
                     (msteams--get (msteams-message-at-point) 'id)))
      (msteams-chat-next-message)
      (should (equal "message-2"
                     (msteams--get (msteams-message-at-point) 'id)))
      (forward-line 1)
      (msteams-chat-previous-message)
      (should (equal "message-1"
                     (msteams--get (msteams-message-at-point) 'id))))))

(ert-deftest msteams-message-navigation-treats-buffer-edges-as-outside-messages ()
  (let* ((chat (car (msteams-test-read-json "chats.json")))
         (messages (msteams-test-read-json "messages-chat-1.json"))
         (msteams--connected-user-id "current-user-id"))
    (with-temp-buffer
      (msteams-chat-mode)
      (setq msteams--chat chat
            msteams--messages messages)
      (msteams--render-chat)
      (should (equal "message-2"
                     (msteams--get (msteams-message-at-point) 'id)))
      (goto-char (point-min))
      (msteams-chat-next-message)
      (should (equal "message-1"
                     (msteams--get (msteams-message-at-point) 'id))))))

(ert-deftest msteams-explicit-chat-open-renders-at-buffer-bottom-once ()
  (let* ((chat (car (msteams-test-read-json "chats.json")))
         (messages (msteams-test-read-json "messages-chat-1.json"))
         (msteams--connected-user-id "current-user-id"))
    (with-temp-buffer
      (msteams-chat-mode)
      (setq msteams--chat chat
            msteams--messages messages
            msteams--jump-to-bottom-on-render t)
      (msteams--render-chat)
      (should (= (point) (point-max)))
      (should-not msteams--jump-to-bottom-on-render)
      (should-not (get-text-property (point) 'msteams-message))
      (msteams-chat-previous-message)
      (should (equal "message-2"
                     (msteams--get
                      (msteams-message-at-point) 'id))))))

(ert-deftest msteams-opening-thread-respects-read-policy ()
  (let* ((chat '((id . "chat-policy") (topic . "Policy test")))
         (buffer-name msteams--preview-buffer-name)
         (msteams-mark-read-on-open nil)
         marked)
    (unwind-protect
        (cl-letf (((symbol-function 'msteams-chat-refresh) #'ignore)
                  ((symbol-function 'msteams--display-chat-buffer) #'ignore)
                  ((symbol-function 'msteams--set-read-state)
                   (lambda (state &optional _quiet) (setq marked state))))
          (msteams-open-chat chat t)
          (should-not marked)
          (with-current-buffer buffer-name
            (should-not msteams--jump-to-bottom-on-render))
          (setq msteams-mark-read-on-open t)
          (msteams-open-chat chat t)
          (should (eq 'read marked))
          (msteams-open-chat chat)
          (with-current-buffer buffer-name
            (should msteams--jump-to-bottom-on-render)))
      (when-let ((buffer (get-buffer buffer-name))) (kill-buffer buffer)))))

(ert-deftest msteams-thread-preview-keeps-inbox-focus ()
  (let ((index (get-buffer-create msteams--recent-buffer-name))
        (thread (generate-new-buffer " *Teams preview test*"))
        (msteams-index-width 0.46))
    (unwind-protect
        (save-window-excursion
          (delete-other-windows)
          (switch-to-buffer index)
          (let ((index-window (selected-window)))
            (msteams--display-chat-buffer thread t)
            (should (eq index-window (selected-window)))
            (should (get-buffer-window thread))
            (msteams--display-chat-buffer thread nil)
            (should (eq thread (window-buffer (selected-window))))))
      (when (buffer-live-p index) (kill-buffer index))
      (when (buffer-live-p thread) (kill-buffer thread)))))

(ert-deftest msteams-reopen-inbox-preserves-buffer-request-state ()
  (let ((buffer (get-buffer-create msteams--recent-buffer-name)))
    (unwind-protect
        (progn
          (with-current-buffer buffer
            (msteams-recent-mode)
            (setq msteams--request-id 41))
          (save-current-buffer
            (cl-letf (((symbol-function 'pop-to-buffer)
                       (lambda (target &rest _args) (set-buffer target)))
                      ((symbol-function 'msteams--with-status)
                       (lambda (_callback) nil)))
              (msteams-recent)))
          (with-current-buffer buffer
            (should (= 41 msteams--request-id))))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest msteams-reopen-channel-preserves-buffer-request-state ()
  (let* ((team '((id . "team-1") (displayName . "Engineering")))
         (channel '((id . "channel-1") (displayName . "General")))
         (buffer
          (get-buffer-create
           (msteams--channel-index-buffer-name team channel)))
         refreshed)
    (unwind-protect
        (progn
          (with-current-buffer buffer
            (msteams-channel-index-mode)
            (setq msteams-channel--request-id 41))
          (save-current-buffer
            (cl-letf (((symbol-function 'pop-to-buffer)
                       (lambda (target &rest _args) (set-buffer target)))
                      ((symbol-function 'msteams-channel-refresh)
                       (lambda () (setq refreshed t))))
              (msteams-open-channel team channel)))
          (should refreshed)
          (with-current-buffer buffer
            (should (= 41 msteams-channel--request-id))))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest msteams-chat-selection-callback-uses-initiating-buffer ()
  (let ((origin (generate-new-buffer " *Teams select origin*"))
        (transport (generate-new-buffer " *Teams select transport*"))
        observed)
    (unwind-protect
        (progn
          (with-current-buffer origin
            (cl-letf (((symbol-function 'msteams--with-status)
                       (lambda (callback)
                         (with-current-buffer transport (funcall callback))))
                      ((symbol-function 'msteams--load-chats)
                       (lambda (callback &optional _error-callback)
                         (with-current-buffer transport
                           (funcall callback '(((id . "chat-1")))))))
                      ((symbol-function 'msteams--choose-chat)
                       (lambda (chats callback)
                         (with-current-buffer transport
                           (funcall callback (car chats))))))
              (msteams--select-chat
               (lambda (_chat) (setq observed (current-buffer))))))
          (should (eq origin observed)))
      (when (buffer-live-p origin) (kill-buffer origin))
      (when (buffer-live-p transport) (kill-buffer transport)))))

(ert-deftest msteams-markdown-export-preserves-structure-and-source ()
  (let* ((chat (car (msteams-test-read-json "chats.json")))
         (messages (msteams-test-read-json "messages-chat-1.json"))
         (markdown (msteams--thread-markdown chat messages)))
    (should (string-match-p "# One-to-one chat" markdown))
    (should (string-match-p "## 2026-08-02" markdown))
    (should (string-match-p (regexp-quote "Hello **Michael**") markdown))
    (should (string-match-p
             (regexp-quote "[review.pdf](https://example.com/review.pdf)")
             markdown))
    (should (string-match-p "Reactions: like 2" markdown))
    (should (string-match-p "Teams chat ID: `chat-1`" markdown))))

(ert-deftest msteams-html-to-markdown-collapses-excess-blank-lines ()
  (should
   (equal "One\n\nTwo"
          (msteams--html-to-markdown
           "<p>One</p><br><br><p>Two</p>"))))

(ert-deftest msteams-export-requests-unbounded-history ()
  (let ((msteams-message-days 30)
        (msteams-message-limit 300)
        (chat '((id . "chat-1"))))
    (should (member "--modifiedStartDateTime"
                    (msteams--message-args chat nil)))
    (should (equal "300"
                   (cadr (member "--limit"
                                 (msteams--message-args chat nil)))))
    (should (equal "75"
                   (cadr (member "--limit"
                                 (msteams--message-args
                                  chat nil 75)))))
    (should-not (member "--modifiedStartDateTime"
                        (msteams--message-args chat t)))
    (should-not (member "--limit"
                        (msteams--message-args chat t)))))

(ert-deftest msteams-incremental-history-keeps-limit-and-removes-date-window ()
  (let* ((msteams-message-days 30)
         (chat '((id . "chat-1")))
         (args (msteams--message-args chat nil 600 t)))
    (should (equal "600" (cadr (member "--limit" args))))
    (should-not (member "--modifiedStartDateTime" args))))

(ert-deftest msteams-message-display-order-does-not-mutate-chronology ()
  (let* ((older '((id . "older")
                  (createdDateTime . "2026-08-01T09:00:00Z")))
         (newer '((id . "newer")
                  (createdDateTime . "2026-08-01T10:00:00Z")))
         (messages (list older newer))
         (msteams-message-order 'oldest-first))
    (with-temp-buffer
      (should (equal '("older" "newer")
                     (mapcar (lambda (message)
                               (msteams--get message 'id))
                             (msteams--messages-for-display
                              messages))))
      (setq-local msteams--message-order 'newest-first)
      (should (equal '("newer" "older")
                     (mapcar (lambda (message)
                               (msteams--get message 'id))
                             (msteams--messages-for-display
                              messages))))
      (should (equal '("older" "newer")
                     (mapcar (lambda (message)
                               (msteams--get message 'id))
                             messages))))))

(ert-deftest msteams-message-normalization-uses-absolute-time-and-stable-ties ()
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
         (normalized (msteams--normalize-messages messages)))
    (should
     (equal '("same-a" "same-b" "middle" "duplicate")
            (mapcar (lambda (message) (msteams--get message 'id))
                    normalized)))
    (should
     (equal "fresh"
            (msteams--dig (car (last normalized)) 'body 'content)))))

(ert-deftest msteams-message-order-toggle-rerenders-and-preserves-selection ()
  (let ((chat (car (msteams-test-read-json "chats.json")))
        (messages (msteams-test-read-json "messages-chat-1.json"))
        (msteams-message-order 'oldest-first)
        (msteams-display-images nil))
    (with-temp-buffer
      (msteams-chat-mode)
      (setq msteams--chat chat
            msteams--messages messages)
      (msteams--render-chat)
      (should (msteams--goto-message-id "message-1"))
      (msteams-toggle-message-order)
      (should (equal "message-1"
                     (msteams--get
                      (msteams-message-at-point) 'id)))
      (should (equal '("message-2" "message-1")
                     (mapcar
                      (lambda (position)
                        (msteams--get
                         (get-text-property position 'msteams-message) 'id))
                      (msteams--message-positions))))
      (should (string-match-p "newest first" header-line-format)))))

(ert-deftest msteams-complete-refresh-does-not-trim-rendered-history ()
  (let ((msteams-message-limit 2)
        (messages
         '(((id . "one") (createdDateTime . "2026-08-01T09:00:00Z"))
           ((id . "two") (createdDateTime . "2026-08-01T10:00:00Z"))
           ((id . "three") (createdDateTime . "2026-08-01T11:00:00Z")))))
    (with-temp-buffer
      (msteams-chat-mode)
      (setq msteams--chat '((id . "chat-1")))
      (cl-letf (((symbol-function 'msteams--run-json)
                 (lambda (_args callback &optional _error-callback)
                   (funcall callback messages)
                   'fake-process))
                ((symbol-function 'msteams--render-chat) #'ignore))
        (msteams-chat-refresh t))
      (should (= 3 (length msteams--messages)))
      (should msteams--loaded-all))))

(ert-deftest msteams-load-more-expands-bound-beyond-date-window ()
  (let ((msteams-load-more-count 300)
        observed)
    (with-temp-buffer
      (msteams-chat-mode)
      (setq msteams--messages '(((id . "one")) ((id . "two"))))
      (cl-letf (((symbol-function 'msteams-chat-refresh)
                 (lambda (&optional all limit ignore-date)
                   (setq observed (list all limit ignore-date)))))
        (msteams-chat-load-more))
      (should (equal '(nil 302 t) observed))
      (setq msteams--loaded-all t)
      (should-error (msteams-chat-load-more) :type 'user-error))))

(ert-deftest msteams-export-writes-private-markdown-file ()
  (let* ((directory (make-temp-file "msteams-export-" t))
         (path (expand-file-name "nested/thread.md" directory))
         (chat (car (msteams-test-read-json "chats.json")))
         (messages (msteams-test-read-json "messages-chat-1.json")))
    (unwind-protect
        (progn
          (should (equal path
                         (msteams--write-thread-export
                          path chat messages)))
          (should (= #o600 (file-modes path)))
          (with-temp-buffer
            (insert-file-contents path)
            (should (search-forward "# One-to-one chat" nil t))
            (should (search-forward "review.pdf" nil t))))
      (delete-directory directory t))))

(ert-deftest msteams-copy-thread-fetches-complete-chronological-markdown ()
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
         captured-markdown)
    (cl-letf (((symbol-function 'msteams--run-json)
               (lambda (args callback &optional _error-callback)
                 (setq captured-args args)
                 (funcall callback (list newer older))
                 'fake-process))
              ((symbol-function 'kill-new)
               (lambda (text &optional _replace)
                 (setq captured-markdown text))))
      (msteams--copy-chat-thread-markdown chat))
    (should-not (member "--limit" captured-args))
    (should-not (member "--modifiedStartDateTime" captured-args))
    (should (< (string-match "First" captured-markdown)
               (string-match "Second" captured-markdown)))))

(ert-deftest msteams-thread-analysis-exports-full-chat-before-first-prompt ()
  (let* ((directory (make-temp-file "msteams-agent-thread-" t))
         (path (expand-file-name "thread.md" directory))
         (chat '((id . "chat-agent") (topic . "Agent analysis")))
         (messages '(((id . "message-agent")
                      (createdDateTime . "2026-08-06T10:00:00Z")
                      (from . ((user . ((displayName . "Ada")))))
                      (body . ((contentType . "text")
                               (content . "Analyze this"))))))
         (config '((:identifier . cursor)))
         request-args start-args insert-args start-directory)
    (unwind-protect
        (cl-letf (((symbol-function 'msteams--chat-at-point)
                   (lambda () chat))
                  ((symbol-function
                    'msteams--thread-analysis-agent-config)
                   (lambda () config))
                  ((symbol-function 'msteams--export-path)
                   (lambda (_chat) path))
                  ((symbol-function 'msteams--run-json)
                   (lambda (args callback &optional _error-callback)
                     (setq request-args args)
                     (funcall callback messages)
                     'fake-process))
                  ((symbol-function 'agent-shell-start)
                   (lambda (&rest args)
                     (setq start-args args
                           start-directory default-directory)
                     'agent-buffer))
                  ((symbol-function 'agent-shell-insert)
                   (lambda (&rest args)
                     (setq insert-args args))))
          (msteams-analyze-current-thread)
          (should (file-exists-p path))
          (should (= #o600 (file-modes path)))
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

(ert-deftest msteams-thread-analysis-resolves-the-customized-agent-symbol ()
  (let ((msteams-thread-analysis-agent 'cursor)
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
              (msteams--thread-analysis-agent-config)))
      (should (eq 'cursor observed)))))

(ert-deftest msteams-capture-appends-org-entry-with-source-properties ()
  (let* ((directory (make-temp-file "msteams-capture-" t))
         (file (expand-file-name "inbox/teams.org" directory))
         (chat (car (msteams-test-read-json "chats.json")))
         (message (car (msteams-test-read-json "messages-chat-1.json")))
         marker)
    (unwind-protect
        (progn
          (setq marker (msteams--capture-entry chat message file))
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

(ert-deftest msteams-thread-org-capture-preserves-conversation-metadata ()
  (let* ((chat (car (msteams-test-read-json "chats.json")))
         (messages (msteams-test-read-json "messages-chat-1.json"))
         (context
          (msteams--chat-capture-context chat (car messages)))
         (entry (msteams--thread-org-entry context messages)))
    (should (string-match-p "\\* Teams: One-to-one chat" entry))
    (should (string-match-p ":TEAMS_CHAT: chat-1" entry))
    (should (string-match-p ":TEAMS_TYPE: Direct" entry))
    (should (string-match-p ":TEAMS_MESSAGE: message-1" entry))
    (should (string-match-p "Open selected item in Microsoft Teams" entry))
    (should (string-match-p "Ada Lovelace" entry))
    (should (string-match-p "Michael-David Fiszer" entry))
    (should (string-match-p "review.pdf" entry))))

(ert-deftest msteams-summary-capture-is-compact-and-actionable ()
  (let* ((chat (car (msteams-test-read-json "chats.json")))
         (message (car (msteams-test-read-json "messages-chat-1.json")))
         (context (msteams--chat-capture-context chat message))
         (entry (msteams--summary-org-entry context message)))
    (should (string-match-p "\\* Teams: One-to-one chat" entry))
    (should (string-match-p ":TEAMS_CHAT: chat-1" entry))
    (should (string-match-p ":TEAMS_MESSAGE: message-1" entry))
    (should (string-match-p "Open in Microsoft Teams" entry))
    (should (string-match-p "Last activity" entry))
    (should (string-match-p "\\*\\* Last message" entry))
    (should (string-match-p "Hello Michael" entry))
    (should-not (string-match-p "Transcript" entry))
    (should-not (string-match-p "Michael-David Fiszer" entry))))

(ert-deftest msteams-thread-capture-uses-editable-org-capture-target ()
  (require 'org-capture)
  (let* ((directory (make-temp-file "msteams-thread-capture-" t))
         (file (expand-file-name "inbox/teams.org" directory))
         (msteams-capture-file file)
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
          (msteams--start-thread-org-capture context messages)
          (should (equal "T" captured-key))
          (should (string-match-p "Architecture review" captured-string))
          (should (equal `(file ,file)
                         (nth 3 (car captured-templates))))
          (should (equal "%i\n%?" (nth 4 (car captured-templates)))))
      (delete-directory directory t))))

(ert-deftest msteams-channel-capture-context-includes-team-and-thread ()
  (let* ((team '((id . "team-1") (displayName . "Engineering")))
         (channel '((id . "channel-1") (displayName . "General")))
         (root '((id . "root-1")
                 (webUrl . "https://teams.microsoft.com/l/message/root-1")
                 (subject . "Architecture review")
                 (createdDateTime . "2026-08-02T10:00:00Z")))
         (context
          (msteams--channel-capture-context
           team channel root root))
         (entry (msteams--thread-org-entry context (list root))))
    (should (string-match-p ":TEAMS_TEAM_ID: team-1" entry))
    (should (string-match-p ":TEAMS_TEAM: Engineering" entry))
    (should (string-match-p ":TEAMS_CHANNEL_ID: channel-1" entry))
    (should (string-match-p ":TEAMS_CHANNEL: General" entry))
    (should (string-match-p ":TEAMS_THREAD: root-1" entry))
    (should (string-match-p "Architecture review" entry))))

(ert-deftest msteams-app-url-uses-native-protocol-handler ()
  (should
   (equal
    "msteams://teams.microsoft.com/l/message/chat-1/message-1"
    (msteams--app-url
     "https://teams.microsoft.com/l/message/chat-1/message-1")))
  (should
   (equal "msteams://teams.microsoft.com/l/chat/chat-1/0"
          (msteams--app-url
           "msteams://teams.microsoft.com/l/chat/chat-1/0")))
  (should-error (msteams--app-url "https://example.com/chat")
                :type 'user-error))

(ert-deftest msteams-browser-url-bypasses-desktop-launcher ()
  (should
   (equal
    "https://teams.microsoft.com/#/l/chat/chat-1/0?tenantId=tenant-1"
    (msteams--browser-url
     "https://teams.microsoft.com/l/chat/chat-1/0?tenantId=tenant-1")))
  (should
   (equal
    "https://teams.cloud.microsoft/#/l/message/chat-1/message-1"
    (msteams--browser-url
     "https://teams.cloud.microsoft/l/message/chat-1/message-1")))
  (should
   (equal
    "https://teams.microsoft.com/#/l/chat/already-routed"
    (msteams--browser-url
     "https://teams.microsoft.com/#/l/chat/already-routed"))))

(ert-deftest msteams-open-commands-use-configured-argv ()
  (let ((msteams-browser-command '("browser-program" "--new-window"))
        (msteams-app-command '("open"))
        commands)
    (cl-letf (((symbol-function 'make-process)
               (lambda (&rest properties)
                 (push (plist-get properties :command) commands)
                 'fake-process)))
      (msteams--open-url-in-browser
       "https://teams.microsoft.com/l/chat/chat-1/0")
      (msteams--open-url-in-app
       "https://teams.cloud.microsoft/l/chat/chat-1/0"))
    (should
     (equal
      '(("open" "msteams://teams.cloud.microsoft/l/chat/chat-1/0")
        ("browser-program" "--new-window"
         "https://teams.microsoft.com/#/l/chat/chat-1/0"))
      commands))))

(ert-deftest msteams-short-command-aliases-exist ()
  (dolist (command '(teams teams-inbox teams-chat teams-recent teams-send
                     teams-export-thread teams-copy-thread-markdown
                     teams-analyze-thread
                     teams-capture-action teams-capture-message
                     teams-capture-thread teams-unread-filter))
    (should (commandp command))))

(ert-deftest msteams-public-export-and-capture-aliases-are-context-aware ()
  (should (eq (indirect-function 'teams-export-thread)
              (indirect-function 'msteams-export-current-thread)))
  (should (eq (indirect-function 'teams-copy-thread-markdown)
              (indirect-function
               'msteams-copy-current-thread-markdown)))
  (should (eq (indirect-function 'teams-analyze-thread)
              (indirect-function
               'msteams-analyze-current-thread)))
  (should (eq (indirect-function 'teams-capture-message)
              (indirect-function 'msteams-capture-current-message)))
  (should (eq (indirect-function 'teams-capture-action)
              (indirect-function 'msteams-capture-current-summary)))
  (should (eq (indirect-function 'teams-capture-thread)
              (indirect-function 'msteams-capture-current-thread))))

(ert-deftest msteams-advanced-command-aliases-exist ()
  (dolist (command '(teams-channels teams-search teams-bookmark teams-filter
                     teams-bulk-action teams-close-inactive teams-sync
                     teams-user teams-create-chat teams-dispatch
                     teams-server-search teams-drafts teams-meeting-transcript
                     teams-handle teams-snooze teams-clear-triage
                     teams-jump-capture))
    (should (commandp command))))

(ert-deftest msteams-channel-send-args-preserve-rich-metadata ()
  (should
   (equal
    '("teams" "channel" "message" "send"
      "--teamId" "team-1" "--channelId" "channel-1"
      "--replyToId" "root-1"
      "--message" "Hello @Ada" "--contentType" "html"
      "--attachment" "/tmp/report.pdf"
      "--mention" "ada-id|Ada"
      "--output" "none")
    (msteams--send-args
     '(:team-id "team-1" :channel-id "channel-1" :label "General")
     "Hello @Ada"
     '((id . "root-1"))
     '("/tmp/report.pdf")
     '("ada-id|Ada")
     "html"))))

(ert-deftest msteams-offline-args-use-credential-free-cache ()
  (let ((msteams-offline-mode t)
        (msteams-message-limit 42))
    (should
     (equal '("teams" "cache" "chat" "message" "list"
              "--chatId" "chat-1" "--limit" "42")
            (msteams--message-args '((id . "chat-1")))))
    (should
     (equal '("teams" "cache" "chat" "message" "list"
              "--chatId" "chat-1" "--limit" "1000000")
            (msteams--message-args '((id . "chat-1")) t)))))

(ert-deftest msteams-batch-history-keeps-newest-inverse-first ()
  (let* ((older (list :kind 'read :chat-id "older"))
         (newer (list :kind 'unread :chat-id "newer"))
         (existing (list :kind 'favorite :chat-id "existing"))
         (msteams--action-history (list existing)))
    (msteams--record-completed-actions (list newer older))
    (should (eq newer (nth 0 msteams--action-history)))
    (should (eq older (nth 1 msteams--action-history)))
    (should (eq existing (nth 2 msteams--action-history)))))

(ert-deftest msteams-partial-sync-uses-failure-callback-and-no-success-time ()
  (let ((msteams-offline-mode nil)
        (msteams--last-sync nil)
        succeeded failed)
    (cl-letf (((symbol-function 'msteams--run-json)
               (lambda (_args callback &optional _error-callback)
                 (funcall callback
                          '((errors . (((resource . "chat:1")
                                        (error . "retry me"))))))
                 'fake-process)))
      (msteams-sync
       nil
       (lambda (_payload) (setq succeeded t))
       (lambda (status detail) (setq failed (cons status detail)))))
    (should-not succeeded)
    (should-not msteams--last-sync)
    (should (equal "partial" (car failed)))
    (should (string-match-p "retry me" (cdr failed)))
    (should (string-match-p "partial" msteams--mode-line))))

(ert-deftest msteams-saved-search-views-round-trip-with-favorites ()
  (let* ((directory (make-temp-file "msteams-views-" t))
         (msteams-state-file (expand-file-name "state.json" directory))
         (msteams--favorites (make-hash-table :test #'equal))
         (msteams--saved-views (make-hash-table :test #'equal))
         (msteams--state-loaded t))
    (unwind-protect
        (progn
          (puthash "chat-1" t msteams--favorites)
          (puthash "Urgent" "release blocker" msteams--saved-views)
          (msteams--save-state)
          (setq msteams--state-loaded nil
                msteams--favorites (make-hash-table :test #'equal)
                msteams--saved-views (make-hash-table :test #'equal))
          (msteams--load-state)
          (should (gethash "chat-1" msteams--favorites))
          (should (equal "release blocker"
                         (gethash "Urgent" msteams--saved-views))))
      (delete-directory directory t))))

(ert-deftest msteams-cache-search-opens-complete-chat-at-message ()
  (let ((message
         '((id . "old-message")
           (cacheContext . ((scopeKind . "chat") (scopeId . "chat-1")))))
        captured)
    (with-temp-buffer
      (msteams-search-mode)
      (setq tabulated-list-entries
            (list (list message ["date" "sender" "chat" "body"])))
      (tabulated-list-print t)
      (goto-char (point-min))
      (cl-letf (((symbol-function 'msteams-open-chat)
                 (lambda (&rest args) (setq captured args))))
        (msteams-search-open)))
    (should (equal "chat-1"
                   (msteams--chat-id (nth 0 captured))))
    (should-not (nth 1 captured))
    (should (eq t (nth 2 captured)))
    (should (equal "old-message" (nth 3 captured)))))

(ert-deftest msteams-built-in-inbox-views-filter-chat-types-and-unread ()
  (let* ((chats (msteams-test-read-json "chats.json"))
         (msteams--read-overrides (make-hash-table :test #'equal))
         (msteams--favorites (make-hash-table :test #'equal))
         (msteams--state-loaded t))
    (let ((msteams--active-view 'direct))
      (should (msteams--view-chat-p (car chats)))
      (should-not (msteams--view-chat-p (cadr chats))))
    (let ((msteams--active-view 'group))
      (should-not (msteams--view-chat-p (car chats)))
      (should (msteams--view-chat-p (cadr chats))))
    (puthash "chat-1" t msteams--favorites)
    (let ((msteams--active-view 'favorites))
      (should (msteams--view-chat-p (car chats))))))

(ert-deftest msteams-upcoming-meetings-use-calendar-status-and-start-order ()
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
                     (msteams--built-in-view-chat-p chat 'upcoming))
                   (list later cancelled sooner))))
    (should (equal '("sooner" "later")
                   (mapcar #'msteams--chat-id
                           (sort visible
                                 #'msteams--meeting-starts-before-p))))
    (should (eq 'upcoming
                (plist-get
                 (seq-find (lambda (bookmark)
                             (eq (plist-get bookmark :key) ?m))
                           msteams-bookmarks)
                 :query)))
    (should (equal "type:meeting"
                   (plist-get
                    (seq-find (lambda (bookmark)
                                (eq (plist-get bookmark :key) ?M))
                              msteams-bookmarks)
                    :query)))))

(ert-deftest msteams-relevant-inbox-excludes-hidden-and-locally-muted-chats ()
  (let* ((visible '((id . "visible") (chatType . "group")))
         (hidden '((id . "hidden")
                   (chatType . "group")
                   (viewpoint . ((isHidden . t)))))
         (local-mute '((id . "local-mute") (chatType . "group")))
         (msteams--muted (make-hash-table :test #'equal))
         (msteams--state-loaded t))
    (puthash "local-mute" t msteams--muted)
    (should (msteams--built-in-view-chat-p visible 'inbox))
    (should-not (msteams--built-in-view-chat-p hidden 'inbox))
    (should-not (msteams--built-in-view-chat-p local-mute 'inbox))
    (should (msteams--built-in-view-chat-p hidden 'all))
    (should (msteams--built-in-view-chat-p local-mute 'muted))
    (should (msteams--query-chat-p hidden "muted"))
    (should (msteams--query-chat-p visible "-muted"))
    (should (eq 'inbox
                (plist-get
                 (seq-find (lambda (bookmark)
                             (eq (plist-get bookmark :key) ?i))
                           msteams-bookmarks)
                 :query)))
    (should (eq 'all
                (plist-get
                 (seq-find (lambda (bookmark)
                             (eq (plist-get bookmark :key) ?a))
                           msteams-bookmarks)
                 :query)))))

(ert-deftest msteams-inbox-and-all-bookmarks-switch-the-visible-row-set ()
  (let* ((visible '((id . "visible") (chatType . "group")))
         (hidden '((id . "hidden")
                   (chatType . "group")
                   (viewpoint . ((isHidden . t)))))
         (local-mute '((id . "local-mute") (chatType . "group")))
         (msteams--chats (list visible hidden local-mute))
         (msteams--muted (make-hash-table :test #'equal))
         (msteams--favorites (make-hash-table :test #'equal))
         (msteams--marks (make-hash-table :test #'equal))
         (msteams--selections (make-hash-table :test #'equal))
         (msteams--read-overrides (make-hash-table :test #'equal))
         (msteams--state-loaded t)
         (msteams--active-view 'all)
         (msteams--active-query nil)
         (msteams--active-filter-name nil))
    (puthash "local-mute" t msteams--muted)
    (with-temp-buffer
      (msteams-recent-mode)
      (cl-letf (((symbol-function 'read-char) (lambda (&rest _args) ?i)))
        (msteams-bookmark-jump))
      (should (eq 'inbox msteams--active-query))
      (should (= 1 (length tabulated-list-entries)))
      (cl-letf (((symbol-function 'read-char) (lambda (&rest _args) ?a)))
        (msteams-bookmark-jump))
      (should (eq 'all msteams--active-query))
      (should (= 3 (length tabulated-list-entries))))))

(ert-deftest msteams-unread-filter-composes-with-active-query ()
  (let* ((chats (msteams-test-read-json "chats.json"))
         (direct (car chats))
         (group (cadr chats))
         (msteams--active-view 'all)
         (msteams--active-query "type:group")
         (msteams--active-filter-name "Groups")
         (msteams--unread-filter-enabled nil)
         (msteams--read-overrides (make-hash-table :test #'equal)))
    (should-not (msteams--view-chat-p direct))
    (should (msteams--view-chat-p group))
    (setq msteams--unread-filter-enabled t)
    (should-not (msteams--view-chat-p direct))
    (should-not (msteams--view-chat-p group))
    (should (equal "Groups + unread only"
                   (msteams--active-filter-label)))
    (should (equal "type:group" msteams--active-query))))

(ert-deftest msteams-inbox-bookmark-query-combines-terms-and-negation ()
  (let* ((chats (msteams-test-read-json "chats.json"))
         (direct (car chats))
         (group (cadr chats))
         (msteams--read-overrides (make-hash-table :test #'equal))
         (msteams--favorites (make-hash-table :test #'equal))
         (msteams--state-loaded t))
    (should (msteams--query-chat-p direct "unread type:direct"))
    (should (msteams--query-chat-p group
                                          "name:\"Project Atlas\" -unread"))
    (should-not (msteams--query-chat-p group "type:direct"))
    (puthash "chat-1" t msteams--favorites)
    (should (msteams--query-chat-p direct "favorite"))
    (should-not (msteams--query-chat-p direct "-favorite"))))

(ert-deftest msteams-bookmark-shortcut-filters-the-headers-buffer ()
  (let ((msteams-bookmarks
         '((:name "Unread" :query "unread" :key ?u)))
        (msteams--chats (msteams-test-read-json "chats.json"))
        (msteams--active-view 'all)
        (msteams--active-query nil)
        (msteams--active-filter-name nil)
        (msteams--marks (make-hash-table :test #'equal))
        (msteams--read-overrides (make-hash-table :test #'equal))
        (msteams--favorites (make-hash-table :test #'equal))
        (msteams--state-loaded t))
    (with-temp-buffer
      (msteams-recent-mode)
      (cl-letf (((symbol-function 'read-char) (lambda (&rest _args) ?u)))
        (msteams-bookmark-jump))
      (should (equal "unread" msteams--active-query))
      (should (equal "Unread" msteams--active-filter-name))
      (should (= 1 (length tabulated-list-entries))))))

(ert-deftest msteams-headers-map-combines-mu4e-and-tui-actions ()
  (dolist (binding
           '(("n" . msteams-recent-next)
             ("p" . msteams-recent-previous)
             ("]" . msteams-recent-next-unread)
             ("[" . msteams-recent-previous-unread)
             ("!" . msteams-mark-read-later)
             ("i" . msteams-mark-read-later)
             ("I" . msteams-mark-read-later)
             ("?" . msteams-mark-unread-later)
             ("u" . msteams-unmark)
             ("U" . msteams-unmark-all)
             ("M" . msteams-toggle-selection)
             ("T" . msteams-toggle-visible-selections)
             ("X" . msteams-bulk-action)
             ("b" . msteams-bookmark-jump)
             ("B" . msteams-bookmark-edit)
             ("c" . msteams-send)
             ("C" . msteams-send)
             ("r" . msteams-mark-read-later)
             ("R" . msteams-reply)
             ("f" . msteams-message-forward)
             ("F" . msteams-message-forward)
             ("*" . msteams-toggle-favorite)
             ("o" . msteams-open-in-browser)
             ("O" . msteams-open-in-app)
             ("E" . msteams-export-thread)
             ("Y" . msteams-copy-thread-markdown)
             ("S" . msteams-sort)
             ("q" . msteams-quit)
             ("H" . msteams-dispatch)))
    (should (eq (lookup-key msteams-recent-mode-map
                            (kbd (car binding)))
                (cdr binding))))
  (should (keymapp (lookup-key msteams-recent-mode-map (kbd "a"))))
  (dolist (binding
           '(("a a" . msteams-capture-current-summary)
             ("a A" . msteams-capture-current-thread)
             ("a j" . msteams-jump-to-capture)
             ("a t" . msteams-meeting-transcript)
             ("a R" . msteams-action-reply)
             ("a i" . msteams-mark-read)
             ("a u" . msteams-mark-unread)
             ("a *" . msteams-toggle-favorite)
             ("a m" . msteams-toggle-muted)
             ("a s" . msteams-snooze)
             ("a k" . msteams-clear-triage)
             ("a e" . msteams-export-current-thread)
             ("a y" . msteams-copy-current-thread-markdown)
             ("a g" . msteams-analyze-current-thread)))
    (should (eq (lookup-key msteams-recent-mode-map
                            (kbd (car binding)))
                (cdr binding))))
  (should-not (lookup-key msteams-recent-mode-map (kbd "a h")))
  (should-not (lookup-key msteams-recent-mode-map (kbd "w"))))

(ert-deftest msteams-refile-mark-uses-existing-handled-state-and-is-undoable ()
  (let* ((directory (make-temp-file "msteams-refile-" t))
         (msteams-state-file (expand-file-name "teams-state.json" directory))
         (chat '((id . "chat-refile")
                 (lastMessagePreview . ((id . "message-1")))))
         (msteams--chats (list chat))
         (msteams--marks (make-hash-table :test #'equal))
         (msteams--favorites (make-hash-table :test #'equal))
         (msteams--muted (make-hash-table :test #'equal))
         (msteams--handled (make-hash-table :test #'equal))
         (msteams--snoozed (make-hash-table :test #'equal))
         (msteams--saved-views (make-hash-table :test #'equal))
         (msteams--state-loaded t)
         (msteams--action-history nil))
    (unwind-protect
        (progn
          (puthash "chat-refile" 'refile msteams--marks)
          (cl-letf (((symbol-function 'msteams--refresh-visible-recent)
                     #'ignore))
            (msteams--execute-mark-list
             '(("chat-refile" . refile)) nil)
            (should (msteams--handled-p chat))
            (should-not (gethash "chat-refile" msteams--marks))
            (should (eq 'triage
                        (plist-get (car msteams--action-history) :kind)))
            (msteams-undo-action)
            (should-not (msteams--handled-p chat))))
      (delete-directory directory t))))

(ert-deftest msteams-headers-reply-uses-selected-latest-message ()
  (let* ((chat (car (msteams-test-read-json "chats.json")))
         (msteams--chats (list chat))
         (msteams--active-view 'all)
         (msteams--active-query nil)
         (msteams--active-filter-name nil)
         (msteams--marks (make-hash-table :test #'equal))
         (msteams--read-overrides (make-hash-table :test #'equal))
         (msteams--favorites (make-hash-table :test #'equal))
         (msteams--state-loaded t)
         captured)
    (with-temp-buffer
      (msteams-recent-mode)
      (msteams--render-recent)
      (goto-char (point-min))
      (cl-letf (((symbol-function 'msteams--open-compose)
                 (lambda (target &optional reply-to _initial)
                   (setq captured (list target reply-to)))))
        (msteams-reply))
      (should (equal chat (car captured)))
      (should (equal (msteams--get chat 'lastMessagePreview)
                     (cadr captured))))))

(ert-deftest msteams-headers-forward-uses-selected-latest-message ()
  (let* ((chat (car (msteams-test-read-json "chats.json")))
         (msteams--chats (list chat))
         (msteams--active-view 'all)
         (msteams--active-query nil)
         (msteams--active-filter-name nil)
         (msteams--marks (make-hash-table :test #'equal))
         (msteams--read-overrides (make-hash-table :test #'equal))
         (msteams--favorites (make-hash-table :test #'equal))
         (msteams--state-loaded t)
         callback captured)
    (with-temp-buffer
      (msteams-recent-mode)
      (msteams--render-recent)
      (goto-char (point-min))
      (cl-letf (((symbol-function 'msteams--select-chat)
                 (lambda (fn) (setq callback fn))))
        (msteams-message-forward))
      (should (functionp callback))
      (cl-letf (((symbol-function 'msteams--open-compose)
                 (lambda (target &optional reply-to initial)
                   (setq captured (list target reply-to initial)))))
        (funcall callback '((id . "destination"))))
      (should (equal "destination"
                     (msteams--get (car captured) 'id)))
      (should-not (cadr captured))
      (should (string-match-p "Forwarded from" (caddr captured)))
      (should (string-match-p
               (regexp-quote
                (msteams--message-body
                 (msteams--get chat 'lastMessagePreview)))
               (caddr captured))))))

(ert-deftest msteams-chat-selection-supports-one-row-and-visible-set ()
  (let* ((msteams--chats (msteams-test-read-json "chats.json"))
         (msteams--active-view 'all)
         (msteams--active-query nil)
         (msteams--active-filter-name nil)
         (msteams--unread-filter-enabled nil)
         (msteams--selections (make-hash-table :test #'equal))
         (msteams--marks (make-hash-table :test #'equal))
         (msteams--favorites (make-hash-table :test #'equal))
         (msteams--read-overrides (make-hash-table :test #'equal))
         (msteams--state-loaded t)
         (msteams-preview-on-move nil))
    (with-temp-buffer
      (msteams-recent-mode)
      (msteams--render-recent)
      (let ((first-id (tabulated-list-get-id)))
        (msteams-toggle-selection)
        (should (gethash first-id msteams--selections))
        (should (equal "+"
                       (substring-no-properties
                        (aref (cadr (assoc first-id tabulated-list-entries))
                              0)))))
      (msteams-toggle-visible-selections)
      (should (= (length msteams--chats)
                 (hash-table-count msteams--selections)))
      (should (string-match-p "2 selected" header-line-format))
      (msteams-toggle-visible-selections)
      (should (= 0 (hash-table-count msteams--selections))))))

(ert-deftest msteams-bulk-action-queues-only-selected-chats ()
  (let* ((msteams--chats (msteams-test-read-json "chats.json"))
         (msteams--selections (make-hash-table :test #'equal))
         (msteams--marks (make-hash-table :test #'equal))
         (msteams-confirm-apply nil)
         (msteams-offline-mode nil)
         executed)
    (dolist (chat msteams--chats)
      (puthash (msteams--chat-id chat) t
               msteams--selections))
    (with-temp-buffer
      (msteams-recent-mode)
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (&rest _args) "Mark unread"))
                ((symbol-function 'yes-or-no-p)
                 (lambda (&rest _args)
                   (ert-fail "Bulk apply unexpectedly requested confirmation")))
                ((symbol-function 'msteams--render-recent) #'ignore)
                ((symbol-function 'msteams--execute-mark-list)
                 (lambda (items completed)
                   (setq executed (list items completed)))))
        (msteams-bulk-action)))
    (should (= 0 (hash-table-count msteams--selections)))
    (should (= 2 (hash-table-count msteams--marks)))
    (should (seq-every-p (lambda (item) (eq (cdr item) 'unread))
                         (car executed)))
    (should-not (cadr executed))))

(ert-deftest msteams-execute-marks-skips-confirmation-by-default ()
  (let ((msteams--marks (make-hash-table :test #'equal))
        (msteams-confirm-apply nil)
        (msteams-offline-mode nil)
        executed)
    (puthash "chat-1" 'favorite-on msteams--marks)
    (cl-letf (((symbol-function 'yes-or-no-p)
               (lambda (&rest _args)
                 (ert-fail "Deferred apply unexpectedly requested confirmation")))
              ((symbol-function 'msteams--execute-mark-list)
               (lambda (items completed)
                 (setq executed (list items completed)))))
      (msteams-execute-marks))
    (should (equal '(("chat-1" . favorite-on)) (car executed)))
    (should-not (cadr executed))))

(ert-deftest msteams-execute-marks-honors-opt-in-confirmation ()
  (let ((msteams--marks (make-hash-table :test #'equal))
        (msteams-confirm-apply t)
        (msteams-offline-mode nil)
        prompted
        executed)
    (puthash "chat-1" 'read msteams--marks)
    (cl-letf (((symbol-function 'yes-or-no-p)
               (lambda (&rest _args)
                 (setq prompted t)
                 nil))
              ((symbol-function 'msteams--execute-mark-list)
               (lambda (&rest _args) (setq executed t))))
      (msteams-execute-marks))
    (should prompted)
    (should-not executed)))

(ert-deftest msteams-bulk-favorite-actions-have-explicit-target-state ()
  (let* ((chat (car (msteams-test-read-json "chats.json")))
         (chat-id (msteams--chat-id chat))
         (msteams--chats (list chat))
         (msteams--marks (make-hash-table :test #'equal))
         (msteams--favorites (make-hash-table :test #'equal))
         (msteams--action-history nil))
    (cl-letf (((symbol-function 'msteams--save-state) #'ignore)
              ((symbol-function 'msteams--refresh-visible-recent)
               #'ignore))
      (puthash chat-id 'favorite-on msteams--marks)
      (msteams--execute-mark-list
       (list (cons chat-id 'favorite-on)) nil)
      (should (gethash chat-id msteams--favorites))
      (should-not (plist-get (car msteams--action-history) :enabled))
      (setq msteams--action-history nil)
      (puthash chat-id 'favorite-off msteams--marks)
      (msteams--execute-mark-list
       (list (cons chat-id 'favorite-off)) nil)
      (should-not (gethash chat-id msteams--favorites))
      (should (plist-get (car msteams--action-history) :enabled)))))

(ert-deftest msteams-transcript-maps-use-shared-actions-and-local-navigation ()
  (dolist (map-and-bindings
           `((,msteams-chat-mode-map
              ("j" . msteams-thread-next)
              ("k" . msteams-thread-previous)
              ("M-j" . msteams-chat-next-message)
              ("M-k" . msteams-chat-previous-message)
              ("R" . msteams-reply)
              ("F" . msteams-message-forward)
              ("c" . msteams-send)
              ("C" . msteams-send)
              ("i" . msteams-chat-run-headers-command)
              ("I" . msteams-chat-run-headers-command)
              ("n" . msteams-chat-run-headers-command)
              ("p" . msteams-chat-run-headers-command)
              ("]" . msteams-chat-run-headers-command)
              ("[" . msteams-chat-run-headers-command)
              ("!" . msteams-chat-run-headers-command)
              ("?" . msteams-chat-run-headers-command)
              ("r" . msteams-chat-run-headers-command)
              ("f" . msteams-chat-run-headers-command)
              ("M" . msteams-chat-run-headers-command)
              ("T" . msteams-chat-run-headers-command)
              ("X" . msteams-chat-run-headers-command)
              ("u" . msteams-chat-run-headers-command)
              ("U" . msteams-chat-run-headers-command)
              ("x" . msteams-chat-run-headers-command)
              ("q" . msteams-chat-view-quit)
              ("o" . msteams-open-in-browser)
              ("O" . msteams-open-in-app)
              ("L" . msteams-chat-load-more)
              ("S" . msteams-chat-run-headers-command)
              ("M-S" . msteams-toggle-message-order)
              ("Y" . msteams-copy-current-thread-markdown)
              ("M-w" . msteams-capture-message))
             (,msteams-channel-index-mode-map
              ("q" . msteams-quit)
              ("o" . msteams-open-current-in-browser)
              ("O" . msteams-open-current-in-app)
              ("E" . msteams-channel-export-thread)
              ("Y" . msteams-copy-current-thread-markdown))
             (,msteams-channel-thread-mode-map
              ("j" . msteams-channel-thread-next)
              ("k" . msteams-channel-thread-previous)
              ("M-j" . msteams-chat-next-message)
              ("M-k" . msteams-chat-previous-message)
              ("R" . msteams-channel-reply)
              ("F" . msteams-message-forward)
              ("M-a" . msteams-attachment-download)
              ("c" . msteams-channel-compose)
              ("C" . msteams-channel-compose)
              ("q" . msteams-channel-view-quit)
              ("o" . msteams-open-current-in-browser)
              ("O" . msteams-open-current-in-app)
              ("S" . msteams-toggle-message-order)
              ("Y" . msteams-copy-current-thread-markdown))))
    (let ((map (car map-and-bindings)))
      (dolist (binding (cdr map-and-bindings))
        (should (eq (lookup-key map (kbd (car binding)))
                    (cdr binding))))
      (should (keymapp (lookup-key map (kbd "a"))))
      (should (eq (lookup-key map (kbd "a a"))
                  #'msteams-capture-current-summary))
      (should (eq (lookup-key map (kbd "a A"))
                  #'msteams-capture-current-thread))
      (should-not (lookup-key map (kbd "w")))
      (should-not (lookup-key map (kbd "W"))))))

(ert-deftest msteams-lowercase-r-marks-read-and-never-replies ()
  (should (eq (lookup-key msteams-recent-mode-map (kbd "r"))
              #'msteams-mark-read-later))
  (should (eq (lookup-key msteams-mark-map (kbd "r"))
              #'msteams-mark-read-later))
  (should (eq (lookup-key msteams-chat-mode-map (kbd "r"))
              #'msteams-chat-run-headers-command))
  (should-not (lookup-key msteams-channel-thread-mode-map (kbd "r")))
  (should-not (lookup-key msteams-action-map (kbd "r")))
  (should (eq (lookup-key msteams-action-map (kbd "R"))
              #'msteams-action-reply)))

(ert-deftest msteams-chat-reader-mirrors-the-complete-headers-key-set ()
  (dolist (key msteams--chat-header-mirror-keys)
    (should (eq (lookup-key msteams-chat-mode-map (kbd key))
                #'msteams-chat-run-headers-command)))
  (dolist (key '("m i" "m r" "m u" "m *" "m SPC"))
    (should (eq (lookup-key msteams-chat-mode-map (kbd key))
                #'msteams-chat-run-headers-command))))

(ert-deftest msteams-unread-face-is-bold-without-warning-color ()
  (should (eq 'bold
              (face-attribute 'msteams-unread :weight nil 'default)))
  (should (equal "unspecified-fg"
                 (face-attribute 'msteams-unread
                                 :foreground nil 'default)))
  (should-not (face-attribute 'msteams-unread :inherit nil 'default)))

(ert-deftest msteams-headers-start-with-status-then-aligned-date-type-and-name ()
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
             . ((messageType . "systemEventMessage")
                (eventDetail
                 . ((@odata.type
                     . "#microsoft.graph.callStartedEventMessageDetail")
                    (callEventType . "meeting")))))))
         (msteams--marks (make-hash-table :test #'equal))
         (msteams--selections (make-hash-table :test #'equal))
         (msteams--favorites (make-hash-table :test #'equal))
         (msteams--read-overrides (make-hash-table :test #'equal))
         (msteams-status-style 'symbols)
         (msteams--state-loaded t)
         (columns (cadr (msteams--recent-entry-advanced chat))))
    (should (equal '("Status" "Updated" "Type" "Conversation" "Meeting"
                     "Star" "Last message")
                   (mapcar #'car
                           (append msteams--recent-format nil))))
    (should (equal "" (aref columns 0)))
    (should (string-prefix-p "2026-08-02"
                             (substring-no-properties (aref columns 1))))
    (should (equal "Meeting" (substring-no-properties (aref columns 2))))
    (should (equal "Architecture review"
                   (substring-no-properties (aref columns 3))))
    (should (string-match-p "Aug 10.*Video room 4"
                            (substring-no-properties (aref columns 4))))
    (should (equal "" (aref columns 5)))
    (puthash "chat-header" 'refile msteams--marks)
    (setq columns (cadr (msteams--recent-entry-advanced chat)))
    (should (equal "↦" (substring-no-properties (aref columns 0))))
    (should-not (string-match-p "!" (mapconcat #'substring-no-properties
                                                (append columns nil) " ")))
    (should (memq 'msteams-type-meeting
                  (get-text-property 0 'face (aref columns 2))))
    (should (memq 'msteams-unread
                  (get-text-property 0 'face (aref columns 3))))
    (should (string-match-p "Meeting started"
                            (substring-no-properties (aref columns 6))))
    (with-temp-buffer
      (tabulated-list-mode)
      (setq tabulated-list-format [("Old" 1 nil)])
      (msteams--configure-recent-format)
      (should (equal msteams--recent-format
                     tabulated-list-format)))))

(ert-deftest msteams-status-column-has-sober-symbol-and-letter-styles ()
  (should (eq 'symbols (default-value 'msteams-status-style)))
  (let ((msteams-status-style 'symbols))
    (should (equal "↦" (substring-no-properties
                         (msteams--status-token 'refile))))
    (should (equal "≡" (substring-no-properties
                         (msteams--status-token 'captured))))
    (should (equal "Queued: refile until a new message"
                   (get-text-property
                    0 'help-echo (msteams--status-token 'refile)))))
  (let ((msteams-status-style 'letters))
    (should (equal "r" (substring-no-properties
                         (msteams--status-token 'refile))))
    (should (equal "c" (substring-no-properties
                         (msteams--status-token 'captured))))))

(ert-deftest msteams-send-confirmation-is-disabled-by-default ()
  (should-not (default-value 'msteams-confirm-send)))

(ert-deftest msteams-apply-confirmation-is-disabled-by-default ()
  (should-not (default-value 'msteams-confirm-apply)))

(ert-deftest msteams-inbox-preview-on-move-is-disabled-by-default ()
  (should-not (default-value 'msteams-preview-on-move)))

(ert-deftest msteams-inbox-preview-scheduling-is-explicitly-opt-in ()
  (let ((msteams-preview-on-move nil)
        (msteams-preview-delay 0.25)
        scheduled)
    (with-temp-buffer
      (insert (propertize "row" 'tabulated-list-id "chat-preview"))
      (goto-char (point-min))
      (setq-local msteams--preview-timer nil)
      (cl-letf (((symbol-function 'run-with-idle-timer)
                 (lambda (&rest _args)
                   (setq scheduled t)
                   'fake-preview-timer)))
        (msteams--schedule-preview)
        (should-not scheduled)
        (setq msteams-preview-on-move t)
        (msteams--schedule-preview)
        (should scheduled)))))

(ert-deftest msteams-quit-never-deletes-a-spaceclient-frame ()
  (let ((msteams--window-configurations
         (make-hash-table :test #'eq))
        deleted buried)
    (cl-letf (((symbol-function 'selected-frame) (lambda () 'teams-frame))
              ((symbol-function 'selected-window) (lambda () 'teams-window))
              ((symbol-function 'window-parent) (lambda (_window) nil))
              ((symbol-function 'msteams--cancel-frame-preview-timers)
               #'ignore)
              ((symbol-function 'delete-frame)
               (lambda (frame) (setq deleted frame)))
              ((symbol-function 'bury-buffer)
               (lambda (&rest _args) (setq buried t))))
      (msteams-quit))
    (should-not deleted)
    (should buried)))

(ert-deftest msteams-reader-quit-closes-only-the-message-pane ()
  (let ((index (get-buffer-create msteams--recent-buffer-name))
        (reader (get-buffer-create msteams--read-buffer-name))
        deleted-frame)
    (unwind-protect
        (save-window-excursion
          (delete-other-windows)
          (switch-to-buffer index)
          (msteams-recent-mode)
          (select-window (split-window-right))
          (switch-to-buffer reader)
          (msteams-chat-mode)
          (cl-letf (((symbol-function 'delete-frame)
                     (lambda (&rest _args) (setq deleted-frame t))))
            (msteams-chat-view-quit))
          (should-not deleted-frame)
          (should-not (buffer-live-p reader))
          (should (eq (current-buffer) index))
          (should (one-window-p t)))
      (when (buffer-live-p index) (kill-buffer index))
      (when (buffer-live-p reader) (kill-buffer reader)))))

(ert-deftest msteams-tabulated-neighbor-navigation-follows-visible-rows ()
  (with-temp-buffer
    (tabulated-list-mode)
    (setq tabulated-list-format [("Chat" 20 nil)]
          tabulated-list-entries '(("chat-1" ["First"])
                                   ("chat-2" ["Second"])))
    (tabulated-list-init-header)
    (tabulated-list-print)
    (should (equal "chat-2"
                   (msteams--tabulated-neighbor-id "chat-1" 1)))
    (should (equal "chat-1"
                   (msteams--tabulated-neighbor-id "chat-2" -1)))))

(ert-deftest msteams-reader-runs-commands-in-linked-headers-context ()
  (let* ((first '((id . "chat-reader-1") (topic . "First")))
         (second '((id . "chat-reader-2") (topic . "Second")))
         (msteams--chats (list first second))
         (index (get-buffer-create msteams--recent-buffer-name))
         (reader (get-buffer-create msteams--read-buffer-name))
         opened selected-window-after)
    (unwind-protect
        (save-window-excursion
          (delete-other-windows)
          (switch-to-buffer index)
          (msteams-recent-mode)
          (setq tabulated-list-entries
                (mapcar #'msteams--recent-entry
                        msteams--chats))
          (tabulated-list-print)
          (msteams--recent-goto-chat-id "chat-reader-1")
          (let ((reader-window (split-window-right)))
            (select-window reader-window)
            (switch-to-buffer reader)
            (msteams-chat-mode)
            (setq msteams--chat first)
            (cl-letf (((symbol-function 'msteams-open-chat)
                       (lambda (chat &rest _args) (setq opened chat))))
              (msteams-chat-run-headers-command
               #'msteams-recent-next))
            (setq selected-window-after (selected-window))
            (should (eq selected-window-after reader-window))))
          (with-current-buffer index
            (should (equal "chat-reader-2" (tabulated-list-get-id))))
          (should (equal "chat-reader-2"
                         (msteams--chat-id opened))))
      (when (buffer-live-p index) (kill-buffer index))
      (when (buffer-live-p reader) (kill-buffer reader))))

(ert-deftest msteams-visible-reader-follows-headers-movement ()
  (let* ((first '((id . "chat-follow-1") (topic . "First")))
         (second '((id . "chat-follow-2") (topic . "Second")))
         (msteams--chats (list first second))
         (msteams-preview-on-move nil)
         (index (get-buffer-create msteams--recent-buffer-name))
         (reader (get-buffer-create msteams--read-buffer-name))
         opened open-args)
    (unwind-protect
        (save-window-excursion
          (delete-other-windows)
          (switch-to-buffer index)
          (msteams-recent-mode)
          (setq tabulated-list-entries
                (mapcar #'msteams--recent-entry
                        msteams--chats))
          (tabulated-list-print)
          (msteams--recent-goto-chat-id "chat-follow-1")
          (let ((index-window (selected-window))
                (reader-window (split-window-right)))
            (with-selected-window reader-window
              (switch-to-buffer reader)
              (msteams-chat-mode)
              (setq msteams--chat first))
            (cl-letf (((symbol-function 'msteams-open-chat)
                       (lambda (chat &rest args)
                         (setq opened chat
                               open-args args)
                         (with-current-buffer reader
                           (setq msteams--chat chat)))))
              (msteams-recent-next))
            (should (eq index-window (selected-window)))
            (should (equal "chat-follow-2" (tabulated-list-get-id)))
            (should (equal "chat-follow-2"
                           (msteams--chat-id opened)))
            (should (equal '(t) open-args))))
      (when (buffer-live-p index) (kill-buffer index))
      (when (buffer-live-p reader) (kill-buffer reader)))))

(ert-deftest msteams-reader-navigation-moves-visible-headers-selection ()
  (let* ((first '((id . "chat-reader-follow-1") (topic . "First")))
         (second '((id . "chat-reader-follow-2") (topic . "Second")))
         (msteams--chats (list first second))
         (index (get-buffer-create msteams--recent-buffer-name))
         (reader (get-buffer-create msteams--read-buffer-name))
         opened)
    (unwind-protect
        (save-window-excursion
          (delete-other-windows)
          (switch-to-buffer index)
          (msteams-recent-mode)
          (setq tabulated-list-entries
                (mapcar #'msteams--recent-entry
                        msteams--chats))
          (tabulated-list-print)
          (msteams--recent-goto-chat-id "chat-reader-follow-1")
          (let ((index-window (selected-window))
                (reader-window (split-window-right)))
            (select-window reader-window)
            (switch-to-buffer reader)
            (msteams-chat-mode)
            (setq msteams--chat first)
            (cl-letf (((symbol-function 'msteams-open-chat)
                       (lambda (chat &rest _args)
                         (setq opened chat)
                         (setq msteams--chat chat))))
              (msteams-thread-next))
            (should (eq reader-window (selected-window)))
            (with-selected-window index-window
              (should (equal "chat-reader-follow-2"
                             (tabulated-list-get-id))))
            (should (equal "chat-reader-follow-2"
                           (msteams--chat-id opened)))))
      (when (buffer-live-p index) (kill-buffer index))
      (when (buffer-live-p reader) (kill-buffer reader)))))

(ert-deftest msteams-filter-rerender-replaces-mismatched-visible-reader ()
  (let* ((first '((id . "chat-filter-follow-1") (topic . "First")))
         (second '((id . "chat-filter-follow-2") (topic . "Second")))
         (msteams--chats (list first second))
         (msteams--active-view 'all)
         (msteams--active-query nil)
         (index (get-buffer-create msteams--recent-buffer-name))
         (reader (get-buffer-create msteams--read-buffer-name))
         opened)
    (unwind-protect
        (save-window-excursion
          (delete-other-windows)
          (switch-to-buffer index)
          (msteams-recent-mode)
          (msteams--render-recent)
          (msteams--recent-goto-chat-id "chat-filter-follow-1")
          (let ((reader-window (split-window-right)))
            (with-selected-window reader-window
              (switch-to-buffer reader)
              (msteams-chat-mode)
              (setq msteams--chat first))
            (setq msteams--active-query
                  (lambda (chat)
                    (equal "chat-filter-follow-2"
                           (msteams--chat-id chat))))
            (cl-letf (((symbol-function 'msteams-open-chat)
                       (lambda (chat &rest _args)
                         (setq opened chat)
                         (with-current-buffer reader
                           (setq msteams--chat chat)))))
              (msteams--render-recent))
            (should (equal "chat-filter-follow-2" (tabulated-list-get-id)))
            (should (equal "chat-filter-follow-2"
                           (msteams--chat-id opened)))))
      (when (buffer-live-p index) (kill-buffer index))
      (when (buffer-live-p reader) (kill-buffer reader)))))

(ert-deftest msteams-reader-filter-with-no-rows-clears-stale-thread ()
  (let* ((chat '((id . "chat-filter-empty") (topic . "Only chat")))
         (msteams--chats (list chat))
         (msteams--active-view 'all)
         (msteams--active-query nil)
         (index (get-buffer-create msteams--recent-buffer-name))
         (reader (get-buffer-create msteams--read-buffer-name)))
    (unwind-protect
        (save-window-excursion
          (delete-other-windows)
          (switch-to-buffer index)
          (msteams-recent-mode)
          (msteams--render-recent)
          (let ((reader-window (split-window-right)))
            (select-window reader-window)
            (switch-to-buffer reader)
            (msteams-chat-mode)
            (setq msteams--chat chat)
            (cl-letf (((symbol-function 'msteams-test-empty-chat-filter)
                       (lambda ()
                         (interactive)
                         (setq msteams--active-query
                               (lambda (_candidate) nil))
                         (msteams--render-recent))))
              (msteams-chat-run-headers-command
               #'msteams-test-empty-chat-filter))
            (should-not msteams--chat)
            (should (string-match-p "No chats match"
                                    (buffer-string)))))
      (when (buffer-live-p index) (kill-buffer index))
      (when (buffer-live-p reader) (kill-buffer reader)))))

(ert-deftest msteams-stale-chat-response-cannot-overwrite-reused-reader ()
  (let (first-callback second-callback rendered)
    (with-temp-buffer
      (cl-letf (((symbol-function 'msteams--run-json)
                 (lambda (_args callback &optional _error-callback)
                   (if first-callback
                       (setq second-callback callback)
                     (setq first-callback callback))
                   nil))
                ((symbol-function 'msteams--render-chat)
                 (lambda () (setq rendered msteams--messages))))
        (msteams-chat-mode)
        (setq msteams--chat '((id . "chat-stale")))
        (msteams-chat-refresh)
        (msteams-channel-thread-mode)
        (msteams-chat-mode)
        (setq msteams--chat '((id . "chat-current")))
        (msteams-chat-refresh)
        (funcall first-callback '(((id . "message-stale"))))
        (should-not rendered)
        (should-not msteams--messages)
        (funcall second-callback '(((id . "message-current"))))
        (should (equal "message-current"
                       (msteams--get (car rendered) 'id)))))))

(ert-deftest msteams-switching-meetings-cancels-and-replaces-context-request ()
  (when-let ((existing (get-buffer msteams--read-buffer-name)))
    (kill-buffer existing))
  (let* ((first '((id . "meeting-first") (chatType . "meeting")))
         (second '((id . "meeting-second") (chatType . "meeting")))
         (buffer (get-buffer-create msteams--read-buffer-name))
         (process (make-pipe-process
                   :name "msteams-stale-meeting"
                   :buffer nil
                   :noquery t))
         loaded)
    (unwind-protect
        (with-current-buffer buffer
          (msteams-chat-mode)
          (setq msteams--chat first
                msteams--meeting-process process
                msteams--meeting-request-id 7)
          (cl-letf (((symbol-function 'msteams-chat-refresh) #'ignore)
                    ((symbol-function 'msteams--display-chat-buffer)
                     #'ignore)
                    ((symbol-function 'msteams--close-other-readers)
                     #'ignore)
                    ((symbol-function 'msteams--load-meeting-context)
                     (lambda (chat) (setq loaded chat))))
            (msteams-open-chat second))
          (should-not (process-live-p process))
          (should (equal "meeting-second"
                         (msteams--chat-id loaded)))
          (should (= 8 msteams--meeting-request-id)))
      (when (process-live-p process) (delete-process process))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest msteams-stale-channel-response-cannot-overwrite-reused-reader ()
  (let (first-callback second-callback rendered)
    (with-temp-buffer
      (cl-letf (((symbol-function 'msteams--run-json)
                 (lambda (_args callback &optional _error-callback)
                   (if first-callback
                       (setq second-callback callback)
                     (setq first-callback callback))
                   nil))
                ((symbol-function 'msteams--render-channel-thread)
                 (lambda ()
                   (setq rendered msteams-channel--messages))))
        (msteams-channel-thread-mode)
        (setq msteams-channel--team '((id . "team-stale"))
              msteams-channel--channel '((id . "channel-stale"))
              msteams-channel--root '((id . "root-stale")))
        (msteams-channel-thread-refresh)
        (msteams-chat-mode)
        (msteams-channel-thread-mode)
        (setq msteams-channel--team '((id . "team-current"))
              msteams-channel--channel '((id . "channel-current"))
              msteams-channel--root '((id . "root-current")))
        (msteams-channel-thread-refresh)
        (funcall first-callback '(((id . "reply-stale"))))
        (should-not rendered)
        (should-not msteams-channel--messages)
        (funcall second-callback '(((id . "reply-current"))))
        (should (equal '("reply-current" "root-current")
                       (sort (mapcar (lambda (message)
                                       (msteams--get message 'id))
                                     rendered)
                             #'string<)))))))

(ert-deftest msteams-thread-navigation-falls-back-without-headers-buffer ()
  (let* ((first '((id . "chat-1")))
         (second '((id . "chat-2")))
         (msteams--chats (list first second))
         opened)
    (with-temp-buffer
      (msteams-chat-mode)
      (setq msteams--chat first)
      (cl-letf (((symbol-function 'msteams--recent-buffer)
                 (lambda () nil))
                ((symbol-function 'msteams--view-chat-p)
                 (lambda (_chat) t))
                ((symbol-function 'msteams-open-chat)
                 (lambda (chat &optional _preview) (setq opened chat))))
        (msteams-thread-next)))
    (should (equal "chat-2" (msteams--chat-id opened)))))

(ert-deftest msteams-chat-list-bounds-metadata-and-accepts-embedded-members ()
  (let ((msteams-chat-metadata-limit 75)
        (msteams-member-enrichment-limit 12)
        (msteams-member-enrichment-concurrency 6)
        (msteams-offline-mode nil)
        (msteams--member-cache (make-hash-table :test #'equal))
        observed result)
    (cl-letf (((symbol-function 'msteams--run-json)
               (lambda (args callback &optional _error-callback)
                 (setq observed args)
                 (funcall callback
                          '(((id . "chat-batched")
                             (membersLoaded . t)
                             (members . (((displayName . "Ada")))))))
                 'fake-process)))
      (msteams--load-chats (lambda (chats) (setq result chats))))
    (should (equal
             '("teams" "chat" "list" "--metadataLimit" "75")
             observed))
    (should (= 1 (length result)))
    (should (equal "Ada"
                   (msteams--get
                    (car (msteams--chat-members (car result)))
                    'displayName)))))

(ert-deftest msteams-member-enrichment-uses-one-asynchronous-batch ()
  (let ((chats '(((id . "chat-1") (topic))
                 ((id . "chat-2") (topic . "Named group"))))
        (msteams-member-enrichment-limit 12)
        (msteams-member-enrichment-concurrency 6)
        (msteams-offline-mode nil)
        (msteams--member-cache (make-hash-table :test #'equal))
        (msteams--member-inflight (make-hash-table :test #'equal))
        observed)
    (cl-letf (((symbol-function 'msteams--run-json)
               (lambda (args callback &optional _error-callback)
                 (setq observed args)
                 (funcall callback
                          '(((chatId . "chat-1")
                             (membersLoaded . t)
                             (members . (((displayName . "Ada")))))))
                 'fake-process))
              ((symbol-function 'msteams--refresh-visible-recent)
               #'ignore))
      (msteams--enrich-members chats))
    (should (equal
             '("teams" "chat" "member" "batch"
               "--memberConcurrency" "6" "--chatId" "chat-1")
             observed))
    (should (equal "Ada"
                   (msteams--get
                    (car (gethash "chat-1" msteams--member-cache))
                    'displayName)))
    (should-not (gethash "chat-1" msteams--member-inflight))))

(ert-deftest msteams-meeting-enrichment-uses-one-event-only-batch ()
  (let* ((meeting
          '((id . "meeting-1")
            (chatType . "meeting")
            (onlineMeetingInfo . ((calendarEventId . "event-1")))))
         (ordinary '((id . "chat-2") (chatType . "group")))
         (msteams--chats (list meeting ordinary))
         (msteams-meeting-enrichment-limit 12)
         (msteams-meeting-enrichment-concurrency 3)
         (msteams-offline-mode nil)
         (msteams--meeting-inflight (make-hash-table :test #'equal))
         observed)
    (cl-letf (((symbol-function 'msteams--run-json)
               (lambda (args callback &optional _error-callback)
                 (setq observed args)
                 (funcall callback
                          '(((chatId . "meeting-1")
                             (event
                              . ((start
                                  . ((dateTime . "2099-08-10T07:30:00")
                                     (timeZone . "UTC"))))))))
                 'fake-process))
              ((symbol-function 'msteams--refresh-visible-recent)
               #'ignore))
      (msteams--enrich-meetings msteams--chats))
    (should (equal '("teams" "meeting" "event" "batch")
                   (seq-take observed 4)))
    (should (equal "3" (car (last observed))))
    (let ((requests
           (json-parse-string (nth 5 observed)
                              :object-type 'alist :array-type 'list)))
      (should (= 1 (length requests)))
      (should (equal "meeting-1" (msteams--get (car requests) 'chatId)))
      (should (equal "event-1" (msteams--get (car requests) 'eventId))))
    (should (equal "2099-08-10T07:30:00"
                   (msteams--dig meeting 'meetingContext 'event
                                  'start 'dateTime)))
    (should-not (gethash "meeting-1" msteams--meeting-inflight))))

(ert-deftest msteams-known-account-skips-redundant-status-process ()
  (let ((msteams-offline-mode nil)
        (msteams--connected-as "user@example.com")
        status-called callback-called)
    (cl-letf (((symbol-function 'msteams--status-request)
               (lambda (&rest _args) (setq status-called t))))
      (msteams--with-status (lambda () (setq callback-called t))))
    (should callback-called)
    (should-not status-called)))

(ert-deftest msteams-preview-reuses-unchanged-recent-transcript ()
  (let* ((chat '((id . "chat-cached")
                 (lastUpdatedDateTime . "2026-08-02T10:00:00Z")))
         (buffer-name msteams--read-buffer-name)
         (msteams-preview-cache-seconds 120)
         (refreshes 0))
    (unwind-protect
        (progn
          (with-current-buffer (get-buffer-create buffer-name)
            (msteams-chat-mode)
            (setq msteams--chat chat
                  msteams--messages '(((id . "message-1")))
                  msteams--loaded-at (float-time)
                  msteams--loaded-update
                  "2026-08-02T10:00:00Z"))
          (cl-letf (((symbol-function 'msteams-chat-refresh)
                     (lambda (&optional _all _limit) (cl-incf refreshes)))
                    ((symbol-function 'msteams--display-chat-buffer)
                     #'ignore))
            (msteams-open-chat chat t)
            (should (= 0 refreshes))
            (msteams-open-chat chat nil)
            (should (= 1 refreshes))))
      (when-let ((buffer (get-buffer buffer-name))) (kill-buffer buffer)))))

(ert-deftest msteams-preview-requests-lightweight-message-page ()
  (let* ((chat '((id . "chat-preview-limit")
                 (lastUpdatedDateTime . "2026-08-02T10:00:00Z")))
         (buffer-name msteams--read-buffer-name)
         (msteams-preview-message-limit 75)
         observed)
    (unwind-protect
        (cl-letf (((symbol-function 'msteams-chat-refresh)
                   (lambda (&optional all limit)
                     (setq observed (list all limit))))
                  ((symbol-function 'msteams--display-chat-buffer)
                   #'ignore))
          (msteams-open-chat chat t)
          (should (equal '(nil 75) observed)))
      (when-let ((buffer (get-buffer buffer-name))) (kill-buffer buffer)))))

(ert-deftest msteams-chat-preview-and-explicit-open-share-one-reader ()
  (let* ((first '((id . "chat-preview-first") (topic . "First")))
         (second '((id . "chat-preview-second") (topic . "Second"))))
    (unwind-protect
        (cl-letf (((symbol-function 'msteams-chat-refresh) #'ignore)
                  ((symbol-function 'msteams--display-chat-buffer)
                   #'ignore))
          (msteams-open-chat first t)
          (msteams-open-chat second t)
          (with-current-buffer msteams--read-buffer-name
            (should msteams--automatic-preview-p)
            (should (derived-mode-p 'msteams-read-mode))
            (should (equal "chat-preview-second"
                           (msteams--chat-id
                            msteams--chat))))
          (msteams-open-chat first nil)
          (with-current-buffer msteams--read-buffer-name
            (should-not msteams--automatic-preview-p)
            (should (equal "chat-preview-first"
                           (msteams--chat-id
                            msteams--chat))))
          (should-not
           (seq-find (lambda (buffer)
                       (string-prefix-p "*Teams Chat " (buffer-name buffer)))
                     (buffer-list))))
      (when-let ((buffer (get-buffer msteams--read-buffer-name)))
        (kill-buffer buffer)))))

(ert-deftest msteams-channel-preview-and-explicit-open-share-one-reader ()
  (let* ((team '((id . "team-preview") (displayName . "Engineering")))
         (channel '((id . "channel-preview") (displayName . "General")))
         (first '((id . "root-preview-first") (subject . "First")))
         (second '((id . "root-preview-second") (subject . "Second"))))
    (unwind-protect
        (cl-letf
            (((symbol-function 'msteams-channel-thread-refresh) #'ignore)
             ((symbol-function 'msteams--display-channel-thread)
              #'ignore))
          (msteams-open-channel-thread team channel first t)
          (msteams-open-channel-thread team channel second t)
          (with-current-buffer msteams--read-buffer-name
            (should msteams--automatic-preview-p)
            (should (derived-mode-p 'msteams-read-mode))
            (should (equal "root-preview-second"
                           (msteams--get msteams-channel--root 'id))))
          (msteams-open-channel-thread team channel first)
          (with-current-buffer msteams--read-buffer-name
            (should-not msteams--automatic-preview-p)
            (should (equal "root-preview-first"
                           (msteams--get
                            msteams-channel--root 'id)))))
      (when-let ((buffer (get-buffer msteams--read-buffer-name)))
        (kill-buffer buffer)))))

(ert-deftest msteams-chat-and-channel-replace-the-same-reader-buffer ()
  (let ((chat '((id . "chat-single-reader") (topic . "Chat")))
        (team '((id . "team-single-reader") (displayName . "Team")))
        (channel '((id . "channel-single-reader") (displayName . "General")))
        (root '((id . "root-single-reader") (subject . "Root")))
        first-buffer)
    (unwind-protect
        (cl-letf
            (((symbol-function 'msteams-chat-refresh) #'ignore)
             ((symbol-function 'msteams-channel-thread-refresh) #'ignore)
             ((symbol-function 'msteams--display-chat-buffer) #'ignore)
             ((symbol-function 'msteams--display-channel-thread)
              #'ignore))
          (msteams-open-chat chat)
          (setq first-buffer (get-buffer msteams--read-buffer-name))
          (msteams-open-channel-thread team channel root)
          (should (eq first-buffer
                      (get-buffer msteams--read-buffer-name)))
          (with-current-buffer first-buffer
            (should (derived-mode-p 'msteams-channel-thread-mode))))
      (when-let ((buffer (get-buffer msteams--read-buffer-name)))
        (kill-buffer buffer)))))

(ert-deftest msteams-close-inactive-transcripts-retains-single-reader ()
  (let ((preview (get-buffer-create msteams--read-buffer-name))
        (chat (generate-new-buffer "*Teams Chat inactive-test*"))
        (channel (generate-new-buffer "*Teams Channel Thread inactive-test*")))
    (unwind-protect
        (progn
          (with-current-buffer preview
            (msteams-chat-mode)
            (setq msteams--automatic-preview-p t))
          (with-current-buffer chat
            (msteams-chat-mode))
          (with-current-buffer channel
            (msteams-channel-thread-mode))
          (msteams-close-inactive-transcripts)
          (should (buffer-live-p preview))
          (should-not (buffer-live-p chat))
          (should-not (buffer-live-p channel)))
      (dolist (buffer (list preview chat channel))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest msteams-compose-draft-restores-body-metadata-and-private-mode ()
  (let* ((directory (make-temp-file "msteams-draft-" t))
         (msteams-draft-directory directory)
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
            (msteams-compose-mode)
            (setq msteams-compose--target target
                  msteams-compose--reply-to reply
                  msteams-compose--content-type "html"
                  msteams-compose--attachments '("/tmp/report.pdf")
                  msteams-compose--mentions '("ada-id|Ada"))
            (msteams-compose--initialize-draft)
            (insert "<strong>Draft</strong> @Ada")
            (msteams-compose--save-draft)
            (setq draft-file msteams-compose--draft-file
                  msteams-compose--discarded t))
          (should (file-exists-p draft-file))
          (should (= #o600 (file-modes draft-file)))
          (let ((payload (msteams-compose--read-draft draft-file)))
            (should (equal "chat-draft"
                           (msteams--dig payload 'target 'chatId)))
            (should (equal "message-draft"
                           (msteams--dig payload 'replyTo 'id)))
            (should (stringp (msteams--get payload 'updatedAt))))
          (with-temp-buffer
            (msteams-compose-mode)
            (setq msteams-compose--target target
                  msteams-compose--reply-to reply)
            (msteams-compose--initialize-draft)
            (should (equal "<strong>Draft</strong> @Ada" (buffer-string)))
            (should (equal "html" msteams-compose--content-type))
            (should (equal '("/tmp/report.pdf")
                           msteams-compose--attachments))
            (should (equal '("ada-id|Ada")
                           msteams-compose--mentions))
            (msteams-compose--delete-draft)))
      (delete-directory directory t))))

(ert-deftest msteams-compose-drafts-are-distinct-per-reply-target ()
  (with-temp-buffer
    (msteams-compose-mode)
    (setq msteams-compose--target '((id . "chat-1"))
          msteams-compose--reply-to '((id . "message-1")))
    (let ((first (msteams-compose--target-key)))
      (setq msteams-compose--reply-to '((id . "message-2")))
      (should-not (equal first (msteams-compose--target-key)))
      (setq msteams-compose--reply-to nil)
      (should (equal "chat-1" (msteams-compose--target-key))))))

(ert-deftest msteams-compose-buffers-are-distinct-per-reply-target ()
  (let ((target '((id . "chat-1") (topic . "Draft test"))))
    (should-not
     (equal (msteams--compose-buffer-name
             target '((id . "message-1")))
            (msteams--compose-buffer-name
             target '((id . "message-2")))))
    (should-not
     (equal (msteams--compose-buffer-name target)
            (msteams--compose-buffer-name
             target '((id . "message-1")))))))

(ert-deftest msteams-compose-reopen-preserves-live-metadata ()
  (let* ((directory (make-temp-file "msteams-live-compose-" t))
         (msteams-draft-directory directory)
         (target '((id . "chat-live") (topic . "Live draft")))
         (name (msteams--compose-buffer-name target))
         buffer)
    (unwind-protect
        (save-current-buffer
          (cl-letf (((symbol-function 'pop-to-buffer)
                     (lambda (target-buffer &rest _args)
                       (setq buffer target-buffer)
                       (set-buffer target-buffer))))
            (msteams--open-compose target)
            (insert "Existing live draft")
            (setq msteams-compose--attachments '("/tmp/report.pdf")
                  msteams-compose--mentions '("ada-id|Ada")
                  msteams-compose--content-type "html")
            (msteams--open-compose target nil "Forwarded replacement")
            (should (eq buffer (get-buffer name)))
            (should (equal "Existing live draft" (buffer-string)))
            (should (equal '("/tmp/report.pdf")
                           msteams-compose--attachments))
            (should (equal '("ada-id|Ada")
                           msteams-compose--mentions))
            (should (equal "html" msteams-compose--content-type))
            (msteams-compose--delete-draft)))
      (when (buffer-live-p buffer) (kill-buffer buffer))
      (delete-directory directory t))))

(ert-deftest msteams-compose-restores-disk-draft-before-initial-text ()
  (let* ((directory (make-temp-file "msteams-disk-compose-" t))
         (msteams-draft-directory directory)
         (target '((id . "chat-disk") (topic . "Disk draft")))
         (name (msteams--compose-buffer-name target))
         buffer)
    (unwind-protect
        (progn
          (with-temp-buffer
            (msteams-compose-mode)
            (setq msteams-compose--target target)
            (msteams-compose--initialize-draft)
            (insert "Recovered disk draft")
            (msteams-compose--save-draft)
            (setq msteams-compose--discarded t))
          (save-current-buffer
            (cl-letf (((symbol-function 'pop-to-buffer)
                       (lambda (target-buffer &rest _args)
                         (setq buffer target-buffer)
                         (set-buffer target-buffer))))
              (msteams--open-compose target nil "Forwarded replacement")
              (should (eq buffer (get-buffer name)))
              (should (equal "Recovered disk draft" (buffer-string)))
              (msteams-compose--delete-draft))))
      (when (buffer-live-p buffer) (kill-buffer buffer))
      (delete-directory directory t))))

(ert-deftest msteams-compose-failed-send-retains-private-draft ()
  (let* ((directory (make-temp-file "msteams-failed-send-" t))
         (msteams-draft-directory directory)
         (msteams-confirm-send nil)
         (msteams-offline-mode nil)
         (buffer (generate-new-buffer " *Teams failed send test*"))
         draft-file reported)
    (unwind-protect
        (with-current-buffer buffer
          (msteams-compose-mode)
          (setq msteams-compose--target
                '((id . "chat-failure") (topic . "Failure test")))
          (msteams-compose--initialize-draft)
          (insert "This must survive the failed send")
          (setq draft-file msteams-compose--draft-file)
          (cl-letf (((symbol-function 'msteams--run)
                     (lambda (_args _callback &optional error-callback)
                       (funcall error-callback 1 "simulated failure")
                       'fake-process))
                    ((symbol-function 'msteams--report-error)
                     (lambda (&rest _args) (setq reported t))))
            (msteams-compose-send))
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
                           (msteams--get payload 'body))))
          (msteams-compose--delete-draft))
      (when (buffer-live-p buffer) (kill-buffer buffer))
      (delete-directory directory t))))

(ert-deftest msteams-channel-export-refetches-complete-replies ()
  (let* ((path (make-temp-file "msteams-channel-export-" nil ".md"))
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
          (msteams-channel-thread-mode)
          (setq msteams-channel--team
                '((id . "team-1") (displayName . "Engineering"))
                msteams-channel--channel
                '((id . "channel-1") (displayName . "General"))
                msteams-channel--root root
                msteams-channel--messages (list root))
          (cl-letf (((symbol-function 'msteams--export-path)
                     (lambda (_chat) path))
                    ((symbol-function 'msteams--run-json)
                     (lambda (args callback &optional _error-callback)
                       (setq captured-args args)
                       (funcall callback (list reply))
                       'fake-process)))
            (msteams-channel-export-thread
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

(ert-deftest msteams-channel-index-can-copy-complete-thread-markdown ()
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
      (msteams-channel-index-mode)
      (setq msteams-channel--team
            '((id . "team-1") (displayName . "Engineering"))
            msteams-channel--channel
            '((id . "channel-1") (displayName . "General"))
            msteams-channel--roots (list root))
      (cl-letf (((symbol-function 'msteams-channel-root-at-point)
                 (lambda () root))
                ((symbol-function 'msteams--run-json)
                 (lambda (args callback &optional _error-callback)
                   (setq captured-args args)
                   (funcall callback (list reply))
                   'fake-process))
                ((symbol-function 'kill-new)
                 (lambda (text &optional _replace)
                   (setq captured-markdown text))))
        (msteams-copy-current-thread-markdown))
      (should
       (equal '("teams" "channel" "reply" "list"
                "--teamId" "team-1" "--channelId" "channel-1"
                "--messageId" "root-copy")
              captured-args))
      (should (string-match-p "Root copy" captured-markdown))
      (should (string-match-p "Reply copy" captured-markdown)))))

(ert-deftest msteams-real-backend-mock-status-sync-and-search ()
  (let* ((directory (make-temp-file "msteams-mock-" t))
         (msteams-mock-mode t)
         (msteams-mock-state-file (expand-file-name "tenant.json" directory))
         (msteams-cache-file (expand-file-name "cache.sqlite3" directory))
         status sync-result search-result cached-chats cached-teams
         cached-roots cached-replies)
    (unwind-protect
        (progn
          (msteams-test-await
           (msteams--status-request (lambda (value) (setq status value))))
          (should (equal "MockTenant" (msteams--get status 'authType)))
          (msteams-test-await
           (msteams--run-json
            '("teams" "sync" "--scope" "all")
            (lambda (value) (setq sync-result value))))
          (should (= 2 (msteams--get sync-result 'teams)))
          (msteams-test-await
           (msteams--run-json
            '("teams" "cache" "search" "--query" "native workflow")
            (lambda (value) (setq search-result value))))
          (should search-result)
          (should (equal "channel"
                         (msteams--dig (car search-result)
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
              (msteams-test-await
               (msteams--run-json
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

(ert-deftest msteams-real-backend-mock-renders-inbox-and-channel-thread ()
  (let* ((directory (make-temp-file "msteams-mock-ui-" t))
         (msteams-mock-mode t)
         (msteams-mock-state-file (expand-file-name "tenant.json" directory))
         (msteams-cache-file (expand-file-name "cache.sqlite3" directory))
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
              (msteams-test-await
               (msteams--run-json
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
            (msteams-recent-mode)
            (setq msteams--chats chats
                  msteams--active-view 'all
                  msteams--marks (make-hash-table :test #'equal)
                  msteams--favorites (make-hash-table :test #'equal))
            (msteams--render-recent)
            (should (string-match-p "Project Atlas" (buffer-string)))
            (should (string-match-p "MOCK" header-line-format)))
          (with-temp-buffer
            (msteams-channel-thread-mode)
            (setq msteams-channel--team (car teams)
                  msteams-channel--channel (car channels)
                  msteams-channel--root (car roots)
                  msteams-channel--messages
                  (cons (car roots) replies))
            (msteams--render-channel-thread)
            (should (string-match-p "Engineering / General" (buffer-string)))
            (should (string-match-p "production command contract"
                                    (buffer-string)))))
      (delete-directory directory t))))

(ert-deftest msteams-real-backend-mock-renders-future-meeting-context ()
  (let* ((directory (make-temp-file "msteams-mock-meeting-" t))
         (msteams-mock-mode t)
         (msteams-mock-state-file (expand-file-name "tenant.json" directory))
         (msteams-cache-file (expand-file-name "cache.sqlite3" directory))
         (msteams--member-cache (make-hash-table :test #'equal))
         chats context meeting)
    (unwind-protect
        (progn
          (msteams-test-await
           (msteams--run-json
            '("teams" "chat" "list")
            (lambda (value) (setq chats value))))
          (setq meeting
                (seq-find
                 (lambda (chat)
                   (equal "mock-chat-future-meeting"
                          (msteams--chat-id chat)))
                 chats))
          (should meeting)
          (msteams-test-await
           (msteams--fetch-meeting-context
            meeting (lambda (value) (setq context value))))
          (should (equal "2026-08-10T07:30:00"
                         (msteams--dig context 'event 'start 'dateTime)))
          (should (= 3 (length (msteams--get context 'members))))
          (with-temp-buffer
            (msteams-chat-mode)
            (setq msteams--chat meeting
                  msteams--messages nil)
            (msteams--render-chat)
            (should (string-match-p "Meeting details" (buffer-string)))
            (should (string-match-p "When: .*2026" (buffer-string)))
            (should (string-match-p "Where: Video room 4" (buffer-string)))
            (should (string-match-p "Participants: .*Grace Hopper"
                                    (buffer-string)))
            (should (string-match-p "Ada Lovelace" (buffer-string)))
            (should (string-match-p "Join meeting" (buffer-string)))))
      (delete-directory directory t))))

(ert-deftest msteams-channel-thread-render-supports-message-navigation ()
  (let* ((messages (msteams-test-read-json "messages-chat-1.json"))
         (root (car messages))
         (reply (cadr messages))
         (msteams--connected-user-id "current-user-id"))
    (with-temp-buffer
      (msteams-channel-thread-mode)
      (setq msteams-channel--team
            '((id . "team-1") (displayName . "Engineering"))
            msteams-channel--channel
            '((id . "channel-1") (displayName . "General"))
            msteams-channel--root root
            msteams-channel--messages (list root reply))
      (msteams--render-channel-thread)
      (should (string-match-p "Engineering / General" (buffer-string)))
      (goto-char (point-min))
      (msteams-chat-next-message)
      (should (equal "message-1"
                     (msteams--get (msteams-current-message) 'id)))
      (msteams-chat-next-message)
      (should (equal "message-2"
                     (msteams--get (msteams-current-message) 'id))))))

(ert-deftest msteams-message-context-distinguishes-chat-and-channel-reply ()
  (with-temp-buffer
    (msteams-chat-mode)
    (setq msteams--chat '((id . "chat-1")))
    (should (equal '("--scope" "chat" "--chatId" "chat-1"
                     "--messageId" "message-1")
                   (msteams--message-context-args
                    '((id . "message-1"))))))
  (with-temp-buffer
    (msteams-channel-thread-mode)
    (setq msteams-channel--team '((id . "team-1"))
          msteams-channel--channel '((id . "channel-1"))
          msteams-channel--root '((id . "root-1")))
    (should (equal '("--scope" "channel" "--teamId" "team-1"
                     "--channelId" "channel-1" "--messageId" "reply-1"
                     "--rootMessageId" "root-1")
                   (msteams--message-context-args
                    '((id . "reply-1")))))))

(ert-deftest msteams-triage-state-expires-without-another-representation ()
  (let* ((directory (make-temp-file "msteams-triage-" t))
         (msteams-state-file (expand-file-name "teams-state.json" directory))
         (msteams--favorites (make-hash-table :test #'equal))
         (msteams--muted (make-hash-table :test #'equal))
         (msteams--handled (make-hash-table :test #'equal))
         (msteams--snoozed (make-hash-table :test #'equal))
         (msteams--saved-views (make-hash-table :test #'equal))
         (msteams--state-loaded t)
         (old '((id . "chat-triage")
                (chatType . "group")
                (lastMessagePreview . ((id . "message-1")))))
         (new '((id . "chat-triage")
                (chatType . "group")
                (lastMessagePreview . ((id . "message-2"))))))
    (unwind-protect
        (progn
          (msteams--set-handled-local old t)
          (msteams--save-state)
          (should (= #o600 (file-modes msteams-state-file)))
          (setq msteams--state-loaded nil
                msteams--handled (make-hash-table :test #'equal)
                msteams--snoozed (make-hash-table :test #'equal))
          (msteams--load-state)
          (should (msteams--handled-p old))
          (should-not (msteams--handled-p new))
          (should-not (msteams--built-in-view-chat-p old 'inbox))
          (should (msteams--built-in-view-chat-p new 'inbox))
          (msteams--set-snoozed-local
           new (format-time-string "%Y-%m-%dT%H:%M:%S%z"
                                   (time-add (current-time) (days-to-time 1))))
          (should-not (msteams--handled-p new))
          (should (msteams--snoozed-p new))
          (puthash "chat-triage" "2000-01-01T00:00:00+0000"
                   msteams--snoozed)
          (should-not (msteams--snoozed-p new)))
      (delete-directory directory t))))

(ert-deftest msteams-attention-query-supports-simple-or-clauses ()
  (let* ((direct '((id . "direct") (chatType . "oneOnOne")))
         (important '((id . "important")
                      (chatType . "group")
                      (lastMessagePreview
                       . ((importance . "high")
                          (body . ((contentType . "text")
                                   (content . "Release")))))))
         (ordinary '((id . "ordinary") (chatType . "group")))
         (msteams--read-overrides (make-hash-table :test #'equal))
         (msteams--favorites (make-hash-table :test #'equal))
         (msteams--muted (make-hash-table :test #'equal))
         (msteams--handled (make-hash-table :test #'equal))
         (msteams--snoozed (make-hash-table :test #'equal))
         (msteams--state-loaded t))
    (should (msteams--query-chat-p direct "important | type:direct"))
    (should (msteams--query-chat-p important
                                          "important | type:direct"))
    (should-not (msteams--query-chat-p ordinary
                                              "important | type:direct"))))

(ert-deftest msteams-cache-first-inbox-renders-cache-then-graph ()
  (let* ((buffer (generate-new-buffer " *Teams cache-first test*"))
         (cached '(((id . "cached")
                    (lastUpdatedDateTime . "2026-08-01T09:00:00Z"))))
         (live '(((id . "live")
                  (lastUpdatedDateTime . "2026-08-02T09:00:00Z"))))
         (msteams--connected-as "user@example.test")
         calls snapshots)
    (unwind-protect
        (with-current-buffer buffer
          (msteams-recent-mode)
          (cl-letf (((symbol-function 'msteams--run-json)
                     (lambda (args callback &optional _error-callback)
                       (push args calls)
                       (funcall callback
                                (if (equal (seq-take args 3)
                                           '("teams" "cache" "chat"))
                                    cached live))
                       'fake-request))
                    ((symbol-function 'msteams--render-recent)
                     (lambda ()
                       (push (list msteams--inbox-source-label
                                   (msteams--chat-id
                                    (car msteams--chats)))
                             snapshots)))
                    ((symbol-function 'msteams--enrich-members) #'ignore)
                    ((symbol-function 'msteams--schedule-preview) #'ignore))
            (msteams--start-cache-first-inbox-load buffer))
          (setq calls (nreverse calls)
                snapshots (nreverse snapshots))
          (should (equal '("teams" "cache" "chat" "list") (car calls)))
          (should (equal '("teams" "chat" "list")
                         (seq-take (cadr calls) 3)))
          (should (equal '("cached, refreshing" "cached")
                         (car snapshots)))
          (should (equal '(nil "live") (car (last snapshots)))))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest msteams-cache-first-chat-renders-cache-then-graph ()
  (let ((chat '((id . "chat-fast")
                (lastUpdatedDateTime . "2026-08-06T09:00:00Z")))
        (cached '(((id . "cached-message")
                   (createdDateTime . "2026-08-06T08:00:00Z"))))
        (live '(((id . "live-message")
                 (createdDateTime . "2026-08-06T09:00:00Z"))))
        (msteams-cache-first t)
        (msteams-offline-mode nil)
        calls snapshots)
    (with-temp-buffer
      (msteams-chat-mode)
      (setq msteams--chat chat)
      (cl-letf (((symbol-function 'msteams--run-json)
                 (lambda (args callback &optional _error-callback)
                   (push args calls)
                   (funcall callback
                            (if (equal (seq-take args 3)
                                       '("teams" "cache" "chat"))
                                cached live))
                   nil))
                ((symbol-function 'msteams--render-chat)
                 (lambda ()
                   (push (mapcar (lambda (message)
                                   (msteams--get message 'id))
                                 msteams--messages)
                         snapshots))))
        (let ((msteams--cache-first-open t))
          (msteams-chat-refresh nil 75)))
      (should (equal '("teams" "cache" "chat" "message" "list")
                     (seq-take (cadr calls) 5)))
      (should (equal '("teams" "chat" "message" "list")
                     (seq-take (car calls) 4)))
      (should (equal '(("cached-message") ("live-message"))
                     (nreverse snapshots))))))

(ert-deftest msteams-capture-markers-reparse-only-after-source-change ()
  (let* ((directory (make-temp-file "msteams-capture-cache-" t))
         (file (expand-file-name "teams.org" directory))
         (msteams-capture-file file)
         (msteams--captured-chat-table
          (make-hash-table :test #'equal))
         (msteams--captured-chat-signature nil)
         (msteams--captured-chat-checked-at 0.0)
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
                             (msteams--captured-chat-table)))
            (msteams--captured-chat-table)
            (should (= 1 reads))
            (with-temp-file file
              (insert "* One\n:PROPERTIES:\n:TEAMS_CHAT: chat-one\n:END:\n"
                      "* Two\n:PROPERTIES:\n:TEAMS_CHAT: chat-two\n:END:\n"))
            (setq msteams--captured-chat-checked-at 0.0)
            (should (gethash "chat-two"
                             (msteams--captured-chat-table)))
            (should (= 2 reads))))
      (delete-directory directory t))))

(ert-deftest msteams-meeting-context-waits-for-message-render ()
  (let ((chat '((id . "meeting-fast") (chatType . "meeting")))
        (msteams-offline-mode nil)
        (renders 0))
    (with-temp-buffer
      (msteams-chat-mode)
      (setq msteams--chat chat)
      (cl-letf (((symbol-function 'msteams--fetch-meeting-context)
                 (lambda (_chat callback &optional _error-callback)
                   (funcall callback '((members . nil)))
                   nil))
                ((symbol-function 'msteams--render-chat)
                 (lambda () (cl-incf renders))))
        (msteams--load-meeting-context chat)
        (should (= 0 renders))
        (setq msteams--loaded-at (float-time))
        (msteams--load-meeting-context chat)
        (should (= 1 renders))))))

(ert-deftest msteams-org-linkage-prefers-message-then-conversation ()
  (let* ((directory (make-temp-file "msteams-org-link-" t))
         (file (expand-file-name "teams.org" directory))
         (msteams-capture-file file)
         buffer exact fallback)
    (unwind-protect
        (progn
          (with-temp-file file
            (insert "* Conversation\n:PROPERTIES:\n:TEAMS_CHAT: chat-1\n:END:\n"
                    "** Exact message\n:PROPERTIES:\n"
                    ":TEAMS_MESSAGE: message-2\n:END:\n"))
          (setq exact
                (msteams--find-org-capture
                 '((chatId . "chat-1") (selectedMessageId . "message-2")))
                fallback
                (msteams--find-org-capture
                 '((chatId . "chat-1") (selectedMessageId . "missing"))))
          (setq buffer (marker-buffer exact))
          (with-current-buffer buffer
            (goto-char exact)
            (should (equal "Exact message" (org-get-heading t t t t)))
            (goto-char fallback)
            (should (equal "Conversation" (org-get-heading t t t t)))))
      (when (buffer-live-p buffer) (kill-buffer buffer))
      (delete-directory directory t))))

(ert-deftest msteams-structured-cards-render-without-shadow-message-data ()
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
      (msteams--insert-attachments
       `((attachments . (,adaptive ,snippet))))
      (should (string-match-p "Deployment card" (buffer-string)))
      (should (string-match-p "Deploy ready" (buffer-string)))
      (should (string-match-p "Owner: Ada" (buffer-string)))
      (should (string-match-p "Open runbook" (buffer-string)))
      (should (string-match-p "print('one cache')" (buffer-string))))))

(ert-deftest msteams-vtt-transcript-becomes-readable-speaker-text ()
  (let ((text (msteams--vtt-to-text
               (concat "WEBVTT\n\n00:00:00.000 --> 00:00:03.000\n"
                       "<v Ada>Keep <strong>Graph</strong> authoritative.</v>\n\n"
                       "00:00:03.000 --> 00:00:05.000\nOne cache.\n"))))
    (should (string-match-p "Ada: Keep Graph authoritative" text))
    (should (string-match-p "One cache" text))
    (should-not (string-match-p "WEBVTT\|-->" text))))

(ert-deftest msteams-server-search-is-explicit-and-ephemeral ()
  (let (captured)
    (cl-letf (((symbol-function 'msteams--run-json)
               (lambda (args _callback &optional _error-callback)
                 (setq captured args)
                 'fake-request)))
      (should (eq 'fake-request (msteams-search "one cache" t))))
    (should (equal '("teams" "search" "messages" "--query" "one cache"
                     "--limit" "100")
                   captured))
    (with-temp-buffer
      (msteams-search-mode)
      (setq msteams--search-query "repeat me"
            msteams--search-server t)
      (cl-letf (((symbol-function 'msteams-search)
                 (lambda (query server) (setq captured (list query server)))))
        (msteams-search-refresh))
      (should (equal '("repeat me" t) captured)))))

(ert-deftest msteams-persistent-transport-keeps-mutations-one-shot ()
  (let ((msteams-use-persistent-backend t)
        (program "/tmp/msteams-graph"))
    (should (msteams--persistent-command-p
             program '("teams" "chat" "message" "list" "--chatId" "one")))
    (should (msteams--persistent-command-p
             program '("teams" "search" "messages" "--query" "cache")))
    (should (msteams--persistent-command-p
             program '("teams" "chat" "member" "list" "--chatId" "one")))
    (should-not (msteams--persistent-command-p
                 program '("teams" "chat" "message" "send" "--message" "x")))
    (should-not (msteams--persistent-command-p
                 program '("teams" "chat" "member" "add" "--chatId" "one")))
    (should-not (msteams--persistent-command-p
                 program '("teams" "cache" "clear")))
    (should-not (msteams--persistent-command-p
                 program '("teams" "attachment" "download" "--url" "x")))))

(ert-deftest msteams-persistent-filter-tolerates-python-startup-stdout ()
  (let* ((server (make-pipe-process
                  :name "msteams-protocol-noise-test"
                  :buffer nil
                  :noquery t))
         (msteams--server-process server)
         (msteams--server-fingerprint '(test))
         (msteams--server-pending (make-hash-table :test #'eql))
         first-result second-result)
    (unwind-protect
        (progn
          (puthash
           7
           (list :request (msteams--make-request 7)
                 :server server
                 :args '("status")
                 :callback (lambda (payload) (setq first-result payload)))
           msteams--server-pending)
          (msteams--server-filter
           server
           (concat "python startup banner\n"
                   "{\"id\":7,\"ok\":true,\"result\":{\"ready\":true}}\n"))
          (should (msteams--get first-result 'ready))
          (should-not (gethash 7 msteams--server-pending))
          (should (process-live-p server))

          (puthash
           8
           (list :request (msteams--make-request 8)
                 :server server
                 :args '("status")
                 :callback (lambda (payload) (setq second-result payload)))
           msteams--server-pending)
          (msteams--server-filter
           server
           (concat "banner without newline"
                   "{\"id\":8,\"ok\":true,\"result\":\"ready\"}\n"))
          (should (equal "ready" second-result))
          (should-not (gethash 8 msteams--server-pending))
          (should (process-live-p server)))
      (msteams--stop-server))))

(ert-deftest msteams-removing-pasted-image-deletes-private-temporary-file ()
  (let* ((root (make-temp-file "msteams-clipboard-" t))
         (msteams-draft-directory root)
         (directory (msteams-compose--clipboard-directory))
         (path (expand-file-name "pasted.png" directory))
         (msteams-compose--attachments (list path)))
    (unwind-protect
        (progn
          (make-directory directory t)
          (write-region "image" nil path nil 'silent)
          (cl-letf (((symbol-function 'completing-read)
                     (lambda (&rest _ignored) path))
                    ((symbol-function 'msteams-compose--update-header)
                     #'ignore)
                    ((symbol-function 'msteams-compose--schedule-draft)
                     #'ignore))
            (msteams-compose-remove-attachment))
          (should-not msteams-compose--attachments)
          (should-not (file-exists-p path)))
      (delete-directory root t))))

;;; msteams-tests.el ends here
