(require 'org)
(require 'cl-lib)
(require 'org-id)
(require 'log4e)
(require 'parse-time)
(require 'org-agenda)
(require 'org-duration)
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

(defcustom org-auto-scheduler-large-task-minutes 12
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

(defcustom org-auto-scheduler-start-time "09:00"
  "The time to start scheduling each day (24-hour format, HH:MM)."
  :type 'string
  :group 'org-auto-scheduler)

(defcustom org-auto-scheduler-end-time "17:00"
  "The time to end scheduling each day (24-hour format, HH:MM)."
  :type 'string
  :group 'org-auto-scheduler)

(defcustom org-auto-scheduler-excluded-days '()
  "List of days to exclude from scheduling. 0 is Sunday, 6 is Saturday."
  :type '(repeat integer)
  :group 'org-auto-scheduler)

(defcustom org-auto-scheduler-time-interval 15
  "The interval in minutes for checking time slots. This determines the granularity of the scheduling."
  :type 'integer
  :group 'org-auto-scheduler)

(defcustom org-auto-scheduler-task-gap 5
  "The minimum gap in minutes to leave between tasks."
  :type 'integer
  :group 'org-auto-scheduler)

(defcustom org-auto-scheduler-max-days-to-check 14
  "The maximum number of days to look ahead for an available slot."
  :type 'intege
  :group 'org-auto-scheduler)

(defcustom org-auto-scheduler-debug nil
  "When non-nil, enable debug logging for org-auto-scheduler."
  :type 'boolean
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

(defcustom org-auto-scheduler-scheduled-property "AUTOSCH_SCHEDULED"
  "Property name to mark AUTOSCH tasks that have been scheduled in the current session."
  :type 'string
  :group 'org-auto-scheduler)

(defvar org-auto-scheduler-completed-tasks '()
  "List of AUTOSCH tasks that have been scheduled in the current process.")

(defun org-auto-scheduler-get-agenda-items (date)
  "Get agenda items for DATE.  Includes tasks with active timestamps."
  (condition-case err
      (let* ((date-string (format-time-string "%Y-%m-%d" date))
             (agenda-items
              (delq nil
                    (append
                     ;; Scheduled tasks
                     (org-map-entries
                      (lambda ()
                        (let* ((task-name (org-get-heading t t t t))
                               (scheduled-time-str (org-entry-get nil "SCHEDULED"))
                               (scheduled-time (when scheduled-time-str (org-time-string-to-time scheduled-time-str)))
                               (task-id (org-id-get))
                               (tags (org-get-tags)))
                          (when (and scheduled-time (not (member "AUTOSCH" tags)))
                            (let* ((scheduled-date (format-time-string "%Y-%m-%d" scheduled-time))
                                   (task-end-time (org-auto-scheduler-calculate-task-end-time (point))))
                              (when (string= scheduled-date date-string)
                                (list task-id scheduled-time task-end-time tags t task-name))))))
                      nil
                      'agenda)
                     ;; Tasks with active timestamps
                     (org-map-entries
                      (lambda ()
                        (let* ((task-name (org-get-heading t t t t))
                               (scheduled-time-str (org-entry-get nil "TIMESTAMP"))
                               (scheduled-time (when scheduled-time-str (org-time-string-to-time scheduled-time-str)))
                               (task-id (org-id-get))
                               (tags (org-get-tags)))
                          (when (and scheduled-time (not (member "AUTOSCH" tags)))
                            (let* ((scheduled-date (format-time-string "%Y-%m-%d" scheduled-time))
                                   (task-end-time (org-auto-scheduler-calculate-task-end-time (point))))
                              (when (string= scheduled-date date-string)
                                (list task-id scheduled-time task-end-time tags t task-name))))))
                      nil
                      'agenda)
                      ))))
        ;; Add completed AUTOSCH tasks for the current date
        (dolist (task org-auto-scheduler-completed-tasks)
          (let ((task-date (format-time-string "%Y-%m-%d" (nth 1 task))))
            (when (string= task-date date-string)
              (push task agenda-items))))

        (org-auto-scheduler--log-debug "Agenda items considered for conflicts:")
        (dolist (item agenda-items)
          (org-auto-scheduler--log-debug "Task: %s, ID: %s, Scheduled: %s, End: %s, Tags: %s, Task Name: %s"
                                         (nth 5 item) ; Task name
                                         (nth 0 item) ; Task ID
                                         (format-time-string "%Y-%m-%d %H:%M" (nth 1 item))
                                         (when (nth 2 item) (format-time-string "%Y-%m-%d %H:%M" (nth 2 item)))
                                         (nth 3 item)
                                         (nth 5 item)))
        (org-auto-scheduler--log-debug "Agenda items to be returned: %s" agenda-items)
        agenda-items)
    (error
     (org-auto-scheduler--log-error "Error getting agenda items: %s" err)
     nil)))

(defun org-auto-scheduler-parse-time-string (time-string)
  "Parse a time string in the format YYYY-MM-DD Day HH:MM."
  (when time-string
    (let ((parsed (parse-time-string time-string)))
      (encode-time (or (nth 0 parsed) 0)  ; secon
                   (or (nth 1 parsed) 0)  ; minute
                   (or (nth 2 parsed) 0)  ; hour
                   (or (nth 3 parsed) 1)  ; day
                   (or (nth 4 parsed) 1)  ; month
                   (or (nth 5 parsed) 1970)))))  ; year

(defun org-auto-scheduler-get-effort (pom)
  "Get the effort estimate for the task at point or marker POM.
This function retrieves the effort property of a task and converts
it to minutes."
  (let ((effort (org-entry-get pom "Effort" t)))
    (when effort
      (org-duration-to-minutes effort))))

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

(defun org-auto-scheduler-time-slot-within-scheduling-hours (start-time end-time)
  "Check if the time slot from START-TIME to END-TIME is within scheduling hours."
  (let* ((start-minutes (org-duration-to-minutes (format-time-string "%H:%M" start-time)))
         (end-minutes (org-duration-to-minutes (format-time-string "%H:%M" end-time)))
         (scheduler-start-minutes (org-duration-to-minutes org-auto-scheduler-start-time))
         (scheduler-end-minutes (org-duration-to-minutes org-auto-scheduler-end-time)))
    (and (>= start-minutes scheduler-start-minutes)
         (<= end-minutes scheduler-end-minutes))))

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
        (let ((task-end (save-excursion
                          (or (outline-next-heading)
                              (point-max)))))
          (when (re-search-forward ":LOGBOOK:" task-end t)
            (setq logbook-start (point))
            (if (re-search-forward ":END:" task-end t)
                (setq logbook-end (match-beginning 0))
              (setq logbook-end task-end))
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
                                                 start-str duration-minutes clock-sum))))))))
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
             (urgency-factor (/ 1.0 (1+ days-to-deadline))))
        (org-auto-scheduler--log-debug "Calculating score for task %s" (org-id-get))
        (+ (* effort org-auto-scheduler-effort-weight)
           (* (+ priority-score inherited-priority) org-auto-scheduler-priority-weight)
           (* urgency-factor org-auto-scheduler-urgency-weight)
           state-weight))
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

(defun org-auto-scheduler-get-project-id (marker)
  "Get the ID of the nearest ancestor with a :PROJECT: tag for the task at MARKER."
  (save-excursion
    (with-current-buffer (marker-buffer marker)
      (goto-char (marker-position marker))
      (let ((project-id nil))
        (while (and (not project-id) (org-up-heading-safe))
          (when (member "PROJECT" (org-get-tags nil t))
            (setq project-id (org-id-get))))
        project-id))))

(defun org-auto-scheduler-sort-tasks (tasks)
  "Sort TASKS based on their project, calculated scores, and sibling order within projects."
  (org-auto-scheduler--log-debug "Starting task sorting. Total tasks: %d" (length tasks))

  (let* ((tasks-with-info
          (mapcar (lambda (marker)
                    (org-with-point-at marker
                      (let* ((task-id (org-id-get))
                             (task-name (org-get-heading t t t t))
                             (tags (org-get-tags))
                             (score (org-auto-scheduler-calculate-score marker))
                             (project-id (org-auto-scheduler-get-project-id marker))
                             (hierarchy-position (org-auto-scheduler-get-hierarchy-position marker)))
                        (list marker
                              score
                              project-id
                              hierarchy-position
                              task-id
                              task-name
                              tags))))
                  tasks))
         (sorted-tasks
          (sort tasks-with-info
                (lambda (a b)
                  (let ((project-a (nth 2 a))
                        (project-b (nth 2 b))
                        (hierarchy-a (nth 3 a))
                        (hierarchy-b (nth 3 b))
                        (score-a (nth 1 a))
                        (score-b (nth 1 b)))
                    (cond
                     ;; First, sort by project
                     ((and project-a project-b (not (equal project-a project-b)))
                      (string< project-a project-b))
                     ;; Within the same project, sort by hierarchy
                     ((and project-a project-b (equal project-a project-b))
                      (org-auto-scheduler-compare-hierarchy hierarchy-a hierarchy-b))
                     ;; If no project, sort by score
                     ((not (= score-a score-b))
                      (> score-a score-b))
                     ;; If scores are equal, maintain original order
                     (t nil)))))))

    ;; Log all tasks after sorting
    (org-auto-scheduler--log-debug "Tasks after sorting:")
    (dolist (task sorted-tasks)
      (org-auto-scheduler--log-debug "  ID: %s, Name: %s, Tags: %s, Score: %s, Project: %s, Hierarchy: %s"
                                     (nth 4 task)
                                     (nth 5 task)
                                     (nth 6 task)
                                     (nth 1 task)
                                     (nth 2 task)
                                     (nth 3 task)))

    (org-auto-scheduler--log-debug "Finished sorting tasks. Sorted tasks: %d" (length sorted-tasks))
    (mapcar #'car sorted-tasks)))

(defun org-auto-scheduler-get-hierarchy-position (marker)
  "Get the hierarchical position of the task at MARKER within its project."
  (save-excursion
    (with-current-buffer (marker-buffer marker)
      (goto-char (marker-position marker))
      (let ((positions '()))
        (while (and (org-up-heading-safe)
                    (not (member "PROJECT" (org-get-tags nil t))))
          (push (org-auto-scheduler-get-task-position (point-marker)) positions))
        (nreverse positions)))))

(defun org-auto-scheduler-compare-hierarchy (h1 h2)
  "Compare two hierarchy positions H1 and H2."
  (let ((result nil))
    (while (and (not result) h1 h2)
      (cond
       ((< (car h1) (car h2)) (setq result 'less))
       ((> (car h1) (car h2)) (setq result 'greater))
       (t (setq h1 (cdr h1)
                h2 (cdr h2)))))
    (cond
     ((eq result 'less) t)
     ((eq result 'greater) nil)
     (h1 nil)  ; h1 is longer, so it comes after h2
     (h2 t)    ; h2 is longer, so it comes after h1
     (t nil))))  ; They are equal, maintain original order
     
(defun org-auto-scheduler-time-slot-occupied-p (start-time duration &optional ignore-id)
  "Check if the time slot is occupied, considering active timestamps and ignoring all-day tasks."
  (let* ((end-time (time-add start-time (seconds-to-time (* 60 duration))))
         (agenda-items (org-auto-scheduler-get-agenda-items start-time))
         (day-start (org-auto-scheduler-time-with-time-string start-time org-auto-scheduler-start-time))
         (day-end (org-auto-scheduler-time-with-time-string start-time org-auto-scheduler-end-time)))
    (org-auto-scheduler--log-debug "Checking time slot %s to %s"
                                   (format-time-string "%Y-%m-%d %H:%M" start-time)
                                   (format-time-string "%Y-%m-%d %H:%M" end-time))
    (or 
     ;; Check day boundaries
     (and (time-less-p start-time day-start) day-start)
     (and (time-less-p day-end end-time) day-end)
     ;; Check conflicts with existing tasks
     (cl-some 
      (lambda (item)
        (let* ((task-id (nth 0 item))
               (task-start (nth 1 item))
               (task-end (nth 2 item))
               (tags (nth 3 item))
               (consider-for-conflicts (nth 4 item))
               (task-name (nth 5 item))
               (is-autosch (member "AUTOSCH" tags))
               (has-time (string-match "[0-9][0-9]:[0-9][0-9]" (format-time-string "%H:%M" task-start)))
               (task-start-with-gap (time-subtract task-start (seconds-to-time (* 60 org-auto-scheduler-task-gap))))
               (task-end-with-gap (time-add task-end (seconds-to-time (* 60 org-auto-scheduler-task-gap)))))
          (when (and (not (equal task-id ignore-id))
                     (or (not is-autosch) (and is-autosch consider-for-conflicts))
                     has-time
                     (time-less-p start-time task-end-with-gap)
                     (time-less-p task-start-with-gap end-time))
            (org-auto-scheduler--log-debug "    Conflict detected with task: %s" task-name)
            task-end-with-gap)))
      agenda-items))))

(defun org-auto-scheduler-next-available-time (start-time duration)
  "Find the next available time slot starting from START-TIME for DURATION minutes."
  (org-auto-scheduler--log-debug "[org-auto-scheduler-next-available-time] Finding next available time after %s for %d minutes"
                                 (format-time-string "%Y-%m-%d %H:%M" start-time) duration)
  (let ((current-time start-time)
        (found-slot nil)
        (max-time (time-add start-time (days-to-time org-auto-scheduler-max-days-to-check))))
    (while (and (not found-slot) (time-less-p current-time max-time))
      (let* ((day-start (org-auto-scheduler-time-with-time-string current-time org-auto-scheduler-start-time))
             (day-end (org-auto-scheduler-time-with-time-string current-time org-auto-scheduler-end-time))
             (day-of-week (string-to-number (format-time-string "%w" current-time)))
             (end-time (time-add current-time (seconds-to-time (* 60 duration))))
             (occupied-result (org-auto-scheduler-time-slot-occupied-p current-time duration)))
        (org-auto-scheduler--log-debug "[org-auto-scheduler-next-available-time] Attempting to find next available time slot starting from %s for %d minutes, original start %s"
                                       (format-time-string "%Y-%m-%d %H:%M" current-time) duration (format-time-string "%Y-%m-%d %H:%M" start-time))
        (cond
         ((member day-of-week org-auto-scheduler-excluded-days)
          (org-auto-scheduler--log-debug "[org-auto-scheduler-next-available-time] Day %d is excluded, moving to next day" day-of-week)
          (setq current-time (org-auto-scheduler-next-day current-time)))
         ((time-less-p current-time day-start)
          (org-auto-scheduler--log-debug "[org-auto-scheduler-next-available-time] Current time is before day start, setting to day start")
          (setq current-time day-start))
         ((time-less-p day-end end-time)
          (org-auto-scheduler--log-debug "[org-auto-scheduler-next-available-time] End time is after day end, moving to next day start")
          (setq current-time (org-auto-scheduler-next-day-start current-time)))
         (occupied-result
          (org-auto-scheduler--log-debug "[org-auto-scheduler-next-available-time] Time slot occupied, moving to %s"
                                         (format-time-string "%Y-%m-%d %H:%M" occupied-result))
          (setq current-time occupied-result))
         (t
          (setq found-slot current-time)))))
    (if found-slot
        (progn
          (org-auto-scheduler--log-debug "[org-auto-scheduler-next-available-time] Found available time slot: %s"
                                         (format-time-string "%Y-%m-%d %H:%M" found-slot))
          found-slot)
      (org-auto-scheduler--log-debug "[org-auto-scheduler-next-available-time] No available time slot found within %d days"
                                     org-auto-scheduler-max-days-to-check)
      nil)))

(defun org-auto-scheduler-next-day (time)
  "Get the start of the next day after TIME."
  (time-add time (seconds-to-time (* 24 60 60))))

(defun org-time-with-hour (time hour)
  "Set the hour of TIME to HOUR."
  (let ((decoded (decode-time time)))
    (apply #'encode-time (append (list 0 0 hour) (nthcdr 3 decoded)))))

(defun org-auto-scheduler-next-available-time-in-block (current-time blocks)
  "Find the next available time in the specified BLOCKS after CURRENT-TIME. Returns nil if no time is found within the blocks."
  (let* ((current-minutes (+ (* (nth 2 (decode-time current-time)) 60)
                             (nth 1 (decode-time current-time))))
         (current-day (time-to-days current-time))
         (next-time nil)
         (days-checked 0))
    (while (and (not next-time) (< days-checked org-auto-scheduler-max-days-to-check))
      (cl-loop for (start . end) in blocks
               for start-minutes = (org-auto-scheduler-time-to-minutes start)
               for end-minutes = (org-auto-scheduler-time-to-minutes end)
               when (< current-minutes start-minutes)
               do (setq next-time (org-auto-scheduler-minutes-to-time start-minutes))
               and do (return)
               finally (progn
                         (setq current-minutes 0)
                         (setq current-day (1+ current-day))
                         (setq days-checked (1+ days-checked)))))
    (if next-time
        (let ((date-str (format-time-string "%Y-%m-%d" (days-to-time current-day)))
              (time-str next-time))
          (org-time-string-to-time (concat date-str " " time-str)))
      nil)))

(defun org-auto-scheduler-calculate-task-end-time (&optional pom)
  "Get the end time of the entry at POM based on its scheduled time and effort.
If POM is nil, use the current point."
  (save-excursion
    (when pom (goto-char pom))
    (let* ((scheduled-string (or (org-entry-get nil "SCHEDULED") (org-entry-get nil "TIMESTAMP")))
           (effort (or (org-auto-scheduler-get-effort nil) 60)))
      (when scheduled-string
        (cond
         ;; Format: <2024-10-12 Sat 05:00-09:00>
         ((string-match "<\\([0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\} [A-Za-z]+ [0-9]\\{2\\}:[0-9]\\{2\\}\\)-\\([0-9]\\{2\\}:[0-9]\\{2\\}\\)>" scheduled-string)
          (let* ((date (match-string 1 scheduled-string))
                 (end-time (match-string 2 scheduled-string))
                 (full-end-time-str (concat (substring date 0 11) end-time))
                 (parsed-end-time (org-time-string-to-time full-end-time-str)))
            parsed-end-time))

         ;; Format: <2023-05-01 Mon 09:00>--<2023-05-01 Mon 10:00>
         ((string-match "\\(<?[^>]+>?\\)--\\(<[^>]+>\\)" scheduled-string)
          (let ((parsed-end-time (org-time-string-to-time (match-string 2 scheduled-string))))
            parsed-end-time))

         ;; Single time format: <2023-05-01 Mon 09:00>
         (t
          (let* ((start-time (org-time-string-to-time scheduled-string))
                 (end-time (time-add start-time (seconds-to-time (* effort 60)))))
            end-time)))))))

(defun org-auto-scheduler-next-day-start (time)
  "Get the start time of the next day after TIME."
  (let* ((next-day (time-add time (seconds-to-time 86400))) ; Add 24 hours
         (next-day-str (format-time-string "%Y-%m-%d" next-day))
         (start-time-str (concat next-day-str " " org-auto-scheduler-start-time)))
    (org-time-string-to-time start-time-str)))


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
  "Schedule all schedulable tasks, grouping them by project."
  (interactive)
  (org-auto-scheduler--log-info "Starting auto-scheduling process")
  (condition-case err
      (progn
        (setq org-auto-scheduler-completed-tasks '())  ; Clear the completed tasks list
        (let* ((tasks (org-auto-scheduler-get-schedulable-tasks))
               (sorted-tasks (org-auto-scheduler-sort-tasks tasks))
               (current-time (org-auto-scheduler-get-start-time))
               (tasks-scheduled 0)
               (total-tasks (length sorted-tasks))
               (previous-project nil))
          (dolist (marker sorted-tasks)
            (let ((task-project (org-auto-scheduler-get-project-id marker)))
              (when (or (and task-project (not (equal task-project previous-project)))
                        (and (null task-project) (not (null previous-project))))
                (setq current-time (org-auto-scheduler-get-start-time))
                (setq previous-project task-project)
                (org-auto-scheduler--log-debug "Project changed or no project set. Resetting current time to %s"
                                               (format-time-string "%Y-%m-%d %H:%M" current-time)))

              (setq current-time (org-auto-scheduler-schedule-single-task marker current-time))
              (setq tasks-scheduled (1+ tasks-scheduled))
              (when (zerop (mod tasks-scheduled 10))
                (org-auto-scheduler--log-info "Scheduled %d/%d tasks..." tasks-scheduled total-tasks))))
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
              (headline (org-get-heading t t t t))
              (not-before (org-entry-get nil "NOT_BEFORE")))
         (when (and is-autosch is-valid-state)
           (push (point-marker) tasks)
           (org-auto-scheduler--log-debug "Found schedulable task: %s (State: %s, NOT_BEFORE: %s)"
                                          headline state (or not-before "Not set")))))
     nil)
    (org-auto-scheduler--log-info "Found %d schedulable tasks" (length tasks))
    (nreverse tasks)))

(defun org-auto-scheduler-schedule-single-task (marker current-time)
  "Schedule a single task at MARKER, starting from CURRENT-TIME.
This function attempts to find an available time slot for the task,
respecting time blocks if specified, and avoiding conflicts with
existing scheduled tasks."
  (org-auto-scheduler--log-debug "[org-auto-scheduler-schedule-single-task] Attempting to schedule task at marker %s" marker)
  (when (markerp marker)
    (org-with-point-at marker
      (let* ((headline (org-get-heading t t t t))
             (task-id (org-id-get))
             (total-effort (or (org-auto-scheduler-get-effort marker) 60))
             (clocked-time (org-auto-scheduler-get-clocked-time marker))
             (remaining-effort (if (> clocked-time total-effort)
                                   10  ; Set to 10 minutes if clocked time exceeds total effort
                                 (max 10 (- total-effort clocked-time))))  ; Ensure minimum of 10 minutes
             (time-block (org-auto-scheduler-get-task-tag-block marker))
             (not-before (org-auto-scheduler-get-not-before marker))
             (start-time (if (and not-before (time-less-p current-time not-before))
                             not-before
                           current-time))
             (available-time (if time-block
                                 (org-auto-scheduler-next-available-time-in-block start-time time-block)
                               start-time))
             (end-time nil)
             (attempts 0)
             (max-attempts (* 7 24 60)) ; 7 days in minutes
             (is-currently-clocked (org-clock-is-active)))
        (org-auto-scheduler--log-debug "[org-auto-scheduler-schedule-single-task] Task: %s" headline)
        (org-auto-scheduler--log-debug "[org-auto-scheduler-schedule-single-task] Total effort: %d minutes, Clocked time: %d minutes, Remaining effort: %d minutes, Time block: %s, Currently clocked: %s, Not before: %s"
                                       total-effort clocked-time remaining-effort time-block is-currently-clocked
                                       (if not-before (format-time-string "%Y-%m-%d %H:%M" not-before) "Not set"))
        (while (and (not end-time) (< attempts max-attempts))
          (setq attempts (1+ attempts))
          (when available-time
            (setq end-time (time-add available-time (seconds-to-time (* 60 remaining-effort))))
            (let ((occupied-result (org-auto-scheduler-time-slot-occupied-p available-time remaining-effort task-id)))
              (when occupied-result
                (org-auto-scheduler--log-debug "[org-auto-scheduler-schedule-single-task] Time slot occupied: %s to %s"
                                               (format-time-string "%Y-%m-%d %H:%M" available-time)
                                               (format-time-string "%Y-%m-%d %H:%M" occupied-result))
                (setq end-time nil)
                (setq available-time (if time-block
                                          (org-auto-scheduler-next-available-time-in-block occupied-result time-block)
                                        (org-auto-scheduler-next-available-time occupied-result remaining-effort)))))))
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
                (org-set-property org-auto-scheduler-scheduled-property "t")
                (push (list task-id available-time end-time '("AUTOSCH") t headline) org-auto-scheduler-completed-tasks)
                (org-auto-scheduler--log-info "[org-auto-scheduler-schedule-single-task] Scheduled task '%s' from %s to %s (Remaining effort: %d minutes)"
                                              headline
                                              (format-time-string "%Y-%m-%d %H:%M" available-time)
                                              (format-time-string "%Y-%m-%d %H:%M" end-time)
                                              remaining-effort)
                (org-auto-scheduler--log-debug "[org-auto-scheduler-schedule-single-task] Adding task %s to the list of completed scheduling tasks"
                                               task-id))
              (time-add end-time (seconds-to-time (* 60 org-auto-scheduler-task-gap))))
          (org-auto-scheduler--log-warn "[org-auto-scheduler-schedule-single-task] Could not find available time slot within 7 days for task: %s" headline)
          (org-auto-scheduler--log-debug "[org-auto-scheduler-schedule-single-task] Scheduling failed after %d attempts" attempts)
          (org-auto-scheduler--log-debug "[org-auto-scheduler-schedule-single-task] Last attempted time: %s" (format-time-string "%Y-%m-%d %H:%M" available-time))
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

(defun org-auto-scheduler-safe-get-property (marker property)
  "Safely get PROPERTY for task at MARKER, returning nil if invalid."
  (condition-case nil
      (org-entry-get marker property)
    (error nil)))

(defun org-auto-scheduler-debug ()
  "Run auto-scheduler and display debug information."
  (interactive)
  (let ((org-auto-scheduler--log-level 'debug))
    (org-auto-scheduler--log-clear-log)
    (org-auto-scheduler-schedule-tasks)
    (org-auto-scheduler--log-open-log)))

(defun org-auto-scheduler-time-with-time-string (time time-string)
  "Set the time of TIME to the time specified in TIME-STRING (HH:MM)."
  (let* ((decoded (decode-time time))
         (hour-minute (mapcar #'string-to-number (split-string time-string ":"))))
    (apply #'encode-time
           (append (list 0 (nth 1 hour-minute) (nth 0 hour-minute))
                   (nthcdr 3 decoded)))))

(defun org-auto-scheduler-calculate-remaining-effort (marker)
  "Calculate the remaining effort for the task at MARKER.
This function returns the effort estimate or a default duration
if no effort is specified."
  (or (org-auto-scheduler-get-effort marker)
      org-auto-scheduler-default-task-duration))

(defcustom org-auto-scheduler-default-task-duration 60
  "Default duration in minutes for tasks without an explicit effort."
  :type 'integer
  :group 'org-auto-scheduler)

(defun org-auto-scheduler-validate-config ()
  "Validate the configuration variables for org-auto-scheduler.
This function checks for inconsistencies or invalid values in the
configuration variables and raises errors if any are found."
  (let ((start-time (org-duration-to-minutes org-auto-scheduler-start-time))
        (end-time (org-duration-to-minutes org-auto-scheduler-end-time)))
    (when (>= start-time end-time)
      (error "org-auto-scheduler-start-time must be earlier than org-auto-scheduler-end-time"))
    (when (< org-auto-scheduler-time-interval 1)
      (error "org-auto-scheduler-time-interval must be at least 1 minute"))
    (when (< org-auto-scheduler-task-gap 0)
      (error "org-auto-scheduler-task-gap cannot be negative"))
    (when (< org-auto-scheduler-max-days-to-check 1)
      (error "org-auto-scheduler-max-days-to-check must be at least 1"))
    (dolist (day org-auto-scheduler-excluded-days)
      (unless (and (integerp day) (<= 0 day 6))
        (error "org-auto-scheduler-excluded-days must contain integers from 0 to 6")))))

(defun org-auto-scheduler-get-not-before (marker)
  "Get the NOT_BEFORE property for the task at MARKER."
  (let ((not-before-string (org-entry-get marker "NOT_BEFORE")))
    (when not-before-string
      (org-time-string-to-time not-before-string))))

;; Call this function when the package is loaded
(org-auto-scheduler-validate-config)

(provide 'org-auto-scheduler)