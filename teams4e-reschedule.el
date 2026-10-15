;;; teams4e-reschedule.el --- Calendar comparison and move review -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Commentary:
;; A projection of the availability payload, not another calendar store.
;;; Code:
(require 'teams4e-meetings)
(defvar teams4e-calendar-work-hours)
(defvar teams4e-calendar-work-days)

(defun teams4e-reschedule--slot (start end)
  "Return a UTC slot from START to END."
  `((start (dateTime . ,(teams4e--proposal-utc-string start)) (timeZone . "UTC"))
    (end (dateTime . ,(teams4e--proposal-utc-string end)) (timeZone . "UTC"))))

(defun teams4e-reschedule--day-bounds ()
  "Return local working-hour bounds for the selected day, including DST."
  (let* ((day (or teams4e-availability--day
                  (teams4e-availability--midnight (teams4e-availability--original-time))))
         (parts (decode-time day))
         (hours (if (boundp 'teams4e-calendar-work-hours) teams4e-calendar-work-hours '(0 . 24))))
    (unless (and (integerp (car hours)) (integerp (cdr hours))
                 (<= 0 (car hours)) (< (car hours) (cdr hours)) (<= (cdr hours) 24))
      (user-error "Calendar work hours must be a valid (START . END) within 0..24"))
    (mapcar (lambda (hour)
              (if (= hour 24)
                  (teams4e-availability--midnight day 1)
                (encode-time 0 0 hour (nth 3 parts) (nth 4 parts) (nth 5 parts))))
            (list (car hours) (cdr hours)))))

(defun teams4e-reschedule--duration ()
  "Return the occurrence's duration."
  (time-subtract (teams4e-availability--time (teams4e-availability--event) 'end)
                 (teams4e-availability--original-time)))

(defun teams4e-reschedule--common-runs ()
  "Return confirmed common free stretches and a fitting first candidate in each."
  (let* ((teams4e-availability--view 'timeline)
         (bounds (teams4e-reschedule--day-bounds))
         (workday (or (not (eq teams4e-availability--activity-domain 'work))
                      (not (boundp 'teams4e-calendar-work-days))
                      (memq (nth 6 (decode-time (car bounds))) teams4e-calendar-work-days)))
         runs)
    (when workday
      (dolist (suggestion (teams4e-availability--suggestions))
        (let* ((slot (teams4e--get suggestion 'meetingTimeSlot))
               (start (teams4e-availability--time slot 'start))
               (end (teams4e-availability--time slot 'end)))
          (when (and (= 100 (teams4e--get suggestion 'confidence))
                     (time-less-p (current-time) start)
                     (not (equal start (teams4e-availability--original-time)))
                     (not (time-less-p start (car bounds)))
                     (not (time-less-p (cadr bounds) end)))
            (if (and runs (not (time-less-p (cadar runs) start)))
                (setcar (cdar runs) end)
              (push (list start end slot) runs))))))
    (nreverse runs)))

(defun teams4e-reschedule--review (slot)
  "Stage SLOT for review without any network mutation."
  (when teams4e-availability--submission
    (user-error "Submission pending or uncertain; check the calendar before refreshing"))
  (teams4e-availability--require-proposal)
  (let ((start (teams4e-availability--time slot 'start))
        (end (teams4e-availability--time slot 'end)))
    (unless (and start end (time-less-p (current-time) start) (time-less-p start end))
      (user-error "Choose a future time with a positive duration"))
    (when (equal start (teams4e-availability--original-time))
      (user-error "That is the current meeting time; select another slot"))
    (setq teams4e-availability--review-slot slot)
    (teams4e-availability--render)))

(defun teams4e-reschedule-common-free ()
  "Choose a confirmed common free stretch on the selected day."
  (interactive)
  (let* ((runs (teams4e-reschedule--common-runs))
         (choices (mapcar (lambda (run)
                            (cons (format "%s - %s"
                                          (format-time-string "%H:%M %Z" (car run))
                                          (format-time-string "%H:%M %Z" (cadr run)))
                                  (nth 2 run))) runs)))
    (unless choices (user-error "No confirmed common free stretch fits this meeting on this day"))
    (when-let ((slot (cdr (assoc (completing-read "Common free time: " choices nil t) choices))))
      (teams4e-reschedule--review slot))))

(defun teams4e-reschedule-compare ()
  "Show the selected day's participant comparison without fetching."
  (interactive)
  (teams4e-availability-set-view 'timeline)
  (goto-char (point-min))
  (when (search-forward "Working-day comparison" nil t)
    (beginning-of-line))
  (when-let ((window (get-buffer-window (current-buffer))))
    (set-window-start window (point))))

(defun teams4e-reschedule--insert-day-map ()
  "Insert a compact, clickable participant comparison, using only loaded data."
  (let* ((teams4e-availability--time-cache (make-hash-table :test #'equal))
         (bounds (teams4e-reschedule--day-bounds))
         (width (max 12 (- (window-body-width) 20)))
         (minutes (/ (float-time (time-subtract (cadr bounds) (car bounds))) 60))
         (step (* 60 30 (max 1 (ceiling (/ (* 2 minutes) (* 30 width))))))
         (cursor (car bounds)) cells)
    (while (time-less-p cursor (cadr bounds))
      (push (teams4e-reschedule--slot cursor
                                      (time-add cursor (seconds-to-time (min step (float-time (time-subtract (cadr bounds) cursor)))))) cells)
      (setq cursor (time-add cursor step)))
    (setq cells (nreverse cells))
    (insert (propertize "Working-day comparison\n" 'face 'bold))
    (insert (format "%-18s" ""))
    (cl-loop for cell in cells for i from 0 do
             (insert (if (= 0 (% i 2))
                         (format-time-string "%H" (teams4e-availability--time cell 'start)) "  ")))
    (insert "\n")
    (dolist (person (append (teams4e-availability--participants) '(common)))
      (teams4e-availability--insert-cell
       (if (eq person 'common) "Common free" (teams4e-availability--participant-name person)) 16 'bold)
      (dolist (cell cells)
        (let* ((statuses (if (eq person 'common)
                             (mapcar (lambda (p) (teams4e-availability--slot-status p cell))
                                     (teams4e-availability--participants))
                           (list (teams4e-availability--slot-status person cell))))
               (status (or (seq-find #'teams4e-availability--blocking-status-p statuses)
                           (and statuses "free") "unknown"))
               (mark (pcase (downcase status)
                       ((or "free" "workingelsewhere") "..")
                       ("tentative" "~~") ((or "oof" "outofoffice") "@@")
                       ("unknown" "??") (_ "##")))
               (start (teams4e-availability--time cell 'start)))
          (insert-text-button mark 'face (teams4e-availability--status-face status)
                              'help-echo (concat (teams4e--meeting-slot-time-label cell) " / " status)
                              'follow-link t 'action
                              (lambda (_)
                                (teams4e-reschedule--review
                                 (teams4e-reschedule--slot start (time-add start (teams4e-reschedule--duration))))))))
      (insert "\n"))
    (insert (propertize ".. free   ## busy   ~~ tentative   @@ away   ?? unknown\n" 'face 'shadow))
    (let ((runs (teams4e-reschedule--common-runs)))
      (insert "Fits everyone: ")
      (if (null runs) (insert "none confirmed in working hours")
        (dolist (run runs)
          (let ((slot (nth 2 run)))
            (insert-text-button (format "%s-%s" (format-time-string "%H:%M" (car run))
                                        (format-time-string "%H:%M" (cadr run)))
                                'face 'teams4e-availability-free 'follow-link t
                                'action (lambda (_) (teams4e-reschedule--review slot)))
            (insert "  "))))
      (insert "\n\n"))))

(defun teams4e-reschedule--insert-review ()
  "Render the exact pending change and current participant conflicts."
  (let* ((slot teams4e-availability--review-slot)
         (event (teams4e-availability--event))
         (moving (teams4e-availability--reschedule-p)))
    (insert (propertize (if moving "Review meeting move\n\n" "Review time proposal\n\n") 'face 'bold))
    (insert "From  " (teams4e--meeting-slot-time-label event) "\n"
            "To    " (teams4e--meeting-slot-time-label slot) "\n"
            (format "Duration  %d minutes\n\n" (/ (float-time (teams4e-reschedule--duration)) 60)))
    (dolist (person (teams4e-availability--participants))
      (let ((status (teams4e-availability--slot-status person slot)))
        (insert (propertize (concat (teams4e-availability--participant-name person) "  "
                                    (teams4e-availability--status-name status))
                            'face (teams4e-availability--status-face status)) "\n")
        (dolist (item (teams4e-availability--conflict-items person slot))
          (insert "  " (teams4e--meeting-slot-time-label item) "  "
                  (teams4e-availability--block-title item) "\n"))))
    (insert "\n" (if moving
                     "Only this occurrence moves; attendees receive an update.\n"
                   "The organizer receives a proposal; the meeting does not move until accepted.\n")
            "Only a positively identified own occurrence is released for planning.\n"
            "Other participants' unidentified blocks remain busy.\n"
            "Availability is a snapshot, not a reservation.\n\n")
    (insert-text-button (if moving "Send update" "Send proposal") 'follow-link t
                        'action (lambda (_) (teams4e-reschedule-submit)))
    (insert "    ")
    (insert-text-button "Back to times" 'follow-link t
                        'action (lambda (_) (teams4e-reschedule-back)))
    (insert "\n")))

(defun teams4e-reschedule-back ()
  "Leave review without sending or reloading."
  (interactive)
  (setq teams4e-availability--review-slot nil)
  (teams4e-availability--render))

(defun teams4e-reschedule-submit ()
  "Submit the reviewed time once; no additional confirmation dialog."
  (interactive)
  (when teams4e-availability--submission
    (user-error "Submission pending or uncertain; check the calendar before refreshing"))
  (let ((slot (or teams4e-availability--review-slot (user-error "Review a time first")))
        (workspace (current-buffer)))
    (teams4e-availability--require-proposal)
    (unless (time-less-p (current-time) (teams4e-availability--time slot 'start))
      (user-error "This time has passed; choose another slot"))
    (setq teams4e-availability--review-slot nil teams4e-availability--submission 'sending)
    (condition-case err
        (progn
          (if teams4e-availability--proposal-function
              (funcall teams4e-availability--proposal-function slot)
            (teams4e--proposal-send
             teams4e-availability--chat teams4e-availability--event-id slot
             (lambda (_)
               (when (buffer-live-p workspace)
                 (with-current-buffer workspace (teams4e-availability-quit))))))
          (when (and (buffer-live-p workspace)
                     (eq (buffer-local-value 'teams4e-availability--submission workspace) 'sending))
            (with-current-buffer workspace (teams4e-availability--render))))
      (quit
       (setq teams4e-availability--submission nil teams4e-availability--review-slot slot)
       (signal (car err) (cdr err)))
      (error
       (setq teams4e-availability--submission 'uncertain)
       (signal (car err) (cdr err))))))

(provide 'teams4e-reschedule)
;;; teams4e-reschedule.el ends here
