:PROPERTIES:
:END::PROPERTIES:
:END::PROPERTIES:
:END:(require 'org)
(require 'cl-lib)
(require 'org-id)
(require 'log4e)
(require 'parse-time)
(log4e:deflogger "org-auto-scheduler" "%t [%l] %m" "%H:%M:%S")
(org-auto-scheduler--log-set-level 'debug)

(defgroup org-auto-scheduler nil
  "Customization options for org-auto-scheduler."
  :group 'org)

(defcustom org-auto-scheduler-effort-weight 0.0
  "Base weight for remaining effort in score calculation."
  :type 'float
  :group 'org-auto-scheduler)

(defcustom org-auto-scheduler-priority-weight 10.0
  "Weight for priority in score calculation."
  :type 'float
  :group 'org-auto-scheduler)

(defcustom org-auto-scheduler-urgency-weight 20.0
  "Base weight for urgency factor in score calculation."
  :type 'float
  :group 'org-auto-scheduler)

(defcustom org-auto-scheduler-urgent-days 7
  "Number of days before a deadline is considered urgent."
  :type 'integer
  :group 'org-auto-scheduler)

(defcustom org-auto-scheduler-large-task-minutes 120
  "Number of minutes above which a task is considered large."
  :type 'integer
  :group 'org-auto-scheduler)

(defcustom org-auto-scheduler-state-weights
  '(("TODO" . 0)
    ("NEXT" . 1)
    ("IN-PROGRESS" . 2)
    ("WRITE" . 0)  ; Adding WRITE state with the same weight as IN-PROGRESS
    ("LATER" . -10))
  "Alist of weights for different TODO states."
  :type '(alist :key-type string :value-type number)
  :group 'org-auto-scheduler)

(defcustom org-auto-scheduler-start-time "05:00"
  "Start time for scheduling tasks (24-hour format)."
  :type 'string
  :group 'org-auto-scheduler)

(defcustom org-auto-scheduler-end-time "23:59"
  "End time for scheduling tasks (24-hour format)."
  :type 'string
  :group 'org-auto-scheduler)

(defcustom org-auto-scheduler-task-gap 10
  "Number of minutes to leave as a gap between scheduled tasks."
  :type 'integer
  :group 'org-auto-scheduler)

(defcustom org-auto-scheduler-inherited-priority-property "INHERITED_PRIORITY"
  "Property name for setting inherited priority for subtasks."
  :type 'string
  :group 'org-auto-scheduler)  ;; Fixed: Group name corrected

(defcustom org-auto-scheduler-time-blocks
  '(("FUN" . (("18:00" . "19:00")))    ; 6pm to 7pm
    ("BUYING" . (("14:00" . "15:00"))) ; 2pm to 3pm
    ("CHORES" . (("19:00" . "20:00")))) ; 7pm to 8pm
  "Alist of time blocks for scheduling tasks with specific tags.
Each entry is of the form (TAG . ((START1 . END1) (START2 . END2) ...)).
Times should be in 24-hour format."
  :type '(alist :key-type string
                :value-type (repeat (cons (string :tag "Start time")
                                          (string :tag "End time"))))
  :group 'org-auto-scheduler)

;; Add this near the top of the file, after other defcustom declarations
(defvar org-auto-scheduler-adaptive-data (make-hash-table :test 'equal)
  "Hash table to store adaptive scheduling data for tasks.")

(defcustom org-auto-scheduler-adaptive-factor 0.1
  "Factor for adjusting adaptive scores."
  :type 'float
  :group 'org-auto-scheduler)

(defcustom org-auto-scheduler-max-days-to-check 7
  "Maximum number of days to check for available time slots."
  :type 'integer
  :group 'org-auto-scheduler)

(defun org-auto-scheduler-parse-time-string (time-string)
  "Parse a time string in the format YYYY-MM-DD Day HH:MM."
  (when time-string
    (let ((parsed (parse-time-string time-string)))
      (encode-time (or (nth 0 parsed) 0)  ; second
                   (or (nth 1 parsed) 0)  ; minute
                   (or (nth 2 parsed) 0)  ; hour
                   (or (nth 3 parsed) 1)  ; day
                   (or (nth 4 parsed) 1)  ; month
                   (or (nth 5 parsed) 1970)))))  ; year

(defun org-auto-scheduler-get-effort (task)
  "Get the effort estimate for TASK."
  (let ((effort (org-entry-get task "Effort")))
    (when effort
      (condition-case err
          (org-duration-to-minutes effort)
        (error
         (org-auto-scheduler--log-error "Error parsing effort for task: %s. Error: %s" task err)
         60)))))  ; Default to 60 minutes on error

(defun org-auto-scheduler-get-priority (task)
  "Get the priority of TASK."
  (let ((priority (org-entry-get task "PRIORITY")))
    (cond
     ((equal priority "A") 3)
     ((equal priority "B") 2)
     ((equal priority "C") 1)
     (t 0))))

(defun org-auto-scheduler-get-deadline (task)
  "Get the deadline of TASK."
  (condition-case err
      (let ((deadline-string (org-entry-get task "DEADLINE")))
        (when deadline-string
          (org-time-string-to-time deadline-string)))
    (error
     (org-auto-scheduler--log-error "Error getting deadline for task: %s. Error: %s" task err)
     nil)))

(defun org-auto-scheduler-get-scheduled (task)
  "Get the scheduled date of TASK."
  (org-entry-get task "SCHEDULED"))

(defun org-auto-scheduler-get-clocked-time (marker)
  "Get the total clocked time for the task at MARKER in minutes, including current clock,
but only considering time after the last DONE, NOTE, or DROPPED state change."
  (let ((clock-sum 0)
        (last-state-change nil)
        (current-clock-time nil)
        logbook-start logbook-end)
    (with-current-buffer (marker-buffer marker)
      (save-excursion
        (goto-char (marker-position marker))
        (when (derived-mode-p 'org-agenda-mode)
          ;; In agenda mode, we need to get to the original org file
          (org-agenda-goto)
          (setq marker (point-marker)))
        
        ;; Check for current clock
        (when (and (org-clocking-p)
                   (equal (marker-buffer org-clock-marker) (current-buffer))
                   (= (marker-position org-clock-marker) (point)))
          (setq current-clock-time (float-time (time-subtract (current-time) org-clock-start-time))))
        
        (org-back-to-heading t)
        (when (re-search-forward ":LOGBOOK:" nil t)
          (setq logbook-start (point))
          (if (re-search-forward ":END:" nil t)
              (setq logbook-end (match-beginning 0))
            (setq logbook-end (point-max)))
          (org-auto-scheduler--log-debug "LOGBOOK found from %d to %d" logbook-start logbook-end)
          
          ;; First pass: find the last state change
          (goto-char logbook-start)
          (while (re-search-forward "- State \"\\(DONE\\|NOTE\\|DROPPED\\)\".*\\[\\([^]]+\\)\\]" logbook-end t)
            (setq last-state-change (org-auto-scheduler-parse-time-string (match-string 2))))
          (org-auto-scheduler--log-debug "Last state change: %s" 
                                         (and last-state-change (format-time-string "%Y-%m-%d %H:%M:%S" last-state-change)))
          
          ;; Second pass: sum up clock entries after the last state change
          (goto-char logbook-start)
          (while (re-search-forward "^CLOCK: \\[\\([^]]+\\)\\]--\\[\\([^]]+\\)\\] =>[ ]*\\([0-9]+:[0-9]+\\)" logbook-end t)
            (let* ((start-str (match-string 1))
                   (duration-str (match-string 3))
                   (start-time (org-auto-scheduler-parse-time-string start-str))
                   (duration-parts (split-string duration-str ":"))
                   (duration-minutes (+ (* 60 (string-to-number (car duration-parts)))
                                        (string-to-number (cadr duration-parts)))))
              (when (or (null last-state-change)
                        (time-less-p last-state-change start-time))
                (setq clock-sum (+ clock-sum duration-minutes))
                (org-auto-scheduler--log-debug "Added clock entry: %s, duration: %d minutes, new sum: %f"
                                               start-str duration-minutes clock-sum)))))))
    (let ((total-time (floor (+ clock-sum (or (and current-clock-time (/ current-clock-time 60)) 0)))))
      (org-auto-scheduler--log-debug "Total clocked time: %d minutes" total-time)
      total-time)))

(defun org-auto-scheduler-get-state (task)
  "Get the current state of TASK."
  (org-entry-get task "TODO"))

(defun org-auto-scheduler-get-inherited-priority (marker)
  "Get the inherited priority for the task at MARKER."
  (org-with-point-at marker
    (let ((inherited-priority 0))
      (while (org-up-heading-safe)
        (let ((priority-value (org-entry-get nil org-auto-scheduler-inherited-priority-property)))
          (when priority-value
            (setq inherited-priority (+ inherited-priority (string-to-number priority-value))))))
      inherited-priority)))

(defun org-auto-scheduler-calculate-score (marker)
  "Calculate a score for a task at MARKER based on its properties and state."
  (condition-case err
      (let* ((effort (or (org-auto-scheduler-get-effort marker) 60))
             (priority (org-entry-get marker "PRIORITY"))
             (deadline (org-auto-scheduler-get-deadline marker))
             (state (org-entry-get marker "TODO"))
             (state-weight (or (cdr (assoc state org-auto-scheduler-state-weights)) 0))
             (priority-score (cond ((equal priority "A") 10)
                                   ((equal priority "B") 0)
                                   ((equal priority "C") -5)
                                   (t 0)))
             (inherited-priority (org-auto-scheduler-get-inherited-priority marker))
             (days-to-deadline (if deadline
                                   (max 0 (floor (- (time-to-days deadline)
                                                    (time-to-days (current-time)))))
                                 30))
             (urgency-factor (/ 1.0 (1+ days-to-deadline)))
             (task-id (org-id-get-create))
             (adaptive-score (gethash task-id org-auto-scheduler-adaptive-data 1.0)))
        (org-auto-scheduler--log-debug "Calculating score for task %s" task-id)
        (* (+ (* effort org-auto-scheduler-effort-weight)
              (* (+ priority-score inherited-priority) org-auto-scheduler-priority-weight)
              (* urgency-factor org-auto-scheduler-urgency-weight)
              state-weight)
           adaptive-score))
    (error
     (org-auto-scheduler--log-error "Error calculating score: %s\nMarker: %s\nBacktrace: %s"
                                    err
                                    marker
                                    (with-output-to-string (backtrace)))
     0)))  ; Return 0 score on error

(defun org-auto-scheduler-get-parent-id (marker)
  "Get the ID of the parent heading for the task at MARKER."
  (save-excursion
    (with-current-buffer (marker-buffer marker)
      (goto-char (marker-position marker))
      (org-up-heading-safe)
      (org-id-get))))

(defun org-auto-scheduler-get-task-position (marker)
  "Get the position of the task within its parent."
  (save-excursion
    (with-current-buffer (marker-buffer marker)
      (goto-char (marker-position marker))
      (let ((current-pos 1))
        (while (org-get-last-sibling)
          (setq current-pos (1+ current-pos)))
        current-pos))))

(defun org-auto-scheduler-sort-tasks (tasks)
  "Sort TASKS based on their calculated scores, parent tasks, and sibling order."
  (let* ((tasks-with-info
          (mapcar (lambda (marker)
                    (list marker
                          (org-auto-scheduler-calculate-score marker)
                          (org-auto-scheduler-get-parent-id marker)
                          (org-auto-scheduler-get-task-position marker)))
                  tasks))
         (tasks-with-info-and-position
          (cl-loop for task in tasks-with-info
                   for pos from 0
                   collect (cons pos task))))
    (mapcar #'cadr
            (sort tasks-with-info-and-position
                  (lambda (a b)
                    (let ((score-a (nth 2 a))
                          (score-b (nth 2 b))
                          (parent-a (nth 3 a))
                          (parent-b (nth 3 b))
                          (sibling-pos-a (nth 4 a))
                          (sibling-pos-b (nth 4 b))
                          (file-pos-a (car a))
                          (file-pos-b (car b)))
                      (cond
                       ;; If parents are the same, preserve sibling order
                       ((and parent-a parent-b (equal parent-a parent-b))
                        (< sibling-pos-a sibling-pos-b))
                       ;; If scores are different, higher score comes first
                       ((not (= score-a score-b))
                        (> score-a score-b))
                       ;; If scores are equal, preserve file order
                       (t (< file-pos-a file-pos-b)))))))))

(defun org-auto-scheduler-time-in-range-p (time)
  "Check if TIME is within the scheduling range."
  (let* ((time-str (format-time-string "%H:%M" time))
         (start (org-duration-to-minutes org-auto-scheduler-start-time))
         (end (org-duration-to-minutes org-auto-scheduler-end-time))
         (current (org-duration-to-minutes time-str)))
    (and (>= current start) (< current end))))

(defun org-auto-scheduler-next-available-time (current-time effort-minutes)
  "Find the next available time slot after CURRENT-TIME for EFFORT-MINUTES."
  (when (> effort-minutes 0)
    (let* ((current-day-start (org-time-string-to-time 
                               (format-time-string "%Y-%m-%d " current-time)))
           (start-of-day (time-add current-day-start
                                   (seconds-to-time 
                                    (* 60 (org-duration-to-minutes org-auto-scheduler-start-time)))))
           (end-of-day (time-add current-day-start
                                 (seconds-to-time 
                                  (* 60 (org-duration-to-minutes org-auto-scheduler-end-time)))))
           (slot-start (if (time-less-p current-time start-of-day) start-of-day current-time))
           (days-checked 0))
      (org-auto-scheduler--log-debug "org-auto-scheduler-next-available-time: Start of day: %s, End of day: %s"
                                     (format-time-string "%Y-%m-%d %H:%M" start-of-day)
                                     (format-time-string "%Y-%m-%d %H:%M" end-of-day))
      (while (and (< days-checked org-auto-scheduler-max-days-to-check)
                  (or (time-less-p end-of-day slot-start)
                      (time-less-p end-of-day (time-add slot-start (seconds-to-time (* effort-minutes 60))))
                      (org-auto-scheduler-time-slot-occupied-p slot-start effort-minutes)))
        (org-auto-scheduler--log-debug "org-auto-scheduler-next-available-time: Checking slot %s"
                                       (format-time-string "%Y-%m-%d %H:%M" slot-start))
        (if (or (time-less-p end-of-day slot-start)
                (time-less-p end-of-day (time-add slot-start (seconds-to-time (* effort-minutes 60)))))
            (progn
              (org-auto-scheduler--log-debug "org-auto-scheduler-next-available-time: Not enough time left in day, moving to next day")
              (setq days-checked (1+ days-checked))
              (setq slot-start (org-auto-scheduler-next-day-start slot-start))
              (setq end-of-day (time-add (org-time-string-to-time 
                                          (format-time-string "%Y-%m-%d " slot-start))
                                         (seconds-to-time 
                                          (* 60 (org-duration-to-minutes org-auto-scheduler-end-time))))))
          (setq slot-start (time-add slot-start (seconds-to-time (* 15 60)))))
        (when (= (mod days-checked 10) 0)
          (org-auto-scheduler--log-debug "org-auto-scheduler-next-available-time: Checked %d days" days-checked)))
      (if (< days-checked org-auto-scheduler-max-days-to-check)
          (progn
            (org-auto-scheduler--log-debug "org-auto-scheduler-next-available-time: Found available time slot: %s"
                                           (format-time-string "%Y-%m-%d %H:%M" slot-start))
            slot-start)
        (org-auto-scheduler--log-debug "org-auto-scheduler-next-available-time: No available time slot found within %d days for effort %d minutes"
                                       org-auto-scheduler-max-days-to-check
                                       effort-minutes)
        nil))))

(defun org-auto-scheduler-time-slot-occupied-p (start-time effort-minutes)
  "Check if the time slot starting at START-TIME for EFFORT-MINUTES is occupied.
This includes checking for task gaps and handling auto-scheduled tasks."
  (let* ((end-time (time-add start-time (seconds-to-time (* effort-minutes 60))))
         (start-with-gap (time-subtract start-time (seconds-to-time (* 60 org-auto-scheduler-task-gap))))
         (end-with-gap (time-add end-time (seconds-to-time (* 60 org-auto-scheduler-task-gap))))
         (conflict-found nil))
    (org-auto-scheduler--log-debug "Checking time slot: %s to %s"
                                   (format-time-string "%Y-%m-%d %H:%M" start-with-gap)
                                   (format-time-string "%Y-%m-%d %H:%M" end-with-gap))
    (org-map-entries
     (lambda ()
       (let* ((scheduled-time (org-get-scheduled-time nil))
              (task-effort (or (org-auto-scheduler-get-effort nil) 60))
              (task-end-time (when scheduled-time
                               (time-add scheduled-time (seconds-to-time (* task-effort 60)))))
              (tags (org-get-tags)))
         (when (and scheduled-time
                    (not (member "AUTOSCH" tags)))
           (let ((task-start-with-gap (time-subtract scheduled-time
                                                     (seconds-to-time (* 60 org-auto-scheduler-task-gap))))
                 (task-end-with-gap (time-add task-end-time
                                              (seconds-to-time (* 60 org-auto-scheduler-task-gap)))))
             (when (or (and (time-less-p start-with-gap task-start-with-gap)
                            (time-less-p task-start-with-gap end-with-gap))
                       (and (time-less-p task-start-with-gap start-with-gap)
                            (time-less-p start-with-gap task-end-with-gap)))
               (setq conflict-found t)
               (org-auto-scheduler--log-debug "Conflict found with task: %s (%s to %s)"
                                              (org-entry-get nil "ITEM")
                                              (format-time-string "%Y-%m-%d %H:%M" task-start-with-gap)
                                              (format-time-string "%Y-%m-%d %H:%M" task-end-with-gap)))))))
     "+SCHEDULED>=\"<now>\"" 'agenda)
    conflict-found))

(defun org-auto-scheduler-next-day-start (time)
  "Get the start time of the next day after TIME."
  (let* ((next-day (time-add time (seconds-to-time 86400))) ; Add 24 hours
         (next-day-str (format-time-string "%Y-%m-%d" next-day))
         (start-time-str (concat next-day-str " " org-auto-scheduler-start-time)))
    (org-time-string-to-time start-time-str)))

(defun org-auto-scheduler-get-scheduled-end (pom)
  "Get the scheduled end time for the task at POM."
  (let ((scheduled-str (org-entry-get pom "SCHEDULED")))
    (when scheduled-str
      (if (string-match "-\\([0-9]+:[0-9]+\\)" scheduled-str)
          (org-time-string-to-time (concat (substring scheduled-str 0 11) (match-string 1 scheduled-str)))
        nil))))

(defun org-auto-scheduler-clear-scheduled-times ()
  "Clear scheduled times for all tasks with the 'AUTOSCH' tag and update the element cache."
  (let ((cleared-count 0)
        (modified-buffers '()))
    (org-map-entries
     (lambda ()
       (when (member "AUTOSCH" (org-get-tags))
         (let ((buffer (current-buffer)))
           (org-entry-delete (point) "SCHEDULED")
           (setq cleared-count (1+ cleared-count))
           (unless (memq buffer modified-buffers)
             (push buffer modified-buffers)))))
     "+AUTOSCH" 'agenda)
    ;; Update the org-element cache for modified buffers
    (dolist (buffer modified-buffers)
      (with-current-buffer buffer
        (org-element-cache-reset)
        (org-element-cache-refresh (point-min))))
    (message "Cleared scheduled times for %d tasks and updated element cache" cleared-count)))

(defun org-auto-scheduler-get-start-time ()
  "Get the starting time for scheduling tasks.
If current time is after org-auto-scheduler-end-time, return the start time of the next day."
  (let* ((now (current-time))
         (decoded-time (decode-time now))
         (current-hour (nth 2 decoded-time))
         (current-minute (nth 1 decoded-time))
         (start-time-components (mapcar #'string-to-number
                                        (split-string org-auto-scheduler-start-time ":")))
         (end-time-components (mapcar #'string-to-number
                                       (split-string org-auto-scheduler-end-time ":")))
         (end-hour (car end-time-components))
         (end-minute (cadr end-time-components)))
    (if (or (> current-hour end-hour)
            (and (= current-hour end-hour) (>= current-minute end-minute)))
        ;; If it's after the end time, start from the configured start time the next day
        (let* ((tomorrow (time-add now (seconds-to-time (* 24 3600))))
               (tomorrow-start (apply #'encode-time
                                     (append (list 0
                                                   (cadr start-time-components)
                                                   (car start-time-components))
                                             (nthcdr 3 (decode-time tomorrow))))))
          tomorrow-start)
      ;; Otherwise, start from the current time plus 15 minutes
      (time-add now (seconds-to-time 900)))))

(defun org-auto-scheduler-schedule-tasks ()
  "Automatically schedule tasks based on their properties, states, and time blocks."
  (interactive)
  (org-auto-scheduler--log-info "Starting auto-scheduling process")
  (condition-case err
      (progn
        (org-auto-scheduler-clear-scheduled-times)
        (let* ((tasks (org-auto-scheduler-get-schedulable-tasks))
               (sorted-tasks (org-auto-scheduler-sort-tasks tasks))
               (current-time (org-auto-scheduler-get-start-time))
               (tasks-scheduled 0)
               (total-tasks (length sorted-tasks)))
          (dolist (marker sorted-tasks)
            (setq current-time (org-auto-scheduler-schedule-single-task marker current-time))
            (setq tasks-scheduled (1+ tasks-scheduled))
            (when (zerop (mod tasks-scheduled 10))
              (org-auto-scheduler--log-info "Scheduled %d/%d tasks..." tasks-scheduled total-tasks)))
          (org-auto-scheduler--log-info "Scheduled %d tasks" tasks-scheduled)))
    (error
     (org-auto-scheduler--log-error "Error in scheduling process: %s" err))))

(defun org-auto-scheduler-get-schedulable-tasks ()
  "Get a list of markers for schedulable tasks."
  (let ((tasks '())
        (valid-states '("TODO" "NEXT" "IN-PROGRESS" "WRITE" "LATER" "BUY" "READ")))
    (org-map-entries
     (lambda ()
       (let* ((state (org-get-todo-state))
              (tags (org-get-tags))
              (is-autosch (member "AUTOSCH" tags))
              (is-valid-state (member state valid-states))
              (headline (org-get-heading t t t t)))
         (when (and is-autosch is-valid-state)
           (push (point-marker) tasks))))
     nil
     'agenda)
    (org-auto-scheduler--log-info "Found %d schedulable tasks" (length tasks))
    (nreverse tasks)))

(defun org-auto-scheduler-schedule-single-task (marker current-time)
  "Schedule a single task at MARKER, starting from CURRENT-TIME."
  (when (markerp marker)
    (org-with-point-at marker
      (let* ((headline (org-get-heading t t t t))
             (total-effort (or (org-auto-scheduler-get-effort marker) 60))
             (clocked-time (org-auto-scheduler-get-clocked-time marker))
             (remaining-effort (if (> clocked-time total-effort)
                                   10  ; Set to 10 minutes if clocked time exceeds total effort
                                 (max 10 (- total-effort clocked-time))))  ; Ensure minimum of 10 minutes
             (time-block (org-auto-scheduler-get-task-tag-block marker))
             (available-time current-time)
             (end-time nil)
             (attempts 0)
             (max-attempts (* 7 24 60)) ; 7 days in minutes
             (is-currently-clocked (org-clock-is-active)))
        (org-auto-scheduler--log-debug "Attempting to schedule task: %s" headline)
        (org-auto-scheduler--log-debug "Total effort: %d minutes, Clocked time: %d minutes, Remaining effort: %d minutes, Time block: %s, Currently clocked: %s"
                                       total-effort clocked-time remaining-effort time-block is-currently-clocked)
        (while (and (not end-time) (< attempts max-attempts))
          (setq attempts (1+ attempts))
          (if time-block
              (setq available-time (org-auto-scheduler-next-available-time-in-block available-time time-block))
            (setq available-time (org-auto-scheduler-next-available-time available-time remaining-effort)))
          (when available-time
            (setq end-time (time-add available-time (seconds-to-time (* 60 remaining-effort))))
            (when (org-auto-scheduler-time-slot-occupied-p available-time remaining-effort)
              (org-auto-scheduler--log-debug "Time slot occupied: %s to %s"
                                             (format-time-string "%Y-%m-%d %H:%M" available-time)
                                             (format-time-string "%Y-%m-%d %H:%M" end-time))
              (setq end-time nil))))
        (if end-time
            (progn
              (let* ((start-day (format-time-string "%Y-%m-%d" available-time))
                     (end-day (format-time-string "%Y-%m-%d" end-time))
                     (schedule-string
                      (if (string= start-day end-day)
                          (format "<%s-%s>"
                                  (format-time-string "%Y-%m-%d %a %H:%M" available-time)
                                  (format-time-string "%H:%M" end-time))
                        (format "<%s>--<%s>"
                                (format-time-string "%Y-%m-%d %a %H:%M" available-time)
                                (format-time-string "%Y-%m-%d %a %H:%M" end-time)))))
                (org-set-property "SCHEDULED" schedule-string)
                (org-auto-scheduler--log-info "Scheduled task '%s' from %s to %s (Remaining effort: %d minutes)"
                                              headline
                                              (format-time-string "%Y-%m-%d %H:%M" available-time)
                                              (format-time-string "%Y-%m-%d %H:%M" end-time)
                                              remaining-effort))
              (time-add end-time (seconds-to-time (* 60 org-auto-scheduler-task-gap))))
          (org-auto-scheduler--log-warn "Could not find available time slot within 7 days for task: %s" headline)
          (org-auto-scheduler--log-debug "Scheduling failed after %d attempts" attempts)
          (org-auto-scheduler--log-debug "Last attempted time: %s" (format-time-string "%Y-%m-%d %H:%M" available-time))
          current-time)))))

(defmacro org-with-point-at (pom &rest body)
  "Execute BODY with point at POM. POM can be a marker or a buffer position."
  (declare (indent 1) (debug t))
  `(let ((pom ,pom))
     (save-excursion
       (when (markerp pom)
         (set-buffer (marker-buffer pom)))
       (goto-char (or (marker-position pom) pom))
       ,@body)))

(defun org-auto-scheduler-setup ()
  "Set up the Org Auto Scheduler."
  (interactive)
  (global-set-key (kbd "C-c a s") 'org-auto-scheduler-schedule-tasks))

(defun org-auto-scheduler-time-to-minutes (time-string)
  "Convert a time string (HH:MM) to minutes since midnight."
  (let ((time (parse-time-string time-string)))
    (+ (* (nth 2 time) 60) (nth 1 time))))

(defun org-auto-scheduler-minutes-to-time (minutes)
  "Convert minutes since midnight to a time string (HH:MM)."
  (format "%02d:%02d" (/ minutes 60) (mod minutes 60)))

(defun org-auto-scheduler-get-task-tag-block (marker)
  "Get the time block for the task at MARKER based on its tags."
  (let ((tags (org-get-tags marker)))
    (cl-some (lambda (tag-block)
               (when (member (car tag-block) tags)
                 (cdr tag-block)))
             org-auto-scheduler-time-blocks)))

(defun org-auto-scheduler-next-available-time-in-block (current-time blocks)
  "Find the next available time in the specified BLOCKS after CURRENT-TIME."
  (let* ((current-minutes (+ (* (nth 2 (decode-time current-time)) 60)
                             (nth 1 (decode-time current-time))))
         (current-day (time-to-days current-time))
         (next-time nil)
         (days-checked 0))
    (while (and (not next-time) (< days-checked org-auto-scheduler-max-days-to-check))  ;; Use customizable variable
      (cl-loop for (start . end) in blocks
               for start-minutes = (org-auto-scheduler-time-to-minutes start)
               for end-minutes = (org-auto-scheduler-time-to-minutes end)
               when (< current-minutes start-minutes)
               do (setq next-time (org-auto-scheduler-minutes-to-time start-minutes))
               and return nil
               finally (progn
                         (setq current-minutes 0)
                         (setq current-day (1+ current-day))
                         (setq days-checked (1+ days-checked)))))
    (if next-time
        (org-time-string-to-time (format "<%Y-%m-%d %s>"
                                         (format-time-string "%Y-%m-%d" (days-to-time current-day))
                                         next-time))
      (org-auto-scheduler-next-available-time current-time 15)))) ; Fallback to regular scheduling

(defun org-auto-scheduler-time-fits-block-p (start-time end-time block)
  "Check if the time range fits within the given block."
  (let ((start-minutes (+ (* (nth 2 (decode-time start-time)) 60)
                          (nth 1 (decode-time start-time))))
        (end-minutes (+ (* (nth 2 (decode-time end-time)) 60)
                        (nth 1 (decode-time end-time)))))
    (cl-some (lambda (block-range)
               (let ((block-start (org-auto-scheduler-time-to-minutes (car block-range)))
                     (block-end (org-auto-scheduler-time-to-minutes (cdr block-range))))
                 (and (>= start-minutes block-start)
                      (<= end-minutes block-end))))
             block)))

(defun org-auto-scheduler-update-adaptive-data (task completion-time)
  "Update adaptive data for TASK based on COMPLETION-TIME."
  (condition-case err
      (let* ((task-id (org-id-get task))
             (scheduled-time (org-get-scheduled-time task))
             (time-diff (and scheduled-time completion-time
                             (float-time (time-subtract completion-time scheduled-time))))
             (current-score (gethash task-id org-auto-scheduler-adaptive-data 1.0)))
        (when (and task-id scheduled-time completion-time)
          (let* ((adjustment (* org-auto-scheduler-adaptive-factor
                                (min 1.0 (/ (abs time-diff) (* 60 60)))))
                 (new-score (max 0.5 (min 2.0 (+ current-score (if (< time-diff 0) adjustment (- adjustment)))))))
            (puthash task-id new-score org-auto-scheduler-adaptive-data)
            (org-auto-scheduler--log-debug "Updated adaptive score for task %s: %f" task-id new-score))))
    (error
     (org-auto-scheduler--log-error "Error updating adaptive data: %s" err))))

(defun org-auto-scheduler-safe-get-property (marker property)
  "Safely get PROPERTY for task at MARKER, returning nil if invalid."
  (condition-case nil
      (org-entry-get marker property)
    (error nil)))

(defun org-auto-scheduler-cleanup-adaptive-data ()
  "Remove adaptive data for tasks that no longer exist."
  (maphash (lambda (task-id _)
             (unless (org-id-find task-id 'marker)
               (remhash task-id org-auto-scheduler-adaptive-data)))
           org-auto-scheduler-adaptive-data))

(defun org-auto-scheduler-periodic-cleanup ()
  "Perform periodic cleanup tasks."
  (org-auto-scheduler-cleanup-adaptive-data))

;; Run cleanup every hour
;; (run-with-timer 0 3600 'org-auto-scheduler-periodic-cleanup) ;

(defun org-auto-scheduler-debug ()
  "Run auto-scheduler and display debug information."
  (interactive)
  (let ((org-auto-scheduler--log-level 'debug))
    (org-auto-scheduler--log-clear-log)
    (org-auto-scheduler-schedule-tasks)
    (org-auto-scheduler--log-open-log)))

(provide 'org-auto-scheduler)