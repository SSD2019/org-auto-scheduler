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

(eval-and-compile
  (let ((dir (file-name-directory (or load-file-name buffer-file-name default-directory))))
    (when (and dir (file-directory-p dir))
      (add-to-list 'load-path dir))))

(defvar org-auto-scheduler-base-dir
  (file-name-directory (or load-file-name buffer-file-name default-directory))
  "Base directory of the `org-auto-scheduler' package.")

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
(eval-when-compile (require 'evil nil t))



(log4e:deflogger "org-auto-scheduler" "%t [%l] %m" "%H:%M:%S")
(org-auto-scheduler--log-set-level 'debug)

;; Submodules (loaded before defcustoms so :set hooks can access daemon/review functions)
(require 'org-auto-scheduler-daemon)
(require 'org-auto-scheduler-analytics)
(require 'org-auto-scheduler-review)

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

(defcustom org-auto-scheduler-daily-catchup-block nil
  "Daily time window reserved as a catch-up or slack buffer.
When set to a cons cell or list of two time strings (e.g. `(\"16:00\" . \"17:00\")
or `(\"16:00\" \"17:00\")), standard auto-scheduled tasks will avoid this window,
leaving it open for catching up, buffer time, or unplanned work.
Tasks marked with :FREESET: t or `FREESET'\'' tag can still be scheduled into this window.
Set to nil to disable daily catch-up blocks."
  :type '(choice (const :tag "Disabled" nil)
                 (cons :tag "Time Range"
                       (string :tag "Start Time (HH:MM)")
                       (string :tag "End Time (HH:MM)")))
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

(defcustom org-auto-scheduler-early-done-action 'prompt
  "Action to take when a scheduled task is marked DONE or DROPPED early.
When `prompt' (default), interactively asks whether to pull upcoming tasks forward.
When `pull', automatically pulls upcoming tasks forward without prompting.
When `keep' or nil, leaves the remaining schedule unchanged."
  :type '(choice (const :tag "Interactively Prompt" prompt)
                 (const :tag "Always Pull Forward" pull)
                 (const :tag "Keep Schedule Unchanged" keep))
  :group 'org-auto-scheduler)

(defcustom org-auto-scheduler-early-done-threshold-minutes 15
  "Minimum remaining minutes before scheduled end time required to trigger early-done pull."
  :type 'integer
  :group 'org-auto-scheduler)


(defcustom org-auto-scheduler-pomodoro-enabled t
  "When non-nil, enable Pomodoro interval scheduling for tasks specifying :POMODORO: property."
  :type 'boolean
  :group 'org-auto-scheduler)

(defcustom org-auto-scheduler-pomodoro-property "POMODORO"
  "Org headline property specifying task-scoped Pomodoro work and break intervals.
Value format: 'WORK:BREAK' in minutes (e.g. '25:5', '50:10', or '25 : 5').
When present on a task, the task is split into WORK-minute chunks separated by
BREAK-minute breaks, and followed by a BREAK-minute rest interval."
  :type 'string
  :group 'org-auto-scheduler)

(defcustom org-auto-scheduler-pomodoro-work-minutes 25
  "Default continuous work minutes before a Pomodoro break if break is omitted."
  :type 'integer
  :group 'org-auto-scheduler)

(defcustom org-auto-scheduler-pomodoro-break-minutes 5
  "Default duration in minutes of Pomodoro breaks if only work is specified."
  :type 'integer
  :group 'org-auto-scheduler)

(defvar org-auto-scheduler--pomodoro-continuous-minutes 0
  "Internal continuous work tracker in minutes for Pomodoro break weaving.")

(defun org-auto-scheduler-get-task-pomodoro-spec (marker &optional task-id)
  "Return a plist (:work INT :break INT) if task has a valid Pomodoro property.
Returns nil if the task does not have a POMODORO property or if pomodoro is disabled."
  (when org-auto-scheduler-pomodoro-enabled
    (let* ((m (or marker
                  (when task-id
                    (or (org-id-find task-id t)
                        (let ((pos (org-find-entry-with-id task-id)))
                          (when pos (set-marker (make-marker) pos (current-buffer))))))))
           (prop (when (and m (markerp m) (marker-buffer m))
                   (org-with-point-at m
                     (org-entry-get nil org-auto-scheduler-pomodoro-property t)))))
      (when (and prop (stringp prop))
        (let ((trimmed (string-trim prop)))
          (cond
           ((string-match "^:?[ \t]*\\([0-9]+\\)[ \t]*[:/][ \t]*\\([0-9]+\\)$" trimmed)
            (let ((w (string-to-number (match-string 1 trimmed)))
                  (b (string-to-number (match-string 2 trimmed))))
              (when (> w 0)
                (list :work w :break (max 0 b)))))
           ((string-match "^:?[ \t]*\\([0-9]+\\)$" trimmed)
            (let ((w (string-to-number (match-string 1 trimmed))))
              (when (> w 0)
                (list :work w :break (or org-auto-scheduler-pomodoro-break-minutes 5)))))
           (t nil)))))))

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

(defcustom org-auto-scheduler-project-batching-tolerance 0.15
  "Fractional tolerance (0.0 to 1.0) for soft project batching to reduce context switches.
When interleaving projects, if a task from the currently active project has a score
within this fraction of a competing project's task, the active project's task is
preferred. Set to 0.0 or nil to disable project batching."
  :type '(choice (float :tag "Tolerance fraction (e.g. 0.15)")
                 (const :tag "Disabled" nil))
  :group 'org-auto-scheduler)

(defcustom org-auto-scheduler-critical-path-enabled t
  "When non-nil, perform Critical Path Method (CPM) float analysis on task dependencies.
Tasks with total float less than or equal to `org-auto-scheduler-critical-path-max-float-hours'
receive a score boost of `org-auto-scheduler-critical-path-boost'."
  :type 'boolean
  :group 'org-auto-scheduler)

(defcustom org-auto-scheduler-critical-path-boost 50.0
  "Score boost awarded to tasks on or near the critical path (zero or low float)."
  :type 'float
  :group 'org-auto-scheduler)

(defcustom org-auto-scheduler-critical-path-max-float-hours 4.0
  "Maximum total float (in hours) for a task to be considered on the critical path.
Tasks in a dependency chain with total float less than or equal to this threshold
receive `org-auto-scheduler-critical-path-boost'. Set to 0.0 to boost only strictly
zero-float tasks."
  :type 'float
  :group 'org-auto-scheduler)

(defvar org-auto-scheduler--last-scheduled-project-id nil
  "Project ID of the task most recently scheduled or popped during task sequencing.")

(defvar org-auto-scheduler--critical-tasks (make-hash-table :test 'equal)
  "Hash table mapping task-id to t for tasks currently identified on the critical path.")

(defcustom org-auto-scheduler-siblings-sequential t
  "When non-nil (default), project subtasks under the same parent are scheduled sequentially
in outline order, unless overridden by :ORDERED: nil, :PARALLEL: t, or :INDEPENDENT: t."
  :type 'boolean
  :group 'org-auto-scheduler)

(defcustom org-auto-scheduler-ordered-property "ORDERED"
  "Org property name for heading sequence ordering. Matches Org's built-in :ORDERED: property."
  :type 'string
  :group 'org-auto-scheduler)

(defcustom org-auto-scheduler-parallel-property "PARALLEL"
  "Org property name to allow siblings to be scheduled concurrently/in parallel."
  :type 'string
  :group 'org-auto-scheduler)

(defcustom org-auto-scheduler-independent-property "INDEPENDENT"
  "Org property name to mark a single task as independent from its siblings."
  :type 'string
  :group 'org-auto-scheduler)

(defcustom org-auto-scheduler-kill-todo-state "DROPPED"
  "TODO state applied when a task contains the (-kill-), (-c-), or (-drop-) title marker."
  :type 'string
  :group 'org-auto-scheduler)

(defcustom org-auto-scheduler-waiting-states
  '("WAITING" "HOLD" "PENDING")
  "List of TODO states representing tasks waiting on external events or people.
These tasks are never allocated active work slots by the auto-scheduler.
Instead, they are tracked and displayed in the 'Waiting on Others' section
at the bottom of the review buffer."
  :type '(repeat string)
  :group 'org-auto-scheduler)

(defcustom org-auto-scheduler-waiting-auto-clock-out t
  "When non-nil, automatically clock out if currently clocked into a task
that is moved into one of `org-auto-scheduler-waiting-states'."
  :type 'boolean
  :group 'org-auto-scheduler)

(defcustom org-auto-scheduler-waiting-clear-scheduled-time 'clear-time
  "Action to take on SCHEDULED when a task transitions to a waiting state.
`clear-time': remove the time-of-day component, keeping the date as a follow-up tickler (e.g. <2026-10-02>).
`clear-all': remove the SCHEDULED property entirely.
nil: leave SCHEDULED unchanged."
  :type '(choice (const :tag "Strip time-of-day (keep follow-up date)" clear-time)
                 (const :tag "Remove SCHEDULED completely" clear-all)
                 (const :tag "Do nothing" nil))
  :group 'org-auto-scheduler)

(defcustom org-auto-scheduler-waiting-stale-days 5
  "Number of days a task can remain in a waiting state before being flagged as stale."
  :type 'integer
  :group 'org-auto-scheduler)

(defcustom org-auto-scheduler-waiting-require-autosch-tag t
  "If non-nil, only track waiting tasks that carry the AUTOSCH tag.
If nil, track all tasks in `org-agenda-files' that have a waiting state."
  :type 'boolean
  :group 'org-auto-scheduler)

(defcustom org-auto-scheduler-waiting-since-property "WAITING_SINCE"
  "Org property used to record when a task entered a waiting state."
  :type 'string
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

(defcustom org-auto-scheduler-freeset-tag "FREESET"
  "Tag used to mark a task as free to schedule outside normal working hours."
  :type 'string
  :group 'org-auto-scheduler)

(defcustom org-auto-scheduler-freeset-property "FREESET"
  "Org headline property used to mark a task as free to schedule outside working hours."
  :type 'string
  :group 'org-auto-scheduler)

(defcustom org-auto-scheduler-pinned-tag "PINNED"
  "Tag used to mark a task as pinned to an exact scheduled time."
  :type 'string
  :group 'org-auto-scheduler)

(defcustom org-auto-scheduler-pinned-property "PINNED"
  "Org headline property indicating that a task is pinned."
  :type 'string
  :group 'org-auto-scheduler)

(defcustom org-auto-scheduler-pinned-time-property "PINNED_TIME"
  "Org headline property storing the pinned start time for a task."
  :type 'string
  :group 'org-auto-scheduler)

;; Backward compatibility aliases for old PINNABLE configuration variables
(defvaralias 'org-auto-scheduler-pinnable-tag 'org-auto-scheduler-freeset-tag)
(defvaralias 'org-auto-scheduler-pinnable-property 'org-auto-scheduler-freeset-property)

(defvar org-auto-scheduler-report-buffer-name "*Org Auto Scheduler Report*"
  "Name of the buffer for the Org Auto Scheduler Report.")

(defcustom org-auto-scheduler-silent-mode nil
  "When non-nil, suppress report creation and display."
  :type 'boolean
  :group 'org-auto-scheduler)

(defcustom org-auto-scheduler-background-enabled nil
  "When non-nil, enable background auto-scheduling when Emacs is idle."
  :type 'boolean
  :set (lambda (sym val)
         (set-default sym val)
         (when (fboundp 'org-auto-scheduler-setup-background)
           (org-auto-scheduler-setup-background)))
  :group 'org-auto-scheduler)

(defcustom org-auto-scheduler-idle-time 300
  "Number of idle seconds before running the background scheduler."
  :type 'integer
  :set (lambda (sym val)
         (set-default sym val)
         (when (fboundp 'org-auto-scheduler-setup-background)
           (org-auto-scheduler-setup-background)))
  :group 'org-auto-scheduler)

(defcustom org-auto-scheduler-background-interval 300
  "Interval in seconds between background scheduling runs during continuous idle."
  :type 'integer
  :set (lambda (sym val)
         (set-default sym val)
         (when (fboundp 'org-auto-scheduler-setup-background)
           (org-auto-scheduler-setup-background)))
  :group 'org-auto-scheduler)

(defcustom org-auto-scheduler-background-async t
  "When non-nil, execute background auto-scheduling asynchronously in a thread.
This prevents Emacs from freezing or blocking user input during background runs."
  :type 'boolean
  :group 'org-auto-scheduler)

(defcustom org-auto-scheduler-background-pause-on-clock nil
  "When non-nil, pause background auto-scheduling while a task is clocked in.
When nil (default), background scheduling proceeds even if a clock is running."
  :type 'boolean
  :group 'org-auto-scheduler)

(defcustom org-auto-scheduler-background-pause-on-review nil
  "When non-nil, pause background auto-scheduling while the review buffer is active.
The review buffer is considered active when `*Org Auto Scheduler Review*' or
`*Org Time Grid*' is visible in any window.
When nil (default), background scheduling is not paused merely because the review buffer
is visible (though it will still pause during active scheduling, review preparation,
review application, or CalDAV synchronization to prevent race conditions)."
  :type 'boolean
  :group 'org-auto-scheduler)

(defvar org-auto-scheduler-change-log-buffer-name "*Org Auto Scheduler Changes*"
  "Name of the buffer for the Org Auto Scheduler change log.")

(defcustom org-auto-scheduler-change-log-enabled t
  "When non-nil, log changes executed during background runs."
  :type 'boolean
  :group 'org-auto-scheduler)

(defcustom org-auto-scheduler-change-log-file
  (expand-file-name "org-auto-scheduler-changes.org" user-emacs-directory)
  "File path for persisting the background change log.
If nil, changes are only recorded in the `*Org Auto Scheduler Changes*` buffer."
  :type '(choice (file :tag "Log file")
                 (const :tag "No file logging (buffer only)" nil))
  :group 'org-auto-scheduler)

(defcustom org-auto-scheduler-change-log-record-empty nil
  "When non-nil, record a log entry even when a background run makes no changes.
When nil (default), only runs that modify task schedules, title markers,
or split tasks will be recorded, keeping the log concise and noise-free."
  :type 'boolean
  :group 'org-auto-scheduler)

(defcustom org-auto-scheduler-change-log-collate-empty t
  "When non-nil, collate consecutive background runs with no changes into a single node.
Each 0-change run is appended as a timestamped bullet point under the existing
node instead of creating a new top-level heading every run."
  :type 'boolean
  :group 'org-auto-scheduler)

(defcustom org-auto-scheduler-change-log-background-only t
  "When non-nil, only background scheduler runs are recorded to the change log.
When nil, manual scheduling runs are also recorded."
  :type 'boolean
  :group 'org-auto-scheduler)

(defcustom org-auto-scheduler-change-log-notify t
  "When non-nil, display a message in the echo area when a background run makes changes."
  :type 'boolean
  :group 'org-auto-scheduler)

(defcustom org-auto-scheduler-change-log-max-entries 200
  "Maximum number of run entries to retain in the change log buffer and file.
Older entries beyond this limit are pruned to prevent unbounded growth."
  :type 'integer
  :group 'org-auto-scheduler)

(defcustom org-auto-scheduler-background-save-buffers t
  "When non-nil, save modified Org agenda buffers to disk after background changes."
  :type 'boolean
  :group 'org-auto-scheduler)

(defvar org-auto-scheduler--current-run-type nil
  "Tracks current scheduler execution mode: \='background-async, \='background-sync, or nil (manual).")

(defvar org-auto-scheduler--run-start-time nil
  "Start time of the currently running scheduler execution.")

(defvar org-auto-scheduler--last-run-changes nil
  "List of detected changes from the most recent scheduler run.")

(defvar org-auto-scheduler--session-cleaned-placeholders 0
  "Tracks number of placeholders cleaned during current scheduler run.")


(defcustom org-auto-scheduler-start-buffer-minutes 5
  "Buffer minutes added to current time when starting task scheduling.
Defaults to 5 minutes. If a task is currently clocked in, 0 minutes is used instead."
  :type 'integer
  :group 'org-auto-scheduler)

(defcustom org-auto-scheduler-preserve-today-scheduled t
  "When non-nil, tasks already scheduled for today are preserved unless
rescheduling is triggered by a title marker (such as -r- or -r-all-)."
  :type 'boolean
  :group 'org-auto-scheduler)

(defcustom org-auto-scheduler-preserve-future-scheduled t
  "When non-nil, tasks already scheduled for future days with a specific time
are preserved during scheduling runs, unless rescheduling is triggered by a
title marker (such as -r- or -r-all-) or `force-replan'."
  :type 'boolean
  :group 'org-auto-scheduler)

(defcustom org-auto-scheduler-title-marker-regex
  (let ((token "\\(?:r-all\\|done\\|kill\\|drop\\|defer\\|pri-none\\|\\+[0-9]+d\\|w\\+[0-9]+[dwmy]\\|wait\\+[0-9]+[dwmy]\\|wait\\|e[0-9]+[hm0-9:]*\\|#[a-zA-Z]\\|pri-?[a-zA-Z]\\|![a-zA-Z]\\|\\\\indep\\|indep\\|\\\\[sfpi#!]\\|[rsfpxciwRSFPXCIW]\\)"))
    (format "\\(?:(\\s-*\\)?-\\(%s\\(?:-?%s\\)*\\)-\\(?:\\s-*)\\)?" token token))
  "Regular expression matching title markers for task scheduling modifiers.
Matches patterns like (-r-), -r-, (-s-), (-f-), (-p-), (-\\s-), (-\\f-), (-\\p-), (-rsf-),
(-rp-), (-r\\p-), (-r-all-), (-x-), (-done-), (-kill-), (-drop-), (-c-), (-e30m-), (-e1h-),
(-e1:30-), (-+1d-), (-defer-), (-#A-), (-#a-), (-#B-), (-pri-a-), (-!a-), (-i-), (-indep-),
(-\\i-), (-\\indep-), etc."
  :type 'string
  :group 'org-auto-scheduler)

(defvar org-auto-scheduler--idle-timer nil
  "Primary idle timer for background auto-scheduling.")

(defvar org-auto-scheduler--repeat-idle-timer nil
  "Timer for repeating background auto-scheduling during continuous idle.")

(defvar org-auto-scheduler--background-running nil
  "Flag to prevent concurrent background scheduling runs.")

(defvar org-auto-scheduler--background-thread nil
  "Thread object running the background scheduler asynchronously.")

(defvar org-auto-scheduler--active-operation nil
  "Tracks whether an active scheduler operation (e.g. manual scheduling,
review preparation, review application, or sync) is currently in progress.")

(defmacro org-auto-scheduler--with-active-operation (op-name &rest body)
  "Execute BODY with `org-auto-scheduler--active-operation' bound to OP-NAME."
  (declare (indent 1) (debug t))
  (let ((prev-op (make-symbol "prev-op")))
    `(let ((,prev-op org-auto-scheduler--active-operation))
       (unwind-protect
           (progn
             (setq org-auto-scheduler--active-operation ,op-name)
             ,@body)
         (setq org-auto-scheduler--active-operation ,prev-op)))))

(defcustom org-auto-scheduler-sync-caldav t
  "When non-nil, automatically sync with CalDAV before and after scheduling tasks."
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

(defun org-auto-scheduler--get-waiting-blockers (marker)
  "Return a list of blocker markers for MARKER whose TODO state is in `org-auto-scheduler-waiting-states'."
  (let ((blockers (org-auto-scheduler-get-blockers marker))
        (waiting nil))
    (dolist (m blockers)
      (when (and (markerp m) (marker-buffer m))
        (org-with-point-at m
          (let ((state (org-get-todo-state)))
            (when (and state (member state org-auto-scheduler-waiting-states))
              (push m waiting))))))
    (nreverse waiting)))

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
                   (is-waiting (and todo (member todo org-auto-scheduler-waiting-states)))
                   (b-id (org-with-point-at m (org-id-get)))
                   (b-task (or (cl-find m org-auto-scheduler-completed-tasks
                                        :key (lambda (x) (nth 7 x)))
                               (and b-id (assoc b-id org-auto-scheduler-completed-tasks))))
                   (stat-label
                    (cond
                     (is-done "[DONE]")
                     (is-waiting (format "[WAITING: %s]" todo))
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

(declare-function org-auto-scheduler--build-pinned-cache "org-auto-scheduler")

(defun org-auto-scheduler--build-agenda-cache ()
  "Scan all agenda files once and build a cache of agenda items per date."
  (setq org-auto-scheduler--agenda-cache (make-hash-table :test 'equal))
  (org-map-entries
   (lambda ()
     (let* ((task-name (org-get-heading t t t t))
            (tags (org-get-tags))
            (state (org-get-todo-state))
            (is-done (and state (member state (or org-done-keywords '("DONE" "CANCELLED" "DROPPED")))))
            (is-waiting (and state (member state org-auto-scheduler-waiting-states)))
            (is-placeholder (or (member org-auto-scheduler-placeholder-tag tags)
                                (org-entry-get nil "AUTOSCH_PLACEHOLDER")
                                (org-entry-get nil "AUTOSCH_ORIGIN_ID")))
            (has-repeater (org-auto-scheduler-has-repeater-task (point-marker))))
       (unless (or (member "AUTOSCH" tags)
                   (member "ARCHIVE" tags)
                   is-done
                   is-waiting
                   is-placeholder
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
  (org-auto-scheduler--build-pinned-cache)
  (org-auto-scheduler--log-info "Built agenda cache with %d days." (hash-table-count org-auto-scheduler--agenda-cache)))

(defun org-auto-scheduler--fetch-base-agenda-items-for-date (date-string)
  "Fallback method to fetch native agenda items for DATE-STRING."
  (delq nil
        (append
         ;; Scheduled tasks (excluding habit tasks to avoid double-counting)
         (org-map-entries
          (lambda ()
            (let* ((task-name (org-get-heading t t t t))
                   (state (org-get-todo-state))
                   (is-done (and state (member state (or org-done-keywords '("DONE" "CANCELLED" "DROPPED")))))
                   (is-waiting (and state (member state org-auto-scheduler-waiting-states)))
                   (scheduled-time-str (org-entry-get nil "SCHEDULED"))
                   (scheduled-time (when scheduled-time-str (org-time-string-to-time scheduled-time-str)))
                   (has-time-flag (when scheduled-time-str (string-match "[0-9][0-9]:[0-9][0-9]" scheduled-time-str)))
                   (task-id (org-id-get))
                   (tags (org-get-tags))
                   (is-placeholder (or (member org-auto-scheduler-placeholder-tag tags)
                                       (org-entry-get nil "AUTOSCH_PLACEHOLDER")
                                       (org-entry-get nil "AUTOSCH_ORIGIN_ID")))
                   (has-repeater (org-auto-scheduler-has-repeater-task (point-marker))))
              ;; Exclude AUTOSCH tags, placeholders, ARCHIVE tags, DONE tasks, waiting tasks, and repeater tasks (repeaters are handled separately)
              (when (and scheduled-time
                         (not (member "AUTOSCH" tags))
                         (not is-done)
                         (not is-waiting)
                         (not is-placeholder)
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
                   (state (org-get-todo-state))
                   (is-done (and state (member state (or org-done-keywords '("DONE" "CANCELLED" "DROPPED")))))
                   (is-waiting (and state (member state org-auto-scheduler-waiting-states)))
                   (scheduled-time-str (org-entry-get nil "TIMESTAMP"))
                   (scheduled-time (when scheduled-time-str (org-time-string-to-time scheduled-time-str)))
                   (has-time-flag (when scheduled-time-str (string-match "[0-9][0-9]:[0-9][0-9]" scheduled-time-str)))
                   (task-id (org-id-get))
                   (tags (org-get-tags))
                   (is-placeholder (or (member org-auto-scheduler-placeholder-tag tags)
                                       (org-entry-get nil "AUTOSCH_PLACEHOLDER")
                                       (org-entry-get nil "AUTOSCH_ORIGIN_ID")))
                   (has-repeater (org-auto-scheduler-has-repeater-task (point-marker))))
              ;; Exclude AUTOSCH tags, placeholders, ARCHIVE tags, DONE tasks, waiting tasks, and repeater tasks
              (when (and scheduled-time
                         (not (member "AUTOSCH" tags))
                         (not is-done)
                         (not is-waiting)
                         (not is-placeholder)
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

        ;; Add reservations for pinned tasks not yet completed
        (dolist (item (org-auto-scheduler--get-pinned-tasks-reservations date-string))
          (let ((tid (nth 0 item)))
            (unless (cl-some (lambda (tk) (equal (nth 0 tk) tid)) org-auto-scheduler-completed-tasks)
              (push item agenda-items))))

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

(defun org-auto-scheduler--task-clocked-p (marker)
  "Return non-nil if the task at MARKER is currently clocked in."
  (and (markerp marker)
       (marker-buffer marker)
       (or (and (fboundp 'org-clocking-p) (org-clocking-p))
           (and (fboundp 'org-clock-is-active) (org-clock-is-active)))
       (let ((clock-buf (or (and (boundp 'org-clock-hd-marker) (markerp org-clock-hd-marker) (marker-buffer org-clock-hd-marker))
                            (and (boundp 'org-clock-marker) (markerp org-clock-marker) (marker-buffer org-clock-marker))))
             (clock-pos (or (and (boundp 'org-clock-hd-marker) (markerp org-clock-hd-marker) (marker-position org-clock-hd-marker))
                            (and (boundp 'org-clock-marker) (markerp org-clock-marker)
                                 (org-with-point-at org-clock-marker
                                   (ignore-errors (org-back-to-heading t) (point))))))
             (marker-pos (org-with-point-at marker
                           (ignore-errors (org-back-to-heading t) (point)))))
         (and clock-buf
              (equal clock-buf (marker-buffer marker))
              clock-pos
              marker-pos
              (= clock-pos marker-pos)))))

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
        (when (org-auto-scheduler--task-clocked-p marker)
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

(defun org-auto-scheduler--parse-effort-string (str)
  "Parse a duration STR like '30m', '45', '1h', '1h30m', '1:30' into minutes.
Returns integer minutes or nil if invalid."
  (when (stringp str)
    (cond
     ((string-match "^\\([0-9]+\\):\\([0-9]+\\)$" str)
      (+ (* (string-to-number (match-string 1 str)) 60)
         (string-to-number (match-string 2 str))))
     ((string-match "^\\([0-9]+\\)h\\(?:\\([0-9]+\\)?m?\\)?$" str)
      (+ (* (string-to-number (match-string 1 str)) 60)
         (if (match-string 2 str) (string-to-number (match-string 2 str)) 0)))
     ((string-match "^\\([0-9]+\\)m?$" str)
      (string-to-number (match-string 1 str)))
     (t nil))))

(defun org-auto-scheduler--siblings-sequential-p (parent-node project-id)
  "Return non-nil if siblings under PARENT-NODE should be scheduled sequentially.
Checks parent node properties (:ORDERED:, :PARALLEL:), tags (:PARALLEL:), then project properties
(:PROJECT_ORDERED:, :PROJECT_PARALLEL:) and tags, falling back to `org-auto-scheduler-siblings-sequential`."
  (let ((sequential-setting 'unset))
    ;; 1. Check parent node if it is an actual heading (not 'top)
    (when (and (consp parent-node)
               (buffer-live-p (car parent-node))
               (integerp (cdr parent-node)))
      (save-excursion
        (with-current-buffer (car parent-node)
          (goto-char (cdr parent-node))
          (let* ((props (org-entry-properties nil 'standard))
                 (ordered (or (cdr (assoc-string org-auto-scheduler-ordered-property props t))
                              (org-entry-get nil org-auto-scheduler-ordered-property)))
                 (parallel (or (cdr (assoc-string org-auto-scheduler-parallel-property props t))
                               (org-entry-get nil org-auto-scheduler-parallel-property)))
                 (tags (org-get-tags nil t)))
            (cond
             ((or (member "PARALLEL" tags)
                  (member (downcase (or parallel "")) '("t" "yes" "1")))
              (setq sequential-setting nil))
             ((member (downcase (or parallel "")) '("nil" "no" "0"))
              (setq sequential-setting t))
             ((member (downcase (or ordered "")) '("nil" "no" "0"))
              (setq sequential-setting nil))
             ((member (downcase (or ordered "")) '("t" "yes" "1"))
              (setq sequential-setting t)))))))
    ;; 2. If not determined by parent heading, check project root heading
    (when (and (eq sequential-setting 'unset) project-id)
      (let ((proj-marker (org-id-find project-id t)))
        (when proj-marker
          (org-with-point-at proj-marker
            (let* ((props (org-entry-properties nil 'standard))
                   (proj-ordered (or (cdr (assoc-string "PROJECT_ORDERED" props t))
                                     (org-entry-get nil "PROJECT_ORDERED")))
                   (proj-parallel (or (cdr (assoc-string "PROJECT_PARALLEL" props t))
                                      (org-entry-get nil "PROJECT_PARALLEL")))
                   (proj-tags (org-get-tags nil t)))
              (cond
               ((or (member "PARALLEL" proj-tags)
                    (member (downcase (or proj-parallel "")) '("t" "yes" "1")))
                (setq sequential-setting nil))
               ((member (downcase (or proj-parallel "")) '("nil" "no" "0"))
                (setq sequential-setting t))
               ((member (downcase (or proj-ordered "")) '("nil" "no" "0"))
                (setq sequential-setting nil))
               ((member (downcase (or proj-ordered "")) '("t" "yes" "1"))
                (setq sequential-setting t))))))))
    ;; 3. Fallback to global setting
    (if (eq sequential-setting 'unset)
        org-auto-scheduler-siblings-sequential
      sequential-setting)))

(defun org-auto-scheduler-task-independent-p (marker)
  "Return non-nil if task at MARKER is marked independent or parallel from siblings."
  (org-with-point-at marker
    (let ((tags (org-get-tags nil t))
          (independent (org-entry-get nil org-auto-scheduler-independent-property))
          (parallel (org-entry-get nil org-auto-scheduler-parallel-property)))
      (or (member "INDEPENDENT" tags)
          (member "PARALLEL" tags)
          (member (downcase (or independent "")) '("t" "yes" "1"))
          (member (downcase (or parallel "")) '("t" "yes" "1"))))))

(defun org-auto-scheduler--complex-sort-predicate (a b project-max-scores)
  "Return t if task A has higher priority than task B based on complex scheduling rules."
  (let* ((id-a (nth 5 a))
         (id-b (nth 5 b))
         (dec-a (org-auto-scheduler-get-saved-decision id-a (nth 0 a)))
         (dec-b (org-auto-scheduler-get-saved-decision id-b (nth 0 b)))
         (order-a (and dec-a (not (plist-get dec-a :is-new)) (plist-get dec-a :order)))
         (order-b (and dec-b (not (plist-get dec-b :is-new)) (plist-get dec-b :order)))
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
          (let ((tol (or org-auto-scheduler-project-batching-tolerance 0.0))
                (last-proj org-auto-scheduler--last-scheduled-project-id))
            (cond
             ((and (> tol 0.0) last-proj
                   (equal project-a last-proj)
                   (not (equal project-b last-proj)))
              (let ((diff-threshold (* (max 1.0 (abs score-a) (abs score-b)) tol)))
                (>= score-a (- score-b diff-threshold))))
             ((and (> tol 0.0) last-proj
                   (equal project-b last-proj)
                   (not (equal project-a last-proj)))
              (let ((diff-threshold (* (max 1.0 (abs score-a) (abs score-b)) tol)))
                (< score-b (- score-a diff-threshold))))
             (t
              (> score-a score-b))))
        (if (= max-score-a max-score-b)
            (> score-a score-b)
          (> max-score-a max-score-b))))

     ;; 3. Same project or no project
     ((equal project-a project-b)
      (if (and (equal (car (nth 4 a)) (car (nth 4 b)))
               (org-auto-scheduler--siblings-sequential-p (car (nth 4 a)) project-a)
               (not (nth 15 a))
               (not (nth 15 b)))
          ;; Direct sequential siblings keep their relative textual order
          (< (cdr (nth 4 a)) (cdr (nth 4 b)))
        ;; Tasks across different subtrees or parallel siblings sort by their score prioritizing highest impact
        (> score-a score-b)))

     ;; 4. Fallback to individual scores
     ((not (= score-a score-b))
      (> score-a score-b))

     (t nil))))

(defun org-auto-scheduler--compute-critical-path-floats (id-to-info adj-list preds-map pool-ids)
  "Compute Total Float (in hours) for tasks participating in dependencies.
ID-TO-INFO maps task-id to its task info list.
ADJ-LIST maps task-id to a list of its successor task-ids.
PREDS-MAP maps task-id to a list of its predecessor task-ids.
POOL-IDS is a hash table containing all task-ids in the current scheduling pool.
Returns a hash table mapping task-id to total float in hours."
  (let ((floats (make-hash-table :test 'equal))
        (es-table (make-hash-table :test 'equal))
        (ef-table (make-hash-table :test 'equal))
        (lf-table (make-hash-table :test 'equal))
        (durations (make-hash-table :test 'equal))
        (dep-task-ids '()))
    ;; Identify all tasks that participate in a dependency relationship
    (maphash (lambda (id _)
               (when (or (gethash id adj-list) (gethash id preds-map))
                 (push id dep-task-ids)
                 (let* ((task (gethash id id-to-info))
                        (eff (and task (nth 12 task)))
                        (dur (max 1 (or eff org-auto-scheduler-default-task-duration 60))))
                   (puthash id dur durations))))
             pool-ids)
    (when dep-task-ids
      ;; 1. Compute ES and EF via forward pass
      (let ((visiting (make-hash-table :test 'equal)))
        (cl-labels ((calc-es (id)
                      (or (gethash id es-table)
                          (if (gethash id visiting)
                              0 ; Cycle breaker
                            (puthash id t visiting)
                            (let* ((preds (gethash id preds-map))
                                   (max-pred-ef
                                    (if preds
                                        (apply #'max (mapcar #'calc-ef preds))
                                      0)))
                              (puthash id nil visiting)
                              (puthash id max-pred-ef es-table)
                              max-pred-ef))))
                    (calc-ef (id)
                      (or (gethash id ef-table)
                          (let* ((es (calc-es id))
                                 (dur (gethash id durations 60))
                                 (ef (+ es dur)))
                            (puthash id ef ef-table)
                            ef))))
          (dolist (id dep-task-ids)
            (calc-ef id))))

      ;; 2. Partition into connected components to determine T_max per component
      (let ((visited-comp (make-hash-table :test 'equal))
            (components '()))
        (dolist (id dep-task-ids)
          (unless (gethash id visited-comp)
            (let ((comp '())
                  (q (list id)))
              (puthash id t visited-comp)
              (while q
                (let ((curr (pop q)))
                  (push curr comp)
                  (dolist (neighbor (append (gethash curr adj-list) (gethash curr preds-map)))
                    (when (and (gethash neighbor durations)
                               (not (gethash neighbor visited-comp)))
                      (puthash neighbor t visited-comp)
                      (push neighbor q)))))
              (push comp components))))

        ;; 3. Compute LF and Total Float per component via backward pass
        (dolist (comp components)
          (let* ((t-max (apply #'max (mapcar (lambda (cid) (gethash cid ef-table 0)) comp)))
                 (visiting-bwd (make-hash-table :test 'equal)))
            (cl-labels ((calc-lf (id)
                          (or (gethash id lf-table)
                              (if (gethash id visiting-bwd)
                                  t-max ; Cycle breaker
                                (puthash id t visiting-bwd)
                                (let* ((succs (gethash id adj-list))
                                       (min-succ-ls
                                        (if succs
                                            (apply #'min (mapcar #'calc-ls succs))
                                          t-max)))
                                  (puthash id nil visiting-bwd)
                                  (puthash id min-succ-ls lf-table)
                                  min-succ-ls))))
                        (calc-ls (id)
                          (let* ((lf (calc-lf id))
                                 (dur (gethash id durations 60)))
                            (- lf dur))))
              (dolist (id comp)
                (let* ((ef (gethash id ef-table 0))
                       (lf (calc-lf id))
                       (total-float-mins (max 0 (- lf ef)))
                       (total-float-hours (/ (float total-float-mins) 60.0)))
                  (puthash id total-float-hours floats))))))))
    floats))

(defun org-auto-scheduler-task-critical-p (task-id)
  "Return non-nil if TASK-ID is currently identified on the critical path."
  (and org-auto-scheduler-critical-path-enabled
       task-id
       (hash-table-p org-auto-scheduler--critical-tasks)
       (gethash task-id org-auto-scheduler--critical-tasks)))

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
                           (dependency-depth 0) ; Overwritten during Topological Sort
                           (is-independent (org-auto-scheduler-task-independent-p marker)))
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
                            dependency-depth   ; 14
                            is-independent)))  ; 15
                  tasks))
         ;; Calculate max score per project
         (project-max-scores (make-hash-table :test 'equal))

         ;; Graph State Trackers
         (in-degree (make-hash-table :test 'equal))
         (adj-list (make-hash-table :test 'equal))
         (preds-map (make-hash-table :test 'equal))
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
              (puthash task-id (cons b-id (gethash task-id preds-map)) preds-map)
              (puthash task-id (1+ (gethash task-id in-degree 0)) in-degree))))))

    ;; 2. Add Implicit Sibling Blockers Edges
    (maphash (lambda (parent-key group)
               (let* ((parent-node (car parent-key))
                      (project-id (cdr parent-key))
                      (is-sequential (org-auto-scheduler--siblings-sequential-p parent-node project-id)))
                 (when is-sequential
                   (let ((sorted-group
                          (sort group
                                (lambda (a b)
                                  (let* ((dec-a (org-auto-scheduler-get-saved-decision (nth 5 a) (nth 0 a)))
                                         (dec-b (org-auto-scheduler-get-saved-decision (nth 5 b) (nth 0 b)))
                                         (order-a (and dec-a (not (plist-get dec-a :is-new)) (plist-get dec-a :order)))
                                         (order-b (and dec-b (not (plist-get dec-b :is-new)) (plist-get dec-b :order))))
                                    (cond
                                     ((and order-a order-b (not (= order-a order-b)))
                                      (< order-a order-b))
                                     (order-a t)
                                     (order-b nil)
                                     (t (< (cdr (nth 4 a)) (cdr (nth 4 b))))))))))
                     (let ((prev-id nil))
                       (dolist (info sorted-group)
                         (let ((curr-id (nth 5 info))
                               (curr-indep (nth 15 info)))
                           (unless curr-indep
                             (when prev-id
                               (puthash prev-id (cons curr-id (gethash prev-id adj-list)) adj-list)
                               (puthash curr-id (cons prev-id (gethash curr-id preds-map)) preds-map)
                               (puthash curr-id (1+ (gethash curr-id in-degree 0)) in-degree))
                             (setq prev-id curr-id)))))))))
             parent-groups)

    ;; 2.5 Calculate Critical Path and Float if enabled
    (when org-auto-scheduler-critical-path-enabled
      (unless (hash-table-p org-auto-scheduler--critical-tasks)
        (setq org-auto-scheduler--critical-tasks (make-hash-table :test 'equal)))
      (clrhash org-auto-scheduler--critical-tasks)
      (let ((floats (org-auto-scheduler--compute-critical-path-floats id-to-info adj-list preds-map pool-ids)))
        (dolist (task tasks-with-info)
          (let* ((task-id (nth 5 task))
                 (fl (gethash task-id floats)))
            (when (and fl (<= fl org-auto-scheduler-critical-path-max-float-hours))
              (puthash task-id t org-auto-scheduler--critical-tasks)
              (let* ((old-score (nth 1 task))
                     (new-score (+ old-score org-auto-scheduler-critical-path-boost))
                     (project-id (nth 2 task)))
                (setcar (nthcdr 1 task) new-score)
                (when project-id
                  (let ((current-max (gethash project-id project-max-scores -999999.0)))
                    (when (> new-score current-max)
                      (puthash project-id new-score project-max-scores))))
                (org-auto-scheduler--log-debug
                 "Critical path task boosted: ID %s, Name: %s (Float: %.1fh, +%.1f -> %.2f)"
                 task-id (nth 6 task) fl org-auto-scheduler-critical-path-boost new-score)))))))

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

      (setq org-auto-scheduler--last-scheduled-project-id nil)
      (while queue
        ;; Prioritize the queue
        (setq queue (sort queue (lambda (a b) (org-auto-scheduler--complex-sort-predicate a b project-max-scores))))

        ;; Pop the MOST critical unblocked task
        (let* ((current-info (pop queue))
               (current-id (nth 5 current-info))
               (current-proj (nth 2 current-info))
               (current-depth (gethash current-id depths 0)))

          ;; Update active project for project batching
          (when current-proj
            (setq org-auto-scheduler--last-scheduled-project-id current-proj))

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
         (day-end (org-auto-scheduler-time-with-time-string start-time org-auto-scheduler-end-time))
         (is-freeset (or (bound-and-true-p org-auto-scheduler--scheduling-freeset-p)
                         (bound-and-true-p org-auto-scheduler--scheduling-pinnable-p)
                         (member org-auto-scheduler-freeset-tag proposed-tags)
                         (member "PINNABLE" proposed-tags)
                         (and (bound-and-true-p org-auto-scheduler--reordering-p)
                              (or (member org-auto-scheduler-freeset-tag proposed-tags)
                                  (member "PINNABLE" proposed-tags)))))
         (is-pinned (or (member org-auto-scheduler-pinned-tag proposed-tags)
                        (and ignore-id (org-auto-scheduler-task-pinned-p nil ignore-id)))))
    (org-auto-scheduler--log-debug "Checking time slot %s to %s"
                                   (format-time-string "%Y-%m-%d %H:%M" start-time)
                                   (format-time-string "%Y-%m-%d %H:%M" end-time))
    (or
     ;; Check day boundaries (bypassed for FREESET during review reordering or PINNED tasks)
     (unless (or is-freeset is-pinned)
       (or (and (time-less-p start-time day-start) day-start)
           (and (time-less-p day-end end-time) day-end)))
     ;; Check conflicts with existing tasks and daily catch-up block.
     ;; We scan ALL conflicting items and return the MAXIMUM end-with-gap so that
     ;; next-available-time jumps past every overlapping item in one step.
     (let ((max-conflict-end nil))
       ;; Check daily catch-up / slack window
       (when (and org-auto-scheduler-daily-catchup-block
                  (not is-freeset)
                  (not is-pinned))
         (let* ((c-start-str (car org-auto-scheduler-daily-catchup-block))
                (c-end-str (if (consp (cdr org-auto-scheduler-daily-catchup-block))
                               (cadr org-auto-scheduler-daily-catchup-block)
                             (cdr org-auto-scheduler-daily-catchup-block)))
                (c-start (org-auto-scheduler-time-with-time-string start-time c-start-str))
                (c-end (org-auto-scheduler-time-with-time-string start-time c-end-str)))
           (when (and c-start c-end
                      (time-less-p start-time c-end)
                      (time-less-p c-start end-time))
             (org-auto-scheduler--log-debug "    Conflict detected with daily catch-up block: %s - %s"
                                            c-start-str c-end-str)
             (setq max-conflict-end c-end))))
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
                                     (org-auto-scheduler-task-non-blocking-p task-id marker task-name)))
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


(defun org-auto-scheduler--set-todo-state (state)
  "Set TODO state to STATE on current heading, safely handling custom states."
  (unless (member state org-todo-keywords-1)
    (let* ((head (or (car org-todo-keywords-1) "TODO"))
           (done (or (car org-done-keywords) state))
           (tail (list 'sequence head done state)))
      (setq-local org-todo-keywords-1 (append org-todo-keywords-1 (list state)))
      (setq-local org-done-keywords (append org-done-keywords (list state)))
      (push (cons state tail) org-todo-kwd-alist)
      (setq-local org-todo-regexp
                  (concat "\\(" (mapconcat #'regexp-quote org-todo-keywords-1 "\\|") "\\)"))
      (setq-local org-todo-line-regexp
                  (concat "^\\(\\*+\\)[ 	]+"
                          "\\(?:" org-todo-regexp "[ 	]+\\)?\\(?:\\(\\[#.\\]\\)[ 	]+\\)?\\(.*?\\)"
                          "\\(?:[ 	]+\\(:[[:alnum:]_@#%:]+:\\)\\)?[ 	]*$"))))
  (condition-case nil
      (org-todo state)
    (error
     (org-todo (or (car org-done-keywords) "DONE")))))

(defun org-auto-scheduler--parse-wait-duration (dur-str &optional base-time)
  "Calculate target date string (YYYY-MM-DD) by adding DUR-STR (e.g. '3d', '1w') to BASE-TIME."
  (let ((base (or base-time (current-time))))
    (if (and dur-str (string-match "\\([0-9]+\\)\\([dwmy]\\)" dur-str))
        (let ((num (string-to-number (match-string 1 dur-str)))
              (unit (match-string 2 dur-str)))
          (format-time-string "%Y-%m-%d"
            (cond
             ((string= unit "d") (time-add base (days-to-time num)))
             ((string= unit "w") (time-add base (days-to-time (* num 7))))
             ((string= unit "m") (if (fboundp 'org-auto-scheduler-add-months)
                                     (org-auto-scheduler-add-months base num)
                                   (time-add base (days-to-time (* num 30)))))
             ((string= unit "y") (if (fboundp 'org-auto-scheduler-add-months)
                                     (org-auto-scheduler-add-months base (* num 12))
                                   (time-add base (days-to-time (* num 365)))))
             (t base))))
      (format-time-string "%Y-%m-%d" base))))

(defun org-auto-scheduler--process-title-markers (marker)
  "Process title markers (e.g. -r-, -s-, -f-, -p-, -\\s-, -\\f-, -\\p-, -rsf-, -r-all-,
-x-, -done-, -kill-, -drop-, -c-, -e30m-, -e1h-, -+1d-, -defer-, -#A-, -#B-, -#C-,
-pri-a-, -!a-, -i-, -indep-, -\\i-, -\\indep-) at MARKER.
Strips markers from the headline, sets or deletes SPLITTABLE/FREESET/PINNED/INDEPENDENT properties
and tags, updates priority and TODO state and Effort, and returns a plist:
(:reschedule BOOL :reschedule-all BOOL :splittable BOOL :freeset BOOL :pinned BOOL
 :remove-splittable BOOL :remove-freeset BOOL :remove-pinned BOOL
 :done BOOL :kill BOOL :defer BOOL :effort INT :priority STR :remove-priority BOOL
 :independent BOOL :remove-independent BOOL :title STR)"
  (when (and marker (markerp marker) (marker-buffer marker))
    (org-with-point-at marker
      (let* ((heading (org-get-heading t t t t))
             (regex org-auto-scheduler-title-marker-regex))
        (when (and heading (string-match regex heading))
          (let* ((pos 0)
                 (all-grps '()))
            (while (string-match regex heading pos)
              (push (downcase (match-string 1 heading)) all-grps)
              (setq pos (match-end 0)))
            (let* ((match-grp (mapconcat #'identity (nreverse all-grps) " "))
                   (task-id (or (org-id-get) (when (buffer-file-name) (org-id-get-create))))
                   (is-r-all (string-match-p "r-all" match-grp))
                   (is-defer (and (not (string-match-p "\\(?:w\\|wait\\)\\+" match-grp))
                                  (or (string-match-p "\\+[0-9]+d" match-grp)
                                      (string-match-p "defer" match-grp))))
                   (wait-dur-str (when (string-match "\\(?:w\\|wait\\)\\+\\([0-9]+[dwmy]\\)" match-grp)
                                   (match-string 1 match-grp)))
                   (effort-str (when (string-match "e\\([0-9]+[hm0-9:]*\\)" match-grp)
                                 (match-string 1 match-grp)))
                   (effort-minutes (and effort-str (org-auto-scheduler--parse-effort-string effort-str)))
                   (priority-char
                    (or (when (string-match "#\\([a-zA-Z]\\)" match-grp)
                          (upcase (string-to-char (match-string 1 match-grp))))
                        (when (string-match "pri-?\\([a-zA-Z]\\)" match-grp)
                          (upcase (string-to-char (match-string 1 match-grp))))
                        (when (string-match "!\\([a-zA-Z]\\)" match-grp)
                          (upcase (string-to-char (match-string 1 match-grp))))))
                   (is-pri-off (or (string-match-p "\\\\#" match-grp)
                                   (string-match-p "pri-none" match-grp)
                                   (string-match-p "\\\\!" match-grp)))
                   (regex-strip "\\(?:r-all\\|done\\|kill\\|drop\\|defer\\|pri-none\\|\\+[0-9]+d\\|w\\+[0-9]+[dwmy]\\|wait\\+[0-9]+[dwmy]\\|wait\\|e[0-9]+[hm0-9:]*\\|#[a-zA-Z]\\|pri-?[a-zA-Z]\\|![a-zA-Z]\\|\\\\indep\\|indep\\)")
                   (clean-match (replace-regexp-in-string regex-strip "" match-grp))
                   (is-wait (or (string-match-p "wait" match-grp)
                                (not (null wait-dur-str))
                                (string-match-p "\\(?:^\\|[^a-z]\\)w\\(?:$\\|[^a-z]\\)" clean-match)
                                (string-match-p "\\(?:^\\| \\)w\\(?: \\|$\\)" match-grp)))
                   (is-kill (or (string-match-p "kill" match-grp) (string-match-p "drop" match-grp)
                                (string-match-p "c" clean-match)))
                   (is-done (or (string-match-p "done" match-grp)
                                (string-match-p "x" clean-match)))
                   (is-split-on (string-match-p "\\(?:^\\|[^\\\\]\\)s" clean-match))
                   (is-split-off (string-match-p "\\\\s" clean-match))
                   (is-free-on (string-match-p "\\(?:^\\|[^\\\\]\\)f" clean-match))
                   (is-free-off (string-match-p "\\\\f" clean-match))
                   (is-pin-on (string-match-p "\\(?:^\\|[^\\\\]\\)p" clean-match))
                   (is-pin-off (string-match-p "\\\\p" clean-match))
                   (is-indep-off (or (string-match-p "\\\\indep" match-grp)
                                     (string-match-p "\\\\i" match-grp)))
                   (is-indep-on (and (not is-indep-off)
                                     (or (string-match-p "\\(?:^\\|[^\\\\]\\)indep" match-grp)
                                         (string-match-p "\\(?:^\\|[^\\\\]\\)i" clean-match))))
                   (is-resched (or is-r-all
                                   (and (string-match-p "r" clean-match) t)
                                   (and priority-char t)
                                   is-pri-off
                                   is-indep-on
                                   is-indep-off
                                   (and effort-minutes t)
                                   is-defer
                                   is-wait))
                   (cleaned-title (string-trim (replace-regexp-in-string
                                                "[ \t]+" " "
                                                (replace-regexp-in-string regex "" heading)))))
              ;; Update headline in buffer
              (org-edit-headline cleaned-title)

              ;; Update priority if specified
              (cond
               (priority-char
                (condition-case nil
                    (org-priority priority-char)
                  (error (org-entry-put nil "PRIORITY" (char-to-string priority-char)))))
               (is-pri-off
                (condition-case nil
                    (org-priority 'remove)
                  (error (org-delete-property "PRIORITY")))))

              ;; Update TODO state if marked done or kill
              (cond
               (is-done
                (org-auto-scheduler--set-todo-state "DONE")
                (org-schedule '(4))
                (org-delete-property org-auto-scheduler-scheduled-property))
               (is-kill
                (org-auto-scheduler--set-todo-state org-auto-scheduler-kill-todo-state)
                (org-schedule '(4))
                (org-delete-property org-auto-scheduler-scheduled-property))
               (is-wait
                (let ((w-state (or (car org-auto-scheduler-waiting-states) "WAITING")))
                  (org-auto-scheduler--set-todo-state w-state)
                  (if wait-dur-str
                      (let ((target-day (org-auto-scheduler--parse-wait-duration wait-dur-str)))
                        (org-schedule nil target-day))
                    (pcase org-auto-scheduler-waiting-clear-scheduled-time
                      ('clear-time
                       (let ((cur-sched (org-entry-get nil "SCHEDULED")))
                         (when (and cur-sched (string-match "\\([0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\}\\)" cur-sched))
                           (org-schedule nil (match-string 1 cur-sched)))))
                      ('clear-all
                       (org-schedule '(4)))
                      (_ nil)))
                  (org-delete-property org-auto-scheduler-scheduled-property))))

              ;; Update Effort property if specified
              (when effort-minutes
                (org-entry-put nil "Effort" (org-auto-scheduler-minutes-to-time effort-minutes)))

              ;; Update deferral to tomorrow if requested
              (when is-defer
                (org-schedule '(4))
                (org-delete-property org-auto-scheduler-scheduled-property)
                (let* ((tomorrow-str (org-auto-scheduler--next-day-date-string (format-time-string "%Y-%m-%d")))
                       (not-before-time (concat tomorrow-str " " org-auto-scheduler-start-time)))
                  (org-entry-put nil "NOT_BEFORE" (format "<%s>" not-before-time))))

              ;; Update independent property & tag: -i- enables, -\\i- removes
              (cond
               (is-indep-off
                (org-delete-property org-auto-scheduler-independent-property)
                (org-delete-property org-auto-scheduler-parallel-property)
                (let ((tags (delete "INDEPENDENT" (delete "PARALLEL" (org-get-tags nil t)))))
                  (if (fboundp 'org-set-tags-to) (org-set-tags-to tags) (org-set-tags tags))))
               (is-indep-on
                (org-set-property org-auto-scheduler-independent-property "t")
                (let ((tags (org-get-tags nil t)))
                  (cl-pushnew "INDEPENDENT" tags :test #'string=)
                  (if (fboundp 'org-set-tags-to) (org-set-tags-to tags) (org-set-tags tags)))))

              ;; Update splittable property & tag: -s- enables, -\\s- removes
              (cond
               (is-split-off
                (org-delete-property org-auto-scheduler-split-property)
                (let ((tags (delete org-auto-scheduler-splittable-tag (org-get-tags nil t))))
                  (if (fboundp 'org-set-tags-to) (org-set-tags-to tags) (org-set-tags tags))))
               (is-split-on
                (org-set-property org-auto-scheduler-split-property "t")
                (let ((tags (org-get-tags nil t)))
                  (cl-pushnew org-auto-scheduler-splittable-tag tags :test #'string=)
                  (if (fboundp 'org-set-tags-to) (org-set-tags-to tags) (org-set-tags tags)))))

              ;; Update freeset property & tag: -f- enables, -\\f- removes
              (cond
               (is-free-off
                (org-delete-property org-auto-scheduler-freeset-property)
                (org-delete-property "PINNABLE")
                (let ((tags (delete org-auto-scheduler-freeset-tag
                                    (delete "PINNABLE" (org-get-tags nil t)))))
                  (if (fboundp 'org-set-tags-to) (org-set-tags-to tags) (org-set-tags tags))))
               (is-free-on
                (org-set-property org-auto-scheduler-freeset-property "t")
                (let ((tags (org-get-tags nil t)))
                  (cl-pushnew org-auto-scheduler-freeset-tag tags :test #'string=)
                  (if (fboundp 'org-set-tags-to) (org-set-tags-to tags) (org-set-tags tags)))))

              ;; Update pinned property & tag: -p- pins to incoming time, -\\p- unpins
              (cond
               (is-pin-off
                (org-auto-scheduler-task-set-pinned-time marker task-id nil t))
               (is-pin-on
                (let* ((incoming-time (or (org-entry-get nil "SCHEDULED")
                                          (org-entry-get nil "TIMESTAMP")
                                          (org-entry-get nil org-auto-scheduler-pinned-time-property))))
                  (if incoming-time
                      (org-auto-scheduler-task-set-pinned-time marker task-id incoming-time)
                    (org-set-property org-auto-scheduler-pinned-property "t")
                    (let ((tags (org-get-tags nil t)))
                      (cl-pushnew org-auto-scheduler-pinned-tag tags :test #'string=)
                      (if (fboundp 'org-set-tags-to) (org-set-tags-to tags) (org-set-tags tags)))))))

              (org-auto-scheduler--log-info
               "Processed title marker '%s' on task '%s' -> flags: resched=%s, split-on=%s, split-off=%s, free-on=%s, free-off=%s, pin-on=%s, pin-off=%s, done=%s, kill=%s, defer=%s, effort=%s, pri=%s, pri-off=%s, indep-on=%s, indep-off=%s"
               match-grp cleaned-title is-resched is-split-on is-split-off is-free-on is-free-off is-pin-on is-pin-off is-done is-kill is-defer effort-minutes (and priority-char (char-to-string priority-char)) is-pri-off is-indep-on is-indep-off)

              (list :reschedule (and is-resched t)
                    :reschedule-all (and is-r-all t)
                    :waiting (and is-wait t)
                    :splittable (and is-split-on t)
                    :freeset (and is-free-on t)
                    :pinned (and is-pin-on t)
                    :remove-splittable (and is-split-off t)
                    :remove-freeset (and is-free-off t)
                    :remove-pinned (and is-pin-off t)
                    :done (and is-done t)
                    :kill (and is-kill t)
                    :defer (and is-defer t)
                    :effort effort-minutes
                    :priority (and priority-char (char-to-string priority-char))
                    :remove-priority (and is-pri-off t)
                    :independent (and is-indep-on t)
                    :remove-independent (and is-indep-off t)
                    :title cleaned-title))))))))

(defun org-auto-scheduler--task-scheduled-time (marker &optional min-date-str)
  "Return a cons (START-TIME . END-TIME) if task at MARKER is scheduled or pinned with a specific time.
When MIN-DATE-STR (YYYY-MM-DD) is provided, only matches tasks on or after MIN-DATE-STR.
Returns nil if not scheduled/pinned, scheduled in the past before MIN-DATE-STR,
or scheduled date-only without a time."
  (when (and marker (markerp marker) (marker-buffer marker))
    (org-with-point-at marker
      (let* ((target-min (or min-date-str (format-time-string "%Y-%m-%d")))
             (sched-str (org-entry-get nil "SCHEDULED"))
             (pinned-time-str (org-entry-get nil org-auto-scheduler-pinned-time-property)))
        (or
         ;; Case A: Task pinned via PINNED_TIME property
         (when (and pinned-time-str
                    (string-match-p "[0-9]\\{2\\}:[0-9]\\{2\\}" pinned-time-str))
           (let* ((pt (org-auto-scheduler--parse-flexible-time pinned-time-str marker))
                  (pt-day (and pt (format-time-string "%Y-%m-%d" pt))))
             (when (and pt-day (not (string< pt-day target-min)))
               (let ((end-time (org-auto-scheduler-calculate-task-end-time (point))))
                 (cons pt (or end-time (time-add pt (seconds-to-time 3600))))))))
         ;; Case B: Task scheduled with HH:MM
         (when (and sched-str
                    ;; Must contain HH:MM
                    (string-match-p "[0-9]\\{2\\}:[0-9]\\{2\\}" sched-str))
           (let* ((start-time (org-time-string-to-time sched-str))
                  (start-day (and start-time (format-time-string "%Y-%m-%d" start-time))))
             (when (and start-day (not (string< start-day target-min)))
               (let ((end-time (org-auto-scheduler-calculate-task-end-time (point))))
                 (cons start-time (or end-time (time-add start-time (seconds-to-time 3600)))))))))))))

(defun org-auto-scheduler--task-scheduled-today-p (marker &optional today-str)
  "Return a cons (START-TIME . END-TIME) if task at MARKER is scheduled or pinned for TODAY-STR with a specific time.
TODAY-STR defaults to today's date in YYYY-MM-DD format.
Returns nil if not scheduled/pinned, scheduled on another day, or scheduled date-only without a time."
  (when (and marker (markerp marker) (marker-buffer marker))
    (org-with-point-at marker
      (let* ((target-today (or today-str (format-time-string "%Y-%m-%d")))
             (sched-str (org-entry-get nil "SCHEDULED"))
             (pinned-time-str (org-entry-get nil org-auto-scheduler-pinned-time-property)))
        (or
         ;; Case A: Task pinned to today via PINNED_TIME property
         (when (and pinned-time-str
                    (string-match-p "[0-9]\\{2\\}:[0-9]\\{2\\}" pinned-time-str))
           (let* ((pt (org-auto-scheduler--parse-flexible-time pinned-time-str marker))
                  (pt-day (and pt (format-time-string "%Y-%m-%d" pt))))
             (when (and pt-day (string= pt-day target-today))
               (let ((end-time (org-auto-scheduler-calculate-task-end-time (point))))
                 (cons pt (or end-time (time-add pt (seconds-to-time 3600))))))))
         ;; Case B: Task scheduled for today with HH:MM
         (when (and sched-str
                    ;; Must contain HH:MM
                    (string-match-p "[0-9]\\{2\\}:[0-9]\\{2\\}" sched-str))
           (let* ((start-time (org-time-string-to-time sched-str))
                  (start-day (and start-time (format-time-string "%Y-%m-%d" start-time))))
             (when (and start-day (string= start-day target-today))
               (let ((end-time (org-auto-scheduler-calculate-task-end-time (point))))
                 (cons start-time (or end-time (time-add start-time (seconds-to-time 3600)))))))))))))

;; Note: `org-auto-scheduler--task-clocked-p' is defined earlier near `org-auto-scheduler-get-clocked-time'.

(defun org-auto-scheduler--task-unscheduled-p (task-info)
  "Return non-nil if TASK-INFO represents an unscheduled task eligible for today.
A task is unscheduled if it has no SCHEDULED property, or its SCHEDULED property
is for today or in the past without a specific time (HH:MM)."
  (let ((sched (nth 8 task-info))
        (today-str (format-time-string "%Y-%m-%d")))
    (cond
     ;; No SCHEDULED property at all -> unscheduled!
     ((or (null sched) (string-empty-p (string-trim sched)))
      t)
     ;; Has HH:MM time -> already scheduled with a specific time!
     ((string-match-p "[0-9]\\{2\\}:[0-9]\\{2\\}" sched)
      nil)
     ;; Date-only: check if date is today or in the past (overdue date-only)
     (t
      (let ((date (and (string-match "\\([0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\}\\)" sched)
                       (match-string 1 sched))))
        (or (null date)
            (not (string> date today-str))))))))

(defun org-auto-scheduler-get-start-time ()
  "Get the starting time for scheduling tasks.
If current time is after org-auto-scheduler-end-time, return the start time of the next day.
When clocked into a task, returns current time immediately (0 buffer).
Otherwise, adds `org-auto-scheduler-start-buffer-minutes' (default 5m) buffer."
  (let* ((now (current-time))
         (decoded-time (decode-time now))
         (current-hour (nth 2 decoded-time))
         (current-minute (nth 1 decoded-time))
         (start-time-components (mapcar #'string-to-number
                                        (split-string org-auto-scheduler-start-time ":")))
         (end-time-components (mapcar #'string-to-number
                                      (split-string org-auto-scheduler-end-time ":")))
         (start-hour (car start-time-components))
         (start-minute (cadr start-time-components))
         (end-hour (car end-time-components))
         (end-minute (cadr end-time-components))
         (is-clocked (or (and (fboundp 'org-clocking-p) (org-clocking-p))
                         (and (boundp 'org-clock-current-task) org-clock-current-task)))
         (buffer-seconds (if is-clocked 0 (* org-auto-scheduler-start-buffer-minutes 60))))
    (cond
     ;; If before configured work start time today, start at start-time today
     ((or (< current-hour start-hour)
          (and (= current-hour start-hour) (< current-minute start-minute)))
      (apply #'encode-time
             (append (list 0 start-minute start-hour)
                     (nthcdr 3 decoded-time))))
     ;; If after configured work end time today, start at start-time tomorrow
     ((or (> current-hour end-hour)
          (and (= current-hour end-hour) (>= current-minute end-minute)))
      (let* ((tomorrow (time-add now (seconds-to-time (* 24 3600))))
             (tomorrow-start (apply #'encode-time
                                    (append (list 0 start-minute start-hour)
                                            (nthcdr 3 (decode-time tomorrow))))))
        tomorrow-start))
     ;; Otherwise during workday: start at current time + buffer (0 if clocked, 5m if not)
     (t
      (time-add now (seconds-to-time buffer-seconds))))))

(defun org-auto-scheduler-schedule-tasks (&optional force-replan)
  "Schedule all schedulable tasks, grouping them by project.
When FORCE-REPLAN is non-nil (or with prefix arg `C-u`), re-plan all tasks from
scratch, ignoring `org-auto-scheduler-preserve-today-scheduled'."
  (interactive "P")
  (when (and org-auto-scheduler--background-running
             org-auto-scheduler--background-thread
             (threadp org-auto-scheduler--background-thread)
             (thread-live-p org-auto-scheduler--background-thread)
             (fboundp 'current-thread)
             (not (eq (current-thread) org-auto-scheduler--background-thread)))
    (org-auto-scheduler--log-info "Waiting for background scheduler thread to complete...")
    (thread-join org-auto-scheduler--background-thread))
  (org-auto-scheduler--with-active-operation (or org-auto-scheduler--current-run-type 'scheduling)
    (org-auto-scheduler--log-info "Starting auto-scheduling process")
  (let ((cleaned-placeholders (org-auto-scheduler-cleanup-placeholders force-replan)))
    (setq org-auto-scheduler--session-cleaned-placeholders (or cleaned-placeholders 0))
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
          (setq org-auto-scheduler--pomodoro-continuous-minutes 0)
          (org-auto-scheduler--build-agenda-cache)       ; Build agenda items cache upfront
          (unless org-auto-scheduler--preview-mode
            (org-auto-scheduler-create-report-buffer))      ; Create the report buffer
          (let* ((raw-tasks (org-auto-scheduler-get-schedulable-tasks))
                 (marker-data (make-hash-table :test 'equal))
                 (has-r-all nil)
                 (tasks
                  (let ((sched-tasks '()))
                    (dolist (m raw-tasks)
                      (let* ((task-id (org-with-point-at m
                                        (or (org-id-get)
                                            (when (buffer-file-name) (org-id-get-create))))))
                        (when task-id
                          (let ((m-res (org-auto-scheduler--process-title-markers m)))
                            (when m-res
                              (puthash task-id m-res marker-data)
                              (when (plist-get m-res :reschedule-all)
                                (setq has-r-all t)))
                            (unless (and m-res (or (plist-get m-res :done) (plist-get m-res :kill) (plist-get m-res :waiting)))
                              (push m sched-tasks))))))
                    (nreverse sched-tasks)))
                 (_ (org-auto-scheduler--merge-saved-decisions tasks))
                 (sorted-tasks-info (org-auto-scheduler-sort-tasks tasks))
                 (initial-snapshot (org-auto-scheduler--capture-tasks-snapshot sorted-tasks-info))
                 (current-time (org-auto-scheduler-get-start-time))
                 (tasks-scheduled 0)
                 (total-tasks (length sorted-tasks-info))
                 (now (current-time))
                 (today-str (format-time-string "%Y-%m-%d" now))
                 (preserve-today (and org-auto-scheduler-preserve-today-scheduled
                                      (not force-replan)))
                 (today-scheduled '()) ; list of entries for today
                 (tasks-to-schedule '())) ; tasks that need scheduling slots

            ;; Also capture any done/killed tasks into initial-snapshot so change logging can track them
            (maphash
             (lambda (tid m-res)
               (when (or (plist-get m-res :done) (plist-get m-res :kill) (plist-get m-res :waiting))
                 (unless (gethash tid initial-snapshot)
                   (puthash tid
                            (list :task-id tid
                                  :marker nil
                                  :file nil
                                  :headline (plist-get m-res :title)
                                  :scheduled nil
                                  :tags nil
                                  :pinned nil
                                  :pinned-time nil)
                            initial-snapshot))))
             marker-data)

            ;; 1. Process title markers and classify tasks
            (dolist (task-info sorted-tasks-info)
              (let* ((task-id (nth 5 task-info))
                     (raw-marker (car task-info))
                     (marker (org-auto-scheduler--resolve-task-marker raw-marker task-id))
                     (m-res (or (gethash task-id marker-data)
                                (org-auto-scheduler--process-title-markers marker))))
                (when m-res
                  (puthash task-id m-res marker-data)
                  (when (plist-get m-res :reschedule-all)
                    (setq has-r-all t))
                  (when (plist-get m-res :title)
                    (setf (nth 6 task-info) (plist-get m-res :title)))
                  (when (plist-get m-res :remove-splittable)
                    (setf (nth 7 task-info) (delete org-auto-scheduler-splittable-tag (nth 7 task-info))))
                  (when (plist-get m-res :remove-freeset)
                    (setf (nth 7 task-info) (delete org-auto-scheduler-freeset-tag
                                                   (delete "PINNABLE" (nth 7 task-info)))))
                  (when (plist-get m-res :splittable)
                    (setf (nth 7 task-info) (cl-pushnew org-auto-scheduler-splittable-tag (nth 7 task-info) :test #'string=)))
                  (when (plist-get m-res :freeset)
                    (setf (nth 7 task-info) (cl-pushnew org-auto-scheduler-freeset-tag (nth 7 task-info) :test #'string=)))
                  (when (plist-get m-res :remove-pinned)
                    (setf (nth 7 task-info) (delete org-auto-scheduler-pinned-tag (nth 7 task-info))))
                  (when (plist-get m-res :pinned)
                    (setf (nth 7 task-info) (cl-pushnew org-auto-scheduler-pinned-tag (nth 7 task-info) :test #'string=))))
                ;; Check if scheduled for today or future with a time
                (cond
                 ((or (plist-get m-res :done) (plist-get m-res :kill) (plist-get m-res :waiting))
                  ;; Task was marked DONE or DROPPED via title marker; skip scheduling it
                  nil)
                 (t
                  (when (plist-get m-res :effort)
                    (setf (nth 12 task-info) (plist-get m-res :effort)))
                  (when (plist-get m-res :defer)
                    (let* ((tomorrow-str (org-auto-scheduler--next-day-date-string (format-time-string "%Y-%m-%d")))
                           (not-before-time (concat tomorrow-str " " org-auto-scheduler-start-time)))
                      (setf (nth 10 task-info) (org-auto-scheduler-parse-time-string not-before-time))))
                  (let ((sched-times (when preserve-today
                                       (if org-auto-scheduler-preserve-future-scheduled
                                           (org-auto-scheduler--task-scheduled-time marker today-str)
                                         (org-auto-scheduler--task-scheduled-today-p marker today-str)))))
                    (if sched-times
                        (let* ((start-t (car sched-times))
                               (end-t (cdr sched-times))
                               (is-pin (org-auto-scheduler-task-pinned-p marker task-id))
                               (is-clocked (org-auto-scheduler--task-clocked-p marker))
                               (is-resched (or (and m-res (plist-get m-res :reschedule)) nil))
                               (is-overdue (time-less-p start-t now))
                               (is-lapsed-or-current (or is-clocked is-overdue))
                               (is-today (string= (format-time-string "%Y-%m-%d" start-t) today-str)))
                          (push (list :task-info task-info
                                      :marker marker
                                      :task-id task-id
                                      :start-time start-t
                                      :end-time end-t
                                      :pinned is-pin
                                      :clocked is-clocked
                                      :reschedule is-resched
                                      :overdue is-overdue
                                      :lapsed-or-current is-lapsed-or-current
                                      :is-today is-today)
                                today-scheduled))
                      (push task-info tasks-to-schedule)))))))
            (setq tasks-to-schedule (nreverse tasks-to-schedule))

            ;; 2. Sort today's scheduled tasks chronologically by start-time
            (setq today-scheduled
                  (sort today-scheduled
                        (lambda (a b)
                          (time-less-p (plist-get a :start-time)
                                       (plist-get b :start-time)))))

            ;; 3. Determine trigger mode:
            ;;    - has-priority-or-indep-trigger: priority (-#A-) or independent (-i-) marker set on task
            ;;    - has-r-trigger: user added -r- or -r-all- (cascade from trigger point in previous order)
            ;;    - has-unscheduled: user added new unscheduled AUTOSCH tasks (displace upcoming unpinned tasks automatically)
            ;;    - neither: preserve all today-scheduled tasks
            (let* ((has-priority-or-indep-trigger
                    (cl-some (lambda (e)
                               (let ((m (gethash (plist-get e :task-id) marker-data)))
                                 (and m (or (plist-get m :priority)
                                            (plist-get m :remove-priority)
                                            (plist-get m :independent)
                                            (plist-get m :remove-independent)
                                            (plist-get m :effort)
                                            (plist-get m :defer)))))
                             today-scheduled))
                   (has-r-trigger
                    (and (not has-priority-or-indep-trigger)
                         (cond
                          (has-r-all
                           (or (cl-find-if (lambda (e) (plist-get e :lapsed-or-current)) today-scheduled)
                               (cl-find-if (lambda (e)
                                             (let ((m (gethash (plist-get e :task-id) marker-data)))
                                               (and m (plist-get m :reschedule-all))))
                                           today-scheduled)))
                          (t
                           (cl-find-if (lambda (e) (plist-get e :reschedule)) today-scheduled)))))
                   (has-unscheduled
                    (and preserve-today
                         (cl-some #'org-auto-scheduler--task-unscheduled-p tasks-to-schedule)))
                   (has-priority-reorder (or has-priority-or-indep-trigger has-unscheduled))
                   (preserved-entries '())
                   (final-schedule-list '()))

              (cond
               ;; -------------------------------------------------------------
               ;; CASE 1: -r- or -r-all- trigger present
               ;; Cascade rescheduling from trigger entry in previously scheduled order!
               ;; -------------------------------------------------------------
               (has-r-trigger
                (let ((cascade-entries '())
                      (found-trigger nil)
                      (unpinned-cascade '()))
                  (dolist (e today-scheduled)
                    (if found-trigger
                        (push e cascade-entries)
                      (if (equal (plist-get e :task-id) (plist-get has-r-trigger :task-id))
                          (progn
                            (setq found-trigger t)
                            (push e cascade-entries))
                        (push e preserved-entries))))
                  (setq preserved-entries (nreverse preserved-entries))
                  (setq cascade-entries (nreverse cascade-entries))

                  ;; Separate pinned tasks in cascade from unpinned cascade tasks
                  (dolist (e cascade-entries)
                    (if (plist-get e :pinned)
                        ;; Pinned task: schedule single task at its pinned time
                        (let* ((t-info (plist-get e :task-info))
                               (m (plist-get e :marker))
                               (tid (plist-get e :task-id))
                               (td (nth 14 t-info)))
                          (org-auto-scheduler-schedule-single-task m current-time td)
                          (unless org-auto-scheduler--preview-mode
                            (let ((scheduled-start (nth 1 (car org-auto-scheduler-completed-tasks))))
                              (org-auto-scheduler-add-to-report t-info scheduled-start)))
                          (setq tasks-scheduled (1+ tasks-scheduled)))
                      ;; Unpinned: keep in unpinned-cascade in previous scheduled order!
                      (push (plist-get e :task-info) unpinned-cascade)))
                  (setq unpinned-cascade (nreverse unpinned-cascade))
                  (setq final-schedule-list (append unpinned-cascade tasks-to-schedule))))

               ;; -------------------------------------------------------------
               ;; CASE 2: Priority/independence marker OR newly added unscheduled tasks!
               ;; Preserved: lapsed-or-current tasks and pinned tasks.
               ;; Upcoming unpinned tasks + unscheduled tasks are scheduled together
               ;; according to priority/score (sorted-tasks-info order).
               ;; -------------------------------------------------------------
               (has-priority-reorder
                (let ((reschedule-task-ids (make-hash-table :test 'equal)))
                  ;; Identify preserved tasks vs upcoming unpinned tasks
                  (dolist (e today-scheduled)
                    (if (or (plist-get e :lapsed-or-current)
                            (plist-get e :pinned)
                            (and org-auto-scheduler-preserve-future-scheduled
                                 (not (plist-get e :is-today))))
                        (push e preserved-entries)
                      ;; Upcoming unpinned task for today: mark as eligible for rescheduling
                      (puthash (plist-get e :task-id) t reschedule-task-ids)))
                  (setq preserved-entries (nreverse preserved-entries))

                  ;; Also mark all tasks in tasks-to-schedule as eligible
                  (dolist (ti tasks-to-schedule)
                    (puthash (nth 5 ti) t reschedule-task-ids))

                  ;; Build final-schedule-list from sorted-tasks-info to preserve priority/score order!
                  (dolist (ti sorted-tasks-info)
                    (when (gethash (nth 5 ti) reschedule-task-ids)
                      (push ti final-schedule-list)))
                  (setq final-schedule-list (nreverse final-schedule-list))))

               ;; -------------------------------------------------------------
               ;; CASE 3: Neither -r- trigger nor unscheduled tasks exist.
               ;; Preserve all today-scheduled tasks!
               ;; -------------------------------------------------------------
               (t
                (setq preserved-entries today-scheduled)
                (setq final-schedule-list tasks-to-schedule)))

            ;; 4. Register preserved tasks into completed-tasks so they occupy their slots
            (dolist (e preserved-entries)
              (let* ((t-info (plist-get e :task-info))
                     (tid (plist-get e :task-id))
                     (m (plist-get e :marker))
                     (st (plist-get e :start-time))
                     (et (plist-get e :end-time))
                     (hd (nth 6 t-info))
                     (tags (nth 7 t-info))
                     (td (nth 14 t-info))
                     (is-pin (plist-get e :pinned))
                     (sched-str (org-with-point-at m (org-entry-get nil "SCHEDULED"))))
                ;; Ensure pinned tasks have their SCHEDULED line properly synchronized to PINNED_TIME
                (when (and is-pin
                           (or (gethash tid marker-data)
                               (let ((pt (org-auto-scheduler-task-pinned-time m tid)))
                                 (and pt (not (string-prefix-p (format-time-string "%Y-%m-%d %H:%M" pt)
                                                               (or sched-str "")))))))
                  (org-auto-scheduler-schedule-single-task m current-time td)
                  (setq sched-str (org-with-point-at m (org-entry-get nil "SCHEDULED"))))
                (push (list tid st et (or tags '("AUTOSCH")) t hd sched-str m td)
                      org-auto-scheduler-completed-tasks)
                (unless org-auto-scheduler--preview-mode
                  (org-auto-scheduler-add-to-report t-info st))
                (setq tasks-scheduled (1+ tasks-scheduled))))

            ;; 5. Schedule tasks in final-schedule-list
            (let ((reporter (unless org-auto-scheduler-silent-mode
                              (make-progress-reporter "Scheduling tasks..." 0 total-tasks))))
              (dolist (task-info final-schedule-list)
                ;; Cooperative yield if running in a background worker thread
                (when (and (fboundp 'thread-yield)
                           (fboundp 'current-thread)
                           (fboundp 'main-thread)
                           (not (eq (current-thread) (main-thread))))
                  (thread-yield))
                (let* ((task-id (nth 5 task-info))
                       (raw-marker (car task-info))
                       (marker (org-auto-scheduler--resolve-task-marker raw-marker task-id)))
                  (let ((prev-completed-count (length org-auto-scheduler-completed-tasks)))
                    (setq current-time (org-auto-scheduler-schedule-single-task marker current-time (nth 14 task-info)))
                    (when (nth 2 task-info)
                      (setq org-auto-scheduler--last-scheduled-project-id (nth 2 task-info)))
                    (unless org-auto-scheduler--preview-mode
                      (let ((scheduled-start
                             (when (> (length org-auto-scheduler-completed-tasks) prev-completed-count)
                               (nth 1 (car org-auto-scheduler-completed-tasks)))))
                        (org-auto-scheduler-add-to-report task-info scheduled-start))))
                  (setq tasks-scheduled (1+ tasks-scheduled))
                  (when reporter
                    (progress-reporter-update reporter tasks-scheduled))))
              (when reporter
                (progress-reporter-done reporter))))

          ;; Normalize completed-tasks to chronological order (built via push)
          (setq org-auto-scheduler-completed-tasks (nreverse org-auto-scheduler-completed-tasks))
          ;; Detect and record changes
          (setq org-auto-scheduler--last-run-changes
                (org-auto-scheduler--detect-task-changes initial-snapshot
                                                        org-auto-scheduler-completed-tasks
                                                        marker-data))
          (when (org-auto-scheduler--should-log-changes-p)
            (org-auto-scheduler--record-run-changes
             :run-type (or org-auto-scheduler--current-run-type 'manual)
             :start-time (or (bound-and-true-p org-auto-scheduler--run-start-time) now)
             :end-time (current-time)
             :tasks-evaluated total-tasks
             :changes org-auto-scheduler--last-run-changes
             :cleaned-placeholders (or org-auto-scheduler--session-cleaned-placeholders 0)))
          (unless org-auto-scheduler--preview-mode
            (org-auto-scheduler-display-report))
          (org-auto-scheduler--log-info "Scheduled %d tasks (changes: %d)"
                                        tasks-scheduled
                                        (length org-auto-scheduler--last-run-changes))
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
       (org-auto-scheduler--log-error "Error in scheduling process: %s" err))))))

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
              (is-waiting (and state (member state org-auto-scheduler-waiting-states)))
              (is-valid-state (and (member state valid-states) (not is-waiting)))
              (is-placeholder (or (member org-auto-scheduler-placeholder-tag tags)
                                  (org-entry-get nil "AUTOSCH_PLACEHOLDER")
                                  (org-entry-get nil "AUTOSCH_ORIGIN_ID")))
              (headline (org-get-heading t t t t))
              (not-before (org-entry-get nil "NOT_BEFORE"))
              (recurring (org-entry-get nil "RECURRING"))
              (scheduled (org-entry-get nil "SCHEDULED"))
              (file (buffer-file-name)))
         ;; Check if the task is not in an archived state and not a placeholder
         (when (and is-autosch is-valid-state (not (member "ARCHIVE" tags)) (not is-placeholder))
           (org-auto-scheduler--log-debug "Found schedulable task: %s (State: %s, NOT_BEFORE: %s, RECURRING: %s) in file %s"
                                          headline state (or not-before "Not set") (or recurring "Not set") file)
           (if recurring
               (progn
                 (org-auto-scheduler--log-debug "Creating instances for recurring task: %s in file %s" headline file)
                 (let ((new-instances (org-auto-scheduler-create-recurring-instances headline recurring scheduled not-before)))
                   (setq tasks (append new-instances tasks))))
             (org-auto-scheduler--log-debug "Adding non-recurring task: %s from file %s" headline file)
             (let ((m (point-marker)))
               (set-marker-insertion-type m t)
               (push m tasks))))))
     nil
     'agenda)
    (org-auto-scheduler--log-info "Found %d schedulable tasks across the agenda" (length tasks))
    (nreverse tasks)))

(defun org-auto-scheduler--get-waiting-since (marker &optional state)
  "Return a time value indicating when the task at MARKER entered STATE or WAITING.
Checks `org-auto-scheduler-waiting-since-property', then Org LOGBOOK drawer,
then active/inactive timestamps, falling back to nil."
  (org-with-point-at marker
    (let ((prop (org-entry-get nil org-auto-scheduler-waiting-since-property)))
      (if (and prop (not (string-empty-p prop)))
          (condition-case nil
              (org-time-string-to-time prop)
            (error nil))
        (save-excursion
          (let ((target-state (or state "WAITING"))
                (found-time nil))
            (org-back-to-heading t)
            (let ((end (save-excursion (outline-next-heading) (point))))
              (when (re-search-forward (concat "- State +\"" (regexp-quote target-state) "\"") end t)
                (when (re-search-forward "\\[\\([^]]+\\)\\]" (line-end-position) t)
                  (let ((time-str (match-string-no-properties 1)))
                    (condition-case nil
                        (setq found-time (org-time-string-to-time time-str))
                      (error nil))))))
            (or found-time
                (let ((sched (org-entry-get nil "SCHEDULED")))
                  (when sched
                    (condition-case nil
                        (org-time-string-to-time sched)
                      (error nil)))))))))))

(defun org-auto-scheduler-get-waiting-tasks ()
  "Get a list of waiting task info plists from agenda files.
Tasks are selected if their TODO state is in `org-auto-scheduler-waiting-states'
and (if `org-auto-scheduler-waiting-require-autosch-tag' is non-nil) they have
the AUTOSCH tag, excluding ARCHIVE and placeholder tasks."
  (let ((waiting-tasks '()))
    (org-map-entries
     (lambda ()
       (let* ((state (org-get-todo-state))
              (tags (org-get-tags))
              (is-autosch (member "AUTOSCH" tags))
              (is-waiting (and state (member state org-auto-scheduler-waiting-states)))
              (is-placeholder (or (member org-auto-scheduler-placeholder-tag tags)
                                  (org-entry-get nil "AUTOSCH_PLACEHOLDER")
                                  (org-entry-get nil "AUTOSCH_ORIGIN_ID"))))
         (when (and is-waiting
                    (or (not org-auto-scheduler-waiting-require-autosch-tag) is-autosch)
                    (not (member "ARCHIVE" tags))
                    (not is-placeholder))
           (let* ((marker (point-marker))
                  (task-id (or (org-id-get) (when (buffer-file-name) (org-id-get-create))))
                  (headline (org-get-heading t t t t))
                  (scheduled (org-entry-get nil "SCHEDULED"))
                  (deadline (org-entry-get nil "DEADLINE"))
                  (waiting-since (org-auto-scheduler--get-waiting-since marker state))
                  (days-waiting (when waiting-since
                                  (max 0 (floor (/ (float-time (time-subtract (current-time) waiting-since)) 86400)))))
                  (project-name (org-auto-scheduler--get-project-name marker)))
             (push (list :id task-id
                         :marker marker
                         :headline headline
                         :state state
                         :tags tags
                         :scheduled scheduled
                         :deadline deadline
                         :waiting-since waiting-since
                         :days-waiting days-waiting
                         :project-name project-name)
                   waiting-tasks)))))
     nil
     'agenda)
    (nreverse waiting-tasks)))

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
         (has-date (string-match "\\([0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\}\\)" clean))
         (date-part (when has-date (match-string 1 clean)))
         (has-time (string-match "\\([0-9]\\{1,2\\}:[0-9]\\{2\\}\\)" clean))
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
                              (when (and sched (string-match "\\([0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\}\\)" sched))
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

(defun org-auto-scheduler-task-freeset-p (marker &optional task-id)
  "Return non-nil if task at MARKER or TASK-ID is marked as FREESET (or legacy PINNABLE).
FREESET tasks can be scheduled or moved outside normal working hours,
and split at midnight to the next day."
  (let* ((tid (or task-id (when (and marker (markerp marker) (marker-buffer marker))
                            (org-with-point-at marker (org-id-get)))))
         (override (org-auto-scheduler--get-review-override tid))
         (override-freeset (and override (or (plist-get override :freeset)
                                             (plist-get override :pinnable))))
         (saved-dec (and tid (org-auto-scheduler-get-saved-decision tid marker)))
         (saved-freeset (and saved-dec (or (plist-get saved-dec :freeset)
                                           (plist-get saved-dec :pinnable)))))
    (cond
     (override-freeset t)
     ((and override (plist-member override :freeset) (null (plist-get override :freeset))) nil)
     ((and override (plist-member override :pinnable) (null (plist-get override :pinnable))) nil)
     (saved-freeset t)
     ((and marker (markerp marker) (marker-buffer marker))
      (org-with-point-at marker
        (let* ((tags (org-get-tags))
               (prop (or (org-entry-get nil org-auto-scheduler-freeset-property)
                         (org-entry-get nil "PINNABLE"))))
          (or (member org-auto-scheduler-freeset-tag tags)
              (member "PINNABLE" tags)
              (and prop (not (member (downcase prop) '("nil" "no" "0" ""))))))))
     (t nil))))

(defalias 'org-auto-scheduler-task-pinnable-p 'org-auto-scheduler-task-freeset-p)

(defun org-auto-scheduler-task-toggle-freeset (&optional marker task-id)
  "Toggle FREESET status of task at MARKER or TASK-ID.
Updates tag `org-auto-scheduler-freeset-tag' and property
`org-auto-scheduler-freeset-property'.  Also updates review overrides.
Returns non-nil if now freeset."
  (let* ((m (or marker
                (when (and task-id (stringp task-id))
                  (org-id-find task-id t))
                (and (derived-mode-p 'org-mode) (point-marker))))
         (tid (or task-id
                  (when (and m (markerp m) (marker-buffer m))
                    (org-with-point-at m (or (org-id-get) (when (buffer-file-name (marker-buffer m)) (org-id-get-create))))))))
    (unless (and m (markerp m) (marker-buffer m))
      (user-error "Cannot find task marker"))
    (let* ((currently-freeset (org-auto-scheduler-task-freeset-p m tid))
           (new-freeset (not currently-freeset)))
      (org-with-point-at m
        (let ((tags (org-get-tags nil t)))
          (if currently-freeset
              (progn
                (setq tags (delete org-auto-scheduler-freeset-tag tags))
                (setq tags (delete "PINNABLE" tags))
                (if (fboundp 'org-set-tags-to)
                    (org-set-tags-to tags)
                  (org-set-tags tags))
                (org-delete-property org-auto-scheduler-freeset-property)
                (org-delete-property "PINNABLE"))
            (progn
              (cl-pushnew org-auto-scheduler-freeset-tag tags :test #'string=)
              (if (fboundp 'org-set-tags-to)
                  (org-set-tags-to tags)
                (org-set-tags tags))
              (org-set-property org-auto-scheduler-freeset-property "t")))
          (when (and tid (bound-and-true-p org-auto-scheduler--review-overrides))
            (let ((over (or (gethash tid org-auto-scheduler--review-overrides)
                            (list :order nil :skipped nil :target-date nil))))
              (puthash tid (plist-put (plist-put over :freeset new-freeset)
                                      :pinnable new-freeset)
                       org-auto-scheduler--review-overrides)))
          new-freeset)))))

(defalias 'org-auto-scheduler-task-toggle-pinnable 'org-auto-scheduler-task-toggle-freeset)

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

(defun org-auto-scheduler-task-pinned-p (marker &optional task-id)
  "Return non-nil if task at MARKER or TASK-ID has an anchored pinned time."
  (let* ((tid (or task-id (when (and marker (markerp marker) (marker-buffer marker))
                            (org-with-point-at marker (org-id-get)))))
         (override (org-auto-scheduler--get-review-override tid))
         (override-pinned (and override (or (plist-get override :pinned)
                                            (plist-get override :pinned-time))))
         (saved-dec (and tid (org-auto-scheduler-get-saved-decision tid marker)))
         (saved-pinned (and saved-dec (or (plist-get saved-dec :pinned)
                                          (plist-get saved-dec :pinned-time)))))
    (cond
     (override-pinned t)
     ((and override (plist-member override :pinned) (null (plist-get override :pinned))) nil)
     (saved-pinned t)
     ((and marker (markerp marker) (marker-buffer marker))
      (org-with-point-at marker
        (let* ((tags (org-get-tags))
               (prop (org-entry-get nil org-auto-scheduler-pinned-property))
               (time-prop (org-entry-get nil org-auto-scheduler-pinned-time-property)))
          (or (member org-auto-scheduler-pinned-tag tags)
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
                            (let ((p (org-entry-get nil "PINNED")))
                              (and p (not (member (downcase p) '("t" "nil" "no" "1" ""))) p))))))
         (raw-time (or override-time saved-time prop-time)))
    (when raw-time
      (org-auto-scheduler--parse-flexible-time raw-time marker))))

(defun org-auto-scheduler-task-set-pinned-time (marker &optional task-id time-str unpin)
  "Anchor or unanchor task at MARKER or TASK-ID to a pinned time TIME-STR.
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
    (prog1
        (org-with-point-at m
          (let ((tags (org-get-tags nil t)))
            (if (or unpin (null time-str) (string-empty-p (string-trim time-str)))
                (progn
                  (setq tags (delete org-auto-scheduler-pinned-tag tags))
                  (if (fboundp 'org-set-tags-to)
                      (org-set-tags-to tags)
                    (org-set-tags tags))
                  (org-delete-property org-auto-scheduler-pinned-property)
                  (org-delete-property org-auto-scheduler-pinned-time-property)
                  (when (and tid (bound-and-true-p org-auto-scheduler--review-overrides))
                    (let ((over (gethash tid org-auto-scheduler--review-overrides)))
                      (when over
                        (setq over (plist-put over :pinned nil))
                        (setq over (plist-put over :pinned-time nil))
                        (puthash tid over org-auto-scheduler--review-overrides))))
                  nil)
              (let* ((parsed (org-auto-scheduler--parse-flexible-time time-str m))
                     (formatted-time (format-time-string "%Y-%m-%d %H:%M" parsed))
                     (date-str (format-time-string "%Y-%m-%d" parsed)))
                (cl-pushnew org-auto-scheduler-pinned-tag tags :test #'string=)
                (if (fboundp 'org-set-tags-to)
                    (org-set-tags-to tags)
                  (org-set-tags tags))
                (org-set-property org-auto-scheduler-pinned-property "t")
                (org-set-property org-auto-scheduler-pinned-time-property formatted-time)
                (when (and tid (bound-and-true-p org-auto-scheduler--review-overrides))
                  (let ((over (gethash tid org-auto-scheduler--review-overrides)))
                    (puthash tid (plist-put (plist-put (plist-put (plist-put over :pinned t)
                                                                  :pinned-time formatted-time)
                                                       :pinned-date date-str)
                                            :target-date date-str)
                             org-auto-scheduler--review-overrides)))
                formatted-time))))
      (setq org-auto-scheduler--pinned-cache nil))))

(defalias 'org-auto-scheduler-task-set-pinnable 'org-auto-scheduler-task-set-pinned-time)

(defun org-auto-scheduler--build-pinned-cache ()
  "Build the cache of pinned task reservations across all dates.
Populates `org-auto-scheduler--pinned-cache' with a hash table mapping
date strings (YYYY-MM-DD) and all-dates key to lists of reservation pseudo items."
  (let ((cache (make-hash-table :test 'equal))
        (all-items (org-auto-scheduler--compute-pinned-tasks-reservations nil)))
    (puthash "__all__" all-items cache)
    (dolist (item all-items)
      (let* ((pt (nth 1 item))
             (d-str (and pt (format-time-string "%Y-%m-%d" pt))))
        (when d-str
          (puthash d-str (cons item (gethash d-str cache)) cache))))
    (setq org-auto-scheduler--pinned-cache cache)))

(defun org-auto-scheduler--get-pinned-tasks-reservations (&optional target-date-str)
  "Return a list of pseudo agenda items for all tasks pinned to an exact time.
Each item is (TASK-ID START-TIME END-TIME TAGS t HEADLINE t MARKER).
If TARGET-DATE-STR is non-nil (YYYY-MM-DD), only returns items for that date.
Uses `org-auto-scheduler--pinned-cache' if available, otherwise computes fresh."
  (if (and (boundp 'org-auto-scheduler--pinned-cache)
           (hash-table-p org-auto-scheduler--pinned-cache))
      (gethash (or target-date-str "__all__") org-auto-scheduler--pinned-cache)
    (org-auto-scheduler--compute-pinned-tasks-reservations target-date-str)))

(defun org-auto-scheduler--compute-pinned-tasks-reservations (&optional target-date-str)
  "Compute a list of pseudo agenda items for all tasks pinned to an exact time.
Each item is (TASK-ID START-TIME END-TIME TAGS t HEADLINE t MARKER).
If TARGET-DATE-STR is non-nil (YYYY-MM-DD), only returns items for that date.
Checks:
1. Review overrides
2. Saved review decisions
3. Active Org tasks in agenda files or current buffer with property `org-auto-scheduler-pinned-time-property'."
  (let ((items '())
        (seen (make-hash-table :test 'equal)))
    ;; 1. Check review overrides
    (when (bound-and-true-p org-auto-scheduler--review-overrides)
      (maphash
       (lambda (tid over)
         (when (and (or (plist-get over :pinned) (plist-get over :pinned-time))
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
                 (push (list tid pt end '("AUTOSCH" "PINNED") t "Pinned Task" t nil) items))))))
       org-auto-scheduler--review-overrides))
    ;; 2. Check saved review decisions
    (when (bound-and-true-p org-auto-scheduler--saved-review-decisions)
      (dolist (pair org-auto-scheduler--saved-review-decisions)
        (let* ((tid (car pair))
               (dec (cdr pair)))
          (when (and (not (gethash tid seen))
                     (or (plist-get dec :pinned) (plist-get dec :pinned-time))
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
                  (push (list tid pt end '("AUTOSCH" "PINNED") t "Pinned Task" t nil) items))))))))
    ;; 3. Check live org agenda tasks and current buffer that have property :PINNED_TIME:
    (let ((buffers (delete-dups
                    (append (when (and (boundp 'org-agenda-files) (fboundp 'org-agenda-files))
                              (delq nil (mapcar (lambda (f) (when (file-exists-p f) (find-file-noselect f)))
                                                (org-agenda-files t))))
                            (when (derived-mode-p 'org-mode) (list (current-buffer)))))))
      (dolist (b buffers)
        (when (and b (buffer-live-p b))
          (with-current-buffer b
            (save-excursion
              (save-restriction
                (widen)
                (goto-char (point-min))
                (while (re-search-forward "^\*+[ 	]+" nil t)
                  (let* ((tid (or (org-entry-get nil "ID")
                                  (ignore-errors (org-id-get))
                                  (format "%s:%d" (or (buffer-file-name) (buffer-name)) (point))))
                         (time-str (or (org-entry-get nil org-auto-scheduler-pinned-time-property)
                                       (let ((p (org-entry-get nil "PINNED")))
                                         (and p (not (member (downcase p) '("t" "nil" "no" "1" ""))) p)))))
                    (when (and tid (not (gethash tid seen)) time-str (not (string-empty-p time-str)))
                      (let* ((m (point-marker))
                             (pt (org-auto-scheduler-task-pinned-time m tid))
                             (d-str (and pt (format-time-string "%Y-%m-%d" pt))))
                        (when (and pt (or (null target-date-str) (string= d-str target-date-str)))
                          (let* ((eff (or (org-auto-scheduler-get-effort m) 60))
                                 (midnight (org-auto-scheduler--get-day-midnight pt))
                                 (avail (floor (/ (float-time (time-subtract midnight pt)) 60)))
                                 (chunk (min eff (max 1 avail)))
                                 (end (time-add pt (seconds-to-time (* 60 chunk))))
                                 (hl (org-get-heading t t t t)))
                            (puthash tid t seen)
                            (push (list tid pt end '("AUTOSCH" "PINNED") t hl t m) items)))))))))))))
    items))


(defun org-auto-scheduler--find-child-placeholders (parent-marker origin-id)
  "Find existing placeholder child subtasks under PARENT-MARKER for ORIGIN-ID.
Returns a list of plists with :marker, :part-num, :org-id, :headline, :scheduled, :effort."
  (let ((placeholders '()))
    (when (and parent-marker (markerp parent-marker) (marker-buffer parent-marker))
      (org-with-point-at parent-marker
        (let ((parent-level (org-outline-level)))
          (save-excursion
            (org-back-to-heading t)
            (while (and (outline-next-heading)
                        (> (org-outline-level) parent-level))
              (let* ((tags (org-get-tags))
                     (is-ph-tag (member org-auto-scheduler-placeholder-tag tags))
                     (is-ph-prop (org-entry-get nil "AUTOSCH_PLACEHOLDER"))
                     (ph-origin (org-entry-get nil "AUTOSCH_ORIGIN_ID")))
                (when (and (or is-ph-tag is-ph-prop)
                           (or (null ph-origin) (equal ph-origin origin-id)))
                  (let* ((hd (org-get-heading t t t t))
                         (pn-prop (org-entry-get nil "AUTOSCH_PART_NUM"))
                         (part-num (or (and pn-prop (string-to-number pn-prop))
                                       (when (string-match "Part \\([0-9]+\\)" hd)
                                         (string-to-number (match-string 1 hd)))
                                       1))
                         (sched (org-entry-get nil "SCHEDULED"))
                         (effort (org-entry-get nil "Effort"))
                         (oid (org-id-get))
                         (m (point-marker)))
                    (set-marker-insertion-type m t)
                    (push (list :marker m
                                :part-num part-num
                                :org-id oid
                                :headline hd
                                :scheduled sched
                                :effort effort)
                          placeholders)))))))))
    (nreverse (sort placeholders (lambda (a b)
                                   (< (plist-get a :part-num)
                                      (plist-get b :part-num)))))))

(defun org-auto-scheduler--cleanup-task-placeholders (parent-marker origin-id)
  "Remove all existing placeholder child subtasks under PARENT-MARKER for ORIGIN-ID.
Preserves any clocks back to PARENT-MARKER."
  (let ((phs (org-auto-scheduler--find-child-placeholders parent-marker origin-id)))
    (dolist (ph phs)
      (let ((m (plist-get ph :marker)))
        (when (and m (markerp m) (marker-buffer m))
          (org-with-point-at m
            (let ((clocks '()))
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
              (org-back-to-heading t)
              (org-cut-subtree)
              (setq org-auto-scheduler--session-cleaned-placeholders
                    (1+ (or org-auto-scheduler--session-cleaned-placeholders 0)))
              (when (and clocks parent-marker (markerp parent-marker) (marker-buffer parent-marker))
                (org-with-point-at parent-marker
                  (org-auto-scheduler--insert-clock-entries (nreverse clocks)))))))))))

(defun org-auto-scheduler--place-split-placeholders (origin-id headline marker topo-depth rem-effort min-chunk tags time-block active-gap search-time start-date-str)
  "Place REM-EFFORT across subsequent slots/days as placeholder subtasks.
Reuses and updates existing placeholder subtasks in-place when possible to avoid ID and file churn.
Returns the end-time of the last placeholder scheduled today, or SEARCH-TIME."
  (let* ((part-num 1)
         (current-date-str (format-time-string "%Y-%m-%d" search-time))
         (days-checked 0)
         (max-attempts (* 10 (max 1 org-auto-scheduler-max-days-to-check)))
         (attempts 0)
         (last-today-end search-time)
         (existing-phs (unless org-auto-scheduler--preview-mode
                         (org-auto-scheduler--find-child-placeholders marker origin-id)))
         (handled-part-nums '()))
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
                     (existing-ph (cl-find-if (lambda (p) (= (plist-get p :part-num) part-num))
                                              existing-phs))
                     (actual-marker (when existing-ph (plist-get existing-ph :marker))))
                (push part-num handled-part-nums)
                (if org-auto-scheduler--preview-mode
                    (push (list ph-id ph-slot ph-end (list org-auto-scheduler-placeholder-tag) t
                                ph-headline ph-sched-str marker topo-depth :placeholder
                                (list (format "Remaining: %dm" chunk-dur))
                                :origin-id origin-id :remaining-effort chunk-dur)
                          org-auto-scheduler-completed-tasks)
                  ;; Live mode: reuse or create
                  (if (and actual-marker (markerp actual-marker) (marker-buffer actual-marker))
                      (let* ((curr-sched (plist-get existing-ph :scheduled))
                             (curr-effort (plist-get existing-ph :effort))
                             (needed-effort-str (format "%d:%02d" (/ chunk-dur 60) (% chunk-dur 60)))
                             (sched-match (org-auto-scheduler--timestamps-equal-p curr-sched ph-sched-str))
                             (effort-match (equal curr-effort needed-effort-str)))
                        (unless (and sched-match effort-match)
                          (org-with-point-at actual-marker
                            (org-back-to-heading t)
                            (unless (string= (org-get-heading t t t t) ph-headline)
                              (org-edit-headline ph-headline))
                            (org-auto-scheduler--set-scheduled ph-sched-str)
                            (org-set-property "Effort" needed-effort-str)
                            (org-set-property "AUTOSCH_PART_NUM" (number-to-string part-num))
                            (org-set-property "AUTOSCH_PLACEHOLDER" "t")
                            (org-set-property org-auto-scheduler-scheduled-property "t")))
                        (push (list ph-id ph-slot ph-end (list org-auto-scheduler-placeholder-tag) t
                                    ph-headline ph-sched-str actual-marker topo-depth :placeholder
                                    (list (format "Remaining: %dm" chunk-dur))
                                    :origin-id origin-id :remaining-effort chunk-dur)
                              org-auto-scheduler-completed-tasks))
                    ;; Create new placeholder
                    (let ((new-marker (org-auto-scheduler--create-placeholder-subtask
                                       marker ph-headline ph-slot ph-end chunk-dur origin-id part-num)))
                      (push (list ph-id ph-slot ph-end (list org-auto-scheduler-placeholder-tag) t
                                  ph-headline ph-sched-str (or new-marker marker) topo-depth :placeholder
                                  (list (format "Remaining: %dm" chunk-dur))
                                  :origin-id origin-id :remaining-effort chunk-dur)
                            org-auto-scheduler-completed-tasks))))
                (setq rem-effort (- rem-effort chunk-dur))
                (setq part-num (1+ part-num))
                (when (string= ph-start-day start-date-str)
                  (setq last-today-end ph-end))
                (setq search-time (time-add ph-end (seconds-to-time (* 60 active-gap))))
                (let ((new-date-str (format-time-string "%Y-%m-%d" search-time)))
                  (unless (string= current-date-str new-date-str)
                    (setq days-checked (1+ days-checked))
                    (setq current-date-str new-date-str)))))))))
    ;; Delete any unneeded leftover placeholders (e.g. effort reduced)
    (unless org-auto-scheduler--preview-mode
      (dolist (e-ph existing-phs)
        (unless (member (plist-get e-ph :part-num) handled-part-nums)
          (let ((m (plist-get e-ph :marker)))
            (when (and m (markerp m) (marker-buffer m))
              (org-with-point-at m
                (let ((clocks '()))
                  (save-excursion
                    (let ((end (save-excursion (or (outline-next-heading) (point-max)))))
                      (when (re-search-forward ":LOGBOOK:" end t)
                        (let ((lb-start (point))
                              (lb-end (if (re-search-forward ":END:" end t)
                                          (match-beginning 0)
                                        end)))
                          (goto-char lb-start)
                          (while (re-search-forward "^[ 	]*CLOCK:.*$" lb-end t)
                            (push (match-string 0) clocks))))))
                  (org-back-to-heading t)
                  (org-cut-subtree)
                  (setq org-auto-scheduler--session-cleaned-placeholders
                        (1+ (or org-auto-scheduler--session-cleaned-placeholders 0)))
                  (when (and clocks marker (markerp marker) (marker-buffer marker))
                    (org-with-point-at marker
                      (org-auto-scheduler--insert-clock-entries (nreverse clocks)))))))))))
    last-today-end))

(defun org-auto-scheduler--place-pomodoro-placeholders (origin-id headline marker topo-depth rem-effort work-mins break-mins tags time-block start-time total-parts)
  "Place REM-EFFORT across subsequent Pomodoro intervals as placeholder subtasks.
Each interval has WORK-MINS work separated by BREAK-MINS gaps.
Returns the end-time of the last Pomodoro chunk."
  (let* ((existing-phs (when (and marker (markerp marker) (marker-buffer marker))
                         (org-auto-scheduler--find-child-placeholders marker origin-id)))
         (handled-part-nums '())
         (part-num 2)
         (last-end start-time)
         (search-time (time-add start-time (seconds-to-time (* 60 break-mins))))
         (days-checked 0)
         (current-date-str (format-time-string "%Y-%m-%d" search-time)))
    (while (and (> rem-effort 0) (< days-checked 7))
      (let* ((chunk-dur (min rem-effort work-mins))
             (ph-slot (if time-block
                          (org-auto-scheduler-next-available-time-in-block search-time time-block chunk-dur)
                        (org-auto-scheduler-next-available-time search-time chunk-dur tags))))
        (if (null ph-slot)
            (progn
              (setq search-time (org-auto-scheduler-next-day-start search-time))
              (let ((new-date-str (format-time-string "%Y-%m-%d" search-time)))
                (unless (string= current-date-str new-date-str)
                  (setq days-checked (1+ days-checked))
                  (setq current-date-str new-date-str))))
          (let* ((ph-end (time-add ph-slot (seconds-to-time (* 60 chunk-dur))))
                 (ph-id (format "%s-pomodoro-%d" origin-id part-num))
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
                 (ph-headline (format "%s (Pomodoro %d/%d)" headline part-num total-parts))
                 (existing-ph (cl-find-if (lambda (p) (= (plist-get p :part-num) part-num))
                                          existing-phs))
                 (actual-marker (when existing-ph (plist-get existing-ph :marker))))
            (push part-num handled-part-nums)
            (if org-auto-scheduler--preview-mode
                (push (list ph-id ph-slot ph-end (list org-auto-scheduler-placeholder-tag) t
                            ph-headline ph-sched-str marker topo-depth :placeholder
                            (list (format "Pomodoro chunk: %dm" chunk-dur))
                            :origin-id origin-id :remaining-effort chunk-dur)
                      org-auto-scheduler-completed-tasks)
              ;; Live mode: reuse or create
              (if (and actual-marker (markerp actual-marker) (marker-buffer actual-marker))
                  (let* ((curr-sched (plist-get existing-ph :scheduled))
                         (curr-effort (plist-get existing-ph :effort))
                         (needed-effort-str (format "%d:%02d" (/ chunk-dur 60) (% chunk-dur 60)))
                         (sched-match (org-auto-scheduler--timestamps-equal-p curr-sched ph-sched-str))
                         (effort-match (equal curr-effort needed-effort-str)))
                    (unless (and sched-match effort-match)
                      (org-with-point-at actual-marker
                        (org-back-to-heading t)
                        (unless (string= (org-get-heading t t t t) ph-headline)
                          (org-edit-headline ph-headline))
                        (org-auto-scheduler--set-scheduled ph-sched-str)
                        (org-set-property "Effort" needed-effort-str)
                        (org-set-property "AUTOSCH_PART_NUM" (number-to-string part-num))
                        (org-set-property "AUTOSCH_PLACEHOLDER" "t")
                        (org-set-property org-auto-scheduler-scheduled-property "t")))
                    (push (list ph-id ph-slot ph-end (list org-auto-scheduler-placeholder-tag) t
                                ph-headline ph-sched-str actual-marker topo-depth :placeholder
                                (list (format "Pomodoro chunk: %dm" chunk-dur))
                                :origin-id origin-id :remaining-effort chunk-dur)
                          org-auto-scheduler-completed-tasks))
                ;; Create new placeholder
                (let ((new-marker (org-auto-scheduler--create-placeholder-subtask
                                   marker ph-headline ph-slot ph-end chunk-dur origin-id part-num)))
                  (push (list ph-id ph-slot ph-end (list org-auto-scheduler-placeholder-tag) t
                              ph-headline ph-sched-str (or new-marker marker) topo-depth :placeholder
                              (list (format "Pomodoro chunk: %dm" chunk-dur))
                              :origin-id origin-id :remaining-effort chunk-dur)
                        org-auto-scheduler-completed-tasks))))
            (setq rem-effort (- rem-effort chunk-dur))
            (setq part-num (1+ part-num))
            (setq last-end ph-end)
            (setq search-time (time-add ph-end (seconds-to-time (* 60 break-mins))))
            (let ((new-date-str (format-time-string "%Y-%m-%d" search-time)))
              (unless (string= current-date-str new-date-str)
                (setq days-checked (1+ days-checked))
                (setq current-date-str new-date-str)))))))
    ;; Delete leftover placeholders
    (unless org-auto-scheduler--preview-mode
      (dolist (e-ph existing-phs)
        (unless (member (plist-get e-ph :part-num) handled-part-nums)
          (let ((m (plist-get e-ph :marker)))
            (when (and m (markerp m) (marker-buffer m))
              (org-with-point-at m
                (org-back-to-heading t)
                (org-cut-subtree)
                (setq org-auto-scheduler--session-cleaned-placeholders
                      (1+ (or org-auto-scheduler--session-cleaned-placeholders 0)))))))))
    last-end))

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

(defun org-auto-scheduler--create-placeholder-subtask (parent-marker headline start-time end-time effort parent-id &optional part-num)
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
          (when part-num
            (org-set-property "AUTOSCH_PART_NUM" (number-to-string part-num)))
          (org-set-property "Effort" (format "%d:%02d" (/ effort 60) (% effort 60)))
          (org-id-get-create)
          (let ((pm (point-marker)))
            (set-marker-insertion-type pm t)
            pm))))))

(defun org-auto-scheduler-cleanup-placeholders (&optional all-placeholders)
  "Remove temporary auto-scheduler placeholder tasks across agenda files.
When ALL-PLACEHOLDERS is non-nil (or called interactively), removes ALL placeholders.
When ALL-PLACEHOLDERS is nil, only removes:
1. Placeholders with clock entries (clocks transferred to parent task).
2. Placeholders marked DONE (parent task marked DONE as well).
3. Orphaned placeholders whose parent task no longer exists, is DONE, or is no longer splittable.
Active valid placeholders of TODO splittable tasks are preserved to avoid churn.

Safeguards:
1. If any cleaned placeholder contains clock entries, transfer them to the parent task.
2. If any cleaned placeholder was marked DONE, mark the parent task DONE as well."
  (interactive (list t))
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
                             (parent-exists (and parent-marker (markerp parent-marker) (marker-buffer parent-marker)))
                             (parent-state (when parent-exists
                                             (org-with-point-at parent-marker
                                               (org-get-todo-state))))
                             (parent-is-done (and parent-state (member parent-state org-done-keywords)))
                             (parent-is-splittable (when parent-exists
                                                     (org-with-point-at parent-marker
                                                       (or (member org-auto-scheduler-splittable-tag (org-get-tags))
                                                           (org-entry-get nil "SPLITTABLE")
                                                           (org-auto-scheduler-get-task-pomodoro-spec parent-marker origin-id)))))
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
                                (while (re-search-forward "^[ 	]*CLOCK:.*$" lb-end t)
                                  (push (match-string 0) clocks))))))
                        (let ((should-delete
                               (or all-placeholders
                                   (> (length clocks) 0)
                                   is-done
                                   (not parent-exists)
                                   parent-is-done
                                   (not parent-is-splittable))))
                          (when should-delete
                            ;; Delete the placeholder subtree FIRST
                            (org-back-to-heading t)
                            (org-cut-subtree)
                            (setq modified t)
                            (setq total-deleted (1+ total-deleted))
                            ;; Transfer clocks to parent if found
                            (when (and clocks parent-exists)
                              (let ((clock-lines (nreverse clocks)))
                                (org-with-point-at parent-marker
                                  (org-auto-scheduler--insert-clock-entries clock-lines))
                                (setq total-clocks-preserved (+ total-clocks-preserved (length clock-lines)))
                                (org-auto-scheduler--log-info "[org-auto-scheduler-cleanup-placeholders] Preserved %d clock entries from placeholder to parent task"
                                                              (length clock-lines))))
                            ;; If placeholder was marked DONE, mark parent DONE
                            (when (and is-done parent-exists)
                              (org-with-point-at parent-marker
                                (org-todo (or (car org-done-keywords) "DONE")))
                              (org-auto-scheduler--log-info "[org-auto-scheduler-cleanup-placeholders] Marked parent task DONE based on completed placeholder"))))))))
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
               (score (nth 1 task))
               (task-id (nth 5 task))
               (is-crit (org-auto-scheduler-task-critical-p task-id))
               (name-display (if is-crit (concat "⚡ " (nth 6 task)) (nth 6 task))))
          (insert "| "
                  name-display " | " ; Task name
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
         ((not all-blockers-met)
          (let* ((waiting-blockers (org-auto-scheduler--get-waiting-blockers marker))
                 (has-waiting-blocker (not (null waiting-blockers)))
                 (status-str (if has-waiting-blocker "BLOCKED (WAITING)" "BLOCKED"))
                 (first-waiting-title (when has-waiting-blocker
                                        (org-with-point-at (car waiting-blockers)
                                          (org-get-heading t t t t))))
                 (reason (if has-waiting-blocker
                             (format "Blocked by WAITING: '%s'" (or first-waiting-title "task"))
                           "Blocked by unmet dependencies")))
            (org-auto-scheduler--log-info "[org-auto-scheduler-schedule-single-task] Task '%s' is %s. %s." headline status-str reason)
            ;; Record blocked tasks so they appear in the review buffer
            (when org-auto-scheduler--preview-mode
              (push (list task-id current-time current-time '("AUTOSCH") nil headline
                          status-str marker (or topo-depth 0) :blocked (list reason))
                    org-auto-scheduler-completed-tasks)))
          current-time) ; Return current-time unmodified since task wasn't scheduled

         (is-saved-skipped
          (org-auto-scheduler--log-info "[org-auto-scheduler-schedule-single-task] Task '%s' is marked skipped in saved decisions." headline)
          (when org-auto-scheduler--preview-mode
            (push (list task-id start-time start-time '("AUTOSCH") nil headline
                        "SKIPPED" marker (or topo-depth 0) :skipped '("Skipped in previous session"))
                  org-auto-scheduler-completed-tasks))
          current-time)

         (t
          ;; Task is not blocked, proceed to find an available time
          (let* ((tags (org-get-tags marker))
                 (needs-buffer (member "buffertime" tags))
                 (active-gap (if needs-buffer 15 org-auto-scheduler-task-gap))
                 (is-freeset (org-auto-scheduler-task-freeset-p marker task-id))
                 (is-pinned (org-auto-scheduler-task-pinned-p marker task-id))
                 (pinned-time (org-auto-scheduler-task-pinned-time marker task-id))
                 (chop-today (and task-id
                                  (bound-and-true-p org-auto-scheduler--reordering-p)
                                  (plist-get (org-auto-scheduler--get-review-override task-id) :chop-today)))
                 (is-splittable (or chop-today
                                    (org-auto-scheduler-task-splittable-p marker task-id)
                                    (and is-freeset (bound-and-true-p org-auto-scheduler--reordering-p))
                                    (and is-pinned pinned-time)))
                 (min-chunk (org-auto-scheduler-get-min-chunk marker))
                 (split-result nil)
                 (pomo-spec (org-auto-scheduler-get-task-pomodoro-spec marker task-id))
                 (is-pomodoro (not (null pomo-spec)))
                 (pomo-work (and pomo-spec (plist-get pomo-spec :work)))
                 (pomo-break (and pomo-spec (plist-get pomo-spec :break))))
            (cond
             ;; -------------------------------------------------------------
             ;; PINNED task or FREESET reordered task path:
             ;; -------------------------------------------------------------
             ((or (and is-pinned pinned-time)
                  (and (bound-and-true-p org-auto-scheduler--reordering-p) is-freeset))
              (let* ((origin-id (or task-id (org-with-point-at marker (org-id-get-create))))
                     (eff-id (or task-id origin-id))
                     (eff-start (or pinned-time available-time))
                     (start-date-str (format-time-string "%Y-%m-%d" eff-start))
                     (midnight (org-auto-scheduler--get-day-midnight eff-start))
                     (avail-before-midnight (max 1 (floor (/ (float-time (time-subtract midnight eff-start)) 60))))
                     (fits-before-midnight (<= remaining-effort avail-before-midnight)))
                (if fits-before-midnight
                    ;; Fits before midnight: schedule entire task today at eff-start
                    (let* ((end-time (time-add eff-start (seconds-to-time (* 60 remaining-effort))))
                           (end-day-str (format-time-string "%Y-%m-%d" end-time))
                           (schedule-string
                            (if (string= start-date-str end-day-str)
                                (format "<%s-%s>"
                                        (format-time-string "%Y-%m-%d %a %H:%M" eff-start)
                                        (format-time-string "%H:%M" end-time))
                              (format "<%s>--<%s>"
                                      (format-time-string "%Y-%m-%d %a %H:%M" eff-start)
                                      (format-time-string "%Y-%m-%d %a %H:%M" end-time)))))
                      (if org-auto-scheduler--preview-mode
                          (push (list eff-id eff-start end-time '("AUTOSCH") t headline schedule-string marker topo-depth)
                                org-auto-scheduler-completed-tasks)
                        (org-auto-scheduler--set-scheduled schedule-string)
                        (org-set-property org-auto-scheduler-scheduled-property "t")
                        (org-auto-scheduler--cleanup-task-placeholders marker origin-id)
                        (push (list eff-id eff-start end-time '("AUTOSCH") t headline schedule-string nil topo-depth)
                              org-auto-scheduler-completed-tasks))
                      (org-auto-scheduler--log-info "[org-auto-scheduler-schedule-single-task] Scheduled PINNABLE task '%s' from %s to %s (Effort: %dm)"
                                                    headline
                                                    (format-time-string "%Y-%m-%d %H:%M" eff-start)
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
                                      (format-time-string "%Y-%m-%d %a %H:%M" eff-start)
                                      (format-time-string "%H:%M" today-end))
                            (format "<%s>--<%s>"
                                    (format-time-string "%Y-%m-%d %a %H:%M" eff-start)
                                    (format-time-string "%Y-%m-%d %a %H:%M" today-end)))))
                    (if org-auto-scheduler--preview-mode
                        (push (list eff-id eff-start today-end '("AUTOSCH") t headline schedule-string marker topo-depth :split-today nil :split-today t)
                              org-auto-scheduler-completed-tasks)
                      (org-auto-scheduler--set-scheduled schedule-string)
                      (org-set-property org-auto-scheduler-scheduled-property "t")
                      (push (list eff-id eff-start today-end '("AUTOSCH") t headline schedule-string nil topo-depth :split-today nil :split-today t)
                            org-auto-scheduler-completed-tasks))
                    ;; Place remaining effort on subsequent days starting from next day start
                    (let* ((next-day-start (org-auto-scheduler-next-day-start eff-start))
                           (last-end (org-auto-scheduler--place-split-placeholders
                                      origin-id headline marker topo-depth rem-effort min-chunk
                                      tags time-block active-gap next-day-start start-date-str)))
                      (org-auto-scheduler--log-info "[org-auto-scheduler-schedule-single-task] Split PINNABLE task '%s': today %dm (until midnight), remaining %dm across subsequent days"
                                                    headline today-chunk rem-effort)
                      (time-add last-end (seconds-to-time (* 60 active-gap))))))))

             ;; Standard task path (with Pomodoro & normal SPLITTABLE support)
             ;; -------------------------------------------------------------
             (t
              (while (and available-time (not end-time) (not split-result) (< attempts max-attempts))
                (setq attempts (1+ attempts))
                (when available-time
                  (let* ((work-chunk (if (and is-pomodoro (> remaining-effort pomo-work))
                                         pomo-work
                                       remaining-effort))
                         (candidate-end (time-add available-time (seconds-to-time (* 60 work-chunk))))
                         (occupied-result (org-auto-scheduler-time-slot-occupied-p available-time work-chunk task-id tags)))
                    (if occupied-result
                        (progn
                          (setq end-time nil)
                          ;; If splittable (and NOT pomodoro), check if we can take the available slot right now
                          (let ((avail-now (cond
                                            ((and chop-today (not is-pomodoro))
                                             (min chop-today remaining-effort))
                                            ((and is-splittable (not is-pomodoro))
                                             (org-auto-scheduler--available-duration-at available-time remaining-effort tags)))))
                            (if (and is-splittable (not is-pomodoro)
                                     avail-now
                                     (>= avail-now (if chop-today 1 min-chunk))
                                     (< avail-now remaining-effort))
                                ;; Split task into today's chunk and place remaining chunks
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
                                  (if org-auto-scheduler--preview-mode
                                      (push (list task-id available-time today-end '("AUTOSCH") t headline schedule-string marker topo-depth :split-today nil :split-today t)
                                            org-auto-scheduler-completed-tasks)
                                    (org-auto-scheduler--set-scheduled schedule-string)
                                    (org-set-property org-auto-scheduler-scheduled-property "t")
                                    (org-auto-scheduler--cleanup-task-placeholders marker origin-id)
                                    (push (list task-id available-time today-end '("AUTOSCH") t headline schedule-string nil topo-depth :split-today nil :split-today t)
                                          org-auto-scheduler-completed-tasks))
                                  (let* ((next-day-start (org-auto-scheduler-next-day-start available-time))
                                         (last-end (org-auto-scheduler--place-split-placeholders
                                                    origin-id headline marker topo-depth rem-effort min-chunk
                                                    tags time-block active-gap next-day-start today-start-day)))
                                    (org-auto-scheduler--log-info "[org-auto-scheduler-schedule-single-task] Split task '%s': today %dm (%s), remaining %dm across subsequent days"
                                                                  headline today-chunk
                                                                  (format-time-string "%H:%M" available-time))
                                    (setq split-result (time-add last-end (seconds-to-time (* 60 active-gap))))))

                              ;; Cannot split: advance normally
                              (setq available-time (if time-block
                                                       (org-auto-scheduler-next-available-time-in-block occupied-result time-block work-chunk)
                                                     (org-auto-scheduler-next-available-time occupied-result work-chunk tags))))))

                      ;; Slot is available!
                      (if (and is-pomodoro (> remaining-effort pomo-work))
                          ;; Pomodoro intra-task split: schedule first chunk on parent headline, place remaining chunks
                          (let* ((today-chunk pomo-work)
                                 (today-end candidate-end)
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
                                 (origin-id (or task-id (org-with-point-at marker (org-id-get-create))))
                                 (total-parts (+ (/ remaining-effort pomo-work)
                                                 (if (> (% remaining-effort pomo-work) 0) 1 0))))
                            (if org-auto-scheduler--preview-mode
                                (push (list task-id available-time today-end '("AUTOSCH") t headline schedule-string marker topo-depth :pomodoro-parent nil)
                                      org-auto-scheduler-completed-tasks)
                              (org-auto-scheduler--set-scheduled schedule-string)
                              (org-set-property org-auto-scheduler-scheduled-property "t")
                              (push (list task-id available-time today-end '("AUTOSCH") t headline schedule-string nil topo-depth :pomodoro-parent nil)
                                    org-auto-scheduler-completed-tasks))
                            (let ((last-end (org-auto-scheduler--place-pomodoro-placeholders
                                             origin-id headline marker topo-depth rem-effort pomo-work pomo-break
                                             tags time-block today-end total-parts)))
                              (org-auto-scheduler--log-info "[org-auto-scheduler-schedule-single-task] Pomodoro split task '%s': initial chunk %dm (%s to %s), remaining %dm across Pomodoro intervals"
                                                            headline today-chunk
                                                            (format-time-string "%H:%M" available-time)
                                                            (format-time-string "%H:%M" today-end)
                                                            rem-effort)
                              (setq split-result (time-add last-end (seconds-to-time (* 60 (max active-gap pomo-break)))))))
                        ;; Entire task fits (or remaining-effort <= pomo-work)
                        (setq end-time candidate-end))))))
              (cond
               (split-result
                split-result)
               (end-time
                (let* ((start-day (format-time-string "%Y-%m-%d" available-time))
                       (end-day (format-time-string "%Y-%m-%d" end-time))
                       (schedule-string
                        (if (string= start-day end-day)
                            (format "<%s-%s>"
                                    (format-time-string "%Y-%m-%d %a %H:%M" available-time)
                                    (format-time-string "%H:%M" end-time))
                          (format "<%s>--<%s>"
                                  (format-time-string "%Y-%m-%d %a %H:%M" available-time)
                                  (format-time-string "%Y-%m-%d %a %H:%M" end-time))))
                       (origin-id (or task-id (org-with-point-at marker (org-id-get-create)))))
                  (if org-auto-scheduler--preview-mode
                      (push (list task-id available-time end-time '("AUTOSCH") t headline schedule-string marker topo-depth) org-auto-scheduler-completed-tasks)
                    (org-auto-scheduler--set-scheduled schedule-string)
                    (org-set-property org-auto-scheduler-scheduled-property "t")
                    (org-auto-scheduler--cleanup-task-placeholders marker (or task-id origin-id))
                    (push (list task-id available-time end-time '("AUTOSCH") t headline schedule-string nil topo-depth) org-auto-scheduler-completed-tasks))
                  (org-auto-scheduler--log-info "[org-auto-scheduler-schedule-single-task] Scheduled task '%s' from %s to %s (Remaining effort: %d minutes, Gap: %dm)"
                                                headline
                                                (format-time-string "%Y-%m-%d %H:%M" available-time)
                                                (format-time-string "%Y-%m-%d %H:%M" end-time)
                                                remaining-effort active-gap)
                  (org-auto-scheduler--log-debug "[org-auto-scheduler-schedule-single-task] Adding task %s to the list of completed scheduling tasks"
                                                 task-id))
                (let ((next-gap (if is-pomodoro
                                    (max active-gap pomo-break)
                                  active-gap)))
                  (time-add end-time (seconds-to-time (* 60 next-gap)))))
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
(defvar org-auto-scheduler--scheduling-freeset-p nil
  "Internal flag bound non-nil when scheduling a FREESET task during review recalculation.
Bypasses day working-hours checks (start-time and end-time) so the task can be
scheduled early morning or late evening up to midnight.")

(defvaralias 'org-auto-scheduler--scheduling-pinnable-p 'org-auto-scheduler--scheduling-freeset-p)

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
  "Convert minutes since midnight to a time string (H:MM or HH:MM)."
  (format "%d:%02d" (/ minutes 60) (mod minutes 60)))

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
         (override-time (plist-get override :pinned-time))
         (override-date (or (plist-get override :pinned-date)
                            (unless (bound-and-true-p org-auto-scheduler--ignore-target-dates-p)
                              (plist-get override :target-date))))
         (saved-dec (and task-id (null override-date) (null override-time)
                         (org-auto-scheduler-get-saved-decision task-id marker)))
         (saved-date (and saved-dec
                          (unless (bound-and-true-p org-auto-scheduler--ignore-target-dates-p)
                            (plist-get saved-dec :target-date))))
         (effective-date (or override-date saved-date)))
    (cond
     (override-time
      (org-time-string-to-time override-time))
     (effective-date
      (org-auto-scheduler-parse-time-string (concat effective-date " 00:00")))
     (t
      (let ((not-before-string (org-entry-get marker "NOT_BEFORE")))
        (when not-before-string
          (org-time-string-to-time not-before-string)))))))

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
          (let ((waiting-tasks (org-auto-scheduler-get-waiting-tasks)))
            (when waiting-tasks
              (let ((stale (cl-remove-if-not (lambda (w)
                                               (let ((d (plist-get w :days-waiting)))
                                                 (and d (>= d org-auto-scheduler-waiting-stale-days))))
                                             waiting-tasks)))
                (insert (format "- Waiting tasks: %d" (length waiting-tasks)))
                (if stale
                    (insert (format " (%d STALE >= %d days)\n" (length stale) org-auto-scheduler-waiting-stale-days))
                  (insert "\n"))
                (when stale
                  (insert "\n** ⚠️ Stale Waiting Tasks Requiring Follow-Up\n")
                  (dolist (st stale)
                    (insert (format "  - [%s] %s (waiting %d days%s)\n"
                                    (plist-get st :state)
                                    (plist-get st :headline)
                                    (or (plist-get st :days-waiting) 0)
                                    (if (plist-get st :scheduled)
                                        (format ", Follow-up: %s" (plist-get st :scheduled))
                                      ""))))))))
          ;; Final alignment of the entire table
          (goto-char (point-min))
          (search-forward "|" nil t)
          (beginning-of-line)
          (org-table-align))
        (pop-to-buffer buffer)))))


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
                           " [f] Focus HUD Cockpit\n"
                           " [S] Save Review Decisions\n"
                           " [M] Restore & Merge Schedule\n"
                           " [C] Clear Saved Decisions\n"
                           " [c] Score Adherence\n"
                           " [a] Adherence Report\n"
                           " [b] Bump Agenda\n"
                           " [e] Extend Current Task\n"
                           " [N] Toggle Non-Blocking\n"
                           " [k] Cleanup Placeholders\n"
                           " [W] Weekly Retrospective\n"
                           "Choice: ")
                   '(?s ?r ?t ?f ?F ?S ?M ?C ?c ?a ?b ?e ?N ?n ?k ?W ?w))))
      (cond
       ((memq choice '(?f ?F)) (call-interactively 'org-auto-scheduler-focus))
       ((eq choice ?e) (call-interactively 'org-auto-scheduler-extend-current-task))
       ((eq choice ?s) (call-interactively 'org-auto-scheduler-schedule-tasks))
       ((eq choice ?r) (call-interactively 'org-auto-scheduler-review-and-apply))
       ((eq choice ?t) (call-interactively 'org-auto-scheduler-schedule-today))
       ((eq choice ?S) (call-interactively 'org-auto-scheduler-review-save-decisions))
       ((eq choice ?M) (call-interactively 'org-auto-scheduler-review-restore-and-merge))
       ((eq choice ?C) (call-interactively 'org-auto-scheduler-clear-saved-decisions))
       ((eq choice ?c) (call-interactively 'org-auto-scheduler-score-schedule))
       ((eq choice ?a) (call-interactively 'org-auto-scheduler-adherence-report))
       ((memq choice '(?W ?w)) (call-interactively 'org-auto-scheduler-weekly-retrospective))
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
    ["Adherence & Analytics"
      ("A" "Snapshot schedule"       org-auto-scheduler-snapshot-schedule)
      ("c" "Score adherence"         org-auto-scheduler-score-schedule)
      ("a" "Adherence report"        org-auto-scheduler-adherence-report)
      ("W" "Weekly retrospective"    org-auto-scheduler-weekly-retrospective)]
    ["Tools"
      ("f" "Focus HUD Cockpit"       org-auto-scheduler-focus)
      ("b" "Bump agenda"             org-auto-scheduler-bump-agenda)
      ("e" "Extend current task"     org-auto-scheduler-extend-current-task)
      ("N" "Toggle non-blocking"     org-auto-scheduler-toggle-non-blocking)
      ("h" "Historical insights"     org-auto-scheduler-historical-insights)
      ("B" "Toggle background"       org-auto-scheduler-toggle-background)
      ("k" "Cleanup placeholders"    org-auto-scheduler-cleanup-placeholders)]))

;;; Dynamic Repacking, Smart Bump & Real-Time Adaptation

(defun org-auto-scheduler--format-time-range (start-time end-time)
  "Format START-TIME and END-TIME into a scheduled string."
  (let ((start-day (format-time-string "%Y-%m-%d" start-time))
        (end-day (format-time-string "%Y-%m-%d" end-time)))
    (if (string= start-day end-day)
        (format "<%s-%s>"
                (format-time-string "%Y-%m-%d %a %H:%M" start-time)
                (format-time-string "%H:%M" end-time))
      (format "<%s>--<%s>"
              (format-time-string "%Y-%m-%d %a %H:%M" start-time)
              (format-time-string "%Y-%m-%d %a %H:%M" end-time)))))

(defun org-auto-scheduler-get-today-scheduled-tasks (&optional date-str)
  "Return a list of AUTOSCH tasks scheduled for DATE-STR (default today).
Each item is a plist: (:id ID :marker MARKER :headline HEADLINE :start START
:end END :effort EFFORT :tags TAGS :state STATE :is-done DONE-P)."
  (let* ((target-date (or date-str (format-time-string "%Y-%m-%d")))
         (tasks '()))
    (org-map-entries
     (lambda ()
       (let* ((sched-str (org-entry-get (point) "SCHEDULED"))
              (tags (org-get-tags))
              (is-autosch (member "AUTOSCH" tags)))
         (when (and sched-str is-autosch (not (member "ARCHIVE" tags)))
           (let* ((range (org-auto-scheduler-parse-scheduled-time-range sched-str))
                  (start-time (nth 0 range))
                  (end-time (nth 1 range)))
             (when (and start-time
                        (string= (format-time-string "%Y-%m-%d" start-time) target-date))
               (let* ((id (or (org-id-get) (when (buffer-file-name) (org-id-get-create))))
                      (m (point-marker))
                      (hl (org-get-heading t t t t))
                      (state (org-get-todo-state))
                      (is-done (and state (member state (or org-done-keywords '("DONE" "CANCELLED" "DROPPED")))))
                      (effort (or (org-auto-scheduler-get-effort m)
                                  (when (and start-time end-time)
                                    (round (/ (float-time (time-subtract end-time start-time)) 60)))
                                  org-auto-scheduler-default-task-duration)))
                 (push (list :id id
                             :marker m
                             :headline hl
                             :start start-time
                             :end (or end-time (time-add start-time (seconds-to-time (* 60 effort))))
                             :effort effort
                             :tags tags
                             :state state
                             :is-done is-done)
                       tasks)))))))
     nil 'agenda)
    (sort (nreverse tasks) (lambda (a b) (time-less-p (plist-get a :start) (plist-get b :start))))))

(defun org-auto-scheduler--repack-tasks (tasks-to-repack start-from-time &optional preserve-tasks)
  "Repack TASKS-TO-REPACK starting from START-FROM-TIME into collision-free slots.
PRESERVE-TASKS is a list of task plists that should be treated as fixed reservations.
Returns the count of successfully repacked tasks."
  (let ((current-time start-from-time)
        (repacked-count 0)
        (temp-completed '())
        (cont-work 0))
    ;; Register preserved tasks into temp-completed so they act as collision obstacles
    (dolist (pt preserve-tasks)
      (let* ((pid (plist-get pt :id))
             (pstart (plist-get pt :start))
             (pend (plist-get pt :end))
             (ptags (or (plist-get pt :tags) '("AUTOSCH")))
             (phl (plist-get pt :headline)))
        (push (list pid pstart pend ptags t phl nil nil nil) temp-completed)))

    (let ((org-auto-scheduler-completed-tasks temp-completed))
      (dolist (task tasks-to-repack)
        (let* ((tid (plist-get task :id))
               (m (plist-get task :marker))
               (effort (or (plist-get task :effort) org-auto-scheduler-default-task-duration))
               (tags (plist-get task :tags))
               (is-pinned (and m (org-auto-scheduler-task-pinned-p m tid)))
               (pinned-time (and m (org-auto-scheduler-task-pinned-time m tid))))
          (if (and is-pinned pinned-time)
              ;; Pinned task stays at its pinned time
              (let ((pin-t (org-time-string-to-time pinned-time)))
                (push (list tid pin-t (time-add pin-t (seconds-to-time (* 60 effort)))
                            tags t (plist-get task :headline) nil m nil)
                      org-auto-scheduler-completed-tasks)
                (setq current-time (time-add pin-t (seconds-to-time (* 60 (+ effort org-auto-scheduler-task-gap)))))
                (setq cont-work 0))
            ;; Regular task: find next available collision-free slot
            (let* ((pomo-spec (and m (org-auto-scheduler-get-task-pomodoro-spec m tid)))
                   (pomo-break (and pomo-spec (plist-get pomo-spec :break)))
                   (active-gap (if pomo-break
                                   (max (if (member "buffertime" tags) 15 org-auto-scheduler-task-gap)
                                        pomo-break)
                                 (if (member "buffertime" tags) 15 org-auto-scheduler-task-gap)))
                   (slot-start (org-auto-scheduler-next-available-time current-time effort tags)))
              (when slot-start
                (let* ((slot-end (time-add slot-start (seconds-to-time (* 60 effort))))
                       (sched-str (org-auto-scheduler--format-time-range slot-start slot-end)))
                  (when (and m (markerp m) (marker-buffer m))
                    (org-with-point-at m
                      (org-auto-scheduler--set-scheduled sched-str)))
                  (push (list tid slot-start slot-end tags t (plist-get task :headline) sched-str m nil)
                        org-auto-scheduler-completed-tasks)
                  (setq current-time (time-add slot-end (seconds-to-time (* 60 active-gap))))
                  (cl-incf repacked-count))))))))
    repacked-count))

(defun org-auto-scheduler-bump-agenda (minutes)
  "Push the current task and all subsequent AUTOSCH tasks for today forward by MINUTES.
Uses collision-aware repacking to jump over fixed calendar appointments and
gracefully roll over tasks that exceed workday hours."
  (interactive "nBump agenda items forward by minutes: ")
  (let* ((marker (cond
                  ((eq major-mode 'org-agenda-mode) (org-get-at-bol 'org-marker))
                  ((derived-mode-p 'org-mode) (point-marker))
                  (t nil)))
         (target-id (when (and marker (markerp marker) (marker-buffer marker))
                      (org-with-point-at marker (or (org-id-get) (when (buffer-file-name) (org-id-get-create)))))))
    (unless target-id
      (user-error "No valid task at point"))
    (org-auto-scheduler--build-agenda-cache)
    (let* ((today-tasks (org-auto-scheduler-get-today-scheduled-tasks))
           (found-target nil)
           (target-task nil)
           (preserve-tasks '())
           (subsequent-tasks '()))
      (dolist (tk today-tasks)
        (cond
         ((equal (plist-get tk :id) target-id)
          (setq found-target t)
          (setq target-task tk))
         (found-target
          (push tk subsequent-tasks))
         (t
          (push tk preserve-tasks))))
      (unless found-target
        (user-error "Task '%s' is not scheduled for today" target-id))
      (setq subsequent-tasks (nreverse subsequent-tasks))
      (setq preserve-tasks (nreverse preserve-tasks))
      (let* ((t-start (plist-get target-task :start))
             (bump-start (time-add t-start (seconds-to-time (* minutes 60))))
             (tasks-to-repack (cons target-task subsequent-tasks))
             (count (org-auto-scheduler--repack-tasks tasks-to-repack bump-start preserve-tasks)))
        (when (eq major-mode 'org-agenda-mode)
          (org-agenda-redo))
        (when (get-buffer "*Org Agenda*")
          (with-current-buffer "*Org Agenda*" (org-agenda-redo)))
        (message "Bumped and repacked %d tasks forward by %d minutes (collision-free)." count minutes)))))

(defun org-auto-scheduler-extend-current-task (&optional minutes)
  "Extend the current task by MINUTES (default 15) and repack downstream tasks.
Finds current task via active clock, agenda point, or Org headline."
  (interactive (list (read-number "Extend current task by minutes: " 15)))
  (let* ((min (or minutes 15))
         (marker (cond
                  ((and (fboundp 'org-clock-is-active) (org-clock-is-active)
                        (boundp 'org-clock-marker) (markerp org-clock-marker) (marker-buffer org-clock-marker))
                   org-clock-marker)
                  ((eq major-mode 'org-agenda-mode) (org-get-at-bol 'org-marker))
                  ((derived-mode-p 'org-mode) (point-marker))
                  (t nil)))
         (task-id (when (and marker (markerp marker) (marker-buffer marker))
                    (org-with-point-at marker (or (org-id-get) (when (buffer-file-name) (org-id-get-create)))))))
    (unless task-id
      (user-error "No active or selected task found to extend"))
    (org-auto-scheduler--build-agenda-cache)
    (let* ((today-tasks (org-auto-scheduler-get-today-scheduled-tasks))
           (found-target nil)
           (target-task nil)
           (preserve-tasks '())
           (downstream-tasks '()))
      (dolist (tk today-tasks)
        (cond
         ((equal (plist-get tk :id) task-id)
          (setq found-target t)
          (setq target-task tk))
         (found-target
          (push tk downstream-tasks))
         (t
          (push tk preserve-tasks))))
      (unless found-target
        (user-error "Current task is not scheduled for today"))
      (setq downstream-tasks (nreverse downstream-tasks))
      (setq preserve-tasks (nreverse preserve-tasks))
      ;; Extend target task: new end is extended by min
      (let* ((t-start (plist-get target-task :start))
             (t-end (plist-get target-task :end))
             (t-effort (or (plist-get target-task :effort)
                           (round (/ (float-time (time-subtract t-end t-start)) 60))))
             (new-effort (+ t-effort min))
             (new-end (time-add t-end (seconds-to-time (* min 60))))
             (new-sched-str (org-auto-scheduler--format-time-range t-start new-end)))
        (org-with-point-at marker
          (org-auto-scheduler--set-scheduled new-sched-str)
          (when (org-entry-get nil "Effort")
            (org-entry-put nil "Effort" (org-auto-scheduler-minutes-to-time new-effort))))
        (plist-put target-task :end new-end)
        (plist-put target-task :effort new-effort)
        (push target-task preserve-tasks)
        (let* ((next-start (time-add new-end (seconds-to-time (* org-auto-scheduler-task-gap 60))))
               (count (org-auto-scheduler--repack-tasks downstream-tasks next-start preserve-tasks)))
          (when (eq major-mode 'org-agenda-mode)
            (org-agenda-redo))
          (when (get-buffer "*Org Agenda*")
            (with-current-buffer "*Org Agenda*" (org-agenda-redo)))
          (when (fboundp 'org-auto-scheduler--update-overrun-modeline)
            (org-auto-scheduler--update-overrun-modeline))
          (message "Extended '%s' by %d min and repacked %d downstream tasks."
                   (plist-get target-task :headline) min count))))))

(defvar org-auto-scheduler-test-early-done nil
  "Internal test variable to force non-interactive testing of early-done hook.")

(defun org-auto-scheduler--on-todo-state-change ()
  "Hook function for `org-after-todo-state-change-hook' to handle early task completion."
  (condition-case err
      (when (and (boundp 'org-state)
                 (stringp org-state)
                 (or (member org-state (or org-done-keywords '("DONE")))
                     (and org-auto-scheduler-kill-todo-state
                          (string= org-state org-auto-scheduler-kill-todo-state))))
        (save-excursion
          (let* ((m (point-marker))
                 (tags (org-get-tags m))
                 (is-autosch (member "AUTOSCH" tags))
                 (sched-str (org-entry-get m "SCHEDULED")))
            (when (and is-autosch sched-str)
              (let* ((range (org-auto-scheduler-parse-scheduled-time-range sched-str))
                     (start-time (nth 0 range))
                     (end-time (nth 1 range))
                     (now (current-time)))
                (when (and start-time end-time
                           (string= (format-time-string "%Y-%m-%d" start-time)
                                    (format-time-string "%Y-%m-%d" now))
                           (time-less-p now end-time))
                  (let ((remaining-mins (round (/ (float-time (time-subtract end-time now)) 60))))
                    (when (>= remaining-mins org-auto-scheduler-early-done-threshold-minutes)
                      (let ((action
                             (cond
                              ((eq org-auto-scheduler-early-done-action 'pull) 'pull)
                              ((or (eq org-auto-scheduler-early-done-action 'keep)
                                   (null org-auto-scheduler-early-done-action)) 'keep)
                              ((and noninteractive (not org-auto-scheduler-test-early-done)) 'keep)
                              (t
                               (let ((ch (read-char-choice
                                          (format "Task finished %dm early! [p]ull upcoming tasks forward, [r]est / break, [k]eep schedule: " remaining-mins)
                                          '(?p ?P ?r ?R ?k ?K ?q ?\s ?\r ?\e))))
                             (if (memq ch '(?p ?P)) 'pull 'keep))))))
                        (when (eq action 'pull)
                          ;; Truncate the completed task's scheduled end to now
                          (org-with-point-at m
                            (org-auto-scheduler--set-scheduled
                             (org-auto-scheduler--format-time-range start-time now)))
                          ;; Repack upcoming tasks
                          (org-auto-scheduler--build-agenda-cache)
                          (let* ((cur-id (org-with-point-at m (or (org-id-get) (when (buffer-file-name) (org-id-get-create)))))
                                 (today-tasks (org-auto-scheduler-get-today-scheduled-tasks))
                                 (preserve '())
                                 (upcoming '())
                                 (seen-target nil))
                            (dolist (tk today-tasks)
                              (cond
                               ((or (and cur-id (not (string= cur-id "")) (equal (plist-get tk :id) cur-id))
                                    (equal (plist-get tk :marker) m))
                                (setq seen-target t)
                                (plist-put tk :end now)
                                (push tk preserve))
                               (seen-target
                                (unless (plist-get tk :is-done)
                                  (push tk upcoming)))
                               (t
                                (push tk preserve))))
                            (setq upcoming (nreverse upcoming))
                            (setq preserve (nreverse preserve))
                            (let* ((pull-start (time-add now (seconds-to-time (* org-auto-scheduler-task-gap 60))))
                                   (cnt (org-auto-scheduler--repack-tasks upcoming pull-start preserve)))
                              (when (eq major-mode 'org-agenda-mode)
                                (org-agenda-redo))
                              (when (get-buffer "*Org Agenda*")
                                (with-current-buffer "*Org Agenda*" (org-agenda-redo)))
                              (message "Pulled %d upcoming tasks forward to close the %d-minute gap." cnt remaining-mins)))))))))))))
    (error (org-auto-scheduler--log-warn "Error in early-done hook: %s" err))))

(add-hook 'org-after-todo-state-change-hook #'org-auto-scheduler--on-todo-state-change)

(defun org-auto-scheduler--on-waiting-state-change ()
  "Hook function for `org-after-todo-state-change-hook' to handle waiting state transitions.
Clocks out if currently clocked into the task, strips or removes SCHEDULED time
based on `org-auto-scheduler-waiting-clear-scheduled-time', and records/clears
the `WAITING_SINCE' property."
  (condition-case err
      (let* ((new-state (or (and (boundp 'org-state) (stringp org-state) org-state)
                            (org-get-todo-state)))
             (is-waiting (and new-state (member new-state org-auto-scheduler-waiting-states))))
        (if is-waiting
            (save-excursion
              (org-back-to-heading t)
              ;; 1. Automatic Clock-out if active
              (when (and org-auto-scheduler-waiting-auto-clock-out
                         (fboundp 'org-clock-is-active)
                         (org-clock-is-active))
                (let ((clock-m (and (boundp 'org-clock-marker) (markerp org-clock-marker) org-clock-marker)))
                  (when (or (null clock-m)
                            (and (equal (marker-buffer clock-m) (current-buffer))
                                 (<= (point) (marker-position clock-m))
                                 (< (marker-position clock-m)
                                    (save-excursion (outline-next-heading) (point)))))
                    (org-clock-out nil t)
                    (message "Clocked out: task moved to %s." new-state))))

              ;; 2. Clear or strip scheduled time
              (let ((sched (org-entry-get nil "SCHEDULED")))
                (when sched
                  (pcase org-auto-scheduler-waiting-clear-scheduled-time
                    ('clear-all
                     (org-entry-delete nil "SCHEDULED")
                     (message "Removed SCHEDULED timestamp for %s task." new-state))
                    ('clear-time
                     (when (string-match "\\([0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\}\\(?: +[A-Za-z]+\\)?\\)" sched)
                       (let ((date-part (match-string 1 sched)))
                         (org-auto-scheduler--set-scheduled (format "<%s>" date-part))
                         (message "Converted SCHEDULED to follow-up tickler date <%s>." date-part))))
                    (_ nil))))

              ;; 3. Record WAITING_SINCE property if not already set
              (unless (org-entry-get nil org-auto-scheduler-waiting-since-property)
                (org-entry-put nil org-auto-scheduler-waiting-since-property
                               (format-time-string "%Y-%m-%d %H:%M"))))

          ;; Transitioning OUT of waiting state
          (when (org-entry-get nil org-auto-scheduler-waiting-since-property)
            (org-entry-delete nil org-auto-scheduler-waiting-since-property))))
    (error (org-auto-scheduler--log-warn "Error in waiting state change hook: %s" err))))

(add-hook 'org-after-todo-state-change-hook #'org-auto-scheduler--on-waiting-state-change)

;; Initialize background scheduler if enabled at load time
(when org-auto-scheduler-background-enabled
  (org-auto-scheduler-setup-background))
;;; ============================================================================
;;; Focus HUD Integration (Powered by org-focus-hud)
;;; ============================================================================

(eval-and-compile
  (let ((sibling (expand-file-name "../org-focus-hud"
                                   (file-name-directory
                                    (or load-file-name buffer-file-name default-directory)))))
    (when (file-directory-p sibling)
      (add-to-list 'load-path sibling))))

(require 'org-focus-hud nil t)

(defun org-auto-scheduler-focus-setup-integration ()
  "Configure `org-focus-hud' to use `org-auto-scheduler' capabilities."
  (when (featurep 'org-focus-hud)
    (setq org-focus-hud-today-tasks-function #'org-auto-scheduler-get-today-scheduled-tasks)
    (setq org-focus-hud-extend-task-function #'org-auto-scheduler-extend-current-task)
    (setq org-focus-hud-effort-function #'org-auto-scheduler-get-effort)
    (setq org-focus-hud-clocked-time-function #'org-auto-scheduler-get-clocked-time)
    (setq org-focus-hud-pomodoro-function #'org-auto-scheduler-get-task-pomodoro-spec)
    (setq org-focus-hud-waiting-states org-auto-scheduler-waiting-states)
    (add-hook 'org-focus-hud-on-done-hook #'org-auto-scheduler--on-todo-state-change)

    ;; Backward compatibility aliases for org-auto-scheduler-focus-* symbols:
    (defalias 'org-auto-scheduler-focus-mode 'org-focus-hud-mode)
    (defvaralias 'org-auto-scheduler-focus-mode-map 'org-focus-hud-mode-map)
    (defalias 'org-auto-scheduler-focus-refresh 'org-focus-hud-refresh)
    (defalias 'org-auto-scheduler-focus-log-work 'org-focus-hud-log-work)
    (defalias 'org-auto-scheduler-focus-log-scroll-up 'org-focus-hud-log-scroll-up)
    (defalias 'org-auto-scheduler-focus-log-scroll-down 'org-focus-hud-log-scroll-down)
    (defalias 'org-auto-scheduler-focus-move-item-up 'org-focus-hud-move-item-up)
    (defalias 'org-auto-scheduler-focus-move-item-down 'org-focus-hud-move-item-down)
    (defalias 'org-auto-scheduler-focus-outdent-item 'org-focus-hud-outdent-item)
    (defalias 'org-auto-scheduler-focus-indent-item 'org-focus-hud-indent-item)
    (defalias 'org-auto-scheduler-focus-toggle-checklist 'org-focus-hud-toggle-checklist)
    (defalias 'org-auto-scheduler-focus-add-checklist 'org-focus-hud-add-checklist)
    (defalias 'org-auto-scheduler-focus-add-note 'org-focus-hud-add-note)
    (defalias 'org-auto-scheduler-focus-add-subtask 'org-focus-hud-add-subtask)
    (defalias 'org-auto-scheduler-focus-add-sibling 'org-focus-hud-add-sibling)
    (defalias 'org-auto-scheduler-focus-done 'org-focus-hud-done)
    (defalias 'org-auto-scheduler-focus-wait 'org-focus-hud-wait)
    (defalias 'org-auto-scheduler-focus-extend 'org-focus-hud-extend)
    (defalias 'org-auto-scheduler-focus-toggle-pause 'org-focus-hud-toggle-pause)
    (defalias 'org-auto-scheduler-focus-toggle-help 'org-focus-hud-toggle-help)
    (defalias 'org-auto-scheduler-focus-quit 'org-focus-hud-quit)
    (defalias 'org-auto-scheduler-focus-goto-task 'org-focus-hud-goto-task)
    (defalias 'org-auto-scheduler-focus-goto-task-other-window 'org-focus-hud-goto-task-other-window)
    (defalias 'org-auto-scheduler-focus-clock-in-task 'org-focus-hud-clock-in-task)
    (defalias 'org-auto-scheduler-focus-next-checklist 'org-focus-hud-next-checklist)
    (defalias 'org-auto-scheduler-focus-prev-checklist 'org-focus-hud-prev-checklist)
    (defalias 'org-auto-scheduler-focus--get-checklists 'org-focus-hud--get-checklists)
    (defalias 'org-auto-scheduler-focus--get-notes 'org-focus-hud--get-notes)
    (defalias 'org-auto-scheduler-focus--get-subtasks 'org-focus-hud--get-subtasks)
    (defalias 'org-auto-scheduler-focus--get-logs 'org-focus-hud--get-logs)
    (defalias 'org-auto-scheduler-focus--calculate-levels 'org-focus-hud--calculate-levels)
    (defalias 'org-auto-scheduler-focus--resolve-task 'org-focus-hud--resolve-task)
    (defvaralias 'org-auto-scheduler-focus--target-marker 'org-focus-hud--target-marker)
    (defvaralias 'org-auto-scheduler-focus--log-offset 'org-focus-hud--log-offset)
    (defvaralias 'org-auto-scheduler-focus--show-help 'org-focus-hud--show-help)
    (defvaralias 'org-auto-scheduler--focus-timer 'org-focus-hud--timer)

    (when (boundp 'org-auto-scheduler-focus-mode-map)
      (define-key org-auto-scheduler-focus-mode-map (kbd "RET") #'org-auto-scheduler-focus-toggle-checklist)
      (define-key org-auto-scheduler-focus-mode-map (kbd "k") #'org-auto-scheduler-focus-add-checklist)
      (define-key org-auto-scheduler-focus-mode-map (kbd "n") #'org-auto-scheduler-focus-add-note)
      (define-key org-auto-scheduler-focus-mode-map (kbd "s") #'org-auto-scheduler-focus-add-subtask)
      (define-key org-auto-scheduler-focus-mode-map (kbd "a") #'org-auto-scheduler-focus-add-sibling)
      (define-key org-auto-scheduler-focus-mode-map (kbd "d") #'org-auto-scheduler-focus-done)
      (define-key org-auto-scheduler-focus-mode-map (kbd "w") #'org-auto-scheduler-focus-wait)
      (define-key org-auto-scheduler-focus-mode-map (kbd "+") #'org-auto-scheduler-focus-extend)
      (define-key org-auto-scheduler-focus-mode-map (kbd "=") #'org-auto-scheduler-focus-extend)
      (define-key org-auto-scheduler-focus-mode-map (kbd "p") #'org-auto-scheduler-focus-toggle-pause)
      (define-key org-auto-scheduler-focus-mode-map (kbd "?") #'org-auto-scheduler-focus-toggle-help)
      (define-key org-auto-scheduler-focus-mode-map (kbd "q") #'org-auto-scheduler-focus-quit)
      (define-key org-auto-scheduler-focus-mode-map (kbd "o") #'org-auto-scheduler-focus-goto-task-other-window)
      (define-key org-auto-scheduler-focus-mode-map (kbd "O") #'org-auto-scheduler-focus-goto-task)
      (define-key org-auto-scheduler-focus-mode-map (kbd "c") #'org-auto-scheduler-focus-clock-in-task)
      (define-key org-auto-scheduler-focus-mode-map (kbd "r") #'org-auto-scheduler-focus-refresh)
      (define-key org-auto-scheduler-focus-mode-map (kbd "g") #'org-auto-scheduler-focus-refresh)
      (define-key org-auto-scheduler-focus-mode-map (kbd "l") #'org-auto-scheduler-focus-log-work)
      (define-key org-auto-scheduler-focus-mode-map (kbd "[") #'org-auto-scheduler-focus-log-scroll-up)
      (define-key org-auto-scheduler-focus-mode-map (kbd "]") #'org-auto-scheduler-focus-log-scroll-down)
      (define-key org-auto-scheduler-focus-mode-map (kbd "TAB") #'org-auto-scheduler-focus-next-checklist)
      (define-key org-auto-scheduler-focus-mode-map (kbd "<backtab>") #'org-auto-scheduler-focus-prev-checklist)
      (define-key org-auto-scheduler-focus-mode-map (kbd "M-k") #'org-auto-scheduler-focus-move-item-up)
      (define-key org-auto-scheduler-focus-mode-map (kbd "M-<up>") #'org-auto-scheduler-focus-move-item-up)
      (define-key org-auto-scheduler-focus-mode-map (kbd "M-j") #'org-auto-scheduler-focus-move-item-down)
      (define-key org-auto-scheduler-focus-mode-map (kbd "M-<down>") #'org-auto-scheduler-focus-move-item-down)
      (define-key org-auto-scheduler-focus-mode-map (kbd "M-h") #'org-auto-scheduler-focus-outdent-item)
      (define-key org-auto-scheduler-focus-mode-map (kbd "M-<left>") #'org-auto-scheduler-focus-outdent-item)
      (define-key org-auto-scheduler-focus-mode-map (kbd "M-l") #'org-auto-scheduler-focus-indent-item)
      (define-key org-auto-scheduler-focus-mode-map (kbd "M-<right>") #'org-auto-scheduler-focus-indent-item))))

(with-eval-after-load 'org-focus-hud
  (org-auto-scheduler-focus-setup-integration))
(when (featurep 'org-focus-hud)
  (org-auto-scheduler-focus-setup-integration))

;;;###autoload
(defun org-auto-scheduler-focus (&optional marker)
  "Open the Focus HUD for MARKER (or current active task).
Delegates to `org-focus-hud'."
  (interactive
   (list (cond
          ((and (derived-mode-p 'org-mode)
                (not (derived-mode-p 'org-agenda-mode))
                (ignore-errors (save-excursion (org-back-to-heading t) (point-marker)))))
          ((eq major-mode 'org-agenda-mode)
           (let ((m (or (org-get-at-bol 'org-marker) (org-get-at-bol 'org-hd-marker))))
             (and m (markerp m) (marker-buffer m) m)))
          ((and (fboundp 'org-clock-is-active) (org-clock-is-active)
                (boundp 'org-clock-marker) (markerp org-clock-marker) (marker-buffer org-clock-marker))
           (org-with-point-at org-clock-marker
             (org-back-to-heading t)
             (point-marker)))
          (t nil))))
  (if (fboundp 'org-focus-hud)
      (org-focus-hud marker)
    (user-error "The `org-focus-hud' package is required to launch the Focus HUD cockpit")))

;;;###autoload
(defun org-auto-scheduler-reload ()
  "Reload `org-auto-scheduler' and all its submodules cleanly from disk.
Re-evaluates core, daemon, analytics, and review modules,
and re-arms background scheduler timers if enabled."
  (interactive)
  (let ((dir (or (and (boundp 'org-auto-scheduler-base-dir) org-auto-scheduler-base-dir)
                 (file-name-directory (or (locate-library "org-auto-scheduler") "")))))
    (when (and dir (file-directory-p dir))
      (add-to-list 'load-path dir)))
  (message "Reloading org-auto-scheduler and submodules...")
  (load (or (locate-library "org-auto-scheduler") "org-auto-scheduler") nil t)
  (load (or (locate-library "org-auto-scheduler-daemon") "org-auto-scheduler-daemon") nil t)
  (load (or (locate-library "org-auto-scheduler-analytics") "org-auto-scheduler-analytics") nil t)
  (load (or (locate-library "org-auto-scheduler-review") "org-auto-scheduler-review") nil t)
  (when (and (bound-and-true-p org-auto-scheduler-background-enabled)
             (fboundp 'org-auto-scheduler-setup-background))
    (org-auto-scheduler-setup-background))
  (message "Org Auto Scheduler successfully reloaded."))

(provide 'org-auto-scheduler)

;;; org-auto-scheduler.el ends here
