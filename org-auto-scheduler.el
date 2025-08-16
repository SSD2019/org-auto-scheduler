(require 'org)
(require 'cl-lib)
(require 'org-id)
(require 'log4e)
(require 'parse-time)
(require 'org-agenda)
(require 'org-duration)
(require 'time-date)
(require 'org-clock)


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
    ("WRITE" . 0)
    ("LATER" . -10)
    ("BUY" . 0)
    ("READ" . 0))
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

(defcustom org-auto-scheduler-recurring-look-days-ahead 30
  "Number of days to look ahead for scheduling recurring tasks."
  :type 'integer
  :group 'org-auto-scheduler)

(defcustom org-auto-scheduler-repeater-integration t
  "When non-nil, integrate repeater tasks (including habits) into conflict detection.
This will project repeater task occurrences into the future to prevent
AUTOSCH tasks from being scheduled at the same time as repeater tasks.
Supports +, ++, and .+ repeater types with d/w/m/y intervals."
  :type 'boolean
  :group 'org-auto-scheduler)

(defcustom org-auto-scheduler-repeater-look-days-ahead nil
  "Number of days to look ahead for projecting repeater task occurrences.
If nil, uses the maximum of org-auto-scheduler-max-days-to-check 
and org-auto-scheduler-recurring-look-days-ahead."
  :type '(choice (const :tag "Use max of other settings" nil)
                 (integer :tag "Specific number of days"))
  :group 'org-auto-scheduler)

;; Keep habit-related variables for backward compatibility
(defvaralias 'org-auto-scheduler-habit-integration 'org-auto-scheduler-repeater-integration)
(defvaralias 'org-auto-scheduler-habit-look-days-ahead 'org-auto-scheduler-repeater-look-days-ahead)

(defvar org-auto-scheduler-completed-tasks '()
  "List of AUTOSCH tasks that have been scheduled in the current process.")

(defvar org-auto-scheduler--repeater-projections-cache nil
  "Cache for repeater projections to improve performance.
Format: ((end-date . projections) ...)")

(defvar org-auto-scheduler--repeater-cache-valid-until nil
  "Time until which the repeater projections cache is valid.")

(defcustom org-auto-scheduler-tag-weights
  '(("URGENT" . 10)
    ("IMPORTANT" . 5)
    ("QUICK" . 2))
  "Alist of weights for different tags."
  :type '(alist :key-type string :value-type number)
  :group 'org-auto-scheduler)

(defcustom org-auto-scheduler-project-priority-property "PROJECT_PRIORITY"
  "Property name for setting project priority."
  :type 'string
  :group 'org-auto-scheduler)

(defcustom org-auto-scheduler-project-interleave-property "PROJECT_INTERLEAVE"
  "Property name for controlling project interleaving.
Values can be:
- \"t\" or \"yes\": allow interleaving
- \"nil\" or \"no\": prevent interleaving
- not set: use default from org-auto-scheduler-interleave-projects"
  :type 'string
  :group 'org-auto-scheduler)

(defcustom org-auto-scheduler-interleave-projects t
  "When non-nil, interleave tasks between different projects by default.
This can be overridden on a per-project basis using the PROJECT_INTERLEAVE property."
  :type 'boolean
  :group 'org-auto-scheduler)

(defcustom org-auto-scheduler-category-weights
  '(("Work" . 10)
    ("Personal" . 5)
    ("Errands" . 2))
  "Alist of weights for different categories."
  :type '(alist :key-type string :value-type number)
  :group 'org-auto-scheduler)

(defvar org-auto-scheduler-report-buffer-name "*Org Auto Scheduler Report*"
  "Name of the buffer for the Org Auto Scheduler Report.")

(defcustom org-auto-scheduler-silent-mode nil
  "When non-nil, suppress report creation and display."
  :type 'boolean
  :group 'org-auto-scheduler)

(defcustom org-auto-scheduler-background-enabled nil
  "When non-nil, enable background auto-scheduling when Emacs is idle."
  :type 'boolean
  :group 'org-auto-scheduler)

(defcustom org-auto-scheduler-idle-time 300
  "Number of idle seconds before running the background scheduler."
  :type 'integer
  :group 'org-auto-scheduler)

(defcustom org-auto-scheduler-background-interval 300
  "Interval in seconds for background scheduling (default: 5 minutes)."
  :type 'integer
  :group 'org-auto-scheduler)

(defvar org-auto-scheduler--idle-timer nil
  "Timer for background auto-scheduling.")

(defvar org-auto-scheduler--background-running nil
  "Flag to prevent concurrent background scheduling runs.")

(defcustom org-auto-scheduler-sync-caldav t
  "When non-nil, automatically sync with CalDAV before and after scheduling tasks."
  :type 'boolean
  :group 'org-auto-scheduler)

(defcustom org-auto-scheduler-allowed-hostnames nil
  "List of hostnames allowed to run background auto-scheduling.
When nil, background scheduling can run on any computer if enabled.
When set to a list of strings, background scheduling will only run
if the current system's hostname matches one in this list.
Example: '(\"work-laptop\" \"home-desktop\")"
  :type '(choice (const :tag "Any computer" nil)
                 (repeat :tag "Specific computers" string))
  :group 'org-auto-scheduler)

(defun org-auto-scheduler-get-category-weight (marker)
  "Get the weight for the category of the task at MARKER."
  (let ((category (org-with-point-at marker (org-get-category))))
    (or (cdr (assoc category org-auto-scheduler-category-weights))
        1)))  ; Default weight if category not found

(defun org-auto-scheduler-get-project-priority (marker)
  "Get the priority of the project that contains the task at MARKER."
  (save-excursion
    (with-current-buffer (marker-buffer marker)
      (goto-char (marker-position marker))
      (let ((priority nil))
        (while (and (not priority) (org-up-heading-safe))
          (when (member "PROJECT" (org-get-tags nil t))
            (setq priority (org-entry-get nil org-auto-scheduler-project-priority-property))))
        (or (and priority (string-to-number priority)) 0)))))

(defun org-auto-scheduler-get-agenda-items (date)
  "Get agenda items for DATE.  Includes tasks with active timestamps and projected habit occurrences."
  (condition-case err
      (let* ((date-string (format-time-string "%Y-%m-%d" date))
             (agenda-items
              (delq nil
                    (append
                     ;; Scheduled tasks (excluding habit tasks to avoid double-counting)
                     (org-map-entries
                      (lambda ()
                        (let* ((task-name (org-get-heading t t t t))
                               (scheduled-time-str (org-entry-get nil "SCHEDULED"))
                               (scheduled-time (when scheduled-time-str (org-time-string-to-time scheduled-time-str)))
                               (task-id (org-id-get))
                               (tags (org-get-tags))
                               (has-repeater (org-auto-scheduler-has-repeater-task (point-marker))))
                          ;; Exclude AUTOSCH tags and repeater tasks (repeaters are handled separately)
                          (when (and scheduled-time 
                                   (not (member "AUTOSCH" tags))
                                   (not has-repeater))
                            (let* ((scheduled-date (format-time-string "%Y-%m-%d" scheduled-time))
                                   (task-end-time (org-auto-scheduler-calculate-task-end-time (point))))
                              (when (string= scheduled-date date-string)
                                (list task-id scheduled-time task-end-time tags t task-name))))))
                      nil
                      'agenda)
                     ;; Tasks with active timestamps (excluding habit tasks)
                     (org-map-entries
                      (lambda ()
                        (let* ((task-name (org-get-heading t t t t))
                               (scheduled-time-str (org-entry-get nil "TIMESTAMP"))
                               (scheduled-time (when scheduled-time-str (org-time-string-to-time scheduled-time-str)))
                               (task-id (org-id-get))
                               (tags (org-get-tags))
                               (has-repeater (org-auto-scheduler-has-repeater-task (point-marker))))
                          ;; Exclude AUTOSCH tags and repeater tasks
                          (when (and scheduled-time 
                                   (not (member "AUTOSCH" tags))
                                   (not has-repeater))
                            (let* ((scheduled-date (format-time-string "%Y-%m-%d" scheduled-time))
                                   (task-end-time (org-auto-scheduler-calculate-task-end-time (point))))
                              (when (string= scheduled-date date-string)
                                (list task-id scheduled-time task-end-time tags t task-name))))))
                      nil
                      'agenda)))))
        
        ;; Add completed AUTOSCH tasks for the current date
        (dolist (task org-auto-scheduler-completed-tasks)
          (let ((task-date (format-time-string "%Y-%m-%d" (nth 1 task))))
            (when (string= task-date date-string)
              (push task agenda-items))))

        ;; Add projected repeater occurrences for the current date
        (when org-auto-scheduler-repeater-integration
          (let* ((look-ahead-days (or org-auto-scheduler-repeater-look-days-ahead
                                    (max org-auto-scheduler-max-days-to-check
                                         org-auto-scheduler-recurring-look-days-ahead)))
                 (end-date (time-add (current-time) (days-to-time look-ahead-days)))
                 (repeater-projections (org-auto-scheduler-get-all-repeater-projections end-date)))
            (dolist (repeater-item repeater-projections)
              (let ((repeater-date (format-time-string "%Y-%m-%d" (nth 1 repeater-item))))
                (when (string= repeater-date date-string)
                  (push repeater-item agenda-items)
                  (org-auto-scheduler--log-debug "Added projected repeater occurrence: %s at %s"
                                                 (nth 5 repeater-item)
                                                 (format-time-string "%Y-%m-%d %H:%M" (nth 1 repeater-item))))))))

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
  "Calculate a score for a task at MARKER based on its properties and state.
Returns a list containing the total score and individual score components."
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
             (category-weight (org-auto-scheduler-get-category-weight marker))
             (effort-score (* effort org-auto-scheduler-effort-weight))
             (priority-total (* (+ priority-score inherited-priority) org-auto-scheduler-priority-weight))
             (urgency-score (* urgency-factor org-auto-scheduler-urgency-weight))
             (category-score (* category-weight 10))
             (total-score (+ effort-score 
                            priority-total
                            urgency-score
                            category-score
                            state-weight)))
        (org-auto-scheduler--log-debug "Calculating score for task %s" (org-id-get))
        (list total-score effort-score priority-total urgency-score category-score state-weight
              effort priority-score inherited-priority days-to-deadline category-weight state))
    (error
     (org-auto-scheduler--log-error "Error calculating score: %s\nMarker: %s\nBacktrace: %s"
                                   err
                                   marker
                                   (with-output-to-string (backtrace)))
     (list 0 0 0 0 0 0 0 0 0 0 0 ""))))  ; Return all zeroes on error

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

(defun org-auto-scheduler-project-allows-interleave (marker)
  "Check if the project containing task at MARKER allows interleaving."
  (save-excursion
    (with-current-buffer (marker-buffer marker)
      (goto-char (marker-position marker))
      (let ((interleave-setting nil))
        (while (and (not interleave-setting) (org-up-heading-safe))
          (when (member "PROJECT" (org-get-tags nil t))
            (setq interleave-setting 
                  (org-entry-get nil org-auto-scheduler-project-interleave-property))))
        (cond
         ((or (equal interleave-setting "t") 
              (equal interleave-setting "yes")) t)
         ((or (equal interleave-setting "nil") 
              (equal interleave-setting "no")) nil)
         (t org-auto-scheduler-interleave-projects))))))

(defun org-auto-scheduler-sort-tasks (tasks)
  "Sort TASKS based on their project, scheduled date, calculated scores, and position."
  (let* ((tasks-with-info
          (mapcar (lambda (marker)
                    (let* ((task-id (org-with-point-at marker 
                                    (or (org-id-get) 
                                        (org-id-get-create))))
                           (task-name (org-with-point-at marker 
                                      (org-get-heading t t t t)))
                           (tags (org-with-point-at marker 
                                 (org-get-tags)))
                           (score-info (org-auto-scheduler-calculate-score marker))
                           (score (car score-info))
                           (project-id (org-auto-scheduler-get-project-id marker))
                           (project-priority (org-auto-scheduler-get-project-priority marker))
                           (allows-interleave (org-auto-scheduler-project-allows-interleave marker))
                           (task-position (org-auto-scheduler-get-task-position marker))
                           (scheduled (org-with-point-at marker 
                                      (org-entry-get nil "SCHEDULED")))
                           (not-before (org-auto-scheduler-get-not-before marker))
                           (time-block (org-auto-scheduler-get-task-tag-block marker))
                           (effort (org-auto-scheduler-get-effort marker)))
                      (org-auto-scheduler--log-debug 
                       "Task info: Name: %s, ID: %s, Project: %s, Score: %f, Position: %d"
                       task-name task-id project-id score task-position)
                      (list marker
                            score
                            project-id
                            project-priority
                            task-position
                            task-id
                            task-name
                            tags
                            scheduled
                            allows-interleave
                            not-before
                            time-block
                            effort
                            (cdr score-info))))
                  tasks)))
    (org-auto-scheduler--log-debug "Tasks after sorting:")
    (let ((sorted-tasks (sort tasks-with-info
                             (lambda (a b)
                               (let* ((project-priority-a (nth 3 a))
                                      (project-priority-b (nth 3 b))
                                      (project-a (nth 2 a))
                                      (project-b (nth 2 b))
                                      (position-a (nth 4 a))
                                      (position-b (nth 4 b))
                                      (score-a (nth 1 a))
                                      (score-b (nth 1 b))
                                      (allows-interleave-a (nth 9 a))
                                      (allows-interleave-b (nth 9 b)))
                                 (cond
                                  ((not (= project-priority-a project-priority-b))
                                   (> project-priority-a project-priority-b))
                                  ((and project-a project-b
                                        (not (equal project-a project-b)))
                                   (if (and allows-interleave-a allows-interleave-b)
                                       (< position-a position-b)
                                     (string< project-a project-b)))
                                  ((and project-a project-b
                                        (equal project-a project-b))
                                   (< position-a position-b))
                                  ((not (= score-a score-b))
                                   (> score-a score-b))
                                  (t nil)))))))
      (dolist (task sorted-tasks)
        (org-auto-scheduler--log-debug 
         "  ID: %s, Name: %s, Tags: %s, Score: %f, Project: %s, Position: %d, Scheduled: %s"
         (nth 5 task)  ; task-id
         (nth 6 task)  ; task-name
         (nth 7 task)  ; tags
         (nth 1 task)  ; score
         (nth 2 task)  ; project-id
         (nth 4 task)  ; position
         (nth 8 task))) ; scheduled
      sorted-tasks)))

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

(defun time-to-minutes (time)
  "Convert TIME duration to minutes."
  (/ (time-to-seconds time) 60))

(defun org-auto-scheduler-next-available-time-in-block (current-time blocks remaining-effort)
  "Find the next available time in the specified BLOCKS after CURRENT-TIME.
Returns the next available time if found within the blocks and max-days-to-check,
and if the task with REMAINING-EFFORT fits within the block.
If no slot is found within blocks after max-days-to-check, returns nil."
  (let* ((days-checked 0)
         (found-time nil))
    
    ;; Try to find a slot within blocks
    (while (and (not found-time) 
                (< days-checked org-auto-scheduler-max-days-to-check))
      (let ((day-start (time-add current-time (days-to-time days-checked))))
        (dolist (block blocks)
          (let* ((block-start (org-auto-scheduler-time-with-time-string day-start (car block)))
                 (block-end (org-auto-scheduler-time-with-time-string day-start (cdr block))))
            (when (and (time-less-p current-time block-end)
                      (org-auto-scheduler-time-fits-block-p block-start block-end remaining-effort))
              (setq found-time (if (time-less-p current-time block-start)
                                  block-start
                                current-time))))))
      
      ;; If no slot found in the current day, check the immediate next day
      (when (and (not found-time) (= days-checked 0))
        (let ((next-day-start (org-auto-scheduler-next-day-start current-time)))
          (dolist (block blocks)
            (let* ((block-start (org-auto-scheduler-time-with-time-string next-day-start (car block)))
                   (block-end (org-auto-scheduler-time-with-time-string next-day-start (cdr block))))
              (when (org-auto-scheduler-time-fits-block-p block-start block-end remaining-effort)
                (setq found-time block-start))))))

      ;; Move to the next day
      (setq days-checked (1+ days-checked))
      (setq current-time (org-auto-scheduler-next-day-start current-time)))
    
    (when found-time
      (org-auto-scheduler--log-debug 
       "Found next available block time: %s" 
       (format-time-string "%Y-%m-%d %H:%M" found-time)))
    
    found-time))

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
  (when org-auto-scheduler-sync-caldav
    (require 'org-caldav)
    (org-caldav-sync))
  (condition-case err
      (progn
        (setq org-auto-scheduler-completed-tasks '())  ; Clear the completed tasks list
        (org-auto-scheduler-create-report-buffer)      ; Create the report buffer
        (let* ((tasks (org-auto-scheduler-get-schedulable-tasks))
               (sorted-tasks-info (org-auto-scheduler-sort-tasks tasks))
               (current-time (org-auto-scheduler-get-start-time))
               (tasks-scheduled 0)
               (total-tasks (length sorted-tasks-info))
               (previous-project nil))
          
          (dolist (task-info sorted-tasks-info)
            (let* ((marker (car task-info))
                   (task-project (nth 2 task-info)))
              
              (when (or (not (equal task-project previous-project))
                        (null task-project))
                (setq current-time (org-auto-scheduler-get-start-time))
                (setq previous-project task-project)
                (org-auto-scheduler--log-debug "Project changed or is null. Resetting current time to %s"
                                             (format-time-string "%Y-%m-%d %H:%M" current-time)))

              (setq current-time (org-auto-scheduler-schedule-single-task marker current-time))
              (org-auto-scheduler-add-to-report task-info current-time)
              (setq tasks-scheduled (1+ tasks-scheduled)) 
              (when (zerop (mod tasks-scheduled 10))
                (org-auto-scheduler--log-info "Scheduled %d/%d tasks..." tasks-scheduled total-tasks))))
          
          (org-auto-scheduler-display-report)
          (org-auto-scheduler--log-info "Scheduled %d tasks" tasks-scheduled)
          (when org-auto-scheduler-sync-caldav
            ;; Save all org agenda buffers before syncing with CalDAV
            (org-auto-scheduler--log-info "Saving all org agenda buffers before CalDAV sync")
            (save-some-buffers t (lambda () 
                                   (and (buffer-file-name)
                                        (member (buffer-file-name) (org-agenda-files t)))))
            (org-caldav-sync))))
    (error  
     (org-auto-scheduler--log-error "Error in scheduling process: %s" err))))

(defun org-auto-scheduler-get-schedulable-tasks ()
  "Get a list of markers for schedulable tasks from the agenda files, including recurring task instances."
  (let ((tasks '())
        (valid-states (mapcar #'car org-auto-scheduler-state-weights)))
    (org-map-entries
     (lambda ()
       (let* ((state (org-get-todo-state))
              (tags (org-get-tags))
              (is-autosch (member "AUTOSCH" tags))
              (is-valid-state (member state valid-states))
              (headline (org-get-heading t t t t))
              (not-before (org-entry-get nil "NOT_BEFORE"))
              (recurring (org-entry-get nil "RECURRING"))
              (scheduled (org-entry-get nil "SCHEDULED"))
              (file (buffer-file-name)))
         ;; Check if the task is not in an archived state by checking tags
         (when (and is-autosch is-valid-state (not (member "ARCHIVE" tags)))
           (if recurring
               (progn
                 (org-auto-scheduler--log-debug "Creating instances for recurring task: %s in file %s" headline file)
                 (org-auto-scheduler-create-recurring-instances headline recurring scheduled not-before tasks))
             (org-auto-scheduler--log-debug "Adding non-recurring task: %s from file %s" headline file)
             (push (point-marker) tasks)))
         (org-auto-scheduler--log-debug "Found schedulable task: %s (State: %s, NOT_BEFORE: %s, RECURRING: %s) in file %s"
                                        headline state (or not-before "Not set") (or recurring "Not set") file)))
     nil
     'agenda)
    (org-auto-scheduler--log-info "Found %d schedulable tasks across the agenda" (length tasks))
    (nreverse tasks)))

(defun org-auto-scheduler-create-recurring-instances (headline recurring scheduled not-before tasks)
  "Create recurring instances for a task and add them to TASKS list."
  (let* ((start-date (if scheduled
                         (org-time-string-to-time scheduled)
                       (current-time)))
         (end-date (time-add (current-time) (days-to-time org-auto-scheduler-recurring-look-days-ahead)))
         (current-date start-date)
         (last-instance-date nil))
    (while (time-less-p current-date end-date)
      (let* ((date-string (format-time-string "%Y-%m-%d" current-date))
             (instance-headline (format "%s - %s" headline date-string))
             (existing-instance (org-auto-scheduler-find-existing-instance instance-headline)))
        (unless existing-instance
          (let ((new-task (org-auto-scheduler-create-subtask instance-headline current-date)))
            (push new-task tasks)))
        (setq current-date (org-auto-scheduler-next-recurring-date current-date recurring))
        (setq last-instance-date current-date)))
    ;; Update the SCHEDULED property of the main task
    (when last-instance-date
      (org-set-property "SCHEDULED" (format-time-string "<%Y-%m-%d %a>" last-instance-date)))))

(defun org-auto-scheduler-create-subtask (headline date)
  "Create a new subtask with HEADLINE and DATE as NOT_BEFORE property."
  (save-excursion
    (org-back-to-heading t)  ; Move to the parent heading
    (let ((parent-state (org-get-todo-state)))
      (org-insert-heading-respect-content)  ; Insert a new heading after the current heading
            (org-do-demote)  ; Demote the new heading to make it a child of the parent heading
            (insert headline)  ; Insert the headline text
            (when parent-state
              (org-todo parent-state))  ; Set the TODO state
            (org-set-tags-to '("AUTOSCH"))  ; Set the tags
            (org-set-property "NOT_BEFORE" (format-time-string "[%Y-%m-%d %a]" date))  
            (point-marker))))  ; Return the point marker

(defun org-auto-scheduler-find-existing-instance (headline)
  "Find an existing instance of a recurring task with HEADLINE."
  (save-excursion
    (org-back-to-heading t)
    (let ((end (save-excursion (org-end-of-subtree t t))))
      (re-search-forward (regexp-quote headline) end t))))

(defun org-auto-scheduler-next-recurring-date (date recurring)
  "Calculate the next date based on the RECURRING frequency."
  (pcase recurring
    ("daily" (time-add date (days-to-time 1)))
    ("weekly" (time-add date (days-to-time 7)))
    ("bi-weekly" (time-add date (days-to-time 14)))
    ("monthly" (org-auto-scheduler-add-months date 1))
    (_ date))) ; Default case, return the same date

(defun org-auto-scheduler-add-months (time months)
  "Add MONTHS to TIME, handling end of month and leap year cases."
  (let* ((decoded (decode-time time))
         (month (nth 4 decoded))
         (year (nth 5 decoded))
         (day (nth 3 decoded))
         (last-day-of-month
          (calendar-last-day-of-month month year)))
    (setf (nth 4 decoded) (+ month months))
    (when (> (nth 4 decoded) 12)
      (setf (nth 5 decoded) (1+ year))
      (setf (nth 4 decoded) (- (nth 4 decoded) 12)))
    (setf (nth 3 decoded) (min day (calendar-last-day-of-month (nth 4 decoded) (nth 5 decoded))))
    (apply #'encode-time decoded)))

(defun org-auto-scheduler-create-report-buffer ()
  "Create or clear the report buffer."
  (let ((buffer (get-buffer-create org-auto-scheduler-report-buffer-name)))
    (with-current-buffer buffer
      (erase-buffer)
      (org-mode)
      (insert "#+TITLE: Org Auto Scheduler Report\n")
      (insert "#+DATE: " (format-time-string "%Y-%m-%d %H:%M:%S") "\n\n")
      (insert "| Task | Score | Scheduled | Not Before | Time Block | Effort | Project | Effort Score | Priority Score | Urgency Score | Category Score | State |\n")
      (insert "|------|-------|-----------|------------|------------|--------|---------|--------------|----------------|---------------|---------------|-------|\n"))
    buffer))



(defun org-auto-scheduler-add-to-report (task scheduled)
  "Add a task to the report buffer.
TASK is the task info list, SCHEDULED is the scheduled timestamp."
  (let ((buffer (get-buffer org-auto-scheduler-report-buffer-name)))
    (when buffer
      (with-current-buffer buffer
        (goto-char (point-max))
        (let* ((score-components (nth 13 task))
               (effort-score (nth 0 score-components))
               (priority-score (nth 1 score-components))
               (urgency-score (nth 2 score-components))
               (category-score (nth 3 score-components))
               (state-weight (nth 4 score-components))
               (state (nth 11 score-components))
               (score (nth 1 task)))
          (insert "| " 
                (nth 6 task) " | " ; Task name
                (format "%.2f" score) " | " ; Score
                (or (and scheduled 
                     (format-time-string "%Y-%m-%d %H:%M" scheduled)) 
                    "Not scheduled") " | "
                (or (and (nth 10 task) 
                     (format-time-string "%Y-%m-%d %H:%M" (nth 10 task)))
                    "None") " | "
                (if (nth 11 task)
                    (format "%s" (nth 11 task))
                  "None") " | "
                (or (and (nth 12 task) 
                     (format "%d" (nth 12 task)))
                    "60") " | "
                (or (nth 2 task) "None") " | "
                (format "%.2f" effort-score) " | "
                (format "%.2f" priority-score) " | "
                (format "%.2f" urgency-score) " | "
                (format "%.2f" category-score) " | "
                (or state "None") " |\n"))))))    

(defun org-auto-scheduler-schedule-single-task (marker current-time)
  "Schedule a single task at MARKER, starting from CURRENT-TIME.
This function attempts to find an available time slot for the task,
respecting time blocks if specified, and avoiding conflicts with
existing scheduled tasks. If no available time slot is found within
the time block, it schedules the task outside the time block."
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
                                 (org-auto-scheduler-next-available-time-in-block start-time time-block remaining-effort)
                               start-time))
             (end-time nil)
             (attempts 0)
             (max-attempts (* 7 24 60)) ; 7 days in minutes
             (is-currently-clocked (org-clock-is-active)))
        (org-auto-scheduler--log-debug "[org-auto-scheduler-schedule-single-task] Task: %s" headline)
        (org-auto-scheduler--log-debug "[org-auto-scheduler-schedule-single-task] Total effort: %d minutes, Clocked time: %d minutes, Remaining effort: %d minutes, Time block: %s, Currently clocked: %s, Not before: %s"
                                       total-effort clocked-time remaining-effort time-block is-currently-clocked
                                       (if not-before (format-time-string "%Y-%m-%d %H:%M" not-before) "Not set"))
        (when (and time-block (null available-time))
          ;; Log that no available time slot was found
          (org-auto-scheduler--log-debug "[org-auto-scheduler-schedule-single-task] No available time slot found within the time block. Scheduling outside the time block.")
          ;; Reset time block since no available time was found
          (setq time-block nil)
          ;; Log task information
          (org-auto-scheduler--log-debug "[org-auto-scheduler-schedule-single-task] outside time block Task: %s" headline)
          (org-auto-scheduler--log-debug "[org-auto-scheduler-schedule-single-task] Total effort: %d minutes, Clocked time: %d minutes, Remaining effort: %d minutes, Time block: %s, Currently clocked: %s, Not before: %s"
                                       total-effort clocked-time remaining-effort time-block is-currently-clocked
                                       (if not-before (format-time-string "%Y-%m-%d %H:%M" not-before) "Not set"))
          (setq available-time start-time))
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
                                          (org-auto-scheduler-next-available-time-in-block occupied-result time-block remaining-effort)
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
  (let* ((tags (org-get-tags marker))
         (matching-block nil))
    (dolist (tag-block org-auto-scheduler-time-blocks)
      (when (and (not matching-block)
                 (member (car tag-block) tags))
        (setq matching-block (cdr tag-block))))
    matching-block))

(defun org-auto-scheduler-time-fits-block-p (block-start block-end remaining-effort)
  "Check if the task with REMAINING-EFFORT fits within the time block from BLOCK-START to BLOCK-END."
  (let ((block-duration (time-to-seconds (time-subtract block-end block-start))))
        (>= (/ block-duration 60) remaining-effort)))

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
  (let* ((start-time (org-duration-to-minutes org-auto-scheduler-start-time))
         (end-time (org-duration-to-minutes org-auto-scheduler-end-time))
         (time-interval org-auto-scheduler-time-interval)
         (task-gap org-auto-scheduler-task-gap)
         (max-days-to-check org-auto-scheduler-max-days-to-check)
         (excluded-days org-auto-scheduler-excluded-days))
    (when (>= start-time end-time)
      (error "org-auto-scheduler-start-time must be earlier than org-auto-scheduler-end-time"))
    (when (< time-interval 1)
      (error "org-auto-scheduler-time-interval must be at least 1 minute"))
    (when (< task-gap 0)
      (error "org-auto-scheduler-task-gap cannot be negative"))
    (when (< max-days-to-check 1)
      (error "org-auto-scheduler-max-days-to-check must be at least 1"))
    (dolist (day excluded-days)
      (unless (and (integerp day) (<= 0 day 6))
        (error "org-auto-scheduler-excluded-days must contain integers from 0 to 6")))))

(defun org-auto-scheduler-get-not-before (marker)
  "Get the NOT_BEFORE property for the task at MARKER."
      (let ((not-before-string (org-entry-get marker "NOT_BEFORE")))
        (when not-before-string
      (org-time-string-to-time not-before-string))))

(defun org-auto-scheduler-has-repeater-task (marker)
  "Check if the task at MARKER has a repeater interval.
Returns t if the task has a scheduled time with repeater (+, ++, or .+)."
  (when marker
    (let ((scheduled-string (org-entry-get marker "SCHEDULED")))
      (and scheduled-string 
           (string-match "\\([.+]*\\+\\+?\\)\\([0-9]+\\)\\([dwmy]\\)" scheduled-string)))))

(defun org-auto-scheduler-parse-repeater-interval (scheduled-string)
  "Parse the repeater interval from a SCHEDULED string.
Supports formats like:
  '<2024-01-01 Mon 09:00 +1d>'
  '<2024-01-01 Mon 09:00 ++1w>'
  '<2024-01-01 Mon 09:00 .+1m>'
  '<2025-08-16 Sat 15:54-17:24 ++1d>'
Returns a list (repeater-type interval-number interval-unit) where:
  - repeater-type is '+', '++', or '.+'
  - interval-number is the numeric part
  - interval-unit is 'd', 'w', 'm', or 'y'"
  (when (and scheduled-string 
             (string-match "\\([.+]*\\+\\+?\\)\\([0-9]+\\)\\([dwmy]\\)" scheduled-string))
    (list (match-string 1 scheduled-string)
          (string-to-number (match-string 2 scheduled-string))
          (match-string 3 scheduled-string))))

(defun org-auto-scheduler-parse-scheduled-time-range (scheduled-string)
  "Parse scheduled string to extract start time, end time, and repeater info.
Supports formats like:
  '<2024-01-01 Mon 09:00 +1d>' -> (start-time nil repeater-info)
  '<2025-08-16 Sat 15:54-17:24 ++1d>' -> (start-time end-time repeater-info)
  '<2024-01-01 Mon 09:00>--<2024-01-01 Mon 10:00>' -> (start-time end-time nil)
Returns a list (start-time end-time repeater-info) where repeater-info is from parse-repeater-interval."
  (when scheduled-string
    (cond
     ;; Format with explicit end time and repeater: <2025-08-16 Sat 15:54-17:24 ++1d>
     ((string-match "<\\([0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\} [A-Za-z]+ [0-9]\\{2\\}:[0-9]\\{2\\}\\)-\\([0-9]\\{2\\}:[0-9]\\{2\\}\\)\\([^>]*\\)>" scheduled-string)
      (let* ((start-part (match-string 1 scheduled-string))
             (end-time-part (match-string 2 scheduled-string))
             (repeater-part (match-string 3 scheduled-string))
             (start-time (org-time-string-to-time start-part))
             (full-end-time-str (concat (substring start-part 0 11) end-time-part))
             (end-time (org-time-string-to-time full-end-time-str))
             (repeater-info (when (string-match "\\([.+]*\\+\\+?\\)\\([0-9]+\\)\\([dwmy]\\)" repeater-part)
                            (list (match-string 1 repeater-part)
                                  (string-to-number (match-string 2 repeater-part))
                                  (match-string 3 repeater-part)))))
        (list start-time end-time repeater-info)))
     
     ;; Format with range and repeater: <2023-05-01 Mon 09:00>--<2023-05-01 Mon 10:00> +1d
     ((string-match "\\(<[^>]+>\\)--\\(<[^>]+>\\)\\s*\\([.+]*\\+\\+?[0-9]+[dwmy]\\)?" scheduled-string)
      (let* ((start-time (org-time-string-to-time (match-string 1 scheduled-string)))
             (end-time (org-time-string-to-time (match-string 2 scheduled-string)))
             (repeater-part (match-string 3 scheduled-string))
             (repeater-info (when repeater-part
                            (org-auto-scheduler-parse-repeater-interval repeater-part))))
        (list start-time end-time repeater-info)))
     
     ;; Standard format with repeater: <2024-01-01 Mon 09:00 +1d>
     (t 
      (let* ((start-time (org-time-string-to-time scheduled-string))
             (repeater-info (org-auto-scheduler-parse-repeater-interval scheduled-string)))
        (list start-time nil repeater-info))))))

(defun org-auto-scheduler-calculate-next-repeater-occurrence (base-time interval-info)
  "Calculate the next occurrence of a repeater task from BASE-TIME using INTERVAL-INFO.
INTERVAL-INFO is a list (repeater-type number unit) where:
  - repeater-type is '+', '++', or '.+'
  - number is the interval number
  - unit is 'd', 'w', 'm', or 'y'
For '+' type: simple repetition from the base time
For '++' type: catch-up repetition (same as + for future projections)  
For '.+' type: restart from completion time (same as + for future projections)"
  (when interval-info
    (let ((repeater-type (car interval-info))
          (number (cadr interval-info))
          (unit (caddr interval-info)))
      ;; For projection purposes, all repeater types work the same way
      ;; The difference is in how they behave when marked done, which doesn't affect projection
      (cond
       ((string= unit "d") (time-add base-time (days-to-time number)))
       ((string= unit "w") (time-add base-time (days-to-time (* number 7))))
       ((string= unit "m") (org-auto-scheduler-add-months base-time number))
       ((string= unit "y") (org-auto-scheduler-add-months base-time (* number 12)))
       (t base-time)))))

(defun org-auto-scheduler-get-repeater-task-info (marker)
  "Get repeater task information from MARKER.
Returns a list (start-time end-time repeater-info effort) or nil if not a repeater task."
  (when (org-auto-scheduler-has-repeater-task marker)
    (let* ((scheduled-string (org-entry-get marker "SCHEDULED"))
           (time-range-info (when scheduled-string (org-auto-scheduler-parse-scheduled-time-range scheduled-string)))
           (start-time (car time-range-info))
           (end-time (cadr time-range-info))
           (repeater-info (caddr time-range-info))
           (effort (or (org-auto-scheduler-get-effort marker) 60)))
      (when (and start-time repeater-info)
        ;; If no explicit end time, calculate from effort
        (let ((calculated-end-time (or end-time 
                                     (time-add start-time (seconds-to-time (* effort 60))))))
          (list start-time calculated-end-time repeater-info effort))))))

(defun org-auto-scheduler-project-repeater-occurrences (marker end-date)
  "Project all occurrences of a repeater task at MARKER up to END-DATE.
Returns a list of agenda items compatible with org-auto-scheduler-get-agenda-items format."
  (let ((repeater-info (org-auto-scheduler-get-repeater-task-info marker)))
    (when repeater-info
      (let* ((start-time (car repeater-info))
             (task-end-time (cadr repeater-info))
             (interval-info (caddr repeater-info))
             (effort (cadddr repeater-info))
             (task-id (org-with-point-at marker (or (org-id-get) (org-id-get-create))))
             (task-name (org-with-point-at marker (org-get-heading t t t t)))
             (tags (org-with-point-at marker (org-get-tags)))
             (current-start-time start-time)
             (occurrences '()))
        ;; Project occurrences starting from the base time
        (while (time-less-p current-start-time end-date)
          (let* ((current-end-time (time-add current-start-time 
                                           (time-subtract task-end-time start-time)))
                 (agenda-item (list task-id current-start-time current-end-time tags t task-name)))
            (push agenda-item occurrences)
            (setq current-start-time (org-auto-scheduler-calculate-next-repeater-occurrence current-start-time interval-info))))
        (nreverse occurrences)))))

(defun org-auto-scheduler-get-all-repeater-projections (end-date)
  "Get all projected repeater task occurrences up to END-DATE.
Returns a list of agenda items for all repeater tasks found in agenda files.
Uses caching to improve performance when called multiple times with same end-date."
  (when org-auto-scheduler-repeater-integration
    ;; Check if we have a valid cached result
    (let* ((cache-key (format-time-string "%Y-%m-%d" end-date))
           (cached-result (assoc cache-key org-auto-scheduler--repeater-projections-cache))
           (cache-expired (or (null org-auto-scheduler--repeater-cache-valid-until)
                            (time-less-p org-auto-scheduler--repeater-cache-valid-until (current-time)))))
      
      (if (and cached-result (not cache-expired))
          ;; Return cached result
          (progn
            (org-auto-scheduler--log-debug "Using cached repeater projections for %s" cache-key)
            (cdr cached-result))
        ;; Generate new projections
        (org-auto-scheduler--log-debug "Generating new repeater projections for %s" cache-key)
        (let ((repeater-occurrences '()))
          (org-map-entries
           (lambda ()
             (when (org-auto-scheduler-has-repeater-task (point-marker))
               (let ((projections (org-auto-scheduler-project-repeater-occurrences (point-marker) end-date)))
                 (setq repeater-occurrences (append repeater-occurrences projections)))))
           nil
           'agenda)
          
          ;; Cache the result (cache expires in 10 minutes)
          (setq org-auto-scheduler--repeater-cache-valid-until 
                (time-add (current-time) (seconds-to-time 600)))
          (setq org-auto-scheduler--repeater-projections-cache
                (cons (cons cache-key repeater-occurrences)
                      (cl-remove-if (lambda (item) (string= (car item) cache-key))
                                    org-auto-scheduler--repeater-projections-cache)))
          
          repeater-occurrences)))))

(defun org-auto-scheduler-clear-repeater-cache ()
  "Clear the repeater projections cache.
This is useful when repeater tasks have been modified and you want
to ensure fresh projections are generated."
  (interactive)
  (setq org-auto-scheduler--repeater-projections-cache nil)
  (setq org-auto-scheduler--repeater-cache-valid-until nil)
  (org-auto-scheduler--log-info "Cleared repeater projections cache")
  (when (called-interactively-p 'interactive)
    (message "Repeater projections cache cleared")))

;; Keep old function names for backward compatibility
(defalias 'org-auto-scheduler-clear-habit-cache 'org-auto-scheduler-clear-repeater-cache)

(defun org-auto-scheduler-show-repeater-projections ()
  "Show projected repeater occurrences for debugging purposes."
  (interactive)
  (let* ((look-ahead-days (or org-auto-scheduler-repeater-look-days-ahead
                            (max org-auto-scheduler-max-days-to-check
                                 org-auto-scheduler-recurring-look-days-ahead)))
         (end-date (time-add (current-time) (days-to-time look-ahead-days)))
         (projections (org-auto-scheduler-get-all-repeater-projections end-date)))
    (with-output-to-temp-buffer "*Repeater Projections*"
      (princ (format "Repeater projections for the next %d days:\n\n" look-ahead-days))
      (if projections
          (dolist (projection projections)
            (princ (format "- %s: %s to %s\n"
                           (nth 5 projection) ; task name
                           (format-time-string "%Y-%m-%d %H:%M" (nth 1 projection)) ; start
                           (format-time-string "%H:%M" (nth 2 projection))))) ; end
        (princ "No repeater tasks found or repeater integration is disabled.\n"))
      (princ (format "\nRepeater integration enabled: %s\n" org-auto-scheduler-repeater-integration))
      (princ (format "Look-ahead days: %d\n" look-ahead-days)))))

;; Keep old function name for backward compatibility
(defalias 'org-auto-scheduler-show-habit-projections 'org-auto-scheduler-show-repeater-projections)


;; Call this function when the package is loaded
(org-auto-scheduler-validate-config)


(defun org-auto-scheduler-display-report ()
  "Format and display the scheduler report."
  (when (not org-auto-scheduler-silent-mode)
    (let ((buffer (get-buffer org-auto-scheduler-report-buffer-name)))
      (when buffer
        (with-current-buffer buffer
          (goto-char (point-max))
            (insert "\n\n* Summary\n")
            (insert (format "- Total tasks scheduled: %d\n" 
                            (length org-auto-scheduler-completed-tasks)))
            ;; Final alignment of the entire table
            (goto-char (point-min))
            (search-forward "|" nil t)
            (beginning-of-line)
            (org-table-align))
          (pop-to-buffer buffer)))))

(defun org-auto-scheduler-background-run ()
  "Run the scheduler silently in the background."
  (interactive)
  (when (and org-auto-scheduler-background-enabled
             (org-auto-scheduler-allowed-on-this-computer-p)
             (not org-auto-scheduler--background-running)
             (not (minibufferp))
             (not (and (boundp 'org-clock-current-task) org-clock-current-task)))
    (setq org-auto-scheduler--background-running t)
    (org-auto-scheduler--log-info "Starting background auto-scheduler run...")
    (condition-case err
        (let ((org-auto-scheduler-silent-mode t))
          ;; Run scheduler in silent mode
          (org-auto-scheduler-schedule-tasks))
      (error 
       (org-auto-scheduler--log-error "Error in background scheduler: %s" err)))
    (org-auto-scheduler--log-info "Background auto-scheduler run completed.")
    (setq org-auto-scheduler--background-running nil)))

(defun org-auto-scheduler-allowed-on-this-computer-p ()
  "Check if background scheduling is allowed on this computer.
Returns t if org-auto-scheduler-allowed-hostnames is nil or
if the current system's hostname is in the list."
  (or (null org-auto-scheduler-allowed-hostnames)
      (member (system-name) org-auto-scheduler-allowed-hostnames)))

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
                               org-auto-scheduler-background-enabled)
  
  ;; Cancel existing timer if present
  (when org-auto-scheduler--idle-timer
    (org-auto-scheduler--log-debug "Canceling existing background timer")
    (cancel-timer org-auto-scheduler--idle-timer)
    (setq org-auto-scheduler--idle-timer nil))
  
  ;; Create new timer if enabled
  (when org-auto-scheduler-background-enabled
    (org-auto-scheduler--log-info "Creating new background timer. Idle time: %d seconds, Interval: %d seconds"
                                 org-auto-scheduler-idle-time
                                 org-auto-scheduler-background-interval)
    (setq org-auto-scheduler--idle-timer
          (run-with-idle-timer 
           org-auto-scheduler-idle-time
           org-auto-scheduler-background-interval
           #'org-auto-scheduler-background-run))
    (add-hook 'kill-emacs-hook #'org-auto-scheduler-cleanup-background)))

;; Ensure background scheduler is set up when Emacs is running in daemon mode
(add-hook 'emacs-startup-hook 'org-auto-scheduler-setup-background)

(defun org-auto-scheduler-cleanup-background ()
  "Clean up background scheduler resources when Emacs is shutting down."
  (when org-auto-scheduler--idle-timer
    (cancel-timer org-auto-scheduler--idle-timer)
    (setq org-auto-scheduler--idle-timer nil))
  (setq org-auto-scheduler--background-running nil))

(provide 'org-auto-scheduler)
