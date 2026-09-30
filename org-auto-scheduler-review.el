;;; org-auto-scheduler-review.el --- Interactive review, capacity gauge, diff & timegrid -*- lexical-binding: t; -*-

;; Copyright (C) 2024-2026 SSD2019
;; License: GPL-3.0-or-later

;;; Commentary:
;;
;; Interactive review table mode, decision persistence (save/restore/merge/skip),
;; Unicode capacity load gauge, task chop, What-If Diff buffer, and synchronized
;; org-timegrid split view for org-auto-scheduler.

;;; Code:

(require 'org)
(require 'cl-lib)
(require 'tabulated-list)
(require 'color)
(eval-when-compile (require 'evil nil t))

(unless (fboundp 'org-auto-scheduler--with-active-operation)
  (defmacro org-auto-scheduler--with-active-operation (op-name &rest body)
    "Execute BODY with `org-auto-scheduler--active-operation` bound to OP-NAME."
    (declare (indent 1) (debug t))
    (let ((prev-op (make-symbol "prev-op")))
      `(let ((,prev-op (and (boundp 'org-auto-scheduler--active-operation)
                            org-auto-scheduler--active-operation)))
         (unwind-protect
             (progn
               (setq org-auto-scheduler--active-operation ,op-name)
               ,@body)
           (setq org-auto-scheduler--active-operation ,prev-op))))))

(defcustom org-auto-scheduler-review-show-agenda-events t
  "If non-nil, display existing fixed agenda events (non-AUTOSCH) in the review buffer."
  :type 'boolean
  :group 'org-auto-scheduler)

(defcustom org-auto-scheduler-review-compact-schedule t
  "If non-nil, `org-auto-scheduler-review-recalculate` packs tasks continuously,
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
Applies to `org-auto-scheduler-review-move-up`,
`org-auto-scheduler-review-move-down`, `org-auto-scheduler-review-move-before`,
and the day-shifting commands: the schedule is immediately recalculated
(as if \"r\" were pressed) so moved tasks never overlap.  When nil, moving a
task only reorders the list and you must press \"r\" to recalculate, as
before."
  :type 'boolean
  :group 'org-auto-scheduler)

(defcustom org-auto-scheduler-review-recalculate-delay 3.0
  "Delay in seconds of idle time after moving tasks before auto-recalculating.
When non-nil and positive, rapid keystrokes (K, J, D, >, <) and mouse drags
reorder rows instantly and debounce schedule recalculation until input pauses.
If nil or 0, recalculate immediately on each move."
  :type '(choice (const :tag "Immediate" nil)
                 (number :tag "Seconds delay" 3.0))
  :group 'org-auto-scheduler)

(defvar org-auto-scheduler--review-recalc-timer nil
  "Idle timer object for debounced review buffer schedule recalculation.")

(defcustom org-auto-scheduler-review-timegrid-integration nil
  "If non-nil, offer a visual time-grid view of the proposed schedule.
When enabled, `org-auto-scheduler-review-open-timegrid` (bound to \"T\" in
the review buffer) renders the currently proposed schedule using the
`org-timegrid` package (https://github.com/Gleek/org-timegrid), a
read-only, draggable-block calendar view.  Requires `org-timegrid` to be
installed; it is not a dependency of org-auto-scheduler and is not
pulled in automatically."
  :type 'boolean
  :group 'org-auto-scheduler)

(defcustom org-auto-scheduler-review-timegrid-layout 'horizontal
  "Default layout style when opening the review timegrid view.
Can be `horizontal` (timegrid above the review buffer, showing full week / 7 days)
or `side-by-side` (timegrid on the left showing `org-auto-scheduler-review-timegrid-side-by-side-days`
days, and review table on the right).
You can toggle between these layouts anytime with `i` in either the review
table or the timegrid."
  :type '(choice (const :tag "Horizontal split (timegrid above, table below)" horizontal)
                 (const :tag "Side-by-side (timegrid on left, table on right)" side-by-side))
  :group 'org-auto-scheduler)

(defcustom org-auto-scheduler-review-timegrid-side-by-side-days 3
  "Number of days displayed in the timegrid when in side-by-side layout."
  :type 'integer
  :group 'org-auto-scheduler)

(defcustom org-auto-scheduler-review-timegrid-horizontal-days 7
  "Number of days displayed in the timegrid when in horizontal layout."
  :type 'integer
  :group 'org-auto-scheduler)

(defvar-local org-auto-scheduler--timegrid-current-layout nil
  "Tracks whether the active timegrid split is 'side-by-side or 'horizontal.")


(unless (fboundp 'org-auto-scheduler--log-debug)
  (defun org-auto-scheduler--log-debug (&rest _args) nil))
(unless (fboundp 'org-auto-scheduler--log-warn)
  (defun org-auto-scheduler--log-warn (&rest _args) nil))
(unless (fboundp 'org-auto-scheduler--log-error)
  (defun org-auto-scheduler--log-error (&rest _args) nil))

(defsubst org-auto-scheduler--review-special-row-p (id)
  "Return t if ID represents a non-task row (day separator or header shortcuts)."
  (and id (string-prefix-p "__" id)))

(defvar org-auto-scheduler--review-all-entries)
(defvar org-auto-scheduler--review-overrides)

(defun org-auto-scheduler--get-review-overrides ()
  "Return the review overrides hash-table from current buffer or review buffer."
  (unless (and (bound-and-true-p org-auto-scheduler--background-running)
               (boundp 'org-auto-scheduler-background-pause-on-review)
               (not org-auto-scheduler-background-pause-on-review))
    (or (and (boundp 'org-auto-scheduler--review-overrides)
             (hash-table-p org-auto-scheduler--review-overrides)
             (> (hash-table-count org-auto-scheduler--review-overrides) 0)
             org-auto-scheduler--review-overrides)
        (let ((buf (get-buffer "*Org Auto Scheduler Review*")))
          (when (and buf (buffer-live-p buf))
            (buffer-local-value 'org-auto-scheduler--review-overrides buf)))
        (and (boundp 'org-auto-scheduler--review-overrides)
             org-auto-scheduler--review-overrides))))

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

(defcustom org-auto-scheduler-auto-non-blocking-regexp
  "\\b\\(Lunch\\|Gym\\|Tentative\\|OOO\\|Commute\\|Travel\\)\\b"
  "Regular expression matching headline titles of non-AUTOSCH events that should
automatically be treated as non-blocking.
Matching events will not block auto-scheduler slots unless explicitly overridden
by an Org headline property (e.g. `:NON_BLOCKING: nil'\'' or `no'\'').
Set to nil to disable automatic title-based non-blocking detection."
  :type '(choice (regexp :tag "Regular expression")
                 (const :tag "Disabled" nil))
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

(defvar org-auto-scheduler--pinned-cache nil
  "Cache for pinned task reservations during a scheduling/recalculating run.
Hash table mapping date string (or all-dates key) to list of reservation items.")


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


(defun org-auto-scheduler-task-non-blocking-p (task-id &optional marker headline)
  "Return non-nil if TASK-ID, MARKER, or HEADLINE represents a non-blocking task.
Checks Org headline properties, saved configuration records, and
`org-auto-scheduler-auto-non-blocking-regexp`."
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
        (ignore-errors (org-back-to-heading t))
        (let ((val (or (org-entry-get nil org-auto-scheduler-non-blocking-property nil t)
                       (org-entry-get nil "AUTOSCH_NON_BLOCKING" nil t)
                       (org-entry-get nil "NON_BLOCKING" nil t))))
          ;; Fallback: if not found via org-entry-get, check property drawer even if placed after timestamp
          (unless val
            (save-excursion
              (let ((end (save-excursion (outline-next-heading) (point))))
                (when (re-search-forward "^[ \t]*:\\(?:AUTOSCH_\\)?NON_BLOCKING:[ \t]*\\([^ \t\n\r]+\\)" end t)
                  (setq val (match-string 1))))))
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
     ((and org-auto-scheduler-auto-non-blocking-regexp
           (let ((title (or headline
                            (and tid (plist-get (cdr (assoc tid org-auto-scheduler--non-blocking-tasks)) :headline))
                            (when (and m (markerp m) (marker-buffer m))
                              (org-with-point-at m
                                (ignore-errors (org-back-to-heading t))
                                (org-get-heading t t t t))))))
             (and title (string-match-p org-auto-scheduler-auto-non-blocking-regexp title))))
      t)
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
                 (prop-freeset (or (org-entry-get nil org-auto-scheduler-freeset-property)
                                   (org-entry-get nil "PINNABLE")))
                 (prop-pinned (org-entry-get nil org-auto-scheduler-pinned-property))
                 (prop-pinned-time (or (org-entry-get nil org-auto-scheduler-pinned-time-property)
                                       (let ((p (org-entry-get nil "PINNED")))
                                         (and p (not (member (downcase p) '("t" "nil" "no" "1" ""))) p))))
                 (order (if prop-order (string-to-number prop-order) (plist-get entry :order)))
                 (skipped (cond ((string= prop-skip "t") t)
                                ((string= prop-skip "nil") nil)
                                (prop-skip t)
                                (t (plist-get entry :skipped))))
                 (target-date (or prop-target (plist-get entry :target-date)))
                 (freeset (cond ((string= prop-freeset "t") t)
                                ((string= prop-freeset "nil") nil)
                                (prop-freeset t)
                                (t (or (plist-get entry :freeset) (plist-get entry :pinnable)))))
                 (pinned (cond ((string= prop-pinned "t") t)
                               ((string= prop-pinned "nil") nil)
                               (prop-pinned t)
                               (t (plist-get entry :pinned))))
                 (pinned-time (or prop-pinned-time (plist-get entry :pinned-time))))
            (list :order order :skipped skipped :target-date target-date
                  :freeset freeset :pinnable freeset :pinned pinned :pinned-time pinned-time)))
      entry)))

(defun org-auto-scheduler-review-save-decisions (&optional silent)
  "Save current ordering, skipping, and date decisions from review buffer.
When SILENT is non-nil, suppress confirmation message."
  (interactive)
  (unless (eq major-mode 'org-auto-scheduler-review-mode)
    (user-error "Not in an Org Auto Scheduler Review buffer"))
  (org-auto-scheduler--review-flush-pending-recalculate)
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
          (let* ((task-data (assoc row-id org-auto-scheduler-completed-tasks))
                 (is-blocked-or-failed (and task-data (memq (nth 9 task-data) '(:blocked :failed))))
                 (is-waiting (org-auto-scheduler--review-waiting-row-p row-id))
                 (checked (if entry (string= (aref entry 0) "[X]") t))
                 (skipped (if (or is-blocked-or-failed is-waiting) nil (not checked)))
                 (marker (and task-data (nth 7 task-data)))
                 (headline (and task-data (nth 5 task-data)))
                 (override (and (bound-and-true-p org-auto-scheduler--review-overrides)
                                (gethash row-id org-auto-scheduler--review-overrides)))
                 (prev-dec (cdr (assoc row-id org-auto-scheduler--saved-review-decisions)))
                 (target-date (or (plist-get override :target-date)
                                  (plist-get override :pinned-date)
                                  (and prev-dec (plist-get prev-dec :target-date))))
                 (freeset (or (plist-get override :freeset) (plist-get override :pinnable)))
                 (pinned (plist-get override :pinned))
                 (pinned-time (plist-get override :pinned-time))
                 (decision (list :order order-rank
                                 :skipped skipped
                                 :target-date target-date
                                 :freeset freeset
                                 :pinnable freeset
                                 :pinned pinned
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
                (if freeset
                    (progn
                      (org-set-property org-auto-scheduler-freeset-property "t")
                      (org-delete-property "PINNABLE"))
                  (org-delete-property org-auto-scheduler-freeset-property)
                  (org-delete-property "PINNABLE"))
                (if pinned
                    (org-set-property org-auto-scheduler-pinned-property "t")
                  (org-delete-property org-auto-scheduler-pinned-property))
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
  (setq org-auto-scheduler--pinned-cache nil)
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
                     (is-done (member todo org-done-keywords))
                     (is-waiting (and todo (member todo org-auto-scheduler-waiting-states))))
                (unless is-done
                  (let* ((b-head (or (org-with-point-at b (org-get-heading t t t t)) "Blocker task"))
                         (b-id (org-with-point-at b (org-id-get)))
                         (b-task (or (cl-find b org-auto-scheduler-completed-tasks
                                              :key (lambda (x) (nth 7 x)))
                                     (and b-id (assoc b-id org-auto-scheduler-completed-tasks)))))
                    (cond
                      (is-waiting
                       (push (format "⛔ Blocker is WAITING (%s): %s"
                                     todo (org-auto-scheduler--truncate b-head 30))
                             warnings))
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

(defun org-auto-scheduler--copy-overrides (table)
  "Create an independent deep copy of review overrides TABLE."
  (let ((new-table (make-hash-table :test 'equal)))
    (when (hash-table-p table)
      (maphash (lambda (k v)
                 (puthash k (copy-sequence v) new-table))
               table))
    new-table))

(defun org-auto-scheduler--review-push-undo ()
  "Save current entries, overrides, and completed tasks to undo stack."
  (when tabulated-list-entries
    (push (list :entries (mapcar (lambda (e) (list (car e) (copy-sequence (cadr e))))
                                 tabulated-list-entries)
                :all-entries (copy-sequence org-auto-scheduler--review-all-entries)
                :overrides (org-auto-scheduler--copy-overrides org-auto-scheduler--review-overrides)
                :completed-tasks (copy-tree org-auto-scheduler-completed-tasks))
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

(defun org-auto-scheduler-workday-duration-minutes ()
  "Return the total configured workday duration in minutes."
  (let* ((start-m (condition-case nil (org-duration-to-minutes org-auto-scheduler-start-time) (error 540)))
         (end-m (condition-case nil (org-duration-to-minutes org-auto-scheduler-end-time) (error 1020)))
         (diff (- (or end-m 1020) (or start-m 540))))
    (if (> diff 0) diff 480)))

(defun org-auto-scheduler--render-capacity-gauge (today-minutes workday-minutes)
  "Render a visual Unicode capacity bar for TODAY-MINUTES out of WORKDAY-MINUTES."
  (let* ((workday (max 1 (or workday-minutes 480)))
         (pct (round (* (/ (float today-minutes) workday) 100)))
         (today-h (/ today-minutes 60.0))
         (workday-h (/ workday 60.0))
         (slack-m (- workday today-minutes))
         (slack-h (/ (abs slack-m) 60.0))
         (bar-width 10)
         (filled (min bar-width (round (/ (* (min 100 pct) bar-width) 100.0))))
         (empty (max 0 (- bar-width filled)))
         (bar-chars (concat (make-string filled ?█) (make-string empty ?░)))
         (face (cond
                ((> pct 100) 'error)
                ((> pct 85) 'warning)
                (t 'success)))
         (bar (propertize (format "[%s]" bar-chars) 'face face)))
    (if (> pct 100)
        (format "Load: %s %.1fh/%.1fh (%d%% OVERLOAD +%.1fh)"
                bar today-h workday-h pct slack-h)
      (format "Load: %s %.1fh/%.1fh (%d%%) │ Slack: %.1fh"
              bar today-h workday-h pct slack-h))))

(defun org-auto-scheduler--review-header-line (entries)
  "Build the `header-line-format' string from ENTRIES."
  (let ((total 0) (hours 0.0) (waiting-count 0) (projects (make-hash-table :test 'equal))
        (min-date nil) (max-date nil) (today-count 0) (today-minutes 0)
        (today-str (format-time-string "%Y-%m-%d")))
    (dolist (e entries)
      (let* ((vec (cadr e))
             (id (car e)))
        (unless (org-auto-scheduler--review-special-row-p id)
          (let ((task-data (assoc id org-auto-scheduler-completed-tasks)))
            (if task-data
                (progn
                  (cl-incf total)
                  (let* ((dur-str (aref vec 4))
                         (dur (string-to-number dur-str))
                         (proj (aref vec 5)))
                    (setq hours (+ hours (/ dur 60.0)))
                    (when (and proj (not (string= proj "—")))
                      (puthash proj (1+ (gethash proj projects 0)) projects))
                    ;; Check if task is today
                    (when (nth 1 task-data)
                      (let ((d (format-time-string "%Y-%m-%d" (nth 1 task-data))))
                        (when (string= d today-str)
                          (cl-incf today-count)
                          (cl-incf today-minutes dur))
                        (when (or (null min-date) (string< d min-date)) (setq min-date d))
                        (when (or (null max-date) (string< max-date d)) (setq max-date d))))))
              ;; Task not in completed-tasks is in the waiting section
              (cl-incf waiting-count))))))
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
      (let* ((workday-mins (org-auto-scheduler-workday-duration-minutes))
             (gauge (org-auto-scheduler--render-capacity-gauge today-minutes workday-mins))
             (waiting-badge (if (> waiting-count 0)
                                (format " │ %s" (propertize (format "⏳ %d waiting" waiting-count)
                                                            'face '(:inherit bold :foreground "#e5c07b")))
                              ""))
             (legend (format " %s │ %d scheduled (%.1fh)%s │%s"
                             gauge total hours waiting-badge proj-legend)))
        (list "" (or (bound-and-true-p tabulated-list--header-string) "") "   " legend)))))

;;; Interactive Review Mode


(defun org-auto-scheduler-review-quit ()
  "Quit the Org Auto Scheduler review buffer and kill it."
  (interactive)
  (let ((win (get-buffer-window (current-buffer) t)))
    (if win
        (quit-window t win)
      (kill-buffer (current-buffer)))))

(defvar org-auto-scheduler-review-mode-map nil
  "Keymap for `org-auto-scheduler-review-mode'.")

;; Ensure the map is a valid keymap (recovers from previous `nil` state)
(unless (keymapp org-auto-scheduler-review-mode-map)
  (setq org-auto-scheduler-review-mode-map (make-sparse-keymap))
  (set-keymap-parent org-auto-scheduler-review-mode-map tabulated-list-mode-map))

(let ((map org-auto-scheduler-review-mode-map))
  ;; Core operations (RET and m toggle; SPC left to scroll/leader)
  (define-key map (kbd "RET") #'org-auto-scheduler-review-toggle)
  (define-key map (kbd "m")   #'org-auto-scheduler-review-toggle)
  (define-key map (kbd "TAB") #'org-auto-scheduler-review-jump)
  (define-key map (kbd "x")   #'org-auto-scheduler-review-execute)
  (define-key map (kbd "C-c C-c") #'org-auto-scheduler-review-execute)
  ;; Reorder
  (define-key map (kbd "K")   #'org-auto-scheduler-review-move-up)
  (define-key map (kbd "J")   #'org-auto-scheduler-review-move-down)
  ;; Slicing & Diff
  (define-key map (kbd "c")   #'org-auto-scheduler-review-chop)
  (define-key map (kbd "C-c c") #'org-auto-scheduler-review-chop)
  (define-key map (kbd "D")   #'org-auto-scheduler-review-diff)
  (define-key map (kbd "C-c C-v") #'org-auto-scheduler-review-diff)
  ;; Day shifting
  (define-key map (kbd ">")     #'org-auto-scheduler-review-move-day-forward)
  (define-key map (kbd "<")     #'org-auto-scheduler-review-move-day-backward)
  (define-key map (kbd "+")     #'org-auto-scheduler-review-move-day-forward)
  (define-key map (kbd "-")     #'org-auto-scheduler-review-move-day-backward)
  (define-key map (kbd "M-<down>") #'org-auto-scheduler-review-move-day-forward)
  (define-key map (kbd "M-<up>")   #'org-auto-scheduler-review-move-day-backward)
  (define-key map (kbd "d")     #'org-auto-scheduler-review-move-to-date)
  (define-key map (kbd "O")     #'org-auto-scheduler-review-move-before)
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
  ;; Undo (U is unified undo everywhere; u also supported)
  (define-key map (kbd "U")   #'org-auto-scheduler-review-undo)
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
  (define-key map (kbd "T")   #'org-auto-scheduler-review-open-timegrid)
  (define-key map (kbd "i")   #'org-auto-scheduler-review-toggle-timegrid-layout)
  ;; Toggle fixed agenda events
  (define-key map (kbd "E")   #'org-auto-scheduler-review-toggle-agenda-events)
  ;; Non-blocking toggle for fixed events (B in timegrid; B and b in review)
  (define-key map (kbd "B")   #'org-auto-scheduler-review-toggle-non-blocking)
  (define-key map (kbd "b")   #'org-auto-scheduler-review-toggle-non-blocking)
  ;; Splittable, Freeset, and Pinned shortcuts
  (define-key map (kbd "s")   #'org-auto-scheduler-review-toggle-splittable)
  (define-key map (kbd "F")   #'org-auto-scheduler-review-toggle-freeset)
  (define-key map (kbd "P")   #'org-auto-scheduler-review-pin-task)
  (define-key map (kbd "p")   #'org-auto-scheduler-review-pin-task)
  ;; Help
  (define-key map (kbd "?")   #'org-auto-scheduler-review-help)
  ;; Change log
  (define-key map (kbd "L")   #'org-auto-scheduler-show-change-log)
  (define-key map (kbd "C-c C-l") #'org-auto-scheduler-show-change-log)
  ;; Quit
  (define-key map (kbd "t")     #'org-auto-scheduler-review-set-todo-state)
  (define-key map (kbd "q")     #'org-auto-scheduler-review-quit)
  (define-key map (kbd "C-c C-k") #'org-auto-scheduler-review-quit))

;; Evil/Spacemacs compatibility: let the full mode map (including the
;; "f" filter and "*" bulk-mark prefixes) win over evil state bindings.
(with-eval-after-load 'evil
  (dolist (state '(normal motion))
    (evil-define-key state org-auto-scheduler-review-mode-map
      ;; Core operations
      (kbd "RET")     #'org-auto-scheduler-review-toggle
      (kbd "TAB")     #'org-auto-scheduler-review-jump
      (kbd "m")       #'org-auto-scheduler-review-toggle
      (kbd "B")       #'org-auto-scheduler-review-toggle-non-blocking
      (kbd "b")       #'org-auto-scheduler-review-toggle-non-blocking
      (kbd "s")       #'org-auto-scheduler-review-toggle-splittable
      (kbd "F")       #'org-auto-scheduler-review-toggle-freeset
      (kbd "P")       #'org-auto-scheduler-review-pin-task
      (kbd "p")       #'org-auto-scheduler-review-pin-task
      (kbd "L")       #'org-auto-scheduler-show-change-log
      (kbd "x")       #'org-auto-scheduler-review-execute
      (kbd "C-c C-c") #'org-auto-scheduler-review-execute
      (kbd "t")       #'org-auto-scheduler-review-set-todo-state
      (kbd "q")       #'org-auto-scheduler-review-quit
      ;; Reordering
      (kbd "K")       #'org-auto-scheduler-review-move-up
      (kbd "J")       #'org-auto-scheduler-review-move-down
      (kbd "c")       #'org-auto-scheduler-review-chop
      (kbd "D")       #'org-auto-scheduler-review-diff
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
      (kbd "U")       #'org-auto-scheduler-review-undo
      (kbd "u")       #'org-auto-scheduler-review-undo
      ;; What-if
      (kbd "e")       #'org-auto-scheduler-review-edit-effort
      ;; Views
      (kbd "T")       #'org-auto-scheduler-review-open-timegrid
      (kbd "i")       #'org-auto-scheduler-review-toggle-timegrid-layout
      ;; Move before another task (keyboard drag-to-position)
      (kbd "O")       #'org-auto-scheduler-review-move-before
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
  (add-hook 'kill-buffer-hook #'org-auto-scheduler--review-cancel-recalc-timer nil t)
  (tabulated-list-init-header))

(defun org-auto-scheduler-review-set-todo-state ()
  "Prompt to change the TODO state of the task at point in the review buffer.
Updates the state in the original Org buffer, runs state-change hooks,
and refreshes the review buffer. Works on scheduled tasks, unscheduled tasks,
and waiting tasks."
  (interactive)
  (let* ((row-id (tabulated-list-get-id)))
    (when (or (null row-id) (org-auto-scheduler--review-special-row-p row-id))
      (user-error "Not on a task row"))
    (let* ((marker (cond
                    ((string-prefix-p "__event_" row-id)
                     (or (get-text-property (point) 'event-marker)
                         (org-id-find row-id t)))
                    ((assoc row-id org-auto-scheduler-completed-tasks)
                     (let ((data (assoc row-id org-auto-scheduler-completed-tasks)))
                       (or (nth 7 data) (org-id-find row-id t))))
                    (t
                     (org-id-find row-id t)))))
      (unless (and marker (markerp marker) (marker-buffer marker))
        (user-error "Cannot find original task for ID: %s" row-id))
      (let* ((buffer (marker-buffer marker))
             (current-state (org-with-point-at marker (org-get-todo-state)))
             (file-keywords (with-current-buffer buffer
                              (if (boundp 'org-todo-keywords-1)
                                  org-todo-keywords-1
                                '("TODO" "NEXT" "IN-PROGRESS" "WAITING" "HOLD" "DONE" "CANCELLED" "DROPPED"))))
             (all-keywords (delete-dups (append file-keywords
                                                org-auto-scheduler-waiting-states
                                                (mapcar #'car org-auto-scheduler-state-weights)
                                                '("DONE" "CANCELLED"))))
             (choices (cons "[CLEAR]" all-keywords))
             (prompt (format "Change TODO state for '%s' (current: %s): "
                             (org-auto-scheduler--truncate
                              (org-with-point-at marker (org-get-heading t t t t)) 30)
                             (or current-state "none")))
             (new-state (completing-read prompt choices nil t)))
        (org-auto-scheduler--review-push-undo)
        (with-current-buffer buffer
          (save-excursion
            (goto-char marker)
            (if (string= new-state "[CLEAR]")
                (org-todo "")
              (org-todo new-state))))
        (message "Updated task to state '%s'."
                 (if (string= new-state "[CLEAR]") "none" new-state))
        ;; Save in-progress review decisions so custom orders are kept
        (org-auto-scheduler-review-save-decisions t)
        ;; Recalculate preview schedule and refresh the view
        (org-auto-scheduler-review-and-apply)
        ;; Restore point to modified task if present
        (when (get-buffer "*Org Auto Scheduler Review*")
          (with-current-buffer "*Org Auto Scheduler Review*"
            (org-auto-scheduler--review-goto-task row-id)))))))

(defun org-auto-scheduler-review-toggle ()
  "Toggle the apply checkmark for the task at point.
On fixed agenda events, toggles their non-blocking status instead."
  (interactive)
  (let* ((id (tabulated-list-get-id))
         (entry (tabulated-list-get-entry)))
    (cond
     ((and id (string-prefix-p "__event_" id))
      (org-auto-scheduler-review-toggle-non-blocking))
     ((and entry id (not (org-auto-scheduler--review-special-row-p id)))
      (org-auto-scheduler--review-push-undo)
      (aset entry 0 (if (string= (aref entry 0) "[X]") "[ ]" "[X]"))
      (tabulated-list-print t)
      (forward-line 1)))))

(defun org-auto-scheduler-review-toggle-non-blocking ()
  "Toggle non-blocking status of the event at point in the review buffer."
  (interactive)
  (unless (eq major-mode 'org-auto-scheduler-review-mode)
    (user-error "Not in an Org Auto Scheduler Review buffer"))
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
      (user-error "Not on an agenda event row")))))

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

(defun org-auto-scheduler--review-cancel-recalc-timer ()
  "Cancel any pending debounced schedule recalculation timer."
  (when (timerp org-auto-scheduler--review-recalc-timer)
    (cancel-timer org-auto-scheduler--review-recalc-timer)
    (setq org-auto-scheduler--review-recalc-timer nil)))

(defun org-auto-scheduler--review-flush-pending-recalculate ()
  "If a debounced recalculation is pending, execute it immediately."
  (when (timerp org-auto-scheduler--review-recalc-timer)
    (org-auto-scheduler--review-cancel-recalc-timer)
    (org-auto-scheduler-review-recalculate)))

(defun org-auto-scheduler--review-maybe-auto-recalculate (task-id)
  "Recalculate the schedule and re-park point on TASK-ID, per user settings.
When `org-auto-scheduler-review-auto-recalculate-on-move' is non-nil,
recalculates either after `org-auto-scheduler-review-recalculate-delay' seconds
of idle time, or immediately if that delay is nil or non-positive."
  (when org-auto-scheduler-review-auto-recalculate-on-move
    (if (and org-auto-scheduler-review-recalculate-delay
             (> org-auto-scheduler-review-recalculate-delay 0))
        (progn
          (org-auto-scheduler--review-cancel-recalc-timer)
          (message "Task moved. Recalculating in %gs... (press 'r' to recalculate now)"
                   org-auto-scheduler-review-recalculate-delay)
          (setq org-auto-scheduler--review-recalc-timer
                (run-with-idle-timer
                 org-auto-scheduler-review-recalculate-delay nil
                 (lambda (buf tid)
                   (setq org-auto-scheduler--review-recalc-timer nil)
                   (when (buffer-live-p buf)
                     (with-current-buffer buf
                       (org-auto-scheduler-review-recalculate)
                       (when tid (org-auto-scheduler--review-goto-task tid))
                       (org-auto-scheduler--timegrid-maybe-refresh))))
                 (current-buffer) task-id)))
      (org-auto-scheduler--review-cancel-recalc-timer)
      (org-auto-scheduler-review-recalculate)
      (when task-id (org-auto-scheduler--review-goto-task task-id)))))

(defun org-auto-scheduler--review-waiting-row-p (task-id)
  "Return non-nil if TASK-ID belongs to a waiting task in the review buffer."
  (and task-id
       (let ((marker (or (get-text-property (point) 'task-marker)
                         (org-id-find task-id t))))
         (and marker (markerp marker) (marker-buffer marker)
              (org-with-point-at marker
                (let ((state (org-get-todo-state)))
                  (and state (member state org-auto-scheduler-waiting-states))))))))

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
     ((org-auto-scheduler--review-waiting-row-p id1)
      (user-error "Cannot move WAITING task. Set state to TODO with 't' to schedule"))
     ((and id2 (string= id2 "__sep_Waiting"))
      (user-error "Cannot move across Waiting section separator"))
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
         ((org-auto-scheduler--review-waiting-row-p id1)
          (user-error "Cannot move WAITING task. Set state to TODO with 't' to schedule"))
         ((and id2 (string= id2 "__sep_Waiting"))
          (user-error "Cannot move scheduled tasks into Waiting section"))
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

(defun org-auto-scheduler-review-move-to-date (&optional arg)
  "Prompt for a date (and optional time if pinnable) and move the task at point.
If point is on a waiting task, prompt for a follow-up tickler date,
or clear it with prefix ARG (C-u d)."
  (interactive "P")
  "Prompt for a date (and optional time if pinnable) and move the task at point."
  (interactive)
  (let* ((task-id (tabulated-list-get-id))
         (current-day (org-auto-scheduler--review-get-task-day task-id)))
    (if (or (null task-id) (org-auto-scheduler--review-special-row-p task-id))
        (if (and task-id (string-prefix-p "__event_" task-id))
            (user-error "Cannot move fixed agenda event")
          (user-error "Not on a task"))
      (if (org-auto-scheduler--review-waiting-row-p task-id)
          (let* ((marker (or (get-text-property (point) 'task-marker)
                             (org-id-find task-id t)))
                 (headline (and marker (markerp marker) (marker-buffer marker)
                                (org-with-point-at marker (org-get-heading t t t t)))))
            (unless (and marker (markerp marker) (marker-buffer marker))
              (user-error "Cannot find original task for ID: %s" task-id))
            (org-auto-scheduler--review-push-undo)
            (if arg
                (progn
                  (with-current-buffer (marker-buffer marker)
                    (save-excursion
                      (goto-char marker)
                      (org-schedule '(4))))
                  (message "Cleared tickler date for waiting task '%s'." (or headline "")))
              (let* ((prompt (format "Set follow-up tickler date for '%s': "
                                     (org-auto-scheduler--truncate (or headline "task") 30)))
                     (date-input (org-read-date nil nil nil prompt))
                     (target-day (if (and date-input (>= (length date-input) 10))
                                     (substring date-input 0 10)
                                   date-input)))
                (with-current-buffer (marker-buffer marker)
                  (save-excursion
                    (goto-char marker)
                    (org-schedule nil target-day)))
                (message "Set follow-up tickler date to <%s> for '%s'." target-day (or headline ""))))
            (org-auto-scheduler-review-save-decisions t)
            (org-auto-scheduler-review-and-apply)
            (when (get-buffer "*Org Auto Scheduler Review*")
              (with-current-buffer "*Org Auto Scheduler Review*"
                (org-auto-scheduler--review-goto-task task-id))))
      (let* ((task (assoc task-id org-auto-scheduler-completed-tasks))
             (marker (and task (nth 7 task)))
             (is-pinnable (org-auto-scheduler-task-pinnable-p marker task-id))
             (prompt (if is-pinnable
                         (format "Move pinnable task to date/time (current: %s): " current-day)
                       (format "Move task to date (current: %s): " current-day)))
             (date-input (org-read-date is-pinnable nil nil prompt))
             (final-ans (or (bound-and-true-p org-read-date-final-answer) date-input))
             (has-time (string-match-p "[0-9]\\{2\\}:[0-9]\\{2\\}" final-ans))
             (target-day (if (and date-input (>= (length date-input) 10))
                             (substring date-input 0 10)
                           date-input))
             (today-str (format-time-string "%Y-%m-%d")))
        (when (string< target-day today-str)
          (user-error "Cannot schedule tasks in the past (before %s)" today-str))
        (let ((over (or (gethash task-id org-auto-scheduler--review-overrides)
                        (list :order nil :skipped nil))))
          (setq over (plist-put (plist-put over :target-date target-day)
                                :pinned-date target-day))
          (when (and is-pinnable has-time)
            (setq over (plist-put (plist-put over :pinnable t)
                                  :pinned-time final-ans)))
          (puthash task-id over org-auto-scheduler--review-overrides))
        (org-auto-scheduler-review-move-to-day target-day))))))

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

(defun org-auto-scheduler--format-waiting-review-entry (w-task today-str)
  "Format a waiting task plist W-TASK for display in the review buffer."
  (let* ((task-id (plist-get w-task :id))
         (marker (plist-get w-task :marker))
         (headline (plist-get w-task :headline))
         (state (or (plist-get w-task :state) "WAITING"))
         (days-waiting (plist-get w-task :days-waiting))
         (is-stale (and days-waiting (>= days-waiting org-auto-scheduler-waiting-stale-days)))
         (sched (plist-get w-task :scheduled))
         (dead (plist-get w-task :deadline))
         (project-name (or (plist-get w-task :project-name) "—"))
         (proj-trunc (org-auto-scheduler--truncate project-name 18))
         (proj-color (and org-auto-scheduler--project-colors
                          (gethash proj-trunc org-auto-scheduler--project-colors)))
         (checked "[ ]")
         (dot (org-auto-scheduler--project-dot proj-trunc))
         (state-prefix (propertize (format "[%s] " state)
                                   'face (if is-stale '(:inherit bold :foreground "#e5c07b") 'warning)))
         (display-headline (concat state-prefix (copy-sequence (or headline "Untitled"))))
         (time-str (cond
                    (sched
                     (let* ((cleaned (replace-regexp-in-string "[<>]" "" sched))
                            (is-past (condition-case nil
                                         (time-less-p (org-time-string-to-time sched)
                                                      (current-time))
                                       (error nil))))
                       (if is-past
                           (propertize (format "Ping: %s" cleaned) 'face '(:inherit bold :foreground "#e06c75"))
                         (propertize (format "Ping: %s" cleaned) 'face '(:inherit italic :foreground "#98c379")))))
                    (dead
                     (let ((cleaned (replace-regexp-in-string "[<>]" "" dead)))
                       (propertize (format "Due: %s" cleaned) 'face '(:inherit italic :foreground "#e5c07b"))))
                    (t
                     (propertize "No Follow-up" 'face 'shadow))))
         (dur-str (cond
                   ((and days-waiting (> days-waiting 0))
                    (if is-stale
                        (propertize (format "%dd ⚠️" days-waiting) 'face '(:inherit bold :foreground "#e5c07b"))
                      (format "%dd" days-waiting)))
                   (days-waiting "0d")
                   (t "—")))
         (colored-proj (cond
                        (proj-color (propertize (copy-sequence proj-trunc) 'face `(:foreground ,proj-color)))
                        ((string= proj-trunc "—") "")
                        (t (copy-sequence proj-trunc))))
         (colored-score (if is-stale
                            (propertize "STALE" 'face '(:inherit bold :foreground "#e06c75"))
                          (propertize "wait" 'face 'shadow)))
         (stat-str (if is-stale
                       (propertize "⚠️" 'face 'warning
                                   'help-echo (format "Waiting for %d days (threshold: %d)"
                                                      days-waiting org-auto-scheduler-waiting-stale-days))
                     (propertize "⏳" 'face '(:foreground "#e5c07b" :inherit bold)
                                 'help-echo "Waiting on external condition/person"))))
    (list task-id
          (vector (propertize checked 'task-marker marker) dot (propertize display-headline 'task-marker marker) time-str dur-str
                  colored-proj colored-score stat-str))))

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
         (is-pinned (org-auto-scheduler-task-pinned-p marker task-id))
         (is-freeset (org-auto-scheduler-task-freeset-p marker task-id))
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
                         ((eq status :blocked)
                          (let ((waiting-b (and marker (markerp marker) (marker-buffer marker)
                                                (org-auto-scheduler--get-waiting-blockers marker))))
                            (if waiting-b
                                (propertize "BLOCKED (WAITING)" 'face 'warning
                                            'help-echo (mapconcat #'identity (reverse all-warnings) "\n"))
                              (propertize "BLOCKED" 'face 'warning
                                          'help-echo (mapconcat #'identity (reverse all-warnings) "\n")))))
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
      (let ((badge-icons (concat
                          (when is-pinned (propertize "📌 " 'face '(:inherit bold :foreground "#e5c07b")))
                          (when is-freeset (propertize "⚡ " 'face '(:inherit bold :foreground "#61afef"))))))
        (setq display-headline (concat (org-auto-scheduler--format-depth-prefix
                                        depth
                                        (if (eq status :placeholder)
                                            (org-auto-scheduler--status-blend-color proj-color task marker)
                                          proj-color)
                                        blockers-info)
                                       badge-icons
                                       (cond
                                        (is-new
                                         (concat (propertize "[NEW] " 'face '(:inherit bold :foreground "#98c379"))
                                                 display-headline))
                                        (t display-headline)))))

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
  (let* ((all-items (if (and (boundp 'org-auto-scheduler--agenda-cache)
                             (hash-table-p org-auto-scheduler--agenda-cache))
                        (gethash date-str org-auto-scheduler--agenda-cache)
                      (let ((date-time (org-auto-scheduler-parse-time-string (concat date-str " 00:00"))))
                        (when date-time
                          (org-auto-scheduler-get-agenda-items date-time)))))
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

    ;; Waiting on Others (placed after all days and unscheduled tasks, at the very bottom)
    (let ((waiting-tasks (org-auto-scheduler-get-waiting-tasks)))
      (when waiting-tasks
        (let* ((stale-count (cl-count-if (lambda (w)
                                           (let ((d (plist-get w :days-waiting)))
                                             (and d (>= d org-auto-scheduler-waiting-stale-days))))
                                         waiting-tasks))
               (sep-title (format "-- Waiting on Others (%d task%s%s) "
                                  (length waiting-tasks)
                                  (if (= (length waiting-tasks) 1) "" "s")
                                  (if (> stale-count 0)
                                      (format ", %d STALE" stale-count)
                                    "")))
               (sep-line (concat sep-title (make-string (max 0 (- 50 (length sep-title))) ?-)))
               (sep-face (if (> stale-count 0) '(:inherit bold :foreground "#e5c07b") 'bold)))
          (push (list "__sep_Waiting"
                      (vector "" "" (propertize sep-line 'face sep-face)
                              "" "" "" "" ""))
                raw-entries)
          (dolist (w-task waiting-tasks)
            (push (org-auto-scheduler--format-waiting-review-entry w-task today-str) raw-entries)))))

    ;; Shortcuts banner at top
    (cons (list "__header_shortcuts"
                (vector "" "" (propertize "  [RET] toggle  [t] state  [s] split  [p] pin  [b] non-blocking  [K/J] reorder  [>/<] day  [d] date  [r] recalc  [S] save  [M] merge  [C] clear  [x] apply  [?] help" 'face 'shadow)
                        "" "" "" "" ""))
          (nreverse raw-entries))))

(defun org-auto-scheduler-review-recalculate (&optional arg)
  "Recalculate scheduled times based on visual order without resorting.
When `org-auto-scheduler-review-compact-schedule' is non-nil (default), tasks
pack continuously and automatically backfill into available earlier day slots.
With prefix ARG (C-u r), or when `org-auto-scheduler-review-compact-schedule' is nil,
tasks are constrained to start on or after their current day section."
  (interactive "P")
  (org-auto-scheduler--review-cancel-recalc-timer)
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
                  (let* ((task-pinned-time (org-auto-scheduler-task-pinned-time marker task-id))
                         (day-start (if (string= task-day today-str)
                                       (org-auto-scheduler-get-start-time)
                                     (org-auto-scheduler-time-with-time-string
                                      (org-auto-scheduler-parse-time-string (concat task-day " 00:00"))
                                      org-auto-scheduler-start-time))))
                    (if (and task-pinned-time
                             (string= (format-time-string "%Y-%m-%d" task-pinned-time) task-day))
                        (setq current-time task-pinned-time)
                      (when (time-less-p current-time day-start)
                        (setq current-time day-start))))))
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
  (org-auto-scheduler--with-active-operation 'review-apply
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
  (org-auto-scheduler-cleanup-placeholders t)
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
    (unwind-protect
        (progn
          (when org-auto-scheduler-review-auto-save-decisions
            (condition-case err
                (org-auto-scheduler-review-save-decisions t)
              (error
               (org-auto-scheduler--log-error "Failed to auto-save review decisions: %s" err))))
          (org-auto-scheduler-display-report)
          (message "Applied %d tasks from the auto-scheduler review!" applied-count))
      (kill-buffer (current-buffer)))
    (when (and org-auto-scheduler-sync-caldav
               (require 'org-caldav nil t))
      (condition-case err
          (org-caldav-sync)
        (error (message "CalDAV sync failed (review apply): %s" (error-message-string err))))))))

(defun org-auto-scheduler-review-and-apply ()
  "Calculate an auto-schedule in preview mode and display it for interactive review."
  (interactive)
  (org-auto-scheduler--with-active-operation 'review-prepare
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
    (switch-to-buffer buf))))

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
  "Toggle SPLITTABLE status of the task at point in the review buffer."
  (interactive)
  (unless (eq major-mode 'org-auto-scheduler-review-mode)
    (user-error "Not in an Org Auto Scheduler Review buffer"))
  (let* ((task-id (tabulated-list-get-id)))
    (cond
     ((or (null task-id) (org-auto-scheduler--review-special-row-p task-id))
      (if (and task-id (string-prefix-p "__event_" task-id))
          (user-error "Fixed agenda events cannot be marked splittable")
        (user-error "Not on a task")))
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
          (message "Task '%s' marked %s.%s"
                   headline
                   (if now-splittable "SPLITTABLE" "NOT splittable")
                   (if org-auto-scheduler-review-auto-recalculate-on-move ""
                     " Press 'r' to recalculate schedule."))
          (if org-auto-scheduler-review-auto-recalculate-on-move
              (org-auto-scheduler--review-maybe-auto-recalculate task-id)
            (tabulated-list-print t))))))))

(defun org-auto-scheduler-review-toggle-freeset ()
  "Toggle FREESET status of the task at point in the review buffer.
When marked FREESET, the task can be freely rescheduled in the timegrid
and table view review buffers without considering day working hours,
and if it goes beyond midnight, splits to the next day."
  (interactive)
  (unless (eq major-mode 'org-auto-scheduler-review-mode)
    (user-error "Not in an Org Auto Scheduler Review buffer"))
  (let* ((task-id (tabulated-list-get-id)))
    (cond
     ((or (null task-id) (org-auto-scheduler--review-special-row-p task-id))
      (if (and task-id (string-prefix-p "__event_" task-id))
          (user-error "Fixed agenda events cannot be marked freeset")
        (user-error "Not on a task")))
     (t
      (let* ((task-data (assoc task-id org-auto-scheduler-completed-tasks))
             (raw-marker (and task-data (nth 7 task-data)))
             (marker (org-auto-scheduler--resolve-task-marker raw-marker task-id))
             (headline (if task-data (nth 5 task-data) "Task"))
             (status (and task-data (nth 9 task-data))))
        (when (eq status :placeholder)
          (user-error "Cannot set a placeholder chunk; set the parent task"))
        (org-auto-scheduler--review-push-undo)
        (let ((now-freeset (org-auto-scheduler-task-toggle-freeset marker task-id)))
          (message "Task '%s' marked %s.%s"
                   headline
                   (if now-freeset "FREESET" "NOT freeset")
                   (if org-auto-scheduler-review-auto-recalculate-on-move ""
                     " Press 'r' to recalculate schedule."))
          (if org-auto-scheduler-review-auto-recalculate-on-move
              (org-auto-scheduler--review-maybe-auto-recalculate task-id)
            (tabulated-list-print t))))))))

(defalias 'org-auto-scheduler-review-toggle-pinnable 'org-auto-scheduler-review-toggle-freeset)

(defun org-auto-scheduler-review-pin-task (&optional arg)
  "Pin the task at point to an exact scheduled date/time (prompted).
Defaults to the task's currently scheduled time in the preview review buffer.
With prefix ARG (C-u p) or empty input, unpins the task."
  (interactive "P")
  (unless (eq major-mode 'org-auto-scheduler-review-mode)
    (user-error "Not in an Org Auto Scheduler Review buffer"))
  (let* ((task-id (tabulated-list-get-id)))
    (cond
     ((or (null task-id) (org-auto-scheduler--review-special-row-p task-id))
      (if (and task-id (string-prefix-p "__event_" task-id))
          (user-error "Fixed agenda events cannot be pinned")
        (user-error "Not on a task")))
     (t
      (let* ((task-data (assoc task-id org-auto-scheduler-completed-tasks))
             (raw-marker (and task-data (nth 7 task-data)))
             (marker (org-auto-scheduler--resolve-task-marker raw-marker task-id))
             (headline (if task-data (nth 5 task-data) "Task"))
             (status (and task-data (nth 9 task-data))))
        (when (eq status :placeholder)
          (user-error "Cannot pin a placeholder chunk; pin the parent task"))
        (if arg
            (progn
              (org-auto-scheduler--review-push-undo)
              (org-auto-scheduler-task-set-pinned-time marker task-id nil t)
              (message "Task '%s' unpinned." headline)
              (org-auto-scheduler--review-maybe-auto-recalculate task-id))
          (let* ((curr-start (and task-data (nth 1 task-data)))
                 (default-time-str (if curr-start
                                       (format-time-string "%Y-%m-%d %H:%M" curr-start)
                                     (format-time-string "%Y-%m-%d %H:%M")))
                 (prompt (format "Pin task to date/time (default %s, empty to unpin): " default-time-str))
                 (date-input (org-read-date t nil nil prompt nil default-time-str))
                 (final-ans (or (bound-and-true-p org-read-date-final-answer) date-input)))
            (org-auto-scheduler--review-push-undo)
            (if (or (null final-ans) (string-empty-p (string-trim final-ans)))
                (progn
                  (org-auto-scheduler-task-set-pinned-time marker task-id nil t)
                  (message "Task '%s' unpinned." headline))
              (let ((formatted (org-auto-scheduler-task-set-pinned-time marker task-id final-ans)))
                (message "Task '%s' pinned to %s." headline formatted)))
            (org-auto-scheduler--review-maybe-auto-recalculate task-id))))))))
(defun org-auto-scheduler-review-undo ()
  "Undo the last modification in the review buffer."
  (interactive)
  (org-auto-scheduler--review-cancel-recalc-timer)
  (if (null org-auto-scheduler--review-undo-stack)
      (user-error "No further undo information")
    (let ((snapshot (pop org-auto-scheduler--review-undo-stack)))
      (if (and (listp snapshot) (plist-member snapshot :entries))
          (progn
            (setq tabulated-list-entries (plist-get snapshot :entries))
            (when (plist-get snapshot :all-entries)
              (setq org-auto-scheduler--review-all-entries (plist-get snapshot :all-entries)))
            (when (plist-get snapshot :overrides)
              (setq org-auto-scheduler--review-overrides (plist-get snapshot :overrides)))
            (when (plist-get snapshot :completed-tasks)
              (setq org-auto-scheduler-completed-tasks (plist-get snapshot :completed-tasks))))
        ;; Legacy snapshot format (plain entries list)
        (setq tabulated-list-entries snapshot))
      (setq org-auto-scheduler--pinned-cache nil)
      (tabulated-list-print t)
      (setq header-line-format
            (org-auto-scheduler--review-header-line tabulated-list-entries))
      (org-auto-scheduler--timegrid-maybe-refresh)
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
      (let* ((task (assoc id org-auto-scheduler-completed-tasks))
             (status (and task (nth 9 task))))
        (when (eq status :placeholder)
          (let ((origin-id (or (cadr (memq :origin-id task))
                               (plist-get (nthcdr 9 task) :origin-id))))
            (if (and origin-id (assoc origin-id org-auto-scheduler-completed-tasks))
                (setq id origin-id
                      entry (cadr (assoc id tabulated-list-entries)))
              (user-error "Cannot edit effort of a placeholder chunk; edit the parent task")))))
      (org-auto-scheduler--review-push-undo)
      (puthash id (plist-put (gethash id org-auto-scheduler--review-overrides) :effort new-effort)
               org-auto-scheduler--review-overrides)
      (when entry
        (aset entry 4 (propertize (format "%dm*" new-effort) 'face 'warning)))
      (when-let* ((all-entry (cadr (assoc id org-auto-scheduler--review-all-entries))))
        (unless (eq all-entry entry)
          (aset all-entry 4 (propertize (format "%dm*" new-effort) 'face 'warning))))
      (tabulated-list-print t)
      (message "Effort updated to %d min (press 'r' to recalculate schedule)" new-effort))))

(defun org-auto-scheduler-review-chop (&optional minutes-today)
  "Chop the task at point into a today chunk and defer the rest to subsequent days.
Prompts for MINUTES-TODAY (default: half of current effort).
The remaining effort is scheduled for subsequent days via splittable placeholder logic."
  (interactive)
  (unless (eq major-mode 'org-auto-scheduler-review-mode)
    (user-error "Not in an Org Auto Scheduler Review buffer"))
  (let* ((task-id (tabulated-list-get-id)))
    (when (or (null task-id) (org-auto-scheduler--review-special-row-p task-id))
      (if (and task-id (string-prefix-p "__event_" task-id))
          (user-error "Fixed agenda events cannot be chopped")
        (user-error "Not on a task")))
    (let* ((task-data (assoc task-id org-auto-scheduler-completed-tasks))
           (status (and task-data (nth 9 task-data))))
      (when (eq status :placeholder)
        (user-error "Cannot chop a placeholder chunk; chop the parent task instead"))
      (let* ((raw-marker (and task-data (nth 7 task-data)))
             (marker (org-auto-scheduler--resolve-task-marker raw-marker task-id))
             (headline (if task-data (nth 5 task-data) "Task"))
             (current-effort (or (org-auto-scheduler-get-effort marker) 60)))
        (when (<= current-effort 15)
          (user-error "Task effort is too short to chop (%d min)" current-effort))
        (let* ((default-split (max 10 (* 5 (round (/ (/ current-effort 2.0) 5.0)))))
               (prompt (format "Keep today for '%s' (e.g. 45m or 1:00, current %dm, default %dm): "
                               headline current-effort default-split))
               (input (if minutes-today
                          (if (numberp minutes-today)
                              (number-to-string minutes-today)
                            minutes-today)
                        (read-string prompt nil nil (number-to-string default-split))))
               (keep-today (let ((parsed (condition-case nil (org-duration-to-minutes input) (error nil))))
                             (if (and parsed (> parsed 0))
                                 parsed
                               (string-to-number input)))))
          (unless (and (numberp keep-today) (> keep-today 0) (< keep-today current-effort))
            (user-error "Invalid chop duration: must be between 1 and %d minutes" (1- current-effort)))
          (setq keep-today (round keep-today))
          (let ((rem-effort (- current-effort keep-today)))
            (org-auto-scheduler--review-push-undo)
            ;; Mark parent task as splittable
            (when (and marker (markerp marker) (marker-buffer marker))
              (org-with-point-at marker
                (unless (or (member org-auto-scheduler-splittable-tag (org-get-tags))
                            (org-entry-get nil "SPLITTABLE"))
                  (org-toggle-tag org-auto-scheduler-splittable-tag 'on)
                  (org-set-property "SPLITTABLE" "t"))))
            ;; Record override for review recalculation
            (let ((over (or (gethash task-id org-auto-scheduler--review-overrides)
                            (list :order nil :skipped nil))))
              (setq over (plist-put over :chop-today keep-today))
              (setq over (plist-put over :splittable t))
              (puthash task-id over org-auto-scheduler--review-overrides))
            (message "Chopped '%s': %dm kept today, %dm deferred to subsequent days."
                     headline keep-today rem-effort)
            (if org-auto-scheduler-review-auto-recalculate-on-move
                (org-auto-scheduler--review-maybe-auto-recalculate task-id)
              (tabulated-list-print t))))))))

;;; What-If Diff Buffer

(defvar org-auto-scheduler-diff-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (define-key map (kbd "q") #'quit-window)
    (define-key map (kbd "RET") #'org-auto-scheduler-diff-jump-to-review)
    (define-key map (kbd "TAB") #'org-auto-scheduler-diff-jump-to-review)
    map)
  "Keymap for `org-auto-scheduler-diff-mode'.")

(define-derived-mode org-auto-scheduler-diff-mode special-mode "AutoSch-Diff"
  "Major mode for inspecting the What-If schedule diff against disk state."
  (setq buffer-read-only t))

(defun org-auto-scheduler-diff-jump-to-review ()
  "Jump to the corresponding task in the review buffer from the diff buffer."
  (interactive)
  (let ((tid (get-text-property (point) 'task-id))
        (src-buf (bound-and-true-p org-auto-scheduler--diff-source-buffer)))
    (if (and tid src-buf (buffer-live-p src-buf))
        (let ((win (get-buffer-window src-buf)))
          (if win
              (select-window win)
            (pop-to-buffer src-buf))
          (org-auto-scheduler--review-goto-task tid))
      (user-error "No review task link at point"))))

(defun org-auto-scheduler-review-diff ()
  "Display a What-If diff comparing active schedule on disk against proposed review schedule."
  (interactive)
  (let* ((diff-buf (get-buffer-create "*Org Auto Scheduler Diff*"))
         (source-buf (current-buffer))
         (moved-count 0)
         (new-count 0)
         (skipped-count 0)
         (unchanged-count 0)
         (diff-lines '()))
    (dolist (item org-auto-scheduler-completed-tasks)
      (let* ((task-id (nth 0 item))
             (proposed-start (nth 1 item))
             (proposed-end (nth 2 item))
             (headline (nth 5 item))
             (status (nth 9 item))
             (marker (nth 7 item))
             (is-placeholder (eq status :placeholder))
             (is-skipped (eq status :skipped)))
        (unless (or (string-prefix-p "__sep_" (or task-id ""))
                    (string-prefix-p "__event_" (or task-id "")))
          (let* ((orig-sched (when (and marker (markerp marker) (marker-buffer marker))
                               (org-with-point-at marker
                                 (org-entry-get nil "SCHEDULED"))))
                 (orig-clean (when orig-sched (string-trim orig-sched)))
                 (prop-range (when (and proposed-start proposed-end)
                               (org-auto-scheduler--format-time-range proposed-start proposed-end))))
            (cond
             (is-skipped
              (cl-incf skipped-count)
              (push (list :type 'skipped
                          :task-id task-id
                          :text (format "- %-36s %s (SKIPPED / UNCHECKED)
"
                                        (truncate-string-to-width headline 36 nil nil "…")
                                        (or orig-clean "Unscheduled")))
                    diff-lines))
             (is-placeholder
              (cl-incf new-count)
              (push (list :type 'new
                          :task-id task-id
                          :text (format "+ %-36s %s (SPLIT/PLACEHOLDER CHUNK)
"
                                        (truncate-string-to-width headline 36 nil nil "…")
                                        (or prop-range "")))
                    diff-lines))
             ((null orig-clean)
              (cl-incf new-count)
              (push (list :type 'new
                          :task-id task-id
                          :text (format "+ %-36s %s (NEWLY SCHEDULED)
"
                                        (truncate-string-to-width headline 36 nil nil "…")
                                        (or prop-range "")))
                    diff-lines))
             ((org-auto-scheduler--timestamps-equal-p orig-clean prop-range)
              (cl-incf unchanged-count)
              (push (list :type 'unchanged
                          :task-id task-id
                          :text (format "  %-36s %s (UNCHANGED)
"
                                        (truncate-string-to-width headline 36 nil nil "…")
                                        orig-clean))
                    diff-lines))
             (t
              (cl-incf moved-count)
              (push (list :type 'moved
                          :task-id task-id
                          :text (format "- %-36s %s
+ %-36s %s (MOVED)
"
                                        (truncate-string-to-width headline 36 nil nil "…")
                                        orig-clean
                                        (truncate-string-to-width headline 36 nil nil "…")
                                        prop-range))
                    diff-lines)))))))
    (setq diff-lines (nreverse diff-lines))
    (with-current-buffer diff-buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (org-auto-scheduler-diff-mode)
        (setq-local org-auto-scheduler--diff-source-buffer source-buf)
        ;; Header
        (insert "================================================================================
")
        (insert " Org Auto Scheduler: Proposed What-If Schedule Diff
")
        (insert "================================================================================
")
        (insert (format " Summary: %d moved, %d new, %d skipped, %d unchanged (%d total evaluated)
"
                        moved-count new-count skipped-count unchanged-count
                        (+ moved-count new-count skipped-count unchanged-count)))
        (insert " Keys: [q] Close diff buffer  |  [RET/TAB] Jump to task in review
")
        (insert "--------------------------------------------------------------------------------

")
        ;; Diff entries
        (dolist (item diff-lines)
          (let ((start (point))
                (type (plist-get item :type))
                (text (plist-get item :text))
                (tid (plist-get item :task-id)))
            (insert text)
            (put-text-property start (point) 'task-id tid)
            (cond
             ((eq type 'moved)
              (add-face-text-property start (point) 'diff-changed nil))
             ((eq type 'new)
              (add-face-text-property start (point) 'diff-added nil))
             ((eq type 'skipped)
              (add-face-text-property start (point) 'diff-removed nil))
             ((eq type 'unchanged)
              (add-face-text-property start (point) 'shadow nil))))))
      (goto-char (point-min)))
    (display-buffer diff-buf)))

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
matching the display used in the review buffer."
  (let ((start (nth 1 ev))
        (end (nth 2 ev)))
    (when (and start end (time-less-p start end))
      (let* ((ev-id (nth 0 ev))
             (headline (or (nth 5 ev) "Event"))
             (marker (or (nth 7 ev)
                         (and ev-id (stringp ev-id)
                              (not (string-prefix-p "__event_" ev-id))
                              (org-id-find ev-id))))
             (non-blocking (org-auto-scheduler-task-non-blocking-p ev-id marker))
             (title (if non-blocking headline (format "🔒 %s" headline))))
        (org-timegrid-event-create
         :id (format "org-auto-scheduler-event-%s" (or ev-id (sxhash ev)))
         :title title
         :start (org-auto-scheduler--timegrid-minutes start)
         :end (org-auto-scheduler--timegrid-minutes end)
         :all-day nil
         :color (if non-blocking "#98c379" "#5c6370")
         :source (list :marker marker :task-id ev-id :event-id ev-id :event-p t))))))

(defun org-auto-scheduler--timegrid-list (review-buffer start end)
  "Return org-timegrid events for the schedule in REVIEW-BUFFER.
Reads the review buffer's live `tabulated-list-entries' (so the row
set and visual order are always current) joined with
`org-auto-scheduler-completed-tasks' for timing, plus fixed agenda
events when `org-auto-scheduler-review-show-agenda-events' is enabled.
START and END are absolute minutes, as required by an
`org-timegrid-backend' list-function."
  (when (and review-buffer (buffer-live-p review-buffer))
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
      (append task-events event-events))))

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
    ;; If the task is PINNED or FREESET, record new-start as its target time in review overrides
    (let* ((task (assoc task-id org-auto-scheduler-completed-tasks))
           (marker (and task (nth 7 task)))
           (is-pinned (org-auto-scheduler-task-pinned-p marker task-id))
           (is-freeset (org-auto-scheduler-task-freeset-p marker task-id)))
      (when (or is-pinned is-freeset)
        (let ((over (or (gethash task-id org-auto-scheduler--review-overrides)
                        (list :order nil :skipped nil :target-date new-day))))
          (puthash task-id
                   (plist-put (plist-put over :pinned-time (format-time-string "%Y-%m-%d %H:%M" new-start))
                              :pinned (or is-pinned t))
                   org-auto-scheduler--review-overrides))))
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
`org-auto-scheduler--timegrid-update' -- and delegating undo to REVIEW-BUFFER, but no
create/delete, so new-entry gestures and deletion still cleanly no-op with an error."
  (org-timegrid-backend-create
   :name "org-auto-scheduler proposed schedule"
   :list-function (lambda (start end)
                    (org-auto-scheduler--timegrid-list review-buffer start end))
   :update-function (lambda (event start end &rest args)
                      (apply #'org-auto-scheduler--timegrid-update
                             review-buffer event start end args))
   :undo-function (lambda (_continue redo)
                    (unless (and review-buffer (buffer-live-p review-buffer))
                      (user-error "The source review buffer no longer exists"))
                    (with-current-buffer review-buffer
                      (if redo
                          (user-error "Redo is not supported; use review commands")
                        (org-auto-scheduler-review-undo))))
   :visit-function #'org-auto-scheduler--timegrid-visit))

(defun org-auto-scheduler--timegrid-maybe-refresh ()
  "Refresh the live `*Org Time Grid*' buffer, if one is visible, in place.
Called after table-view edits (toggle, move, recalculate) so the grid
reflects the latest checkbox/order state without waiting on its own
periodic timer or a manual `g'."
  (when (and (bound-and-true-p org-timegrid-buffer-name)
             (let ((buf (get-buffer org-timegrid-buffer-name)))
               (and buf (get-buffer-window buf t))))
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

(defun org-auto-scheduler--timegrid-selected-task-id ()
  "Return the task ID for the currently selected block or block at cursor in the timegrid."
  (when-let* ((block (or (and (fboundp 'org-timegrid--block-at-cursor)
                              (ignore-errors (org-timegrid--block-at-cursor)))
                         (and (fboundp 'org-timegrid--selected-id)
                              (org-timegrid--selected-id)
                              (fboundp 'org-timegrid--block)
                              (org-timegrid--block (org-timegrid--selected-id)))))
              (event (org-timegrid-block-event block))
              (source (and event (org-timegrid-event-source event))))
    (plist-get source :task-id)))

(defun org-auto-scheduler--timegrid-jump ()
  "Jump to the original Org task or agenda event for the selected timegrid block."
  (interactive)
  (let* ((block (or (and (fboundp 'org-timegrid--block-at-cursor)
                         (ignore-errors (org-timegrid--block-at-cursor)))
                    (and (fboundp 'org-timegrid--selected-id)
                         (org-timegrid--selected-id)
                         (fboundp 'org-timegrid--block)
                         (org-timegrid--block (org-timegrid--selected-id)))))
         (event (and block (org-timegrid-block-event block))))
    (unless event
      (user-error "No task selected; press n or click a task block first"))
    (org-auto-scheduler--timegrid-visit event)))

(defun org-auto-scheduler--review-goto-event (marker &optional event-id)
  "Move point to the row for MARKER or EVENT-ID in the review buffer."
  (let ((orig-point (point))
        (found nil))
    (goto-char (point-min))
    (while (and (not (eobp)) (not found))
      (let* ((row-id (tabulated-list-get-id))
             (entry (tabulated-list-get-entry)))
        (when (and row-id (string-prefix-p "__event_" row-id) entry)
          (let ((m (or (get-text-property 0 'event-marker (aref entry 2))
                       (get-text-property 0 'event-marker (aref entry 1))))
                (eid (or (get-text-property 0 'event-id (aref entry 2))
                         (get-text-property 0 'event-id (aref entry 1)))))
            (when (or (and marker m (equal marker m))
                      (and event-id eid (equal event-id eid)))
              (setq found t)))))
      (unless found
        (forward-line 1)))
    (unless found
      (goto-char orig-point))))

(defun org-auto-scheduler--timegrid-run-review-command (cmd &optional needs-task)
  "Execute review command CMD in the linked review buffer.
When NEEDS-TASK is non-nil, signals a `user-error' if no task is selected or at cursor."
  (interactive)
  (unless (and org-auto-scheduler--timegrid-source-buffer
               (buffer-live-p org-auto-scheduler--timegrid-source-buffer))
    (user-error "No linked Org Auto Scheduler review buffer"))
  (let* ((block (or (and (fboundp 'org-timegrid--block-at-cursor)
                         (ignore-errors (org-timegrid--block-at-cursor)))
                    (and (fboundp 'org-timegrid--selected-id)
                         (org-timegrid--selected-id)
                         (fboundp 'org-timegrid--block)
                         (org-timegrid--block (org-timegrid--selected-id)))))
         (event (and block (org-timegrid-block-event block)))
         (source (and event (org-timegrid-event-source event)))
         (task-id (and source (plist-get source :task-id)))
         (marker (and source (plist-get source :marker)))
         (event-p (and source (plist-get source :event-p)))
         (review-buf org-auto-scheduler--timegrid-source-buffer))
    (when (and needs-task (not task-id) (not marker))
      (user-error "No task selected; press n or click a task block first"))
    (with-current-buffer review-buf
      (if event-p
          (org-auto-scheduler--review-goto-event marker task-id)
        (when task-id
          (org-auto-scheduler--review-goto-task task-id)))
      (call-interactively cmd))
    (org-auto-scheduler--timegrid-maybe-refresh)))

(defun org-auto-scheduler--timegrid-setup-keymap ()
  "Set up unified Auto-Scheduler shortcuts in the current `*Org Time Grid*' buffer.
Leaves default `org-timegrid' navigation keys (n, p, b, f, SPC, u) untouched,
while ensuring Evil motion/normal states do not intercept navigation (e.g. n, b, f, j, .)."
  (use-local-map (copy-keymap (or (current-local-map) (make-sparse-keymap))))
  (let ((bindings
         (list
          (cons "n"       #'org-timegrid-next-block)
          (cons "p"       #'org-timegrid-previous-block)
          (cons "b"       #'org-timegrid-backward-day)
          (cons "f"       #'org-timegrid-forward-day)
          (cons "j"       #'org-timegrid-goto-date)
          (cons "."       #'org-timegrid-goto-today)
          (cons "g"       #'org-timegrid-refresh)
          (cons "q"       #'quit-window)
          (cons "T"       #'org-auto-scheduler-review-close-timegrid)
          (cons "i"       #'org-auto-scheduler-review-toggle-timegrid-layout)
          (cons "TAB"     #'org-auto-scheduler--timegrid-jump)
          (cons "RET"     (lambda () (interactive) (org-auto-scheduler--timegrid-run-review-command #'org-auto-scheduler-review-toggle t)))
          (cons "m"       (lambda () (interactive) (org-auto-scheduler--timegrid-run-review-command #'org-auto-scheduler-review-toggle t)))
          (cons "s"       (lambda () (interactive) (org-auto-scheduler--timegrid-run-review-command #'org-auto-scheduler-review-toggle-splittable t)))
          (cons "F"       (lambda () (interactive) (org-auto-scheduler--timegrid-run-review-command #'org-auto-scheduler-review-toggle-freeset t)))
          (cons "B"       (lambda () (interactive) (org-auto-scheduler--timegrid-run-review-command #'org-auto-scheduler-review-toggle-non-blocking t)))
          (cons "P"       (lambda () (interactive) (org-auto-scheduler--timegrid-run-review-command #'org-auto-scheduler-review-pin-task t)))
          (cons "e"       (lambda () (interactive) (org-auto-scheduler--timegrid-run-review-command #'org-auto-scheduler-review-edit-effort t)))
          (cons "O"       (lambda () (interactive) (org-auto-scheduler--timegrid-run-review-command #'org-auto-scheduler-review-move-before t)))
          (cons "d"       (lambda () (interactive) (org-auto-scheduler--timegrid-run-review-command #'org-auto-scheduler-review-move-to-date t)))
          (cons "U"       (lambda () (interactive) (org-auto-scheduler--timegrid-run-review-command #'org-auto-scheduler-review-undo)))
          (cons "K"       (lambda () (interactive) (org-auto-scheduler--timegrid-run-review-command #'org-auto-scheduler-review-move-up t)))
          (cons "J"       (lambda () (interactive) (org-auto-scheduler--timegrid-run-review-command #'org-auto-scheduler-review-move-down t)))
          (cons "D"       (lambda () (interactive) (org-auto-scheduler--timegrid-run-review-command #'org-auto-scheduler-review-move-down t)))
          (cons ">"       (lambda () (interactive) (org-auto-scheduler--timegrid-run-review-command #'org-auto-scheduler-review-move-day-forward t)))
          (cons "+"       (lambda () (interactive) (org-auto-scheduler--timegrid-run-review-command #'org-auto-scheduler-review-move-day-forward t)))
          (cons "<"       (lambda () (interactive) (org-auto-scheduler--timegrid-run-review-command #'org-auto-scheduler-review-move-day-backward t)))
          (cons "-"       (lambda () (interactive) (org-auto-scheduler--timegrid-run-review-command #'org-auto-scheduler-review-move-day-backward t)))
          (cons "r"       (lambda () (interactive) (org-auto-scheduler--timegrid-run-review-command #'org-auto-scheduler-review-recalculate)))
          (cons "C-c C-r" (lambda () (interactive) (org-auto-scheduler--timegrid-run-review-command #'org-auto-scheduler-review-recalculate)))
          (cons "R"       (lambda () (interactive) (org-auto-scheduler--timegrid-run-review-command #'org-auto-scheduler-review-refresh)))
          (cons "x"       (lambda () (interactive) (org-auto-scheduler--timegrid-run-review-command #'org-auto-scheduler-review-execute)))
          (cons "C-c C-c" (lambda () (interactive) (org-auto-scheduler--timegrid-run-review-command #'org-auto-scheduler-review-execute)))
          (cons "S"       (lambda () (interactive) (org-auto-scheduler--timegrid-run-review-command #'org-auto-scheduler-review-save-decisions)))
          (cons "C-c C-s" (lambda () (interactive) (org-auto-scheduler--timegrid-run-review-command #'org-auto-scheduler-review-save-decisions)))
          (cons "M"       (lambda () (interactive) (org-auto-scheduler--timegrid-run-review-command #'org-auto-scheduler-review-restore-and-merge)))
          (cons "C-c C-m" (lambda () (interactive) (org-auto-scheduler--timegrid-run-review-command #'org-auto-scheduler-review-restore-and-merge)))
          (cons "C"       (lambda () (interactive) (org-auto-scheduler--timegrid-run-review-command #'org-auto-scheduler-clear-saved-decisions)))
          (cons "C-c C-d" (lambda () (interactive) (org-auto-scheduler--timegrid-run-review-command #'org-auto-scheduler-clear-saved-decisions)))
          (cons "E"       (lambda () (interactive) (org-auto-scheduler--timegrid-run-review-command #'org-auto-scheduler-review-toggle-agenda-events)))
          (cons "?"       (lambda () (interactive) (org-auto-scheduler--timegrid-run-review-command #'org-auto-scheduler-review-help))))))
    (dolist (b bindings)
      (local-set-key (kbd (car b)) (cdr b))
      (when (and (featurep 'evil) (fboundp 'evil-local-set-key))
        (evil-local-set-key 'motion (kbd (car b)) (cdr b))
        (evil-local-set-key 'normal (kbd (car b)) (cdr b))))))

(defun org-auto-scheduler--timegrid-apply-layout (review-buffer grid-buffer layout &optional target-day)
  "Configure windows and displayed days for REVIEW-BUFFER and GRID-BUFFER using LAYOUT.
LAYOUT may be `side-by-side' (grid on left with
`org-auto-scheduler-review-timegrid-side-by-side-days' days, review table on right)
or `horizontal' (grid above with `org-auto-scheduler-review-timegrid-horizontal-days'
days, review table below).
TARGET-DAY is an optional calendar absolute day to start/anchor the visible range."
  (let* ((orig-window (selected-window))
         (frame (or (and (window-live-p orig-window) (window-frame orig-window))
                    (selected-frame)))
         (active-layout (or layout org-auto-scheduler-review-timegrid-layout 'horizontal))
         (num-days (if (eq active-layout 'side-by-side)
                       org-auto-scheduler-review-timegrid-side-by-side-days
                     (or org-auto-scheduler-review-timegrid-horizontal-days 7)))
         ;; Determine anchor day
         (anchor-day
          (or target-day
              (with-current-buffer grid-buffer
                (and (boundp 'org-timegrid--state) org-timegrid--state
                     (fboundp 'org-timegrid--calendar-state-week-start)
                     (let* ((ws (org-timegrid--calendar-state-week-start org-timegrid--state))
                            (cursor (and (fboundp 'org-timegrid--cursor) (org-timegrid--cursor)))
                            (cday (and cursor (fboundp 'org-timegrid--cursor-state-day)
                                       (ignore-errors (org-timegrid--cursor-state-day cursor)))))
                       (if (numberp cday)
                           (+ ws cday)
                         ws))))
              (with-current-buffer review-buffer
                (let* ((task-day (org-auto-scheduler--review-get-task-day))
                       (time (when task-day (org-auto-scheduler-parse-time-string (concat task-day " 12:00")))))
                  (if time
                      (calendar-absolute-from-gregorian
                       (let ((decoded (decode-time time)))
                         (list (nth 4 decoded) (nth 3 decoded) (nth 5 decoded))))
                    (calendar-absolute-from-gregorian (calendar-current-date)))))))
         (start-day
          (if (eq active-layout 'horizontal)
              (if (fboundp 'org-timegrid-week-start)
                  (org-timegrid-week-start anchor-day)
                anchor-day)
            anchor-day)))
    ;; Record layout in both buffers
    (with-current-buffer review-buffer
      (setq org-auto-scheduler--timegrid-current-layout active-layout))
    (with-current-buffer grid-buffer
      (setq org-auto-scheduler--timegrid-current-layout active-layout)
      (setq-local org-timegrid-days num-days)
      (when (fboundp 'org-timegrid--load-state)
        (setq-local org-timegrid--state (org-timegrid--load-state start-day))
        (when (fboundp 'org-timegrid--refresh)
          (org-timegrid--refresh t))))
    ;; Arrange windows deterministically in frame
    (let ((review-window (get-buffer-window review-buffer frame)))
      (unless (and review-window (window-live-p review-window))
        (setq review-window (if (eq (window-buffer orig-window) grid-buffer)
                                (let ((alt (delq orig-window (window-list frame))))
                                  (or (car alt) orig-window))
                              orig-window))
        (set-window-buffer review-window review-buffer))
      ;; Remove any other windows showing grid-buffer in this frame
      (let ((existing-grids (delq review-window (get-buffer-window-list grid-buffer nil frame))))
        (dolist (w existing-grids)
          (when (and (window-live-p w) (> (length (window-list frame)) 1))
            (ignore-errors (delete-window w)))))
      ;; Now split review-window into review-window and grid-window
      (let* ((split-side (if (eq active-layout 'side-by-side) 'left 'above))
             (grid-window (condition-case nil
                              (split-window review-window nil split-side)
                            (error
                             (condition-case nil
                                 (if (eq split-side 'left)
                                     (split-window review-window nil 'above)
                                   (split-window review-window nil 'left))
                               (error review-window))))))
        (set-window-buffer grid-window grid-buffer)
        (set-window-buffer review-window review-buffer)
        (with-selected-window grid-window
          (org-auto-scheduler--timegrid-sync-week-range))
        ;; Preserve focus on whichever buffer initiated the layout change
        (if (eq (window-buffer orig-window) grid-buffer)
            (select-window grid-window)
          (select-window review-window))))))

(defun org-auto-scheduler--timegrid-open-fresh (review-buffer &optional layout)
  "Do the actual work of opening/refreshing the timegrid for REVIEW-BUFFER.
Uses LAYOUT (or `org-auto-scheduler-review-timegrid-layout') to configure
window arrangement and the number of displayed days.
Split out from `org-auto-scheduler-review-open-timegrid' so that
command can check for the toggle-off case first without duplicating
this setup.  Callable only after that command's own checks have
confirmed the integration is enabled and org-timegrid is loaded."
  (unless (and (boundp 'org-auto-scheduler--pinned-cache) (hash-table-p org-auto-scheduler--pinned-cache))
    (org-auto-scheduler--build-pinned-cache))
  (let* ((active-layout (or layout org-auto-scheduler-review-timegrid-layout 'horizontal))
         (backend (org-auto-scheduler--timegrid-backend review-buffer))
         (task-day (with-current-buffer review-buffer (org-auto-scheduler--review-get-task-day)))
         (task-time (when task-day (org-auto-scheduler-parse-time-string (concat task-day " 12:00"))))
         (reference-time (or task-time
                             (cl-some (lambda (tk) (nth 1 tk)) org-auto-scheduler-completed-tasks)
                             (current-time)))
         (ref-abs-day (calendar-absolute-from-gregorian
                       (let ((decoded (decode-time reference-time)))
                         (list (nth 4 decoded) (nth 3 decoded) (nth 5 decoded))))))
    (org-timegrid-open backend ref-abs-day)
    (with-current-buffer org-timegrid-buffer-name
      (setq org-auto-scheduler--timegrid-source-buffer review-buffer)
      (org-auto-scheduler--timegrid-setup-keymap))
    (let ((grid-buffer (get-buffer org-timegrid-buffer-name)))
      (org-auto-scheduler--timegrid-apply-layout review-buffer grid-buffer active-layout ref-abs-day))))

(defun org-auto-scheduler--timegrid-close (review-buffer grid-window)
  "Return focus to REVIEW-BUFFER and close GRID-WINDOW.
Shared by `org-auto-scheduler-review-close-timegrid' (called with point
already in the grid, so GRID-WINDOW is `selected-window') and the `T'
toggle-off path in `org-auto-scheduler-review-open-timegrid' (called
with point in the table, so GRID-WINDOW is looked up explicitly).  The
grid never mutates the review buffer beyond what dragging already
applied directly, so nothing else needs to be restored -- the table's
checkboxes, order, and overrides are exactly as they were left."
  (if (and review-buffer (buffer-live-p review-buffer))
      (let ((review-window (get-buffer-window review-buffer (window-frame grid-window))))
        (if (and review-window (not (eq review-window grid-window)))
            (progn
              (select-window review-window)
              (when (window-live-p grid-window)
                (ignore-errors (delete-window grid-window))))
          (switch-to-buffer review-buffer)))
    ;; Cleanly close or delete the grid window if the review buffer is dead
    (if (and (window-live-p grid-window) (> (length (window-list)) 1))
        (delete-window grid-window)
      (quit-window t grid-window))))

(defun org-auto-scheduler-review-close-timegrid ()
  "Return focus to the review table and close the timegrid split.
Bound to `T' inside `*Org Time Grid*' when it was opened from a review
buffer."
  (interactive)
  (org-auto-scheduler--timegrid-close org-auto-scheduler--timegrid-source-buffer
                                      (selected-window)))

(defun org-auto-scheduler-review-toggle-timegrid-layout ()
  "Toggle the timegrid between 3-day side-by-side view and horizontal split.
In side-by-side view, the timegrid is shown on the left with 3 days
(`org-auto-scheduler-review-timegrid-side-by-side-days') and the review tableview
is shown on the right.
In horizontal split, the timegrid is shown on top with 7 days
(`org-auto-scheduler-review-timegrid-horizontal-days') and the review tableview
is shown below.
Can be invoked from either the review table or the timegrid via `i'."
  (interactive)
  (let* ((in-grid (derived-mode-p 'org-timegrid-mode))
         (in-review (derived-mode-p 'org-auto-scheduler-review-mode))
         (review-buffer (cond (in-review (current-buffer))
                              (in-grid org-auto-scheduler--timegrid-source-buffer)
                              (t (get-buffer "*Org Auto Scheduler Review*"))))
         (grid-buffer (and (bound-and-true-p org-timegrid-buffer-name)
                           (get-buffer org-timegrid-buffer-name))))
    (unless (and review-buffer (buffer-live-p review-buffer))
      (user-error "No active Org Auto Scheduler review buffer found"))
    ;; Ensure integration enabled and library available
    (unless org-auto-scheduler-review-timegrid-integration
      (if (y-or-n-p "Enable org-timegrid integration (`org-auto-scheduler-review-timegrid-integration')? ")
          (setq org-auto-scheduler-review-timegrid-integration t)
        (user-error "Set `org-auto-scheduler-review-timegrid-integration' to non-nil to enable this")))
    (unless (require 'org-timegrid nil t)
      (user-error "org-timegrid is not installed: https://github.com/Gleek/org-timegrid"))
    (let* ((grid-win (and grid-buffer (get-buffer-window grid-buffer t)))
           (grid-open (and grid-buffer (buffer-live-p grid-buffer) grid-win)))
      (if (not grid-open)
          ;; If grid is not open, open it in side-by-side (3-day) layout
          (org-auto-scheduler--timegrid-open-fresh review-buffer 'side-by-side)
        ;; If grid is already open, toggle between side-by-side and horizontal
        (let* ((current-layout
                (or (buffer-local-value 'org-auto-scheduler--timegrid-current-layout review-buffer)
                    (buffer-local-value 'org-auto-scheduler--timegrid-current-layout grid-buffer)
                    (let ((rw (get-buffer-window review-buffer (window-frame grid-win))))
                      (if (and rw (< (car (window-pixel-edges grid-win)) (car (window-pixel-edges rw))))
                          'side-by-side
                        'horizontal))))
               (target-layout (if (eq current-layout 'side-by-side) 'horizontal 'side-by-side)))
          (org-auto-scheduler--timegrid-apply-layout review-buffer grid-buffer target-layout)
          (message "Timegrid layout: %s (%d days)"
                   (if (eq target-layout 'side-by-side) "Side-by-side (table on right)" "Horizontal split")
                   (if (eq target-layout 'side-by-side)
                       org-auto-scheduler-review-timegrid-side-by-side-days
                     (or org-auto-scheduler-review-timegrid-horizontal-days 7))))))))

;; Keep any open `*Org Time Grid*' preview in sync with table-view edits
;; (checkbox toggles, non-blocking toggles, and every reorder/recalculate/undo
;; path), rather than waiting on its periodic timer or a manual `g'.
(dolist (cmd '(org-auto-scheduler-review-toggle
               org-auto-scheduler-review-toggle-non-blocking
               org-auto-scheduler-review-recalculate
               org-auto-scheduler-review-undo))
  (advice-add cmd :after (lambda (&rest _) (org-auto-scheduler--timegrid-maybe-refresh))))

;; Keep the review table's date scope in sync whenever the linked grid
;; redraws for any reason (initial open, week navigation, its own data
;; timer, a manual `g'), not just when we ourselves triggered the redraw.
(with-eval-after-load 'org-timegrid
  (advice-add 'org-timegrid--refresh :after
              (lambda (&rest _) (org-auto-scheduler--timegrid-sync-week-range)))
  (with-eval-after-load 'evil
    (dolist (state '(normal motion))
      (evil-define-key state org-timegrid-mode-map
        (kbd "n") #'org-timegrid-next-block
        (kbd "p") #'org-timegrid-previous-block
        (kbd "b") #'org-timegrid-backward-day
        (kbd "f") #'org-timegrid-forward-day
        (kbd "j") #'org-timegrid-goto-date
        (kbd ".") #'org-timegrid-goto-today
        (kbd "g") #'org-timegrid-refresh
        (kbd "i") #'org-auto-scheduler-review-toggle-timegrid-layout
        (kbd "q") #'quit-window))))

(defun org-auto-scheduler-review-help ()
  "Show help for the review buffer and timegrid."
  (interactive)
  (with-output-to-temp-buffer "*Org Auto Scheduler Review Help*"
    (with-current-buffer standard-output
      (insert "Org Auto Scheduler Review & Timegrid Keybindings:\n\n")
      (insert "  RET, m       Toggle application of task at point/selected ([X] / [ ])\n")
      (insert "  TAB          Jump to task or event in Org file\n")
      (insert "  t            Set or change TODO state of task at point (all tasks & waiting)\n")
      (insert "  s            Toggle SPLITTABLE status on task at point/selected\n")
      (insert "  F            Toggle FREESET status (off-hours flexible; splits at midnight)\n")
      (insert "  B, b         Toggle non-blocking status of fixed agenda event (B in timegrid)\n")
      (insert "  P, p         Pin task to prompted time (P in timegrid; default: preview time; C-u to unpin)\n")
      (insert "  e            Edit estimated effort of task at point/selected (What-If)\n")
      (insert "  O            Move task to before another task, picked by name\n")
      (insert "  K            Move task up / earlier in order (crosses days)\n")
      (insert "  J            Move task down / later in order (crosses days)\n")
      (insert "  c, C-c c     Chop/slice task into today's chunk & defer remainder\n")
      (insert "  D, C-c C-v   What-If diff buffer comparing proposed against disk\n")
      (insert "  >, +         Move task to next scheduled day\n")
      (insert "  <, -         Move task to previous scheduled day\n")
      (insert "  d            Move task to specific date (org-read-date)\n")
      (insert "  U, u         Undo last review modification (U everywhere; u in review)\n")
      (insert "  x, C-c C-c   Apply all checked scheduled times to Org files\n")
      (insert "  r, C-c C-r   Recalculate schedule (auto-compacts; C-u r preserves day sections)\n")
      (insert "  R            Refresh/re-run auto-scheduler from scratch\n")
      (insert "  S, C-c C-s   Save ordering, skipping, and day decisions across sessions\n")
      (insert "  M, C-c C-m   Restore previous review order and merge live changes\n")
      (insert "  C, C-c C-d   Clear saved decisions (all, skipped, order, non-blocking, or task at point)\n")
      (insert "  E            Toggle showing existing fixed agenda events\n")
      (insert "  T            Toggle open/close org-timegrid calendar split\n")
      (insert "  i            Toggle timegrid layout (3-day side-by-side vs horizontal split)\n\n")
      (insert "Timegrid Native Navigation (in *Org Time Grid*):\n")
      (insert "  n / p        Select next / previous task block\n")
      (insert "  b / f        Navigate backward / forward by one day\n")
      (insert "  M-b / M-f    Navigate backward / forward by one week\n")
      (insert "  j / .        Jump to date / today\n")
      (insert "  SPC / C-v    Page down\n")
      (insert "  u            Undo native timegrid tile edit / scheduler undo\n")
      (insert "  M-<arrows>   Nudge block 15m earlier/later or day prev/next\n")
      (insert "  S-<arrows>   Resize block duration / effort\n\n")
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

(provide 'org-auto-scheduler-review)

;;; org-auto-scheduler-review.el ends here
