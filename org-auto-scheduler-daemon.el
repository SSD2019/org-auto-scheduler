;;; org-auto-scheduler-daemon.el --- Background runner & audit logger -*- lexical-binding: t; -*-

;; Copyright (C) 2024-2026 SSD2019
;; License: GPL-3.0-or-later

;;; Commentary:
;;
;; Background daemon runner, idle timer scheduling, computer hostname checks,
;; and change-log auditing for org-auto-scheduler.

;;; Code:

(eval-and-compile
  (let ((dir (file-name-directory (or load-file-name buffer-file-name default-directory))))
    (when (and dir (file-directory-p dir))
      (add-to-list 'load-path dir))))

(require 'org)
(require 'cl-lib)

(defvar org-auto-scheduler--idle-timer nil
  "Primary idle timer for background auto-scheduling.")

(defvar org-auto-scheduler--repeat-idle-timer nil
  "Timer for repeating background auto-scheduling during continuous idle.")

(defvar org-auto-scheduler--background-running nil
  "Flag to prevent concurrent background scheduling runs.")

(defvar org-auto-scheduler--background-thread nil
  "Thread object running the background scheduler asynchronously.")

(defun org-auto-scheduler-background-run ()
  "Run the scheduler silently in the background.
If `org-auto-scheduler-background-async' is non-nil and `make-thread' is supported,
runs asynchronously in a worker thread so the Emacs UI remains fully responsive."
  (interactive)
  (cond
   ((not org-auto-scheduler-background-enabled)
    (org-auto-scheduler--log-debug "Background scheduler skipped: not enabled."))
   ((not (org-auto-scheduler-allowed-on-this-computer-p))
    (org-auto-scheduler--log-debug "Background scheduler skipped: not allowed on hostname %s." (system-name)))
   ((and org-auto-scheduler-background-pause-on-review
         (or (get-buffer-window "*Org Auto Scheduler Review*" t)
             (and (boundp 'org-timegrid-buffer-name)
                  (get-buffer-window org-timegrid-buffer-name t))))
    (org-auto-scheduler--log-debug "Background scheduler skipped: review buffer is active."))
   ((or org-auto-scheduler--background-running
        (and org-auto-scheduler--background-thread
             (threadp org-auto-scheduler--background-thread)
             (thread-live-p org-auto-scheduler--background-thread))
        (bound-and-true-p org-auto-scheduler--active-operation))
    (org-auto-scheduler--log-debug "Background scheduler skipped: operation '%s' or run already in progress."
                                  (or (bound-and-true-p org-auto-scheduler--active-operation) "background")))
   ((minibufferp)
    (org-auto-scheduler--log-debug "Background scheduler skipped: minibuffer active."))
   ((and org-auto-scheduler-background-pause-on-clock
         (boundp 'org-clock-current-task)
         org-clock-current-task)
    (org-auto-scheduler--log-debug "Background scheduler skipped: task currently clocked in."))
   (t
    (if (and org-auto-scheduler-background-async
             (fboundp 'make-thread))
        (setq org-auto-scheduler--background-thread
              (make-thread
               #'org-auto-scheduler--execute-background-job
               "org-auto-scheduler-worker"))
      (org-auto-scheduler--execute-background-job)))))

(defun org-auto-scheduler--execute-background-job ()
  "Worker function executing a background scheduler run."
  (setq org-auto-scheduler--background-running t)
  (let* ((is-async (and (fboundp 'current-thread)
                        (fboundp 'main-thread)
                        (not (eq (current-thread) (main-thread)))))
         (run-type (if is-async 'background-async 'background-sync))
         (start-time (current-time)))
    (org-auto-scheduler--log-info "Starting background auto-scheduler run (async: %s)..."
                                  (if is-async "yes" "no"))
    (unwind-protect
        (condition-case err
            (let ((org-auto-scheduler-silent-mode t)
                  (org-auto-scheduler--current-run-type run-type)
                  (org-auto-scheduler--run-start-time start-time))
              ;; Run scheduler in silent mode
              (org-auto-scheduler-schedule-tasks)
              ;; Save agenda buffers if configured and changes were made
              (when (and org-auto-scheduler-background-save-buffers
                         org-auto-scheduler--last-run-changes
                         (> (length org-auto-scheduler--last-run-changes) 0))
                (org-auto-scheduler--log-info "Saving all org agenda buffers after background changes")
                (save-some-buffers t (lambda ()
                                       (and (buffer-file-name)
                                            (member (buffer-file-name) (org-agenda-files t))))))
              ;; Notify user if changes were made
              (when (and org-auto-scheduler-change-log-notify
                         org-auto-scheduler--last-run-changes
                         (> (length org-auto-scheduler--last-run-changes) 0))
                (message "Org Auto Scheduler [background]: %d task(s) updated. [M-x org-auto-scheduler-show-change-log]"
                         (length org-auto-scheduler--last-run-changes))))
          (error
           (org-auto-scheduler--log-error "Error in background scheduler: %s" err)
           (when (org-auto-scheduler--should-log-changes-p)
             (org-auto-scheduler--record-run-error
              :run-type run-type
              :start-time start-time
              :error-message (error-message-string err)))))
      (setq org-auto-scheduler--background-running nil)
      (org-auto-scheduler--log-info "Background auto-scheduler run completed.")
      (org-auto-scheduler--maybe-schedule-idle-repeat))))

(defun org-auto-scheduler--maybe-schedule-idle-repeat ()
  "Schedule the next background run if Emacs continues to be idle."
  (when (and org-auto-scheduler-background-enabled
             (numberp org-auto-scheduler-background-interval)
             (> org-auto-scheduler-background-interval 0)
             (current-idle-time))
    (when org-auto-scheduler--repeat-idle-timer
      (cancel-timer org-auto-scheduler--repeat-idle-timer)
      (setq org-auto-scheduler--repeat-idle-timer nil))
    (setq org-auto-scheduler--repeat-idle-timer
          (run-with-idle-timer
           (+ (float-time (current-idle-time)) org-auto-scheduler-background-interval)
           nil
           #'org-auto-scheduler-background-run))))

(defun org-auto-scheduler-allowed-on-this-computer-p ()
  "Check if background scheduling is allowed on this computer.
Returns t if `org-auto-scheduler-allowed-hostnames' is nil or
if the current system's hostname (short or FQDN, case-insensitive) is in the list."
  (if (null org-auto-scheduler-allowed-hostnames)
      t
    (let* ((sys (downcase (system-name)))
           (short (car (split-string sys "\\.")))
           (allowed (mapcar #'downcase org-auto-scheduler-allowed-hostnames)))
      (or (member sys allowed)
          (member short allowed)))))

(defun org-auto-scheduler-toggle-background ()
  "Toggle background auto-scheduling."
  (interactive)
  (setq org-auto-scheduler-background-enabled
        (not org-auto-scheduler-background-enabled))
  (org-auto-scheduler-setup-background)
  (message "Background auto-scheduling %s%s"
           (if org-auto-scheduler-background-enabled "enabled" "disabled")
           (if (and org-auto-scheduler-background-enabled
                    (not (org-auto-scheduler-allowed-on-this-computer-p)))
               " (but not allowed on this computer)" "")))

(defun org-auto-scheduler-setup-background ()
  "Set up or cancel the background auto-scheduling timer based on the current setting."
  (interactive)
  (org-auto-scheduler--log-info "Setting up background scheduler. Enabled: %s"
                                (bound-and-true-p org-auto-scheduler-background-enabled))

  ;; Cancel existing timers if present
  (when (bound-and-true-p org-auto-scheduler--idle-timer)
    (org-auto-scheduler--log-debug "Canceling existing background timer")
    (cancel-timer org-auto-scheduler--idle-timer)
    (setq org-auto-scheduler--idle-timer nil))

  (when (bound-and-true-p org-auto-scheduler--repeat-idle-timer)
    (org-auto-scheduler--log-debug "Canceling existing background repeat timer")
    (cancel-timer org-auto-scheduler--repeat-idle-timer)
    (setq org-auto-scheduler--repeat-idle-timer nil))

  ;; Create new timer if enabled
  (when (bound-and-true-p org-auto-scheduler-background-enabled)
    (let ((idle-time (if (boundp 'org-auto-scheduler-idle-time) org-auto-scheduler-idle-time 300))
          (interval (if (boundp 'org-auto-scheduler-background-interval) org-auto-scheduler-background-interval 300))
          (async (if (boundp 'org-auto-scheduler-background-async) org-auto-scheduler-background-async t)))
      (org-auto-scheduler--log-info "Creating new background timer. Idle time: %d seconds, Interval: %d seconds, Async: %s"
                                    idle-time interval async)
      (setq org-auto-scheduler--idle-timer
            (run-with-idle-timer
             idle-time
             t  ; REPEAT: t means fire each time Emacs becomes idle for idle-time seconds
             #'org-auto-scheduler-background-run))
      (add-hook 'kill-emacs-hook #'org-auto-scheduler-cleanup-background))))

;; Ensure background scheduler is set up after user config and custom settings load
(add-hook 'emacs-startup-hook #'org-auto-scheduler-setup-background t)

(defun org-auto-scheduler-cleanup-background ()
  "Clean up background scheduler resources when Emacs is shutting down."
  (when (bound-and-true-p org-auto-scheduler--idle-timer)
    (cancel-timer org-auto-scheduler--idle-timer)
    (setq org-auto-scheduler--idle-timer nil))
  (when (bound-and-true-p org-auto-scheduler--repeat-idle-timer)
    (cancel-timer org-auto-scheduler--repeat-idle-timer)
    (setq org-auto-scheduler--repeat-idle-timer nil))
  (setq org-auto-scheduler--background-running nil))


;;; ============================================================================
;;; Background Run Change Logging
;;; ============================================================================

(defun org-auto-scheduler--timestamps-equal-p (str1 str2)
  "Return non-nil if Org schedule strings STR1 and STR2 represent the same time slot."
  (cond
   ((and (null str1) (null str2)) t)
   ((or (null str1) (null str2)) nil)
   ((string= (string-trim str1) (string-trim str2)) t)
   (t
    (condition-case nil
        (let ((r1 (org-auto-scheduler-parse-scheduled-time-range str1))
              (r2 (org-auto-scheduler-parse-scheduled-time-range str2)))
          (and r1 r2
               (car r1) (car r2)
               (time-equal-p (car r1) (car r2))
               (or (and (null (nth 1 r1)) (null (nth 1 r2)))
                   (and (nth 1 r1) (nth 1 r2)
                        (time-equal-p (nth 1 r1) (nth 1 r2))))))
      (error nil)))))

(defun org-auto-scheduler--capture-tasks-snapshot (tasks-info)
  "Capture a snapshot of tasks state before scheduling.
TASKS-INFO is a list of task-info structures from `org-auto-scheduler-sort-tasks'."
  (let ((snapshot (make-hash-table :test 'equal)))
    (dolist (ti tasks-info)
      (let* ((tid (nth 5 ti))
             (m (nth 0 ti))
             (buf (and (markerp m) (marker-buffer m)))
             (file (and buf (buffer-file-name buf)))
             (sched (nth 8 ti))
             (hd (nth 6 ti))
             (tags (nth 7 ti))
             (pt (and (markerp m) (org-auto-scheduler-task-pinned-time m tid)))
             (pinned (and (markerp m) (org-auto-scheduler-task-pinned-p m tid))))
        (puthash tid
                 (list :task-id tid
                       :marker m
                       :file file
                       :headline hd
                       :scheduled sched
                       :tags tags
                       :pinned pinned
                       :pinned-time pt)
                 snapshot)))
    ;; Also capture existing placeholder tasks so their initial schedule is known
    (dolist (file (org-agenda-files t))
      (when (and file (file-exists-p file))
        (with-current-buffer (find-file-noselect file)
          (save-excursion
            (goto-char (point-min))
            (while (re-search-forward (concat ":" (regexp-quote org-auto-scheduler-placeholder-tag) ":\\|:AUTOSCH_PLACEHOLDER:") nil t)
              (org-back-to-heading t)
              (let* ((origin-id (org-entry-get nil "AUTOSCH_ORIGIN_ID"))
                     (hd (org-get-heading t t t t))
                     (pn-prop (org-entry-get nil "AUTOSCH_PART_NUM"))
                     (part-num (or (and pn-prop (string-to-number pn-prop))
                                   (when (string-match "Part \\([0-9]+\\)" hd)
                                     (string-to-number (match-string 1 hd)))
                                   1))
                     (ph-id (and origin-id (format "%s-remaining-%d" origin-id part-num)))
                     (sched (org-entry-get nil "SCHEDULED"))
                     (tags (org-get-tags))
                     (m (point-marker)))
                (when ph-id
                  (puthash ph-id
                           (list :task-id ph-id
                                 :marker m
                                 :file file
                                 :headline hd
                                 :scheduled sched
                                 :tags tags
                                 :is-placeholder t
                                 :origin-id origin-id
                                 :part-num part-num)
                           snapshot)))
              (outline-next-heading))))))
    snapshot))

(defun org-auto-scheduler--detect-task-changes (initial-snapshot completed-tasks marker-data)
  "Detect task changes by comparing INITIAL-SNAPSHOT with COMPLETED-TASKS and MARKER-DATA.
Returns a list of change plists."
  (let ((changes '())
        (seen-ids (make-hash-table :test 'equal)))
    (dolist (ct completed-tasks)
      (let* ((tid (nth 0 ct))
             (final-sched (nth 6 ct))
             (final-hd (nth 5 ct))
             (marker (nth 7 ct))
             (extra-plist (nthcdr 8 ct))
             (split-today (plist-get extra-plist :split-today))
             (init-entry (and tid initial-snapshot (gethash tid initial-snapshot)))
             (orig-sched (and init-entry (plist-get init-entry :scheduled)))
             (orig-hd (or (and init-entry (plist-get init-entry :headline)) final-hd))
             (file (or (and init-entry (plist-get init-entry :file))
                       (and (markerp marker) (buffer-file-name (marker-buffer marker)))))
             (m-res (and tid marker-data (gethash tid marker-data)))
             (sched-changed (not (org-auto-scheduler--timestamps-equal-p orig-sched final-sched)))
             (sched-change-type
              (when sched-changed
                (cond
                 ((null orig-sched) :newly-scheduled)
                 ((null final-sched) :unscheduled)
                 (t :rescheduled))))
             (marker-actions '()))
        (when (and tid (not (gethash tid seen-ids)))
          (puthash tid t seen-ids)
          ;; Process marker actions if title markers were handled
          (when m-res
            (when (plist-get m-res :reschedule-all)
              (push "Reschedule all trigger (-r-all-)" marker-actions))
            (when (and (plist-get m-res :reschedule) (not (plist-get m-res :reschedule-all)))
              (push "Reschedule trigger (-r-)" marker-actions))
            (when (plist-get m-res :pinned)
              (let ((pt (and (markerp marker) (org-auto-scheduler-task-pinned-time marker tid))))
                (push (if pt
                          (format "Pinned task (-p-) at %s" (format-time-string "%Y-%m-%d %H:%M" pt))
                        "Pinned task (-p-)")
                      marker-actions)))
            (when (plist-get m-res :remove-pinned)
              (push "Unpinned task (-\\p-)" marker-actions))
            (when (plist-get m-res :splittable)
              (push "Marked splittable (-s-)" marker-actions))
            (when (plist-get m-res :remove-splittable)
              (push "Removed splittable status (-\\s-)" marker-actions))
            (when (plist-get m-res :freeset)
              (push "Marked freeset (-f-)" marker-actions))
            (when (plist-get m-res :remove-freeset)
              (push "Removed freeset status (-\\f-)" marker-actions))
            (when (plist-get m-res :done)
              (push "Marked DONE (-x-/-done-)" marker-actions))
            (when (plist-get m-res :kill)
              (push (format "Marked %s (-kill-)" org-auto-scheduler-kill-todo-state) marker-actions))
            (when (plist-get m-res :defer)
              (push "Deferred to tomorrow (-+1d-)" marker-actions))
            (when (plist-get m-res :effort)
              (push (format "Updated effort to %s (-e-)"
                            (org-auto-scheduler-minutes-to-time (plist-get m-res :effort)))
                    marker-actions))
            (when (plist-get m-res :priority)
              (push (format "Set priority [#%s] (-#%s-)"
                            (plist-get m-res :priority)
                            (plist-get m-res :priority))
                    marker-actions))
            (when (plist-get m-res :remove-priority)
              (push "Removed priority" marker-actions))
            (when (plist-get m-res :independent)
              (push "Marked independent (-i-)" marker-actions))
            (when (plist-get m-res :remove-independent)
              (push "Removed independent status (-\i-)" marker-actions)))
          ;; If anything changed (schedule, markers, split), record it
          (when (or sched-changed marker-actions split-today)
            (push (list :task-id tid
                        :headline final-hd
                        :orig-headline orig-hd
                        :file file
                        :marker marker
                        :schedule-changed sched-changed
                        :schedule-change-type sched-change-type
                        :orig-scheduled orig-sched
                        :final-scheduled final-sched
                        :marker-actions (nreverse marker-actions)
                        :split-today split-today)
                  changes)))))
    (when (hash-table-p marker-data)
      (maphash
       (lambda (tid m-res)
         (unless (gethash tid seen-ids)
           (puthash tid t seen-ids)
           (let* ((marker-actions '())
                  (init-entry (and initial-snapshot (gethash tid initial-snapshot)))
                  (orig-sched (and init-entry (plist-get init-entry :scheduled)))
                  (orig-hd (and init-entry (plist-get init-entry :headline)))
                  (file (and init-entry (plist-get init-entry :file))))
             (when (plist-get m-res :done)
               (push "Marked DONE (-x-/-done-)" marker-actions))
             (when (plist-get m-res :kill)
               (push (format "Marked %s (-kill-)" org-auto-scheduler-kill-todo-state) marker-actions))
             (when (plist-get m-res :defer)
               (push "Deferred to tomorrow (-+1d-)" marker-actions))
             (when (plist-get m-res :effort)
               (push (format "Updated effort to %s (-e-)"
                             (org-auto-scheduler-minutes-to-time (plist-get m-res :effort)))
                     marker-actions))
             (when (plist-get m-res :priority)
               (push (format "Set priority [#%s] (-#%s-)"
                             (plist-get m-res :priority)
                             (plist-get m-res :priority))
                     marker-actions))
             (when (plist-get m-res :remove-priority)
               (push "Removed priority" marker-actions))
             (when (plist-get m-res :independent)
               (push "Marked independent (-i-)" marker-actions))
             (when (plist-get m-res :remove-independent)
               (push "Removed independent status (-\i-)" marker-actions))
             (when marker-actions
               (push (list :task-id tid
                           :headline (or (plist-get m-res :title) orig-hd "Task")
                           :orig-headline orig-hd
                           :file file
                           :marker nil
                           :schedule-changed (and orig-sched (or (plist-get m-res :done) (plist-get m-res :kill) (plist-get m-res :defer)))
                           :schedule-change-type (cond
                                                  ((or (plist-get m-res :done) (plist-get m-res :kill)) :unscheduled)
                                                  (t nil))
                           :orig-scheduled orig-sched
                           :final-scheduled nil
                           :marker-actions (nreverse marker-actions)
                           :split-today nil)
                     changes)))))
       marker-data))
    (nreverse changes)))

(defun org-auto-scheduler--should-log-changes-p ()
  "Return non-nil if changes should be logged for the current run."
  (and org-auto-scheduler-change-log-enabled
       (or (not org-auto-scheduler-change-log-background-only)
           (memq org-auto-scheduler--current-run-type '(background-async background-sync)))))

(defun org-auto-scheduler--format-change-log-entry (run-info changes)
  "Format an Org-mode change log entry for a scheduler run.
RUN-INFO is a plist with :run-type, :start-time, :end-time, :tasks-evaluated,
:cleaned-placeholders.
CHANGES is a list of change plists."
  (let* ((run-type (plist-get run-info :run-type))
         (start-time (or (plist-get run-info :start-time) (current-time)))
         (end-time (or (plist-get run-info :end-time) (current-time)))
         (duration (float-time (time-subtract end-time start-time)))
         (tasks-eval (or (plist-get run-info :tasks-evaluated) 0))
         (cleaned-ph (or (plist-get run-info :cleaned-placeholders) 0))
         (num-changes (length changes))
         (time-str (format-time-string "%Y-%m-%d %a %H:%M:%S" start-time))
         (run-label (cond
                     ((eq run-type 'background-async) "Background Run (Async)")
                     ((eq run-type 'background-sync) "Background Run (Sync)")
                     (t "Manual Run")))
         (lines '()))
    (if (= num-changes 0)
        (push (format "* [%s] %s: No changes (%d task(s) evaluated)"
                      time-str run-label tasks-eval)
              lines)
      (push (format "* [%s] %s (%d task(s) updated)"
                    time-str run-label num-changes)
            lines))
    (push ":PROPERTIES:" lines)
    (push (format ":RUN_TYPE: %s" (or run-type 'manual)) lines)
    (push (format ":TASKS_EVALUATED: %d" tasks-eval) lines)
    (push (format ":TASKS_CHANGED: %d" num-changes) lines)
    (push (format ":PLACEHOLDERS_CLEANED: %d" cleaned-ph) lines)
    (push (format ":DURATION: %.2fs" duration) lines)
    (push ":END:
" lines)

    (when (> cleaned-ph 0)
      (push (format "- Cleaned up %d split placeholder subtask(s)
" cleaned-ph) lines))

    (dolist (ch changes)
      (let* ((hd (plist-get ch :headline))
             (orig-hd (plist-get ch :orig-headline))
             (file (plist-get ch :file))
             (sched-changed (plist-get ch :schedule-changed))
             (sched-type (plist-get ch :schedule-change-type))
             (orig-sched (plist-get ch :orig-scheduled))
             (final-sched (plist-get ch :final-scheduled))
             (marker-acts (plist-get ch :marker-actions))
             (split (plist-get ch :split-today))
             ;; Build action tag for subheading
             (action-tag (cond
                          ((and marker-acts sched-changed) "MARKER & RESCHEDULED")
                          (marker-acts "MARKER UPDATED")
                          ((eq sched-type :newly-scheduled) "NEWLY SCHEDULED")
                          ((eq sched-type :unscheduled) "UNSCHEDULED")
                          (t "RESCHEDULED")))
             ;; Format headline with link if file exists
             (linked-title
              (if (and file (file-exists-p file))
                  (format "[[file:%s::*%s][%s]]" file hd hd)
                hd)))
        (push (format "** %s: %s" action-tag linked-title) lines)
        (when (and orig-hd (not (string= orig-hd hd)))
          (push (format "  - Title: =%s= → =%s=" orig-hd hd) lines))
        (dolist (ma marker-acts)
          (push (format "  - Action: %s" ma) lines))
        (when sched-changed
          (push (format "  - Schedule: %s → %s"
                        (or orig-sched "Unscheduled")
                        (or final-sched "Unscheduled"))
                lines))
        (when split
          (push "  - Split: initial chunk scheduled, remaining effort placed on subsequent days" lines))
        (when file
          (push (format "  - File: =%s=" file) lines))
        (push "" lines)))
    (mapconcat #'identity (nreverse lines) "
")))

(defun org-auto-scheduler--prune-change-log-buffer (buf max-entries)
  "Prune older entries in BUF to keep at most MAX-ENTRIES top-level headings."
  (when (and (buffer-live-p buf) (numberp max-entries) (> max-entries 0))
    (with-current-buffer buf
      (save-excursion
        (goto-char (point-min))
        (let ((headings '()))
          (while (re-search-forward "^\\* \\[" nil t)
            (push (line-beginning-position) headings))
          (setq headings (nreverse headings))
          (let ((excess (- (length headings) max-entries)))
            (when (> excess 0)
              (let ((cutoff (nth excess headings)))
                (goto-char (car headings))
                (delete-region (point) cutoff)))))))))

(defun org-auto-scheduler--prune-change-log-file (file max-entries)
  "Prune older entries in FILE to keep at most MAX-ENTRIES top-level headings."
  (when (and file (file-exists-p file) (numberp max-entries) (> max-entries 0))
    (condition-case nil
        (with-temp-buffer
          (insert-file-contents file)
          (org-auto-scheduler--prune-change-log-buffer (current-buffer) max-entries)
          (write-region (point-min) (point-max) file nil 'silent))
      (error nil))))

(defconst org-auto-scheduler--change-log-no-changes-re
  (rx bol "* ["
      (group (= 4 digit) "-" (= 2 digit) "-" (= 2 digit))
      (zero-or-more (not (any "]"))) "]"
      (one-or-more (any " \t"))
      "Background Run"
      (zero-or-more (not (any ":")))
      ": No changes")
  "Regular expression matching top-level background run headings with no changes.")

(defconst org-auto-scheduler--change-log-header-runs-re
  (rx bol "* "
      (group "[" (= 4 digit) "-" (= 2 digit) "-" (= 2 digit)
             (zero-or-more (not (any "]"))) "]"
             (one-or-more (any " \t"))
             "Background Run"
             (zero-or-more (not (any ":")))
             ": No changes")
      (opt (one-or-more (any " \t")) "(" (one-or-more (not (any ")"))) ")")
      eol)
  "Regular expression matching background run heading to update run count suffix.")

(defconst org-auto-scheduler--change-log-time-re
  (rx "[" (= 4 digit) "-" (= 2 digit) "-" (= 2 digit)
      (zero-or-more (not (any "]")))
      (one-or-more (any " \t"))
      (group (= 2 digit) ":" (= 2 digit) ":" (= 2 digit))
      "]")
  "Regular expression matching time component inside an inactive Org timestamp.")

(defun org-auto-scheduler--collate-or-append-no-changes-in-buffer (buf run-info)
  "In buffer BUF, collate RUN-INFO into the last 'No changes' heading or create a new one."
  (with-current-buffer buf
    (unless (derived-mode-p 'org-mode)
      (org-mode))
    (when (= (buffer-size) 0)
      (insert "#+TITLE: Org Auto Scheduler Changes Log\n#+STARTUP: showeverything\n\n"))
    (let* ((run-type (plist-get run-info :run-type))
           (start-time (or (plist-get run-info :start-time) (current-time)))
           (end-time (or (plist-get run-info :end-time) (current-time)))
           (duration (float-time (time-subtract end-time start-time)))
           (tasks-eval (or (plist-get run-info :tasks-evaluated) 0))
           (cleaned-ph (or (plist-get run-info :cleaned-placeholders) 0))
           (time-str (format-time-string "%Y-%m-%d %a %H:%M:%S" start-time))
           (target-date (format-time-string "%Y-%m-%d" start-time))
           (time-bullet (format-time-string "%H:%M:%S" start-time))
           (run-label (cond
                       ((eq run-type 'background-async) "Background Run (Async)")
                       ((eq run-type 'background-sync) "Background Run (Sync)")
                       (t "Background Run")))
           (bullet-text (if (> cleaned-ph 0)
                            (format "- [%s] No changes (%d task(s) evaluated, %d placeholder(s) cleaned, %.2fs)"
                                    time-bullet tasks-eval cleaned-ph duration)
                          (format "- [%s] No changes (%d task(s) evaluated, %.2fs)"
                                  time-bullet tasks-eval duration)))
           (collated-heading-pos nil))
      (when org-auto-scheduler-change-log-collate-empty
        (save-excursion
          (goto-char (point-max))
          (when (re-search-backward "^\\* " nil t)
            (let ((hpos (point)))
              (when (looking-at org-auto-scheduler--change-log-no-changes-re)
                (let ((hdate (match-string 1)))
                  (when (string= hdate target-date)
                    (setq collated-heading-pos hpos))))))))

      (if collated-heading-pos
          (save-excursion
            (goto-char collated-heading-pos)
            (let* ((heading-line (buffer-substring-no-properties (line-beginning-position) (line-end-position)))
                   (next-heading (save-excursion
                                   (forward-line 1)
                                   (if (re-search-forward "^\\* " nil t)
                                       (match-beginning 0)
                                     (point-max))))
                   (has-bullets (save-excursion
                                  (re-search-forward "^- \\[" next-heading t))))
              ;; If existing node had no bullet points (legacy format), add bullet for the first run
              (unless has-bullets
                (let ((first-time
                       (when (string-match org-auto-scheduler--change-log-time-re heading-line)
                         (match-string 1 heading-line)))
                      (first-tasks
                       (or (org-entry-get (point) "TASKS_EVALUATED")
                           (number-to-string tasks-eval)))
                      (first-dur
                       (or (org-entry-get (point) "DURATION")
                           "0.00s")))
                  (when first-time
                    (goto-char collated-heading-pos)
                    (if (re-search-forward "^:END:" next-heading t)
                        (forward-line 1)
                      (forward-line 1))
                    (unless (bolp) (insert "\n"))
                    (insert (format "\n- [%s] No changes (%s task(s) evaluated, %s)\n"
                                    first-time first-tasks first-dur)))))

              ;; Count existing bullets
              (goto-char collated-heading-pos)
              (setq next-heading (save-excursion
                                   (forward-line 1)
                                   (if (re-search-forward "^\\* " nil t)
                                       (match-beginning 0)
                                     (point-max))))
              (let ((bullet-count 0))
                (save-excursion
                  (while (re-search-forward "^- \\[" next-heading t)
                    (setq bullet-count (1+ bullet-count))))
                (let ((total-runs (1+ bullet-count)))
                  (goto-char collated-heading-pos)
                  (when (looking-at org-auto-scheduler--change-log-header-runs-re)
                    (replace-match (format "* \\1 (%d runs)" total-runs)))
                  (org-entry-put (point) "LAST_RUN" time-str)
                  (org-entry-put (point) "TOTAL_RUNS" (number-to-string total-runs))))

              ;; Insert bullet at the end of this node (before next heading or point-max)
              (goto-char collated-heading-pos)
              (forward-line 1)
              (let ((entry-end (if (re-search-forward "^\\* " nil t)
                                   (match-beginning 0)
                                 (point-max))))
                (goto-char entry-end)
                (skip-chars-backward "\n\r \t")
                (forward-line 1)
                (insert bullet-text "\n"))))

        ;; New node
        (let ((entry-lines
               (list (format "* [%s] %s: No changes" time-str run-label)
                     ":PROPERTIES:"
                     (format ":RUN_TYPE: %s" (or run-type 'background))
                     (format ":TASKS_EVALUATED: %d" tasks-eval)
                     ":TASKS_CHANGED: 0"
                     (format ":PLACEHOLDERS_CLEANED: %d" cleaned-ph)
                     (format ":DURATION: %.2fs" duration)
                     (format ":LAST_RUN: %s" time-str)
                     ":TOTAL_RUNS: 1"
                     ":END:\n"
                     bullet-text)))
          (goto-char (point-max))
          (unless (bolp) (insert "\n"))
          (insert (mapconcat #'identity entry-lines "\n") "\n"))))))

(defun org-auto-scheduler--collate-empty-change-log (run-info)
  "Collate empty background RUN-INFO into change log buffer and persistent file."
  ;; 1. Update buffer
  (let ((buf (get-buffer-create org-auto-scheduler-change-log-buffer-name)))
    (with-current-buffer buf
      (when (and (= (buffer-size) 0)
                 org-auto-scheduler-change-log-file
                 (file-exists-p org-auto-scheduler-change-log-file))
        (insert-file-contents org-auto-scheduler-change-log-file))
      (org-auto-scheduler--collate-or-append-no-changes-in-buffer buf run-info)
      (org-auto-scheduler--prune-change-log-buffer buf org-auto-scheduler-change-log-max-entries)))
  ;; 2. Update persistent file
  (when (and org-auto-scheduler-change-log-file
             (stringp org-auto-scheduler-change-log-file))
    (condition-case err
        (let ((file-dir (file-name-directory org-auto-scheduler-change-log-file)))
          (when (and file-dir (not (file-directory-p file-dir)))
            (make-directory file-dir t))
          (let ((visiting-buf (find-buffer-visiting org-auto-scheduler-change-log-file)))
            (if (and visiting-buf (buffer-live-p visiting-buf))
                (with-current-buffer visiting-buf
                  (org-auto-scheduler--collate-or-append-no-changes-in-buffer visiting-buf run-info)
                  (org-auto-scheduler--prune-change-log-buffer visiting-buf org-auto-scheduler-change-log-max-entries)
                  (save-buffer))
              (with-temp-buffer
                (when (file-exists-p org-auto-scheduler-change-log-file)
                  (insert-file-contents org-auto-scheduler-change-log-file))
                (org-auto-scheduler--collate-or-append-no-changes-in-buffer (current-buffer) run-info)
                (org-auto-scheduler--prune-change-log-buffer (current-buffer) org-auto-scheduler-change-log-max-entries)
                (write-region (point-min) (point-max) org-auto-scheduler-change-log-file nil 'silent)))))
      (error
       (org-auto-scheduler--log-warn "Failed to write change log file %s: %s"
                                     org-auto-scheduler-change-log-file err)))))

(defun org-auto-scheduler--append-change-log (entry-text)
  "Append ENTRY-TEXT to the change log buffer and persistent file."
  ;; 1. Update buffer
  (let ((buf (get-buffer-create org-auto-scheduler-change-log-buffer-name)))
    (with-current-buffer buf
      (unless (derived-mode-p 'org-mode)
        (org-mode)
        (insert "#+TITLE: Org Auto Scheduler Changes Log\n#+STARTUP: showeverything\n\n"))
      (when (and (= (buffer-size) 0)
                 org-auto-scheduler-change-log-file
                 (file-exists-p org-auto-scheduler-change-log-file))
        (insert-file-contents org-auto-scheduler-change-log-file))
      (goto-char (point-max))
      (unless (bolp) (insert "\n"))
      (insert entry-text "\n")
      (org-auto-scheduler--prune-change-log-buffer buf org-auto-scheduler-change-log-max-entries)))
  ;; 2. Update persistent file
  (when (and org-auto-scheduler-change-log-file
             (stringp org-auto-scheduler-change-log-file))
    (condition-case err
        (let ((file-dir (file-name-directory org-auto-scheduler-change-log-file)))
          (when (and file-dir (not (file-directory-p file-dir)))
            (make-directory file-dir t))
          (let ((need-header (not (file-exists-p org-auto-scheduler-change-log-file))))
            (with-temp-buffer
              (when need-header
                (insert "#+TITLE: Org Auto Scheduler Changes Log\n#+STARTUP: showeverything\n\n"))
              (insert entry-text "\n")
              (write-region (point-min) (point-max) org-auto-scheduler-change-log-file t 'silent)))
          (org-auto-scheduler--prune-change-log-file
           org-auto-scheduler-change-log-file
           org-auto-scheduler-change-log-max-entries))
      (error
       (org-auto-scheduler--log-warn "Failed to write change log file %s: %s"
                                     org-auto-scheduler-change-log-file err)))))

(defun org-auto-scheduler--record-run-changes (&rest run-info)
  "Record changes from a scheduler run.
RUN-INFO is a plist containing :run-type, :start-time, :end-time,
:tasks-evaluated, :changes, :cleaned-placeholders."
  (let* ((changes (plist-get run-info :changes))
         (has-changes (> (length changes) 0))
         (run-type (plist-get run-info :run-type))
         (is-background (memq run-type '(background-async background-sync background))))
    (when (or has-changes org-auto-scheduler-change-log-record-empty)
      (if (and (not has-changes)
               is-background
               org-auto-scheduler-change-log-collate-empty)
          (org-auto-scheduler--collate-empty-change-log run-info)
        (let ((entry-text (org-auto-scheduler--format-change-log-entry run-info changes)))
          (org-auto-scheduler--append-change-log entry-text))))))

(defun org-auto-scheduler--record-run-error (&rest err-info)
  "Record an error encountered during a scheduler run.
ERR-INFO is a plist containing :run-type, :start-time, :error-message."
  (let* ((run-type (plist-get err-info :run-type))
         (start-time (or (plist-get err-info :start-time) (current-time)))
         (err-msg (plist-get err-info :error-message))
         (now (current-time))
         (time-str (format-time-string "%Y-%m-%d %a %H:%M:%S" now))
         (duration (float-time (time-subtract now start-time)))
         (entry-text (concat
                      (format "* [%s] %s: ERROR
"
                              time-str
                              (if (eq run-type 'background-async) "Background Run (Async)" "Background Run"))
                      ":PROPERTIES:
"
                      (format ":RUN_TYPE: %s
" (or run-type 'background))
                      ":STATUS: error
"
                      (format ":DURATION: %.2fs
" duration)
                      ":END:

"
                      (format "- Error: =%s=

" err-msg))))
    (org-auto-scheduler--append-change-log entry-text)))

(defun org-auto-scheduler-show-change-log ()
  "Display the Org Auto Scheduler change log buffer."
  (interactive)
  (let ((buf (get-buffer-create org-auto-scheduler-change-log-buffer-name)))
    (with-current-buffer buf
      (unless (derived-mode-p 'org-mode)
        (org-mode))
      ;; If buffer is empty and log file exists, load from file
      (when (and (= (buffer-size) 0)
                 org-auto-scheduler-change-log-file
                 (file-exists-p org-auto-scheduler-change-log-file))
        (insert-file-contents org-auto-scheduler-change-log-file))
      (goto-char (point-max)))
    (pop-to-buffer buf)
    (goto-char (point-max))))

(defun org-auto-scheduler-clear-change-log (&optional clear-file)
  "Clear the Org Auto Scheduler change log buffer.
With prefix argument CLEAR-FILE, or when prompted interactively,
also truncate the persistent change log file."
  (interactive "P")
  (let ((buf (get-buffer org-auto-scheduler-change-log-buffer-name)))
    (when buf
      (with-current-buffer buf
        (erase-buffer))))
  (setq org-auto-scheduler--last-run-changes nil)
  (when (and (or clear-file (called-interactively-p 'interactive))
             org-auto-scheduler-change-log-file
             (file-exists-p org-auto-scheduler-change-log-file))
    (when (or clear-file (y-or-n-p (format "Also truncate log file %s? " org-auto-scheduler-change-log-file)))
      (with-temp-file org-auto-scheduler-change-log-file
        (insert ""))))
  (message "Org Auto Scheduler change log cleared."))


(defun org-auto-scheduler-historical-insights ()
  "Display historical prediction accuracy of effort estimates in a separate buffer."
  (interactive)
  (let ((buffer (get-buffer-create "*Org Auto Scheduler Insights*")))
    (with-current-buffer buffer
      (erase-buffer)
      (org-mode)
      (insert "#+TITLE: Org Auto Scheduler Historical Prediction Insights\n")
      (insert "#+DATE: " (format-time-string "%Y-%m-%d %H:%M:%S") "\n\n")
      (insert "This buffer shows how your actual tracked time compares against your \n")
      (insert "original explicit effort estimates based on Categories and Tags.\n")
      (insert "A multiplier of 1.0 means your estimates are perfectly accurate.\n")
      (insert "A multiplier of 1.5 means tests take 50% longer than you estimated.\n")
      (insert "A multiplier of 0.8 means you generally finish 20% faster than estimated.\n\n")
      (insert "| Category / Tag | Historical Multiplier | Prediction Accuracy |\n")
      (insert "|----------------|-----------------------|---------------------|\n")
      (if (null org-auto-scheduler-historical-multipliers)
          (insert "| (No data yet)  | N/A                   | N/A                 |\n")
        (let ((sorted-multipliers (sort (copy-sequence org-auto-scheduler-historical-multipliers)
                                        (lambda (a b) (> (cdr a) (cdr b))))))
          (dolist (item sorted-multipliers)
            (let* ((name (car item))
                   (multiplier (cdr item))
                   (accuracy (cond
                              ((> multiplier 1.5) "Severely Underestimated")
                              ((> multiplier 1.1) "Underestimated")
                              ((< multiplier 0.5) "Severely Overestimated")
                              ((< multiplier 0.9) "Overestimated")
                              (t "Highly Accurate"))))
              (insert (format "| %s | %.2fx | %s |\n" name multiplier accuracy))))))
      (goto-char (point-min))
      (search-forward "|" nil t)
      (beginning-of-line)
      (org-table-align))
    (pop-to-buffer buffer)))

(provide 'org-auto-scheduler-daemon)

;;; org-auto-scheduler-daemon.el ends here
