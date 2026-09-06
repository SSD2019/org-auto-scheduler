;;; org-auto-scheduler.el --- Auto task scheduler for Org -*- lexical-binding: t; -*-
(require 'org)
(require 'cl-lib)
(require 'org-id)
(require 'log4e)
(require 'parse-time)
(require 'org-agenda)
(require 'org-duration)
(require 'time-date)
(require 'org-clock)
(require 'calendar)
(require 'tabulated-list)



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

(defcustom org-auto-scheduler-default-task-duration 60
  "Default duration in minutes for tasks without an explicit effort."
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
  :type 'integer
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

;; Advise org-caldav to ensure lexical-binding cookie in sync state buffers and files
(defun org-auto-scheduler--org-caldav-load-sync-state-advice (orig-fun &rest args)
  "Ensure the temporary buffer in `org-caldav-load-sync-state' has lexical-binding set."
  (let ((orig-insert-file-contents (symbol-function 'insert-file-contents)))
    (cl-letf (((symbol-function 'insert-file-contents)
               (lambda (&rest iargs)
                 (apply orig-insert-file-contents iargs)
                 (save-excursion
                   (goto-char (point-min))
                   (unless (re-search-forward "lexical-binding:" (line-end-position) t)
                     (insert ";;; -*- lexical-binding: t; -*-\n"))))))
      (apply orig-fun args))))

(defun org-auto-scheduler--org-caldav-save-sync-state-advice (orig-fun &rest args)
  "Ensure files written by `org-caldav-save-sync-state` contain a lexical-binding cookie."
  (let ((orig-insert (symbol-function 'insert)))
    (cl-letf (((symbol-function 'insert)
               (lambda (&rest iargs)
                 (if (and (stringp (car-safe iargs))
                          (string-prefix-p ";; This is the sync state" (car iargs)))
                     (apply orig-insert ";;; -*- lexical-binding: t; -*-\n" iargs)
                   (apply orig-insert iargs)))))
      (apply orig-fun args))))

(with-eval-after-load 'org-caldav
  (advice-add 'org-caldav-load-sync-state :around #'org-auto-scheduler--org-caldav-load-sync-state-advice)
  (advice-add 'org-caldav-save-sync-state :around #'org-auto-scheduler--org-caldav-save-sync-state-advice))

(when (featurep 'org-caldav)
  (advice-add 'org-caldav-load-sync-state :around #'org-auto-scheduler--org-caldav-load-sync-state-advice)
  (advice-add 'org-caldav-save-sync-state :around #'org-auto-scheduler--org-caldav-save-sync-state-advice))

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
        (insert ";;; -*- lexical-binding: t; -*-\n")
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
      (insert ";;; -*- lexical-binding: t; -*-\n")
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
                 (let* ((time-val (org-time-string-to-time time-str))
                        (has-time-flag (string-match "[0-9][0-9]:[0-9][0-9]" time-str)))
                   (unless task-id (setq task-id (org-id-get)))
                   (unless task-end-time (setq task-end-time (org-auto-scheduler-calculate-task-end-time (point))))
                   (let* ((date-string (format-time-string "%Y-%m-%d" time-val))
                          (item (list task-id time-val task-end-time tags t task-name has-time-flag))
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
                   (has-time-flag (when scheduled-time-str (string-match "[0-9][0-9]:[0-9][0-9]" scheduled-time-str)))
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
                    (list task-id scheduled-time task-end-time tags t task-name has-time-flag))))))
          nil
          'agenda)
         ;; Tasks with active timestamps (excluding habit tasks)
         (org-map-entries
          (lambda ()
            (let* ((task-name (org-get-heading t t t t))
                   (scheduled-time-str (org-entry-get nil "TIMESTAMP"))
                   (scheduled-time (when scheduled-time-str (org-time-string-to-time scheduled-time-str)))
                   (has-time-flag (when scheduled-time-str (string-match "[0-9][0-9]:[0-9][0-9]" scheduled-time-str)))
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
                    (list task-id scheduled-time task-end-time tags t task-name has-time-flag))))))
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
                  ;; Has time flag is true for repeaters as they are scheduled tasks with a time duration
                  (setq repeater-item (append repeater-item (list t)))
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
      (encode-time (or (nth 0 parsed) 0)  ; second
                   (or (nth 1 parsed) 0)  ; minute
                   (or (nth 2 parsed) 0)  ; hour
                   (or (nth 3 parsed) 1)  ; day
                   (or (nth 4 parsed) 1)  ; month
                   (or (nth 5 parsed) 1970)))))  ; year

(defun org-auto-scheduler-get-effort (pom)
  "Get the effort estimate for the task at point or marker POM.
Checks for what-if overrides in the review buffer if active."
  (let* ((task-id (org-with-point-at pom (org-id-get)))
         (override (and task-id
                        (bound-and-true-p org-auto-scheduler--review-overrides)
                        (gethash task-id org-auto-scheduler--review-overrides)))
         (overridden-effort (plist-get override :effort)))
    (if overridden-effort
        overridden-effort
      (let ((effort (org-entry-get pom "Effort")))
        (when effort
          (org-duration-to-minutes effort))))))

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
     ;; Check conflicts with existing tasks.
     ;; We scan ALL conflicting items and return the MAXIMUM end-with-gap so that
     ;; next-available-time jumps past every overlapping item in one step.
     ;; Using cl-some would return the first match's end time (in non-deterministic
     ;; list order), requiring multiple loop iterations and causing inconsistent results.
     (let ((max-conflict-end nil))
       (dolist (item agenda-items)
         (let* ((task-id (nth 0 item))
                (task-start (nth 1 item))
                (task-end (nth 2 item))
                (tags (nth 3 item))
                (consider-for-conflicts (nth 4 item))
                (task-name (nth 5 item))
                (has-time (nth 6 item))
                (is-autosch (member "AUTOSCH" tags))
                (needs-buffer (or (member "buffertime" tags) (member "buffertime" proposed-tags)))
                (active-gap (if needs-buffer 15 org-auto-scheduler-task-gap))
                (task-start-with-gap (time-subtract task-start (seconds-to-time (* 60 active-gap))))
                (task-end-with-gap (time-add task-end (seconds-to-time (* 60 active-gap)))))
           (when (and task-start  ; guard against nil timestamps from bad cache entries
                      task-end
                      (not (equal task-id ignore-id))
                      (or (not is-autosch) (and is-autosch consider-for-conflicts))
                      has-time
                      (time-less-p start-time task-end-with-gap)
                      (time-less-p task-start-with-gap end-time))
             (org-auto-scheduler--log-debug "    Conflict detected with task: %s (ends %s)"
                                            task-name
                                            (format-time-string "%H:%M" task-end-with-gap))
             (when (or (null max-conflict-end)
                       (time-less-p max-conflict-end task-end-with-gap))
               (setq max-conflict-end task-end-with-gap)))))
       max-conflict-end))))


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
  (let* ((decoded (decode-time time))
         (next-day-decoded (append (cl-subseq decoded 0 3)
                                   (list (1+ (nth 3 decoded)))
                                   (nthcdr 4 decoded))))
    (apply #'encode-time next-day-decoded)))


(defun org-auto-scheduler-next-available-time-in-block (current-time blocks remaining-effort)
  "Find the next available time in the specified BLOCKS after CURRENT-TIME.
Returns the next available time if found within the blocks and max-days-to-check,
and if the task with REMAINING-EFFORT fits within the block.
If no slot is found within blocks after max-days-to-check, returns nil."
  (let* ((days-checked 0)
         (found-time nil)
         (original-time current-time))

    ;; Try to find a slot within blocks
    (while (and (not found-time)
                (< days-checked org-auto-scheduler-max-days-to-check))
      (let ((day-start (time-add original-time (days-to-time days-checked))))
        (dolist (block blocks)
          (let* ((block-start (org-auto-scheduler-time-with-time-string day-start (car block)))
                 (block-end (org-auto-scheduler-time-with-time-string day-start (cdr block))))
            (when (and (time-less-p current-time block-end)
                       (org-auto-scheduler-time-fits-block-p block-start block-end remaining-effort))
              (setq found-time (if (time-less-p current-time block-start)
                                   block-start
                                 current-time))))))

      ;; Move to the next day
      (setq days-checked (1+ days-checked)))

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
  (let* ((next-day (org-auto-scheduler-next-day time))
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
             (not org-auto-scheduler--preview-mode)
             (require 'org-caldav nil t))
    (condition-case err
        (org-caldav-sync)
      (error (message "CalDAV sync failed (pre-schedule): %s" (error-message-string err)))))
  (condition-case err
      (progn
        (org-auto-scheduler-validate-config)              ; Validate config at runtime
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

          (let ((reporter (make-progress-reporter "Scheduling tasks..." 0 total-tasks)))
            (dolist (task-info sorted-tasks-info)
              (let* ((marker (car task-info))
                     (task-project (nth 2 task-info)))

                (when (or (not (equal task-project previous-project))
                          (null task-project))
                  (setq current-time (org-auto-scheduler-get-start-time))
                  (setq previous-project task-project)
                  (org-auto-scheduler--log-debug "Project changed or is null. Resetting current time to %s"
                                                 (format-time-string "%Y-%m-%d %H:%M" current-time)))

                (let ((prev-completed-count (length org-auto-scheduler-completed-tasks)))
                  (setq current-time (org-auto-scheduler-schedule-single-task marker current-time (nth 14 task-info)))
                  (unless org-auto-scheduler--preview-mode
                    (let ((scheduled-start
                           (when (> (length org-auto-scheduler-completed-tasks) prev-completed-count)
                             (nth 1 (car org-auto-scheduler-completed-tasks)))))
                      (org-auto-scheduler-add-to-report task-info scheduled-start))))
                (setq tasks-scheduled (1+ tasks-scheduled))
                (progress-reporter-update reporter tasks-scheduled)))
            (progress-reporter-done reporter))

          ;; Normalize completed-tasks to chronological order (built via push)
          (setq org-auto-scheduler-completed-tasks (nreverse org-auto-scheduler-completed-tasks))
          (unless org-auto-scheduler--preview-mode
            (org-auto-scheduler-display-report))
          (org-auto-scheduler--log-info "Scheduled %d tasks" tasks-scheduled)
          (when (and org-auto-scheduler-sync-caldav
                     (require 'org-caldav nil t))
            (org-auto-scheduler--log-info "Saving all org agenda buffers before CalDAV sync")
            (save-some-buffers t (lambda ()
                                   (and (buffer-file-name)
                                        (member (buffer-file-name) (org-agenda-files t)))))
            (condition-case err
                (org-caldav-sync)
              (error (message "CalDAV sync failed (post-schedule): %s" (error-message-string err)))))))
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
                 (let ((new-instances (org-auto-scheduler-create-recurring-instances headline recurring scheduled not-before)))
                   (setq tasks (append new-instances tasks))))
             (org-auto-scheduler--log-debug "Adding non-recurring task: %s from file %s" headline file)
             (push (point-marker) tasks)))
         (org-auto-scheduler--log-debug "Found schedulable task: %s (State: %s, NOT_BEFORE: %s, RECURRING: %s) in file %s"
                                        headline state (or not-before "Not set") (or recurring "Not set") file)))
     nil
     'agenda)
    (org-auto-scheduler--log-info "Found %d schedulable tasks across the agenda" (length tasks))
    (nreverse tasks)))

(defun org-auto-scheduler-create-recurring-instances (headline recurring scheduled not-before)
  "Create recurring instances for a task and return a list of markers for the scheduled tasks."
  (let* ((start-date (if scheduled
                         (org-time-string-to-time scheduled)
                       (current-time)))
         (end-date (time-add (current-time) (days-to-time org-auto-scheduler-recurring-look-days-ahead)))
         (current-date start-date)
         (last-instance-date nil)
         (new-tasks '()))
    (while (time-less-p current-date end-date)
      (let* ((date-string (format-time-string "%Y-%m-%d" current-date))
             (instance-headline (format "%s - %s" headline date-string))
             (existing-instance (org-auto-scheduler-find-existing-instance instance-headline)))
        (unless existing-instance
          (let ((new-task (org-auto-scheduler-create-subtask instance-headline current-date)))
            (push new-task new-tasks)))
        (setq current-date (org-auto-scheduler-next-recurring-date current-date recurring))
        (setq last-instance-date current-date)))
    ;; Update the SCHEDULED property of the main task
    ;; Save-excursion to get back to the parent heading since create-subtask moves point
    (save-excursion
      (org-back-to-heading t)
      (when last-instance-date
        (org-set-property "SCHEDULED" (format-time-string "<%Y-%m-%d %a>" last-instance-date))))
    new-tasks))

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
    (_ (error "Unknown recur frequency: %s" recurring))))

(defun org-auto-scheduler-add-months (time months)
  "Add MONTHS to TIME, handling end of month, multi-year jumps, and leap year cases."
  (let* ((decoded (decode-time time))
         (month (nth 4 decoded))
         (year (nth 5 decoded))
         (day (nth 3 decoded))
         (total-months (+ month months -1))
         (new-year (+ year (floor total-months 12)))
         (new-month (1+ (mod total-months 12))))
    (setf (nth 5 decoded) new-year)
    (setf (nth 4 decoded) new-month)
    (setf (nth 3 decoded) (min day (calendar-last-day-of-month new-month new-year)))
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
              ;; Record blocked tasks so they appear in the review buffer
              (when org-auto-scheduler--preview-mode
                (push (list task-id current-time current-time '("AUTOSCH") nil headline
                            "BLOCKED" marker (or topo-depth 0) :blocked '("Blocked by unmet dependencies"))
                      org-auto-scheduler-completed-tasks))
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
                      (push (list task-id available-time end-time '("AUTOSCH") t headline schedule-string nil topo-depth) org-auto-scheduler-completed-tasks))
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
              ;; Record failed tasks so they appear in the review buffer with error status
              (when org-auto-scheduler--preview-mode
                (push (list task-id current-time current-time '("AUTOSCH") nil headline
                            "FAILED" marker (or topo-depth 0) :failed '("No available slot within 7 days"))
                      org-auto-scheduler-completed-tasks))
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

;; NOTE: Using Org's built-in `org-with-point-at` macro.
;; The custom redefinition that was here has been removed to avoid
;; shadowing Org's version, which had subtle scoping bugs.

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
;; NOTE: validate-config is called inside schedule-tasks, not at load time,
;; to avoid errors when the user hasn't configured their settings yet.


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
           t  ; REPEAT: t means fire every time Emacs goes idle for idle-time seconds
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

;;; ────────────────────────────────────────────────────────────────
;;; Review Buffer Helpers — project colors, filters, undo, smart effort
;;; ────────────────────────────────────────────────────────────────

(defvar org-auto-scheduler--project-color-palette
  '("dodger blue" "orange" "medium sea green" "orchid"
    "sandy brown" "deep sky blue" "salmon" "lime green"
    "hot pink" "turquoise" "gold" "slate blue")
  "Colors cycled through for project indicators in the review buffer.")

(defvar org-auto-scheduler--project-colors nil
  "Hash-table mapping project-name → color string.  Rebuilt each review session.")

(defvar org-auto-scheduler--project-name-cache nil
  "Hash-table mapping marker-buffer+pos → project heading name.  Session cache.")

(defvar-local org-auto-scheduler--review-all-entries nil
  "Full unfiltered copy of `tabulated-list-entries' for filter/restore.")

(defvar-local org-auto-scheduler--review-undo-stack nil
  "Undo stack of previous `tabulated-list-entries' snapshots.")

(defvar-local org-auto-scheduler--review-undo-max 30
  "Maximum undo stack depth.")

(defvar-local org-auto-scheduler--review-active-filter nil
  "Currently active filter description string, or nil.")

(defvar-local org-auto-scheduler--review-overrides nil
  "Hash-table of task-id → plist of what-if overrides (:effort N :priority P).")

(defvar-local org-auto-scheduler--review-view 'table
  "Current view mode: `table' or `calendar'.")

(defun org-auto-scheduler--get-project-name (marker)
  "Get the human-readable heading of the nearest :PROJECT: ancestor for MARKER.
Returns a truncated string (max 20 chars) or nil."
  (when (and marker (markerp marker) (marker-buffer marker))
    (or (and org-auto-scheduler--project-name-cache
             (gethash (cons (marker-buffer marker) (marker-position marker))
                      org-auto-scheduler--project-name-cache))
        (let ((name (save-excursion
                      (with-current-buffer (marker-buffer marker)
                        (goto-char (marker-position marker))
                        (catch 'found
                          (let ((tags (org-get-tags nil t)))
                            (when (cl-find-if (lambda (tag) (string-equal-ignore-case tag "PROJECT")) tags)
                              (throw 'found (org-get-heading t t t t))))
                          (while (org-up-heading-safe)
                            (let ((tags (org-get-tags nil t)))
                              (when (cl-find-if (lambda (tag) (string-equal-ignore-case tag "PROJECT")) tags)
                                (throw 'found (org-get-heading t t t t)))))
                          nil)))))
          (when name
            (unless org-auto-scheduler--project-name-cache
              (setq org-auto-scheduler--project-name-cache (make-hash-table :test 'equal)))
            (puthash (cons (marker-buffer marker) (marker-position marker))
                     name org-auto-scheduler--project-name-cache))
          name))))

(defun org-auto-scheduler--truncate (str max)
  "Truncate STR to MAX chars, appending '..' if needed."
  (if (and str (> (length str) max))
      (concat (substring str 0 (- max 2)) "..")
    (or str "")))

(defun org-auto-scheduler--assign-project-colors (tasks)
  "Build `org-auto-scheduler--project-colors' from TASKS."
  (setq org-auto-scheduler--project-colors (make-hash-table :test 'equal))
  (let ((idx 0))
    (dolist (task tasks)
      (let* ((marker (nth 7 task))
             (proj-name (or (org-auto-scheduler--get-project-name marker) "—"))
             (proj-trunc (org-auto-scheduler--truncate proj-name 18)))
        (when (and proj-trunc (not (string= proj-trunc "—"))
                   (not (gethash proj-trunc org-auto-scheduler--project-colors)))
          (puthash proj-trunc
                   (nth (% idx (length org-auto-scheduler--project-color-palette))
                        org-auto-scheduler--project-color-palette)
                   org-auto-scheduler--project-colors)
          (cl-incf idx))))))

(defun org-auto-scheduler--project-dot (project-name)
  "Return a propertized '●' for PROJECT-NAME, or a dim '·' for no-project."
  (if (and project-name (not (string= project-name "—"))
           org-auto-scheduler--project-colors)
      (let ((color (gethash project-name org-auto-scheduler--project-colors)))
        (if color
            (propertize "●" 'face `(:foreground ,color))
          "·"))
    "·"))

(defun org-auto-scheduler--status-indicator (task)
  "Return a status string for a completed-task entry.
TASK is a list: (id start end tags consider headline sched-str marker depth status warnings)."
  (let ((status (nth 9 task))
        (warnings (nth 10 task)))
    (cond
     ((eq status :failed)  (propertize "✗" 'face 'error))
     ((eq status :blocked) (propertize "⊘" 'face 'warning))
     (warnings             (propertize "⚠" 'face 'warning))
     (t                    (propertize "✓" 'face 'success)))))

(defun org-auto-scheduler--check-task-warnings (task marker)
  "Check for scheduling warnings on TASK and return a list of warning strings."
  (let ((warnings nil)
        (time-block (org-auto-scheduler-get-task-tag-block marker))
        (not-before (org-auto-scheduler-get-not-before marker))
        (start (nth 1 task))
        (effort-prop (org-auto-scheduler-get-effort marker)))
    ;; Outside time block?
    (when (and time-block start (not (eq (nth 9 task) :failed)))
      (let ((in-block nil))
        (dolist (block time-block)
          (let ((bs (org-auto-scheduler-time-with-time-string start (car block)))
                (be (org-auto-scheduler-time-with-time-string start (cdr block))))
            (when (and (not (time-less-p start bs))
                       (time-less-p start be))
              (setq in-block t))))
        (unless in-block
          (push "Scheduled outside preferred time block" warnings))))
    ;; NOT_BEFORE constraint was active?
    (when not-before
      (push "📌 NOT_BEFORE constraint" warnings))
    ;; Default effort used?
    (unless effort-prop
      (push "Using default effort estimate" warnings))
    warnings))

(defun org-auto-scheduler--smart-effort-label (marker)
  "Return effort string, appending '[?]' if using default/historical estimate."
  (let ((explicit (org-auto-scheduler-get-effort marker)))
    (if explicit
        (format "%dm" (round explicit))
      (let* ((cat (org-with-point-at marker (org-get-category)))
             (mult (cdr (assoc cat org-auto-scheduler-historical-multipliers)))
             (est (round (* org-auto-scheduler-default-task-duration (or mult 1.0)))))
        (format "%dm[?]" est)))))

(defun org-auto-scheduler--format-time-short (time)
  "Format TIME as 'Mon 09:15' for the review buffer."
  (if time
      (format-time-string "%a %H:%M" time)
    "—"))

(defun org-auto-scheduler--review-push-undo ()
  "Save current entries to undo stack."
  (when tabulated-list-entries
    (push (mapcar (lambda (e) (list (car e) (copy-sequence (cadr e))))
                  tabulated-list-entries)
          org-auto-scheduler--review-undo-stack)
    (when (> (length org-auto-scheduler--review-undo-stack)
             org-auto-scheduler--review-undo-max)
      (setq org-auto-scheduler--review-undo-stack
            (cl-subseq org-auto-scheduler--review-undo-stack 0
                       org-auto-scheduler--review-undo-max)))))

(defun org-auto-scheduler--review-header-line (entries)
  "Build the `header-line-format' string from ENTRIES."
  (let ((total 0) (hours 0.0) (projects (make-hash-table :test 'equal))
        (min-date nil) (max-date nil) (today-count 0)
        (today-str (format-time-string "%Y-%m-%d")))
    (dolist (e entries)
      (let* ((vec (cadr e))
             (id (car e)))
        (unless (string-prefix-p "__sep_" (or id ""))
          (cl-incf total)
          (let* ((dur-str (aref vec 4))
                 (dur (string-to-number dur-str))
                 (proj (aref vec 5))
                 (time-str (aref vec 3)))
            (setq hours (+ hours (/ dur 60.0)))
            (when (and proj (not (string= proj "—")))
              (puthash proj (1+ (gethash proj projects 0)) projects))
            ;; Check if task is today
            (let ((task-data (assoc id org-auto-scheduler-completed-tasks)))
              (when (and task-data (nth 1 task-data))
                (let ((d (format-time-string "%Y-%m-%d" (nth 1 task-data))))
                  (when (string= d today-str) (cl-incf today-count))
                  (when (or (null min-date) (string< d min-date)) (setq min-date d))
                  (when (or (null max-date) (string< max-date d)) (setq max-date d)))))))))
    (let ((proj-legend ""))
      (maphash (lambda (name count)
                 (let ((color (and org-auto-scheduler--project-colors
                                   (gethash name org-auto-scheduler--project-colors))))
                   (setq proj-legend
                         (concat proj-legend
                                 (if color (propertize (format " ● %s(%d)" name count)
                                                       'face `(:foreground ,color))
                                   (format " %s(%d)" name count))))))
               projects)
      (let ((legend (format " %d tasks │ %.1fh │ %d today │%s   [RET]=toggle [K/J]=reorder [r]=recalc [x]=apply [c]=calendar [?]=help"
                            total hours today-count proj-legend)))
        (list "" (or (bound-and-true-p tabulated-list--header-string) "") "   " legend)))))

;;; Interactive Review Mode


(defvar org-auto-scheduler-review-mode-map nil
  "Keymap for `org-auto-scheduler-review-mode'.")

;; Ensure the map is a valid keymap (recovers from previous `nil` state)
(unless (keymapp org-auto-scheduler-review-mode-map)
  (setq org-auto-scheduler-review-mode-map (make-sparse-keymap))
  (set-keymap-parent org-auto-scheduler-review-mode-map tabulated-list-mode-map))

(let ((map org-auto-scheduler-review-mode-map))
  ;; Core operations
  (define-key map (kbd "SPC") #'org-auto-scheduler-review-toggle)
  (define-key map (kbd "RET") #'org-auto-scheduler-review-toggle)
  (define-key map (kbd "m")   #'org-auto-scheduler-review-toggle)
  (define-key map (kbd "TAB") #'org-auto-scheduler-review-jump)
  (define-key map (kbd "x")   #'org-auto-scheduler-review-execute)
  (define-key map (kbd "C-c C-c") #'org-auto-scheduler-review-execute)
  ;; Reorder
  (define-key map (kbd "U")   #'org-auto-scheduler-review-move-up)
  (define-key map (kbd "K")   #'org-auto-scheduler-review-move-up)
  (define-key map (kbd "p")   #'org-auto-scheduler-review-move-up)
  (define-key map (kbd "D")   #'org-auto-scheduler-review-move-down)
  (define-key map (kbd "J")   #'org-auto-scheduler-review-move-down)
  (define-key map (kbd "n")   #'org-auto-scheduler-review-move-down)
  ;; Recalculate / Refresh
  (define-key map (kbd "r")   #'org-auto-scheduler-review-recalculate)
  (define-key map (kbd "C-c C-r") #'org-auto-scheduler-review-recalculate)
  (define-key map (kbd "R")   #'org-auto-scheduler-review-refresh)
  ;; Undo
  (define-key map (kbd "u")   #'org-auto-scheduler-review-undo)
  ;; Filters
  (define-key map (kbd "f t") #'org-auto-scheduler-review-filter-today)
  (define-key map (kbd "f p") #'org-auto-scheduler-review-filter-project)
  (define-key map (kbd "f a") #'org-auto-scheduler-review-filter-clear)
  (define-key map (kbd "/")   #'org-auto-scheduler-review-filter-regexp)
  ;; Bulk operations
  (define-key map (kbd "* a") #'org-auto-scheduler-review-mark-all)
  (define-key map (kbd "* n") #'org-auto-scheduler-review-unmark-all)
  (define-key map (kbd "* t") #'org-auto-scheduler-review-mark-today)
  (define-key map (kbd "* p") #'org-auto-scheduler-review-mark-project)
  (define-key map (kbd "* %") #'org-auto-scheduler-review-mark-regexp)
  ;; What-if
  (define-key map (kbd "e")   #'org-auto-scheduler-review-edit-effort)
  ;; Views
  (define-key map (kbd "v")   #'org-auto-scheduler-review-toggle-calendar)
  (define-key map (kbd "c")   #'org-auto-scheduler-review-toggle-calendar)
  ;; Help
  (define-key map (kbd "?")   #'org-auto-scheduler-review-help))

;; Evil/Spacemacs compatibility: let the full mode map (including the
;; "f" filter and "*" bulk-mark prefixes) win over evil state bindings.
(with-eval-after-load 'evil
  (dolist (state '(normal motion))
    (evil-define-key state org-auto-scheduler-review-mode-map
      (kbd "RET") #'org-auto-scheduler-review-toggle
      (kbd "m")   #'org-auto-scheduler-review-toggle
      (kbd "x")   #'org-auto-scheduler-review-execute
      (kbd "K")   #'org-auto-scheduler-review-move-up
      (kbd "J")   #'org-auto-scheduler-review-move-down
      (kbd "r")   #'org-auto-scheduler-review-recalculate
      (kbd "R")   #'org-auto-scheduler-review-refresh
      (kbd "u")   #'org-auto-scheduler-review-undo
      (kbd "c")   #'org-auto-scheduler-review-toggle-calendar
      (kbd "?")   #'org-auto-scheduler-review-help)))

(define-derived-mode org-auto-scheduler-review-mode tabulated-list-mode "AutoSch-Review"
  "Major mode for reviewing proposed auto-scheduled tasks before applying them."
  (setq tabulated-list-format [("Apply" 5 t)
                               ("●" 2 nil)
                               ("Task" 38 t)
                               ("Time" 20 t)
                               ("Dur" 8 t)
                               ("Project" 18 t)
                               ("Score" 7 t)
                               ("St" 3 nil)])
  (setq tabulated-list-padding 2)
  (setq tabulated-list-sort-key nil)  ; We sort chronologically ourselves in --build-review-entries
  (setq-local revert-buffer-function #'org-auto-scheduler-review-refresh-revert)
  (setq-local org-auto-scheduler--review-overrides (make-hash-table :test 'equal))
  (tabulated-list-init-header))

(defun org-auto-scheduler-review-toggle ()
  "Toggle the apply checkmark for the task at point."
  (interactive)
  (let* ((id (tabulated-list-get-id))
         (entry (tabulated-list-get-entry)))
    (when (and entry id (not (string-prefix-p "__sep_" id)))
      (org-auto-scheduler--review-push-undo)
      (aset entry 0 (if (string= (aref entry 0) "[X]") "[ ]" "[X]"))
      (tabulated-list-print t)
      (forward-line 1))))

(defun org-auto-scheduler-review-jump ()
  "Jump to the original Org task from the review buffer."
  (interactive)
  (let ((task-id (tabulated-list-get-id)))
    (when (and task-id (string-prefix-p "__sep_" task-id))
      (user-error "This is a day separator, not a task"))
    (if task-id
        (let ((marker (org-id-find task-id t)))
          (if marker
              (progn
                (switch-to-buffer-other-window (marker-buffer marker))
                (goto-char marker)
                (org-show-context))
            (user-error "Task marker no longer valid")))
      (user-error "No valid task ID found for this entry"))))

(defun org-auto-scheduler-review-move-up ()
  "Move the current task up in the review list."
  (interactive)
  (let* ((id1 (tabulated-list-get-id))
         (id2 (save-excursion (forward-line -1) (tabulated-list-get-id))))
    (when (and id1 id2
               (not (string-prefix-p "__sep_" id1)))
      (org-auto-scheduler--review-push-undo)
      (let* ((entry1 (tabulated-list-get-entry))
             (entry2 (save-excursion (forward-line -1) (tabulated-list-get-entry)))
             (node1 (assoc id1 tabulated-list-entries))
             (node2 (assoc id2 tabulated-list-entries)))
        (when (and node1 node2)
          (setcdr node1 (list entry2))
          (setcdr node2 (list entry1))
          (setcar node1 id2)
          (setcar node2 id1)
          (setq tabulated-list-sort-key nil)
          (tabulated-list-print t))))))

(defun org-auto-scheduler-review-move-down ()
  "Move the current task down in the review list."
  (interactive)
  (let ((current-id (tabulated-list-get-id)))
    (when (and current-id (not (string-prefix-p "__sep_" current-id)))
      (save-excursion
        (forward-line 1)
        (when (not (eobp))
          (let ((id2 (tabulated-list-get-id)))
            (when id2
              (org-auto-scheduler--review-push-undo)
              (let* ((entry1 (save-excursion (forward-line -1) (tabulated-list-get-entry)))
                     (entry2 (tabulated-list-get-entry))
                     (node1 (assoc current-id tabulated-list-entries))
                     (node2 (assoc id2 tabulated-list-entries)))
                (when (and node1 node2)
                  (setcdr node1 (list entry2))
                  (setcdr node2 (list entry1))
                  (setcar node1 id2)
                  (setcar node2 current-id)))))))
      (setq tabulated-list-sort-key nil)
      (tabulated-list-print t))))

(defun org-auto-scheduler--build-review-entries (tasks)
  "Build tabulated-list-entries from TASKS with day separators and new columns.
TASKS are sorted chronologically by start time before display."
  (setq org-auto-scheduler--project-name-cache nil)
  (org-auto-scheduler--assign-project-colors tasks)
  ;; Sort tasks chronologically by start time so day separators are correct
  (let* ((sorted-tasks (sort (copy-sequence tasks)
                             (lambda (a b)
                               (let ((sa (nth 1 a))
                                     (sb (nth 1 b)))
                                 (cond ((and sa sb) (time-less-p sa sb))
                                       (sa t)
                                       (t nil))))))
         (raw-entries nil) (prev-date nil)
         (today-str (format-time-string "%Y-%m-%d")))
    (dolist (task sorted-tasks)
      (let* ((task-id (nth 0 task))
             (marker (nth 7 task))
             (headline (nth 5 task))
             (start (nth 1 task))
             (end (nth 2 task))
             (status (nth 9 task))
             (depth (nth 8 task))
             (duration (if (and start end (not (memq status '(:failed :blocked :skipped))))
                           (round (/ (float-time (time-subtract end start)) 60)) 0))
             (project-name (or (org-auto-scheduler--get-project-name marker) "—"))
             (proj-trunc (org-auto-scheduler--truncate project-name 18))
             (score (car (org-auto-scheduler-calculate-score marker)))
             (auto-warnings (org-auto-scheduler--check-task-warnings task marker))
             (all-warnings (append (or (nth 10 task) '()) auto-warnings))
             (stat-str (cond ((eq status :failed)  (propertize "✗" 'face 'error))
                             ((eq status :blocked) (propertize "⊘" 'face 'warning))
                             ((eq status :skipped) (propertize "⏸" 'face 'shadow))
                             (all-warnings         (propertize "⚠" 'face 'warning))
                             (t                    (propertize "✓" 'face 'success))))
             (time-str (cond ((eq status :failed)  (propertize "FAILED" 'face 'error))
                             ((eq status :blocked) (propertize "BLOCKED" 'face 'warning))
                             ((eq status :skipped) (propertize "SKIPPED" 'face 'shadow))
                             (start (concat (org-auto-scheduler--format-time-short start) "–"
                                            (format-time-string "%H:%M" end)))
                             (t "—")))
             (dur-str (if (memq status '(:failed :blocked :skipped)) "—"
                        (org-auto-scheduler--smart-effort-label marker)))
             (date-str (if start (format-time-string "%Y-%m-%d" start) "Unknown"))

             (checked (if (memq status '(:failed :blocked :skipped)) "[ ]" "[X]"))
             (is-today (string= date-str today-str))
             (is-blocked (> depth 0))
             (priority (org-with-point-at marker (org-entry-get nil "PRIORITY")))
             (is-high-priority (and priority (string= priority "A")))
             (is-unchecked (string= checked "[ ]"))
             (display-headline (copy-sequence headline)))

        ;; Apply face formatting
        (let ((row-face nil)
              (row-strike nil))
          (when is-blocked
            (setq display-headline (concat "  " display-headline))
            (setq row-face 'warning))
          (when (and (not is-blocked) (not is-today))
            (setq row-face 'shadow))
          (when is-high-priority
            (setq row-face 'bold))
          (when is-unchecked
            (setq row-strike '(:strike-through t)))

          (let ((cols (list checked display-headline time-str dur-str stat-str)))
            (dolist (col cols)
              (when row-face
                (add-face-text-property 0 (length col) row-face nil col))
              (when row-strike
                (add-face-text-property 0 (length col) row-strike t col))))

          ;; Apply project color to the project name
          (let* ((proj-color (and org-auto-scheduler--project-colors
                                  (gethash proj-trunc org-auto-scheduler--project-colors)))
                 (colored-proj (if proj-color
                                   (propertize (copy-sequence proj-trunc) 'face `(:foreground ,proj-color))
                                 (copy-sequence proj-trunc)))
                 (colored-score (copy-sequence (format "%.1f" score))))
            (when row-face
              (add-face-text-property 0 (length colored-proj) row-face nil colored-proj)
              (add-face-text-property 0 (length colored-score) row-face nil colored-score))
            (when row-strike
              (add-face-text-property 0 (length colored-proj) row-strike t colored-proj)
              (add-face-text-property 0 (length colored-score) row-strike t colored-score))

            ;; Day separator
            (unless (equal date-str prev-date)
              (let* ((day-label (if start (format-time-string "-- %A, %b %d " start)
                                  "-- Unknown Date "))
                     (sep-line (concat day-label (make-string (max 0 (- 50 (length day-label))) ?-))))
                (push (list (concat "__sep_" date-str)
                            (vector "" "" (propertize sep-line 'face 'bold) "" "" "" "" ""))
                      raw-entries))
              (setq prev-date date-str))
            (push (list task-id
                        (vector checked
                                (org-auto-scheduler--project-dot proj-trunc)
                                display-headline time-str dur-str
                                colored-proj colored-score stat-str))
                  raw-entries)))))
    (nreverse raw-entries)))

(defun org-auto-scheduler-review-recalculate ()
  "Recalculate scheduled times based on visual order without resorting."
  (interactive)
  (message "Recalculating proposed schedule based on visual order...")
  (let ((ordered-tasks '()))
    (save-excursion
      (goto-char (point-min))
      (while (not (eobp))
        (let* ((task-id (tabulated-list-get-id))
               (entry (tabulated-list-get-entry))
               (checked-state (if entry (aref entry 0) "[X]"))
               (data (and task-id (not (string-prefix-p "__sep_" task-id))
                          (assoc task-id org-auto-scheduler-completed-tasks))))
          (when data (push (cons checked-state data) ordered-tasks)))
        (forward-line 1)))
    (setq ordered-tasks (nreverse ordered-tasks))
    (let ((org-auto-scheduler--preview-mode t)
          (org-auto-scheduler--ignore-blockers-p t)
          (current-time (org-auto-scheduler-get-start-time))
          (previous-project nil))
      (org-auto-scheduler--build-agenda-cache)
      (setq org-auto-scheduler-completed-tasks '())
      (dolist (item ordered-tasks)
        (let* ((checked-state (car item))
               (task (cdr item))
               (marker (nth 7 task))
               (depth (nth 8 task))
               (task-project (org-with-point-at marker
                               (org-auto-scheduler-get-project-id marker))))
          (when (or (not (equal task-project previous-project)) (null task-project))
            (setq current-time (org-auto-scheduler-get-start-time))
            (setq previous-project task-project))
          (if (string= checked-state "[ ]")
              (push (list (nth 0 task) current-time current-time '("AUTOSCH") nil (nth 5 task)
                          "SKIPPED" marker (or depth 0) :skipped '("Unchecked by user"))
                    org-auto-scheduler-completed-tasks)
            (setq current-time
                  (org-auto-scheduler-schedule-single-task marker current-time depth)))))
      (let ((check-map (make-hash-table :test 'equal)))
        (dolist (item ordered-tasks)
          (puthash (nth 0 (cdr item)) (car item) check-map))
        (let ((new-entries (org-auto-scheduler--build-review-entries
                            org-auto-scheduler-completed-tasks)))
          (dolist (entry new-entries)
            (let ((saved (gethash (car entry) check-map)))
              (when saved (aset (cadr entry) 0 saved))))
          (setq tabulated-list-entries new-entries)))
      (setq org-auto-scheduler--review-all-entries (copy-sequence tabulated-list-entries))
      (setq tabulated-list-sort-key nil)
      (tabulated-list-print t)
      (setq header-line-format
            (org-auto-scheduler--review-header-line tabulated-list-entries))
      (message "Recalculation complete!"))))

(defun org-auto-scheduler-review-refresh (&rest _args)
  "Recalculate the auto-schedule from scratch, resetting the view."
  (interactive)
  (org-auto-scheduler-review-and-apply))

(defun org-auto-scheduler-review-refresh-revert (&optional _ignore-auto _noconfirm)
  "Revert function for `org-auto-scheduler-review-mode'."
  (org-auto-scheduler-review-refresh))

(defun org-auto-scheduler-review-execute ()
  "Apply the scheduled times for all checked tasks in the review buffer.
Automatically recalculates dependent times based on visual layout before execution."
  (interactive)
  (org-auto-scheduler-review-recalculate)
  (org-auto-scheduler-create-report-buffer)
  (let ((applied-count 0))
    (save-excursion
      (goto-char (point-min))
      (while (not (eobp))
        (let* ((task-id (tabulated-list-get-id))
               (entry (tabulated-list-get-entry))
               (checked (and entry (string= (aref entry 0) "[X]"))))
          (when (and checked task-id (not (string-prefix-p "__sep_" task-id)))
            (let* ((data (assoc task-id org-auto-scheduler-completed-tasks)))
              (when data
                (let* ((schedule-string (nth 6 data))
                       (marker (nth 7 data))
                       (headline (nth 5 data))
                       (start (nth 1 data))
                       (end (nth 2 data))
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
                  (org-auto-scheduler-add-to-report task-info start)
                  (setq applied-count (1+ applied-count)))))))
        (forward-line 1)))
    (org-auto-scheduler-display-report)
    (message "Applied %d tasks from the auto-scheduler review!" applied-count)
    (kill-buffer (current-buffer))
    (when (and org-auto-scheduler-sync-caldav
               (require 'org-caldav nil t))
      (condition-case err
          (org-caldav-sync)
        (error (message "CalDAV sync failed (review apply): %s" (error-message-string err)))))))

(defun org-auto-scheduler-review-and-apply ()
  "Calculate an auto-schedule in preview mode and display it for interactive review."
  (interactive)
  (message "Calculating proposed schedule...")
  (let ((org-auto-scheduler--preview-mode t))
    (org-auto-scheduler-schedule-tasks))
  (let ((buf (get-buffer-create "*Org Auto Scheduler Review*")))
    (with-current-buffer buf
      (org-auto-scheduler-review-mode)
      (setq org-auto-scheduler--review-view 'table)
      (setq org-auto-scheduler--review-undo-stack nil)
      (setq tabulated-list-entries (org-auto-scheduler--build-review-entries
                                    org-auto-scheduler-completed-tasks))
      (setq org-auto-scheduler--review-all-entries (copy-sequence tabulated-list-entries))
      (tabulated-list-print t)
      (setq header-line-format
            (org-auto-scheduler--review-header-line tabulated-list-entries)))
    (switch-to-buffer buf)))

(defun org-auto-scheduler-review-undo ()
  "Undo the last modification in the review buffer."
  (interactive)
  (if (null org-auto-scheduler--review-undo-stack)
      (user-error "No further undo information")
    (let ((snapshot (pop org-auto-scheduler--review-undo-stack)))
      (setq tabulated-list-entries snapshot)
      (tabulated-list-print t)
      (setq header-line-format
            (org-auto-scheduler--review-header-line tabulated-list-entries))
      (message "Undo!"))))

(defun org-auto-scheduler--apply-current-filter ()
  "Apply the active filter to `tabulated-list-entries`."
  (if (null org-auto-scheduler--review-active-filter)
      (setq tabulated-list-entries (copy-sequence org-auto-scheduler--review-all-entries))
    (let ((filtered nil))
      (dolist (e org-auto-scheduler--review-all-entries)
        (let* ((id (car e))
               (vec (cadr e)))
          (when (or (string-prefix-p "__sep_" id)
                    (funcall org-auto-scheduler--review-active-filter id vec))
            (push e filtered))))
      (let ((cleaned nil) (prev-is-sep nil))
        (dolist (e (nreverse filtered))
          (let ((is-sep (string-prefix-p "__sep_" (car e))))
            (if is-sep
                (unless prev-is-sep
                  (push e cleaned)
                  (setq prev-is-sep t))
              (push e cleaned)
              (setq prev-is-sep nil))))
        (setq tabulated-list-entries (nreverse cleaned)))))
  (tabulated-list-print t)
  (setq header-line-format
        (org-auto-scheduler--review-header-line tabulated-list-entries)))

(defun org-auto-scheduler-review-filter-today ()
  "Filter review list to show only today's tasks."
  (interactive)
  (let ((today-str (format-time-string "%Y-%m-%d")))
    (setq org-auto-scheduler--review-active-filter
          (lambda (id _vec)
            (let ((task-data (assoc id org-auto-scheduler-completed-tasks)))
              (and task-data (nth 1 task-data)
                   (string= (format-time-string "%Y-%m-%d" (nth 1 task-data)) today-str)))))
    (org-auto-scheduler--apply-current-filter)
    (message "Filtered: Today only")))

(defun org-auto-scheduler-review-filter-project ()
  "Filter review list by project."
  (interactive)
  (let* ((projects nil))
    (dolist (e org-auto-scheduler--review-all-entries)
      (let ((proj (aref (cadr e) 5)))
        (when (and proj (not (string= proj "—")) (not (string= proj "")))
          (cl-pushnew proj projects :test #'string=))))
    (if (null projects)
        (message "No projects found to filter by")
      (let ((choice (completing-read "Filter by project: " projects nil t)))
        (setq org-auto-scheduler--review-active-filter
              (lambda (_id vec)
                (string= (aref vec 5) choice)))
        (org-auto-scheduler--apply-current-filter)
        (message "Filtered by project: %s" choice)))))

(defun org-auto-scheduler-review-filter-clear ()
  "Clear any active filter."
  (interactive)
  (setq org-auto-scheduler--review-active-filter nil)
  (org-auto-scheduler--apply-current-filter)
  (message "Filter cleared"))

(defun org-auto-scheduler-review-filter-regexp (regexp)
  "Filter review list by REGEXP matching task headline."
  (interactive "sFilter by regexp: ")
  (if (string= regexp "")
      (org-auto-scheduler-review-filter-clear)
    (setq org-auto-scheduler--review-active-filter
          (lambda (_id vec)
            (string-match-p regexp (substring-no-properties (aref vec 2)))))
    (org-auto-scheduler--apply-current-filter)
    (message "Filtered by regexp: %s" regexp)))

(defun org-auto-scheduler-review-mark-all ()
  "Mark all visible tasks as checked."
  (interactive)
  (org-auto-scheduler--review-push-undo)
  (dolist (e tabulated-list-entries)
    (let ((id (car e)) (vec (cadr e)))
      (unless (string-prefix-p "__sep_" id)
        (aset vec 0 "[X]")
        (aset vec 2 (substring-no-properties (aref vec 2))))))
  (tabulated-list-print t))

(defun org-auto-scheduler-review-unmark-all ()
  "Unmark all visible tasks."
  (interactive)
  (org-auto-scheduler--review-push-undo)
  (dolist (e tabulated-list-entries)
    (let ((id (car e)) (vec (cadr e)))
      (unless (string-prefix-p "__sep_" id)
        (aset vec 0 "[ ]")
        (aset vec 2 (propertize (substring-no-properties (aref vec 2)) 'face 'shadow)))))
  (tabulated-list-print t))

(defun org-auto-scheduler-review-mark-today ()
  "Mark all tasks scheduled for today."
  (interactive)
  (org-auto-scheduler--review-push-undo)
  (let ((today-str (format-time-string "%Y-%m-%d")))
    (dolist (e tabulated-list-entries)
      (let* ((id (car e)) (vec (cadr e))
             (task-data (assoc id org-auto-scheduler-completed-tasks)))
        (when (and task-data (nth 1 task-data)
                   (string= (format-time-string "%Y-%m-%d" (nth 1 task-data)) today-str))
          (aset vec 0 "[X]")
          (aset vec 2 (substring-no-properties (aref vec 2)))))))
  (tabulated-list-print t))

(defun org-auto-scheduler-review-mark-project ()
  "Mark all tasks belonging to a chosen project."
  (interactive)
  (let* ((projects nil))
    (dolist (e tabulated-list-entries)
      (let ((proj (aref (cadr e) 5)))
        (when (and proj (not (string= proj "—")) (not (string= proj "")))
          (cl-pushnew proj projects :test #'string=))))
    (if (null projects)
        (message "No projects found")
      (let ((choice (completing-read "Mark project: " projects nil t)))
        (org-auto-scheduler--review-push-undo)
        (dolist (e tabulated-list-entries)
          (let ((id (car e)) (vec (cadr e)))
            (when (string= (aref vec 5) choice)
              (aset vec 0 "[X]")
              (aset vec 2 (substring-no-properties (aref vec 2))))))
        (tabulated-list-print t)))))

(defun org-auto-scheduler-review-mark-regexp (regexp)
  "Mark all tasks matching REGEXP."
  (interactive "sMark matching regexp: ")
  (when (not (string= regexp ""))
    (org-auto-scheduler--review-push-undo)
    (dolist (e tabulated-list-entries)
      (let ((id (car e)) (vec (cadr e)))
        (when (and (not (string-prefix-p "__sep_" id))
                   (string-match-p regexp (substring-no-properties (aref vec 2))))
          (aset vec 0 "[X]")
          (aset vec 2 (substring-no-properties (aref vec 2))))))
    (tabulated-list-print t)))

(defun org-auto-scheduler-review-edit-effort (new-effort)
  "Edit the estimated effort (in minutes) for the task at point (temporary override)."
  (interactive "nNew effort in minutes: ")
  (let* ((id (tabulated-list-get-id))
         (entry (tabulated-list-get-entry)))
    (if (or (null id) (string-prefix-p "__sep_" id))
        (user-error "Not on a task")
      (org-auto-scheduler--review-push-undo)
      (puthash id (plist-put (gethash id org-auto-scheduler--review-overrides) :effort new-effort)
               org-auto-scheduler--review-overrides)
      (aset entry 4 (propertize (format "%dm*" new-effort) 'face 'warning))
      (tabulated-list-print t)
      (message "Effort updated to %d min (press 'r' to recalculate schedule)" new-effort))))

(defun org-auto-scheduler-review-toggle-calendar ()
  "Toggle between table view and calendar view in the review buffer."
  (interactive)
  (if (eq org-auto-scheduler--review-view 'calendar)
      (progn
        (setq org-auto-scheduler--review-view 'table)
        (let ((inhibit-read-only t))
          (erase-buffer))
        (tabulated-list-init-header)
        (tabulated-list-print t)
        (setq header-line-format
              (org-auto-scheduler--review-header-line tabulated-list-entries))
        (message "Switched to Table View"))
    (setq org-auto-scheduler--review-view 'calendar)
    (org-auto-scheduler--render-calendar-view)))

(defun org-auto-scheduler--render-calendar-view ()
  "Render the calendar view of the proposed schedule."
  (let ((inhibit-read-only t)
        (tasks (cl-remove-if (lambda (t2) (memq (nth 9 t2) '(:failed :blocked)))
                             org-auto-scheduler-completed-tasks)))
    (erase-buffer)
    (setq header-line-format
          (concat " " (propertize "Auto Scheduler Calendar View" 'face 'bold)
                  " │ [v] Table View │ [TAB/RET] Jump to task │ Scroll to navigate"))
    (insert (propertize " Proposed Schedule Calendar View \n" 'face 'org-document-title))
    (insert (propertize "========================================================\n\n" 'face 'shadow))
    (if (null tasks)
        (insert "  No successfully scheduled tasks to display.\n")
      (let ((days-hash (make-hash-table :test 'equal))
            (dates nil))
        (dolist (task tasks)
          (let* ((start (nth 1 task))
                 (date-str (format-time-string "%Y-%m-%d" start)))
            (cl-pushnew date-str dates :test #'string=)
            (puthash date-str (cons task (gethash date-str days-hash)) days-hash)))
        (setq dates (sort dates #'string<))
        (dolist (date-str dates)
          (let* ((day-tasks (nreverse (gethash date-str days-hash)))
                 (min-time (cl-reduce (lambda (a b) (if (time-less-p (nth 1 a) (nth 1 b)) a b)) day-tasks))
                 (max-time (cl-reduce (lambda (a b) (if (time-less-p (nth 2 a) (nth 2 b)) b a)) day-tasks))
                 (start-hour (max 0 (- (string-to-number (format-time-string "%H" (nth 1 min-time))) 1)))
                 (end-hour (min 23 (+ (string-to-number (format-time-string "%H" (nth 2 max-time))) 1)))
                 (parsed-date (nth 1 min-time)))
            (insert (propertize (format " 📅 %s \n" (format-time-string "%A, %B %d, %Y" parsed-date))
                                'face 'bold-italic))
            (insert (propertize " ──────────────────────────────────────────────────────\n" 'face 'shadow))
            (let ((hour start-hour)
                  (minute 0)
                  (last-printed-task-id nil))
              (while (<= hour end-hour)
                (let* ((slot-time (org-auto-scheduler-parse-time-string (format "%s %02d:%02d" date-str hour minute)))
                       (active-task (cl-find-if (lambda (t2)
                                                  (let ((ts (nth 1 t2))
                                                        (te (nth 2 t2)))
                                                    (and (not (time-less-p slot-time ts))
                                                         (time-less-p slot-time te))))
                                                day-tasks)))
                  (insert (format "  %02d:%02d │ " hour minute))
                  (if active-task
                      (let* ((task-id (car active-task))
                             (headline (nth 5 active-task))
                             (marker (nth 7 active-task))
                             (project-name (or (org-auto-scheduler--get-project-name marker) "—"))
                             (proj-trunc (org-auto-scheduler--truncate project-name 18))
                             (color (and org-auto-scheduler--project-colors
                                         (gethash proj-trunc org-auto-scheduler--project-colors)))
                             (bar-char (propertize "█" 'face (if color `(:foreground ,color) 'default))))
                        (insert bar-char " ")
                        (if (equal task-id last-printed-task-id)
                            (insert (propertize "║" 'face (if color `(:foreground ,color) 'shadow)))
                          (setq last-printed-task-id task-id)
                          (let ((start-lbl (format-time-string "%H:%M" (nth 1 active-task)))
                                (end-lbl (format-time-string "%H:%M" (nth 2 active-task))))
                            (insert (propertize (format "[%s] %s (%s–%s)" proj-trunc headline start-lbl end-lbl)
                                                'face (if color `(:foreground ,color) 'default)
                                                'task-id task-id
                                                'mouse-face 'highlight
                                                'help-echo "RET/TAB to jump to task")))))
                    (setq last-printed-task-id nil)
                    (insert (propertize "·" 'face 'shadow)))
                  (insert "\n")
                  (setq minute (+ minute 15))
                  (when (>= minute 60)
                    (setq minute 0)
                    (setq hour (1+ hour))))))
            (insert "\n")))))
    (goto-char (point-min))))

(defun org-auto-scheduler-review-help ()
  "Show help for the review buffer."
  (interactive)
  (with-output-to-temp-buffer "*Org Auto Scheduler Review Help*"
    (with-current-buffer standard-output
      (insert "Org Auto Scheduler Review Mode Keybindings:\n\n")
      (insert "  SPC, m       Toggle application of task at point\n")
      (insert "  TAB, RET     Jump to task in Org file\n")
      (insert "  x, C-c C-c   Apply all checked scheduled times to Org files\n")
      (insert "  U, p         Move task up (manually reorder)\n")
      (insert "  D, n         Move task down (manually reorder)\n")
      (insert "  r, C-c C-r   Recalculate times based on current visual order\n")
      (insert "  R            Refresh/re-run auto-scheduler from scratch\n")
      (insert "  u            Undo last toggle, move, filter, or override\n")
      (insert "  e            Edit estimated effort of task at point (What-If)\n")
      (insert "  v            Toggle between Table View and Calendar View\n\n")
      (insert "Filters (prefix with 'f'):\n")
      (insert "  f t          Show only tasks scheduled for today\n")
      (insert "  f p          Filter tasks by project\n")
      (insert "  f a          Clear active filter\n")
      (insert "  /            Filter by regexp match on headline\n\n")
      (insert "Bulk Marks (prefix with '*'):\n")
      (insert "  * a          Mark all tasks\n")
      (insert "  * n          Unmark/clear all tasks\n")
      (insert "  * t          Mark all tasks scheduled for today\n")
      (insert "  * p          Mark all tasks in a project\n")
      (insert "  * %          Mark all tasks matching a regexp\n"))))

(defun org-auto-scheduler-schedule-today ()
  "Schedule tasks for the remainder of today only."
  (interactive)
  (let ((org-auto-scheduler-max-days-to-check 1))
    (org-auto-scheduler-review-and-apply)))

(defun org-auto-scheduler-dispatch ()
  "Display the command menu for Org Auto Scheduler.
Uses `transient` if available, otherwise falls back to a simple prompt."
  (interactive)
  (if (require 'transient nil t)
      (call-interactively 'org-auto-scheduler-dispatch-menu)
    (let ((choice (read-char-choice
                   (concat "Org Auto Scheduler Menu:\n"
                           " [s] Schedule Tasks\n"
                           " [r] Review & Apply\n"
                           " [t] Schedule Today Only\n"
                           " [c] Score Adherence\n"
                           " [a] Adherence Report\n"
                           " [b] Bump Agenda\n"
                           "Choice: ")
                   '(?s ?r ?t ?c ?a ?b))))
      (cond
       ((eq choice ?s) (call-interactively 'org-auto-scheduler-schedule-tasks))
       ((eq choice ?r) (call-interactively 'org-auto-scheduler-review-and-apply))
       ((eq choice ?t) (call-interactively 'org-auto-scheduler-schedule-today))
       ((eq choice ?c) (call-interactively 'org-auto-scheduler-score-schedule))
       ((eq choice ?a) (call-interactively 'org-auto-scheduler-adherence-report))
       ((eq choice ?b) (call-interactively 'org-auto-scheduler-bump-agenda))))))

(with-eval-after-load 'transient
  (transient-define-prefix org-auto-scheduler-dispatch-menu ()
    "Org Auto Scheduler commands."
    ["Schedule"
     ("s" "Schedule tasks"       org-auto-scheduler-schedule-tasks)
     ("r" "Review & Apply"       org-auto-scheduler-review-and-apply)
     ("t" "Schedule today only"  org-auto-scheduler-schedule-today)]
    ["Adherence"
     ("S" "Snapshot schedule"    org-auto-scheduler-snapshot-schedule)
     ("c" "Score adherence"      org-auto-scheduler-score-schedule)
     ("a" "Adherence report"     org-auto-scheduler-adherence-report)]
    ["Tools"
     ("b" "Bump agenda"          org-auto-scheduler-bump-agenda)
     ("h" "Historical insights"  org-auto-scheduler-historical-insights)
     ("B" "Toggle background"    org-auto-scheduler-toggle-background)]))

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

(defun org-auto-scheduler-score-schedule (&optional target-date no-display)
  "Score performance against a morning's snapshot.
If TARGET-DATE is provided or prompted for, scores that specific day.
When scoring the current day, only considers tasks whose expected
start time is in the past.
If NO-DISPLAY is non-nil, suppresses the graphical output."
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
         (clock-intervals (org-auto-scheduler-get-clock-intervals score-date))
         (total-effort 0.0)
         (earned-effort 0.0)
         (total-overlap-mins 0.0)
         (punctuality-earned 0.0)
         (weighted-earned 0.0)
         (weighted-total 0.0)
         (tasks-results nil)
         (cat-stats (make-hash-table :test 'equal))
         (postponed-tasks 0)
         (unplanned-tasks nil)
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

          (let ((task-val 1.0)
                (overlap-mins 0.0)
                (punctual-mult 1.0))
            (if marker
                (progn
                  ;; Get task score for priority weighting
                  (let ((score-info (org-auto-scheduler-calculate-score marker)))
                    (setq task-val (max 1.0 (car score-info))))

                  ;; Calculate overlap and punctuality from clock intervals
                  (when scheduled-time
                    (let* ((plan-start (org-time-string-to-time scheduled-time))
                           (plan-end (time-add plan-start (seconds-to-time (* effort 60))))
                           (first-start nil))
                      (dolist (interval clock-intervals)
                        (when (equal (nth 1 interval) id)
                          (let* ((actual-start (nth 2 interval))
                                 (actual-end (nth 3 interval)))
                            ;; Track earliest start
                            (unless first-start (setq first-start actual-start))
                            ;; Add overlap — compute the intersection of [plan-start,plan-end] and [actual-start,actual-end]
                            (let* ((overlap-start (max (float-time plan-start) (float-time actual-start)))
                                   (overlap-end (min (float-time plan-end) (float-time actual-end)))
                                   (overlap-duration (max 0.0 (- overlap-end overlap-start))))
                              (when (> overlap-duration 0)
                                (cl-incf overlap-mins (/ overlap-duration 60.0)))))))
                      ;; Calculate punctuality multiplier
                      (when first-start
                        (let ((variance-mins (/ (abs (float-time (time-subtract first-start plan-start))) 60.0)))
                          (if (<= variance-mins 15.0)
                              (setq punctual-mult 1.0)
                            ;; Lose 0.1 for every 30 mins late/early past 15 min buffer
                            (setq punctual-mult (max 0.5 (- 1.0 (* (ffloor (/ (- variance-mins 15.0) 30.0)) 0.1)))))))))

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

            ;; Update multi-score totals
            (setq earned-effort (+ earned-effort earned))
            (setq total-overlap-mins (+ total-overlap-mins (min (float effort) overlap-mins)))
            (setq punctuality-earned (+ punctuality-earned (* earned punctual-mult)))
            (setq weighted-earned (+ weighted-earned (* earned task-val)))
            (setq weighted-total (+ weighted-total (* effort task-val)))

            (let ((cat-data (gethash category cat-stats)))
              (setcar (cdr cat-data) (+ (cadr cat-data) earned))))

          ;; Postponement Check (was it in yesterday's snapshot?)
          (let ((was-yesterday (cl-find-if (lambda (yt) (equal (plist-get yt :id) id)) yesterday-snapshot)))
            (when (and was-yesterday (not is-done))
              (cl-incf postponed-tasks)))

          ;; Track Missed Tasks for Time of Day Analysis
          ;; Only add if not already recorded as a rescheduled task (3-element list)
          (let ((already-rescheduled (cl-find-if (lambda (m) (and (= (length m) 3) (string= (nth 0 m) heading))) missed-tasks)))
            (when (and (not is-done) (not already-rescheduled) (< (/ earned effort) 0.8) has-passed)
              (push (list heading scheduled-time clocked effort category) missed-tasks)))

          (push (list heading earned effort is-done) tasks-results))))

    ;; 2. Unplanned Tasks Check - collect detailed info
    (org-map-entries
     (lambda ()
       (when (member (org-get-todo-state) org-done-keywords)
         (let* ((id (org-id-get))
                (in-snapshot (cl-find-if (lambda (t-snap) (equal (plist-get t-snap :id) id)) snapshot)))
           (unless in-snapshot
             (let ((closed-ts (org-entry-get (point) "CLOSED")))
               (when (and closed-ts (string= (substring closed-ts 1 11) score-date))
                 (let* ((heading (org-get-heading t t t t))
                        (effort (or (org-auto-scheduler-get-effort (point-marker)) 0))
                        (clocked (org-auto-scheduler-get-clocked-time (point-marker)))
                        (category (or (org-get-category) "Uncategorized")))
                   (push (list heading id effort clocked category) unplanned-tasks))))))))
     nil 'agenda)

    (let* ((score (if (> total-effort 0) (* (/ earned-effort total-effort) 100.0) 100.0))
           (true-adherence (if (> total-effort 0) (* (/ total-overlap-mins total-effort) 100.0) 100.0))
           (punctuality-score (if (> total-effort 0) (* (/ punctuality-earned total-effort) 100.0) 100.0))
           (weighted-score (if (> weighted-total 0) (* (/ weighted-earned weighted-total) 100.0) 100.0))
           (score-data (list :score score
                             :true-adherence true-adherence
                             :punctuality-score punctuality-score
                             :weighted-score weighted-score
                             :total-effort total-effort
                             :earned-effort earned-effort
                             :postponed postponed-tasks
                             :unplanned (length unplanned-tasks)
                             :unplanned-tasks unplanned-tasks
                             :categories cat-stats
                             :missed missed-tasks))
           (history-entry (assoc score-date org-auto-scheduler--adherence-history)))

      ;; Update History
      (if history-entry
          (setcdr history-entry score-data)
        (push (cons score-date score-data) org-auto-scheduler--adherence-history))

      (org-auto-scheduler-save-adherence)
      (unless no-display
        (with-current-buffer (get-buffer-create "*Org Auto Scheduler Scores*")
          (let ((inhibit-read-only t))
            (erase-buffer))
          (org-auto-scheduler-report-mode)
          (let ((inhibit-read-only t))
            (insert (propertize (format " Daily Schedule Adherence - %s \n" score-date) 'face 'org-document-title))
            (insert (make-string 50 ?=) "\n\n")

            ;; 1. Global Score Overview
            (let* ((streak (org-auto-scheduler-get-adherence-streak))
                   (get-color (lambda (s) (cond ((>= s 90) "green")
                                                ((>= s 70) "orange")
                                                (t "red")))))
              (insert (format "Pure Effort:       %s\n"
                              (propertize (format "%5.1f%%" score) 'face `(:foreground ,(funcall get-color score) :weight bold))))
              (insert (format "True Adherence:    %s\n"
                              (propertize (format "%5.1f%%" true-adherence) 'face `(:foreground ,(funcall get-color true-adherence) :weight bold))))
              (insert (format "Punctuality Score: %s\n"
                              (propertize (format "%5.1f%%" punctuality-score) 'face `(:foreground ,(funcall get-color punctuality-score) :weight bold))))
              (insert (format "Weighted Effort:   %s\n\n"
                              (propertize (format "%5.1f%%" weighted-score) 'face `(:foreground ,(funcall get-color weighted-score) :weight bold))))

              (insert (format "Current Streak: %d days 🔥\n" streak))
              (insert (format "Effort: %.1fh planned, %.1fh earned\n\n"
                              (/ total-effort 60.0)
                              (/ earned-effort 60.0))))

            ;; 2. Category Breakdown
            (insert (propertize " Category Breakdown \n" 'face 'org-level-1))
            (insert (make-string 30 ?-) "\n")
            (if (and cat-stats (> (hash-table-count cat-stats) 0))
                (maphash (lambda (cat stats)
                           (let* ((total (car stats))
                                  (earned (cadr stats))
                                  (cat-score (if (> total 0) (* (/ earned total) 100.0) 100.0)))
                             (insert (format "%-15s : %6.1f%% (Planned: %.1fh, Earned: %.1fh)\n"
                                             cat cat-score (/ total 60.0) (/ earned 60.0)))))
                         cat-stats)
              (insert "No categories tracked.\n"))
            (insert "\n")

            ;; 4. Time of Day Analysis / Missed Tasks
            (when missed-tasks
              (insert (propertize " Missed or Rescheduled Tasks \n" 'face 'org-level-1))
              (insert (make-string 30 ?-) "\n")
              (dolist (m missed-tasks)
                (if (= (length m) 3)
                    ;; It's a rescheduled task - find ID from snapshot
                    (let* ((heading (nth 0 m))
                           (old (nth 1 m))
                           (new (nth 2 m))
                           (snap-task (cl-find-if (lambda (s) (string= (plist-get s :heading) heading)) snapshot))
                           (task-id (and snap-task (plist-get snap-task :id))))
                      (insert "[Rescheduled] ")
                      (if task-id
                          (org-auto-scheduler--insert-linked-heading heading task-id)
                        (insert heading))
                      (insert (format "\n  From: %s\n  To:   %s\n" old new)))
                  ;; It's a standard missed task
                  (let* ((heading (nth 0 m))
                         (time (nth 1 m))
                         (clocked (nth 2 m))
                         (effort (nth 3 m))
                         (cat (nth 4 m))
                         (snap-task (cl-find-if (lambda (s) (string= (plist-get s :heading) heading)) snapshot))
                         (task-id (and snap-task (plist-get snap-task :id))))
                    (let ((time-str (if (and time (string-match "\\([0-9]\\{2\\}:[0-9]\\{2\\}\\)" time))
                                        (match-string 1 time)
                                      "Unscheduled")))
                      (insert (format "[%-5s] " time-str))
                      (if task-id
                          (org-auto-scheduler--insert-linked-heading heading task-id)
                        (insert heading))
                      (insert (format " | Effort: %dm, Clocked: %dm\n" effort clocked))))))
              (insert "\n"))

            ;; 5. Postponed & Unplanned Warnings
            (when (or (> postponed-tasks 0) (> (length unplanned-tasks) 0))
              (insert (propertize " Warnings \n" 'face 'org-level-1))
              (insert (make-string 30 ?-) "\n")
              (when (> postponed-tasks 0)
                (insert (format "⚠️ You have %d tasks that rolled over from yesterday.\n" postponed-tasks)))
              (when (> (length unplanned-tasks) 0)
                (insert (format "⚠️ The \"Squirrel!\" Penalty: You completed %d unplanned tasks today:\n" (length unplanned-tasks)))
                (dolist (ut unplanned-tasks)
                  (let ((heading (nth 0 ut))
                        (task-id (nth 1 ut))
                        (effort (nth 2 ut))
                        (clocked (nth 3 ut))
                        (category (nth 4 ut)))
                    (insert "  • ")
                    (if task-id
                        (org-auto-scheduler--insert-linked-heading heading task-id)
                      (insert heading))
                    (insert (format " [%s] Clocked: %dm\n" category clocked)))))
              (insert "\n"))

            ;; 6. Hall of Fame (Past Bests)
            (let ((best-week 0.0) (best-week-date "")
                  (best-month 0.0) (best-month-date "")
                  (best-year 0.0) (best-year-date ""))
              (dolist (entry org-auto-scheduler--adherence-history)
                (let* ((d-str (car entry))
                       (entry-data (cdr entry))
                       (entry-score (plist-get entry-data :score))
                       (entry-time (org-auto-scheduler-parse-time-string (concat d-str " 12:00")))
                       (days-ago (and entry-time (time-to-days (time-subtract current-time entry-time)))))
                  (when days-ago
                    ;; Week
                    (when (and (<= days-ago 7) (> entry-score best-week))
                      (setq best-week entry-score)
                      (setq best-week-date d-str))
                    ;; Month
                    (when (and (<= days-ago 30) (> entry-score best-month))
                      (setq best-month entry-score)
                      (setq best-month-date d-str))
                    ;; Year
                    (when (and (<= days-ago 365) (> entry-score best-year))
                      (setq best-year entry-score)
                      (setq best-year-date d-str)))))
              (when (> best-week 0)
                (insert (propertize " 🏆 Hall of Fame (Past Bests) \n" 'face 'org-level-1))
                (insert (make-string 30 ?-) "\n")
                (insert (format "Best Last 7 Days:  %6.1f%% (%s)\n" best-week best-week-date))
                (insert (format "Best Last 30 Days: %6.1f%% (%s)\n" best-month best-month-date))
                (insert (format "Best Last 1 Year:  %6.1f%% (%s)\n" best-year best-year-date))
                (insert "\n")))

            ;; 7. Historical Multipliers
            (when org-auto-scheduler-historical-multipliers
              (insert (propertize " Estimation vs Reality (Historical Multipliers) \n" 'face 'org-level-1))
              (insert (make-string 30 ?-) "\n")
              (dolist (m org-auto-scheduler-historical-multipliers)
                (insert (format "%-15s : %5.2fx (meaning tasks take %s time than estimated)\n"
                                (car m) (cdr m)
                                (if (> (cdr m) 1.2) "more" (if (< (cdr m) 0.8) "less" "about the same"))))))

            ;; 7. Compact Gantt Timeline
            (when snapshot
              (org-auto-scheduler--render-compact-gantt score-date snapshot))

            ;; 8. 30-Day Trend (2x2 Grid at bottom)
            (insert (propertize " 📈 30-Day Trend \n" 'face 'org-level-1))
            (insert (make-string 30 ?-) "\n")

            (let ((graph1 (org-auto-scheduler--get-bar-graph-lines "Pure Effort" :score score-date))
                  (graph2 (org-auto-scheduler--get-bar-graph-lines "True Adherence" :true-adherence score-date))
                  (graph3 (org-auto-scheduler--get-bar-graph-lines "Punctuality" :punctuality-score score-date))
                  (graph4 (org-auto-scheduler--get-bar-graph-lines "Weighted Score" :weighted-score score-date)))
              ;; Top row (Effort, Adherence)
              (dotimes (i 14)
                (insert (nth i graph1) "  " (nth i graph2) "\n"))
              (insert "\n")
              ;; Bottom row (Punctuality, Weighted)
              (dotimes (i 14)
                (insert (nth i graph3) "  " (nth i graph4) "\n")))

            (goto-char (point-min)))
          (display-buffer (current-buffer))))
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

;;; Adherence Report Mode (TAB / RET jump-to-task)

(defvar org-auto-scheduler-report-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (define-key map (kbd "TAB") #'org-auto-scheduler-report-jump-to-task)
    (define-key map (kbd "RET") #'org-auto-scheduler-report-jump-to-task)
    map)
  "Keymap for `org-auto-scheduler-report-mode`.")

(define-derived-mode org-auto-scheduler-report-mode special-mode "AutoSch-Report"
  "Major mode for viewing the adherence report with TAB/RET jump-to-task.")

(defun org-auto-scheduler-report-jump-to-task ()
  "Jump to the Org task under point using the `org-id` text property."
  (interactive)
  (let ((task-id (get-text-property (point) 'org-id)))
    (if task-id
        (let ((marker (org-id-find task-id t)))
          (if marker
              (progn
                (switch-to-buffer-other-window (marker-buffer marker))
                (goto-char marker)
                (org-show-context))
            (user-error "Cannot find task with ID %s" task-id)))
      (user-error "No task link at point"))))

(defun org-auto-scheduler--insert-linked-heading (heading task-id)
  "Insert HEADING with an `org-id` text property set to TASK-ID.
This enables TAB/RET navigation from the report buffer."
  (let ((start (point)))
    (insert (propertize heading
                        'org-id task-id
                        'face 'link
                        'mouse-face 'highlight))))

;;; Clock interval extraction for timeline

(defun org-auto-scheduler-get-clock-intervals (date-str)
  "Return a list of (HEADING ID START-TIME END-TIME) for all CLOCK entries on DATE-STR.
Scans all org-agenda-files for CLOCK lines matching the target date."
  (let ((intervals nil))
    (dolist (file (org-agenda-files))
      (with-current-buffer (find-file-noselect file)
        (org-with-wide-buffer
         (goto-char (point-min))
         (while (re-search-forward
                 "^[ \t]*CLOCK: \\[\\([^]]+\\)\\]--\\[\\([^]]+\\)\\]" nil t)
           (let* ((start-str (match-string 1))
                  (end-str (match-string 2))
                  (start-time (org-auto-scheduler-parse-time-string start-str))
                  (end-time (org-auto-scheduler-parse-time-string end-str))
                  (start-date (format-time-string "%Y-%m-%d" start-time)))
             (when (string= start-date date-str)
               (save-excursion
                 (org-back-to-heading t)
                 (let ((heading (org-get-heading t t t t))
                       (id (org-id-get)))
                   (push (list heading id start-time end-time) intervals)))))))))
    (sort intervals (lambda (a b) (time-less-p (nth 2 a) (nth 2 b))))))

;;; Compact Gantt Timeline Rendering

(defun org-auto-scheduler--time-to-day-minutes (time-val)
  "Convert TIME-VAL to minutes since midnight of that day."
  (let* ((decoded (decode-time time-val))
         (hour (nth 2 decoded))
         (minute (nth 1 decoded)))
    (+ (* hour 60) minute)))

(defun org-auto-scheduler--render-gantt-row (label intervals chunk-start-min chunk-end-min chars-per-min date-str legend-hash)
  "Render a single Gantt row for LABEL (e.g. \"Planned\", \"Actual\").
INTERVALS is a list of (HEADING ID START-TIME END-TIME).
CHUNK-START-MIN and CHUNK-END-MIN are minute offsets from midnight.
CHARS-PER-MIN is the character resolution (e.g. 0.2 = 1 char per 5 min).
DATE-STR is the target date for clamping.
LEGEND-HASH maps task IDs to short numbers strings for display."
  (let* ((chunk-width (round (* (- chunk-end-min chunk-start-min) chars-per-min)))
         (row (make-string chunk-width ?\s)))
    ;; Fill in each interval
    (dolist (interval intervals)
      (let* ((start-min (org-auto-scheduler--time-to-day-minutes (nth 2 interval)))
             (end-min (org-auto-scheduler--time-to-day-minutes (nth 3 interval)))
             ;; Clamp to chunk boundaries
             (clamped-start (max start-min chunk-start-min))
             (clamped-end (min end-min chunk-end-min))
             (heading (nth 0 interval))
             (id (nth 1 interval)))
        (when (> clamped-end clamped-start)
          (let* ((col-start (round (* (- clamped-start chunk-start-min) chars-per-min)))
                 (col-end (round (* (- clamped-end chunk-start-min) chars-per-min)))
                 (safe-start (max 0 (min col-start (1- chunk-width))))
                 (safe-end (max (1+ safe-start) (min col-end chunk-width)))
                 (block-len (- safe-end safe-start))
                 (legend-val (if id (gethash id legend-hash (list heading nil)) (list heading nil)))
                 (legend-id (if (stringp legend-val) legend-val (car legend-val)))
                 (block-color (if (stringp legend-val) nil (cadr legend-val)))
                 ;; Truncate heading to fit
                 (display-name (if (> (length legend-id) (- block-len 2))
                                   (if (> block-len 4)
                                       (concat (substring legend-id 0 (- block-len 3)) "..")
                                     (make-string block-len ?=))
                                 legend-id))
                 ;; Pad name within block
                 (pad-len (max 0 (- block-len (length display-name) 2)))
                 (pad-left (/ pad-len 2))
                 (pad-right (- pad-len pad-left))
                 (raw-padded (concat "[" (make-string pad-left ?=) display-name (make-string pad-right ?=) "]"))
                 (padded (if block-color (propertize raw-padded 'face `(:foreground ,block-color)) raw-padded)))
            ;; Continuation markers for tasks spanning chunk boundaries
            (when (< start-min chunk-start-min)
              (aset row safe-start ?<))
            (when (> end-min chunk-end-min)
              (when (< (1- safe-end) chunk-width)
                (aset row (1- safe-end) ?>)))
            ;; Write the block into the row
            (let ((write-str (substring raw-padded 0 (min (length raw-padded) block-len))))
              (dotimes (i (min (length write-str) (- chunk-width safe-start)))
                (let ((char (aref write-str i)))
                  ;; If it's a visible char, inject it with properties directly if colored
                  (if block-color
                      (put-text-property (+ safe-start i) (+ safe-start i 1)
                                         'face block-color row))
                  (aset row (+ safe-start i) char))))))))
    (insert (format "%-8s %s\n" label row))))

(defun org-auto-scheduler--render-timeline-header (chunk-start-min chunk-end-min chars-per-min)
  "Insert a timeline header with hour markers.
CHUNK-START-MIN and CHUNK-END-MIN are minute offsets from midnight."
  (let* ((chunk-width (round (* (- chunk-end-min chunk-start-min) chars-per-min)))
         (header (make-string chunk-width ?\s))
         (ruler (make-string chunk-width ?\s)))
    ;; Place hour labels and tick marks
    (let ((hour-start (/ chunk-start-min 60)))
      (cl-loop for hour from hour-start to (/ chunk-end-min 60)
               for col = (round (* (- (* hour 60) chunk-start-min) chars-per-min))
               when (and (>= col 0) (< col chunk-width))
               do (let ((label (format "%02d:00" hour)))
                    ;; Write hour label into header
                    (dotimes (i (min (length label) (- chunk-width col)))
                      (aset header (+ col i) (aref label i)))
                    ;; Write tick mark into ruler
                    (aset ruler col ?|))))
    (insert (format "%-8s %s\n" "" header))
    (insert (format "%-8s %s\n" "" ruler))))

(defun org-auto-scheduler--render-compact-gantt (date-str snapshot)
  "Render the compact chunked Gantt timeline for DATE-STR.
SNAPSHOT is the planned schedule snapshot for the day.
Clocked intervals are extracted from the org files."
  (let* ((chunk-hours 4)        ;; 4-hour chunks
         (chars-per-min (/ 1.0 5))  ;; 1 char per 5 minutes => 12 chars/hour
         ;; Parse start/end times from the customization
         (start-minutes (org-duration-to-minutes org-auto-scheduler-start-time))
         (end-minutes (org-duration-to-minutes org-auto-scheduler-end-time))
         ;; Build planned intervals from snapshot
         (planned-intervals nil)
         ;; Get actual clocked intervals
         (clocked-intervals (org-auto-scheduler-get-clock-intervals date-str))
         (date-time (org-auto-scheduler-parse-time-string (concat date-str " 00:00")))
         (legend-hash (make-hash-table :test 'equal))
         (legend-list nil)
         (legend-counter 1)
         (colors '(font-lock-keyword-face
                   font-lock-type-face
                   font-lock-string-face
                   font-lock-variable-name-face
                   font-lock-function-name-face
                   font-lock-constant-face
                   font-lock-builtin-face
                   font-lock-warning-face))
         (color-idx 0))
    ;; Build planned intervals from snapshot
    (dolist (task snapshot)
      (let* ((heading (plist-get task :heading))
             (id (plist-get task :id))
             (effort (or (plist-get task :effort) 30))
             (scheduled-str (plist-get task :scheduled))
             (scheduled-time (when scheduled-str (org-time-string-to-time scheduled-str)))
             (scheduled-date (when scheduled-time (format-time-string "%Y-%m-%d" scheduled-time))))
        (when (and scheduled-time (string= scheduled-date date-str))
          (let ((end-time (time-add scheduled-time (seconds-to-time (* effort 60)))))
            (push (list heading id scheduled-time end-time) planned-intervals)))))
    (setq planned-intervals (sort planned-intervals (lambda (a b) (time-less-p (nth 2 a) (nth 2 b)))))

    ;; Build legend hash before rendering with colors
    (dolist (interval (append planned-intervals clocked-intervals))
      (let ((heading (nth 0 interval))
            (id (nth 1 interval)))
        (when (and id (not (gethash id legend-hash)))
          (let* ((legend-id (number-to-string legend-counter))
                 (assigned-color (nth (% color-idx (length colors)) colors)))
            (puthash id (list legend-id assigned-color) legend-hash)
            (push (list legend-id heading id assigned-color) legend-list)
            (cl-incf legend-counter)
            (cl-incf color-idx)))))
    (setq legend-list (nreverse legend-list))

    (insert (propertize " 📊 Daily Timeline \n" 'face 'org-level-1))
    (insert (make-string 30 ?-) "\n")
    (when (and (null planned-intervals) (null clocked-intervals))
      (insert "No timeline data available.\n\n")
      (cl-return-from org-auto-scheduler--render-compact-gantt nil))

    ;; Render chunk by chunk (Explicitly 06:00 - 12:00, 12:00 - 18:00, 18:00 - 24:00)
    (let ((chunks '((360 720) (720 1080) (1080 1440))))
      (dolist (chunk chunks)
        (let ((chunk-start (car chunk))
              (chunk-end (cadr chunk)))
          ;; Header with hour markers
          (org-auto-scheduler--render-timeline-header chunk-start chunk-end chars-per-min)
          ;; Planned row
          (org-auto-scheduler--render-gantt-row "Planned" planned-intervals chunk-start chunk-end chars-per-min date-str legend-hash)
          ;; Actual row
          (org-auto-scheduler--render-gantt-row "Actual" clocked-intervals chunk-start chunk-end chars-per-min date-str legend-hash)
          (insert "\n"))))
    (insert "\n")
    ;; Render Legend
    (when legend-list
      (insert (propertize " Timeline Legend \n" 'face 'org-level-2))
      (insert (make-string 30 ?-) "\n")
      (dolist (item legend-list)
        (let* ((legend-id (nth 0 item))
               (heading (nth 1 item))
               (id (nth 2 item))
               (color (nth 3 item))
               ;; Since color is a face symbol (e.g., 'font-lock-keyword-face), we use it directly
               (fmt-legend-id (if color (propertize (format " [%2s] " legend-id) 'face color)
                                (format " [%2s] " legend-id))))
          (insert fmt-legend-id)
          (if id
              (let ((start (point)))
                (insert (propertize heading
                                    'org-id id
                                    'face (if color `(:inherit ,color :underline t) 'link)
                                    'mouse-face 'highlight)))
            (insert (if color (propertize heading 'face color) heading)))
          (insert "\n")))
      (insert "\n"))))

;;; Adherence Report

(defun org-auto-scheduler--get-bar-graph-lines (label property target-date-str)
  "Return a list of strings representing a 10-row high bar graph for LABEL.
Extracts PROPERTY from history ending at TARGET-DATE-STR.
Normalizes the Y-axis based on the maximum score in the 30-day window."
  (let* ((days 30)
         (target-time (org-auto-scheduler-parse-time-string (concat target-date-str " 12:00")))
         (values nil)
         ;; Unicode blocks:   ▂ ▃ ▄ ▅ ▆ ▇ █ (8 levels, plus space for 0)
         (bars [" " " " "▂" "▃" "▄" "▅" "▆" "▇" "█"])
         (latest-val 0.0)
         (lines nil))
    ;; Collect last 30 days of data
    (dotimes (i days)
      (let* ((date-time (time-subtract target-time (days-to-time (- (1- days) i))))
             (date-str (format-time-string "%Y-%m-%d" date-time))
             (entry (assoc date-str org-auto-scheduler--adherence-history))
             (val (if entry (or (plist-get (cdr entry) property) (plist-get (cdr entry) :score) 0.0) 0.0)))
        (push val values)
        (when (= i (1- days))
          (setq latest-val val))))
    (setq values (nreverse values))

    ;; Build output array
    (let* ((color (cond ((>= latest-val 90) "green")
                        ((>= latest-val 70) "orange")
                        (t "red")))
           (actual-max (apply #'max values))
           (max-val (max 10.0 (* 10.0 (ceiling (/ actual-max 10.0)))))
           (rows 10))

      ;; Header lines
      (push (format "%-25s (Last 30 Days)" label) lines)
      (push (make-string 38 ?-) lines)

      ;; Graph lines
      (dotimes (r rows)
        (let* ((level (- rows r))
               (threshold (* (/ max-val rows) level))
               (prev-threshold (* (/ max-val rows) (1- level)))
               (y-label (format "%4s | " (format "%d%%" (round threshold))))
               (row-str y-label))
          ;; Build the row string horizontally
          (dolist (val values)
            (let ((char (cond ((>= val threshold) "█")
                              ((and (< val threshold) (> val prev-threshold))
                               (let* ((fraction (/ (float (- val prev-threshold)) (float (- threshold prev-threshold))))
                                      (idx (max 0 (min 8 (round (* fraction 8))))))
                                 (aref bars idx)))
                              (t " "))))
              (setq row-str (concat row-str (propertize char 'face `(:foreground ,color))))))
          (push row-str lines)))

      ;; X-axis
      (push (concat "       +" (make-string days ?-)) lines)
      (push " " lines))

    (nreverse lines)))

(defun org-auto-scheduler-adherence-generate ()
  "Recalculate adherence scores silently for all available snapshot dates."
  (interactive)
  (let ((count 0))
    (dolist (snap org-auto-scheduler--adherence-snapshots)
      (org-auto-scheduler-score-schedule (car snap) t)
      (cl-incf count))
    (message "Successfully regenerated adherence scores for %d days." count)))

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
