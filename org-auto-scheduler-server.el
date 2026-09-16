;;; org-auto-scheduler-server.el --- Server and REST API integration for org-auto-scheduler -*- lexical-binding: t; -*-

;; Author: SSD2019
;; Keywords: calendar, convenience, org, tools, api
;; Package-Requires: ((emacs "27.1") (org "9.3"))

;;; Commentary:
;; This package provides JSON-ready API endpoints and server process management
;; for org-auto-scheduler, enabling remote connection from mobile apps (Android)
;; and other HTTP clients.

;;; Code:

(require 'org)
(require 'org-agenda)
(require 'org-id)
(require 'json)
(require 'org-auto-scheduler)

(defgroup org-auto-scheduler-server nil
  "Server and API settings for org-auto-scheduler."
  :group 'org-auto-scheduler
  :prefix "org-auto-scheduler-server-")

(defcustom org-auto-scheduler-server-port 8989
  "Port number for the org-auto-scheduler HTTP bridge server."
  :type 'integer
  :group 'org-auto-scheduler-server)

(defcustom org-auto-scheduler-server-host "0.0.0.0"
  "Host address to bind the HTTP bridge server to."
  :type 'string
  :group 'org-auto-scheduler-server)

(defcustom org-auto-scheduler-server-token ""
  "Optional authentication token for the HTTP bridge server.
Empty string means no authentication required."
  :type 'string
  :group 'org-auto-scheduler-server)

(defvar org-auto-scheduler-server--process nil
  "Background process running the HTTP bridge server.")

;;; API Helpers

(defun org-auto-scheduler-api--clean-string (str)
  "Strip text properties and trim whitespace from STR."
  (if (stringp str)
      (string-trim (substring-no-properties str))
    ""))

(defun org-auto-scheduler-api--task-to-plist (marker)
  "Extract task metadata from MARKER into a JSON-friendly plist."
  (org-with-point-at marker
    (let* ((id (or (org-id-get)
                   (progn
                     (org-id-get-create)
                     (org-id-get))))
           (heading (org-auto-scheduler-api--clean-string (org-get-heading t t t t)))
           (todo (org-auto-scheduler-api--clean-string (org-get-todo-state)))
           (priority (org-entry-get nil "PRIORITY"))
           (effort (org-entry-get nil "Effort"))
           (scheduled (org-entry-get nil "SCHEDULED"))
           (deadline (org-entry-get nil "DEADLINE"))
           (tags (org-get-tags))
           (file (buffer-file-name))
           (project (org-auto-scheduler--get-project-name marker))
           (props (org-entry-properties nil 'standard))
           (not-before (org-entry-get nil "NOT_BEFORE"))
           (blockers (org-entry-get nil "BLOCKER"))
           (depends-on (org-entry-get nil "DEPENDS_ON"))
           (recurring (org-entry-get nil "RECURRING"))
           (is-autosch (member "AUTOSCH" tags))
           (custom-props (cl-remove-if (lambda (p)
                                         (member (car p)
                                                 '("ID" "CATEGORY" "TODO" "PRIORITY" "Effort"
                                                   "SCHEDULED" "DEADLINE" "TAGS" "BLOCKED" "FILE")))
                                       props)))
      (list :id (or id "")
            :heading (or heading "")
            :todo (or todo "")
            :priority (or priority "")
            :effort (or effort "")
            :scheduled (or scheduled "")
            :deadline (or deadline "")
            :tags (if tags (vconcat tags) [])
            :file (or file "")
            :project (or project "")
            :is_autosch (if is-autosch t :false)
            :not_before (or not-before "")
            :blocker (or blockers "")
            :depends_on (or depends-on "")
            :recurring (or recurring "")
            :properties (vconcat
                         (mapcar (lambda (kv)
                                   (list :key (car kv) :value (cdr kv)))
                                 custom-props))))))

;;; API Functions

(defun org-auto-scheduler-api-status ()
  "Return system status as a JSON string."
  (let* ((agenda-files (org-agenda-files t))
         (todo-kws (cl-remove-if (lambda (k) (or (null k) (string= k "|")))
                                 (delete-dups
                                  (delq nil
                                        (mapcar (lambda (kw)
                                                  (when (stringp kw)
                                                    (if (string-match "^\\([A-Za-z0-9_-]+\\)" kw)
                                                        (match-string 1 kw)
                                                      kw)))
                                                (flatten-list org-todo-keywords))))))
         (review-active (and (get-buffer "*Org Auto Scheduler Review*") t))
         (res (list :status "ok"
                    :version "1.0.0"
                    :emacs_version emacs-version
                    :agenda_files_count (length agenda-files)
                    :todo_keywords (vconcat (or todo-kws '("TODO" "NEXT" "DONE")))
                    :review_active (if review-active t :false)
                    :timestamp (format-time-string "%Y-%m-%dT%H:%M:%S%z"))))
    (json-serialize res)))

(defun org-auto-scheduler-api-agenda (&optional date-str days-count)
  "Return agenda tasks and events for DATE-STR spanning DAYS-COUNT days as JSON.
DATE-STR defaults to today. DAYS-COUNT defaults to 1."
  (let* ((start-date (if (and date-str (not (string-empty-p date-str)))
                         date-str
                       (format-time-string "%Y-%m-%d")))
         (count (or days-count 1))
         (days-result []))
    (dotimes (i count)
      (let* ((current-time (time-add (org-auto-scheduler-parse-time-string (concat start-date " 00:00"))
                                     (days-to-time i)))
             (day-str (format-time-string "%Y-%m-%d" current-time))
             (day-label (format-time-string "%A, %b %d" current-time))
             (items (org-auto-scheduler-get-agenda-items current-time))
             (tasks-list '())
             (events-list '()))

        (dolist (item items)
          (let* ((task-id (nth 0 item))
                 (start-time (nth 1 item))
                 (end-time (nth 2 item))
                 (tags (nth 3 item))
                 (is-autosch (member "AUTOSCH" tags))
                 (headline (org-auto-scheduler-api--clean-string (nth 5 item)))
                 (marker (nth 7 item))
                 (start-str (if start-time (format-time-string "%H:%M" start-time) ""))
                 (end-str (if end-time (format-time-string "%H:%M" end-time) ""))
                 (duration-min (if (and start-time end-time)
                                   (round (/ (float-time (time-subtract end-time start-time)) 60))
                                 0)))

            (if (or is-autosch (and marker (org-id-find task-id t)))
                ;; Schedulable / Org task
                (let* ((m (or marker (org-id-find task-id t)))
                       (task-plist (if m
                                       (org-auto-scheduler-api--task-to-plist m)
                                     (list :id (or task-id "")
                                           :heading headline
                                           :todo ""
                                           :priority ""
                                           :effort ""
                                           :scheduled ""
                                           :deadline ""
                                           :tags (if tags (vconcat tags) [])
                                           :file ""
                                           :project ""
                                           :is_autosch (if is-autosch t :false)))))
                  (setq task-plist (plist-put task-plist :start_time start-str))
                  (setq task-plist (plist-put task-plist :end_time end-str))
                  (setq task-plist (plist-put task-plist :duration duration-min))
                  (push task-plist tasks-list))
              ;; Fixed calendar / agenda event
              (push (list :id (or task-id (format "ev-%s-%s" day-str start-str))
                          :title headline
                          :start_time start-str
                          :end_time end-str
                          :duration duration-min
                          :is_event t)
                    events-list))))

        (setq tasks-list (sort tasks-list (lambda (a b)
                                            (string< (plist-get a :start_time)
                                                     (plist-get b :start_time)))))
        (setq events-list (sort events-list (lambda (a b)
                                              (string< (plist-get a :start_time)
                                                       (plist-get b :start_time)))))

        (setq days-result (vconcat days-result
                                   (list (list :date day-str
                                               :label day-label
                                               :is_today (if (string= day-str (format-time-string "%Y-%m-%d")) t :false)
                                               :tasks (vconcat (nreverse tasks-list))
                                               :events (vconcat (nreverse events-list))))))))
    (json-serialize (list :status "ok" :days days-result))))

(defun org-auto-scheduler-api-review-state (&optional force-run)
  "Return current Review & Apply state as a JSON string.
If FORCE-RUN is non-nil or buffer does not exist, runs scheduler in preview mode."
  (when (or force-run (null (get-buffer "*Org Auto Scheduler Review*")))
    (save-window-excursion
      (let ((org-auto-scheduler-review-auto-save-decisions nil))
        (org-auto-scheduler-review-and-apply))))
  (let ((entries-result [])
        (total-tasks 0)
        (checked-count 0)
        (warning-count 0))
    (with-current-buffer (get-buffer-create "*Org Auto Scheduler Review*")
      (dolist (e tabulated-list-entries)
        (let* ((id (car e))
               (vec (cadr e)))
          (cond
           ;; Header shortcut row - skip
           ((string= id "__header_shortcuts") nil)

           ;; Day Separator row
           ((string-prefix-p "__sep_" id)
            (let* ((date-str (substring id 6))
                   (text (org-auto-scheduler-api--clean-string (aref vec 2))))
              (setq entries-result
                    (vconcat entries-result
                             (list (list :type "separator"
                                         :id id
                                         :date date-str
                                         :label text))))))

           ;; Fixed Agenda Event row
           ((string-prefix-p "__event_" id)
            (let* ((headline (org-auto-scheduler-api--clean-string (aref vec 2)))
                   (time-str (org-auto-scheduler-api--clean-string (aref vec 3)))
                   (duration (org-auto-scheduler-api--clean-string (aref vec 4))))
              (setq entries-result
                    (vconcat entries-result
                             (list (list :type "event"
                                         :id id
                                         :headline headline
                                         :time_str time-str
                                         :duration duration))))))

           ;; Schedulable Task row
           (t
            (let* ((checked (string= (aref vec 0) "[X]"))
                   (color-prop (get-text-property 0 'face (aref vec 1)))
                   (color (cond
                           ((and (listp color-prop) (plist-get color-prop :foreground))
                            (plist-get color-prop :foreground))
                           (t "#61afef")))
                   (headline (org-auto-scheduler-api--clean-string (aref vec 2)))
                   (time-str (org-auto-scheduler-api--clean-string (aref vec 3)))
                   (duration (org-auto-scheduler-api--clean-string (aref vec 4)))
                   (project (org-auto-scheduler-api--clean-string (aref vec 5)))
                   (score (org-auto-scheduler-api--clean-string (aref vec 6)))
                   (status (org-auto-scheduler-api--clean-string (aref vec 7)))
                   (task-data (assoc id org-auto-scheduler-completed-tasks))
                   (marker (and task-data (nth 7 task-data)))
                   (warns (and task-data marker (org-auto-scheduler--check-task-warnings task-data marker)))
                   (clean-warns (mapcar #'org-auto-scheduler-api--clean-string (or warns '()))))

              (setq total-tasks (1+ total-tasks))
              (when checked (setq checked-count (1+ checked-count)))
              (when clean-warns (setq warning-count (1+ warning-count)))

              (setq entries-result
                    (vconcat entries-result
                             (list (list :type "task"
                                         :id id
                                         :checked (if checked t :false)
                                         :project_color color
                                         :headline headline
                                         :time_str time-str
                                         :duration duration
                                         :project project
                                         :score score
                                         :status status
                                         :warnings (vconcat clean-warns)))))))))))
    (json-serialize
     (list :status "ok"
           :entries entries-result
           :summary (list :total total-tasks
                          :checked checked-count
                          :warnings warning-count)
           :undo_available (if (and (boundp 'org-auto-scheduler--review-undo-stack)
                                    org-auto-scheduler--review-undo-stack)
                               t :false)))))

(defun org-auto-scheduler-api--find-review-row (task-id)
  "Navigate point to the row for TASK-ID in `*Org Auto Scheduler Review*` buffer."
  (let ((found nil))
    (goto-char (point-min))
    (while (and (not (eobp)) (not found))
      (if (equal (tabulated-list-get-id) task-id)
          (setq found t)
        (forward-line 1)))
    found))

(defun org-auto-scheduler-api-review-action (action-type &optional task-id arg-val)
  "Execute ACTION-TYPE on the review buffer and return updated state JSON."
  (let ((buf (get-buffer "*Org Auto Scheduler Review*")))
    (unless buf
      (save-window-excursion
        (let ((org-auto-scheduler-review-auto-save-decisions nil))
          (org-auto-scheduler-review-and-apply)))
      (setq buf (get-buffer "*Org Auto Scheduler Review*")))
    (with-current-buffer buf
      (cond
       ;; Toggle task mark
       ((string= action-type "toggle")
        (when (org-auto-scheduler-api--find-review-row task-id)
          (org-auto-scheduler-review-toggle)))

       ;; Move up
       ((string= action-type "move-up")
        (when (org-auto-scheduler-api--find-review-row task-id)
          (org-auto-scheduler-review-move-up)))

       ;; Move down
       ((string= action-type "move-down")
        (when (org-auto-scheduler-api--find-review-row task-id)
          (org-auto-scheduler-review-move-down)))

       ;; Move day forward
       ((string= action-type "move-day-forward")
        (when (org-auto-scheduler-api--find-review-row task-id)
          (org-auto-scheduler-review-move-day-forward)))

       ;; Move day backward
       ((string= action-type "move-day-backward")
        (when (org-auto-scheduler-api--find-review-row task-id)
          (org-auto-scheduler-review-move-day-backward)))

       ;; Move to specific day
       ((string= action-type "move-to-day")
        (when (and arg-val (org-auto-scheduler-api--find-review-row task-id))
          (org-auto-scheduler-review-move-to-day arg-val)))

       ;; In-memory Effort edit
       ((string= action-type "edit-effort")
        (when (and arg-val (org-auto-scheduler-api--find-review-row task-id))
          (org-auto-scheduler-review-edit-effort arg-val)))

       ;; Recalculate schedule
       ((string= action-type "recalculate")
        (org-auto-scheduler-review-recalculate))

       ;; Toggle fixed agenda events
       ((string= action-type "toggle-events")
        (org-auto-scheduler-review-toggle-agenda-events))

       ;; Undo
       ((string= action-type "undo")
        (when (and (boundp 'org-auto-scheduler--review-undo-stack)
                   org-auto-scheduler--review-undo-stack)
          (org-auto-scheduler-review-undo)))

       ;; Bulk mark operations
       ((string= action-type "mark-all")
        (org-auto-scheduler-review-mark-all))

       ((string= action-type "unmark-all")
        (org-auto-scheduler-review-unmark-all))

       ((string= action-type "mark-today")
        (org-auto-scheduler-review-mark-today))

       ;; Filter operations
       ((string= action-type "filter-today")
        (org-auto-scheduler-review-filter-today))

       ((string= action-type "filter-clear")
        (org-auto-scheduler-review-filter-clear))

       ((string= action-type "filter-regexp")
        (when arg-val (org-auto-scheduler-review-filter-regexp arg-val)))

       ;; Discard and refresh from scratch
       ((string= action-type "refresh")
        (org-auto-scheduler-review-refresh))

       ;; Apply changes to Org files!
       ((string= action-type "apply")
        (let ((result-msg (condition-case err
                              (progn
                                (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t)))
                                  (org-auto-scheduler-review-execute))
                                "Schedule successfully applied to Org files!")
                            (error (error-message-string err)))))
          (cl-return-from org-auto-scheduler-api-review-action
            (json-serialize (list :status "applied" :message result-msg))))))))
  (org-auto-scheduler-api-review-state))

(defun org-auto-scheduler-api-get-task (task-id)
  "Return full task metadata and properties drawer for TASK-ID as JSON."
  (let ((marker (org-id-find task-id t)))
    (if (null marker)
        (json-serialize (list :status "error" :message (format "Task ID not found: %s" task-id)))
      (json-serialize (plist-put (org-auto-scheduler-api--task-to-plist marker)
                                 :status "ok")))))

(defun org-auto-scheduler-api-edit-task (task-id json-payload)
  "Update properties for TASK-ID using JSON-PAYLOAD string, and save the file."
  (let ((marker (org-id-find task-id t)))
    (if (null marker)
        (json-serialize (list :status "error" :message (format "Task ID not found: %s" task-id)))
      (let* ((data (json-parse-string json-payload :object-type 'plist))
             (heading (plist-get data :heading))
             (todo (plist-get data :todo))
             (priority (plist-get data :priority))
             (effort (plist-get data :effort))
             (scheduled (plist-get data :scheduled))
             (deadline (plist-get data :deadline))
             (tags (plist-get data :tags))
             (not-before (plist-get data :not_before))
             (blocker (plist-get data :blocker))
             (depends-on (plist-get data :depends_on))
             (recurring (plist-get data :recurring))
             (custom-props (plist-get data :properties)))
        (org-with-point-at marker
          ;; Edit headline
          (when (and heading (not (string-empty-p heading)))
            (org-edit-headline heading))

          ;; Edit TODO state
          (when (and todo (not (string-empty-p todo)))
            (org-todo todo))

          ;; Edit Priority
          (when priority
            (if (string-empty-p priority)
                (org-priority ?\s)
              (org-priority (aref priority 0))))

          ;; Edit Effort
          (when effort
            (if (string-empty-p effort)
                (org-entry-delete nil "Effort")
              (org-entry-put nil "Effort" effort)))

          ;; Edit Scheduled
          (when scheduled
            (if (string-empty-p scheduled)
                (org-schedule '(4))
              (org-schedule nil scheduled)))

          ;; Edit Deadline
          (when deadline
            (if (string-empty-p deadline)
                (org-deadline '(4))
              (org-deadline nil deadline)))

          ;; Edit Tags
          (when tags
            (org-set-tags (append tags nil)))

          ;; Edit standard autosch properties
          (when not-before
            (if (string-empty-p not-before)
                (org-entry-delete nil "NOT_BEFORE")
              (org-entry-put nil "NOT_BEFORE" not-before)))

          (when blocker
            (if (string-empty-p blocker)
                (org-entry-delete nil "BLOCKER")
              (org-entry-put nil "BLOCKER" blocker)))

          (when depends-on
            (if (string-empty-p depends-on)
                (org-entry-delete nil "DEPENDS_ON")
              (org-entry-put nil "DEPENDS_ON" depends-on)))

          (when recurring
            (if (string-empty-p recurring)
                (org-entry-delete nil "RECURRING")
              (org-entry-put nil "RECURRING" recurring)))

          ;; Custom properties
          (when (vectorp custom-props)
            (dolist (prop (append custom-props nil))
              (let ((k (plist-get prop :key))
                    (v (plist-get prop :value)))
                (when (and k (not (string-empty-p k)))
                  (if (or (null v) (string-empty-p v))
                      (org-entry-delete nil k)
                    (org-entry-put nil k v))))))

          (save-buffer))
        (json-serialize (plist-put (org-auto-scheduler-api--task-to-plist marker)
                                   :status "ok"))))))

(defun org-auto-scheduler-api-bump-agenda (task-id minutes)
  "Bump TASK-ID and subsequent AUTOSCH tasks today by MINUTES."
  (let* ((marker (org-id-find task-id t))
         (current-time (current-time))
         (day-start (org-auto-scheduler-time-with-time-string current-time org-auto-scheduler-start-time))
         (agenda-items (org-auto-scheduler-get-agenda-items day-start))
         (bump-seconds (* minutes 60))
         (found-target nil)
         (bumped-count 0))
    (if (null marker)
        (json-serialize (list :status "error" :message "Task not found"))
      (dolist (item (sort agenda-items (lambda (a b) (time-less-p (nth 1 a) (nth 1 b)))))
        (let* ((tid (nth 0 item))
               (start-time (nth 1 item))
               (end-time (nth 2 item))
               (tags (nth 3 item))
               (is-autosch (member "AUTOSCH" tags)))
          (when (equal tid task-id)
            (setq found-target t))
          (when (and found-target is-autosch)
            (let* ((item-marker (org-id-find tid t))
                   (new-start (time-add start-time (seconds-to-time bump-seconds)))
                   (new-end (time-add end-time (seconds-to-time bump-seconds))))
              (when item-marker
                (org-with-point-at item-marker
                  (let* ((start-day (format-time-string "%Y-%m-%d" new-start))
                         (end-day (format-time-string "%Y-%m-%d" new-end))
                         (schedule-string
                          (if (string= start-day end-day)
                              (format "<%s-%s>"
                                      (format-time-string "%Y-%m-%d %a %H:%M" new-start)
                                      (format-time-string "%H:%M" new-end))
                            (format "<%s>--<%s>"
                                      (format-time-string "%Y-%m-%d %a %H:%M" new-start)
                                      (format-time-string "%Y-%m-%d %a %H:%M" new-end)))))
                    (org-set-property "SCHEDULED" schedule-string)
                    (setq bumped-count (1+ bumped-count)))))))))
      (save-some-buffers t (lambda ()
                             (and (buffer-file-name)
                                  (member (buffer-file-name) (org-agenda-files t)))))
      (json-serialize (list :status "ok"
                            :bumped_count bumped-count
                            :minutes minutes)))))

(defun org-auto-scheduler-api-clock (task-id action)
  "Perform clock ACTION ("in" or "out") on TASK-ID."
  (let ((marker (org-id-find task-id t)))
    (if (null marker)
        (json-serialize (list :status "error" :message "Task not found"))
      (org-with-point-at marker
        (if (string= action "in")
            (progn
              (org-clock-in)
              (json-serialize (list :status "ok" :action "in" :message "Clocked in")))
          (progn
            (org-clock-out)
            (json-serialize (list :status "ok" :action "out" :message "Clocked out"))))))))

(defun org-auto-scheduler-api-create-task (json-payload)
  "Create a new task in the primary agenda file using JSON-PAYLOAD string."
  (let* ((data (json-parse-string json-payload :object-type 'plist))
         (heading (or (plist-get data :heading) "New Task"))
         (todo (or (plist-get data :todo) "TODO"))
         (effort (plist-get data :effort))
         (priority (plist-get data :priority))
         (tags (or (plist-get data :tags) ["AUTOSCH"]))
         (target-file (or (car (org-agenda-files t)) (buffer-file-name))))
    (unless target-file
      (error "No agenda file available to create task"))
    (with-current-buffer (find-file-noselect target-file)
      (goto-char (point-max))
      (unless (bolp) (insert "
"))
      (insert (format "* %s %s
" todo heading))
      (let ((marker (point-marker)))
        (org-with-point-at marker
          (forward-line -1)
          (org-id-get-create)
          (let ((new-id (org-id-get)))
            (when (and priority (not (string-empty-p priority)))
              (org-priority (aref priority 0)))
            (when (and effort (not (string-empty-p effort)))
              (org-entry-put nil "Effort" effort))
            (when tags
              (org-set-tags (append tags nil)))
            (save-buffer)
            (json-serialize (list :status "ok"
                                  :id new-id
                                  :message "Task created successfully"))))))))

(defun org-auto-scheduler-api-adherence ()
  "Return adherence data and stats as JSON."
  (let* ((today-str (format-time-string "%Y-%m-%d"))
         (streak (if (boundp 'org-auto-scheduler-streak-count)
                     org-auto-scheduler-streak-count 0))
         (score (if (fboundp 'org-auto-scheduler-score-schedule)
                    (condition-case nil
                        (org-auto-scheduler-score-schedule)
                      (error nil))
                  nil)))
    (json-serialize (list :status "ok"
                          :today today-str
                          :streak streak
                          :score (or score 0)))))

(defun org-auto-scheduler-api-snapshot ()
  "Trigger morning snapshot."
  (org-auto-scheduler-snapshot-schedule)
  (json-serialize (list :status "ok" :message "Morning snapshot captured successfully")))

(defun org-auto-scheduler-api-jump (task-id)
  "Jump to TASK-ID in Emacs window."
  (let ((marker (org-id-find task-id t)))
    (if (null marker)
        (json-serialize (list :status "error" :message "Task not found"))
      (switch-to-buffer (marker-buffer marker))
      (goto-char (marker-position marker))
      (org-show-entry)
      (recenter)
      (json-serialize (list :status "ok" :message "Jumped to task in Emacs")))))

;;; Server Process Management

(defun org-auto-scheduler-server-start (&optional port)
  "Start the HTTP bridge server for mobile access on PORT (default: `org-auto-scheduler-server-port`)."
  (interactive)
  (let* ((p (or port org-auto-scheduler-server-port))
         (dir (file-name-directory (locate-library "org-auto-scheduler")))
         (script (expand-file-name "server/org_auto_scheduler_server.py" dir)))
    (if (and org-auto-scheduler-server--process
             (process-live-p org-auto-scheduler-server--process))
        (message "Org Auto Scheduler server is already running (PID: %s)"
                 (process-id org-auto-scheduler-server--process))
      (unless (file-exists-p script)
        (error "Server script not found at %s" script))
      (let* ((cmd (list "python3" script
                        "--port" (number-to-string p)
                        "--host" org-auto-scheduler-server-host
                        "--static-dir" (expand-file-name "android-app" dir)))
             (proc (make-process :name "org-auto-scheduler-server"
                                 :buffer "*Org Auto Scheduler Server*"
                                 :command (if (and org-auto-scheduler-server-token
                                                   (not (string-empty-p org-auto-scheduler-server-token)))
                                              (append cmd (list "--token" org-auto-scheduler-server-token))
                                            cmd)
                                 :noquery t)))
        (setq org-auto-scheduler-server--process proc)
        (message "Org Auto Scheduler server started on http://%s:%d"
                 (if (string= org-auto-scheduler-server-host "0.0.0.0") "localhost" org-auto-scheduler-server-host)
                 p)))))

(defun org-auto-scheduler-server-stop ()
  "Stop the HTTP bridge server."
  (interactive)
  (if (and org-auto-scheduler-server--process
           (process-live-p org-auto-scheduler-server--process))
      (progn
        (delete-process org-auto-scheduler-server--process)
        (setq org-auto-scheduler-server--process nil)
        (message "Org Auto Scheduler server stopped"))
    (message "Org Auto Scheduler server is not running")))

(provide 'org-auto-scheduler-server)
;;; org-auto-scheduler-server.el ends here
