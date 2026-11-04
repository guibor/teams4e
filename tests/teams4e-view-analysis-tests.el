;;; teams4e-view-analysis-tests.el --- View-wide agent context -*- lexical-binding: t; -*-

(require 'ert)
(require 'teams4e)
(require 'teams4e-companion)

(defconst teams4e-view-test-root
  (expand-file-name ".." (file-name-directory (or load-file-name buffer-file-name))))

(defmacro teams4e-view-test-session (&rest body)
  "Run BODY with isolated rows, private exports and fake agent/backend calls."
  (declare (indent 0))
  `(let* ((directory (make-temp-file "teams4e-view-test-" t))
          (headers (generate-new-buffer " *view-headers*"))
          (teams4e--recent-buffer-name (buffer-name headers))
          (teams4e-view-analysis--buffer-name " *view-export-test*")
          (teams4e-export-directory directory)
          (teams4e-offline-mode nil)
          (teams4e-mock-mode t)
          (teams4e--state-loaded t)
          (teams4e--connected-as "fixture-account-label")
          (teams4e--connected-user-id "fixture-account-id")
          (teams4e--active-query 'all)
          (teams4e--active-filter-name "Today")
          (teams4e--unread-filter-enabled t)
          (teams4e--read-overrides (make-hash-table :test #'equal))
          (teams4e--selections (make-hash-table :test #'equal))
          (teams4e--chats
           (copy-tree '(((id . "a") (topic . "Alpha") (webUrl . "https://example.test/a"))
             ((id . "b") (topic . "Beta") (webUrl . "https://example.test/b"))
             ((id . "hidden") (topic . "Hidden unrelated chat")))))
          (config '((:identifier . cursor)))
          requests launches submitted errors)
     (unwind-protect
         (save-window-excursion
           (with-current-buffer headers
             (teams4e-recent-mode)
             (setq tabulated-list-entries '(("b" []) ("a" []))))
           (cl-letf (((symbol-function 'teams4e--thread-analysis-agent-config)
                      (lambda () config))
                     ((symbol-function 'teams4e--run-json)
                      (lambda (args success &optional failure)
                        (setq requests (append requests (list (list args success failure))))
                        (teams4e--make-request (length requests))))
                     ((symbol-function 'teams4e--report-error)
                      (lambda (&rest args) (push args errors)))
                     ((symbol-function 'agent-shell-start)
                      (lambda (&rest args)
                        (push (list args default-directory) launches)
                        'fake-agent))
                     ((symbol-function 'agent-shell-insert)
                      (lambda (&rest args) (push args submitted))))
             ,@body))
       (when-let ((progress (get-buffer teams4e-view-analysis--buffer-name)))
         (kill-buffer progress))
       (when (buffer-live-p headers) (kill-buffer headers))
       (delete-directory directory t))))

(defun teams4e-view-test-complete (request &optional payload)
  "Deliver a complete synthetic export to REQUEST, or use explicit PAYLOAD."
  (funcall
   (nth 1 request)
   (or payload
       '((value . (((id . "message") (createdDateTime . "2020-01-02T07:00:00Z")
                     (from . ((user . ((displayName . "Example Person")))))
                     (body . ((contentType . "text") (content . "Earlier full history"))))))
         (history . ((complete . t) (messageCount . 1) (pageCount . 2)))))))

(defun teams4e-view-test-index ()
  "Return the sole index path from the active test export directory."
  (car (directory-files-recursively teams4e-export-directory "index\\.md\\'")))

(ert-deftest teams4e-view-analysis-freezes-all-listed-rows-and-exports-full-history ()
  (teams4e-view-test-session
    (puthash "hidden" t teams4e--selections)
    (with-current-buffer headers (teams4e-analyze-view))
    (should (= 1 (length requests)))
    (should-not launches)
    (should (equal '("teams" "chat" "message" "export" "--chatId" "b")
                   (caar requests)))
    ;; Filtering, marking read and metadata refresh after G cannot change scope.
    (setq teams4e--active-query 'unread teams4e--active-filter-name "Changed")
    (puthash "a" (cons 'read nil) teams4e--read-overrides)
    (setcdr (assq 'topic (car teams4e--chats)) "Changed title")
    (with-current-buffer headers (setq tabulated-list-entries '(("hidden" []))))
    (teams4e-view-test-complete (car requests))
    (should (= 2 (length requests)))
    (should (equal '("teams" "chat" "message" "export" "--chatId" "a")
                   (car (cadr requests))))
    (should-not launches)
    (teams4e-view-test-complete (cadr requests))
    (should (= 1 (length launches)))
    (should (= 1 (length submitted)))
    (should (equal config (plist-get (caar launches) :config)))
    (let* ((index (teams4e-view-test-index))
           (text (with-temp-buffer (insert-file-contents index) (buffer-string)))
           (files (directory-files (file-name-directory index) t "thread-.*\\.md\\'")))
      (should (= 2 (length files)))
      (should (= #o700 (file-modes (directory-file-name (file-name-directory index)))))
      (should (= #o600 (file-modes index)))
      (should (string-match-p (regexp-quote "Today + unread only") text))
      (should (string-match-p "Coverage: 2 of 2 complete histories; 0 unavailable" text))
      (should (string-match-p "Alpha" text))
      (should-not (string-match-p "Changed title\\|Hidden unrelated\\|fixture-account" text))
      (should (string-match-p "https://example.test/b" text))
      (dolist (file files)
        (should (= #o600 (file-modes file)))
        (should (with-temp-buffer
                  (insert-file-contents file)
                  (search-forward "Earlier full history" nil t))))
      (should (equal (format teams4e-view-analysis-prompt index)
                     (plist-get (car submitted) :text)))
      (should (plist-get (car submitted) :submit)))
    (should-not (buffer-local-value 'teams4e-view-analysis--token
                                   (get-buffer teams4e-view-analysis--buffer-name)))))

(ert-deftest teams4e-view-analysis-uses-linked-headers-not-the-open-chat ()
  (teams4e-view-test-session
    (with-temp-buffer
      (teams4e-chat-mode)
      (setq teams4e--chat '((id . "hidden")))
      (teams4e-analyze-view))
    (should (equal "b" (car (last (caar requests)))))
    (kill-buffer headers)
    (teams4e-view-test-complete (car requests))
    (teams4e-view-test-complete (cadr requests))
    (should (= 1 (length launches)))))

(ert-deftest teams4e-view-analysis-failures-are-explicit-and-not-sent-as-source ()
  (teams4e-view-test-session
    (with-current-buffer headers (teams4e-analyze-view))
    (funcall (nth 2 (car requests)) "429" "sensitive-backend-detail")
    (should (= 2 (length requests)))
    (teams4e-view-test-complete (cadr requests))
    (should (= 1 (length errors)))
    (should (= 1 (length launches)))
    (with-temp-buffer
      (insert-file-contents (teams4e-view-test-index))
      (should (search-forward "UNAVAILABLE: Beta" nil t))
      (should (search-forward "Coverage: 1 of 2 complete histories; 1 unavailable" nil t))
      (should-not (string-match-p "sensitive-backend-detail" (buffer-string))))))

(ert-deftest teams4e-view-analysis-rejects-incomplete-or-inconsistent-history ()
  (teams4e-view-test-session
    (with-current-buffer headers (teams4e-analyze-view))
    (teams4e-view-test-complete (car requests) '((history . ((complete . :false)))))
    (teams4e-view-test-complete (cadr requests)
                              '((value . nil) (history . ((complete . t) (messageCount . 5)))))
    (should-not launches)
    (should (= 2 (length errors)))
    (should (teams4e-view-test-index))
    (should-not (directory-files-recursively directory "thread-.*\\.md\\'"))))

(ert-deftest teams4e-view-analysis-cancellation-ignores-late-results-and-allows-restart ()
  (teams4e-view-test-session
    (with-current-buffer headers (teams4e-analyze-view))
    (should-error (with-current-buffer headers (teams4e-analyze-view)) :type 'user-error)
    (teams4e-view-analysis-cancel)
    (with-current-buffer headers (teams4e-analyze-view))
    (teams4e-view-test-complete (car requests))
    (should (= 2 (length requests)))
    (should-not launches)
    (teams4e-view-test-complete (cadr requests))
    (teams4e-view-test-complete (nth 2 requests))
    (should (= 1 (length launches)))))

(ert-deftest teams4e-view-analysis-account-change-stops-collection-and-submission ()
  (teams4e-view-test-session
    (with-current-buffer headers (teams4e-analyze-view))
    (setq teams4e--connected-user-id "different-account")
    (teams4e-view-test-complete (car requests))
    (should (= 1 (length requests)))
    (should-not launches)
    (should-not (directory-files-recursively directory "\\.md\\'"))))

(ert-deftest teams4e-view-analysis-killing-progress-cancels-without-starting-agent ()
  (teams4e-view-test-session
    (with-current-buffer headers (teams4e-analyze-view))
    (kill-buffer teams4e-view-analysis--buffer-name)
    (teams4e-view-test-complete (car requests))
    (should (= 1 (length requests)))
    (should-not launches)))

(ert-deftest teams4e-view-analysis-duplicate-callbacks-do-not-advance-the-next-chat ()
  (teams4e-view-test-session
    (with-current-buffer headers (teams4e-analyze-view))
    (teams4e-view-test-complete (car requests))
    (teams4e-view-test-complete (car requests))
    (funcall (nth 2 (car requests)) "late" "obsolete failure")
    (should (= 2 (length requests)))
    (should-not launches)
    (should-not errors)
    (teams4e-view-test-complete (cadr requests))
    (should (= 1 (length launches)))))

(ert-deftest teams4e-view-analysis-synchronous-adapter-finishes-once ()
  (teams4e-view-test-session
    (cl-letf (((symbol-function 'teams4e--run-json)
               (lambda (_args callback &optional _error)
                 (teams4e-view-test-complete (list nil callback))
                 (teams4e--make-request 1))))
      (with-current-buffer headers (teams4e-analyze-view)))
    (should (= 1 (length launches)))
    (should-not (buffer-local-value 'teams4e-view-analysis--request
                                   (get-buffer teams4e-view-analysis--buffer-name)))))

(ert-deftest teams4e-view-analysis-process-start-error-releases-the-job ()
  (teams4e-view-test-session
    (with-current-buffer headers (teams4e-analyze-view))
    (cl-letf (((symbol-function 'teams4e--run-json)
               (lambda (&rest _) (error "Synthetic process launch failure"))))
      (teams4e-view-test-complete (car requests)))
    (should-not launches)
    (should-not (buffer-local-value 'teams4e-view-analysis--token
                                   (get-buffer teams4e-view-analysis--buffer-name)))))

(ert-deftest teams4e-view-analysis-handoff-failure-releases-the-job ()
  (teams4e-view-test-session
    (with-current-buffer headers (teams4e-analyze-view))
    (teams4e-view-test-complete (car requests))
    (cl-letf (((symbol-function 'agent-shell-start)
               (lambda (&rest _) (error "Synthetic agent start failure"))))
      (teams4e-view-test-complete (cadr requests)))
    (should (teams4e-view-test-index))
    (should-not submitted)
    (should-not (buffer-local-value 'teams4e-view-analysis--token
                                   (get-buffer teams4e-view-analysis--buffer-name)))))

(ert-deftest teams4e-view-analysis-real-mock-backend-exports-both-histories ()
  (let ((run-json (symbol-function 'teams4e--run-json)))
    (teams4e-view-test-session
      (let ((teams4e-backend-program (expand-file-name "bin/teams4e-graph" teams4e-view-test-root))
            (teams4e-use-persistent-backend nil)
            (teams4e-mock-delay-ms 0)
            (teams4e-mock-state-file (expand-file-name "mock.json" directory))
            (teams4e-cache-file (expand-file-name "cache.sqlite3" directory))
            (teams4e--chats '(((id . "chat-1") (topic . "Mock One"))
                              ((id . "chat-2") (topic . "Mock Two")))))
        (with-current-buffer headers
          (setq tabulated-list-entries '(("chat-1" []) ("chat-2" []))))
        (cl-letf (((symbol-function 'teams4e--run-json) run-json))
          (with-current-buffer headers (teams4e-analyze-view))
          (let ((deadline (+ (float-time) 10)))
            (while (and (< (float-time) deadline)
                        (buffer-local-value 'teams4e-view-analysis--token
                                            (get-buffer teams4e-view-analysis--buffer-name)))
              (accept-process-output nil 0.05))))
        (should-not errors)
        (should (= 1 (length launches)))
        (with-temp-buffer
          (insert-file-contents (teams4e-view-test-index))
          (should (search-forward "Coverage: 2 of 2 complete histories; 0 unavailable" nil t)))))))

(ert-deftest teams4e-view-analysis-empty-offline-and-stale-views-do-no-work ()
  (teams4e-view-test-session
    (with-current-buffer headers
      (let ((teams4e-offline-mode t))
        (should-error (teams4e-analyze-view) :type 'user-error))
      (setq tabulated-list-entries nil)
      (should-error (teams4e-analyze-view) :type 'user-error)
      (setq tabulated-list-entries '(("missing" [])))
      (should-error (teams4e-analyze-view) :type 'user-error))
    (should-not requests)
    (should-not launches)))

(ert-deftest teams4e-view-analysis-keys-work-without-activating-another-action ()
  (dolist (mode '(teams4e-recent-mode teams4e-chat-mode))
    (with-temp-buffer
      (funcall mode)
      (should (eq #'teams4e-analyze-view (lookup-key (current-local-map) (kbd "G"))))
      (should (eq #'teams4e-analyze-view (lookup-key (current-local-map) (kbd "a G"))))
      (should (eq #'teams4e-analyze-current-thread
                  (lookup-key (current-local-map) (kbd "a g"))))
      (when (eq mode 'teams4e-chat-mode)
        (should (eq #'teams4e-chat-refresh (lookup-key (current-local-map) (kbd "M-g"))))))))

(ert-deftest teams4e-view-analysis-evil-G-works-in-normal-and-motion ()
  (skip-unless (featurep 'evil))
  (evil-mode 1)
  (dolist (mode '(teams4e-recent-mode teams4e-chat-mode))
    (dolist (state '(normal motion))
      (with-temp-buffer
        (funcall mode)
        (evil-change-state state)
        (should (eq #'teams4e-analyze-view (key-binding (kbd "G"))))
        (teams4e-install-headers-bindings)
        (teams4e-install-chat-reader-bindings)
        (teams4e-evil-refresh-bookmark-bindings)
        (should (eq #'teams4e-analyze-view (key-binding (kbd "G"))))))))

(provide 'teams4e-view-analysis-tests)
;;; teams4e-view-analysis-tests.el ends here
