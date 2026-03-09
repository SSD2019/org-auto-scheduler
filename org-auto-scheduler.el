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

(defcustom org-auto-scheduler-hard-deadline-days 1
  "Number of days before a deadline when a task gets a massive priority boost."
  :type 'integer
  :group 'org-auto-scheduler)

(defcustom org-auto-scheduler-hard-deadline-boost 10000
  "The score boost applied to tasks that are at or past their hard deadline."
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

(defcustom org-auto-scheduler-energy-blocks
  '(("@HighEnergy" . (("09:00" . "12:00")))
    ("@LowEnergy" . (("14:00" . "17:00"))))
  "Preferred time blocks based on energy tags.
Similar to `org-auto-scheduler-time-blocks`, but tailored for context or energy
level scheduling. Acts as a soft constraint (preferences)."
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

(defvar org-auto-scheduler--preview-mode nil
  "When non-nil, task schedules are only calculated and saved, not applied to the Org buffer.")

(defvar org-auto-scheduler--custom-order nil
  "List of task markers specifying an explicit schedule priority override.")

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

(defcustom org-auto-scheduler-enable-historical-tracking t
  "When non-nil, automatically update historical effort multipliers when tasks are completed."
  :type 'boolean
  :group 'org-auto-scheduler)

(defcustom org-auto-scheduler-apply-historical-multipliers t
  "When non-nil, use historical multipliers to automatically adjust task estimates
during scheduling. If nil, estimates are strictly based on explicit task properties,
but tracking (if enabled) continues silently in the background."
  :type 'boolean
  :group 'org-auto-scheduler)

(defvar org-auto-scheduler-historical-multipliers nil
  "Alist mapping categories/tags to historical effort inflation multipliers.
Updated automatically when tasks are marked DONE if tracking is enabled.
Multipliers are exponential moving averages of clocked time vs estimated effort.")

(defcustom org-auto-scheduler-history-file (expand-file-name "org-auto-scheduler-history.el" user-emacs-directory)
  "File to save `org-auto-scheduler-historical-multipliers` across sessions.
Defaults to `org-auto-scheduler-history.el` inside your Emacs directory."
  :type 'string
  :group 'org-auto-scheduler)

(defun org-auto-scheduler-save-history ()
  "Save historical tracking data to `org-auto-scheduler-history-file`."
  (when org-auto-scheduler-enable-historical-tracking
    (with-temp-file org-auto-scheduler-history-file
      (let ((print-length nil)
            (print-level nil))
        (insert ";; Auto-generated by org-auto-scheduler\n")
        (insert (format "(setq org-auto-scheduler-historical-multipliers '%S)\n" 
                        org-auto-scheduler-historical-multipliers))))))

(defun org-auto-scheduler-load-history ()
  "Load historical tracking data from `org-auto-scheduler-history-file`."
  (when (file-exists-p org-auto-scheduler-history-file)
    (load org-auto-scheduler-history-file t t t)))

;; Auto-save history when Emacs closes, and load when plugin loads
(add-hook 'kill-emacs-hook #'org-auto-scheduler-save-history)
(org-auto-scheduler-load-history)

;;; Adherence Tracking
(defcustom org-auto-scheduler-adherence-file (expand-file-name "org-auto-scheduler-adherence.el" user-emacs-directory)
  "File to save schedule adherence snapshots and history."
  :type 'string
  :group 'org-auto-scheduler)

(defvar org-auto-scheduler--adherence-history nil
  "Alist mapping date strings (YYY-MM-DD) to daily adherence data.
Format: ((date . ((:score . 85.5) (:streak . 3) (:details . ...))))")

(defvar org-auto-scheduler--adherence-snapshots nil
  "Alist mapping date strings to the list of tasks planned for that day.
Each task is stored as a plist: (:id ID :file FILE :pos POS :heading HEADING :effort EFFORT :category CATEGORY :tags TAGS :scheduled TIME)")

(defun org-auto-scheduler-save-adherence ()
  "Save adherence data to `org-auto-scheduler-adherence-file`.
Prunes snapshots older than 30 days to prevent excessive file growth."
  (let* ((cutoff-time (time-subtract (current-time) (days-to-time 30)))
         (cutoff-date-str (format-time-string "%Y-%m-%d" cutoff-time)))
    ;; Filter out snapshots older than 30 days
    (setq org-auto-scheduler--adherence-snapshots
          (cl-remove-if (lambda (entry)
                          (string< (car entry) cutoff-date-str))
                        org-auto-scheduler--adherence-snapshots)))
  (with-temp-file org-auto-scheduler-adherence-file
    (let ((print-length nil)
          (print-level nil))
      (insert ";; Auto-generated by org-auto-scheduler\n")
      (insert (format "(setq org-auto-scheduler--adherence-history '%S)\n" 
                      org-auto-scheduler--adherence-history))
      (insert (format "(setq org-auto-scheduler--adherence-snapshots '%S)\n" 
                      org-auto-scheduler--adherence-snapshots)))))

(defun org-auto-scheduler-load-adherence ()
  "Load adherence data from `org-auto-scheduler-adherence-file`."
  (when (file-exists-p org-auto-scheduler-adherence-file)
    (load org-auto-scheduler-adherence-file t t t)))

(add-hook 'kill-emacs-hook #'org-auto-scheduler-save-adherence)
(org-auto-scheduler-load-adherence)

(defun org-auto-scheduler-track-historical-effort ()
  "Hook function to track historical effort when a task is marked DONE."
  (when (and org-auto-scheduler-enable-historical-tracking
             (boundp 'org-state)
             (string= org-state "DONE"))
    (let ((effort (org-auto-scheduler-get-effort (point-marker)))
          (clocked-time (org-auto-scheduler-get-clocked-time (point-marker)))
          (category (org-get-category))
          (updated nil))
      (when (and effort clocked-time category (> effort 0) (> clocked-time 0))
        (let* ((ratio (/ (float clocked-time) (float effort)))
               (existing (assoc category org-auto-scheduler-historical-multipliers)))
          (setq updated t)
          (if existing
              (setcdr existing (+ (* 0.8 (cdr existing)) (* 0.2 ratio)))
            (push (cons category ratio) org-auto-scheduler-historical-multipliers))
          ;; Auto-save immediately upon update to prevent data loss
          (when updated
            (org-auto-scheduler-save-history)))))))

(add-hook 'org-after-todo-state-change-hook #'org-auto-scheduler-track-historical-effort)

(defun org-auto-scheduler-get-effort-multiplier (marker)
  "Get the historical effort multiplier for the task at MARKER.
Returns 1.0 if `org-auto-scheduler-apply-historical-multipliers' is nil."
  (if (not org-auto-scheduler-apply-historical-multipliers)
      1.0
    (let* ((category (org-with-point-at marker (org-get-category)))
           (existing (assoc category org-auto-scheduler-historical-multipliers)))
      (if existing
          (cdr existing)
        1.0))))

(defun org-auto-scheduler-get-blockers (marker)
  "Get a list of markers for tasks that block the task at MARKER.
Returns a list of markers for tasks specified in BLOCKER or DEPENDS_ON that are not DONE."
  (condition-case err
      (let ((blockers (org-entry-get marker "BLOCKER"))
            (depends (org-entry-get marker "DEPENDS_ON")))
        (let* ((all-blockers (concat (or blockers "") " " (or depends "")))
               (blocker-ids (split-string all-blockers "[ \t\n\r]+" t))
               (active-blockers nil))
          (dolist (id blocker-ids)
            (let ((b-marker (org-id-find id t)))
              (when b-marker
                (org-with-point-at b-marker
                  (unless (member (org-get-todo-state) org-done-keywords)
                    (push b-marker active-blockers))))))
          active-blockers))
    (error
     (org-auto-scheduler--log-error "Error checking blockers for task: %s" err)
     nil)))

(defun org-auto-scheduler-task-blocked-p (marker)
  "Check if task at MARKER is blocked by incomplete tasks.
Returns t if a BLOCKER or DEPENDS_ON task is not DONE."
  (not (null (org-auto-scheduler-get-blockers marker))))

(defun org-auto-scheduler-get-dependency-depth (marker &optional visited)
  "Calculate the dependency depth of the task at MARKER.
0 means no blockers. 1 means it has blockers, but those blockers have no blockers, etc.
VISITED is an internal list to prevent infinite loops from circular dependencies."
  (if (member marker visited)
      0 ; Circular dependency detected, break cycle
    (let ((blockers (org-auto-scheduler-get-blockers marker)))
      (if (null blockers)
          0
        (1+ (apply #'max 
                   (mapcar (lambda (b) 
                             (org-auto-scheduler-get-dependency-depth b (cons marker visited)))
                           blockers)))))))

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

(defvar org-auto-scheduler--agenda-cache nil
  "Cache for agenda items during a scheduling run.
Hash table with date strings as keys and lists of items as values.")

(defun org-auto-scheduler--build-agenda-cache ()
  "Scan all agenda files once and build a cache of agenda items per date."
  (setq org-auto-scheduler--agenda-cache (make-hash-table :test 'equal))
  (org-map-entries
   (lambda ()
     (let* ((task-name (org-get-heading t t t t))
            (tags (org-get-tags))
            (has-repeater (org-auto-scheduler-has-repeater-task (point-marker))))
       (unless (or (member "AUTOSCH" tags)
                   (member "ARCHIVE" tags)
                   has-repeater)
         (let ((task-id nil)
               (task-end-time nil))
           (dolist (prop '("SCHEDULED" "TIMESTAMP"))
             (let ((time-str (org-entry-get nil prop)))
               (when time-str
                 (let ((time-val (org-time-string-to-time time-str)))
                   (unless task-id (setq task-id (org-id-get)))
                   (unless task-end-time (setq task-end-time (org-auto-scheduler-calculate-task-end-time (point))))
                   (let* ((date-string (format-time-string "%Y-%m-%d" time-val))
                          (item (list task-id time-val task-end-time tags t task-name))
                          (existing (gethash date-string org-auto-scheduler--agenda-cache)))
                     (puthash date-string (cons item existing) org-auto-scheduler--agenda-cache))))))))))
   nil 'agenda)
  (org-auto-scheduler--log-info "Built agenda cache with %d days." (hash-table-count org-auto-scheduler--agenda-cache)))

(defun org-auto-scheduler--fetch-base-agenda-items-for-date (date-string)
  "Fallback method to fetch native agenda items for DATE-STRING."
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
              ;; Exclude AUTOSCH tags, ARCHIVE tags, and repeater tasks (repeaters are handled separately)
              (when (and scheduled-time 
                         (not (member "AUTOSCH" tags))
                         (not (member "ARCHIVE" tags))
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
              ;; Exclude AUTOSCH tags, ARCHIVE tags, and repeater tasks
              (when (and scheduled-time 
                         (not (member "AUTOSCH" tags))
                         (not (member "ARCHIVE" tags))
                         (not has-repeater))
                (let* ((scheduled-date (format-time-string "%Y-%m-%d" scheduled-time))
                       (task-end-time (org-auto-scheduler-calculate-task-end-time (point))))
                  (when (string= scheduled-date date-string)
                    (list task-id scheduled-time task-end-time tags t task-name))))))
          nil
          'agenda))))

(defun org-auto-scheduler-get-agenda-items (date)
  "Get agenda items for DATE.  Includes tasks with active timestamps and projected habit occurrences."
  (condition-case err
      (let* ((date-string (format-time-string "%Y-%m-%d" date))
             (agenda-items
              (if (and (boundp 'org-auto-scheduler--agenda-cache)
                       (hash-table-p org-auto-scheduler--agenda-cache))
                  (copy-sequence (gethash date-string org-auto-scheduler--agenda-cache))
                (org-auto-scheduler--fetch-base-agenda-items-for-date date-string))))
        
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
      (let* ((base-effort (or (org-auto-scheduler-get-effort marker) 60))
             (multiplier (org-auto-scheduler-get-effort-multiplier marker))
             (effort (round (* base-effort multiplier)))
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
             (hard-deadline-score (if (and deadline (<= days-to-deadline org-auto-scheduler-hard-deadline-days))
                                      org-auto-scheduler-hard-deadline-boost 0))
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
                            state-weight
                            hard-deadline-score)))
        (org-auto-scheduler--log-debug "Calculating score for task %s"
                                       (org-with-point-at marker (or (org-id-get) "NO-ID")))
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
  "Get the ID of the nearest ancestor (including self) with a :PROJECT: tag for the task at MARKER."
  (save-excursion
    (with-current-buffer (marker-buffer marker)
      (goto-char (marker-position marker))
      (let ((project-id nil))
        (catch 'found
          ;; 1. Check current heading first
          (when (member "PROJECT" (org-get-tags nil t))
            (setq project-id (org-id-get))
            (when project-id (throw 'found project-id)))
          ;; 2. Traverse upwards
          (while (org-up-heading-safe)
            (when (member "PROJECT" (org-get-tags nil t))
              (setq project-id (org-id-get))
              (when project-id (throw 'found project-id)))))
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

(defun org-auto-scheduler--complex-sort-predicate (a b project-max-scores)
  "Return t if task A has higher priority than task B based on complex scheduling rules."
  (let* ((project-priority-a (nth 3 a))
         (project-priority-b (nth 3 b))
         (project-a (nth 2 a))
         (project-b (nth 2 b))
         (score-a (nth 1 a))
         (score-b (nth 1 b))
         (allows-interleave-a (nth 9 a))
         (allows-interleave-b (nth 9 b))
          (max-score-a (if project-a (gethash project-a project-max-scores) -999999.0))
          (max-score-b (if project-b (gethash project-b project-max-scores) -999999.0)))
    (cond
     ;; 1. Explicit project priority
     ((not (= project-priority-a project-priority-b))
      (> project-priority-a project-priority-b))
      
     ;; 2. Different projects
     ((and project-a project-b (not (equal project-a project-b)))
      (if (and allows-interleave-a allows-interleave-b)
          (> score-a score-b)
        (if (= max-score-a max-score-b)
            (> score-a score-b)
          (> max-score-a max-score-b))))
          
     ;; 3. Same project or no project
     ((equal project-a project-b)
      (if (equal (car (nth 4 a)) (car (nth 4 b)))
          ;; Direct siblings keep their relative textual order
          (< (cdr (nth 4 a)) (cdr (nth 4 b)))
        ;; Tasks across different subtrees sort by their score prioritizing highest impact
        (> score-a score-b)))
      
     ;; 4. Fallback to individual scores
     ((not (= score-a score-b))
      (> score-a score-b))
      
     (t nil))))

(defun org-auto-scheduler-sort-tasks (tasks)
  "Sort TASKS based on their project, scheduled date, calculated scores, and position using Kahn's Topological Sort."
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
                           (effort (org-auto-scheduler-get-effort marker))
                           (parent-node (save-excursion
                                          (with-current-buffer (marker-buffer marker)
                                            (goto-char (marker-position marker))
                                            (if (org-up-heading-safe)
                                                (cons (current-buffer) (point))
                                              (cons (current-buffer) 'top)))))
                           (position-info (cons parent-node task-position))
                           (dependency-depth 0)) ; Overwritten during Topological Sort
                      (org-auto-scheduler--log-debug 
                       "Task info: Name: %s, ID: %s, Project: %s, Score: %f, Position: %d"
                       task-name task-id project-id score task-position)
                      (list marker             ; 0
                            score              ; 1
                            project-id         ; 2
                            project-priority   ; 3
                            position-info      ; 4
                            task-id            ; 5
                            task-name          ; 6
                            tags               ; 7
                            scheduled          ; 8
                            allows-interleave  ; 9
                            not-before         ; 10
                            time-block         ; 11
                            effort             ; 12
                            (cdr score-info)   ; 13
                            dependency-depth))) ; 14
                  tasks))
         ;; Calculate max score per project
         (project-max-scores (make-hash-table :test 'equal))
         
         ;; Graph State Trackers
         (in-degree (make-hash-table :test 'equal))
         (adj-list (make-hash-table :test 'equal))
         (id-to-info (make-hash-table :test 'equal))
         (pool-ids (make-hash-table :test 'equal))
         (parent-groups (make-hash-table :test 'equal)))
    
    ;; Populate Project Scores & Initialize Graph Nodes
    (dolist (task tasks-with-info)
      (let ((project-id (nth 2 task))
            (score (nth 1 task))
            (task-id (nth 5 task))
            (parent-node (car (nth 4 task))))
        (puthash task-id task id-to-info)
        (puthash task-id t pool-ids)
        (puthash task-id 0 in-degree)
        ;; Group by both parent-node and project-id to ensure only same-project siblings form chains.
        ;; Do NOT create chains for independent tasks (project-id is nil).
        (when project-id
          (let ((group-key (cons parent-node project-id)))
            (puthash group-key (cons task (gethash group-key parent-groups)) parent-groups)))
        (when project-id
          (let ((current-max (gethash project-id project-max-scores -999999.0)))
            (when (> score current-max)
              (puthash project-id score project-max-scores))))))

    ;; 1. Add Explicit Blockers Edges
    (dolist (info tasks-with-info)
      (let* ((marker (nth 0 info))
             (task-id (nth 5 info))
             (blockers (org-auto-scheduler-get-blockers marker)))
        (dolist (b-marker blockers)
          (let ((b-id (org-with-point-at b-marker (org-id-get))))
            (when (gethash b-id pool-ids)
              (puthash b-id (cons task-id (gethash b-id adj-list)) adj-list)
              (puthash task-id (1+ (gethash task-id in-degree 0)) in-degree))))))

    ;; 2. Add Implicit Sibling Blockers Edges
    (maphash (lambda (parent group)
               (let ((sorted-group (sort group (lambda (a b) (< (cdr (nth 4 a)) (cdr (nth 4 b)))))))
                 (let ((prev-id nil))
                   (dolist (info sorted-group)
                     (let ((curr-id (nth 5 info)))
                       (when prev-id
                         (puthash prev-id (cons curr-id (gethash prev-id adj-list)) adj-list)
                         (puthash curr-id (1+ (gethash curr-id in-degree 0)) in-degree))
                       (setq prev-id curr-id))))))
             parent-groups)

    ;; 3. Kahn's Topological Sort Queue
    (let ((queue '())
          (sorted-tasks '())
          (depths (make-hash-table :test 'equal)))
      ;; Enqueue unblocked
      (maphash (lambda (id deg)
                 (when (= deg 0)
                   (push (gethash id id-to-info) queue)
                   (puthash id 0 depths)))
               in-degree)

      (while queue
        ;; Prioritize the queue
        (setq queue (sort queue (lambda (a b) (org-auto-scheduler--complex-sort-predicate a b project-max-scores))))
        
        ;; Pop the MOST critical unblocked task
        (let* ((current-info (pop queue))
               (current-id (nth 5 current-info))
               (current-depth (gethash current-id depths 0)))
          
          ;; Inject its computed graphical Depth structurally
          (setcar (nthcdr 14 current-info) current-depth)
          (push current-info sorted-tasks)
          
          ;; Cascade downwards
          (dolist (dep-id (gethash current-id adj-list))
            (let ((new-deg (1- (gethash dep-id in-degree))))
              (puthash dep-id new-deg in-degree)
              (puthash dep-id (max (gethash dep-id depths 0) (1+ current-depth)) depths)
              (when (= new-deg 0)
                (push (gethash dep-id id-to-info) queue))))))

      ;; Append any cyclic unresolvable tasks safely to the end
      (let ((cycle-tasks '()))
        (maphash (lambda (id deg)
                   (when (> deg 0)
                     (let ((info (gethash id id-to-info)))
                       ;; Give them an arbitrary extreme depth so they format strangely in UI as a warning
                       (setcar (nthcdr 14 info) 99)
                       (push info cycle-tasks))))
                 in-degree)
                 
        (setq sorted-tasks (nreverse sorted-tasks))
        
        (when cycle-tasks
          (setq cycle-tasks (sort cycle-tasks (lambda (a b) (org-auto-scheduler--complex-sort-predicate a b project-max-scores))))
          (setq sorted-tasks (append sorted-tasks cycle-tasks))))
          
      (dolist (task sorted-tasks)
        (org-auto-scheduler--log-debug 
         "  ID: %s, Name: %s, Tags: %s, Score: %f, Depth: %d, Project: %s, Position: %d, Scheduled: %s"
         (nth 5 task)  ; task-id
         (nth 6 task)  ; task-name
         (nth 7 task)  ; tags
         (nth 1 task)  ; score
         (nth 14 task) ; depth
         (nth 2 task)  ; project-id
         (cdr (nth 4 task))  ; position
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
     
(defun org-auto-scheduler-time-slot-occupied-p (start-time duration &optional ignore-id proposed-tags)
  "Check if the time slot is occupied, considering active timestamps and ignoring all-day tasks.
PROPOSED-TAGS are the tags of the task we are trying to schedule, used to calculate dynamic buffer times."
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
               (needs-buffer (or (member "buffertime" tags) (member "buffertime" proposed-tags)))
               (active-gap (if needs-buffer 15 org-auto-scheduler-task-gap))
               (task-start-with-gap (time-subtract task-start (seconds-to-time (* 60 active-gap))))
               (task-end-with-gap (time-add task-end (seconds-to-time (* 60 active-gap)))))
          (when (and (not (equal task-id ignore-id))
                    (or (not is-autosch) (and is-autosch consider-for-conflicts))
                    has-time
                    (time-less-p start-time task-end-with-gap)
                    (time-less-p task-start-with-gap end-time))
            (org-auto-scheduler--log-debug "    Conflict detected with task: %s" task-name)
            task-end-with-gap)))
      agenda-items))))

(defun org-auto-scheduler-next-available-time (start-time duration &optional proposed-tags)
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
             (occupied-result (org-auto-scheduler-time-slot-occupied-p current-time duration nil proposed-tags)))
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
                 (full-end-time-str (concat "<" (substring date 0 11) end-time ">"))
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
  (when (and org-auto-scheduler-sync-caldav
             (not org-auto-scheduler--preview-mode))
    (require 'org-caldav)
    (org-caldav-sync))
  (condition-case err
      (progn
        (setq org-auto-scheduler-completed-tasks '())  ; Clear the completed tasks list
        (org-auto-scheduler--build-agenda-cache)       ; Build agenda items cache upfront
        (unless org-auto-scheduler--preview-mode
          (org-auto-scheduler-create-report-buffer))      ; Create the report buffer
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

              (setq current-time (org-auto-scheduler-schedule-single-task marker current-time (nth 14 task-info)))
              (unless org-auto-scheduler--preview-mode
                (org-auto-scheduler-add-to-report task-info current-time))
              (setq tasks-scheduled (1+ tasks-scheduled)) 
              (when (zerop (mod tasks-scheduled 10))
                (org-auto-scheduler--log-info "Scheduled %d/%d tasks..." tasks-scheduled total-tasks))))
          
          (unless org-auto-scheduler--preview-mode
            (org-auto-scheduler-display-report))
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

(defun org-auto-scheduler-schedule-single-task (marker current-time &optional topo-depth)
  "Schedule a single task at MARKER, starting from CURRENT-TIME.
This function attempts to find an available time slot for the task,
respecting time blocks if specified, and avoiding conflicts with
existing scheduled tasks. If no available time slot is found within
the time block, it schedules the task outside the time block.
TOPO-DEPTH represents Kahn's Topological Sort computed depth."
  (org-auto-scheduler--log-debug "[org-auto-scheduler-schedule-single-task] Attempting to schedule task at marker %s" marker)
  (when (markerp marker)
    (org-with-point-at marker
      (let* ((headline (org-get-heading t t t t))
             (task-id (org-id-get))
             (base-effort (or (org-auto-scheduler-get-effort marker) 60))
             (multiplier (org-auto-scheduler-get-effort-multiplier marker))
             (total-effort (round (* base-effort multiplier)))
             (clocked-time (org-auto-scheduler-get-clocked-time marker))
             (remaining-effort (if (> clocked-time total-effort)
                                   10  ; Set to 10 minutes if clocked time exceeds total effort
                                 (max 10 (- total-effort clocked-time))))  ; Ensure minimum of 10 minutes
             (time-block (org-auto-scheduler-get-task-tag-block marker))
             (not-before (org-auto-scheduler-get-not-before marker))
             (blocked-result (org-auto-scheduler--evaluate-blockers marker))
             (all-blockers-met (car blocked-result))
             (blocker-end-time (cdr blocked-result))
             (start-time (let ((base-start (if (and not-before (time-less-p current-time not-before))
                                               not-before
                                             current-time)))
                           (if (and blocker-end-time (time-less-p base-start blocker-end-time))
                               blocker-end-time
                             base-start)))
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
        
        (if (not all-blockers-met)
            (progn
              (org-auto-scheduler--log-info "[org-auto-scheduler-schedule-single-task] Task '%s' is blocked by unmet dependencies. Skipping." headline)
              current-time) ; Return current-time unmodified since task wasn't scheduled

          ;; Task is not blocked, proceed to find an available time
          (let* ((tags (org-get-tags marker))
                 (needs-buffer (member "buffertime" tags))
                 (active-gap (if needs-buffer 15 org-auto-scheduler-task-gap)))
            (while (and (not end-time) (< attempts max-attempts))
              (setq attempts (1+ attempts))
              (when available-time
                (setq end-time (time-add available-time (seconds-to-time (* 60 remaining-effort))))
                  (let ((occupied-result (org-auto-scheduler-time-slot-occupied-p available-time remaining-effort task-id tags)))
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
                    (if org-auto-scheduler--preview-mode
                        (push (list task-id available-time end-time '("AUTOSCH") t headline schedule-string marker topo-depth) org-auto-scheduler-completed-tasks)
                      (org-set-property "SCHEDULED" schedule-string)
                      (org-set-property org-auto-scheduler-scheduled-property "t")
                      (push (list task-id available-time end-time '("AUTOSCH") t headline nil nil topo-depth) org-auto-scheduler-completed-tasks))
                    (org-auto-scheduler--log-info "[org-auto-scheduler-schedule-single-task] Scheduled task '%s' from %s to %s (Remaining effort: %d minutes, Gap: %dm)"
                                                  headline
                                                  (format-time-string "%Y-%m-%d %H:%M" available-time)
                                                  (format-time-string "%Y-%m-%d %H:%M" end-time)
                                                  remaining-effort active-gap)
                    (org-auto-scheduler--log-debug "[org-auto-scheduler-schedule-single-task] Adding task %s to the list of completed scheduling tasks"
                                                   task-id))
                  (time-add end-time (seconds-to-time (* 60 active-gap))))
              (org-auto-scheduler--log-warn "[org-auto-scheduler-schedule-single-task] Could not find available time slot within 7 days for task: %s" headline)
              (org-auto-scheduler--log-debug "[org-auto-scheduler-schedule-single-task] Scheduling failed after %d attempts" attempts)
              (org-auto-scheduler--log-debug "[org-auto-scheduler-schedule-single-task] Last attempted time: %s" (format-time-string "%Y-%m-%d %H:%M" available-time))
              current-time)))))))

(defvar org-auto-scheduler--ignore-blockers-p nil
  "Internal flag to dynamically bypass all dependency blockers when recalculating visual order.")

(defun org-auto-scheduler--evaluate-blockers (marker)
  "Evaluate if all blockers for MARKER have been met for current scheduling.
A blocker is met if it's either already DONE, or it has been scheduled 
in the current run (`org-auto-scheduler-completed-tasks`).
If `org-auto-scheduler--ignore-blockers-p` is dynamically bound to t, ignores dependencies entirely.
Returns a cons cell `(all-met-p . latest-end-time)` where `latest-end-time`
is the maximum end time of any blocker scheduled today (or nil if none)."
  (if org-auto-scheduler--ignore-blockers-p
      (cons t nil)
    (let ((blockers (org-auto-scheduler-get-blockers marker))
        (all-met t)
        (latest-end nil))
    (dolist (b-marker blockers)
      (when all-met ; Short-circuit checking
        (let* ((b-id (org-with-point-at b-marker (org-id-get)))
               ;; Search for blocker in today's freshly scheduled tasks
               (scheduled-b (cl-find b-id org-auto-scheduler-completed-tasks 
                                     :key #'car :test #'equal)))
          (if scheduled-b
              ;; Blocker was scheduled today; we must start after it ends.
              (let ((b-end-time (nth 2 scheduled-b)))
                (when (or (null latest-end) (time-less-p latest-end b-end-time))
                  (setq latest-end b-end-time)))
            ;; Blocker is NOT DONE (since it's in the list) AND NOT scheduled today
            (setq all-met nil)))))
      (cons all-met latest-end))))

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
    (dolist (tag-block (append org-auto-scheduler-time-blocks org-auto-scheduler-energy-blocks))
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
if no effort is specified, adjusted by historical effort multiplier."
  (let* ((base-effort (or (org-auto-scheduler-get-effort marker)
                          org-auto-scheduler-default-task-duration))
         (multiplier (org-auto-scheduler-get-effort-multiplier marker)))
    (round (* base-effort multiplier))))

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
             (let ((tags (org-get-tags)))
               (when (and (not (member "ARCHIVE" tags))
                        (org-auto-scheduler-has-repeater-task (point-marker)))
                 (let ((projections (org-auto-scheduler-project-repeater-occurrences (point-marker) end-date)))
                   (setq repeater-occurrences (append repeater-occurrences projections))))))
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

;;; Interactive Review Mode

(defvar org-auto-scheduler-review-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map tabulated-list-mode-map)
    map)
  "Keymap for `org-auto-scheduler-review-mode`.")

(define-key org-auto-scheduler-review-mode-map (kbd "SPC") 'org-auto-scheduler-review-toggle)
(define-key org-auto-scheduler-review-mode-map (kbd "m") 'org-auto-scheduler-review-toggle)
(define-key org-auto-scheduler-review-mode-map (kbd "TAB") 'org-auto-scheduler-review-jump)
(define-key org-auto-scheduler-review-mode-map (kbd "C-c C-c") 'org-auto-scheduler-review-execute)
(define-key org-auto-scheduler-review-mode-map (kbd "x") 'org-auto-scheduler-review-execute)
(define-key org-auto-scheduler-review-mode-map (kbd "U") 'org-auto-scheduler-review-move-up)
(define-key org-auto-scheduler-review-mode-map (kbd "p") 'org-auto-scheduler-review-move-up)
(define-key org-auto-scheduler-review-mode-map (kbd "D") 'org-auto-scheduler-review-move-down)
(define-key org-auto-scheduler-review-mode-map (kbd "n") 'org-auto-scheduler-review-move-down)
(define-key org-auto-scheduler-review-mode-map (kbd "r") 'org-auto-scheduler-review-recalculate)
(define-key org-auto-scheduler-review-mode-map (kbd "C-c C-r") 'org-auto-scheduler-review-recalculate)
(define-key org-auto-scheduler-review-mode-map (kbd "R") 'org-auto-scheduler-review-refresh)

(define-derived-mode org-auto-scheduler-review-mode tabulated-list-mode "AutoSch-Review"
  "Major mode for reviewing proposed auto-scheduled tasks before applying them."
  (setq tabulated-list-format [("Apply" 7 t)
                               ("Task Name" 40 t)
                               ("Proposed Time" 35 t)
                               ("Duration" 10 t)
                               ("Project ID" 20 t)
                               ("Score" 8 t)
                               ("Depth" 8 t)
                               ("Blockers" 25 t)])
  (setq tabulated-list-padding 2)
  (setq tabulated-list-sort-key (cons "Proposed Time" nil))
  (setq-local revert-buffer-function #'org-auto-scheduler-review-refresh-revert)
  (tabulated-list-init-header))

(defun org-auto-scheduler-review-toggle ()
  "Toggle the apply checkmark for the task at point."
  (interactive)
  (let* ((id (tabulated-list-get-id))
         (entry (tabulated-list-get-entry))
         (current-state (aref entry 0)))
    (when entry
      (aset entry 0 (if (string= current-state "[X]") "[ ]" "[X]"))
      (tabulated-list-put-tag current-state t) ; force redraw line
      (forward-line 1))))

(defun org-auto-scheduler-review-jump ()
  "Jump to the original Org task from the review buffer cleanly."
  (interactive)
  (let ((task-id (tabulated-list-get-id)))
    (if task-id
        (let ((marker (org-id-find task-id t)))
          (if marker
              (org-with-point-at marker
                (switch-to-buffer-other-window (marker-buffer marker))
                (goto-char marker)
                (org-show-context))
            (user-error "Task marker no longer valid")))
      (user-error "No valid task ID found for this entry"))))

(defun org-auto-scheduler-review-move-up ()
  "Move the current task up in the review list."
  (interactive)
  (when (> (line-number-at-pos) 1) ; Don't move up if already at the top
    (let* ((entry1 (tabulated-list-get-entry))
           (id1 (tabulated-list-get-id))
           (entry2 (save-excursion (forward-line -1) (tabulated-list-get-entry)))
           (id2 (save-excursion (forward-line -1) (tabulated-list-get-id))))
      (let ((node1 (assoc id1 tabulated-list-entries))
            (node2 (assoc id2 tabulated-list-entries)))
        (setcdr node1 (list entry2))
        (setcdr node2 (list entry1))
        (setcar node1 id2)
        (setcar node2 id1))
      ;; Disable automatic sorting so tabulated-list-print respects our manual structural map 
      (setq tabulated-list-sort-key nil)
      (tabulated-list-print t))))

(defun org-auto-scheduler-review-move-down ()
  "Move the current task down in the review list."
  (interactive)
  (let ((current-id (tabulated-list-get-id)))
    (save-excursion
      (forward-line 1)
      (when (not (eobp)) ; Don't move down if at the bottom
        (let* ((entry1 (save-excursion (forward-line -1) (tabulated-list-get-entry)))
               (id1 current-id)
               (entry2 (tabulated-list-get-entry))
               (id2 (tabulated-list-get-id)))
          (let ((node1 (assoc id1 tabulated-list-entries))
                (node2 (assoc id2 tabulated-list-entries)))
            (setcdr node1 (list entry2))
            (setcdr node2 (list entry1))
            (setcar node1 id2)
            (setcar node2 id1)))))
    (when (assoc current-id tabulated-list-entries)
      ;; Disable automatic sorting so tabulated-list-print respects our manual structural map 
      (setq tabulated-list-sort-key nil)
      (tabulated-list-print t))))

(defun org-auto-scheduler-review-recalculate ()
  "Recalculate scheduled times sequentially based purely on the current visual order without resorting."
  (interactive)
  (message "Recalculating proposed schedule based on visual order...")
  (let ((ordered-tasks '()))
    (save-excursion
      (goto-char (point-min))
      (while (not (eobp))
        (let* ((task-id (tabulated-list-get-id))
               (entry (tabulated-list-get-entry))
               (checked-state (if entry (aref entry 0) "[X]"))
               (data (and task-id (assoc task-id org-auto-scheduler-completed-tasks))))
          (when data
            (push (cons checked-state data) ordered-tasks)))
        (forward-line 1)))
    (setq ordered-tasks (nreverse ordered-tasks))
    
    (let ((org-auto-scheduler--preview-mode t)
          (org-auto-scheduler--ignore-blockers-p t)
          (current-time (org-auto-scheduler-get-start-time))
          (previous-project nil))
      (org-auto-scheduler--build-agenda-cache)
      (setq org-auto-scheduler-completed-tasks '()) ; clear previous preview state
      
      (dolist (item ordered-tasks)
        (let* ((task (cdr item))
               (marker (nth 7 task))
               (depth (nth 8 task))
               (task-project (org-with-point-at marker (org-auto-scheduler-get-project-id marker))))
          
          (when (or (not (equal task-project previous-project))
                    (null task-project))
            (setq current-time (org-auto-scheduler-get-start-time))
            (setq previous-project task-project))
            
          (setq current-time (org-auto-scheduler-schedule-single-task marker current-time depth)))))
          
    ;; Rebuild the tabulated list entries natively in the same buffer window
    (setq tabulated-list-entries nil)
    (let ((index 0))
      (dolist (task (reverse org-auto-scheduler-completed-tasks))
        (let* ((item (nth index ordered-tasks))
               (check-state (car item))
               (marker (nth 7 task))
               (headline (nth 5 task))
               (schedule-str-actual (nth 6 task))
               (start (nth 1 task))
               (end (nth 2 task))
               (duration (round (/ (float-time (time-subtract end start)) 60)))
               (project-id (org-with-point-at marker (org-auto-scheduler-get-project-id marker)))
               (score (car (org-auto-scheduler-calculate-score marker)))
               (depth (or (nth 8 task) 0))
               (blockers-list (org-auto-scheduler-get-blockers marker))
               (blockers-str (if blockers-list
                                 (mapconcat (lambda (b) 
                                              (org-with-point-at b (org-get-heading t t t t)))
                                            blockers-list ", ")
                               "None"))
               (prefix (if (> depth 0) (concat (make-string (* 2 (1- depth)) ? ) "├─ ") ""))
               (tree-headline (concat prefix headline)))
          (push (list (nth 0 task) (vector check-state
                                           tree-headline 
                                           schedule-str-actual
                                           (format "%d mins" duration)
                                           (or project-id "None")
                                           (format "%.2f" score)
                                           (format "%d" depth)
                                           blockers-str))
                tabulated-list-entries)
          (setq index (1+ index)))))
    (setq tabulated-list-entries (nreverse tabulated-list-entries))
    (setq tabulated-list-sort-key nil) ; disable sort stringency
    (tabulated-list-print t)
    (message "Recalculation complete!")))

(defun org-auto-scheduler-review-refresh (&rest _args)
  "Recalculate the auto-schedule from scratch, resetting the view.
This allows picking up any fresh Org file changes (tags, blockers) dynamically."
  (interactive)
  (org-auto-scheduler-review-and-apply))

(defun org-auto-scheduler-review-refresh-revert (&optional ignore-auto noconfirm)
  "Revert function for `org-auto-scheduler-review-mode`."
  (org-auto-scheduler-review-refresh))

(defun org-auto-scheduler-review-execute ()
  "Apply the scheduled times for all checked tasks in the review buffer.
Automatically recalculates dependent times based on visual layout before execution."
  (interactive)
  (org-auto-scheduler-review-recalculate) ; Always trust the exact visual layout before apply
  (org-auto-scheduler-create-report-buffer)
  (let ((applied-count 0))
    (save-excursion
      (goto-char (point-min))
      (while (not (eobp))
        (let* ((task-id (tabulated-list-get-id))
               (entry (tabulated-list-get-entry))
               (checked (string= (aref entry 0) "[X]")))
          (when (and checked task-id)
            (let* ((data (assoc task-id org-auto-scheduler-completed-tasks)))
              (when data
                (let* ((schedule-string (nth 6 data))
                       (marker (nth 7 data))
                       (headline (nth 5 data))
                       (end-time (nth 2 data))
                       (project-id (org-with-point-at marker (org-auto-scheduler-get-project-id marker)))
                       (score-info (org-auto-scheduler-calculate-score marker))
                       (score (car score-info))
                       (not-before (org-auto-scheduler-get-not-before marker))
                       (time-block (org-auto-scheduler-get-task-tag-block marker))
                       (effort (org-auto-scheduler-get-effort marker))
                       (task-info (list marker             ; 0
                                        score              ; 1
                                        project-id         ; 2
                                        nil                ; 3 project-priority
                                        nil                ; 4 position-info
                                        task-id            ; 5
                                        headline           ; 6
                                        nil                ; 7 tags
                                        nil                ; 8 scheduled
                                        nil                ; 9 allows-interleave
                                        not-before         ; 10
                                        time-block         ; 11
                                        effort             ; 12
                                        (cdr score-info)   ; 13 score-components
                                        0)))               ; 14 depth
                  (org-with-point-at marker
                    (org-set-property "SCHEDULED" schedule-string)
                    (org-set-property org-auto-scheduler-scheduled-property "t"))
                  (org-auto-scheduler-add-to-report task-info end-time)
                  (setq applied-count (1+ applied-count)))))))
        (forward-line 1)))
    (org-auto-scheduler-display-report)
    (message "Applied %d tasks from the auto-scheduler review!" applied-count)
    (kill-buffer (current-buffer))
    (when org-auto-scheduler-sync-caldav
      (require 'org-caldav)
      (org-caldav-sync))))

(defun org-auto-scheduler-review-and-apply ()
  "Calculate an auto-schedule in preview mode and display it for interactive review."
  (interactive)
  (message "Calculating proposed schedule...")
  (let ((org-auto-scheduler--preview-mode t))
    ;; Run the scheduler cleanly without applying to buffers
    (org-auto-scheduler-schedule-tasks))
  ;; Now build the tabulated list
  (let ((buf (get-buffer-create "*Org Auto Scheduler Review*")))
    (with-current-buffer buf
      (org-auto-scheduler-review-mode)
      (setq tabulated-list-entries nil)
      (dolist (task org-auto-scheduler-completed-tasks)
        ;; preview task : (task-id available-time end-time '("AUTOSCH") t headline schedule-string marker topo-depth)
        (let* ((marker (nth 7 task))
               (headline (nth 5 task))
               (schedule-str-actual (nth 6 task))
               (start (nth 1 task))
               (end (nth 2 task))
               (duration (round (/ (float-time (time-subtract end start)) 60)))
               (project-id (org-with-point-at marker (org-auto-scheduler-get-project-id marker)))
               (score (car (org-auto-scheduler-calculate-score marker)))
               (depth (or (nth 8 task) 0))
               (blockers-list (org-auto-scheduler-get-blockers marker))
               (blockers-str (if blockers-list
                                 (mapconcat (lambda (b) 
                                              (org-with-point-at b (org-get-heading t t t t)))
                                            blockers-list ", ")
                               "None"))
               (prefix (if (> depth 0) (concat (make-string (* 2 (1- depth)) ? ) "├─ ") ""))
               (tree-headline (concat prefix headline)))
          (push (list (nth 0 task) (vector "[X]" 
                                           tree-headline 
                                           schedule-str-actual
                                     (format "%d mins" duration)
                                     (or project-id "None")
                                     (format "%.2f" score)
                                     (format "%d" depth)
                                     blockers-str))
                tabulated-list-entries)))
      (tabulated-list-print t))
    (switch-to-buffer buf)))

;;; Agenda Bump Rescheduling

(defun org-auto-scheduler-bump-agenda (minutes)
  "Push the current agenda task and all subsequent AUTOSCH tasks for today forward by MINUTES."
  (interactive "nBump agenda items forward by minutes: ")
  (when (eq major-mode 'org-agenda-mode)
    (let* ((marker (org-get-at-bol 'org-marker))
           (current-time (current-time))
           (day-start (org-auto-scheduler-time-with-time-string current-time org-auto-scheduler-start-time))
           (day-end (org-auto-scheduler-time-with-time-string current-time org-auto-scheduler-end-time))
           (agenda-items (org-auto-scheduler-get-agenda-items day-start))
           (bump-seconds (* minutes 60))
           (found-target nil)
           (bumped-count 0))
      
      (if (not marker)
          (user-error "No agenda item at point")
        (let ((target-id (org-with-point-at marker (org-id-get))))
          ;; Filter for today's tasks and identify when to start bumping
          (dolist (item (sort agenda-items (lambda (a b) (time-less-p (nth 1 a) (nth 1 b)))))
            (let* ((task-id (nth 0 item))
                   (start-time (nth 1 item))
                   (end-time (nth 2 item))
                   (tags (nth 3 item))
                   (task-name (nth 5 item))
                   (is-autosch (member "AUTOSCH" tags)))
              
              (when (equal task-id target-id)
                (setq found-target t))
              
              ;; Once we find the target, bump it and all subsequent AUTOSCH items for the day
              (when (and found-target is-autosch)
                (let* ((item-marker (org-id-find task-id t))
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
                        (setq bumped-count (1+ bumped-count))))))))))
        
        (if found-target
            (progn
              (message "Bumped %d tasks forward by %d minutes." bumped-count minutes)
              (org-agenda-redo))
          (user-error "Target task not found in today's active schedule"))))))

;;; Schedule Adherence Tracking & Scoring

(defun org-auto-scheduler-snapshot-schedule ()
  "Record a snapshot of today's scheduled tasks for adherence tracking.
Only records tasks that have a SCHEDULED property matching today's date."
  (interactive)
  (let* ((today-date (format-time-string "%Y-%m-%d"))
         (snapshot nil)
         (count 0))
    (org-map-entries
     (lambda ()
       (let* ((scheduled-time-str (org-entry-get (point) "SCHEDULED"))
              (scheduled-time (when scheduled-time-str (org-time-string-to-time scheduled-time-str))))
         (when (and scheduled-time
                    (string= (format-time-string "%Y-%m-%d" scheduled-time) today-date)
                    (not (member "ARCHIVE" (org-get-tags))))
           (let* ((id (or (org-id-get) (org-id-get-create)))
                  (file (buffer-file-name))
                  (pos (point))
                  (heading (org-get-heading t t t t))
                  (effort (org-auto-scheduler-get-effort (point-marker)))
                  (category (org-get-category))
                  (tags (org-get-tags))
                  (task-plist (list :id id
                                    :file file
                                    :pos pos
                                    :heading heading
                                    :effort effort
                                    :category category
                                    :tags tags
                                    :scheduled scheduled-time-str)))
             (push task-plist snapshot)
             (cl-incf count)))))
     nil 'agenda)
    ;; Update snapshot list
    (let ((existing (assoc today-date org-auto-scheduler--adherence-snapshots)))
      (if existing
          (setcdr existing snapshot)
        (push (cons today-date snapshot) org-auto-scheduler--adherence-snapshots)))
    (org-auto-scheduler-save-adherence)
    (message "Snapshot saved: %d tasks planned for today." count)))

(defun org-auto-scheduler-score-schedule (&optional target-date)
  "Score performance against a morning's snapshot.
If TARGET-DATE is provided or prompted for, scores that specific day.
When scoring the current day, only considers tasks whose expected
start time is in the past."
  (interactive
   (list (when current-prefix-arg
           (let ((prompt-date (org-read-date nil nil nil "Score schedule for date: ")))
             (when prompt-date
               ;; org-read-date returns a date string, we need YYYY-MM-DD
               (format-time-string "%Y-%m-%d" (org-time-string-to-time prompt-date)))))))
  (let* ((score-date (or target-date (format-time-string "%Y-%m-%d")))
         (is-today (string= score-date (format-time-string "%Y-%m-%d")))
         (yesterday-date (format-time-string "%Y-%m-%d"
                           (time-subtract (org-time-string-to-time score-date) (days-to-time 1))))
         (snapshot (cdr (assoc score-date org-auto-scheduler--adherence-snapshots)))
         (yesterday-snapshot (cdr (assoc yesterday-date org-auto-scheduler--adherence-snapshots)))
         (current-time (current-time))
         (total-effort 0.0)
         (earned-effort 0.0)
         (tasks-results nil)
         (cat-stats (make-hash-table :test 'equal))
         (postponed-tasks 0)
         (unplanned-tasks 0)
         (missed-tasks nil))

    (unless snapshot
      (if is-today
          (user-error "No schedule snapshot found for today! Run `M-x org-auto-scheduler-snapshot-schedule` first.")
        (user-error "No schedule snapshot found for %s." score-date)))

    ;; 1. Check Snapshot Tasks (Earned vs Total)
    (dolist (task snapshot)
      (let* ((id (plist-get task :id))
             (heading (plist-get task :heading))
             (effort (or (plist-get task :effort) 30)) ; fallback to 30 mins
             (category (or (plist-get task :category) "Uncategorized"))
             (scheduled-time (plist-get task :scheduled))
             (marker (org-id-find id t))
             (is-done nil)
             (clocked 0)
             (earned 0.0)
             (should-score t)
             (has-passed t))
        
        ;; Evaluate state and clocked time first
        (when marker
          (org-with-point-at marker
            (setq is-done (member (org-get-todo-state) org-done-keywords))
            (setq clocked (org-auto-scheduler-get-clocked-time marker))))

        ;; Time-gating: Only evaluate tasks whose start time has passed if scoring "today"
        (when (and is-today scheduled-time)
           (setq has-passed (time-less-p (org-time-string-to-time scheduled-time) current-time))
           (when (and (not is-done) (not has-passed))
             ;; If it hasn't passed and hasn't been clocked, don't score it yet
             (when (= clocked 0)
               (setq should-score nil))))

        (when should-score
          (setq total-effort (+ total-effort effort))
          (unless (gethash category cat-stats)
            (puthash category (list 0.0 0.0) cat-stats))
          (let ((cat-data (gethash category cat-stats)))
            (setcar cat-data (+ (car cat-data) effort)))
  
          (if marker
              (progn
                ;; Check if it was rescheduled
                (let* ((current-scheduled (org-with-point-at marker (org-entry-get marker "SCHEDULED"))))
                  (when (and current-scheduled scheduled-time
                             (not (string= current-scheduled scheduled-time))
                             (not is-done))
                    (push (list heading scheduled-time current-scheduled) missed-tasks)))
                (if is-done
                    (setq earned (float effort))
                  ;; Partial credit: up to the estimated effort
                  (setq earned (min (float effort) (float clocked)))))
            ;; Marker not found - count as 0 earned
            (setq earned 0.0))
          
          (setq earned-effort (+ earned-effort earned))
          (let ((cat-data (gethash category cat-stats)))
            (setcar (cdr cat-data) (+ (cadr cat-data) earned)))
  
          ;; Postponement Check (was it in yesterday's snapshot?)
          (let ((was-yesterday (cl-find-if (lambda (yt) (equal (plist-get yt :id) id)) yesterday-snapshot)))
            (when (and was-yesterday (not is-done))
              (cl-incf postponed-tasks)))
  
          ;; Track Missed Tasks for Time of Day Analysis
          (when (and (not is-done) (< (/ earned effort) 0.8) has-passed)
            (push (list heading scheduled-time clocked effort category) missed-tasks))
  
          (push (list heading earned effort is-done) tasks-results))))

    ;; 2. Unplanned Tasks Check
    (org-map-entries
     (lambda ()
       (when (member (org-get-todo-state) org-done-keywords)
         (let* ((id (org-id-get))
                (in-snapshot (cl-find-if (lambda (t-snap) (equal (plist-get t-snap :id) id)) snapshot)))
           (unless in-snapshot
             (let ((closed-ts (org-entry-get (point) "CLOSED")))
               (when (and closed-ts (string= (substring closed-ts 1 11) score-date))
                 (cl-incf unplanned-tasks)))))))
     nil 'agenda)

    (let* ((score (if (> total-effort 0) (* (/ earned-effort total-effort) 100.0) 100.0))
           (score-data (list :score score
                             :total-effort total-effort
                             :earned-effort earned-effort
                             :postponed postponed-tasks
                             :unplanned unplanned-tasks
                             :categories cat-stats
                             :missed missed-tasks))
           (history-entry (assoc score-date org-auto-scheduler--adherence-history)))
      
      ;; Update History
      (if history-entry
          (setcdr history-entry score-data)
        (push (cons score-date score-data) org-auto-scheduler--adherence-history))
      
      (org-auto-scheduler-save-adherence)
      (org-auto-scheduler-adherence-report score-date)
      (message "Schedule scored: %.1f%% adherence calculated for %s." score score-date))))

(defun org-auto-scheduler-get-adherence-streak ()
  "Calculate current adherence streak (> 80% score)."
  (let ((streak 0)
        (date (current-time)))
    (catch 'break
      (while t
        (let* ((date-str (format-time-string "%Y-%m-%d" date))
               (entry (assoc date-str org-auto-scheduler--adherence-history)))
          (if entry
              (let ((score (plist-get (cdr entry) :score)))
                (if (>= score 80.0)
                    (cl-incf streak)
                  (throw 'break t)))
            (throw 'break t)))
        (setq date (time-subtract date (days-to-time 1)))))
    streak))

(defun org-auto-scheduler-adherence-report (&optional date-str)
  "Display the adherence report for DATE-STR.
If DATE-STR is nil, defaults to today."
  (interactive)
  (let* ((date-str (or date-str (format-time-string "%Y-%m-%d")))
         (data (cdr (assoc date-str org-auto-scheduler--adherence-history)))
         (buf (get-buffer-create "*Org Auto Scheduler Adherence*")))
    (unless data
      (user-error "No data to display for %s" date-str))
    
    (with-current-buffer buf
      (read-only-mode -1)
      (erase-buffer)
      (insert (propertize (format " Daily Schedule Adherence - %s \n" date-str) 'face 'org-document-title))
      (insert (make-string 50 ?=) "\n\n")
      
      ;; 1. Global Score
      (let* ((score (plist-get data :score))
             (streak (org-auto-scheduler-get-adherence-streak))
             (color (cond ((>= score 90) "green")
                          ((>= score 70) "orange")
                          (t "red"))))
        (insert (format "Overall Score: %s\n" 
                        (propertize (format "%.1f%%" score) 'face `(:foreground ,color :weight bold))))
        (insert (format "Current Streak: %d days 🔥\n" streak))
        (insert (format "Effort: %.1fh planned, %.1fh earned\n\n" 
                        (/ (plist-get data :total-effort) 60.0) 
                        (/ (plist-get data :earned-effort) 60.0))))
      
      ;; 2. Category Breakdown
      (insert (propertize " Category Breakdown \n" 'face 'org-level-1))
      (insert (make-string 30 ?-) "\n")
      (let ((cat-stats (plist-get data :categories)))
        (if (and cat-stats (> (hash-table-count cat-stats) 0))
            (maphash (lambda (cat stats)
                       (let* ((total (car stats))
                              (earned (cadr stats))
                              (cat-score (if (> total 0) (* (/ earned total) 100.0) 100.0)))
                         (insert (format "%-15s : %6.1f%% (Planned: %.1fh, Earned: %.1fh)\n"
                                         cat cat-score (/ total 60.0) (/ earned 60.0)))))
                     cat-stats)
          (insert "No categories tracked.\n")))
      (insert "\n")
      
      ;; 3. Time of Day Analysis / Missed Tasks
      (let ((missed (plist-get data :missed)))
        (when missed
          (insert (propertize " Missed or Rescheduled Tasks \n" 'face 'org-level-1))
          (insert (make-string 30 ?-) "\n")
          (dolist (m missed)
            (if (= (length m) 3)
                ;; It's a rescheduled task
                (let ((heading (nth 0 m))
                      (old (nth 1 m))
                      (new (nth 2 m)))
                  (insert (format "[Rescheduled] %s\n  From: %s\n  To:   %s\n" heading old new)))
              ;; It's a standard missed task
              (let ((heading (nth 0 m))
                    (time (nth 1 m))
                    (clocked (nth 2 m))
                    (effort (nth 3 m))
                    (cat (nth 4 m)))
                (let ((time-str (if (and time (string-match "\\([0-9]\\{2\\}:[0-9]\\{2\\}\\)" time))
                                    (match-string 1 time)
                                  "Unscheduled")))
                  (insert (format "[%-5s] %s | Effort: %dm, Clocked: %dm\n" time-str heading effort clocked))))))
          (insert "\n")))
      
      ;; 4. Postponed & Unplanned Warnings
      (let ((postponed (or (plist-get data :postponed) 0))
            (unplanned (or (plist-get data :unplanned) 0)))
        (when (or (> postponed 0) (> unplanned 0))
          (insert (propertize " Warnings \n" 'face 'org-level-1))
          (insert (make-string 30 ?-) "\n")
          (when (> postponed 0)
            (insert (format "⚠️ You have %d tasks that rolled over from yesterday.\n" postponed)))
          (when (> unplanned 0)
            (insert (format "⚠️ The \"Squirrel!\" Penalty: You completed %d unplanned tasks today.\n" unplanned)))
          (insert "\n")))
          
      ;; 5. Hall of Fame (Best Days)
      (let ((best-week 0.0) (best-week-date "")
            (best-month 0.0) (best-month-date "")
            (best-year 0.0) (best-year-date "")
            (today-time (current-time)))
        (dolist (entry org-auto-scheduler--adherence-history)
          (let* ((date-str (car entry))
                 (entry-data (cdr entry))
                 (entry-score (plist-get entry-data :score))
                 (entry-time (org-auto-scheduler-parse-time-string (concat date-str " 12:00")))
                 (days-ago (and entry-time (time-to-days (time-subtract today-time entry-time)))))
            (when days-ago
              ;; Week
              (when (and (<= days-ago 7) (> entry-score best-week))
                (setq best-week entry-score)
                (setq best-week-date date-str))
              ;; Month
              (when (and (<= days-ago 30) (> entry-score best-month))
                (setq best-month entry-score)
                (setq best-month-date date-str))
              ;; Year
              (when (and (<= days-ago 365) (> entry-score best-year))
                (setq best-year entry-score)
                (setq best-year-date date-str)))))
        (when (> best-week 0)
          (insert (propertize " 🏆 Hall of Fame (Past Bests) \n" 'face 'org-level-1))
          (insert (make-string 30 ?-) "\n")
          (insert (format "Best Last 7 Days:  %6.1f%% (%s)\n" best-week best-week-date))
          (insert (format "Best Last 30 Days: %6.1f%% (%s)\n" best-month best-month-date))
          (insert (format "Best Last 1 Year:  %6.1f%% (%s)\n" best-year best-year-date))
          (insert "\n")))
          
      ;; 6. Historical Multipliers
      (let ((multipliers org-auto-scheduler-historical-multipliers))
        (when multipliers
          (insert (propertize " Estimation vs Reality (Historical Multipliers) \n" 'face 'org-level-1))
          (insert (make-string 30 ?-) "\n")
          (dolist (m multipliers)
            (insert (format "%-15s : %5.2fx (meaning tasks take %s time than estimated)\n"
                            (car m) (cdr m)
                            (if (> (cdr m) 1.2) "more" (if (< (cdr m) 0.8) "less" "about the same")))))))
                            
      (read-only-mode 1)
      (display-buffer buf))))

(defvar org-auto-scheduler--adherence-timer nil
  "Timer for updating the adherence score in the mode line.")

(defvar org-auto-scheduler-adherence-string ""
  "String displayed in the global mode line representing current adherence.")

(defun org-auto-scheduler-update-adherence-score-silent ()
  "Silently update the daily adherence score in the background without displaying."
  (let* ((today-date (format-time-string "%Y-%m-%d"))
         (snapshot (cdr (assoc today-date org-auto-scheduler--adherence-snapshots)))
         (current-time (current-time))
         (total-effort 0.0)
         (earned-effort 0.0))
    (when snapshot
      (dolist (task snapshot)
        (let* ((id (plist-get task :id))
               (effort (or (plist-get task :effort) 30))
               (scheduled-time (plist-get task :scheduled))
               (marker (org-id-find id t))
               (earned 0.0)
               (should-score t)
               (is-done nil)
               (clocked 0))
               
          (when marker
            (org-with-point-at marker
              (setq is-done (member (org-get-todo-state) org-done-keywords))
              (setq clocked (org-auto-scheduler-get-clocked-time marker))))

          (when (and scheduled-time (not is-done))
             (let* ((scheduled-ts (org-time-string-to-time scheduled-time))
                    (has-passed (time-less-p scheduled-ts current-time)))
               (unless has-passed
                 (when (= clocked 0)
                   (setq should-score nil)))))
                 
          (when should-score
            (setq total-effort (+ total-effort effort))
            (when marker
              (if is-done
                  (setq earned (float effort))
                (setq earned (min (float effort) (float clocked)))))
            (setq earned-effort (+ earned-effort earned)))))
      (let* ((score (if (> total-effort 0) (* (/ earned-effort total-effort) 100.0) 100.0))
             (streak (org-auto-scheduler-get-adherence-streak)))
        (setq org-auto-scheduler-adherence-string 
              (format " [Adh: %.0f%%%s]" score (if (> streak 0) (format " 🔥%d" streak) "")))
        (force-mode-line-update t)))))

(defun org-auto-scheduler-adherence-mode-line-enable ()
  "Enable displaying the adherence score in the global mode line."
  (interactive)
  (unless (memq 'org-auto-scheduler-adherence-string global-mode-string)
    (setq global-mode-string (append global-mode-string '(org-auto-scheduler-adherence-string))))
  (when org-auto-scheduler--adherence-timer
    (cancel-timer org-auto-scheduler--adherence-timer))
  ;; Update immediately, then every 5 minutes
  (org-auto-scheduler-update-adherence-score-silent)
  (setq org-auto-scheduler--adherence-timer
        (run-with-timer 300 300 #'org-auto-scheduler-update-adherence-score-silent))
  (message "Org Auto Scheduler adherence score enabled in mode line."))

(defun org-auto-scheduler-adherence-mode-line-disable ()
  "Disable displaying the adherence score in the global mode line."
  (interactive)
  (setq global-mode-string (delq 'org-auto-scheduler-adherence-string global-mode-string))
  (when org-auto-scheduler--adherence-timer
    (cancel-timer org-auto-scheduler--adherence-timer)
    (setq org-auto-scheduler--adherence-timer nil))
  (message "Org Auto Scheduler adherence score disabled in mode line."))

(provide 'org-auto-scheduler)
