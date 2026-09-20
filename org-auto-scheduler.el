;;; org-auto-scheduler.el --- Auto task scheduler for Org -*- lexical-binding: t; -*-

;; Copyright (C) 2024-2026 SSD2019

;; Author: SSD2019 <santosh.dayapule@gmail.com>
;; URL: https://github.com/SSD2019/org-auto-scheduler
;; Version: 0.1.0
;; Package-Requires: ((emacs "27.1") (log4e "0.3.0"))
;; Keywords: org, calendar, convenience
;; License: GPL-3.0-or-later

;; This file is not part of GNU Emacs.

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Org Auto Scheduler automatically scores tasks by priority, deadline,
;; effort, state, and category; topologically sorts them via
;; dependency-aware Kahn's algorithm; and packs them into available time
;; windows while respecting time blocks, repeater conflicts, and blockers.

;;; Code:

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
(require 'color)



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

(defcustom org-auto-scheduler-splittable-tag "SPLITTABLE"
  "Tag used to mark a task as splittable across days/time windows."
  :type 'string
  :group 'org-auto-scheduler)

(defcustom org-auto-scheduler-placeholder-tag "AUTOSCH_PLACEHOLDER"
  "Tag used to mark temporary placeholder tasks for remaining split effort."
  :type 'string
  :group 'org-auto-scheduler)

(defcustom org-auto-scheduler-split-min-chunk 30
  "Minimum chunk duration in minutes required to split a task today.
If available time today is less than this value, the task is deferred
to the next day in its entirety rather than being split into small fragments."
  :type 'integer
  :group 'org-auto-scheduler)

(defcustom org-auto-scheduler-placeholder-suffix "(Remaining)"
  "Suffix appended to headline for temporary remaining placeholder subtasks."
  :type 'string
  :group 'org-auto-scheduler)

(defcustom org-auto-scheduler-split-property "SPLITTABLE"
  "Org headline property used to mark a task as splittable."
  :type 'string
  :group 'org-auto-scheduler)

(defvaralias 'org-auto-scheduler-splittable-property 'org-auto-scheduler-split-property
  "Alias for `org-auto-scheduler-split-property'.")

(defcustom org-auto-scheduler-min-chunk-property "MIN_CHUNK"
  "Org headline property to override minimum chunk duration in minutes."
  :type 'string
  :group 'org-auto-scheduler)

(defcustom org-auto-scheduler-pinnable-tag "PINNABLE"
  "Tag used to mark a task as pinnable to a specific time."
  :type 'string
  :group 'org-auto-scheduler)

(defcustom org-auto-scheduler-pinnable-property "PINNABLE"
  "Org headline property used to mark a task as pinnable."
  :type 'string
  :group 'org-auto-scheduler)

(defcustom org-auto-scheduler-pinned-time-property "PINNED_TIME"
  "Org headline property storing the pinned start time for a task."
  :type 'string
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

(defcustom org-auto-scheduler-review-show-agenda-events t
  "If non-nil, display existing fixed agenda events (non-AUTOSCH) in the review buffer."
  :type 'boolean
  :group 'org-auto-scheduler)

(defcustom org-auto-scheduler-review-compact-schedule t
  "If non-nil, `org-auto-scheduler-review-recalculate' packs tasks continuously,
allowing tasks to automatically fill available time slots on earlier days.
When nil, tasks are constrained to start on or after the day section they appear under.
Can be inverted per-invocation with a prefix argument (C-u r)."
  :type 'boolean
  :group 'org-auto-scheduler)

(defcustom org-auto-scheduler-review-dim-future-days nil
  "If non-nil, dim tasks scheduled for future days using the shadow face.
When nil (recommended), all tasks retain full clarity and vibrant project colors."
  :type 'boolean
  :group 'org-auto-scheduler)

(defcustom org-auto-scheduler-review-auto-recalculate-on-move t
  "If non-nil, reordering a task in the review buffer recalculates times.
Applies to `org-auto-scheduler-review-move-up',
`org-auto-scheduler-review-move-down', `org-auto-scheduler-review-move-before',
and the day-shifting commands: the schedule is immediately recalculated
(as if \"r\" were pressed) so moved tasks never overlap.  When nil, moving a
task only reorders the list and you must press \"r\" to recalculate, as
before."
  :type 'boolean
  :group 'org-auto-scheduler)

(defcustom org-auto-scheduler-review-timegrid-integration nil
  "If non-nil, offer a visual time-grid view of the proposed schedule.
When enabled, `org-auto-scheduler-review-open-timegrid' (bound to \"T\" in
the review buffer) renders the currently proposed schedule using the
`org-timegrid' package (https://github.com/Gleek/org-timegrid), a
read-only, draggable-block calendar view.  Requires `org-timegrid' to be
installed; it is not a dependency of org-auto-scheduler and is not
pulled in automatically."
  :type 'boolean
  :group 'org-auto-scheduler)

(defvar org-auto-scheduler--ignore-target-dates-p nil
  "Internal flag: when non-nil, ignore transient target-date overrides during recalculation.")

(defvar org-auto-scheduler--ignore-saved-skips-p nil
  "Internal flag: when non-nil, ignore saved skip status in `schedule-single-task`.")

(defvar org-auto-scheduler-completed-tasks nil
  "List of completed/processed tasks in the current scheduling session.")

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

(defsubst org-auto-scheduler--review-special-row-p (id)
  "Return t if ID represents a non-task row (day separator or header shortcuts)."
  (and id (string-prefix-p "__" id)))

(defvar org-auto-scheduler--review-all-entries)
(defvar org-auto-scheduler--review-overrides)

(defun org-auto-scheduler--get-review-overrides ()
  "Return the review overrides hash-table from current buffer or review buffer."
  (or (and (boundp 'org-auto-scheduler--review-overrides)
           (hash-table-p org-auto-scheduler--review-overrides)
           (> (hash-table-count org-auto-scheduler--review-overrides) 0)
           org-auto-scheduler--review-overrides)
      (let ((buf (get-buffer "*Org Auto Scheduler Review*")))
        (when (and buf (buffer-live-p buf))
          (buffer-local-value 'org-auto-scheduler--review-overrides buf)))
      (and (boundp 'org-auto-scheduler--review-overrides)
           org-auto-scheduler--review-overrides)))

(defun org-auto-scheduler--get-review-override (task-id)
  "Return the review override plist for TASK-ID, if any."
  (when task-id
    (let ((tbl (org-auto-scheduler--get-review-overrides)))
      (when (hash-table-p tbl)
        (gethash task-id tbl)))))

;;; Review Decisions Persistence (Ordering & Skipping)

(defcustom org-auto-scheduler-review-state-file
  (expand-file-name "org-auto-scheduler-review-state.el" user-emacs-directory)
  "File to save user review decisions (ordering, skipping, target dates) across sessions.
Defaults to `org-auto-scheduler-review-state.el` inside your Emacs directory."
  :type 'string
  :group 'org-auto-scheduler)

(defcustom org-auto-scheduler-review-persistence-backend 'state-file
  "Storage backend for review decisions across sessions.
Values can be:
  `state-file'     - Store decisions in `org-auto-scheduler-review-state-file' (default).
  `org-properties' - Store directly in Org headline properties (:AUTOSCH_ORDER:, :AUTOSCH_SKIP:, :AUTOSCH_TARGET_DATE:).
  `both'           - Store in both the state file and Org headline properties."
  :type '(choice (const :tag "State file only" state-file)
                 (const :tag "Org headline properties only" org-properties)
                 (const :tag "Both state file and properties" both))
  :group 'org-auto-scheduler)

(defcustom org-auto-scheduler-review-auto-save-decisions t
  "Whether `org-auto-scheduler-review-execute' automatically saves decisions.
When non-nil, applying the schedule from the review buffer automatically persists
the ordering, skipping, and target-date decisions for subsequent runs."
  :type 'boolean
  :group 'org-auto-scheduler)

(defcustom org-auto-scheduler-order-property "AUTOSCH_ORDER"
  "Property name for storing task order in Org headlines when using org-properties backend."
  :type 'string
  :group 'org-auto-scheduler)

(defcustom org-auto-scheduler-skip-property "AUTOSCH_SKIP"
  "Property name for storing task skip status in Org headlines when using org-properties backend."
  :type 'string
  :group 'org-auto-scheduler)

(defcustom org-auto-scheduler-target-date-property "AUTOSCH_TARGET_DATE"
  "Property name for storing task target date in Org headlines when using org-properties backend."
  :type 'string
  :group 'org-auto-scheduler)

(defcustom org-auto-scheduler-non-blocking-property "AUTOSCH_NON_BLOCKING"
  "Property name for storing non-blocking status in Org headline properties.
Non-AUTOSCH tasks with this property set to \"t\" or \"yes\" will not block
auto-scheduler slots."
  :type 'string
  :group 'org-auto-scheduler)

(defcustom org-auto-scheduler-non-blocking-backend 'both
  "Storage backend for non-blocking task status across sessions.
Values can be:
  `both'           - Store in both the review state file and Org headline properties (default).
  `state-file'     - Store in `org-auto-scheduler-review-state-file' only.
  `org-properties' - Store directly in Org headline properties only."
  :type '(choice (const :tag "Both review state file and Org properties" both)
                 (const :tag "Review state file only" state-file)
                 (const :tag "Org headline properties only" org-properties))
  :group 'org-auto-scheduler)

(defvar org-auto-scheduler--saved-review-decisions nil
  "Alist mapping task-id (string) to a plist of saved review decisions.
Each entry is of the form:
  (TASK-ID . (:order NUMBER :skipped BOOLEAN :target-date STRING :headline STRING :updated-at TIME))")

(defvar org-auto-scheduler--non-blocking-tasks nil
  "Alist mapping task-id (string) to a plist of non-blocking metadata.
Each entry is of the form:
  (TASK-ID . (:headline STRING :non-blocking BOOLEAN :file FILE :updated-at TIME))")

(defvar org-auto-scheduler--state-file-last-mtime nil
  "Last recorded modification time of `org-auto-scheduler-review-state-file`.")

(defun org-auto-scheduler--state-file-mtime ()
  "Return modification time of `org-auto-scheduler-review-state-file`, or nil if non-existent."
  (when (and (stringp org-auto-scheduler-review-state-file)
             (file-exists-p org-auto-scheduler-review-state-file))
    (file-attribute-modification-time
     (file-attributes org-auto-scheduler-review-state-file))))

(defun org-auto-scheduler--read-state-file ()
  "Read decisions and non-blocking tasks from `org-auto-scheduler-review-state-file`.
Returns a plist (:decisions DECISIONS :non-blocking NON-BLOCKING :mtime MTIME)
or nil on failure."
  (when (and (stringp org-auto-scheduler-review-state-file)
             (file-exists-p org-auto-scheduler-review-state-file))
    (condition-case err
        (let ((mtime (org-auto-scheduler--state-file-mtime)))
          (with-temp-buffer
            (insert-file-contents org-auto-scheduler-review-state-file)
            (goto-char (point-min))
            (let ((decisions nil)
                  (non-blocking nil)
                  (found-decisions nil)
                  (found-nb nil)
                  (form nil))
              (while (condition-case nil
                         (setq form (read (current-buffer)))
                       (end-of-file nil))
                (when (consp form)
                  (pcase form
                    (`(setq org-auto-scheduler--saved-review-decisions ',val)
                     (setq decisions val
                           found-decisions t))
                    (`(setq org-auto-scheduler--non-blocking-tasks ',val)
                     (setq non-blocking val
                           found-nb t)))))
              (if (or found-decisions found-nb)
                  (list :decisions decisions
                        :non-blocking non-blocking
                        :mtime mtime)
                ;; Fallback if formatted differently: evaluate buffer safely in isolated let-scope
                (let ((org-auto-scheduler--saved-review-decisions nil)
                      (org-auto-scheduler--non-blocking-tasks nil))
                  (eval-buffer (current-buffer))
                  (list :decisions org-auto-scheduler--saved-review-decisions
                        :non-blocking org-auto-scheduler--non-blocking-tasks
                        :mtime mtime))))))
      (error
       (org-auto-scheduler--log-warn "Failed to read state file %s: %s"
                                     org-auto-scheduler-review-state-file
                                     (error-message-string err))
       nil))))

(defun org-auto-scheduler--merge-decision-alists (local-alist remote-alist)
  "Merge LOCAL-ALIST and REMOTE-ALIST of (KEY . PLIST) entries.
When keys collide, entry with the newer :updated-at timestamp wins.
If timestamps cannot be compared or are identical, LOCAL-ALIST entry is preferred."
  (let ((merged (copy-alist local-alist)))
    (dolist (item remote-alist)
      (let* ((key (car item))
             (remote-val (cdr item))
             (local-entry (assoc key merged)))
        (if (not local-entry)
            (push (cons key remote-val) merged)
          (let* ((local-val (cdr local-entry))
                 (l-time (plist-get local-val :updated-at))
                 (r-time (plist-get remote-val :updated-at)))
            (cond
             ((and l-time r-time)
              (when (time-less-p l-time r-time)
                (setcdr local-entry remote-val)))
             ((and (null l-time) r-time)
              (setcdr local-entry remote-val)))))))
    merged))

(defun org-auto-scheduler-save-review-decisions (&optional no-merge)
  "Save review decisions (order, skip, target dates) and non-blocking tasks
to `org-auto-scheduler-review-state-file`.
Unless NO-MERGE is non-nil, checks if the file on disk was modified externally
and merges disk state by :updated-at timestamps before saving."
  (when (or (memq org-auto-scheduler-review-persistence-backend '(state-file both))
            (memq org-auto-scheduler-non-blocking-backend '(state-file both config-file)))
    (condition-case err
        (let ((dir (file-name-directory org-auto-scheduler-review-state-file)))
          (when (and dir (not (file-directory-p dir)))
            (make-directory dir t))
          (unless no-merge
            (when (file-exists-p org-auto-scheduler-review-state-file)
              (let ((disk-mtime (org-auto-scheduler--state-file-mtime)))
                (when (and disk-mtime
                           org-auto-scheduler--state-file-last-mtime
                           (time-less-p org-auto-scheduler--state-file-last-mtime disk-mtime))
                  (let ((disk-data (org-auto-scheduler--read-state-file)))
                    (when disk-data
                      (setq org-auto-scheduler--saved-review-decisions
                            (org-auto-scheduler--merge-decision-alists
                             org-auto-scheduler--saved-review-decisions
                             (plist-get disk-data :decisions)))
                      (setq org-auto-scheduler--non-blocking-tasks
                            (org-auto-scheduler--merge-decision-alists
                             org-auto-scheduler--non-blocking-tasks
                             (plist-get disk-data :non-blocking)))))))))
          (with-temp-file org-auto-scheduler-review-state-file
            (let ((print-length nil)
                  (print-level nil))
              (insert ";;; -*- lexical-binding: t; -*-\n")
              (insert ";; Auto-generated by org-auto-scheduler review decisions\n")
              (insert (format "(setq org-auto-scheduler--saved-review-decisions '%S)\n"
                              org-auto-scheduler--saved-review-decisions))
              (insert (format "(setq org-auto-scheduler--non-blocking-tasks '%S)\n"
                              org-auto-scheduler--non-blocking-tasks))))
          (setq org-auto-scheduler--state-file-last-mtime
                (org-auto-scheduler--state-file-mtime)))
      (error
       (message "org-auto-scheduler: failed to save review decisions: %s"
                (error-message-string err))))))

(defun org-auto-scheduler-load-review-decisions (&optional force)
  "Load review decisions and non-blocking tasks from `org-auto-scheduler-review-state-file`.
When FORCE is non-nil, un-initialized, or when the file on disk has a newer
modification time than `org-auto-scheduler--state-file-last-mtime`, reload
and reconcile state from disk."
  (when (and (or (memq org-auto-scheduler-review-persistence-backend '(state-file both))
                 (memq org-auto-scheduler-non-blocking-backend '(state-file both config-file)))
             (file-exists-p org-auto-scheduler-review-state-file))
    (let* ((current-mtime (org-auto-scheduler--state-file-mtime))
           (uninitialized (and (null org-auto-scheduler--saved-review-decisions)
                               (null org-auto-scheduler--non-blocking-tasks)))
           (disk-newer (and current-mtime
                            (or (null org-auto-scheduler--state-file-last-mtime)
                                (time-less-p org-auto-scheduler--state-file-last-mtime current-mtime)))))
      (when (or force uninitialized disk-newer)
        (let ((data (org-auto-scheduler--read-state-file)))
          (if data
              (let ((disk-decisions (plist-get data :decisions))
                    (disk-nb (plist-get data :non-blocking))
                    (mtime (plist-get data :mtime)))
                (if (or force uninitialized)
                    (progn
                      (setq org-auto-scheduler--saved-review-decisions disk-decisions)
                      (setq org-auto-scheduler--non-blocking-tasks disk-nb))
                  (setq org-auto-scheduler--saved-review-decisions
                        (org-auto-scheduler--merge-decision-alists
                         org-auto-scheduler--saved-review-decisions disk-decisions))
                  (setq org-auto-scheduler--non-blocking-tasks
                        (org-auto-scheduler--merge-decision-alists
                         org-auto-scheduler--non-blocking-tasks disk-nb)))
                (setq org-auto-scheduler--state-file-last-mtime (or mtime current-mtime))
                (org-auto-scheduler--log-debug
                 "org-auto-scheduler: loaded review decisions from %s (mtime: %s)"
                 org-auto-scheduler-review-state-file
                 (format-time-string "%Y-%m-%d %H:%M:%S" org-auto-scheduler--state-file-last-mtime)))
            ;; Fallback to standard load if custom parsing failed
            (load org-auto-scheduler-review-state-file t t t)
            (setq org-auto-scheduler--state-file-last-mtime current-mtime)))))))

(add-hook 'kill-emacs-hook #'org-auto-scheduler-save-review-decisions)
(org-auto-scheduler-load-review-decisions)

(defun org-auto-scheduler-save-non-blocking-state (&optional no-merge)
  "Save non-blocking task records to `org-auto-scheduler-review-state-file`."
  (org-auto-scheduler-save-review-decisions no-merge))

(defun org-auto-scheduler-load-non-blocking-state (&optional force)
  "Load non-blocking task records from `org-auto-scheduler-review-state-file`."
  (org-auto-scheduler-load-review-decisions force))


(defun org-auto-scheduler-task-non-blocking-p (task-id &optional marker)
  "Return non-nil if TASK-ID or MARKER represents a non-blocking task.
Checks both Org headline properties and saved configuration records."
  (let* ((prop-val nil)
         (record-val nil)
         (m (or marker
                (when (and task-id (stringp task-id) (not (string= task-id "")))
                  (org-id-find task-id t))))
         (tid (or (and task-id (stringp task-id) (not (string= task-id "")) task-id)
                  (when (and m (markerp m) (marker-buffer m))
                    (org-with-point-at m (org-id-get))))))
    ;; Check Org properties if marker is available
    (when (and m (markerp m) (marker-buffer m)
               (memq org-auto-scheduler-non-blocking-backend '(org-properties both config-file state-file)))
      (org-with-point-at m
        (let ((val (or (org-entry-get nil org-auto-scheduler-non-blocking-property)
                       (org-entry-get nil "AUTOSCH_NON_BLOCKING")
                       (org-entry-get nil "NON_BLOCKING"))))
          (when val
            (setq prop-val
                  (cond
                   ((member (downcase val) '("t" "yes" "true" "1")) t)
                   ((member (downcase val) '("nil" "no" "false" "0")) :explicit-nil)
                   (t t)))))))
    ;; Check config file / in-memory record
    (when (and tid (stringp tid))
      (let ((entry (cdr (assoc tid org-auto-scheduler--non-blocking-tasks))))
        (when entry
          (setq record-val (plist-get entry :non-blocking)))))
    ;; Evaluate
    (cond
     ((eq prop-val :explicit-nil) nil)
     (prop-val t)
     (record-val t)
     (t nil))))

(defun org-auto-scheduler-mark-non-blocking (&optional task-id marker headline)
  "Mark a non-AUTOSCH task as non-blocking.
Persists the decision according to `org-auto-scheduler-non-blocking-backend`."
  (let* ((m (or marker
                (when (and task-id (stringp task-id))
                  (org-id-find task-id t))
                (and (derived-mode-p 'org-mode) (point-marker))))
         (tid (or task-id
                  (when (and m (markerp m) (marker-buffer m))
                    (org-with-point-at m (or (org-id-get) (org-id-get-create))))))
         (hl (or headline
                 (when (and m (markerp m) (marker-buffer m))
                   (org-with-point-at m (org-get-heading t t t t)))
                 tid
                 "Event"))
         (file (and m (markerp m) (marker-buffer m)
                    (buffer-file-name (marker-buffer m)))))
    ;; 1. Org properties
    (when (and m (markerp m) (marker-buffer m)
               (memq org-auto-scheduler-non-blocking-backend '(org-properties both)))
      (org-with-point-at m
        (org-set-property org-auto-scheduler-non-blocking-property "t")))
    ;; 2. Config file
    (when (and tid (memq org-auto-scheduler-non-blocking-backend '(config-file both state-file)))
      (let ((entry (assoc tid org-auto-scheduler--non-blocking-tasks))
            (meta (list :headline hl :non-blocking t :file file :updated-at (current-time))))
        (if entry
            (setcdr entry meta)
          (push (cons tid meta) org-auto-scheduler--non-blocking-tasks)))
      (org-auto-scheduler-save-non-blocking-state))
    t))

(defun org-auto-scheduler-unmark-non-blocking (&optional task-id marker)
  "Unmark a non-AUTOSCH task as non-blocking (restore to blocking).
Persists the decision according to `org-auto-scheduler-non-blocking-backend`."
  (let* ((m (or marker
                (when (and task-id (stringp task-id))
                  (org-id-find task-id t))
                (and (derived-mode-p 'org-mode) (point-marker))))
         (tid (or task-id
                  (when (and m (markerp m) (marker-buffer m))
                    (org-with-point-at m (org-id-get))))))
    ;; 1. Org properties
    (when (and m (markerp m) (marker-buffer m)
               (memq org-auto-scheduler-non-blocking-backend '(org-properties both)))
      (org-with-point-at m
        (org-delete-property org-auto-scheduler-non-blocking-property)
        (org-delete-property "AUTOSCH_NON_BLOCKING")
        (org-delete-property "NON_BLOCKING")))
    ;; 2. Config file
    (when (and tid (memq org-auto-scheduler-non-blocking-backend '(config-file both state-file)))
      (setq org-auto-scheduler--non-blocking-tasks
            (cl-remove-if (lambda (e) (equal (car e) tid))
                          org-auto-scheduler--non-blocking-tasks))
      (org-auto-scheduler-save-non-blocking-state))
    nil))

(defun org-auto-scheduler-get-saved-decision (task-id &optional marker)
  "Get saved decision plist for TASK-ID.
If MARKER is provided and backend is `org-properties` or `both`, also checks
the task's Org properties."
  (let ((entry (and task-id (cdr (assoc task-id org-auto-scheduler--saved-review-decisions)))))
    (if (and marker (markerp marker) (marker-buffer marker)
             (memq org-auto-scheduler-review-persistence-backend '(org-properties both)))
        (org-with-point-at marker
          (let* ((prop-order (org-entry-get nil org-auto-scheduler-order-property))
                 (prop-skip (org-entry-get nil org-auto-scheduler-skip-property))
                 (prop-target (org-entry-get nil org-auto-scheduler-target-date-property))
                 (prop-pinnable (org-entry-get nil org-auto-scheduler-pinnable-property))
                 (prop-pinned-time (or (org-entry-get nil org-auto-scheduler-pinned-time-property)
                                       (org-entry-get nil "PINNED")))
                 (order (if prop-order (string-to-number prop-order) (plist-get entry :order)))
                 (skipped (cond ((string= prop-skip "t") t)
                                ((string= prop-skip "nil") nil)
                                (prop-skip t)
                                (t (plist-get entry :skipped))))
                 (target-date (or prop-target (plist-get entry :target-date)))
                 (pinnable (cond ((string= prop-pinnable "t") t)
                                 ((string= prop-pinnable "nil") nil)
                                 (prop-pinnable t)
                                 (t (plist-get entry :pinnable))))
                 (pinned-time (or prop-pinned-time (plist-get entry :pinned-time))))
            (list :order order :skipped skipped :target-date target-date
                  :pinnable pinnable :pinned-time pinned-time)))
      entry)))

(defun org-auto-scheduler-review-save-decisions (&optional silent)
  "Save current ordering, skipping, and date decisions from review buffer.
When SILENT is non-nil, suppress confirmation message."
  (interactive)
  (unless (eq major-mode 'org-auto-scheduler-review-mode)
    (user-error "Not in an Org Auto Scheduler Review buffer"))
  (let ((order-rank 0)
        (current-sep-date nil)
        (saved-count 0)
        (skipped-count 0)
        (entries (or org-auto-scheduler--review-all-entries tabulated-list-entries)))
    (dolist (item entries)
      (let ((row-id (car item))
            (entry (cadr item)))
        (cond
         ((and (stringp row-id) (string-prefix-p "__sep_" row-id))
          (setq current-sep-date (substring row-id 6)))
         ((and row-id (not (org-auto-scheduler--review-special-row-p row-id)))
          (setq order-rank (+ order-rank 100.0))
          (let* ((checked (if entry (string= (aref entry 0) "[X]") t))
                 (skipped (not checked))
                 (task-data (assoc row-id org-auto-scheduler-completed-tasks))
                 (marker (and task-data (nth 7 task-data)))
                 (headline (and task-data (nth 5 task-data)))
                 (override (and (bound-and-true-p org-auto-scheduler--review-overrides)
                                (gethash row-id org-auto-scheduler--review-overrides)))
                 (target-date (or (plist-get override :target-date)
                                  (plist-get override :pinned-date)
                                  (and current-sep-date
                                       (not (string= current-sep-date "Unknown"))
                                       current-sep-date)))
                 (pinnable (plist-get override :pinnable))
                 (pinned-time (plist-get override :pinned-time))
                 (decision (list :order order-rank
                                 :skipped skipped
                                 :target-date target-date
                                 :pinnable pinnable
                                 :pinned-time pinned-time
                                 :headline (or headline "task")
                                 :is-new nil
                                 :updated-at (current-time))))
            (setq saved-count (1+ saved-count))
            (when skipped (setq skipped-count (1+ skipped-count)))
            ;; Update memory alist
            (let ((existing (assoc row-id org-auto-scheduler--saved-review-decisions)))
              (if existing
                  (setcdr existing decision)
                (push (cons row-id decision) org-auto-scheduler--saved-review-decisions)))
            ;; Optionally write to Org properties
            (when (and marker (markerp marker) (marker-buffer marker)
                       (memq org-auto-scheduler-review-persistence-backend '(org-properties both)))
              (org-with-point-at marker
                (org-set-property org-auto-scheduler-order-property (number-to-string order-rank))
                (org-set-property org-auto-scheduler-skip-property (if skipped "t" "nil"))
                (if target-date
                    (org-set-property org-auto-scheduler-target-date-property target-date)
                  (org-delete-property org-auto-scheduler-target-date-property))
                (if pinnable
                    (org-set-property org-auto-scheduler-pinnable-property "t")
                  (org-delete-property org-auto-scheduler-pinnable-property))
                (if pinned-time
                    (org-set-property org-auto-scheduler-pinned-time-property pinned-time)
                  (org-delete-property org-auto-scheduler-pinned-time-property)))))))))
    ;; Persist to state file
    (org-auto-scheduler-save-review-decisions)
    (unless silent
      (message "Saved review decisions for %d tasks (%d skipped) across sessions."
               saved-count skipped-count))))

(defun org-auto-scheduler-clear-saved-decisions (&optional scope target-task-id)
  "Clear saved review decisions.
SCOPE can be:
  `all`          - Clear all saved ordering, skipping, and non-blocking decisions.
  `skipped`      - Clear only skipped flags (reset all tasks to unskipped).
  `order`        - Clear only saved order rankings.
  `non-blocking` - Clear all non-blocking marks (restore all to blocking).
  `task`         - Clear decisions for TARGET-TASK-ID or task at point.
Interactively, prompts the user to select SCOPE."
  (interactive
   (list (intern (completing-read "Clear saved decisions: "
                                  '("all" "skipped" "order" "non-blocking" "task")
                                  nil t nil nil "all"))))
  (pcase scope
    ('all
     (setq org-auto-scheduler--saved-review-decisions nil)
     (when (memq org-auto-scheduler-review-persistence-backend '(org-properties both))
       (org-map-entries
        (lambda ()
          (org-delete-property org-auto-scheduler-order-property)
          (org-delete-property org-auto-scheduler-skip-property)
          (org-delete-property org-auto-scheduler-target-date-property))
        "+AUTOSCH" 'agenda))
     (org-auto-scheduler-save-review-decisions t)
     ;; Also clear non-blocking
     (setq org-auto-scheduler--non-blocking-tasks nil)
     (when (memq org-auto-scheduler-non-blocking-backend '(org-properties both))
       (org-map-entries
        (lambda ()
          (org-delete-property org-auto-scheduler-non-blocking-property)
          (org-delete-property "AUTOSCH_NON_BLOCKING")
          (org-delete-property "NON_BLOCKING"))
        "-AUTOSCH" 'agenda))
     (org-auto-scheduler-save-non-blocking-state t)
     (message "Cleared all saved review decisions and non-blocking marks."))
    ('skipped
     (dolist (entry org-auto-scheduler--saved-review-decisions)
       (setcdr entry (plist-put (cdr entry) :skipped nil)))
     (when (memq org-auto-scheduler-review-persistence-backend '(org-properties both))
       (org-map-entries
        (lambda ()
          (org-delete-property org-auto-scheduler-skip-property))
        "+AUTOSCH" 'agenda))
     (org-auto-scheduler-save-review-decisions t)
     (message "Cleared all skipped flags."))
    ('order
     (dolist (entry org-auto-scheduler--saved-review-decisions)
       (setcdr entry (plist-put (cdr entry) :order nil)))
     (when (memq org-auto-scheduler-review-persistence-backend '(org-properties both))
       (org-map-entries
        (lambda ()
          (org-delete-property org-auto-scheduler-order-property))
        "+AUTOSCH" 'agenda))
     (org-auto-scheduler-save-review-decisions t)
     (message "Cleared all saved order rankings."))
    ('non-blocking
     (setq org-auto-scheduler--non-blocking-tasks nil)
     (when (memq org-auto-scheduler-non-blocking-backend '(org-properties both))
       (org-map-entries
        (lambda ()
          (org-delete-property org-auto-scheduler-non-blocking-property)
          (org-delete-property "AUTOSCH_NON_BLOCKING")
          (org-delete-property "NON_BLOCKING"))
        "-AUTOSCH" 'agenda))
     (org-auto-scheduler-save-non-blocking-state t)
     (message "Cleared all non-blocking marks."))
    ('task
     (let* ((task-id (or target-task-id
                         (if (eq major-mode 'org-auto-scheduler-review-mode)
                             (tabulated-list-get-id)
                           (org-id-get))))
            (marker (if (eq major-mode 'org-auto-scheduler-review-mode)
                        (let ((data (assoc task-id org-auto-scheduler-completed-tasks)))
                          (or (and data (nth 7 data))
                              (get-text-property (point) 'event-marker)))
                      (and (not target-task-id) (point-marker)))))
       (if (not task-id)
           (user-error "No task found at point")
         (setq org-auto-scheduler--saved-review-decisions
               (cl-remove-if (lambda (e) (equal (car e) task-id))
                             org-auto-scheduler--saved-review-decisions))
         (when (and marker (markerp marker) (marker-buffer marker)
                    (memq org-auto-scheduler-review-persistence-backend '(org-properties both)))
           (org-with-point-at marker
             (org-delete-property org-auto-scheduler-order-property)
             (org-delete-property org-auto-scheduler-skip-property)
             (org-delete-property org-auto-scheduler-target-date-property)))
         (org-auto-scheduler-save-review-decisions t)
         (org-auto-scheduler-unmark-non-blocking task-id marker)
         (message "Cleared saved decisions for task %s." task-id)))))
  (when (eq major-mode 'org-auto-scheduler-review-mode)
    (org-auto-scheduler-review-refresh)))

(defun org-auto-scheduler-review-reset-decisions ()
  "Reset all saved review decisions and refresh the review buffer from scratch."
  (interactive)
  (when (yes-or-no-p "Clear all saved review decisions and recalculate from scratch? ")
    (org-auto-scheduler-clear-saved-decisions 'all)
    (org-auto-scheduler-review-refresh)))

(defun org-auto-scheduler--merge-saved-decisions (tasks)
  "Reconcile and merge saved review decisions with the current live TASKS.
TASKS is a list of markers for schedulable tasks.
Prunes dead/completed tasks, preserves previous relative order, and
intelligently slots new tasks using sibling outline position or project scores.
Returns a plist (:pruned N :new N :kept N)."
  (org-auto-scheduler-load-review-decisions)
  (let* ((live-map (make-hash-table :test 'equal))
         (live-id-set (make-hash-table :test 'equal))
         (pruned-count 0)
         (new-count 0)
         (kept-count 0)
         (max-rank 0.0))

    ;; 1. Scan live tasks and collect outline & scoring metadata
    (dolist (m tasks)
      (when (markerp m)
        (org-with-point-at m
          (let* ((tid (or (org-id-get) (org-id-get-create)))
                 (headline (org-get-heading t t t t))
                 (todo (org-get-todo-state))
                 (score (car (org-auto-scheduler-calculate-score m)))
                 (proj (org-auto-scheduler-get-project-id m))
                 (parent-node (save-excursion
                                (if (org-up-heading-safe)
                                    (cons (current-buffer) (point))
                                  (cons (current-buffer) 'top))))
                 (pos (org-auto-scheduler-get-task-position m))
                 (manual-sched (org-entry-get nil "SCHEDULED"))
                 (info (list :marker m
                             :id tid
                             :headline headline
                             :todo todo
                             :score (or score 0.0)
                             :project proj
                             :parent parent-node
                             :position pos
                             :manual-sched manual-sched)))
            (puthash tid info live-map)
            (puthash tid t live-id-set)))))

    ;; 2. Prune decisions for tasks no longer live in agenda
    (let ((remaining '()))
      (dolist (entry org-auto-scheduler--saved-review-decisions)
        (let ((tid (car entry)))
          (if (gethash tid live-id-set)
              (progn
                (push entry remaining)
                (let ((r (plist-get (cdr entry) :order)))
                  (when (and r (numberp r) (> r max-rank))
                    (setq max-rank (float r))))
                (setq kept-count (1+ kept-count)))
            (setq pruned-count (1+ pruned-count)))))
      (setq org-auto-scheduler--saved-review-decisions (nreverse remaining)))

    ;; 3. Identify new tasks (tasks without a saved :order)
    (let ((new-task-infos '())
          (parent-groups (make-hash-table :test 'equal)))
      (maphash (lambda (_tid info)
                 (let* ((tid (plist-get info :id))
                        (saved (assoc tid org-auto-scheduler--saved-review-decisions))
                        (order (and saved (plist-get (cdr saved) :order)))
                        (parent (plist-get info :parent)))
                   (if (and order (numberp order))
                       (setq info (plist-put info :order (float order)))
                     (push info new-task-infos))
                   (puthash parent (cons info (gethash parent parent-groups)) parent-groups)))
               live-map)

      ;; 4. Interpolate new tasks using Sibling Outline Anchoring
      (let ((unslotted '()))
        (dolist (info new-task-infos)
          (let* ((parent (plist-get info :parent))
                 (group (gethash parent parent-groups))
                 (sorted-sibs (sort (copy-sequence group)
                                    (lambda (a b) (< (plist-get a :position)
                                                     (plist-get b :position)))))
                 (curr-pos (plist-get info :position))
                 (prev-ranked-sib nil)
                 (next-ranked-sib nil))
            ;; Scan siblings before and after
            (dolist (sib sorted-sibs)
              (let ((s-pos (plist-get sib :position))
                    (s-ord (plist-get sib :order)))
                (when (and s-ord (numberp s-ord))
                  (if (< s-pos curr-pos)
                      (setq prev-ranked-sib s-ord)
                    (when (null next-ranked-sib)
                      (setq next-ranked-sib s-ord))))))
            (cond
             ;; Sibling before and after: interpolate midpoint
             ((and prev-ranked-sib next-ranked-sib)
              (let ((interpolated (/ (+ prev-ranked-sib next-ranked-sib) 2.0)))
                (setq info (plist-put info :order interpolated))
                (plist-put (gethash (plist-get info :id) live-map) :order interpolated)))
             ;; Sibling before only
             (prev-ranked-sib
              (let ((new-ord (+ prev-ranked-sib 50.0)))
                (setq info (plist-put info :order new-ord))
                (plist-put (gethash (plist-get info :id) live-map) :order new-ord)))
             ;; Sibling after only
             (next-ranked-sib
              (let ((new-ord (max 1.0 (- next-ranked-sib 50.0))))
                (setq info (plist-put info :order new-ord))
                (plist-put (gethash (plist-get info :id) live-map) :order new-ord)))
             (t
              (push info unslotted)))))

        ;; 5. Score & Project Anchoring for remaining unslotted new tasks
        (dolist (info unslotted)
          (let* ((proj (plist-get info :project))
                 (score (plist-get info :score))
                 (proj-ranked-tasks '()))
            ;; Find ranked tasks in same project
            (maphash (lambda (_tid other-info)
                       (when (and (equal (plist-get other-info :project) proj)
                                  (plist-get other-info :order))
                         (push other-info proj-ranked-tasks)))
                     live-map)
            (if proj-ranked-tasks
                (let* ((sorted-proj (sort proj-ranked-tasks
                                          (lambda (a b) (> (plist-get a :score) (plist-get b :score)))))
                       (closest (car sorted-proj))
                       (c-ord (plist-get closest :order))
                       (new-ord (if (>= score (plist-get closest :score))
                                    (max 1.0 (- c-ord 25.0))
                                  (+ c-ord 25.0))))
                  (setq info (plist-put info :order new-ord))
                  (plist-put (gethash (plist-get info :id) live-map) :order new-ord))
              ;; Global fallback: append at end
              (setq max-rank (+ max-rank 100.0))
              (setq info (plist-put info :order max-rank))
              (plist-put (gethash (plist-get info :id) live-map) :order max-rank)))))

      ;; 6. Update saved decisions alist with new tasks and smart skip flags
      (maphash (lambda (tid info)
                 (let* ((existing (assoc tid org-auto-scheduler--saved-review-decisions))
                        (order (plist-get info :order))
                        (prev-skipped (and existing (plist-get (cdr existing) :skipped)))
                        (todo (plist-get info :todo))
                        (manual-sched (plist-get info :manual-sched))
                        ;; Un-skip if user moved to NEXT or manually scheduled it
                        (skipped (if (and prev-skipped (or (string= todo "NEXT") manual-sched))
                                     nil
                                   prev-skipped))
                        (is-new (null existing))
                        (target-date (and existing (plist-get (cdr existing) :target-date)))
                        (decision (list :order (or order (setq max-rank (+ max-rank 100.0)))
                                        :skipped skipped
                                        :target-date target-date
                                        :headline (plist-get info :headline)
                                        :is-new is-new
                                        :updated-at (current-time))))
                   (if existing
                       (setcdr existing decision)
                     (setq new-count (1+ new-count))
                     (push (cons tid decision) org-auto-scheduler--saved-review-decisions))))
               live-map))

    ;; 7. Save merged state to file
    (org-auto-scheduler-save-review-decisions)
    (list :pruned pruned-count :new new-count :kept kept-count)))

(defun org-auto-scheduler-review-restore-and-merge ()
  "Restore saved review decisions and merge with live Org task modifications.
Prunes completed/removed tasks, restores previous visual ordering, slots
newly added tasks using sibling outline position or score, and refreshes the review view."
  (interactive)
  (message "Restoring previous order and merging live changes...")
  (let* ((tasks (org-auto-scheduler-get-schedulable-tasks))
         (stats (org-auto-scheduler--merge-saved-decisions tasks)))
    (org-auto-scheduler-review-and-apply)
    (message "Restored and merged schedule: %d kept, %d new merged, %d pruned."
             (plist-get stats :kept)
             (plist-get stats :new)
             (plist-get stats :pruned))))

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

(defun org-auto-scheduler--extract-blocker-ids (str)
  "Extract clean ID tokens from STR, handling ids(...), id: prefix, and quotes."
  (let ((tokens nil))
    (when (stringp str)
      (let ((cleaned (replace-regexp-in-string "[()\"`\t\n\r]" " " str)))
        (dolist (item (split-string cleaned "[ \t]+" t))
          (let ((val (replace-regexp-in-string "^id:" "" item)))
            (unless (member (downcase val) (quote ("ids" "id" "nil" "previous-sibling" "ancestors")))
              (push val tokens))))))
    (nreverse tokens)))

(defun org-auto-scheduler--extract-blocker-specs (marker)
  "Extract raw blocker specifications from MARKER."
  (let ((blockers (org-with-point-at marker (org-entry-get nil "BLOCKER")))
        (depends (org-with-point-at marker (org-entry-get nil "DEPENDS_ON"))))
    (let* ((all-raw (concat (or blockers "") " " (or depends "")))
           (ids (org-auto-scheduler--extract-blocker-ids all-raw))
           (specs nil))
      (dolist (id ids)
        (push (cons 'id id) specs))
      (when (string-match-p "\\bprevious-sibling\\b" (downcase all-raw))
        (push (cons 'previous-sibling nil) specs))
      (when (string-match-p "\\bancestors\\b" (downcase all-raw))
        (push (cons 'ancestors nil) specs))
      (nreverse specs))))

(defun org-auto-scheduler--resolve-blocker-specs (marker)
  "Resolve all blocker specs for MARKER.
Returns a list of plists: (:spec spec :marker marker :id id :error error)."
  (let ((specs (org-auto-scheduler--extract-blocker-specs marker))
        (resolved nil))
    (dolist (spec specs)
      (let ((type (car spec))
            (val (cdr spec)))
        (cond
         ((eq type 'id)
          (let ((b-m (or (org-id-find val t)
                         (save-excursion
                           (with-current-buffer (marker-buffer marker)
                             (let ((pos (or (org-find-property "ID" val)
                                            (org-find-property "CUSTOM_ID" val))))
                               (when pos (copy-marker pos)))))
                         (cl-some (lambda (buf)
                                    (when (and (buffer-live-p buf)
                                               (with-current-buffer buf (derived-mode-p 'org-mode)))
                                      (with-current-buffer buf
                                        (let ((pos (or (org-find-property "ID" val)
                                                       (org-find-property "CUSTOM_ID" val))))
                                          (when pos (copy-marker pos))))))
                                  (buffer-list)))))
            (if b-m
                (push (list :spec spec :marker b-m :id val :error nil) resolved)
              (push (list :spec spec :marker nil :id val :error "ID not found") resolved))))
         ((eq type 'previous-sibling)
          (let ((prev (save-excursion
                        (with-current-buffer (marker-buffer marker)
                          (goto-char (marker-position marker))
                          (when (org-goto-sibling t)
                            (point-marker))))))
            (if prev
                (push (list :spec spec :marker prev :id nil :error nil) resolved)
              (push (list :spec spec :marker nil :id nil :error "No previous sibling") resolved))))
         ((eq type 'ancestors)
          (let (anc-markers)
            (save-excursion
              (with-current-buffer (marker-buffer marker)
                (goto-char (marker-position marker))
                (while (org-up-heading-safe)
                  (push (point-marker) anc-markers))))
            (if anc-markers
                (dolist (m anc-markers)
                  (push (list :spec spec :marker m :id nil :error nil) resolved))
              (push (list :spec spec :marker nil :id nil :error "No ancestors") resolved)))))))
    (nreverse resolved)))

(defun org-auto-scheduler-get-all-blocker-markers (marker)
  "Get all markers for tasks specified in BLOCKER or DEPENDS_ON of MARKER, whether DONE or not."
  (let ((resolved (org-auto-scheduler--resolve-blocker-specs marker))
        (markers nil))
    (dolist (item resolved)
      (let ((m (plist-get item :marker)))
        (when m (push m markers))))
    (delete-dups (nreverse markers))))

(defun org-auto-scheduler-get-blockers (marker)
  "Get a list of markers for tasks that block the task at MARKER.
Returns a list of markers for tasks specified in BLOCKER or DEPENDS_ON that are not DONE."
  (let ((all-markers (org-auto-scheduler-get-all-blocker-markers marker))
        (active-blockers nil))
    (dolist (m all-markers)
      (org-with-point-at m
        (unless (member (org-get-todo-state) org-done-keywords)
          (push m active-blockers))))
    (nreverse active-blockers)))

(defun org-auto-scheduler--get-task-blockers-info (marker)
  "Return detailed list of blocker descriptions for MARKER.
Each item is (label . status-string)."
  (let ((resolved (org-auto-scheduler--resolve-blocker-specs marker))
        (info nil))
    (dolist (item resolved)
      (let ((m (plist-get item :marker))
            (id (plist-get item :id))
            (err (plist-get item :error)))
        (if m
            (let* ((h (org-with-point-at m (org-get-heading t t t t)))
                   (todo (org-with-point-at m (org-get-todo-state)))
                   (is-done (member todo org-done-keywords))
                   (b-id (org-with-point-at m (org-id-get)))
                   (b-task (or (cl-find m org-auto-scheduler-completed-tasks
                                        :key (lambda (x) (nth 7 x)))
                               (and b-id (assoc b-id org-auto-scheduler-completed-tasks))))
                   (stat-label
                    (cond
                     (is-done "[DONE]")
                     ((null b-task) "[NOT IN SCHEDULE]")
                     ((eq (nth 9 b-task) :skipped) "[SKIPPED]")
                     ((eq (nth 9 b-task) :failed) "[FAILED]")
                     ((eq (nth 9 b-task) :blocked) "[BLOCKED]")
                     ((nth 1 b-task)
                      (format "[%s]" (org-auto-scheduler--format-time-short (nth 1 b-task))))
                     (t "[UNSCHEDULED]"))))
              (push (cons (or h "Unknown task") stat-label) info))
          ;; Marker was not resolved (e.g. ID not found)
          (let ((label (if id (format "ID %s" id) (or err "Unknown blocker"))))
            (push (cons label "[NOT FOUND]") info)))))
    (nreverse info)))

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
                          (is-nb (org-auto-scheduler-task-non-blocking-p task-id (point-marker)))
                          (item (list task-id time-val task-end-time tags (not is-nb) task-name has-time-flag (point-marker)))
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
                       (task-end-time (org-auto-scheduler-calculate-task-end-time (point)))
                       (is-nb (org-auto-scheduler-task-non-blocking-p task-id (point-marker))))
                  (when (string= scheduled-date date-string)
                    (list task-id scheduled-time task-end-time tags (not is-nb) task-name has-time-flag (point-marker)))))))
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
                       (task-end-time (org-auto-scheduler-calculate-task-end-time (point)))
                       (is-nb (org-auto-scheduler-task-non-blocking-p task-id (point-marker))))
                  (when (string= scheduled-date date-string)
                    (list task-id scheduled-time task-end-time tags (not is-nb) task-name has-time-flag (point-marker)))))))
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

        ;; Add reservations for pinned tasks not yet completed during review reordering
        (when (bound-and-true-p org-auto-scheduler--reordering-p)
          (dolist (item (org-auto-scheduler--get-pinned-tasks-reservations date-string))
            (let ((tid (nth 0 item)))
              (unless (cl-some (lambda (tk) (equal (nth 0 tk) tid)) org-auto-scheduler-completed-tasks)
                (push item agenda-items)))))

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
                  (cond
                   ((= (length repeater-item) 6)
                    (setq repeater-item (append repeater-item (list t nil))))
                   ((= (length repeater-item) 7)
                    (setq repeater-item (append repeater-item (list nil)))))
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
         (override (org-auto-scheduler--get-review-override task-id))
         (overridden-effort (and override (plist-get override :effort))))
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
            (while (re-search-forward "^[ \t]*CLOCK: \\[\\([^]]+\\)\\]--\\[\\([^]]+\\)\\] =>[ ]*\\([0-9]+:[0-9]+\\)" logbook-end t)
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
  (let* ((id-a (nth 5 a))
         (id-b (nth 5 b))
         (dec-a (org-auto-scheduler-get-saved-decision id-a (nth 0 a)))
         (dec-b (org-auto-scheduler-get-saved-decision id-b (nth 0 b)))
         (order-a (and dec-a (plist-get dec-a :order)))
         (order-b (and dec-b (plist-get dec-b :order)))
         (project-priority-a (nth 3 a))
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
     ;; 0. Saved review order (explicit user sequence decisions)
     ((and order-a order-b (not (= order-a order-b)))
      (< order-a order-b))
     ((and order-a (null order-b)) t)
     ((and (null order-a) order-b) nil)

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
          (let ((b-id (org-with-point-at b-marker (or (org-id-get) (org-id-get-create)))))
            (when (gethash b-id pool-ids)
              (puthash b-id (cons task-id (gethash b-id adj-list)) adj-list)
              (puthash task-id (1+ (gethash task-id in-degree 0)) in-degree))))))

    ;; 2. Add Implicit Sibling Blockers Edges
    (maphash (lambda (parent group)
               (let ((sorted-group
                      (sort group
                            (lambda (a b)
                              (let* ((dec-a (org-auto-scheduler-get-saved-decision (nth 5 a) (nth 0 a)))
                                     (dec-b (org-auto-scheduler-get-saved-decision (nth 5 b) (nth 0 b)))
                                     (order-a (and dec-a (plist-get dec-a :order)))
                                     (order-b (and dec-b (plist-get dec-b :order))))
                                (cond
                                 ((and order-a order-b (not (= order-a order-b)))
                                  (< order-a order-b))
                                 (order-a t)
                                 (order-b nil)
                                 (t (< (cdr (nth 4 a)) (cdr (nth 4 b))))))))))
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
                (marker (nth 7 item))
                (is-autosch (member "AUTOSCH" tags))
                (is-non-blocking (or (null consider-for-conflicts)
                                     (org-auto-scheduler-task-non-blocking-p task-id marker)))
                (needs-buffer (or (member "buffertime" tags) (member "buffertime" proposed-tags)))
                (active-gap (if needs-buffer 15 org-auto-scheduler-task-gap))
                (task-start-with-gap (time-subtract task-start (seconds-to-time (* 60 active-gap))))
                (task-end-with-gap (time-add task-end (seconds-to-time (* 60 active-gap)))))
           (when (and task-start  ; guard against nil timestamps from bad cache entries
                      task-end
                      (not (equal task-id ignore-id))
                      (not (and (not is-autosch) is-non-blocking))
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
  (org-auto-scheduler-cleanup-placeholders)
  (org-auto-scheduler-load-review-decisions)
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
               (_ (org-auto-scheduler--merge-saved-decisions tasks))
               (sorted-tasks-info (org-auto-scheduler-sort-tasks tasks))
               (current-time (org-auto-scheduler-get-start-time))
               (tasks-scheduled 0)
               (total-tasks (length sorted-tasks-info))
               (previous-project nil))

          (let ((reporter (make-progress-reporter "Scheduling tasks..." 0 total-tasks)))
            (dolist (task-info sorted-tasks-info)
              (let* ((task-id (nth 5 task-info))
                     (raw-marker (car task-info))
                     (marker (org-auto-scheduler--resolve-task-marker raw-marker task-id))
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

(defun org-auto-scheduler--set-scheduled (schedule-str)
  "Safely set SCHEDULED planning info on current heading to SCHEDULE-STR.
Uses `org-schedule` directly to avoid `org-entry-put` advancing to the next
heading when the current heading does not yet have a planning line."
  (org-back-to-heading t)
  (org-schedule nil schedule-str))

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
              (is-placeholder (or (member org-auto-scheduler-placeholder-tag tags)
                                  (org-entry-get nil "AUTOSCH_PLACEHOLDER")))
              (headline (org-get-heading t t t t))
              (not-before (org-entry-get nil "NOT_BEFORE"))
              (recurring (org-entry-get nil "RECURRING"))
              (scheduled (org-entry-get nil "SCHEDULED"))
              (file (buffer-file-name)))
         ;; Check if the task is not in an archived state and not a placeholder
         (when (and is-autosch is-valid-state (not (member "ARCHIVE" tags)) (not is-placeholder))
           (if recurring
               (progn
                 (org-auto-scheduler--log-debug "Creating instances for recurring task: %s in file %s" headline file)
                 (let ((new-instances (org-auto-scheduler-create-recurring-instances headline recurring scheduled not-before)))
                   (setq tasks (append new-instances tasks))))
             (org-auto-scheduler--log-debug "Adding non-recurring task: %s from file %s" headline file)
             (let ((m (point-marker)))
               (set-marker-insertion-type m t)
               (push m tasks))))
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
        (org-auto-scheduler--set-scheduled (format-time-string "<%Y-%m-%d %a>" last-instance-date))))
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
      (let ((m (point-marker)))
        (set-marker-insertion-type m t)
        m))))  ; Return the point marker

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

(defun org-auto-scheduler--get-day-midnight (time)
  "Return the midnight time (00:00:00 of the following calendar day) for TIME."
  (let* ((next-day-decoded (decode-time (time-add time (days-to-time 1)))))
    (encode-time 0 0 0
                 (nth 3 next-day-decoded)
                 (nth 4 next-day-decoded)
                 (nth 5 next-day-decoded))))

(defun org-auto-scheduler--parse-flexible-time (raw-time &optional marker)
  "Parse RAW-TIME (HH:MM, YYYY-MM-DD HH:MM, or Org timestamp) into Emacs time.
If only HH:MM is specified, uses the date from MARKER, review override, or today."
  (let* ((clean (string-trim (if (stringp raw-time) raw-time "") "[<>\s	
]+"))
         (has-date (string-match "\([0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}\)" clean))
         (date-part (when has-date (match-string 1 clean)))
         (has-time (string-match "\([0-9]\{1,2\}:[0-9]\{2\}\)" clean))
         (time-part (when has-time (match-string 1 clean))))
    (cond
     ((null raw-time) nil)
     ((listp raw-time) raw-time)
     ((and date-part time-part)
      (org-auto-scheduler-parse-time-string (concat date-part " " time-part)))
     (time-part
      (let* ((base-date
              (or (when (and marker (markerp marker) (marker-buffer marker))
                    (org-with-point-at marker
                      (let* ((tid (org-id-get))
                             (over (and tid (bound-and-true-p org-auto-scheduler--review-overrides)
                                        (gethash tid org-auto-scheduler--review-overrides)))
                             (t-date (or (and over (plist-get over :target-date))
                                         (and over (plist-get over :pinned-date)))))
                        (or t-date
                            (let ((sched (org-entry-get nil "SCHEDULED")))
                              (when (and sched (string-match "\([0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}\)" sched))
                                (match-string 1 sched)))))))
                  (format-time-string "%Y-%m-%d"))))
        (org-auto-scheduler-parse-time-string (concat base-date " " time-part))))
     (date-part
      (org-auto-scheduler-parse-time-string (concat date-part " " org-auto-scheduler-start-time)))
     (t
      (condition-case nil
          (org-time-string-to-time clean)
        (error (current-time)))))))

(defun org-auto-scheduler-task-splittable-p (marker &optional task-id)
  "Return non-nil if task at MARKER or TASK-ID is marked as splittable.
Checks review overrides, tags (`org-auto-scheduler-splittable-tag'),
or property (`org-auto-scheduler-split-property')."
  (let* ((tid (or task-id (when (and marker (markerp marker) (marker-buffer marker))
                            (org-with-point-at marker (org-id-get)))))
         (override (org-auto-scheduler--get-review-override tid)))
    (cond
     ((and override (plist-member override :splittable))
      (plist-get override :splittable))
     ((and marker (markerp marker) (marker-buffer marker))
      (org-with-point-at marker
        (let* ((tags (org-get-tags))
               (prop (org-entry-get nil org-auto-scheduler-split-property)))
          (or (member org-auto-scheduler-splittable-tag tags)
              (and prop (not (member (downcase prop) '("nil" "no" "0" ""))))))))
     (t nil))))

(defun org-auto-scheduler-task-toggle-splittable (&optional marker task-id)
  "Toggle SPLITTABLE status of task at MARKER or TASK-ID.
Adds or removes `org-auto-scheduler-splittable-tag' and sets/clears
`org-auto-scheduler-split-property'. Also updates review overrides.
Returns non-nil if task is now splittable, nil otherwise."
  (let* ((m (or marker
                (when (and task-id (stringp task-id))
                  (org-id-find task-id t))
                (and (derived-mode-p 'org-mode) (point-marker))))
         (tid (or task-id
                  (when (and m (markerp m) (marker-buffer m))
                    (org-with-point-at m (or (org-id-get) (org-id-get-create)))))))
    (unless (and m (markerp m) (marker-buffer m))
      (user-error "Cannot find task marker"))
    (org-with-point-at m
      (let* ((tags (org-get-tags nil t))
             (is-split (org-auto-scheduler-task-splittable-p m tid))
             (new-split (not is-split)))
        (if is-split
            (progn
              (setq tags (delete org-auto-scheduler-splittable-tag tags))
              (if (fboundp 'org-set-tags-to)
                  (org-set-tags-to tags)
                (org-set-tags tags))
              (org-delete-property org-auto-scheduler-split-property))
          (progn
            (cl-pushnew org-auto-scheduler-splittable-tag tags :test #'string=)
            (if (fboundp 'org-set-tags-to)
                (org-set-tags-to tags)
              (org-set-tags tags))
            (org-set-property org-auto-scheduler-split-property "t")))
        (when (and tid (bound-and-true-p org-auto-scheduler--review-overrides))
          (let ((over (gethash tid org-auto-scheduler--review-overrides)))
            (puthash tid (plist-put over :splittable new-split)
                     org-auto-scheduler--review-overrides)))
        new-split))))

(defun org-auto-scheduler-task-pinnable-p (marker &optional task-id)
  "Return non-nil if task at MARKER or TASK-ID is marked as pinnable.
Checks review overrides, headline tags, properties, and saved decisions."
  (let* ((tid (or task-id (when (and marker (markerp marker) (marker-buffer marker))
                            (org-with-point-at marker (org-id-get)))))
         (override (org-auto-scheduler--get-review-override tid))
         (override-pinnable (and override (or (plist-get override :pinnable)
                                              (plist-get override :pinned-time))))
         (saved-dec (and tid (org-auto-scheduler-get-saved-decision tid marker)))
         (saved-pinnable (and saved-dec (or (plist-get saved-dec :pinnable)
                                            (plist-get saved-dec :pinned-time)))))
    (cond
     (override-pinnable t)
     ((and override (plist-member override :pinnable) (null (plist-get override :pinnable))) nil)
     (saved-pinnable t)
     ((and marker (markerp marker) (marker-buffer marker))
      (org-with-point-at marker
        (let* ((tags (org-get-tags))
               (prop (org-entry-get nil org-auto-scheduler-pinnable-property))
               (time-prop (or (org-entry-get nil org-auto-scheduler-pinned-time-property)
                              (org-entry-get nil "PINNED"))))
          (or (member org-auto-scheduler-pinnable-tag tags)
              (and prop (not (member (downcase prop) '("nil" "no" "0" ""))))
              (and time-prop (not (string-empty-p (string-trim time-prop))))))))
     (t nil))))

(defun org-auto-scheduler-task-pinned-time (marker &optional task-id)
  "Return the parsed pinned time for task at MARKER or TASK-ID as an Emacs time value, or nil."
  (let* ((tid (or task-id (when (and marker (markerp marker) (marker-buffer marker))
                            (org-with-point-at marker (org-id-get)))))
         (override (and tid (bound-and-true-p org-auto-scheduler--review-overrides)
                        (gethash tid org-auto-scheduler--review-overrides)))
         (override-time (and override (plist-get override :pinned-time)))
         (saved-dec (and tid (org-auto-scheduler-get-saved-decision tid marker)))
         (saved-time (and saved-dec (plist-get saved-dec :pinned-time)))
         (prop-time (when (and marker (markerp marker) (marker-buffer marker))
                      (org-with-point-at marker
                        (or (org-entry-get nil org-auto-scheduler-pinned-time-property)
                            (org-entry-get nil "PINNED")))))
         (sched-time (when (and marker (markerp marker) (marker-buffer marker)
                                (org-auto-scheduler-task-pinnable-p marker tid))
                       (org-with-point-at marker
                         (org-entry-get nil "SCHEDULED"))))
         (raw-time (or override-time saved-time prop-time sched-time)))
    (when raw-time
      (org-auto-scheduler--parse-flexible-time raw-time marker))))

(defun org-auto-scheduler-task-set-pinnable (marker &optional task-id time-str unpin)
  "Mark or unmark task at MARKER or TASK-ID as PINNABLE.
If UNPIN is non-nil or TIME-STR is nil/empty, unpins the task.
Otherwise pins the task to TIME-STR.  Returns the formatted pinned time or nil."
  (let* ((m (or marker
                (when (and task-id (stringp task-id))
                  (org-id-find task-id t))
                (and (derived-mode-p 'org-mode) (point-marker))))
         (tid (or task-id
                  (when (and m (markerp m) (marker-buffer m))
                    (org-with-point-at m (or (org-id-get) (org-id-get-create)))))))
    (unless (and m (markerp m) (marker-buffer m))
      (user-error "Cannot find task marker"))
    (org-with-point-at m
      (let ((tags (org-get-tags nil t)))
        (if (or unpin (null time-str) (string-empty-p (string-trim time-str)))
            (progn
              (setq tags (delete org-auto-scheduler-pinnable-tag tags))
              (if (fboundp 'org-set-tags-to)
                  (org-set-tags-to tags)
                (org-set-tags tags))
              (org-delete-property org-auto-scheduler-pinnable-property)
              (org-delete-property org-auto-scheduler-pinned-time-property)
              (org-delete-property "PINNED")
              (when (and tid (bound-and-true-p org-auto-scheduler--review-overrides))
                (let ((over (gethash tid org-auto-scheduler--review-overrides)))
                  (when over
                    (setq over (plist-put over :pinnable nil))
                    (setq over (plist-put over :pinned-time nil))
                    (puthash tid over org-auto-scheduler--review-overrides))))
              nil)
          (let* ((parsed (org-auto-scheduler--parse-flexible-time time-str m))
                 (formatted-time (format-time-string "%Y-%m-%d %H:%M" parsed))
                 (date-str (format-time-string "%Y-%m-%d" parsed)))
            (cl-pushnew org-auto-scheduler-pinnable-tag tags :test #'string=)
            (if (fboundp 'org-set-tags-to)
                (org-set-tags-to tags)
              (org-set-tags tags))
            (org-set-property org-auto-scheduler-pinnable-property "t")
            (org-set-property org-auto-scheduler-pinned-time-property formatted-time)
            (when (and tid (bound-and-true-p org-auto-scheduler--review-overrides))
              (let ((over (gethash tid org-auto-scheduler--review-overrides)))
                (puthash tid (plist-put (plist-put (plist-put (plist-put over :pinnable t)
                                                              :pinned-time formatted-time)
                                                   :pinned-date date-str)
                                        :target-date date-str)
                         org-auto-scheduler--review-overrides)))
            formatted-time))))))

(defun org-auto-scheduler--get-pinned-tasks-reservations (&optional target-date-str)
  "Return a list of pseudo agenda items for all tasks marked PINNABLE with a time.
Each item is (TASK-ID START-TIME END-TIME TAGS t HEADLINE t MARKER).
If TARGET-DATE-STR is non-nil (YYYY-MM-DD), only returns items for that date."
  (let ((items '())
        (seen (make-hash-table :test 'equal)))
    ;; 1. Check review overrides
    (when (bound-and-true-p org-auto-scheduler--review-overrides)
      (maphash
       (lambda (tid over)
         (when (and (plist-get over :pinnable)
                    (plist-get over :pinned-time))
           (let* ((pt (org-auto-scheduler-task-pinned-time nil tid))
                  (d-str (and pt (format-time-string "%Y-%m-%d" pt))))
             (when (and pt (or (null target-date-str) (string= d-str target-date-str)))
               (let* ((eff (or (plist-get over :effort) 60))
                      (midnight (org-auto-scheduler--get-day-midnight pt))
                      (avail (floor (/ (float-time (time-subtract midnight pt)) 60)))
                      (chunk (min eff (max 1 avail)))
                      (end (time-add pt (seconds-to-time (* 60 chunk)))))
                 (puthash tid t seen)
                 (push (list tid pt end '("AUTOSCH" "PINNABLE") t "Pinned Task" t nil) items))))))
       org-auto-scheduler--review-overrides))
    ;; 2. Check saved review decisions
    (when (bound-and-true-p org-auto-scheduler--saved-review-decisions)
      (dolist (pair org-auto-scheduler--saved-review-decisions)
        (let* ((tid (car pair))
               (dec (cdr pair)))
          (when (and (not (gethash tid seen))
                     (plist-get dec :pinnable)
                     (plist-get dec :pinned-time))
            (let* ((pt (org-auto-scheduler-task-pinned-time nil tid))
                   (d-str (and pt (format-time-string "%Y-%m-%d" pt))))
              (when (and pt (or (null target-date-str) (string= d-str target-date-str)))
                (let* ((eff 60)
                       (midnight (org-auto-scheduler--get-day-midnight pt))
                       (avail (floor (/ (float-time (time-subtract midnight pt)) 60)))
                       (chunk (min eff (max 1 avail)))
                       (end (time-add pt (seconds-to-time (* 60 chunk)))))
                  (puthash tid t seen)
                  (push (list tid pt end '("AUTOSCH" "PINNABLE") t "Pinned Task" t nil) items))))))))
    items))

(defun org-auto-scheduler--place-split-placeholders (origin-id headline marker topo-depth rem-effort min-chunk tags time-block active-gap search-time start-date-str)
  "Place REM-EFFORT across subsequent slots/days as placeholder subtasks.
Returns the end-time of the last placeholder scheduled today, or SEARCH-TIME."
  (let* ((part-num 1)
         (current-date-str (format-time-string "%Y-%m-%d" search-time))
         (days-checked 0)
         (max-attempts (* 10 (max 1 org-auto-scheduler-max-days-to-check)))
         (attempts 0)
         (last-today-end search-time))
    (while (and (> rem-effort 0)
                (< days-checked org-auto-scheduler-max-days-to-check)
                (< attempts max-attempts))
      (setq attempts (1+ attempts))
      (let* ((req-dur (min rem-effort min-chunk))
             (ph-slot (if time-block
                          (org-auto-scheduler-next-available-time-in-block search-time time-block req-dur)
                        (org-auto-scheduler-next-available-time search-time req-dur tags))))
        (if (null ph-slot)
            (progn
              (setq search-time (org-auto-scheduler-next-day-start search-time))
              (let ((new-date-str (format-time-string "%Y-%m-%d" search-time)))
                (unless (string= current-date-str new-date-str)
                  (setq days-checked (1+ days-checked))
                  (setq current-date-str new-date-str))))
          (let* ((avail-here (org-auto-scheduler--available-duration-at ph-slot rem-effort tags))
                 (chunk-dur (if (>= avail-here rem-effort)
                                rem-effort
                              (if (>= avail-here min-chunk)
                                  avail-here
                                (min rem-effort (max avail-here min-chunk))))))
            (if (or (null chunk-dur) (<= chunk-dur 0))
                (progn
                  (setq search-time (org-auto-scheduler-next-day-start ph-slot))
                  (let ((new-date-str (format-time-string "%Y-%m-%d" search-time)))
                    (unless (string= current-date-str new-date-str)
                      (setq days-checked (1+ days-checked))
                      (setq current-date-str new-date-str))))
              (let* ((ph-end (time-add ph-slot (seconds-to-time (* 60 chunk-dur))))
                     (ph-id (format "%s-remaining-%d" origin-id part-num))
                     (ph-start-day (format-time-string "%Y-%m-%d" ph-slot))
                     (ph-end-day (format-time-string "%Y-%m-%d" ph-end))
                     (ph-sched-str
                      (if (string= ph-start-day ph-end-day)
                          (format "<%s-%s>"
                                  (format-time-string "%Y-%m-%d %a %H:%M" ph-slot)
                                  (format-time-string "%H:%M" ph-end))
                        (format "<%s>--<%s>"
                                (format-time-string "%Y-%m-%d %a %H:%M" ph-slot)
                                (format-time-string "%Y-%m-%d %a %H:%M" ph-end))))
                     (ph-headline (if (and (= part-num 1) (<= (- rem-effort chunk-dur) 0))
                                      (format "%s %s" headline org-auto-scheduler-placeholder-suffix)
                                    (format "%s %s Part %d" headline org-auto-scheduler-placeholder-suffix part-num)))
                     (ph-entry (list ph-id ph-slot ph-end (list org-auto-scheduler-placeholder-tag) t
                                     ph-headline ph-sched-str marker topo-depth :placeholder
                                     (list (format "Remaining: %dm" chunk-dur))
                                     :origin-id origin-id :remaining-effort chunk-dur)))
                (if org-auto-scheduler--preview-mode
                    (push ph-entry org-auto-scheduler-completed-tasks)
                  (org-auto-scheduler--create-placeholder-subtask
                   marker ph-headline ph-slot ph-end chunk-dur origin-id)
                  (push ph-entry org-auto-scheduler-completed-tasks))
                (setq rem-effort (- rem-effort chunk-dur))
                (setq part-num (1+ part-num))
                (when (string= ph-start-day start-date-str)
                  (setq last-today-end ph-end))
                (setq search-time (time-add ph-end (seconds-to-time (* 60 active-gap))))
                (let ((new-date-str (format-time-string "%Y-%m-%d" search-time)))
                  (unless (string= current-date-str new-date-str)
                    (setq days-checked (1+ days-checked))
                    (setq current-date-str new-date-str)))))))))
    last-today-end))

(defun org-auto-scheduler-get-min-chunk (marker)
  "Return the minimum chunk duration in minutes for task at MARKER."
  (let ((prop (and marker (markerp marker) (marker-buffer marker)
                   (org-with-point-at marker
                     (org-entry-get nil org-auto-scheduler-min-chunk-property)))))
    (if (and prop (string-match-p "^[0-9]+$" (string-trim prop)))
        (string-to-number (string-trim prop))
      org-auto-scheduler-split-min-chunk)))

(defun org-auto-scheduler--available-duration-at (start-time max-needed &optional proposed-tags)
  "Calculate contiguous available minutes at START-TIME up to MAX-NEEDED minutes.
Considers day boundaries (start/end times, excluded days) and existing agenda conflicts.
Returns the number of available minutes (integer)."
  (let* ((day-start (org-auto-scheduler-time-with-time-string start-time org-auto-scheduler-start-time))
         (day-end (org-auto-scheduler-time-with-time-string start-time org-auto-scheduler-end-time))
         (day-of-week (string-to-number (format-time-string "%w" start-time))))
    (cond
     ((member day-of-week org-auto-scheduler-excluded-days) 0)
     ((time-less-p start-time day-start) 0)
     ((not (time-less-p start-time day-end)) 0)
     ;; Check if START-TIME itself is immediately occupied (test 1 minute)
     ((org-auto-scheduler-time-slot-occupied-p start-time 1 nil proposed-tags) 0)
     (t
      ;; START-TIME is open. Find the earliest upcoming obstacle.
      (let* ((earliest-stop day-end)
             (agenda-items (org-auto-scheduler-get-agenda-items start-time)))
        (dolist (item agenda-items)
          (let* ((item-start (nth 1 item))
                 (item-tags (nth 3 item))
                 (item-id (nth 0 item))
                 (marker (nth 7 item))
                 (consider-for-conflicts (nth 4 item))
                 (is-autosch (member "AUTOSCH" item-tags))
                 (is-nb (or (null consider-for-conflicts)
                            (org-auto-scheduler-task-non-blocking-p item-id marker)))
                 (needs-buffer (or (member "buffertime" item-tags)
                                   (member "buffertime" proposed-tags)))
                 (active-gap (if needs-buffer 15 org-auto-scheduler-task-gap))
                 (item-start-with-gap (when item-start
                                        (time-subtract item-start (seconds-to-time (* 60 active-gap))))))
            (when (and item-start
                       (not (and (not is-autosch) is-nb))
                       item-start-with-gap
                       (time-less-p start-time item-start-with-gap))
              (when (time-less-p item-start-with-gap earliest-stop)
                (setq earliest-stop item-start-with-gap)))))
        (let ((avail-minutes (floor (/ (float-time (time-subtract earliest-stop start-time)) 60))))
          (max 0 (min (or max-needed avail-minutes) avail-minutes))))))))

(defun org-auto-scheduler--insert-clock-entries (clock-lines)
  "Insert CLOCK-LINES into the LOGBOOK of the current heading."
  (org-back-to-heading t)
  (let ((end (save-excursion (or (outline-next-heading) (point-max)))))
    (if (re-search-forward ":LOGBOOK:" end t)
        (progn
          (forward-line 1)
          (dolist (line clock-lines)
            (insert "  " (string-trim line) "\n")))
      (org-end-of-meta-data t)
      (insert "  :LOGBOOK:\n")
      (dolist (line clock-lines)
        (insert "  " (string-trim line) "\n"))
      (insert "  :END:\n"))))

(defun org-auto-scheduler--resolve-task-marker (marker &optional task-id)
  "Resolve MARKER, ensuring it points to the correct heading for TASK-ID.
If MARKER has drifted (or its heading ID no longer matches TASK-ID),
attempt to locate the heading via `org-id-find'."
  (if (and task-id (stringp task-id) (not (string-empty-p task-id)))
      (if (and marker (markerp marker) (marker-buffer marker)
               (org-with-point-at marker
                 (equal (org-id-get) task-id)))
          marker
        (let ((found (org-id-find task-id 'marker)))
          (if (and found (markerp found))
              (progn
                (set-marker-insertion-type found t)
                found)
            marker)))
    marker))

(defun org-auto-scheduler--create-placeholder-subtask (parent-marker headline start-time end-time effort parent-id)
  "Create a placeholder child subtask under PARENT-MARKER for remaining EFFORT.
START-TIME and END-TIME define the scheduled window."
  (when (and parent-marker (markerp parent-marker) (marker-buffer parent-marker))
    (org-with-point-at parent-marker
      (let* ((parent-state (org-get-todo-state))
             (origin-id (or parent-id (org-id-get-create)))
             (start-day (format-time-string "%Y-%m-%d" start-time))
             (end-day (format-time-string "%Y-%m-%d" end-time))
             (schedule-str (if (string= start-day end-day)
                               (format "<%s-%s>"
                                       (format-time-string "%Y-%m-%d %a %H:%M" start-time)
                                       (format-time-string "%H:%M" end-time))
                             (format "<%s>--<%s>"
                                     (format-time-string "%Y-%m-%d %a %H:%M" start-time)
                                     (format-time-string "%Y-%m-%d %a %H:%M" end-time)))))
        (save-excursion
          (org-back-to-heading t)
          (org-insert-heading-respect-content)
          (org-do-demote)
          (insert headline)
          (when parent-state
            (org-todo parent-state))
          (if (fboundp 'org-set-tags-to)
              (org-set-tags-to (list org-auto-scheduler-placeholder-tag))
            (org-set-tags (list org-auto-scheduler-placeholder-tag)))
          (org-back-to-heading t)
          (org-auto-scheduler--set-scheduled schedule-str)
          (org-set-property org-auto-scheduler-scheduled-property "t")
          (org-set-property "AUTOSCH_ORIGIN_ID" origin-id)
          (org-set-property "AUTOSCH_PLACEHOLDER" "t")
          (org-set-property "Effort" (format "%d:%02d" (/ effort 60) (% effort 60)))
          (org-id-get-create)
          (let ((pm (point-marker)))
            (set-marker-insertion-type pm t)
            pm))))))

(defun org-auto-scheduler-cleanup-placeholders ()
  "Remove all temporary auto-scheduler placeholder tasks across agenda files.
Safeguards:
1. If the placeholder contains any clock entries, transfer them to the parent task.
2. If the placeholder was marked DONE, mark the parent task DONE as well."
  (interactive)
  (let ((total-deleted 0)
        (total-clocks-preserved 0)
        (files (org-agenda-files t)))
    (dolist (file files)
      (when (and file (file-exists-p file))
        (with-current-buffer (find-file-noselect file)
          ;; Fast string pre-check: avoid running org-map-entries over all headings
          ;; if the placeholder tag or property does not exist in the buffer at all.
          (let ((has-placeholders
                 (save-excursion
                   (goto-char (point-min))
                   (or (search-forward org-auto-scheduler-placeholder-tag nil t)
                       (search-forward "AUTOSCH_PLACEHOLDER" nil t)))))
            (when has-placeholders
              (let ((modified nil)
                    (placeholders '()))
                ;; Collect all placeholder markers first
                (org-map-entries
                 (lambda ()
                   (let* ((tags (org-get-tags))
                          (is-ph-tag (member org-auto-scheduler-placeholder-tag tags))
                          (is-ph-prop (org-entry-get nil "AUTOSCH_PLACEHOLDER")))
                     (when (or is-ph-tag is-ph-prop)
                       (push (point-marker) placeholders))))
                 nil nil)
                ;; Process collected placeholders in reverse order (bottom to top)
                (dolist (ph-marker placeholders)
                  (when (and (markerp ph-marker) (marker-buffer ph-marker))
                    (org-with-point-at ph-marker
                      (let* ((origin-id (org-entry-get nil "AUTOSCH_ORIGIN_ID"))
                             (ph-state (org-get-todo-state))
                             (is-done (and ph-state (member ph-state org-done-keywords)))
                             (parent-marker (or (and origin-id (org-id-find origin-id 'marker))
                                                (save-excursion
                                                  (when (org-up-heading-safe)
                                                    (point-marker)))))
                             (clocks '()))
                        ;; Extract CLOCK lines from LOGBOOK if any
                        (save-excursion
                          (let ((end (save-excursion (or (outline-next-heading) (point-max)))))
                            (when (re-search-forward ":LOGBOOK:" end t)
                              (let ((lb-start (point))
                                    (lb-end (if (re-search-forward ":END:" end t)
                                                (match-beginning 0)
                                              end)))
                                (goto-char lb-start)
                                (while (re-search-forward "^[ \t]*CLOCK:.*$" lb-end t)
                                  (push (match-string 0) clocks))))))
                        ;; Delete the placeholder subtree FIRST
                        (org-back-to-heading t)
                        (org-cut-subtree)
                        (setq modified t)
                        (setq total-deleted (1+ total-deleted))
                        ;; Transfer clocks to parent if found
                        (when (and clocks parent-marker (markerp parent-marker) (marker-buffer parent-marker))
                          (let ((clock-lines (nreverse clocks)))
                            (org-with-point-at parent-marker
                              (org-auto-scheduler--insert-clock-entries clock-lines))
                            (setq total-clocks-preserved (+ total-clocks-preserved (length clock-lines)))
                            (org-auto-scheduler--log-info "[org-auto-scheduler-cleanup-placeholders] Preserved %d clock entries from placeholder to parent task"
                                                          (length clock-lines))))
                        ;; If placeholder was marked DONE, mark parent DONE
                        (when (and is-done parent-marker (markerp parent-marker) (marker-buffer parent-marker))
                          (org-with-point-at parent-marker
                            (org-todo (or (car org-done-keywords) "DONE")))
                          (org-auto-scheduler--log-info "[org-auto-scheduler-cleanup-placeholders] Marked parent task DONE based on completed placeholder"))))))
                (when modified
                  (save-buffer))))))))
    (when (or (> total-deleted 0) (> total-clocks-preserved 0))
      (org-auto-scheduler--log-info "[org-auto-scheduler-cleanup-placeholders] Cleaned up %d placeholders, preserved %d clock entries"
                                    total-deleted total-clocks-preserved)
      (when (called-interactively-p 'interactive)
        (message "Cleaned up %d placeholders (preserved %d clock entries)"
                 total-deleted total-clocks-preserved)))
    total-deleted))

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
             (saved-dec (and task-id (org-auto-scheduler-get-saved-decision task-id marker)))
             (is-saved-skipped (and saved-dec
                                    (not (bound-and-true-p org-auto-scheduler--ignore-saved-skips-p))
                                    (plist-get saved-dec :skipped)))
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

        (cond
         (is-saved-skipped
          (org-auto-scheduler--log-info "[org-auto-scheduler-schedule-single-task] Task '%s' is marked skipped in saved decisions." headline)
          (when org-auto-scheduler--preview-mode
            (push (list task-id start-time start-time '("AUTOSCH") nil headline
                        "SKIPPED" marker (or topo-depth 0) :skipped '("Skipped in previous session"))
                  org-auto-scheduler-completed-tasks))
          current-time)

         ((not all-blockers-met)
          (org-auto-scheduler--log-info "[org-auto-scheduler-schedule-single-task] Task '%s' is blocked by unmet dependencies. Skipping." headline)
          ;; Record blocked tasks so they appear in the review buffer
          (when org-auto-scheduler--preview-mode
            (push (list task-id current-time current-time '("AUTOSCH") nil headline
                            "BLOCKED" marker (or topo-depth 0) :blocked '("Blocked by unmet dependencies"))
                  org-auto-scheduler-completed-tasks))
          current-time) ; Return current-time unmodified since task wasn't scheduled

         (t
          ;; Task is not blocked, proceed to find an available time
          (let* ((tags (org-get-tags marker))
                 (needs-buffer (member "buffertime" tags))
                 (active-gap (if needs-buffer 15 org-auto-scheduler-task-gap))
                 (is-pinnable (when (bound-and-true-p org-auto-scheduler--reordering-p)
                                (org-auto-scheduler-task-pinnable-p marker task-id)))
                 (pinned-time (when (and (bound-and-true-p org-auto-scheduler--reordering-p) is-pinnable)
                                (org-auto-scheduler-task-pinned-time marker task-id)))
                 (is-splittable (or (org-auto-scheduler-task-splittable-p marker task-id)
                                    (and is-pinnable pinned-time)))
                 (min-chunk (org-auto-scheduler-get-min-chunk marker))
                 (split-result nil))
            (cond
             ;; -------------------------------------------------------------
             ;; PINNABLE task path: set to given time, can exceed day hours,
             ;; and if remaining effort crosses midnight, treat as SPLITTABLE.
             ;; -------------------------------------------------------------
             ((and (bound-and-true-p org-auto-scheduler--reordering-p) is-pinnable pinned-time)
              (let* ((origin-id (or task-id (org-with-point-at marker (org-id-get-create))))
                     (start-date-str (format-time-string "%Y-%m-%d" pinned-time))
                     (midnight (org-auto-scheduler--get-day-midnight pinned-time))
                     (avail-before-midnight (max 1 (floor (/ (float-time (time-subtract midnight pinned-time)) 60))))
                     (fits-before-midnight (<= remaining-effort avail-before-midnight)))
                (if fits-before-midnight
                    ;; Fits before midnight: schedule entire task today at pinned-time
                    (let* ((end-time (time-add pinned-time (seconds-to-time (* 60 remaining-effort))))
                           (end-day-str (format-time-string "%Y-%m-%d" end-time))
                           (schedule-string
                            (if (string= start-date-str end-day-str)
                                (format "<%s-%s>"
                                        (format-time-string "%Y-%m-%d %a %H:%M" pinned-time)
                                        (format-time-string "%H:%M" end-time))
                              (format "<%s>--<%s>"
                                      (format-time-string "%Y-%m-%d %a %H:%M" pinned-time)
                                      (format-time-string "%Y-%m-%d %a %H:%M" end-time)))))
                      (if org-auto-scheduler--preview-mode
                          (push (list (or task-id origin-id) pinned-time end-time '("AUTOSCH") t headline schedule-string marker topo-depth)
                                org-auto-scheduler-completed-tasks)
                        (org-auto-scheduler--set-scheduled schedule-string)
                        (org-set-property org-auto-scheduler-scheduled-property "t")
                        (push (list (or task-id origin-id) pinned-time end-time '("AUTOSCH") t headline schedule-string nil topo-depth)
                              org-auto-scheduler-completed-tasks))
                      (org-auto-scheduler--log-info "[org-auto-scheduler-schedule-single-task] Scheduled PINNED task '%s' from %s to %s (Effort: %dm)"
                                                    headline
                                                    (format-time-string "%Y-%m-%d %H:%M" pinned-time)
                                                    (format-time-string "%Y-%m-%d %H:%M" end-time)
                                                    remaining-effort)
                      (time-add end-time (seconds-to-time (* 60 active-gap))))
                  ;; Does NOT fit before midnight: treated as SPLITTABLE to next day!
                  (let* ((today-chunk avail-before-midnight)
                         (today-end midnight)
                         (rem-effort (- remaining-effort today-chunk))
                         (today-end-day (format-time-string "%Y-%m-%d" today-end))
                         (schedule-string
                          (if (string= start-date-str today-end-day)
                              (format "<%s-%s>"
                                      (format-time-string "%Y-%m-%d %a %H:%M" pinned-time)
                                      (format-time-string "%H:%M" today-end))
                            (format "<%s>--<%s>"
                                    (format-time-string "%Y-%m-%d %a %H:%M" pinned-time)
                                    (format-time-string "%Y-%m-%d %a %H:%M" today-end)))))
                    (if org-auto-scheduler--preview-mode
                        (push (list (or task-id origin-id) pinned-time today-end '("AUTOSCH") t headline schedule-string marker topo-depth :split-today nil :split-today t)
                              org-auto-scheduler-completed-tasks)
                      (org-auto-scheduler--set-scheduled schedule-string)
                      (org-set-property org-auto-scheduler-scheduled-property "t")
                      (push (list (or task-id origin-id) pinned-time today-end '("AUTOSCH") t headline schedule-string nil topo-depth :split-today nil :split-today t)
                            org-auto-scheduler-completed-tasks))
                    ;; Place remaining effort on subsequent days starting from next day start
                    (let* ((next-day-start (org-auto-scheduler-next-day-start pinned-time))
                           (last-end (org-auto-scheduler--place-split-placeholders
                                      origin-id headline marker topo-depth rem-effort min-chunk
                                      tags time-block active-gap next-day-start start-date-str)))
                      (org-auto-scheduler--log-info "[org-auto-scheduler-schedule-single-task] Split PINNED task '%s': today %dm (until midnight), remaining %dm across subsequent days"
                                                    headline today-chunk rem-effort)
                      (time-add last-end (seconds-to-time (* 60 active-gap))))))))

             ;; -------------------------------------------------------------
             ;; Standard task path (with normal SPLITTABLE support)
             ;; -------------------------------------------------------------
             (t
              (while (and available-time (not end-time) (not split-result) (< attempts max-attempts))
                (setq attempts (1+ attempts))
                (when available-time
                  (setq end-time (time-add available-time (seconds-to-time (* 60 remaining-effort))))
                  (let ((occupied-result (org-auto-scheduler-time-slot-occupied-p available-time remaining-effort task-id tags)))
                    (when occupied-result
                      (setq end-time nil)
                      ;; If splittable, check if we can take the available slot right now
                      (let ((avail-now (when is-splittable
                                         (org-auto-scheduler--available-duration-at available-time remaining-effort tags))))
                        (if (and is-splittable
                                 avail-now
                                 (>= avail-now min-chunk)
                                 (< avail-now remaining-effort))
                            ;; Split the task: schedule today's chunk, then place remaining effort on subsequent days
                            (let* ((today-chunk avail-now)
                                   (today-end (time-add available-time (seconds-to-time (* 60 today-chunk))))
                                   (rem-effort (- remaining-effort today-chunk))
                                   (today-start-day (format-time-string "%Y-%m-%d" available-time))
                                   (today-end-day (format-time-string "%Y-%m-%d" today-end))
                                   (schedule-string
                                    (if (string= today-start-day today-end-day)
                                        (format "<%s-%s>"
                                                (format-time-string "%Y-%m-%d %a %H:%M" available-time)
                                                (format-time-string "%H:%M" today-end))
                                      (format "<%s>--<%s>"
                                              (format-time-string "%Y-%m-%d %a %H:%M" available-time)
                                              (format-time-string "%Y-%m-%d %a %H:%M" today-end))))
                                   (origin-id (or task-id (org-with-point-at marker (org-id-get-create)))))

                              ;; 1. Schedule main task for today
                              (if org-auto-scheduler--preview-mode
                                  (push (list task-id available-time today-end '("AUTOSCH") t headline schedule-string marker topo-depth :split-today nil :split-today t)
                                        org-auto-scheduler-completed-tasks)
                                (org-auto-scheduler--set-scheduled schedule-string)
                                (org-set-property org-auto-scheduler-scheduled-property "t")
                                (push (list task-id available-time today-end '("AUTOSCH") t headline schedule-string nil topo-depth :split-today nil :split-today t)
                                      org-auto-scheduler-completed-tasks))

                              ;; 2. Place remaining effort across today and subsequent days as placeholder subtasks
                              (let* ((search-time (time-add today-end (seconds-to-time (* 60 active-gap))))
                                     (last-end (org-auto-scheduler--place-split-placeholders
                                                origin-id headline marker topo-depth rem-effort min-chunk
                                                tags time-block active-gap search-time today-start-day)))
                                (org-auto-scheduler--log-info "[org-auto-scheduler-schedule-single-task] Split task '%s': initial chunk %dm (%s to %s)"
                                                              headline today-chunk
                                                              (format-time-string "%H:%M" available-time))
                                (setq split-result (time-add last-end (seconds-to-time (* 60 active-gap))))))

                          ;; Cannot split: advance normally
                          (setq available-time (if time-block
                                                   (org-auto-scheduler-next-available-time-in-block occupied-result time-block remaining-effort)
                                                 (org-auto-scheduler-next-available-time occupied-result remaining-effort)))))))))
            (cond
             (split-result
              split-result)
             (end-time
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
                    (org-auto-scheduler--set-scheduled schedule-string)
                    (org-set-property org-auto-scheduler-scheduled-property "t")
                    (push (list task-id available-time end-time '("AUTOSCH") t headline schedule-string nil topo-depth) org-auto-scheduler-completed-tasks))
                  (org-auto-scheduler--log-info "[org-auto-scheduler-schedule-single-task] Scheduled task '%s' from %s to %s (Remaining effort: %d minutes, Gap: %dm)"
                                                headline
                                                (format-time-string "%Y-%m-%d %H:%M" available-time)
                                                (format-time-string "%Y-%m-%d %H:%M" end-time)
                                                remaining-effort active-gap)
                  (org-auto-scheduler--log-debug "[org-auto-scheduler-schedule-single-task] Adding task %s to the list of completed scheduling tasks"
                                                 task-id))
                (time-add end-time (seconds-to-time (* 60 active-gap)))))
             (t
              (org-auto-scheduler--log-warn "[org-auto-scheduler-schedule-single-task] Could not find available time slot within 7 days for task: %s" headline)
              (org-auto-scheduler--log-debug "[org-auto-scheduler-schedule-single-task] Scheduling failed after %d attempts" attempts)
              (org-auto-scheduler--log-debug "[org-auto-scheduler-schedule-single-task] Last attempted time: %s" (format-time-string "%Y-%m-%d %H:%M" available-time))
              ;; Record failed tasks so they appear in the review buffer with error status
              (when org-auto-scheduler--preview-mode
                (push (list task-id current-time current-time '("AUTOSCH") nil headline
                            "FAILED" marker (or topo-depth 0) :failed '("No available slot within 7 days"))
                      org-auto-scheduler-completed-tasks))
              current-time)))))))))))

(defvar org-auto-scheduler--reordering-p nil
  "Internal flag non-nil when recalculating schedule during review reordering.
When nil (initial schedule), tasks are scheduled according to usual order
respecting working hours and task score.")

(defvar org-auto-scheduler--ignore-blockers-p nil
  "Internal flag to dynamically bypass all dependency blockers when recalculating visual order.")

(defun org-auto-scheduler--evaluate-blockers (marker)
  "Evaluate if all blockers for MARKER have been met for current scheduling.
A blocker is met if it's either already DONE, or it has been scheduled
in the current run (`org-auto-scheduler-completed-tasks`).
If `org-auto-scheduler--ignore-blockers-p` is dynamically bound to t, ignores dependencies entirely.
Returns a cons cell `(all-met-p . latest-end-time)` where `latest-end-time`
is the maximum end time of any blocker scheduled (or nil if none)."
  (if org-auto-scheduler--ignore-blockers-p
      (cons t nil)
    (let ((blockers (org-auto-scheduler-get-blockers marker))
          (all-met t)
          (latest-end nil))
      (dolist (b-marker blockers)
        (when all-met ; Short-circuit checking
          (let* ((b-id (org-with-point-at b-marker (org-id-get)))
                 ;; Search for blocker in freshly scheduled tasks
                 (scheduled-b (or (cl-find b-marker org-auto-scheduler-completed-tasks
                                           :key (lambda (x) (nth 7 x)))
                                  (and b-id (assoc b-id org-auto-scheduler-completed-tasks)))))
            (if (and scheduled-b (not (memq (nth 9 scheduled-b) '(:failed :blocked :skipped))))
                ;; Blocker was scheduled cleanly; we must start after it ends.
                (let ((b-end-time (nth 2 scheduled-b)))
                  (when (or (null latest-end) (time-less-p latest-end b-end-time))
                    (setq latest-end b-end-time)))
              ;; Blocker is NOT DONE (since it's in active blockers) AND NOT scheduled cleanly
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
        (error "org-auto-scheduler-excluded-days must contain integers from 0 to 6")))
    (unless (and (stringp org-auto-scheduler-non-blocking-property)
                 (not (string-empty-p org-auto-scheduler-non-blocking-property)))
      (error "org-auto-scheduler-non-blocking-property must be a non-empty string"))
    (unless (memq org-auto-scheduler-non-blocking-backend '(both state-file config-file org-properties))
      (error "org-auto-scheduler-non-blocking-backend must be one of: 'both, 'state-file, 'org-properties"))))

(defun org-auto-scheduler-get-not-before (marker)
  "Get the NOT_BEFORE property for the task at MARKER.
Checks for what-if overrides in the review buffer or saved decisions if active."
  (let* ((task-id (org-with-point-at marker (org-id-get)))
         (override (org-auto-scheduler--get-review-override task-id))
         (override-date (or (plist-get override :pinned-date)
                            (unless (bound-and-true-p org-auto-scheduler--ignore-target-dates-p)
                              (plist-get override :target-date))))
         (saved-dec (and task-id (null override-date)
                         (org-auto-scheduler-get-saved-decision task-id marker)))
         (saved-date (and saved-dec
                          (unless (bound-and-true-p org-auto-scheduler--ignore-target-dates-p)
                            (plist-get saved-dec :target-date))))
         (effective-date (or override-date saved-date)))
    (if effective-date
        (org-auto-scheduler-parse-time-string (concat effective-date " 00:00"))
      (let ((not-before-string (org-entry-get marker "NOT_BEFORE")))
        (when not-before-string
          (org-time-string-to-time not-before-string))))))

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
                 (agenda-item (list task-id current-start-time current-end-time tags t task-name t marker)))
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

(defconst org-auto-scheduler--status-accent-colors
  '(:placeholder "#e5c07b" :warning "#d19a66" :blocker "#e06c75")
  "Accent colors blended into a task's own color to signal status, used
where a status can only be shown through color -- an org-timegrid
block's background and a table row's depth badge -- rather than
through a separate face on a plain-text icon or label.  See
`org-auto-scheduler--status-blend-color'.")

(defun org-auto-scheduler--blend-colors (color1 color2 weight)
  "Blend COLOR1 and COLOR2, weighted WEIGHT (0.0-1.0) toward COLOR2.
Accepts anything `color-name-to-rgb' does (a color name or a hex
string); returns a \"#rrggbb\" hex string.  nil COLOR1 is treated as
COLOR2 alone (nothing to blend it with)."
  (if (null color1)
      color2
    (let ((rgb1 (color-name-to-rgb color1))
          (rgb2 (color-name-to-rgb color2)))
      (apply #'color-rgb-to-hex
             (append (cl-mapcar (lambda (a b) (+ (* a (- 1 weight)) (* b weight))) rgb1 rgb2)
                     '(2))))))

(defun org-auto-scheduler--status-blend-color (base-color task marker)
  "Return BASE-COLOR (a task's own project color, may be nil) blended
toward a status accent -- gold for a placeholder/continuation chunk,
orange for a warning, red for an unmet-dependency violation -- for
anywhere a status can only be shown through color: an org-timegrid
block's background (its title text cannot be tinted per-character, see
`org-auto-scheduler--review-status-icon-info') and a table row's depth
badge (in place of a text label like \"[Placeholder]\").  Falls back to
the accent alone when there is no project color to blend with, and to
BASE-COLOR unchanged when TASK has no notable status."
  (let* ((status (nth 9 task))
         ;; A placeholder's own warnings slot always carries its synthetic
         ;; "Remaining: Nm" note (see the ph-entry push in
         ;; `org-auto-scheduler-schedule-single-task'), which is
         ;; informational, not a problem -- so, exactly like the table's
         ;; own St-column `stat-str' cond, :placeholder must be checked
         ;; before treating that as a real warning.
         (auto-warnings (unless (eq status :placeholder)
                          (org-auto-scheduler--check-task-warnings task marker)))
         (all-warnings (unless (eq status :placeholder)
                        (append (if (listp (nth 10 task)) (nth 10 task) nil) auto-warnings)))
         (has-blocker-violation (cl-some (lambda (w) (string-prefix-p "⛔" w)) all-warnings))
         (accent (cond
                  (has-blocker-violation (plist-get org-auto-scheduler--status-accent-colors :blocker))
                  (all-warnings (plist-get org-auto-scheduler--status-accent-colors :warning))
                  ((eq status :placeholder) (plist-get org-auto-scheduler--status-accent-colors :placeholder))
                  (t nil)))
         (weight (cond (has-blocker-violation 0.55) (all-warnings 0.35) (t 0.3))))
    (if accent
        (org-auto-scheduler--blend-colors base-color accent weight)
      base-color)))

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
     (warnings             (propertize "⚠" 'face 'warning
                                       'help-echo (mapconcat #'identity (reverse warnings) "\n")))
     (t                    (propertize "✓" 'face 'success)))))

(defun org-auto-scheduler--check-task-warnings (task marker)
  "Check for scheduling warnings on TASK and return a list of warning strings."
  (let ((warnings nil)
        (time-block (org-auto-scheduler-get-task-tag-block marker))
        (not-before (org-with-point-at marker (org-entry-get nil "NOT_BEFORE")))
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
    ;; Explicit Org NOT_BEFORE constraint property set?
    (when not-before
      (push "📌 NOT_BEFORE constraint" warnings))
    ;; Default effort used?
    (unless effort-prop
      (push "Using default effort estimate" warnings))
    ;; Explicit Blocker / Dependency Checks
    (when (and marker (markerp marker) (marker-buffer marker))
      (let ((resolved (org-auto-scheduler--resolve-blocker-specs marker)))
        (dolist (item resolved)
          (let ((b (plist-get item :marker))
                (id (plist-get item :id))
                (err (plist-get item :error)))
            (cond
             ;; Missing / unresolvable blocker:
             ((null b)
              (push (format "⛔ Blocker not found: %s (%s)" (or id "target") (or err "missing"))
                    warnings))
             ;; Resolved blocker marker:
             (t
              (let* ((todo (org-with-point-at b (org-get-todo-state)))
                     (is-done (member todo org-done-keywords)))
                ;; If not DONE, check how blocker is scheduled
                (unless is-done
                  (let* ((b-head (or (org-with-point-at b (org-get-heading t t t t)) "Blocker task"))
                         (b-id (org-with-point-at b (org-id-get)))
                         (b-task (or (cl-find b org-auto-scheduler-completed-tasks
                                              :key (lambda (x) (nth 7 x)))
                                     (and b-id (assoc b-id org-auto-scheduler-completed-tasks)))))
                    (cond
                     (b-task
                      (let ((b-status (nth 9 b-task))
                            (b-start (nth 1 b-task))
                            (b-end (nth 2 b-task)))
                        (cond
                         ((eq b-status :skipped)
                          (push (format "⛔ Blocker is unchecked/skipped: %s"
                                        (org-auto-scheduler--truncate b-head 30))
                                warnings))
                         ((eq b-status :failed)
                          (push (format "⛔ Blocker failed to schedule: %s"
                                        (org-auto-scheduler--truncate b-head 30))
                                warnings))
                         ((eq b-status :blocked)
                          (push (format "⛔ Blocker itself is blocked: %s"
                                        (org-auto-scheduler--truncate b-head 30))
                                warnings))
                         ((and start b-end (time-less-p start b-end))
                          (let ((b-time (format-time-string "%a %H:%M" (or b-start b-end))))
                            (push (format "⛔ Scheduled before blocker '%s' (%s)"
                                          (org-auto-scheduler--truncate b-head 25) b-time)
                                  warnings))))))
                     (t
                      (push (format "⛔ Blocker not scheduled: %s"
                                    (org-auto-scheduler--truncate b-head 30))
                            warnings))))))))))))
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

(defun org-auto-scheduler--tabulated-list-printer (id cols)
  "Custom printer to render full-width day separators, header shortcut banner, and event rows."
  (cond
   ((and (stringp id) (string= id "__header_shortcuts"))
    (let ((beg (point)))
      (insert (aref cols 2) "
")
      (put-text-property beg (point) 'tabulated-list-id id)
      (put-text-property beg (point) 'tabulated-list-entry cols)))
   ((and (stringp id) (string-prefix-p "__sep_" id))
    (let ((beg (point)))
      (insert "  " (aref cols 2) "
")
      (put-text-property beg (point) 'tabulated-list-id id)
      (put-text-property beg (point) 'tabulated-list-entry cols)))
   ((and (stringp id) (string-prefix-p "__event_" id))
    (let ((beg (point)))
      (tabulated-list-print-entry id cols)
      (let ((marker (get-text-property 0 'event-marker (aref cols 2)))
            (eid (get-text-property 0 'event-id (aref cols 2))))
        (when marker
          (put-text-property beg (point) 'event-marker marker))
        (when eid
          (put-text-property beg (point) 'event-id eid)))))
   (t
    (tabulated-list-print-entry id cols))))

(defun org-auto-scheduler--review-header-line (entries)
  "Build the `header-line-format' string from ENTRIES."
  (let ((total 0) (hours 0.0) (projects (make-hash-table :test 'equal))
        (min-date nil) (max-date nil) (today-count 0)
        (today-str (format-time-string "%Y-%m-%d")))
    (dolist (e entries)
      (let* ((vec (cadr e))
             (id (car e)))
        (unless (org-auto-scheduler--review-special-row-p id)
          (cl-incf total)
          (let* ((dur-str (aref vec 4))
                 (dur (string-to-number dur-str))
                 (proj (aref vec 5)))
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
      (let* ((date-range-str (cond
                              ((and min-date max-date (string= min-date max-date))
                               (let ((parsed (org-auto-scheduler-parse-time-string (concat min-date " 00:00"))))
                                 (if parsed (format-time-string "%b %d" parsed) min-date)))
                              ((and min-date max-date)
                               (let* ((p1 (org-auto-scheduler-parse-time-string (concat min-date " 00:00")))
                                      (p2 (org-auto-scheduler-parse-time-string (concat max-date " 00:00")))
                                      (d1 (if p1 (format-time-string "%b %d" p1) min-date))
                                      (d2 (if p2 (format-time-string "%b %d" p2) max-date)))
                                 (format "%s–%s" d1 d2)))
                              (t nil)))
             (today-info (if (> today-count 0)
                             (format "%d today" today-count)
                           (if date-range-str
                               (format "0 today (%s)" date-range-str)
                             "0 today")))
             (legend (format " %d tasks │ %.1fh │ %s │%s"
                             total hours today-info proj-legend)))
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
  ;; Day shifting
  (define-key map (kbd ">")     #'org-auto-scheduler-review-move-day-forward)
  (define-key map (kbd "<")     #'org-auto-scheduler-review-move-day-backward)
  (define-key map (kbd "+")     #'org-auto-scheduler-review-move-day-forward)
  (define-key map (kbd "-")     #'org-auto-scheduler-review-move-day-backward)
  (define-key map (kbd "M-<down>") #'org-auto-scheduler-review-move-day-forward)
  (define-key map (kbd "M-<up>")   #'org-auto-scheduler-review-move-day-backward)
  (define-key map (kbd "d")     #'org-auto-scheduler-review-move-to-date)
  (define-key map (kbd "P")     #'org-auto-scheduler-review-move-before)
  ;; Recalculate / Refresh
  (define-key map (kbd "r")   #'org-auto-scheduler-review-recalculate)
  (define-key map (kbd "C-c C-r") #'org-auto-scheduler-review-recalculate)
  (define-key map (kbd "R")   #'org-auto-scheduler-review-refresh)
  ;; Save / Reset / Merge decisions
  (define-key map (kbd "S")   #'org-auto-scheduler-review-save-decisions)
  (define-key map (kbd "C-c C-s") #'org-auto-scheduler-review-save-decisions)
  (define-key map (kbd "M")   #'org-auto-scheduler-review-restore-and-merge)
  (define-key map (kbd "C-c C-m") #'org-auto-scheduler-review-restore-and-merge)
  (define-key map (kbd "C")   #'org-auto-scheduler-clear-saved-decisions)
  (define-key map (kbd "C-c C-d") #'org-auto-scheduler-clear-saved-decisions)
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
  (define-key map (kbd "T")   #'org-auto-scheduler-review-open-timegrid)
  ;; Toggle fixed agenda events
  (define-key map (kbd "E")   #'org-auto-scheduler-review-toggle-agenda-events)
  ;; Non-blocking toggle for fixed events
  (define-key map (kbd "b")   #'org-auto-scheduler-review-toggle-non-blocking)
  ;; Splittable and Pinnable shortcuts
  (define-key map (kbd "s")   #'org-auto-scheduler-review-toggle-splittable)
  (define-key map (kbd "p")   #'org-auto-scheduler-review-toggle-pinnable)
  (define-key map (kbd "i")   #'org-auto-scheduler-review-toggle-pinnable)
  ;; Help
  (define-key map (kbd "?")   #'org-auto-scheduler-review-help))

;; Evil/Spacemacs compatibility: let the full mode map (including the
;; "f" filter and "*" bulk-mark prefixes) win over evil state bindings.
(with-eval-after-load 'evil
  (dolist (state '(normal motion))
    (evil-define-key state org-auto-scheduler-review-mode-map
      ;; Core operations
      (kbd "RET")     #'org-auto-scheduler-review-toggle
      (kbd "TAB")     #'org-auto-scheduler-review-jump
      (kbd "SPC")     #'org-auto-scheduler-review-toggle
      (kbd "m")       #'org-auto-scheduler-review-toggle
      (kbd "b")       #'org-auto-scheduler-review-toggle-non-blocking
      (kbd "s")       #'org-auto-scheduler-review-toggle-splittable
      (kbd "p")       #'org-auto-scheduler-review-toggle-pinnable
      (kbd "i")       #'org-auto-scheduler-review-toggle-pinnable
      (kbd "x")       #'org-auto-scheduler-review-execute
      (kbd "C-c C-c") #'org-auto-scheduler-review-execute
      ;; Reordering
      (kbd "K")       #'org-auto-scheduler-review-move-up
      (kbd "J")       #'org-auto-scheduler-review-move-down
      (kbd "U")       #'org-auto-scheduler-review-move-up
      (kbd "D")       #'org-auto-scheduler-review-move-down
      ;; Day shifting
      (kbd ">")        #'org-auto-scheduler-review-move-day-forward
      (kbd "<")        #'org-auto-scheduler-review-move-day-backward
      (kbd "+")        #'org-auto-scheduler-review-move-day-forward
      (kbd "-")        #'org-auto-scheduler-review-move-day-backward
      (kbd "M-<down>") #'org-auto-scheduler-review-move-day-forward
      (kbd "M-<up>")   #'org-auto-scheduler-review-move-day-backward
      (kbd "d")        #'org-auto-scheduler-review-move-to-date
      ;; Recalculate / Refresh / Undo / Save / Merge
      (kbd "r")       #'org-auto-scheduler-review-recalculate
      (kbd "C-c C-r") #'org-auto-scheduler-review-recalculate
      (kbd "R")       #'org-auto-scheduler-review-refresh
      (kbd "S")       #'org-auto-scheduler-review-save-decisions
      (kbd "M")       #'org-auto-scheduler-review-restore-and-merge
      (kbd "C")       #'org-auto-scheduler-clear-saved-decisions
      (kbd "u")       #'org-auto-scheduler-review-undo
      ;; What-if
      (kbd "e")       #'org-auto-scheduler-review-edit-effort
      ;; Views
      (kbd "c")       #'org-auto-scheduler-review-toggle-calendar
      (kbd "v")       #'org-auto-scheduler-review-toggle-calendar
      (kbd "T")       #'org-auto-scheduler-review-open-timegrid
      ;; Move before another task (keyboard drag-to-position)
      (kbd "P")       #'org-auto-scheduler-review-move-before
      ;; Filters
      (kbd "f t")     #'org-auto-scheduler-review-filter-today
      (kbd "f p")     #'org-auto-scheduler-review-filter-project
      (kbd "f a")     #'org-auto-scheduler-review-filter-clear
      (kbd "/")       #'org-auto-scheduler-review-filter-regexp
      ;; Bulk operations
      (kbd "* a")     #'org-auto-scheduler-review-mark-all
      (kbd "* n")     #'org-auto-scheduler-review-unmark-all
      (kbd "* t")     #'org-auto-scheduler-review-mark-today
      (kbd "* p")     #'org-auto-scheduler-review-mark-project
      (kbd "* %")     #'org-auto-scheduler-review-mark-regexp
      ;; Toggle fixed agenda events
      (kbd "E")       #'org-auto-scheduler-review-toggle-agenda-events
      ;; Help
      (kbd "?")       #'org-auto-scheduler-review-help)))

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
  (setq-local tabulated-list-printer #'org-auto-scheduler--tabulated-list-printer)
  (tabulated-list-init-header))

(defun org-auto-scheduler-review-toggle ()
  "Toggle the apply checkmark for the task at point.
On fixed agenda events, toggles their non-blocking status instead.
In calendar view on fixed agenda events, toggles their non-blocking status."
  (interactive)
  (if (eq org-auto-scheduler--review-view 'calendar)
      (let ((event-marker (get-text-property (point) 'event-marker))
            (event-id (get-text-property (point) 'event-id)))
        (if (or event-marker event-id)
            (org-auto-scheduler-review-toggle-non-blocking)
          (org-auto-scheduler-review-jump)))
    (let* ((id (tabulated-list-get-id))
           (entry (tabulated-list-get-entry)))
      (cond
       ((and id (string-prefix-p "__event_" id))
        (org-auto-scheduler-review-toggle-non-blocking))
       ((and entry id (not (org-auto-scheduler--review-special-row-p id)))
        (org-auto-scheduler--review-push-undo)
        (aset entry 0 (if (string= (aref entry 0) "[X]") "[ ]" "[X]"))
        (tabulated-list-print t)
        (forward-line 1))))))

(defun org-auto-scheduler-review-toggle-non-blocking ()
  "Toggle non-blocking status of the event at point in the review buffer.
Works in both Table view and Calendar view."
  (interactive)
  (unless (eq major-mode 'org-auto-scheduler-review-mode)
    (user-error "Not in an Org Auto Scheduler Review buffer"))
  (if (eq org-auto-scheduler--review-view 'calendar)
      ;; Calendar View
      (let* ((event-id (get-text-property (point) 'event-id))
             (event-marker (get-text-property (point) 'event-marker))
             (task-id (get-text-property (point) 'task-id)))
        (cond
         ((or event-id event-marker)
          (let* ((m (or event-marker (when event-id (org-id-find event-id t))))
                 (tid (or event-id (when m (org-with-point-at m (or (org-id-get) (org-id-get-create))))))
                 (headline (or (and m (org-with-point-at m (org-get-heading t t t t))) "Event"))
                 (is-nb (org-auto-scheduler-task-non-blocking-p tid m)))
            (if is-nb
                (progn
                  (org-auto-scheduler-unmark-non-blocking tid m)
                  (message "Event '%s' marked BLOCKING. Press 'r' to recalculate schedule." headline))
              (org-auto-scheduler-mark-non-blocking tid m headline)
              (message "Event '%s' marked NON-BLOCKING. Press 'r' to recalculate schedule." headline))
            (org-auto-scheduler--render-calendar-view)))
         (task-id
          (user-error "This is an AUTOSCH task; non-blocking status is for fixed agenda events"))
         (t
          (user-error "No event at point in calendar view"))))
    ;; Table View
    (let* ((row-id (tabulated-list-get-id))
           (entry (tabulated-list-get-entry)))
      (cond
       ((and row-id (string-prefix-p "__event_" row-id))
        (org-auto-scheduler--review-push-undo)
        (let* ((marker (or (get-text-property (point) 'event-marker)
                           (and entry (get-text-property 0 'event-marker (aref entry 2)))
                           (and entry (get-text-property 0 'event-marker (aref entry 1)))
                           (and entry (get-text-property 0 'event-marker (aref entry 0)))))
               (task-id (or (get-text-property (point) 'event-id)
                            (and entry (get-text-property 0 'event-id (aref entry 2)))
                            (and entry (get-text-property 0 'event-id (aref entry 1)))
                            (and entry (get-text-property 0 'event-id (aref entry 0)))))
               (m (or marker (when task-id (org-id-find task-id t))))
               (tid (or task-id (when m (org-with-point-at m (or (org-id-get) (org-id-get-create))))))
               (headline (or (and m (org-with-point-at m (org-get-heading t t t t)))
                             (and entry (string-trim (substring-no-properties (aref entry 2))))
                             "Event"))
               (is-nb (org-auto-scheduler-task-non-blocking-p tid m)))
          (if is-nb
              (progn
                (org-auto-scheduler-unmark-non-blocking tid m)
                (message "Event '%s' marked BLOCKING. Press 'r' to recalculate schedule." headline))
            (org-auto-scheduler-mark-non-blocking tid m headline)
            (message "Event '%s' marked NON-BLOCKING. Press 'r' to recalculate schedule." headline))
          ;; Update entry in place in tabulated-list-entries and org-auto-scheduler--review-all-entries
          (when entry
            (let ((new-nb (not is-nb)))
              (aset entry 1 (propertize "📅"
                                        'face (if new-nb 'default 'shadow)
                                        'event-marker m 'event-id tid))
              (let ((hl-text (substring-no-properties (aref entry 2))))
                (aset entry 2 (propertize hl-text
                                          'face (if new-nb 'italic 'shadow)
                                          'event-marker m
                                          'event-id tid
                                          'non-blocking new-nb)))
              (let* ((orig-tag (substring-no-properties (aref entry 5)))
                     (clean-tag (replace-regexp-in-string " \\[NB\\]" "" orig-tag))
                     (new-tag (if new-nb (concat clean-tag " [NB]") clean-tag)))
                (aset entry 5 (propertize new-tag
                                          'face (if new-nb 'font-lock-doc-face 'shadow)
                                          'event-marker m 'event-id tid)))
              (aset entry 7 (propertize (if new-nb "" "🔒")
                                        'face (if new-nb 'font-lock-doc-face 'shadow)
                                        'event-marker m 'event-id tid))
              (let ((cached (assoc row-id org-auto-scheduler--review-all-entries)))
                (when cached
                  (setcdr cached (list entry))))
              (tabulated-list-print t)))))
       ((and row-id (not (org-auto-scheduler--review-special-row-p row-id)))
        (user-error "This is an AUTOSCH task; non-blocking status is for fixed agenda events"))
       (t
        (user-error "Not on an agenda event row"))))))

(defun org-auto-scheduler-agenda-toggle-non-blocking ()
  "Toggle non-blocking status of the agenda event at point."
  (interactive)
  (unless (derived-mode-p 'org-agenda-mode)
    (user-error "Not in an Org Agenda buffer"))
  (let* ((marker (or (org-get-at-bol 'org-marker)
                     (get-text-property (point) 'org-marker))))
    (if (not marker)
        (user-error "No agenda item at point")
      (let* ((tags (org-with-point-at marker (org-get-tags)))
             (headline (org-with-point-at marker (org-get-heading t t t t))))
        (if (member "AUTOSCH" tags)
            (user-error "Item '%s' is an AUTOSCH task; non-blocking is for fixed agenda events" headline)
          (let* ((task-id (org-with-point-at marker (or (org-id-get) (org-id-get-create))))
                 (is-nb (org-auto-scheduler-task-non-blocking-p task-id marker)))
            (if is-nb
                (progn
                  (org-auto-scheduler-unmark-non-blocking task-id marker)
                  (message "Agenda event '%s' marked as BLOCKING." headline))
              (org-auto-scheduler-mark-non-blocking task-id marker headline)
              (message "Agenda event '%s' marked as NON-BLOCKING." headline))
            (org-agenda-redo)))))))

(defun org-auto-scheduler-toggle-non-blocking (&optional task-id marker)
  "Toggle non-blocking status of the task or event at point.
Works across Org buffers, Org Agenda, the Review buffer, and Calendar."
  (interactive)
  (cond
   ;; In Review buffer
   ((eq major-mode 'org-auto-scheduler-review-mode)
    (org-auto-scheduler-review-toggle-non-blocking))
   ;; In Org Agenda
   ((derived-mode-p 'org-agenda-mode)
    (org-auto-scheduler-agenda-toggle-non-blocking))
   ;; In Calendar mode
   ((derived-mode-p 'calendar-mode)
    (let* ((c-date (calendar-cursor-to-date t))
           (date-str (format "%04d-%02d-%02d" (nth 2 c-date) (nth 0 c-date) (nth 1 c-date)))
           (events (org-auto-scheduler--get-existing-events-for-date date-str)))
      (if (null events)
          (message "No non-AUTOSCH events found for %s." date-str)
        (let* ((ev (if (= (length events) 1)
                       (car events)
                     (let* ((choices (mapcar (lambda (e)
                                               (cons (format "%s (%s)" (nth 5 e) (format-time-string "%H:%M" (nth 1 e))) e))
                                             events))
                            (sel (completing-read "Select event: " (mapcar #'car choices) nil t)))
                       (cdr (assoc sel choices)))))
               (ev-id (nth 0 ev))
               (ev-m (or (nth 7 ev) (when ev-id (org-id-find ev-id t))))
               (ev-hl (nth 5 ev))
               (is-nb (org-auto-scheduler-task-non-blocking-p ev-id ev-m)))
          (if is-nb
              (progn
                (org-auto-scheduler-unmark-non-blocking ev-id ev-m)
                (message "Event '%s' is now BLOCKING." ev-hl))
            (org-auto-scheduler-mark-non-blocking ev-id ev-m ev-hl)
            (message "Event '%s' is now NON-BLOCKING." ev-hl))))))
   ;; In Org Mode buffer
   ((derived-mode-p 'org-mode)
    (let* ((m (or marker (point-marker)))
           (tags (org-with-point-at m (org-get-tags)))
           (headline (org-with-point-at m (org-get-heading t t t t))))
      (if (member "AUTOSCH" tags)
          (user-error "Task '%s' has AUTOSCH tag; non-blocking status is for fixed/non-autosch tasks" headline)
        (let* ((tid (org-with-point-at m (or (org-id-get) (org-id-get-create))))
               (is-nb (org-auto-scheduler-task-non-blocking-p tid m)))
          (if is-nb
              (progn
                (org-auto-scheduler-unmark-non-blocking tid m)
                (message "Task '%s' is now BLOCKING." headline))
            (org-auto-scheduler-mark-non-blocking tid m headline)
            (message "Task '%s' is now NON-BLOCKING." headline))))))
   ;; Explicit arguments passed
   ((or task-id marker)
    (let* ((m (or marker (when task-id (org-id-find task-id t))))
           (is-nb (org-auto-scheduler-task-non-blocking-p task-id m)))
      (if is-nb
          (org-auto-scheduler-unmark-non-blocking task-id m)
        (org-auto-scheduler-mark-non-blocking task-id m))))
   (t
    (user-error "Cannot determine task or event at point"))))

(with-eval-after-load 'org-agenda
  (define-key org-agenda-mode-map (kbd "C-c C-x n") #'org-auto-scheduler-agenda-toggle-non-blocking)
  (define-key org-agenda-mode-map (kbd "C-c C-x N") #'org-auto-scheduler-agenda-toggle-non-blocking))


(defun org-auto-scheduler-review-jump ()
  "Jump to the original Org task or agenda event from the review buffer."
  (interactive)
  (let ((row-id (tabulated-list-get-id)))
    (cond
     ((and row-id (string-prefix-p "__sep_" row-id))
      (user-error "This is a separator line, not a task"))
     ((and row-id (string= row-id "__header_shortcuts"))
      (user-error "This is the shortcut banner, not a task"))
     ((and row-id (string-prefix-p "__event_" row-id))
      (let ((marker (get-text-property (point) 'event-marker))
            (eid (get-text-property (point) 'event-id)))
        (cond
         ((and marker (markerp marker) (marker-buffer marker) (marker-position marker))
          (switch-to-buffer-other-window (marker-buffer marker))
          (goto-char (marker-position marker))
          (org-show-context))
         ((and eid (stringp eid) (org-id-find eid t))
          (let ((m (org-id-find eid t)))
            (switch-to-buffer-other-window (marker-buffer m))
            (goto-char (marker-position m))
            (org-show-context)))
         (t
          (user-error "Event marker no longer valid")))))
     (t
      (let ((task-id (or row-id (get-text-property (point) 'task-id))))
        (if task-id
            (let ((marker (org-id-find task-id t)))
              (if marker
                  (progn
                    (switch-to-buffer-other-window (marker-buffer marker))
                    (goto-char marker)
                    (org-show-context))
                (user-error "Task marker no longer valid")))
          (user-error "No valid task ID found for this entry")))))))

(defun org-auto-scheduler--format-day-sep (date-str)
  "Format a day separator banner string for DATE-STR (YYYY-MM-DD)."
  (let* ((parsed (org-auto-scheduler-parse-time-string (concat date-str " 12:00")))
         (day-label (if parsed
                        (format-time-string "-- %A, %b %d " parsed)
                      (format "-- %s " date-str))))
    (concat day-label (make-string (max 0 (- 50 (length day-label))) ?-))))

(defun org-auto-scheduler--next-day-date-string (date-str)
  "Return the next non-excluded day's date string YYYY-MM-DD after DATE-STR."
  (let* ((current (org-auto-scheduler-parse-time-string (concat date-str " 12:00")))
         (next (time-add current (days-to-time 1)))
         (dow (string-to-number (format-time-string "%w" next))))
    (while (member dow org-auto-scheduler-excluded-days)
      (setq next (time-add next (days-to-time 1)))
      (setq dow (string-to-number (format-time-string "%w" next))))
    (format-time-string "%Y-%m-%d" next)))

(defun org-auto-scheduler--prev-day-date-string (date-str)
  "Return the previous non-excluded day's date string YYYY-MM-DD before DATE-STR."
  (let* ((current (org-auto-scheduler-parse-time-string (concat date-str " 12:00")))
         (prev (time-subtract current (days-to-time 1)))
         (dow (string-to-number (format-time-string "%w" prev))))
    (while (member dow org-auto-scheduler-excluded-days)
      (setq prev (time-subtract prev (days-to-time 1)))
      (setq dow (string-to-number (format-time-string "%w" prev))))
    (format-time-string "%Y-%m-%d" prev)))

(defun org-auto-scheduler--review-first-day-sep-p (sep-id)
  "Return t if SEP-ID is the first day separator in `tabulated-list-entries`."
  (let ((first-id nil))
    (dolist (e tabulated-list-entries)
      (let ((id (car e)))
        (when (and (not first-id) (stringp id) (string-prefix-p "__sep_" id))
          (setq first-id id))))
    (equal first-id sep-id)))

(defun org-auto-scheduler--review-get-task-day (&optional task-id)
  "Return the date string (YYYY-MM-DD) for the day containing TASK-ID.
If TASK-ID is nil, use task at point. Scans backward for the nearest day separator."
  (save-excursion
    (when task-id
      (goto-char (point-min))
      (while (and (not (eobp)) (not (equal (tabulated-list-get-id) task-id)))
        (forward-line 1)))
    (let ((found-date nil))
      (while (and (not found-date) (not (bobp)))
        (let ((id (tabulated-list-get-id)))
          (if (and (stringp id) (string-prefix-p "__sep_" id))
              (setq found-date (substring id 6))
            (forward-line -1))))
      (or found-date (format-time-string "%Y-%m-%d")))))

(defun org-auto-scheduler--review-goto-task (task-id)
  "Move point to the row for TASK-ID, if present in the current buffer."
  (when task-id
    (let ((orig-point (point)))
      (goto-char (point-min))
      (while (and (not (eobp)) (not (equal (tabulated-list-get-id) task-id)))
        (forward-line 1))
      (when (eobp)
        (goto-char orig-point)))))

(defun org-auto-scheduler--review-maybe-auto-recalculate (task-id)
  "Recalculate the schedule and re-park point on TASK-ID, per user setting.
No-op unless `org-auto-scheduler-review-auto-recalculate-on-move' is non-nil."
  (when org-auto-scheduler-review-auto-recalculate-on-move
    (org-auto-scheduler-review-recalculate)
    (org-auto-scheduler--review-goto-task task-id)))

(defun org-auto-scheduler-review-move-up ()
  "Move the current task up in the review list, crossing day boundaries if needed.
Recalculates the schedule immediately afterward unless
`org-auto-scheduler-review-auto-recalculate-on-move' is nil."
  (interactive)
  (let* ((id1 (tabulated-list-get-id))
         (id2 (save-excursion (forward-line -1) (tabulated-list-get-id))))
    (prog1
     (cond
     ((or (null id1) (org-auto-scheduler--review-special-row-p id1))
      (if (and id1 (string-prefix-p "__event_" id1))
          (user-error "Cannot move fixed agenda event")
        (user-error "Not on a task")))
     ((or (null id2) (string= id2 "__header_shortcuts"))
      (user-error "Task is already at the top of the schedule"))
     ((string-prefix-p "__sep_" id2)
      ;; Moving up across a day separator into the previous day
      (if (org-auto-scheduler--review-first-day-sep-p id2)
          (user-error "Task is already in the earliest scheduled day")
        (org-auto-scheduler--review-push-undo)
        (let* ((node1 (assoc id1 tabulated-list-entries))
               (node2 (assoc id2 tabulated-list-entries))
               (entry1 (and node1 (cadr node1)))
               (entry2 (and node2 (cadr node2))))
          (when (and node1 node2 entry1 entry2)
            (setcdr node1 (list entry2))
            (setcdr node2 (list entry1))
            (setcar node1 id2)
            (setcar node2 id1)
            (setq tabulated-list-sort-key nil)
            (setq org-auto-scheduler--review-all-entries (copy-sequence tabulated-list-entries))
            (tabulated-list-print t)
            (let ((new-day (org-auto-scheduler--review-get-task-day id1)))
              (puthash id1 (plist-put (plist-put (gethash id1 org-auto-scheduler--review-overrides)
                                                 :target-date new-day)
                                      :pinned-date new-day)
                       org-auto-scheduler--review-overrides)
              (message "Moved up across day separator into %s%s" new-day
                       (if org-auto-scheduler-review-auto-recalculate-on-move ""
                         " (press 'r' to recalculate)")))))))
     (t
      ;; Moving up past another task in the same day
      (org-auto-scheduler--review-push-undo)
      (let* ((node1 (assoc id1 tabulated-list-entries))
             (node2 (assoc id2 tabulated-list-entries))
             (entry1 (and node1 (cadr node1)))
             (entry2 (and node2 (cadr node2))))
        (when (and node1 node2 entry1 entry2)
          (setcdr node1 (list entry2))
          (setcdr node2 (list entry1))
          (setcar node1 id2)
          (setcar node2 id1)
          (setq tabulated-list-sort-key nil)
          (setq org-auto-scheduler--review-all-entries (copy-sequence tabulated-list-entries))
          (tabulated-list-print t)))))
     (org-auto-scheduler--review-maybe-auto-recalculate id1))))

(defun org-auto-scheduler-review-move-down ()
  "Move the current task down in the review list, crossing day boundaries if needed.
Recalculates the schedule immediately afterward unless
`org-auto-scheduler-review-auto-recalculate-on-move' is nil."
  (interactive)
  (let ((id1 (tabulated-list-get-id)))
    (if (or (null id1) (org-auto-scheduler--review-special-row-p id1))
        (if (and id1 (string-prefix-p "__event_" id1))
            (user-error "Cannot move fixed agenda event")
          (user-error "Not on a task"))
      (let ((id2 (save-excursion
                   (forward-line 1)
                   (if (eobp) nil (tabulated-list-get-id)))))
        (prog1
         (cond
         ((null id2)
          (user-error "Task is at the end of the schedule (use '>' to move to next day)"))
         ((string-prefix-p "__sep_" id2)
          ;; Moving down across a day separator into the next day
          (org-auto-scheduler--review-push-undo)
          (let* ((node1 (assoc id1 tabulated-list-entries))
                 (node2 (assoc id2 tabulated-list-entries))
                 (entry1 (and node1 (cadr node1)))
                 (entry2 (and node2 (cadr node2))))
            (when (and node1 node2 entry1 entry2)
              (setcdr node1 (list entry2))
              (setcdr node2 (list entry1))
              (setcar node1 id2)
              (setcar node2 id1)
              (setq tabulated-list-sort-key nil)
              (setq org-auto-scheduler--review-all-entries (copy-sequence tabulated-list-entries))
              (tabulated-list-print t)
              (let ((new-day (substring id2 6)))
                (puthash id1 (plist-put (plist-put (gethash id1 org-auto-scheduler--review-overrides)
                                                   :target-date new-day)
                                        :pinned-date new-day)
                         org-auto-scheduler--review-overrides)
                (message "Moved down across day separator into %s%s" new-day
                         (if org-auto-scheduler-review-auto-recalculate-on-move ""
                           " (press 'r' to recalculate)"))))))
         (t
          ;; Moving down past another task
          (org-auto-scheduler--review-push-undo)
          (let* ((node1 (assoc id1 tabulated-list-entries))
                 (node2 (assoc id2 tabulated-list-entries))
                 (entry1 (and node1 (cadr node1)))
                 (entry2 (and node2 (cadr node2))))
            (when (and node1 node2 entry1 entry2)
              (setcdr node1 (list entry2))
              (setcdr node2 (list entry1))
              (setcar node1 id2)
              (setcar node2 id1)
              (setq tabulated-list-sort-key nil)
              (setq org-auto-scheduler--review-all-entries (copy-sequence tabulated-list-entries))
              (tabulated-list-print t)))))
         (org-auto-scheduler--review-maybe-auto-recalculate id1))))))

(defun org-auto-scheduler-review-move-to-day (target-date)
  "Move the task at point to TARGET-DATE (string formatted as YYYY-MM-DD).
Recalculates the schedule immediately afterward unless
`org-auto-scheduler-review-auto-recalculate-on-move' is nil."
  (let* ((task-id (tabulated-list-get-id))
         (today-str (format-time-string "%Y-%m-%d")))
    (if (or (null task-id) (org-auto-scheduler--review-special-row-p task-id))
        (if (and task-id (string-prefix-p "__event_" task-id))
            (user-error "Cannot move fixed agenda event")
          (user-error "Not on a task"))
      (when (string< target-date today-str)
        (user-error "Cannot schedule tasks in the past (before %s)" today-str))
      (org-auto-scheduler--review-push-undo)
      (let* ((task-node (assoc task-id tabulated-list-entries))
             (target-sep-id (concat "__sep_" target-date))
             (existing-sep (assoc target-sep-id tabulated-list-entries))
             (task-data (assoc task-id org-auto-scheduler-completed-tasks))
             (headline (if task-data (nth 5 task-data) "task")))
        (unless task-node
          (user-error "Task not found in review list"))
        ;; Remove task-node from current tabulated-list-entries
        (setq tabulated-list-entries (delq task-node tabulated-list-entries))
        ;; If target separator doesn't exist, create it and insert in chronological order
        (unless existing-sep
          (let ((new-sep (list target-sep-id
                               (vector "" "" (propertize (org-auto-scheduler--format-day-sep target-date) 'face 'bold)
                                       "" "" "" "" "")))
                (inserted nil)
                (new-list nil))
            (dolist (item tabulated-list-entries)
              (let ((item-id (car item)))
                (if (and (not inserted)
                         (stringp item-id)
                         (string-prefix-p "__sep_" item-id)
                         (string< target-date (substring item-id 6)))
                    (progn
                      (push new-sep new-list)
                      (push item new-list)
                      (setq inserted t))
                  (push item new-list))))
            (unless inserted
              (push new-sep new-list))
            (setq tabulated-list-entries (nreverse new-list))))
        ;; Insert task-node directly under the target day's section (at end of that day's tasks)
        (let ((new-list nil)
              (placed nil)
              (in-target-day nil))
          (dolist (item tabulated-list-entries)
            (let ((item-id (car item)))
              (cond
               ((equal item-id target-sep-id)
                (push item new-list)
                (setq in-target-day t))
               ((and in-target-day (stringp item-id) (string-prefix-p "__sep_" item-id))
                (push task-node new-list)
                (push item new-list)
                (setq placed t)
                (setq in-target-day nil))
               (t
                (push item new-list)))))
          (unless placed
            (push task-node new-list))
          (setq tabulated-list-entries (nreverse new-list)))
        ;; Record target date and pinned date in review overrides
        (puthash task-id
                 (plist-put (plist-put (gethash task-id org-auto-scheduler--review-overrides)
                                       :target-date target-date)
                            :pinned-date target-date)
                 org-auto-scheduler--review-overrides)
        (setq org-auto-scheduler--review-all-entries (copy-sequence tabulated-list-entries))
        (tabulated-list-print t)
        (org-auto-scheduler--review-goto-task task-id)
        (message "Moved '%s' to %s%s" headline target-date
                 (if org-auto-scheduler-review-auto-recalculate-on-move ""
                   " (press 'r' to recalculate schedule)"))
        (org-auto-scheduler--review-maybe-auto-recalculate task-id)))))

(defun org-auto-scheduler-review-move-day-forward ()
  "Move the task at point to the next scheduled day."
  (interactive)
  (let* ((task-id (tabulated-list-get-id))
         (current-day (org-auto-scheduler--review-get-task-day task-id)))
    (if (or (null task-id) (org-auto-scheduler--review-special-row-p task-id))
        (if (and task-id (string-prefix-p "__event_" task-id))
            (user-error "Cannot move fixed agenda event")
          (user-error "Not on a task"))
      (let ((next-day (org-auto-scheduler--next-day-date-string current-day)))
        (org-auto-scheduler-review-move-to-day next-day)))))

(defun org-auto-scheduler-review-move-day-backward ()
  "Move the task at point to the previous scheduled day."
  (interactive)
  (let* ((task-id (tabulated-list-get-id))
         (current-day (org-auto-scheduler--review-get-task-day task-id)))
    (if (or (null task-id) (org-auto-scheduler--review-special-row-p task-id))
        (if (and task-id (string-prefix-p "__event_" task-id))
            (user-error "Cannot move fixed agenda event")
          (user-error "Not on a task"))
      (let ((prev-day (org-auto-scheduler--prev-day-date-string current-day))
            (today-str (format-time-string "%Y-%m-%d")))
        (when (string< prev-day today-str)
          (user-error "Cannot move task before today (%s)" today-str))
        (org-auto-scheduler-review-move-to-day prev-day)))))

(defun org-auto-scheduler-review-move-to-date ()
  "Prompt for a date and move the task at point to that day."
  (interactive)
  (let* ((task-id (tabulated-list-get-id))
         (current-day (org-auto-scheduler--review-get-task-day task-id)))
    (if (or (null task-id) (org-auto-scheduler--review-special-row-p task-id))
        (if (and task-id (string-prefix-p "__event_" task-id))
            (user-error "Cannot move fixed agenda event")
          (user-error "Not on a task"))
      (let* ((prompt (format "Move task to date (current: %s): " current-day))
             (date-input (org-read-date nil nil nil prompt))
             (today-str (format-time-string "%Y-%m-%d")))
        (when (string< date-input today-str)
          (user-error "Cannot schedule tasks in the past (before %s)" today-str))
        (puthash task-id
                 (plist-put (gethash task-id org-auto-scheduler--review-overrides)
                            :pinned-date date-input)
                 org-auto-scheduler--review-overrides)
        (org-auto-scheduler-review-move-to-day date-input)))))

(defun org-auto-scheduler--review-entries-day-before (entries id)
  "Return the day string of the nearest day separator at/before ID in ENTRIES.
ENTRIES is a tabulated-list-entries-shaped list of (row-id . (vector))."
  (let (day)
    (catch 'found
      (dolist (item entries)
        (let ((iid (car item)))
          (cond
           ((and (stringp iid) (string-prefix-p "__sep_" iid))
            (setq day (substring iid 6)))
           ((equal iid id)
            (throw 'found day)))))
      day)))

(defun org-auto-scheduler--review-move-before-id (task-id target-id)
  "Move TASK-ID's row to immediately before TARGET-ID's row in the review
list (both must already be present in `tabulated-list-entries'),
crossing day boundaries if necessary, then recalculate the schedule
unless `org-auto-scheduler-review-auto-recalculate-on-move' is nil.
Shared by `org-auto-scheduler-review-move-before' (keyboard, prompted)
and the org-timegrid drag handler (mouse)."
  (org-auto-scheduler--review-push-undo)
  (let ((node1 (assoc task-id tabulated-list-entries))
        (target-node (assoc target-id tabulated-list-entries)))
    (unless (and node1 target-node)
      (user-error "Task not found in review list"))
    (setq tabulated-list-entries (delq node1 tabulated-list-entries))
    (let ((new-list nil))
      (dolist (item tabulated-list-entries)
        (when (eq item target-node)
          (push node1 new-list))
        (push item new-list))
      (setq tabulated-list-entries (nreverse new-list)))
    (let ((new-day (org-auto-scheduler--review-entries-day-before
                    tabulated-list-entries task-id)))
      (when new-day
        (puthash task-id
                 (plist-put (plist-put (gethash task-id org-auto-scheduler--review-overrides)
                                       :target-date new-day)
                            :pinned-date new-day)
                 org-auto-scheduler--review-overrides)))
    (setq tabulated-list-sort-key nil)
    (setq org-auto-scheduler--review-all-entries (copy-sequence tabulated-list-entries))
    (tabulated-list-print t)
    (org-auto-scheduler--review-goto-task task-id)
    (org-auto-scheduler--review-maybe-auto-recalculate task-id)))

(defun org-auto-scheduler-review-move-before ()
  "Move the task at point to immediately before a task you pick (keyboard drag).
Prompts for a target task (by headline, with its current date/time) and
reorders the task at point to sit right before it, crossing day boundaries
if the target is on a different day.  Recalculates the schedule immediately
afterward unless `org-auto-scheduler-review-auto-recalculate-on-move' is nil."
  (interactive)
  (let ((task-id (tabulated-list-get-id)))
    (if (or (null task-id) (org-auto-scheduler--review-special-row-p task-id))
        (if (and task-id (string-prefix-p "__event_" task-id))
            (user-error "Cannot move fixed agenda event")
          (user-error "Not on a task"))
      (let ((curr-task (assoc task-id org-auto-scheduler-completed-tasks)))
        (when (and curr-task (eq (nth 9 curr-task) :placeholder))
          (user-error "Placeholder chunks cannot be moved; move the parent task instead")))
      (let* ((candidates
              (delq nil
                    (mapcar
                     (lambda (task)
                       (let ((tid (nth 0 task)))
                         (unless (or (equal tid task-id)
                                     (eq (nth 9 task) :placeholder))
                           (let* ((start (nth 1 task))
                                  (marker (nth 7 task))
                                  (proj (and marker (markerp marker) (marker-buffer marker)
                                             (org-auto-scheduler--get-project-name marker)))
                                  (headline (or (nth 5 task) "Untitled"))
                                  (time-str (if start
                                                (format-time-string "%Y-%m-%d %H:%M" start)
                                              "(unscheduled)"))
                                  (label (if (and proj (not (string= proj "—")))
                                             (format "%s  %s  [%s]" time-str headline proj)
                                           (format "%s  %s" time-str headline))))
                             (cons label tid)))))
                     org-auto-scheduler-completed-tasks)))
             (choice (and candidates
                          (completing-read "Move before task: "
                                           (sort (mapcar #'car candidates) #'string<)
                                           nil t)))
             (target-id (cdr (assoc choice candidates))))
        (unless target-id
          (user-error "No target task to move before"))
        (org-auto-scheduler--review-move-before-id task-id target-id)))))

(defun org-auto-scheduler--format-depth-prefix (depth &optional color blockers-info)
  "Return a compact badge string indicating topological DEPTH with parent project COLOR.
BLOCKERS-INFO, if non-nil, indicates explicit BLOCKER or DEPENDS_ON dependencies."
  (let* ((d (or depth 0))
         (badges ["①" "②" "③" "④" "⑤" "⑥" "⑦" "⑧" "⑨" "⑩" "⑪" "⑫" "⑬" "⑭" "⑮" "⑯" "⑰" "⑱" "⑲" "⑳"])
         (is-cycle (>= d 90))
         (badge (cond
                 (is-cycle "⟳")
                 ((< d (length badges)) (aref badges d))
                 (t (format "(%d)" (1+ d)))))
         (fg-color (if is-cycle "orange" (or color "#61afef")))
         (has-explicit (not (null blockers-info)))
         (tooltip
          (cond
           (is-cycle "Cyclic dependency detected")
           (has-explicit
            (concat "Explicit Dependency (BLOCKER / DEPENDS_ON):\n"
                    (mapconcat (lambda (b) (format "  • %s %s" (car b) (cdr b)))
                               blockers-info "\n")))
           ((= d 0) "Topological Root (depth 0)")
           (t (format "Outline sequence #%d (sibling under same parent)" (1+ d)))))
         (link-str (if has-explicit "🔗" "")))
    (if (= d 0)
        (if has-explicit
            (concat (propertize (format "%s%s " link-str badge)
                                'face `(:foreground ,fg-color :weight bold)
                                'help-echo tooltip))
          (propertize (format "%s " badge)
                      'face `(:foreground ,fg-color :weight bold)
                      'help-echo tooltip))
      (let ((indent (make-string (min 6 (* 1 (1- d))) ?\s)))
        (concat indent
                (propertize "↳" 'face 'shadow)
                (propertize (format "%s%s " link-str badge)
                            'face `(:foreground ,fg-color :weight bold)
                            'help-echo tooltip))))))

(defun org-auto-scheduler--format-task-review-entry (task today-str)
  "Format a scheduled TASK for display in the review buffer."
  (let* ((task-id (nth 0 task))
         (marker (nth 7 task))
         (headline (nth 5 task))
         (saved-dec (and task-id (org-auto-scheduler-get-saved-decision task-id marker)))
         (is-new (and saved-dec (plist-get saved-dec :is-new)))
         (start (nth 1 task))
         (end (nth 2 task))
         (status (nth 9 task))
         (depth (nth 8 task))
         (project-name (or (org-auto-scheduler--get-project-name marker) "—"))
         (proj-trunc (org-auto-scheduler--truncate project-name 18))
         (proj-color (and org-auto-scheduler--project-colors
                          (gethash proj-trunc org-auto-scheduler--project-colors)))
         (score (car (org-auto-scheduler-calculate-score marker)))
         (is-pinned (org-auto-scheduler-task-pinnable-p marker task-id))
         (is-splittable (org-auto-scheduler-task-splittable-p marker task-id))
         (blockers-info (and marker (markerp marker) (marker-buffer marker)
                             (org-auto-scheduler--get-task-blockers-info marker)))
         (auto-warnings (org-auto-scheduler--check-task-warnings task marker))
         (all-warnings (append (if (listp (nth 10 task)) (nth 10 task) nil) auto-warnings))
         (has-blocker-violation (cl-some (lambda (w) (string-prefix-p "⛔" w)) all-warnings))
         (stat-str (cond ((eq status :failed)     (propertize "✗" 'face 'error))
                         ((eq status :blocked)    (propertize "⊘" 'face 'warning))
                         ((eq status :skipped)    (propertize "⏸" 'face 'shadow))
                         ((eq status :placeholder)(propertize "⏳" 'face '(:foreground "#e5c07b" :inherit bold)))
                         (has-blocker-violation   (propertize "⛔" 'face 'error
                                                              'help-echo (mapconcat #'identity (reverse all-warnings) "\n")))
                         (all-warnings            (propertize "⚠" 'face 'warning
                                                              'help-echo (mapconcat #'identity (reverse all-warnings) "\n")))
                         (t                       (propertize "✓" 'face 'success))))
         (time-str (cond ((eq status :failed)  (propertize "FAILED" 'face 'error))
                         ((eq status :blocked) (propertize "BLOCKED" 'face 'warning))
                         ((eq status :skipped) (propertize "SKIPPED" 'face 'shadow))
                         (start (concat (org-auto-scheduler--format-time-short start) "–"
                                        (format-time-string "%H:%M" end)))
                         (t "—")))
         (dur-str (cond ((memq status '(:failed :blocked :skipped)) "—")
                        ((eq status :placeholder)
                         (let ((rem (plist-get (nthcdr 9 task) :remaining-effort)))
                           (if rem (format "%dm" rem) "—")))
                        ((or (eq status :split-today) (plist-get (nthcdr 9 task) :split-today))
                         (if (and start end)
                             (format "%dm[part]" (round (/ (float-time (time-subtract end start)) 60)))
                           (org-auto-scheduler--smart-effort-label marker)))
                        (is-splittable
                         (format "%s[s]" (org-auto-scheduler--smart-effort-label marker)))
                        (t
                         (org-auto-scheduler--smart-effort-label marker))))
         (date-str (if start (format-time-string "%Y-%m-%d" start) "Unknown"))

         (checked (if (memq status '(:failed :blocked :skipped)) "[ ]" "[X]"))
         (is-today (string= date-str today-str))
         (is-dependent (and depth (> depth 0)))
         (is-blocked (eq status :blocked))
         (priority (and marker (markerp marker) (marker-buffer marker)
                        (org-with-point-at marker (org-entry-get nil "PRIORITY"))))
         (is-high-priority (and priority (string= priority "A")))
         (is-unchecked (string= checked "[ ]"))
         (display-headline (copy-sequence (or headline "Untitled"))))

    ;; Apply face formatting to text columns
    (let ((row-face nil)
          (row-strike nil))
      (when is-blocked
        (setq row-face 'warning))
      (when (and org-auto-scheduler-review-dim-future-days (not is-blocked) (not is-today))
        (setq row-face 'shadow))
      (when is-high-priority
        (setq row-face 'bold))
      (when is-unchecked
        (setq row-strike '(:strike-through t)))

      ;; Apply styling to text columns
      (let ((cols (list checked display-headline time-str dur-str)))
        (dolist (col cols)
          (when row-face
            (add-face-text-property 0 (length col) row-face nil col))
          (when row-strike
            (add-face-text-property 0 (length col) row-strike t col))))

      ;; Prepend project-colored depth badge AFTER row-face so badge keeps vibrant project color.
      ;; A placeholder/continuation chunk is marked by blending its badge toward gold rather
      ;; than by a "[Placeholder]" text label -- the St column's ⏳ icon already says what it
      ;; is, so the badge just needs to draw the eye, not repeat it in words.
      (setq display-headline (concat (org-auto-scheduler--format-depth-prefix
                                      depth
                                      (if (eq status :placeholder)
                                          (org-auto-scheduler--status-blend-color proj-color task marker)
                                        proj-color)
                                      blockers-info)
                                     (cond
                                      ((and is-pinned is-new)
                                       (concat (propertize "📌 " 'face '(:inherit bold :foreground "#e5c07b"))
                                               (propertize "[NEW] " 'face '(:inherit bold :foreground "#98c379"))
                                               display-headline))
                                      (is-pinned
                                       (concat (propertize "📌 " 'face '(:inherit bold :foreground "#e5c07b"))
                                               display-headline))
                                      (is-new
                                       (concat (propertize "[NEW] " 'face '(:inherit bold :foreground "#98c379"))
                                               display-headline))
                                      (t display-headline))))

      ;; Apply project color to the project name (blank, not "—", when there is none)
      (let* (
             (colored-proj (cond
                            (proj-color (propertize (copy-sequence proj-trunc) 'face `(:foreground ,proj-color)))
                            ((string= proj-trunc "—") "")
                            (t (copy-sequence proj-trunc))))
             (colored-score (copy-sequence (format "%.1f" score))))
        (when (and row-face (not proj-color))
          (add-face-text-property 0 (length colored-proj) row-face nil colored-proj))
        (when row-face
          (add-face-text-property 0 (length colored-score) row-face nil colored-score))
        (when row-strike
          (add-face-text-property 0 (length colored-proj) row-strike t colored-proj)
          (add-face-text-property 0 (length colored-score) row-strike t colored-score))

        (list task-id
              (vector checked
                      (org-auto-scheduler--project-dot proj-trunc)
                      display-headline time-str dur-str
                      colored-proj colored-score stat-str))))))

(defun org-auto-scheduler--get-existing-events-for-date (date-str)
  "Return existing non-AUTOSCH agenda events for DATE-STR (YYYY-MM-DD)."
  (let* ((date-time (org-auto-scheduler-parse-time-string (concat date-str " 00:00")))
         (all-items (if date-time
                        (org-auto-scheduler-get-agenda-items date-time)
                      (and (boundp 'org-auto-scheduler--agenda-cache)
                           (hash-table-p org-auto-scheduler--agenda-cache)
                           (gethash date-str org-auto-scheduler--agenda-cache))))
         (filtered '()))
    (dolist (item all-items)
      (let* ((task-id (nth 0 item))
             (tags (nth 3 item))
             (is-autosch (or (member "AUTOSCH" tags)
                             (and (boundp 'org-auto-scheduler-completed-tasks)
                                  (assoc task-id org-auto-scheduler-completed-tasks))))
             (is-archive (member "ARCHIVE" tags)))
        (unless (or is-autosch is-archive)
          (push item filtered))))
    (nreverse filtered)))

(defun org-auto-scheduler--format-event-review-entry (event date-str index)
  "Format an existing agenda EVENT for display in the review buffer on DATE-STR."
  (let* ((task-id (nth 0 event))
         (start (nth 1 event))
         (end (nth 2 event))
         (tags (nth 3 event))
         (headline (or (nth 5 event) "Untitled Event"))
         (has-time (nth 6 event))
         (marker (or (nth 7 event)
                     (when (and task-id (stringp task-id) (not (string= task-id "")))
                       (org-id-find task-id t))))
         (is-non-blocking (org-auto-scheduler-task-non-blocking-p task-id marker))
         (row-id (format "__event_%s_%d" date-str index))
         (clean-hl (substring-no-properties (string-trim headline)))
         (hl-prop (propertize clean-hl
                              'face (if is-non-blocking 'italic 'shadow)
                              'event-marker marker
                              'event-id task-id
                              'non-blocking is-non-blocking))
         (time-str (cond
                    ((and start end has-time)
                     (concat (org-auto-scheduler--format-time-short start) "–"
                             (format-time-string "%H:%M" end)))
                    ((and start has-time)
                     (org-auto-scheduler--format-time-short start))
                    (t "All-day")))
         (dur-str (if (and start end has-time)
                      (let ((mins (round (/ (float-time (time-subtract end start)) 60))))
                        (if (> mins 0) (format "%dm" mins) "—"))
                    "—"))
         (tag-str (if tags
                      (concat "[" (mapconcat #'identity tags ":") "]")
                    "[Calendar]")))
    (list row-id
          (vector (propertize "" 'event-marker marker 'event-id task-id)
                  (propertize "📅"
                              'face (if is-non-blocking 'default 'shadow)
                              'event-marker marker
                              'event-id task-id)
                  hl-prop
                  (propertize time-str 'face 'shadow 'event-marker marker 'event-id task-id)
                  (propertize dur-str 'face 'shadow 'event-marker marker 'event-id task-id)
                  (propertize (if is-non-blocking (concat tag-str " [NB]") tag-str)
                              'face (if is-non-blocking 'font-lock-doc-face 'shadow)
                              'event-marker marker
                              'event-id task-id)
                  (propertize "—" 'face 'shadow 'event-marker marker 'event-id task-id)
                  (propertize (if is-non-blocking "" "🔒")
                              'face (if is-non-blocking 'font-lock-doc-face 'shadow)
                              'event-marker marker
                              'event-id task-id)))))

(defun org-auto-scheduler-review-toggle-agenda-events ()
  "Toggle visibility of existing fixed agenda events in the review buffer."
  (interactive)
  (org-auto-scheduler--review-push-undo)
  (setq org-auto-scheduler-review-show-agenda-events
        (not org-auto-scheduler-review-show-agenda-events))
  ;; Preserve checkbox states for tasks
  (let ((check-map (make-hash-table :test 'equal)))
    (dolist (e tabulated-list-entries)
      (let ((id (car e)) (vec (cadr e)))
        (when (and id (not (org-auto-scheduler--review-special-row-p id)))
          (puthash id (aref vec 0) check-map))))
    (let ((new-entries (org-auto-scheduler--build-review-entries
                        org-auto-scheduler-completed-tasks)))
      (dolist (entry new-entries)
        (let ((saved (gethash (car entry) check-map)))
          (when saved (aset (cadr entry) 0 saved))))
      (setq tabulated-list-entries new-entries)
      (setq org-auto-scheduler--review-all-entries (copy-sequence tabulated-list-entries))
      (tabulated-list-print t)
      (setq header-line-format
            (org-auto-scheduler--review-header-line tabulated-list-entries))
      (message "Agenda events %s" (if org-auto-scheduler-review-show-agenda-events "shown" "hidden")))))

(defun org-auto-scheduler--build-review-entries (tasks)
  "Build tabulated-list-entries from TASKS with day separators, new columns,
and optionally existing fixed agenda events interleaved chronologically."
  (setq org-auto-scheduler--project-name-cache nil)
  (org-auto-scheduler--assign-project-colors tasks)
  (let* ((sorted-tasks (sort (copy-sequence tasks)
                             (lambda (a b)
                               (let ((sa (nth 1 a))
                                     (sb (nth 1 b)))
                                 (cond ((and sa sb) (time-less-p sa sb))
                                       (sa t)
                                       (t nil))))))
         (task-dates (delete-dups (delq nil (mapcar (lambda (task)
                                                      (when (nth 1 task)
                                                        (format-time-string "%Y-%m-%d" (nth 1 task))))
                                                    sorted-tasks))))
         (today-str (format-time-string "%Y-%m-%d"))
         (all-dates (if (and org-auto-scheduler-review-show-agenda-events
                             (not (member today-str task-dates))
                             (org-auto-scheduler--get-existing-events-for-date today-str))
                        (sort (cons today-str task-dates) #'string<)
                      task-dates))
         (raw-entries nil)
         (event-idx 0))

    ;; Emit day separators, tasks, and events per day
    (dolist (date-str all-dates)
      (let* ((first-task (cl-find-if (lambda (tk)
                                       (and (nth 1 tk)
                                            (string= (format-time-string "%Y-%m-%d" (nth 1 tk)) date-str)))
                                     sorted-tasks))
             (date-time (if first-task (nth 1 first-task)
                          (org-auto-scheduler-parse-time-string (concat date-str " 00:00"))))
             (is-today-sep (string= date-str today-str))
             (day-label (cond
                         ((and date-time is-today-sep)
                          (format-time-string "-- %A, %b %d  [TODAY] " date-time))
                         (date-time
                          (format-time-string "-- %A, %b %d " date-time))
                         (is-today-sep
                          (format "-- %s  [TODAY] " date-str))
                         (t
                          (format "-- %s " date-str))))
             (sep-line (concat day-label (make-string (max 0 (- 50 (length day-label))) ?-)))
             (sep-face (if is-today-sep '(:inherit bold :foreground "#61afef") 'bold)))
        (push (list (concat "__sep_" date-str)
                    (vector "" "" (propertize sep-line 'face sep-face) "" "" "" "" ""))
              raw-entries))

      (let ((day-tasks (cl-remove-if-not (lambda (tk)
                                           (and (nth 1 tk)
                                                (string= (format-time-string "%Y-%m-%d" (nth 1 tk)) date-str)))
                                         sorted-tasks))
            (day-events (when org-auto-scheduler-review-show-agenda-events
                          (org-auto-scheduler--get-existing-events-for-date date-str))))

        ;; Interleave day-tasks and day-events chronologically by start time
        (let* ((combined-items
                (append (mapcar (lambda (tk) (list :task tk (nth 1 tk))) day-tasks)
                        (mapcar (lambda (ev) (list :event ev (nth 1 ev))) day-events)))
               (sorted-items
                (sort combined-items
                      (lambda (a b)
                        (let ((ta (nth 2 a))
                              (tb (nth 2 b)))
                          (cond
                           ((and ta tb) (time-less-p ta tb))
                           (ta t)
                           (t nil)))))))
          (dolist (item sorted-items)
            (if (eq (nth 0 item) :task)
                (push (org-auto-scheduler--format-task-review-entry (nth 1 item) today-str) raw-entries)
              (setq event-idx (1+ event-idx))
              (push (org-auto-scheduler--format-event-review-entry (nth 1 item) date-str event-idx) raw-entries))))))

    ;; Unscheduled tasks (e.g. failed/blocked/skipped without a start time)
    (let ((unscheduled-tasks (cl-remove-if (lambda (tk) (nth 1 tk)) sorted-tasks)))
      (when unscheduled-tasks
        (push (list "__sep_Unknown"
                    (vector "" "" (propertize "-- Unscheduled Tasks ------------------------" 'face 'bold)
                            "" "" "" "" ""))
              raw-entries)
        (dolist (task unscheduled-tasks)
          (push (org-auto-scheduler--format-task-review-entry task today-str) raw-entries))))

    ;; Shortcuts banner at top
    (cons (list "__header_shortcuts"
                (vector "" "" (propertize "  [RET] toggle  [s] split  [p] pin  [b] non-blocking  [K/J] reorder  [>/<] day  [d] date  [r] recalc  [S] save  [M] merge  [C] clear  [x] apply  [?] help" 'face 'shadow)
                        "" "" "" "" ""))
          (nreverse raw-entries))))

(defun org-auto-scheduler-review-recalculate (&optional arg)
  "Recalculate scheduled times based on visual order without resorting.
When `org-auto-scheduler-review-compact-schedule' is non-nil (default), tasks
pack continuously and automatically backfill into available earlier day slots.
With prefix ARG (C-u r), or when `org-auto-scheduler-review-compact-schedule' is nil,
tasks are constrained to start on or after their current day section."
  (interactive "P")
  (let* ((compact (if arg
                      (not org-auto-scheduler-review-compact-schedule)
                    org-auto-scheduler-review-compact-schedule))
         (org-auto-scheduler--ignore-target-dates-p compact))
    (message "Recalculating proposed schedule based on visual order (%s)..."
             (if compact "auto-compact" "rigid day sections"))
    (let ((ordered-tasks '())
          (current-sep-date nil))
      (save-excursion
        (goto-char (point-min))
        (while (not (eobp))
          (let* ((row-id (tabulated-list-get-id))
                 (entry (tabulated-list-get-entry)))
            (cond
             ((and (stringp row-id) (string-prefix-p "__sep_" row-id))
              (setq current-sep-date (substring row-id 6)))
             ((and row-id (not (org-auto-scheduler--review-special-row-p row-id)))
              (let ((checked-state (if entry (aref entry 0) "[X]"))
                    (data (assoc row-id org-auto-scheduler-completed-tasks)))
                (when data
                  (push (list checked-state data current-sep-date) ordered-tasks))))))
          (forward-line 1)))
      (setq ordered-tasks (nreverse ordered-tasks))
      (let ((org-auto-scheduler--preview-mode t)
            (org-auto-scheduler--ignore-blockers-p t)
            (org-auto-scheduler--ignore-saved-skips-p t)
            (org-auto-scheduler--reordering-p t)
            (today-str (format-time-string "%Y-%m-%d"))
            (current-time (org-auto-scheduler-get-start-time))
            (current-day nil))
        (org-auto-scheduler--build-agenda-cache)
        (setq org-auto-scheduler-completed-tasks '())
        (dolist (item ordered-tasks)
          (let* ((checked-state (nth 0 item))
                 (task (nth 1 item))
                 (task-day (nth 2 item))
                 (task-id (nth 0 task))
                 (raw-marker (nth 7 task))
                 (marker (org-auto-scheduler--resolve-task-marker raw-marker task-id))
                 (depth (nth 8 task))
                 (status (nth 9 task)))
            ;; Skip placeholder rows during recalculation: the parent task will recreate them!
            (unless (eq status :placeholder)
              ;; When transitioning to a new day based on review buffer visual sections:
              (unless compact
                (when (and task-day (not (equal task-day current-day)))
                  (setq current-day task-day)
                  (let ((day-start (if (string= task-day today-str)
                                       (org-auto-scheduler-get-start-time)
                                     (org-auto-scheduler-time-with-time-string
                                      (org-auto-scheduler-parse-time-string (concat task-day " 00:00"))
                                      org-auto-scheduler-start-time))))
                    (when (time-less-p current-time day-start)
                      (setq current-time day-start)))))
              (if (string= checked-state "[ ]")
                  (push (list (nth 0 task) current-time current-time '("AUTOSCH") nil (nth 5 task)
                              "SKIPPED" marker (or depth 0) :skipped '("Unchecked by user"))
                        org-auto-scheduler-completed-tasks)
                (setq current-time
                      (org-auto-scheduler-schedule-single-task marker current-time depth))))))
        ;; Normalize completed tasks to chronological order
        (setq org-auto-scheduler-completed-tasks (nreverse org-auto-scheduler-completed-tasks))
        (let ((check-map (make-hash-table :test 'equal)))
          (dolist (item ordered-tasks)
            (puthash (nth 0 (nth 1 item)) (nth 0 item) check-map))
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
        (message "Recalculation complete (%s)!" (if compact "compact" "rigid day sections"))))))


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
  ;; Check for explicit blocker violations among checked tasks
  (let ((violations '()))
    (save-excursion
      (goto-char (point-min))
      (while (not (eobp))
        (let* ((task-id (tabulated-list-get-id))
               (entry (tabulated-list-get-entry))
               (checked (and entry (string= (aref entry 0) "[X]"))))
          (when (and checked task-id (not (org-auto-scheduler--review-special-row-p task-id)))
            (let* ((data (assoc task-id org-auto-scheduler-completed-tasks))
                   (marker (and data (nth 7 data)))
                   (warns (and data marker (org-auto-scheduler--check-task-warnings data marker))))
              (dolist (w warns)
                (when (string-prefix-p "⛔" w)
                  (push (format "%s: %s" (nth 5 data) w) violations))))))
        (forward-line 1)))
    (when violations
      (unless (yes-or-no-p
               (format "Warning: %d dependency violation(s) detected (e.g. '%s'). Apply anyway? "
                       (length violations) (car (reverse violations))))
        (user-error "Application aborted: please fix dependency ordering before applying"))))
  (org-auto-scheduler-create-report-buffer)
  (org-auto-scheduler-cleanup-placeholders)
  (let ((applied-count 0))
    (save-excursion
      (goto-char (point-min))
      (while (not (eobp))
        (let* ((task-id (tabulated-list-get-id))
               (entry (tabulated-list-get-entry))
               (checked (and entry (string= (aref entry 0) "[X]"))))
          (when (and checked task-id (not (org-auto-scheduler--review-special-row-p task-id)))
            (let* ((data (assoc task-id org-auto-scheduler-completed-tasks)))
              (when data
                (let* ((status (nth 9 data))
                       (is-placeholder (eq status :placeholder)))
                  (if is-placeholder
                      (let* ((rem-effort (plist-get (nthcdr 9 data) :remaining-effort))
                             (origin-id (plist-get (nthcdr 9 data) :origin-id))
                             (headline (nth 5 data))
                             (start (nth 1 data))
                             (end (nth 2 data))
                             (raw-marker (nth 7 data))
                             (marker (org-auto-scheduler--resolve-task-marker raw-marker origin-id)))
                        (when (and marker (markerp marker) (marker-buffer marker))
                          (org-auto-scheduler--create-placeholder-subtask
                           marker headline start end rem-effort origin-id)
                          (setq applied-count (1+ applied-count))))
                    (let* ((schedule-string (nth 6 data))
                           (raw-marker (nth 7 data))
                           (marker (org-auto-scheduler--resolve-task-marker raw-marker task-id))
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
                        (org-auto-scheduler--set-scheduled schedule-string)
                        (org-set-property org-auto-scheduler-scheduled-property "t"))
                      (org-auto-scheduler-add-to-report task-info start)
                      (setq applied-count (1+ applied-count)))))))))
        (forward-line 1)))
    ;; Save all modified agenda buffers to disk
    (save-some-buffers t (lambda ()
                           (and (buffer-file-name)
                                (member (buffer-file-name) (org-agenda-files t)))))
    (when org-auto-scheduler-review-auto-save-decisions
      (org-auto-scheduler-review-save-decisions t))
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
  (org-auto-scheduler-load-review-decisions)
  (message "Calculating proposed schedule...")
  (let ((org-auto-scheduler--preview-mode t))
    (org-auto-scheduler-schedule-tasks))
  (let ((buf (get-buffer-create "*Org Auto Scheduler Review*")))
    (with-current-buffer buf
      (org-auto-scheduler-review-mode)
      (setq org-auto-scheduler--review-view 'table)
      (setq org-auto-scheduler--review-undo-stack nil)
      (dolist (item org-auto-scheduler--saved-review-decisions)
        (let ((tid (car item))
              (plist (cdr item)))
          (when (or (plist-get plist :target-date)
                    (plist-get plist :pinned-date)
                    (plist-get plist :pinnable)
                    (plist-get plist :pinned-time))
            (puthash tid (list :target-date (or (plist-get plist :target-date)
                                               (plist-get plist :pinned-date))
                               :pinned-date (plist-get plist :pinned-date)
                               :pinnable (plist-get plist :pinnable)
                               :pinned-time (plist-get plist :pinned-time))
                     org-auto-scheduler--review-overrides))))
      (setq tabulated-list-entries (org-auto-scheduler--build-review-entries
                                    org-auto-scheduler-completed-tasks))
      (setq org-auto-scheduler--review-all-entries (copy-sequence tabulated-list-entries))
      (tabulated-list-print t)
      (setq header-line-format
            (org-auto-scheduler--review-header-line tabulated-list-entries)))
    (switch-to-buffer buf)))

(defun org-auto-scheduler--review-reposition-task-chronologically (task-id pinned-time)
  "Reposition TASK-ID in `tabulated-list-entries' so it appears chronologically at PINNED-TIME."
  (let* ((node (assoc task-id tabulated-list-entries))
         (target-date (format-time-string "%Y-%m-%d" pinned-time))
         (target-sep-id (concat "__sep_" target-date))
         (existing-sep (assoc target-sep-id tabulated-list-entries)))
    (when node
      ;; Remove from current position
      (setq tabulated-list-entries (delq node tabulated-list-entries))
      ;; Ensure day separator exists
      (unless existing-sep
        (let ((new-sep (list target-sep-id
                             (vector "" "" (propertize (org-auto-scheduler--format-day-sep target-date) 'face 'bold)
                                     "" "" "" "" "")))
              (inserted nil)
              (new-list nil))
          (dolist (item tabulated-list-entries)
            (let ((item-id (car item)))
              (if (and (not inserted)
                       (stringp item-id)
                       (string-prefix-p "__sep_" item-id)
                       (string< target-date (substring item-id 6)))
                  (progn
                    (push new-sep new-list)
                    (push item new-list)
                    (setq inserted t))
                (push item new-list))))
          (unless inserted
            (push new-sep new-list))
          (setq tabulated-list-entries (nreverse new-list))))
      ;; Insert node in chronological place within target-date
      (let ((new-list nil)
            (placed nil)
            (in-target-day nil))
        (dolist (item tabulated-list-entries)
          (let ((item-id (car item)))
            (cond
             ((equal item-id target-sep-id)
              (push item new-list)
              (setq in-target-day t))
             ((and in-target-day (stringp item-id) (string-prefix-p "__sep_" item-id))
              ;; Reached next day separator before placing
              (unless placed
                (push node new-list)
                (setq placed t))
              (push item new-list)
              (setq in-target-day nil))
             ((and in-target-day (not placed))
              (let* ((item-data (assoc item-id org-auto-scheduler-completed-tasks))
                     (item-start (and item-data (nth 1 item-data))))
                (if (and item-start (not (time-less-p item-start pinned-time)))
                    (progn
                      (push node new-list)
                      (push item new-list)
                      (setq placed t))
                  (push item new-list))))
             (t
              (push item new-list)))))
        (unless placed
          (push node new-list))
        (setq tabulated-list-entries (nreverse new-list))
        (setq org-auto-scheduler--review-all-entries (copy-sequence tabulated-list-entries))))))

(defun org-auto-scheduler-review-toggle-splittable ()
  "Toggle SPLITTABLE status of the task at point in the review buffer.
Works in both Table view and Calendar view."
  (interactive)
  (unless (eq major-mode 'org-auto-scheduler-review-mode)
    (user-error "Not in an Org Auto Scheduler Review buffer"))
  (let* ((is-calendar (eq org-auto-scheduler--review-view 'calendar))
         (task-id (if is-calendar
                      (get-text-property (point) 'task-id)
                    (tabulated-list-get-id)))
         (entry (unless is-calendar (tabulated-list-get-entry))))
    (cond
     ((and (not is-calendar)
           (or (null task-id) (org-auto-scheduler--review-special-row-p task-id)))
      (if (and task-id (string-prefix-p "__event_" task-id))
          (user-error "Fixed agenda events cannot be marked splittable")
        (user-error "Not on a task")))
     ((and is-calendar (null task-id))
      (if (or (get-text-property (point) 'event-id) (get-text-property (point) 'event-marker))
          (user-error "Fixed agenda events cannot be marked splittable")
        (user-error "No task at point in calendar view")))
     (t
      (let* ((task-data (assoc task-id org-auto-scheduler-completed-tasks))
             (raw-marker (and task-data (nth 7 task-data)))
             (marker (org-auto-scheduler--resolve-task-marker raw-marker task-id))
             (headline (if task-data (nth 5 task-data) "Task"))
             (status (and task-data (nth 9 task-data))))
        (when (eq status :placeholder)
          (user-error "Cannot split a placeholder chunk; mark the parent task splittable"))
        (org-auto-scheduler--review-push-undo)
        (let ((now-splittable (org-auto-scheduler-task-toggle-splittable marker task-id)))
          (if is-calendar
              (progn
                (message "Task '%s' marked %s."
                         headline (if now-splittable "SPLITTABLE" "NOT splittable"))
                (org-auto-scheduler-review-recalculate)
                (org-auto-scheduler--render-calendar-view))
            (message "Task '%s' marked %s.%s"
                     headline
                     (if now-splittable "SPLITTABLE" "NOT splittable")
                     (if org-auto-scheduler-review-auto-recalculate-on-move ""
                       " Press 'r' to recalculate schedule."))
            (if org-auto-scheduler-review-auto-recalculate-on-move
                (org-auto-scheduler-review-recalculate)
              (tabulated-list-print t)))))))))

(defun org-auto-scheduler-review-toggle-pinnable (&optional unpin-arg)
  "Mark or toggle PINNABLE status of the task at point in the review buffer.
Prompts for pinned start time.  If given an empty string, or with prefix UNPIN-ARG,
unpins the task.  Recalculates the schedule so the task starts at the given time
and other tasks are rescheduled to after.  Works in Table and Calendar views."
  (interactive "P")
  (unless (eq major-mode 'org-auto-scheduler-review-mode)
    (user-error "Not in an Org Auto Scheduler Review buffer"))
  (let* ((is-calendar (eq org-auto-scheduler--review-view 'calendar))
         (task-id (if is-calendar
                      (get-text-property (point) 'task-id)
                    (tabulated-list-get-id))))
    (cond
     ((and (not is-calendar)
           (or (null task-id) (org-auto-scheduler--review-special-row-p task-id)))
      (if (and task-id (string-prefix-p "__event_" task-id))
          (user-error "Fixed agenda events are already pinned calendar events")
        (user-error "Not on a task")))
     ((and is-calendar (null task-id))
      (if (or (get-text-property (point) 'event-id) (get-text-property (point) 'event-marker))
          (user-error "Fixed agenda events are already pinned calendar events")
        (user-error "No task at point in calendar view")))
     (t
      (let* ((task-data (assoc task-id org-auto-scheduler-completed-tasks))
             (raw-marker (and task-data (nth 7 task-data)))
             (marker (org-auto-scheduler--resolve-task-marker raw-marker task-id))
             (headline (if task-data (nth 5 task-data) "Task"))
             (status (and task-data (nth 9 task-data)))
             (is-already-pinned (org-auto-scheduler-task-pinnable-p marker task-id))
             (current-start (and task-data (nth 1 task-data)))
             (default-str (cond
                           (is-already-pinned
                            (let ((pt (org-auto-scheduler-task-pinned-time marker task-id)))
                              (if pt (format-time-string "%Y-%m-%d %H:%M" pt) "")))
                           (current-start
                            (format-time-string "%Y-%m-%d %H:%M" current-start))
                           (t (format-time-string "%Y-%m-%d 09:00")))))
        (when (eq status :placeholder)
          (user-error "Cannot pin a placeholder chunk; pin the parent task"))
        (if (or unpin-arg
                (and is-already-pinned
                     (string= (read-string (format "Task '%s' is pinned (%s). Unpin? [y/N]: "
                                                   headline default-str)
                                           nil nil "n")
                              "y")))
            ;; Unpin path
            (progn
              (org-auto-scheduler--review-push-undo)
              (org-auto-scheduler-task-set-pinnable marker task-id nil t)
              (message "Unpinned '%s'. Recalculating..." headline)
              (org-auto-scheduler-review-recalculate)
              (when is-calendar (org-auto-scheduler--render-calendar-view)))
          ;; Prompt for pin time
          (let* ((prompt (format "Pin '%s' to time (e.g. '14:00' or 'YYYY-MM-DD HH:MM', empty to cancel): "
                                 headline))
                 (time-input (read-string prompt default-str)))
            (if (or (null time-input) (string-empty-p (string-trim time-input)))
                (message "Pin cancelled")
              (org-auto-scheduler--review-push-undo)
              (let* ((res-time (org-auto-scheduler-task-set-pinnable marker task-id time-input nil))
                     (parsed (org-auto-scheduler-task-pinned-time marker task-id)))
                (when parsed
                  (org-auto-scheduler--review-reposition-task-chronologically task-id parsed))
                (message "Pinned '%s' to %s. Rescheduling subsequent tasks..." headline res-time)
                (org-auto-scheduler-review-recalculate)
                (when is-calendar (org-auto-scheduler--render-calendar-view))
                (unless is-calendar
                  (org-auto-scheduler--review-goto-task task-id)))))))))))

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
          (when (or (org-auto-scheduler--review-special-row-p id)
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
      (unless (org-auto-scheduler--review-special-row-p id)
        (aset vec 0 "[X]")
        (aset vec 2 (substring-no-properties (aref vec 2))))))
  (tabulated-list-print t))

(defun org-auto-scheduler-review-unmark-all ()
  "Unmark all visible tasks."
  (interactive)
  (org-auto-scheduler--review-push-undo)
  (dolist (e tabulated-list-entries)
    (let ((id (car e)) (vec (cadr e)))
      (unless (org-auto-scheduler--review-special-row-p id)
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
        (when (and (not (org-auto-scheduler--review-special-row-p id))
                   (string-match-p regexp (substring-no-properties (aref vec 2))))
          (aset vec 0 "[X]")
          (aset vec 2 (substring-no-properties (aref vec 2))))))
    (tabulated-list-print t)))

(defun org-auto-scheduler-review-edit-effort (new-effort)
  "Edit the estimated effort (in minutes) for the task at point (temporary override)."
  (interactive "nNew effort in minutes: ")
  (let* ((id (tabulated-list-get-id))
         (entry (tabulated-list-get-entry)))
    (if (or (null id) (org-auto-scheduler--review-special-row-p id))
        (if (and id (string-prefix-p "__event_" id))
            (user-error "Cannot edit effort for fixed agenda event")
          (user-error "Not on a task"))
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
                  " │ [v/c] Table View │ [b] Toggle Non-Blocking │ [TAB/RET] Jump to task │ Scroll to navigate"))
    (insert (propertize " Proposed Schedule Calendar View \n" 'face 'org-document-title))
    (insert (propertize "========================================================\n\n" 'face 'shadow))
    (let ((days-hash (make-hash-table :test 'equal))
          (dates nil))
      (dolist (task tasks)
        (let* ((start (nth 1 task))
               (date-str (format-time-string "%Y-%m-%d" start)))
          (cl-pushnew date-str dates :test #'string=)
          (puthash date-str (cons task (gethash date-str days-hash)) days-hash)))
      (when org-auto-scheduler-review-show-agenda-events
        (let ((today-str (format-time-string "%Y-%m-%d")))
          (when (org-auto-scheduler--get-existing-events-for-date today-str)
            (cl-pushnew today-str dates :test #'string=))))
      (if (null dates)
          (insert "  No scheduled tasks or events to display.\n")
        (setq dates (sort dates #'string<))
        (dolist (date-str dates)
          (let* ((day-tasks (nreverse (gethash date-str days-hash)))
                 (day-events (when org-auto-scheduler-review-show-agenda-events
                               (org-auto-scheduler--get-existing-events-for-date date-str)))
                 (all-time-ranges (append
                                   (mapcar (lambda (tk) (cons (nth 1 tk) (nth 2 tk))) day-tasks)
                                   (delq nil (mapcar (lambda (ev)
                                                       (when (nth 6 ev)
                                                         (cons (nth 1 ev) (nth 2 ev))))
                                                     day-events))))
                 (parsed-date (if all-time-ranges
                                  (car (car all-time-ranges))
                                (org-auto-scheduler-parse-time-string (concat date-str " 09:00"))))
                 (min-start (if all-time-ranges
                                (cl-reduce (lambda (a b) (if (time-less-p a b) a b))
                                           (mapcar #'car all-time-ranges))
                              (org-auto-scheduler-parse-time-string (concat date-str " 09:00"))))
                 (max-end (if all-time-ranges
                              (cl-reduce (lambda (a b) (if (time-less-p a b) b a))
                                         (mapcar #'cdr all-time-ranges))
                            (org-auto-scheduler-parse-time-string (concat date-str " 17:00"))))
                 (start-hour (max 0 (- (string-to-number (format-time-string "%H" min-start)) 1)))
                 (end-hour (min 23 (+ (string-to-number (format-time-string "%H" max-end)) 1))))
            (insert (propertize (format " 📅 %s \n" (format-time-string "%A, %B %d, %Y" parsed-date))
                                'face 'bold-italic))
            (insert (propertize " ──────────────────────────────────────────────────────\n" 'face 'shadow))
            (let ((hour start-hour)
                  (minute 0)
                  (last-printed-task-id nil)
                  (last-printed-ev-id nil))
              (while (<= hour end-hour)
                (let* ((slot-time (org-auto-scheduler-parse-time-string (format "%s %02d:%02d" date-str hour minute)))
                       (active-task (cl-find-if (lambda (t2)
                                                  (let ((ts (nth 1 t2))
                                                        (te (nth 2 t2)))
                                                    (and (not (time-less-p slot-time ts))
                                                         (time-less-p slot-time te))))
                                                day-tasks))
                       (active-event (cl-find-if (lambda (ev)
                                                   (let ((es (nth 1 ev))
                                                         (ee (nth 2 ev))
                                                         (ht (nth 6 ev)))
                                                     (and ht
                                                          (not (time-less-p slot-time es))
                                                          (time-less-p slot-time ee))))
                                                 day-events)))
                  (insert (format "  %02d:%02d │ " hour minute))
                  (cond
                   ((and active-task active-event)
                    ;; Both task and non-blocking event in same slot
                    (let* ((task-id (car active-task))
                           (headline (nth 5 active-task))
                           (marker (nth 7 active-task))
                           (project-name (or (org-auto-scheduler--get-project-name marker) "—"))
                           (proj-trunc (org-auto-scheduler--truncate project-name 18))
                           (color (and org-auto-scheduler--project-colors
                                       (gethash proj-trunc org-auto-scheduler--project-colors)))
                           (ev-id (nth 0 active-event))
                           (ev-marker (or (nth 7 active-event)
                                          (when (and ev-id (stringp ev-id)) (org-id-find ev-id t))))
                           (ev-hl (or (nth 5 active-event) "Event")))
                      (insert (propertize "█" 'face (if color `(:foreground ,color) 'default)
                                          'task-id task-id 'mouse-face 'highlight 'help-echo "RET/TAB to jump to task")
                              (propertize " " 'task-id task-id))
                      (if (equal task-id last-printed-task-id)
                          (insert (propertize "║" 'face (if color `(:foreground ,color) 'shadow) 'task-id task-id))
                        (setq last-printed-task-id task-id)
                        (insert (propertize (format "[%s] %s" proj-trunc headline)
                                            'face (if color `(:foreground ,color) 'default)
                                            'task-id task-id 'mouse-face 'highlight 'help-echo "RET/TAB to jump")))
                      (insert (propertize (format "  │ %s" ev-hl)
                                          'face 'font-lock-doc-face
                                          'event-id ev-id
                                          'event-marker ev-marker
                                          'non-blocking t
                                          'mouse-face 'highlight
                                          'help-echo "b: toggle non-blocking | RET/TAB: jump"))))
                   (active-task
                    (setq last-printed-ev-id nil)
                    (let* ((task-id (car active-task))
                           (headline (nth 5 active-task))
                           (marker (nth 7 active-task))
                           (project-name (or (org-auto-scheduler--get-project-name marker) "—"))
                           (proj-trunc (org-auto-scheduler--truncate project-name 18))
                           (color (and org-auto-scheduler--project-colors
                                       (gethash proj-trunc org-auto-scheduler--project-colors)))
                           (bar-char (propertize "█" 'face (if color `(:foreground ,color) 'default)
                                                 'task-id task-id
                                                 'mouse-face 'highlight
                                                 'help-echo "RET/TAB to jump to task")))
                      (insert bar-char (propertize " " 'task-id task-id))
                      (if (equal task-id last-printed-task-id)
                          (insert (propertize "║" 'face (if color `(:foreground ,color) 'shadow)
                                              'task-id task-id
                                              'mouse-face 'highlight
                                              'help-echo "RET/TAB to jump to task"))
                        (setq last-printed-task-id task-id)
                        (let ((start-lbl (format-time-string "%H:%M" (nth 1 active-task)))
                              (end-lbl (format-time-string "%H:%M" (nth 2 active-task))))
                          (insert (propertize (format "[%s] %s (%s–%s)" proj-trunc headline start-lbl end-lbl)
                                              'face (if color `(:foreground ,color) 'default)
                                              'task-id task-id
                                              'mouse-face 'highlight
                                              'help-echo "RET/TAB to jump to task"))))))
                   (active-event
                    (setq last-printed-task-id nil)
                    (let* ((ev-id (nth 0 active-event))
                           (ev-marker (or (nth 7 active-event)
                                          (when (and ev-id (stringp ev-id)) (org-id-find ev-id t))))
                           (is-nb (org-auto-scheduler-task-non-blocking-p ev-id ev-marker))
                           (ev-hl (or (nth 5 active-event) "Event"))
                           (ev-face (if is-nb 'font-lock-doc-face 'shadow))
                           (bar-char (propertize (if is-nb "░" "▓") 'face ev-face
                                                 'event-id ev-id
                                                 'event-marker ev-marker
                                                 'non-blocking is-nb
                                                 'mouse-face 'highlight
                                                 'help-echo "b: toggle non-blocking | RET/TAB: jump")))
                      (insert bar-char (propertize " " 'event-id ev-id 'event-marker ev-marker))
                      (if (equal ev-id last-printed-ev-id)
                          (insert (propertize "║" 'face ev-face
                                              'event-id ev-id 'event-marker ev-marker
                                              'mouse-face 'highlight
                                              'help-echo "b: toggle non-blocking | RET/TAB: jump"))
                        (setq last-printed-ev-id ev-id)
                        (let ((start-lbl (format-time-string "%H:%M" (nth 1 active-event)))
                              (end-lbl (format-time-string "%H:%M" (nth 2 active-event))))
                          (insert (propertize (if is-nb
                                                  (format "[Non-Blocking] %s (%s–%s)"
                                                          ev-hl start-lbl end-lbl)
                                                (format "🔒 [Event] %s (%s–%s)"
                                                        ev-hl start-lbl end-lbl))
                                              'face ev-face
                                              'event-id ev-id
                                              'event-marker ev-marker
                                              'non-blocking is-nb
                                              'mouse-face 'highlight
                                              'help-echo "b: toggle non-blocking | RET/TAB: jump"))))))
                   (t
                    (setq last-printed-task-id nil
                          last-printed-ev-id nil)
                    (insert (propertize "·" 'face 'shadow))))
                  (insert "\n")
                  (setq minute (+ minute 15))
                  (when (>= minute 60)
                    (setq minute 0)
                    (setq hour (1+ hour))))))
            (insert "\n")))))
    (goto-char (point-min))))

;;; org-timegrid integration (optional)

(defvar-local org-auto-scheduler--timegrid-source-buffer nil
  "The Org Auto Scheduler Review buffer that `*Org Time Grid*' is previewing.
Buffer-local to the `*Org Time Grid*' buffer itself, set by
`org-auto-scheduler-review-open-timegrid'.")

(defvar-local org-auto-scheduler--timegrid-last-synced-week nil
  "The \"YYYY-MM-DD\" week-start last handled by
`org-auto-scheduler--timegrid-sync-week-range', buffer-local to the
`*Org Time Grid*' buffer.  Lets that function tell an actual week
navigation apart from an incidental refresh (a table-view toggle/move
also refreshes the grid to keep it current) so it only moves the
review table's cursor when the visible week genuinely changed.")

(defun org-auto-scheduler--timegrid-minutes (time)
  "Convert Emacs TIME value to org-timegrid absolute minutes."
  (let ((decoded (decode-time time)))
    (+ (* (calendar-absolute-from-gregorian
           (list (nth 4 decoded) (nth 3 decoded) (nth 5 decoded)))
          1440)
       (* 60 (nth 2 decoded))
       (nth 1 decoded))))

(defun org-auto-scheduler--timegrid-date-string (absolute-day)
  "Return the YYYY-MM-DD string for ABSOLUTE-DAY (a calendar absolute date)."
  (let ((g (calendar-gregorian-from-absolute absolute-day)))
    (format "%04d-%02d-%02d" (nth 2 g) (nth 0 g) (nth 1 g))))

(defun org-auto-scheduler--review-status-icon-info (task marker)
  "Return (ICON . TOOLTIP) for TASK/MARKER, mirroring the table view's
\"St\" column (see `org-auto-scheduler--format-task-review-entry').
Tried full-color emoji here (✅/❌/🚫/⚠️) to make just the icon read as
colored, but org-timegrid draws a block's title as one flat SVG
`<text>' run with a single fill color for the whole string -- verified
live, even with a color-emoji font installed, that it renders those as
plain monochrome glyphs like everything else, so there is no way to
tint just the icon here; a status color has to come from the block
itself (`org-auto-scheduler--timegrid-event-from-task's `:color'), not
its title text.  Callers are expected to have already excluded
:failed/:blocked/:skipped tasks, which never reach the grid; this
still handles them defensively."
  (let ((status (nth 9 task)))
    (cond
     ((eq status :failed)  (cons "✗" nil))
     ((eq status :blocked) (cons "⊘" nil))
     ((eq status :skipped) (cons "⏸" nil))
     ((eq status :placeholder) (cons "⏳" nil))
     (t
      (let* ((auto-warnings (org-auto-scheduler--check-task-warnings task marker))
             (all-warnings (append (if (listp (nth 10 task)) (nth 10 task) nil) auto-warnings))
             (has-blocker-violation (cl-some (lambda (w) (string-prefix-p "⛔" w)) all-warnings)))
        (cond
         (has-blocker-violation (cons "⛔" (mapconcat #'identity (reverse all-warnings) "\n")))
         (all-warnings (cons "⚠" (mapconcat #'identity (reverse all-warnings) "\n")))
         (t (cons "✓" nil))))))))

(defun org-auto-scheduler--timegrid-task-title (task project-name)
  "Build a compact, icon-led block title for TASK.
No apply-checkbox icon: unlike the table, everything reaching the grid
already passed the skip/fail/block filter in
`org-auto-scheduler--timegrid-event-from-task', so a checked-vs-skipped
mark would have nothing left to distinguish -- the status icon alone
carries the meaning here.  PROJECT-NAME's segment is left out entirely
when there is no project (\"—\"), rather than printed as a bare dash."
  (let* ((headline (or (nth 5 task) "Untitled"))
         (marker (nth 7 task))
         (status (nth 9 task))
         (start (nth 1 task))
         (end (nth 2 task))
         (status-icon (car (org-auto-scheduler--review-status-icon-info task marker)))
         (is-split (or (eq status :split-today) (plist-get (nthcdr 9 task) :split-today)))
         (detail (cond
                  ((eq status :placeholder)
                   (let ((rem (plist-get (nthcdr 9 task) :remaining-effort)))
                     (format "%s left" (if rem (format "%dm" rem) "?"))))
                  (is-split
                   (if (and start end)
                       (format "%dm part"
                               (round (/ (float-time (time-subtract end start)) 60)))
                     (org-auto-scheduler--smart-effort-label marker)))
                  (t (org-auto-scheduler--smart-effort-label marker))))
         (score (car (org-auto-scheduler-calculate-score marker)))
         (segments (delq nil (list headline
                                   (unless (string= project-name "—") project-name)
                                   detail
                                   (format "★%.1f" score)))))
    (format "%s %s" status-icon (mapconcat #'identity segments " · "))))

(defun org-auto-scheduler--timegrid-event-from-task (task)
  "Convert TASK into an `org-timegrid-event', or nil if it should not appear.
TASK has no time slot, or is :failed/:blocked/:skipped, is left off the
grid entirely (skipped tasks in particular are never shown, per request)."
  (let ((start (nth 1 task))
        (end (nth 2 task))
        (status (nth 9 task)))
    (when (and start end (time-less-p start end) (not (memq status '(:failed :blocked :skipped))))
      (let* ((task-id (nth 0 task))
             (marker (nth 7 task))
             (project-name (or (org-auto-scheduler--get-project-name marker) "—"))
             (proj-trunc (org-auto-scheduler--truncate project-name 18))
             (color (org-auto-scheduler--status-blend-color
                     (and org-auto-scheduler--project-colors
                          (gethash proj-trunc org-auto-scheduler--project-colors))
                     task marker)))
        (org-timegrid-event-create
         :id (format "org-auto-scheduler-%s" (or task-id (sxhash task)))
         :title (org-auto-scheduler--timegrid-task-title task proj-trunc)
         :start (org-auto-scheduler--timegrid-minutes start)
         :end (org-auto-scheduler--timegrid-minutes end)
         :all-day nil
         :color color
         :source (list :marker marker :task-id task-id))))))

(defun org-auto-scheduler--timegrid-event-from-fixed-event (ev)
  "Convert a fixed (non-AUTOSCH) agenda item EV into an `org-timegrid-event'.
Marked with a lock icon 🔒 when blocking, none when toggled non-blocking,
matching the display used in the review buffer and plain-text calendar view."
  (let ((start (nth 1 ev))
        (end (nth 2 ev)))
    (when (and start end (time-less-p start end))
      (let* ((ev-id (nth 0 ev))
             (headline (or (nth 5 ev) "Event"))
             (marker (or (nth 7 ev)
                         (and ev-id (stringp ev-id) (org-id-find ev-id t))))
             (non-blocking (org-auto-scheduler-task-non-blocking-p ev-id marker))
             (title (if non-blocking headline (format "🔒 %s" headline))))
        (org-timegrid-event-create
         :id (format "org-auto-scheduler-event-%s" (or ev-id (sxhash ev)))
         :title title
         :start (org-auto-scheduler--timegrid-minutes start)
         :end (org-auto-scheduler--timegrid-minutes end)
         :all-day nil
         :color (if non-blocking "#98c379" "#5c6370")
         :source (list :marker marker))))))

(defun org-auto-scheduler--timegrid-list (review-buffer start end)
  "Return org-timegrid events for the schedule in REVIEW-BUFFER.
Reads the review buffer's live `tabulated-list-entries' (so the row
set and visual order are always current) joined with
`org-auto-scheduler-completed-tasks' for timing, plus fixed agenda
events when `org-auto-scheduler-review-show-agenda-events' is enabled.
START and END are absolute minutes, as required by an
`org-timegrid-backend' list-function."
  (unless (and review-buffer (buffer-live-p review-buffer))
    (user-error "The source review buffer no longer exists"))
  (let* ((entries (buffer-local-value 'tabulated-list-entries review-buffer))
         (task-events
          (delq nil
                (mapcar
                 (lambda (row)
                   (let* ((row-id (car row))
                          (vec (cadr row))
                          (checked (and (vectorp vec) (> (length vec) 0) (aref vec 0))))
                     (unless (or (org-auto-scheduler--review-special-row-p row-id)
                                 (string= checked "[ ]"))
                       (let ((task (assoc row-id org-auto-scheduler-completed-tasks)))
                         (when task
                           (org-auto-scheduler--timegrid-event-from-task task))))))
                 entries)))
         (event-events
          (when org-auto-scheduler-review-show-agenda-events
            (delq nil
                  (cl-loop for d from (floor start 1440) to (floor (1- end) 1440)
                           append
                           (mapcar #'org-auto-scheduler--timegrid-event-from-fixed-event
                                   (org-auto-scheduler--get-existing-events-for-date
                                    (org-auto-scheduler--timegrid-date-string d))))))))
    (append task-events event-events)))

(defun org-auto-scheduler--timegrid-visit (event)
  "Visit the Org heading backing EVENT."
  (let ((marker (plist-get (org-timegrid-event-source event) :marker)))
    (unless (and (markerp marker) (marker-buffer marker))
      (user-error "The source task is no longer available"))
    (pop-to-buffer-same-window (marker-buffer marker))
    (goto-char marker)
    (org-back-to-heading t)
    (org-fold-show-context)))

(defun org-auto-scheduler--timegrid-time-from-minutes (abs-minutes)
  "Inverse of `org-auto-scheduler--timegrid-minutes': absolute minutes
since the calendar epoch back to an Emacs time value."
  (let* ((day (floor abs-minutes 1440))
         (minute-of-day (mod abs-minutes 1440))
         (date (calendar-gregorian-from-absolute day)))
    (encode-time 0 (mod minute-of-day 60) (floor minute-of-day 60)
                 (nth 1 date) (nth 0 date) (nth 2 date))))

(defun org-auto-scheduler--timegrid-apply-drop (task-id new-start)
  "Reposition TASK-ID's row to reflect a mouse-drag drop at NEW-START.
Finds the first other task already in the review list, scheduled the
same day as NEW-START, whose current start is at/after NEW-START, and
moves TASK-ID to just before it -- the same effect as
`org-auto-scheduler-review-move-before' (keyboard).  If none is found
(dropped after everything that day, or the day has no other tasks),
moves it to the end of that day via
`org-auto-scheduler-review-move-to-day'.  Either way finishes by
recalculating the schedule so nothing overlaps; the exact dropped time
only decides ordering; the task's own effort still decides duration."
  (let* ((new-day (format-time-string "%Y-%m-%d" new-start))
         (today-str (format-time-string "%Y-%m-%d")))
    (when (string< new-day today-str)
      (user-error "Cannot schedule tasks in the past (before %s)" today-str))
    (let ((next-id
           (catch 'found
             (dolist (row tabulated-list-entries)
               (let ((row-id (car row)))
                 (unless (or (equal row-id task-id)
                             (org-auto-scheduler--review-special-row-p row-id))
                   (let* ((other (assoc row-id org-auto-scheduler-completed-tasks))
                          (other-start (and other (nth 1 other))))
                     (when (and other-start
                                (equal (format-time-string "%Y-%m-%d" other-start) new-day)
                                (not (time-less-p other-start new-start)))
                       (throw 'found row-id))))))
             nil)))
      (org-auto-scheduler--review-goto-task task-id)
      (if next-id
          (org-auto-scheduler--review-move-before-id task-id next-id)
        (org-auto-scheduler-review-move-to-day new-day)))))

(defun org-auto-scheduler--timegrid-update (review-buffer event start _end &rest _)
  "org-timegrid backend update-function: apply a mouse drag of EVENT.
Only AUTOSCH task blocks can be dragged (fixed agenda events and
placeholder chunks are rejected with a clear message).  Resizing (only
the block's END changes) is intentionally a no-op beyond a reorder: a
task's duration always comes from its Org EFFORT property via
recalculation, never from how tall its block was dragged, so nothing
happens beyond what the (unchanged) START implies."
  (let* ((source (org-timegrid-event-source event))
         (task-id (plist-get source :task-id)))
    (unless task-id
      (user-error "Only proposed tasks can be dragged here, not fixed events"))
    (unless (and review-buffer (buffer-live-p review-buffer))
      (user-error "The source review buffer no longer exists"))
    (with-current-buffer review-buffer
      (let ((task (assoc task-id org-auto-scheduler-completed-tasks)))
        (unless (and task (assoc task-id tabulated-list-entries))
          (user-error "Task no longer present in the review table"))
        (when (eq (nth 9 task) :placeholder)
          (user-error "Placeholder chunks can't be dragged; move the source task instead")))
      (org-auto-scheduler--timegrid-apply-drop
       task-id (org-auto-scheduler--timegrid-time-from-minutes start)))))

(defun org-auto-scheduler--timegrid-backend (review-buffer)
  "Return a fresh org-timegrid backend previewing REVIEW-BUFFER.
Supports dragging (moving) task blocks to reorder them -- see
`org-auto-scheduler--timegrid-update' -- but no create/delete, so
new-entry gestures and deletion still cleanly no-op with an error."
  (org-timegrid-backend-create
   :name "org-auto-scheduler proposed schedule"
   :list-function (lambda (start end)
                    (org-auto-scheduler--timegrid-list review-buffer start end))
   :update-function (lambda (event start end &rest args)
                      (apply #'org-auto-scheduler--timegrid-update
                             review-buffer event start end args))
   :visit-function #'org-auto-scheduler--timegrid-visit))

(defun org-auto-scheduler--timegrid-maybe-refresh ()
  "Refresh the live `*Org Time Grid*' buffer, if one is open, in place.
Called after table-view edits (toggle, move, recalculate) so the grid
reflects the latest checkbox/order state without waiting on its own
periodic timer or a manual `g'."
  (when (and (bound-and-true-p org-timegrid-buffer-name) (get-buffer org-timegrid-buffer-name))
    (with-current-buffer org-timegrid-buffer-name
      (when (fboundp 'org-timegrid--refresh-data)
        (ignore-errors (org-timegrid--refresh-data))))))

(defun org-auto-scheduler--timegrid-sync-week-range ()
  "Scroll the linked review table to the first day within the grid's
currently displayed week, without hiding any other day.  Earlier this
also filtered the table down to just that week, but that broke
crossing into a day outside the current week with the day-shifting and
reorder commands (their target day's rows were not even present in the
filtered list) and risked losing filtered-out rows entirely when a
reorder copied the visible subset back over the master entry list.  A
no-op unless the current buffer is a `*Org Time Grid*' opened by
`org-auto-scheduler-review-open-timegrid' (i.e. has
`org-auto-scheduler--timegrid-source-buffer' set) -- so this never
touches an unrelated, standalone use of org-timegrid.

Also a no-op when the visible week has not actually changed since the
last call (`org-auto-scheduler--timegrid-last-synced-week'): this
function runs on *every* grid redraw, including the incidental ones
`org-auto-scheduler--timegrid-maybe-refresh' triggers after an ordinary
table-view toggle or reorder, which must not go on to yank the review
table's cursor away from wherever that command just, correctly, left
it -- only a genuine week navigation should move it."
  (when (and (derived-mode-p 'org-timegrid-mode)
             org-auto-scheduler--timegrid-source-buffer
             (buffer-live-p org-auto-scheduler--timegrid-source-buffer)
             (eq (buffer-local-value 'org-auto-scheduler--review-view org-auto-scheduler--timegrid-source-buffer) 'table)
             (boundp 'org-timegrid--state) org-timegrid--state
             (fboundp 'org-timegrid--calendar-state-week-start))
    (let* ((week-start (org-timegrid--calendar-state-week-start org-timegrid--state))
           (start-date (org-auto-scheduler--timegrid-date-string week-start))
           (week-changed (not (equal org-auto-scheduler--timegrid-last-synced-week start-date)))
           (review-buffer org-auto-scheduler--timegrid-source-buffer))
      (setq org-auto-scheduler--timegrid-last-synced-week start-date)
      (when week-changed
        (with-current-buffer review-buffer
          (let ((window (get-buffer-window review-buffer t)))
            (when window
              (let ((target (cl-find-if
                             (lambda (e)
                               (and (stringp (car e))
                                    (string-prefix-p "__sep_" (car e))
                                    (not (string< (substring (car e) 6) start-date))))
                             tabulated-list-entries)))
                (when target
                  (with-selected-window window
                    (goto-char (point-min))
                    (while (and (not (eobp)) (not (equal (tabulated-list-get-id) (car target))))
                      (forward-line 1))
                    (recenter 0)))))))))))

(defun org-auto-scheduler-review-open-timegrid ()
  "Open the proposed schedule in an `org-timegrid' calendar view.
Requires `org-auto-scheduler-review-timegrid-integration' to be non-nil
and the `org-timegrid' package (https://github.com/Gleek/org-timegrid)
to be installed.  Skipped tasks are omitted from the grid.

It opens in a split directly above this very review table (the same
buffer, not a copy), which keeps every one of its usual abilities
(toggle, reorder across any day, save, apply, ...) fully working, and
scrolls to match whenever you navigate the grid to a different week
(without hiding any other day, so reordering across days or weeks
still works from the table).  Press RET/double-click a block to jump
to its Org heading, or drag a block to reorder it -- the same schedule
recalculation as `org-auto-scheduler-review-move-before' then runs so
nothing overlaps; resizing a block has no separate effect, since
duration always comes from its Org EFFORT property.  Press `T' again
-- from either the grid or this table -- to close the grid and return
focus here; nothing is copied or reset, so any changes you made are
simply still there."
  (interactive)
  (unless (derived-mode-p 'org-auto-scheduler-review-mode)
    (user-error "Run this from the Org Auto Scheduler Review buffer"))
  (unless org-auto-scheduler-review-timegrid-integration
    (if (y-or-n-p "Enable org-timegrid integration (`org-auto-scheduler-review-timegrid-integration')? ")
        (setq org-auto-scheduler-review-timegrid-integration t)
      (user-error "Set `org-auto-scheduler-review-timegrid-integration' to non-nil to enable this")))
  (unless (require 'org-timegrid nil t)
    (user-error "org-timegrid is not installed: https://github.com/Gleek/org-timegrid"))
  ;; Only safe to reference `org-timegrid-buffer-name' past this point --
  ;; it belongs to org-timegrid, which the two checks above guarantee is
  ;; now loaded.
  (let* ((review-buffer (current-buffer))
         (existing-grid (get-buffer org-timegrid-buffer-name)))
    ;; Toggle off: a grid linked to THIS review buffer is already open
    ;; and visible somewhere, so `T' from the table closes it instead of
    ;; reopening/refreshing it, mirroring what `T' does from the grid.
    (if (and existing-grid
             (eq (buffer-local-value 'org-auto-scheduler--timegrid-source-buffer existing-grid)
                 review-buffer)
             (get-buffer-window existing-grid t))
        (org-auto-scheduler--timegrid-close review-buffer
                                            (get-buffer-window existing-grid t))
      (org-auto-scheduler--timegrid-open-fresh review-buffer))))

(defun org-auto-scheduler--timegrid-open-fresh (review-buffer)
  "Do the actual work of opening/refreshing the timegrid for REVIEW-BUFFER.
Split out from `org-auto-scheduler-review-open-timegrid' so that
command can check for the toggle-off case first without duplicating
this setup.  Callable only after that command's own checks have
confirmed the integration is enabled and org-timegrid is loaded."
  (let* ((review-window (selected-window))
         (backend (org-auto-scheduler--timegrid-backend review-buffer))
         (reference-time (or (cl-some (lambda (tk) (nth 1 tk)) org-auto-scheduler-completed-tasks)
                             (current-time))))
    (org-timegrid-open backend
                       (calendar-absolute-from-gregorian
                        (let ((decoded (decode-time reference-time)))
                          (list (nth 4 decoded) (nth 3 decoded) (nth 5 decoded)))))
    (with-current-buffer org-timegrid-buffer-name
      (setq org-auto-scheduler--timegrid-source-buffer review-buffer)
      (use-local-map (copy-keymap (current-local-map)))
      (local-set-key (kbd "T") #'org-auto-scheduler-review-close-timegrid)
      (when (and (featurep 'evil) (fboundp 'evil-local-set-key))
        (evil-local-set-key 'motion (kbd "T") #'org-auto-scheduler-review-close-timegrid)
        (evil-local-set-key 'normal (kbd "T") #'org-auto-scheduler-review-close-timegrid)))
    ;; `org-timegrid-open' just popped its buffer up via `pop-to-buffer',
    ;; which -- depending on `display-buffer-alist' and any window-
    ;; management package (popwin, window-purpose, shackle, ...), or even
    ;; just because REVIEW-WINDOW was the frame's only window -- can
    ;; reuse/replace REVIEW-WINDOW itself rather than opening a separate
    ;; one, leaving what looks like two unrelated, unsplit buffers
    ;; instead of one linked view.  Make the layout deterministic instead
    ;; of trusting that guess: first force REVIEW-WINDOW back to
    ;; REVIEW-BUFFER no matter what `pop-to-buffer' did to it, then place
    ;; the grid in a *different*, freshly split window -- reusing one
    ;; `pop-to-buffer' already created elsewhere in this frame if there
    ;; is one, cleaning up any extra strays, or splitting fresh above
    ;; REVIEW-WINDOW otherwise.  All via the low-level `set-window-buffer'
    ;; / `split-window', which no display-buffer logic can redirect.
    (when (window-live-p review-window)
      (let* ((frame (window-frame review-window))
             (grid-buffer (get-buffer org-timegrid-buffer-name)))
        (set-window-buffer review-window review-buffer)
        (let* ((existing (delq review-window
                               (get-buffer-window-list grid-buffer nil frame))))
          (dolist (w (cdr existing))
            (when (and (window-live-p w) (> (length (window-list frame)) 1))
              (ignore-errors (delete-window w))))
          (let ((grid-window (or (car existing) (split-window review-window nil 'above))))
            (set-window-buffer grid-window grid-buffer)
            (select-window grid-window)
            (org-auto-scheduler--timegrid-sync-week-range)))))))

(defun org-auto-scheduler--timegrid-close (review-buffer grid-window)
  "Return focus to REVIEW-BUFFER and close GRID-WINDOW.
Shared by `org-auto-scheduler-review-close-timegrid' (called with point
already in the grid, so GRID-WINDOW is `selected-window') and the `T'
toggle-off path in `org-auto-scheduler-review-open-timegrid' (called
with point in the table, so GRID-WINDOW is looked up explicitly).  The
grid never mutates the review buffer beyond what dragging already
applied directly, so nothing else needs to be restored -- the table's
checkboxes, order, and overrides are exactly as they were left."
  (unless (and review-buffer (buffer-live-p review-buffer))
    (user-error "The source review buffer no longer exists"))
  (let ((review-window (get-buffer-window review-buffer (window-frame grid-window))))
    (if (and review-window (not (eq review-window grid-window)))
        (progn
          (select-window review-window)
          (when (window-live-p grid-window)
            (ignore-errors (delete-window grid-window))))
      (switch-to-buffer review-buffer))))

(defun org-auto-scheduler-review-close-timegrid ()
  "Return focus to the review table and close the timegrid split.
Bound to `T' inside `*Org Time Grid*' when it was opened from a review
buffer."
  (interactive)
  (org-auto-scheduler--timegrid-close org-auto-scheduler--timegrid-source-buffer
                                      (selected-window)))

;; Keep any open `*Org Time Grid*' preview in sync with table-view edits
;; (checkbox toggles, non-blocking toggles, and every reorder/recalculate
;; path), rather than waiting on its periodic timer or a manual `g'.
(dolist (cmd '(org-auto-scheduler-review-toggle
               org-auto-scheduler-review-toggle-non-blocking
               org-auto-scheduler-review-recalculate))
  (advice-add cmd :after (lambda (&rest _) (org-auto-scheduler--timegrid-maybe-refresh))))

;; Keep the review table's date scope in sync whenever the linked grid
;; redraws for any reason (initial open, week navigation, its own data
;; timer, a manual `g'), not just when we ourselves triggered the redraw.
(with-eval-after-load 'org-timegrid
  (advice-add 'org-timegrid--refresh :after
              (lambda (&rest _) (org-auto-scheduler--timegrid-sync-week-range))))

(defun org-auto-scheduler-review-help ()
  "Show help for the review buffer."
  (interactive)
  (with-output-to-temp-buffer "*Org Auto Scheduler Review Help*"
    (with-current-buffer standard-output
      (insert "Org Auto Scheduler Review Mode Keybindings:\n\n")
      (insert "  SPC, m       Toggle application of task at point (or toggle non-blocking on event)\n")
      (insert "  b            Toggle non-blocking status of fixed agenda event\n")
      (insert "  s            Toggle SPLITTABLE status on task at point\n")
      (insert "  p, i         Mark task PINNABLE (pin to specific time; other tasks reschedule after)\n")
      (insert "  TAB, RET     Jump to task or event in Org file\n")
      (insert "  x, C-c C-c   Apply all checked scheduled times to Org files\n")
      (insert "  U, p         Move task up (manually reorder / cross days)\n")
      (insert "  D, n         Move task down (manually reorder / cross days)\n")
      (insert "  P            Move task to before another task, picked by name (keyboard drag)\n")
      (insert "  >, +         Move task to next scheduled day\n")
      (insert "  <, -         Move task to previous scheduled day\n")
      (insert "  d            Move task to specific date (org-read-date)\n")
      (insert "  r, C-c C-r   Recalculate schedule (auto-compacts; C-u r preserves day sections)\n")
      (insert "  R            Refresh/re-run auto-scheduler from scratch\n")
      (insert "  S, C-c C-s   Save ordering, skipping, and day decisions across sessions\n")
      (insert "  M, C-c C-m   Restore previous review order and merge live changes\n")
      (insert "  C, C-c C-d   Clear saved decisions (all, skipped, order, non-blocking, or task at point)\n")
      (insert "  u            Undo last toggle, move, filter, or override\n")
      (insert "  e            Edit estimated effort of task at point (What-If)\n")
      (insert "  E            Toggle showing existing fixed agenda events\n")
      (insert "  v, c         Toggle between Table View and Calendar View\n")
      (insert "  T            Open proposed schedule in org-timegrid (if enabled/installed)\n\n")
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
                           " [S] Save Review Decisions\n"
                           " [M] Restore & Merge Schedule\n"
                           " [C] Clear Saved Decisions\n"
                           " [c] Score Adherence\n"
                           " [a] Adherence Report\n"
                           " [b] Bump Agenda\n"
                           " [N] Toggle Non-Blocking\n"
                           " [k] Cleanup Placeholders\n"
                           "Choice: ")
                   '(?s ?r ?t ?S ?M ?C ?c ?a ?b ?N ?n ?k))))
      (cond
       ((eq choice ?s) (call-interactively 'org-auto-scheduler-schedule-tasks))
       ((eq choice ?r) (call-interactively 'org-auto-scheduler-review-and-apply))
       ((eq choice ?t) (call-interactively 'org-auto-scheduler-schedule-today))
       ((eq choice ?S) (call-interactively 'org-auto-scheduler-review-save-decisions))
       ((eq choice ?M) (call-interactively 'org-auto-scheduler-review-restore-and-merge))
       ((eq choice ?C) (call-interactively 'org-auto-scheduler-clear-saved-decisions))
       ((eq choice ?c) (call-interactively 'org-auto-scheduler-score-schedule))
       ((eq choice ?a) (call-interactively 'org-auto-scheduler-adherence-report))
       ((eq choice ?b) (call-interactively 'org-auto-scheduler-bump-agenda))
       ((memq choice '(?N ?n)) (call-interactively 'org-auto-scheduler-toggle-non-blocking))
       ((eq choice ?k) (call-interactively 'org-auto-scheduler-cleanup-placeholders))))))

(with-eval-after-load 'transient
  (transient-define-prefix org-auto-scheduler-dispatch-menu ()
    "Org Auto Scheduler commands."
    ["Schedule"
      ("s" "Schedule tasks"          org-auto-scheduler-schedule-tasks)
      ("r" "Review & Apply"          org-auto-scheduler-review-and-apply)
      ("t" "Schedule today only"     org-auto-scheduler-schedule-today)]
    ["Decisions"
      ("S" "Save review decisions"     org-auto-scheduler-review-save-decisions)
      ("M" "Restore & merge schedule"  org-auto-scheduler-review-restore-and-merge)
      ("C" "Clear saved decisions"     org-auto-scheduler-clear-saved-decisions)]
    ["Adherence"
      ("A" "Snapshot schedule"       org-auto-scheduler-snapshot-schedule)
      ("c" "Score adherence"         org-auto-scheduler-score-schedule)
      ("a" "Adherence report"        org-auto-scheduler-adherence-report)]
    ["Tools"
      ("b" "Bump agenda"             org-auto-scheduler-bump-agenda)
      ("N" "Toggle non-blocking"     org-auto-scheduler-toggle-non-blocking)
      ("h" "Historical insights"     org-auto-scheduler-historical-insights)
      ("B" "Toggle background"       org-auto-scheduler-toggle-background)
      ("k" "Cleanup placeholders"    org-auto-scheduler-cleanup-placeholders)]))

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
                        (org-auto-scheduler--set-scheduled schedule-string)
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

;;;###autoload
(defun org-auto-scheduler-adherence-report (&optional date-str)
  "Display the full adherence report buffer for DATE-STR (defaults to today).
Calculates schedule adherence against the morning snapshot and displays the
adherence report buffer."
  (interactive
   (list (when current-prefix-arg
           (let ((prompt-date (org-read-date nil nil nil "Adherence report for date: ")))
             (when prompt-date
               (format-time-string "%Y-%m-%d" (org-time-string-to-time prompt-date)))))))
  (org-auto-scheduler-score-schedule date-str))

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

;;; org-auto-scheduler.el ends here
