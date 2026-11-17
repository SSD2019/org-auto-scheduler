;;; 26-new-improvements-suite.el --- New Improvements Suite -*- lexical-binding: t -*-

;; Loaded by test/oas-suites-test.el; uses helpers from test/test-helper.el.

;; ============================================================================
;; TEST 26: New Improvements Suite (Scoring, Soft Energy, Backfill, CPM Float,
;;          Lockfile/Dropbox Safety, Inspector, Snapshot, EOD, Dep Explorer)
;; ============================================================================
(message "\n--- TEST 26: New Improvements Suite ---")

;; 26.1: Unwired defcustoms (tag-weights, urgent-days-boost, large-task-weight)
(with-temp-buffer
  (org-mode)
  (insert "* TODO Urgent Large Task :Urgent:Deep:\nDEADLINE: <2026-10-08 Thu>\n:PROPERTIES:\n:Effort: 2:00\n:END:\n")
  (goto-char (point-min))
  (let* ((m (point-marker))
         (fake-now (encode-time 0 0 9 7 10 2026))
         (org-auto-scheduler-tag-weights '(("Urgent" . 15.0) ("Deep" . 10.0)))
         (org-auto-scheduler-urgent-days 3)
         (org-auto-scheduler-urgent-days-boost 20.0)
         (org-auto-scheduler-large-task-minutes 90)
         (org-auto-scheduler-large-task-weight 0.4))
    (cl-letf (((symbol-function 'current-time) (lambda () fake-now)))
      (let* ((res (org-auto-scheduler-calculate-score m))
             (comps (cdr res)))
        (assert-equal (nth 11 comps) 25.0 "Test 26.1a: Tag weight sums matching tags (15 + 10 = 25.0)")
        (assert-equal (nth 12 comps) 20.0 "Test 26.1b: Urgent days boost applied when within threshold")
        (assert-equal (nth 13 comps) 12.0 "Test 26.1c: Large task weight applied when effort >= threshold")))))

;; 26.2: Historical Effort Multiplier Clamping & Cold-Start 1.0 Prior
(let ((org-auto-scheduler-historical-multipliers nil)
      (org-auto-scheduler-history-file (make-temp-file "org-mult-test-"))
      (org-state "DONE"))
  (with-temp-buffer
    (org-mode)
    (insert "* DONE Outlier Task\n:PROPERTIES:\n:CATEGORY: TestCat\n:Effort: 0:10\n:END:\n:LOGBOOK:\nCLOCK: [2026-10-07 Wed 09:00]--[2026-10-07 Wed 11:00] =>  2:00\n:END:\n")
    (goto-char (point-min))
    (org-auto-scheduler-track-historical-effort)
    ;; Raw ratio = 120 / 10 = 12.0 -> clamped to 2.5 -> blended with 1.0 prior (0.8*1.0 + 0.2*2.5 = 1.30)
    (let ((mult (cdr (assoc "TestCat" org-auto-scheduler-historical-multipliers))))
      (assert-true (and mult (< (abs (- mult 1.3)) 0.01))
                   (format "Test 26.2: Cold-start outlier ratio clamped to 2.5 and blended with 1.0 prior -> 1.30 (actual: %S)" mult))))
  (ignore-errors (delete-file org-auto-scheduler-history-file)))

;; 26.3: Soft Energy Block Same-Day Fallback vs Hard Time Block
(let* ((temp-dir (make-temp-file "org-energy-test-" t))
       (test-org (expand-file-name "test-energy.org" temp-dir))
       (fake-now (encode-time 0 0 9 7 10 2026))
       (org-auto-scheduler-silent-mode t)
       (org-auto-scheduler-sync-caldav nil)
       (org-auto-scheduler-start-time "09:00")
       (org-auto-scheduler-end-time "17:00")
       (org-auto-scheduler-start-buffer-minutes 0)
       (org-auto-scheduler-task-gap 0)
       (org-auto-scheduler-time-blocks '(("HardMorning" . (("09:00" . "11:00")))))
       (org-auto-scheduler-energy-blocks '(("SoftMorning" . (("09:00" . "11:00"))))))
  (with-temp-file test-org
    (insert "* Calendar\n** Busy Morning Meeting\n<2026-10-07 Wed 09:00-11:00>\n* Tasks :PROJECT:\n:PROPERTIES:\n:PARALLEL: t\n:END:\n** TODO [#A] Soft Energy Task :SoftMorning:AUTOSCH:\n:PROPERTIES:\n:Effort: 1:00\n:ID: soft-energy-id\n:END:\n** TODO [#B] Hard TimeBlock Task :HardMorning:AUTOSCH:\n:PROPERTIES:\n:Effort: 1:00\n:ID: hard-block-id\n:END:\n"))
  (setq org-agenda-files (list test-org))
  (cl-letf (((symbol-function 'current-time) (lambda () fake-now)))
    (org-auto-scheduler-schedule-tasks))
  (with-current-buffer (find-file-noselect test-org)
    (goto-char (point-min))
    (re-search-forward ":ID:[ \t]*soft-energy-id")
    (let ((s (org-entry-get nil "SCHEDULED")))
      (assert-equal s "<2026-10-07 Wed 11:00-12:00>"
                    (format "Test 26.3a: Soft energy block falls back to same-day afternoon when morning is full (actual: %s)" s)))
    (goto-char (point-min))
    (re-search-forward ":ID:[ \t]*hard-block-id")
    (let ((s (org-entry-get nil "SCHEDULED")))
      (assert-equal s "<2026-10-08 Thu 09:00-10:00>"
                    (format "Test 26.3b: Hard time block strictly advances to next day's morning window (actual: %s)" s))))
  (when (get-file-buffer test-org) (kill-buffer (get-file-buffer test-org)))
  (delete-directory temp-dir t))

;; 26.4: Free-Interval Gap Backfilling & Dependency Respect
(let* ((temp-dir (make-temp-file "org-backfill-test-" t))
       (test-org (expand-file-name "test-backfill.org" temp-dir))
       (fake-now (encode-time 0 0 9 7 10 2026))
       (org-auto-scheduler-silent-mode t)
       (org-auto-scheduler-sync-caldav nil)
       (org-auto-scheduler-start-time "09:00")
       (org-auto-scheduler-end-time "17:00")
       (org-auto-scheduler-start-buffer-minutes 0)
       (org-auto-scheduler-task-gap 0)
       (org-auto-scheduler-saved-order-respect-dependencies t))
  ;; Fixed meeting at 10:00-11:00 leaves a 60m gap at 09:00-10:00.
  ;; High-priority Task A needs 90m (cannot fit in 09:00-10:00, so jumps to 11:00-12:30).
  ;; Independent Task B needs 45m -> should backfill into 09:00-09:45!
  ;; Dependent Task C (blocked by Task A) needs 30m -> MUST NOT backfill before Task A; must schedule >= 12:30!
  (with-temp-file test-org
    (insert "* Calendar\n** Team Standup\n<2026-10-07 Wed 10:00-11:00>\n* Project A\n:PROPERTIES:\n:PARALLEL: t\n:END:\n** TODO [#A] Big Feature Work :AUTOSCH:\n:PROPERTIES:\n:Effort: 1:30\n:ID: bf-big-a\n:END:\n** TODO [#B] Small Independent Task :AUTOSCH:\n:PROPERTIES:\n:Effort: 0:45\n:ID: bf-small-b\n:END:\n** TODO [#C] Dependent on Big Feature :AUTOSCH:\n:PROPERTIES:\n:Effort: 0:30\n:ID: bf-dep-c\n:BLOCKER: bf-big-a\n:END:\n"))
  (setq org-agenda-files (list test-org))
  (cl-letf (((symbol-function 'current-time) (lambda () fake-now)))
    (org-auto-scheduler-schedule-tasks))
  (with-current-buffer (find-file-noselect test-org)
    (goto-char (point-min))
    (re-search-forward ":ID:[ \t]*bf-big-a")
    (let ((s-a (org-entry-get nil "SCHEDULED")))
      (assert-equal s-a "<2026-10-07 Wed 11:00-12:30>"
                    (format "Test 26.4a: 90m Task A placed after 10:00-11:00 meeting (actual: %s)" s-a)))
    (goto-char (point-min))
    (re-search-forward ":ID:[ \t]*bf-small-b")
    (let ((s-b (org-entry-get nil "SCHEDULED")))
      (assert-equal s-b "<2026-10-07 Wed 09:00-09:45>"
                    (format "Test 26.4b: 45m Independent Task B backfilled into 09:00-10:00 gap! (actual: %s)" s-b)))
    (goto-char (point-min))
    (re-search-forward ":ID:[ \t]*bf-dep-c")
    (let ((s-c (org-entry-get nil "SCHEDULED")))
      (assert-equal s-c "<2026-10-07 Wed 12:30-13:00>"
                    (format "Test 26.4c: Dependent Task C strictly waits for Task A to finish at 12:30 (actual: %s)" s-c))))
  (when (get-file-buffer test-org) (kill-buffer (get-file-buffer test-org)))
  (delete-directory temp-dir t))

;; 26.5: Deadline-Anchored CPM & Negative Float Detection
(let* ((temp-dir (make-temp-file "org-cpm-deadline-" t))
       (test-org (expand-file-name "test-cpm.org" temp-dir))
       (fake-now (encode-time 0 0 9 7 10 2026))
       (org-auto-scheduler-silent-mode t)
       (org-auto-scheduler-sync-caldav nil)
       (org-auto-scheduler-start-time "09:00")
       (org-auto-scheduler-end-time "17:00"))
  ;; Workday is 8h (480m). Chain of two tasks (300m + 300m = 600m = 10h) due TODAY!
  ;; 600m > 480m available today -> negative CPM float (-2.0h)!
  (with-temp-file test-org
    (insert "* Project :PROJECT:\n** TODO Step 1 :AUTOSCH:\n:PROPERTIES:\n:Effort: 5:00\n:ID: cpm-step-1\n:END:\n** TODO Step 2 :AUTOSCH:\nDEADLINE: <2026-10-07 Wed>\n:PROPERTIES:\n:Effort: 5:00\n:ID: cpm-step-2\n:BLOCKER: cpm-step-1\n:END:\n"))
  (setq org-agenda-files (list test-org))
  (cl-letf (((symbol-function 'current-time) (lambda () fake-now)))
    (let ((org-auto-scheduler--preview-mode t))
      (org-auto-scheduler-schedule-tasks))
    (let ((fl-1 (org-auto-scheduler-task-float-hours "cpm-step-1"))
          (fl-2 (org-auto-scheduler-task-float-hours "cpm-step-2")))
      (assert-true (and (numberp fl-1) (< fl-1 -1.5))
                   (format "Test 26.5a: Step 1 has negative CPM float %.1fh when chain exceeds deadline" fl-1))
      (assert-true (and (numberp fl-2) (< fl-2 -1.5))
                   (format "Test 26.5b: Step 2 has negative CPM float %.1fh when chain exceeds deadline" fl-2))))
  (when (get-file-buffer test-org) (kill-buffer (get-file-buffer test-org)))
  (delete-directory temp-dir t))

;; 26.6: Stale vs Active Lockfile Detection
(let* ((temp-dir (make-temp-file "org-lock-test-" t))
       (target-file (expand-file-name "tasks.org" temp-dir))
       (lock-file (expand-file-name ".#tasks.org" temp-dir))
       (org-auto-scheduler-lockfile-max-age-seconds 600))
  (with-temp-file target-file (insert "* Tasks\n"))
  ;; Create a symlink lockfile with dead local PID 999999
  (make-symbolic-link (format "user@%s.999999:1700000000" (system-name)) lock-file t)
  (assert-true (null (org-auto-scheduler--lockfile-active-p target-file))
               "Test 26.6a: Lockfile from dead local PID is treated as stale (inactive)")
  ;; Create a symlink lockfile with live local PID 1 (init/systemd) or fresh remote host
  (make-symbolic-link "user@remote-laptop.4321:1700000000" lock-file t)
  ;; The lock's age is measured against `current-time', which the helper pins to
  ;; 08:00 today, while the symlink gets the real mtime.  Use the real clock here
  ;; (`float-time' with no argument reads it directly) so this passes before 08:00.
  (let ((test-fixed-now (float-time)))
    (assert-true (org-auto-scheduler--lockfile-active-p target-file)
                 "Test 26.6b: Fresh lockfile from remote host is treated as active"))
  (delete-directory temp-dir t))

;; 26.7: Task Inspector, Start-of-Day Snapshot, EOD Wrap-Up, and Dependency Explorer
(let* ((temp-dir (make-temp-file "org-ui-test-" t))
       (test-org (expand-file-name "test-ui.org" temp-dir))
       (org-auto-scheduler-adherence-file (expand-file-name "adherence.el" temp-dir))
       (org-auto-scheduler--adherence-snapshots nil)
       (org-auto-scheduler-silent-mode t)
       (org-auto-scheduler-sync-caldav nil))
  (with-temp-file test-org
    (insert "* Auth Overhaul :PROJECT:\n:PROPERTIES:\n:ORDERED: t\n:END:\n** TODO [#A] Design Auth Schema :AUTOSCH:\n:PROPERTIES:\n:Effort: 1:00\n:ID: ui-task-1\n:END:\n** TODO [#B] Implement Token Refresh :AUTOSCH:\n:PROPERTIES:\n:Effort: 1:00\n:ID: ui-task-2\n:END:\n"))
  (setq org-agenda-files (list test-org))
  (org-auto-scheduler-review-and-apply)
  (with-current-buffer "*Org Auto Scheduler Review*"
    ;; Verify 'I' is bound to org-auto-scheduler-review-inspect-task
    (assert-equal (lookup-key org-auto-scheduler-review-mode-map (kbd "I"))
                  #'org-auto-scheduler-review-inspect-task
                  "Test 26.7a: Key 'I' is bound to org-auto-scheduler-review-inspect-task")
    ;; Move to first task row and inspect
    (org-auto-scheduler--review-goto-task "ui-task-1")
    (org-auto-scheduler-review-inspect-task)
    (assert-true (get-buffer "*Org Auto Scheduler Task Inspector*")
                 "Test 26.7b: Task Inspector buffer created")
    (with-current-buffer "*Org Auto Scheduler Task Inspector*"
      (assert-true (string-match-p "PRIORITY SCORE BREAKDOWN" (buffer-string))
                   "Test 26.7c: Task Inspector contains Priority Score Breakdown")
      (assert-true (string-match-p "SLOT PLACEMENT TRACE" (buffer-string))
                   "Test 26.7d: Task Inspector contains Slot Placement Trace")
      (assert-true (string-match-p "PROJECT HIERARCHY & SEQUENCE" (buffer-string))
                   "Test 26.7d1a: Task Inspector contains Project Hierarchy & Sequence")
      (assert-true (string-match-p "TREE.*│.*SEQUENCE & WHY" (buffer-string))
                   "Test 26.7d1b: Task Inspector renders two-column tree and sequence table")
      (assert-true (string-match-p "▶.*Design Auth Schema.*│ #1 .*First in :ORDERED:" (buffer-string))
                   "Test 26.7d1c: Task Inspector highlights ui-task-1 as #1 with :ORDERED: reason")
      (assert-true (string-match-p "Implement Token Refresh.*│ #2 .*After #1 (:ORDERED:)" (buffer-string))
                   "Test 26.7d1d: Task Inspector shows ui-task-2 as #2 after #1"))
    ;; Follow mode: moving across tasks updates the inspector
    (org-auto-scheduler--review-goto-task "ui-task-2")
    (org-auto-scheduler--review-maybe-update-inspector)
    (with-current-buffer "*Org Auto Scheduler Task Inspector*"
      (assert-true (string-match-p "Implement Token Refresh" (buffer-string))
                   "Test 26.7d2: Task Inspector follow mode updates for task under point")
      (assert-true (string-match-p "▶.*Implement Token Refresh" (buffer-string))
                   "Test 26.7d2b: Follow mode moves ▶ highlight to ui-task-2")
      (assert-true (string-match-p "Predecessors: #1 Design Auth Schema (:ORDERED: sibling)" (buffer-string))
                   "Test 26.7d2c: Follow mode updates Predecessors summary for ui-task-2"))
    ;; Toggle 'I' on task row closes the inspector side window
    (org-auto-scheduler-review-inspect-task)
    (assert-true (null (get-buffer-window "*Org Auto Scheduler Task Inspector*" t))
                 "Test 26.7d3: Pressing 'I' again closes Task Inspector window")
    ;; Snapshot schedule via 'A' command
    (org-auto-scheduler-review-snapshot-schedule)
    (assert-true (org-auto-scheduler--has-snapshot-for-date-p (format-time-string "%Y-%m-%d"))
                 "Test 26.7e: Start-of-Day Snapshot recorded via org-auto-scheduler-review-snapshot-schedule")
    ;; Open Dependency Explorer
    (org-auto-scheduler--review-goto-task "ui-task-2")
    (org-auto-scheduler-explore-dependencies)
    (assert-true (get-buffer "*Org Auto Scheduler Dependencies*")
                 "Test 26.7f: Dependency Explorer buffer created")
    (with-current-buffer "*Org Auto Scheduler Dependencies*"
      (assert-true (string-match-p "PROJECT & SIBLING DEPENDENCY EXPLORER" (buffer-string))
                   "Test 26.7g: Dependency Explorer renders project tree")
      ;; Toggle :INDEPENDENT: on ui-task-2
      (goto-char (point-min))
      (re-search-forward "Implement Token Refresh")
      (beginning-of-line)
      (org-auto-scheduler-dep-explorer-toggle-independent))
    (with-current-buffer (find-file-noselect test-org)
      (goto-char (point-min))
      (re-search-forward ":ID:[ \t]*ui-task-2")
      (assert-equal (org-entry-get nil "INDEPENDENT") "t"
                    "Test 26.7h: Pressing 'i' in Dependency Explorer sets :INDEPENDENT: t on heading")))
  ;; End-of-Day Wrap-Up buffer
  (org-auto-scheduler-eod-review)
  (assert-true (get-buffer "*Org Auto Scheduler End-of-Day*")
               "Test 26.7i: End-of-Day Wrap-Up buffer created")
  (dolist (b '("*Org Auto Scheduler Review*"
               "*Org Auto Scheduler Task Inspector*"
               "*Org Auto Scheduler Dependencies*"
               "*Org Auto Scheduler End-of-Day*"))
    (when (get-buffer b) (kill-buffer b)))
  (when (get-file-buffer test-org) (kill-buffer (get-file-buffer test-org)))
  (delete-directory temp-dir t))

;; 26.8: Multi-Level Project Hierarchy & Sequence in Task Inspector
(let* ((temp-dir (make-temp-file "org-ui-deep-test-" t))
       (test-org (expand-file-name "test-deep.org" temp-dir))
       (org-auto-scheduler-adherence-file (expand-file-name "adherence.el" temp-dir))
       (org-auto-scheduler--adherence-snapshots nil)
       (org-auto-scheduler-silent-mode t)
       (org-auto-scheduler-sync-caldav nil))
  (with-temp-file test-org
    (insert "* Platform Migration :PROJECT:\n:PROPERTIES:\n:ORDERED: t\n:END:\n** Phase 1 :ORDERED:\n:PROPERTIES:\n:ORDERED: t\n:END:\n*** TODO [#A] Migrate DB :AUTOSCH:\n:PROPERTIES:\n:Effort: 1:00\n:ID: deep-task-1\n:END:\n*** TODO [#B] Verify DB :AUTOSCH:\n:PROPERTIES:\n:Effort: 1:00\n:ID: deep-task-2\n:END:\n** Phase 2\n:PROPERTIES:\n:PARALLEL: t\n:END:\n*** TODO [#C] Update Docs :AUTOSCH:\n:PROPERTIES:\n:Effort: 0:30\n:ID: deep-task-3\n:END:\n"))
  (setq org-agenda-files (list test-org))
  (org-auto-scheduler-review-and-apply)
  (with-current-buffer "*Org Auto Scheduler Review*"
    (org-auto-scheduler--review-goto-task "deep-task-2")
    (org-auto-scheduler-review-inspect-task)
    (with-current-buffer "*Org Auto Scheduler Task Inspector*"
      (let ((txt (buffer-string)))
        (assert-true (string-match-p "Phase 1.*│ —   \\[Sequential :ORDERED:\\]" txt)
                     "Test 26.8a: Multi-level container heading Phase 1 shows [Sequential :ORDERED:]")
        (assert-true (string-match-p "Phase 2.*│ —   \\[Parallel :PARALLEL:\\]" txt)
                     "Test 26.8b: Multi-level container heading Phase 2 shows [Parallel :PARALLEL:]")
        (assert-true (string-match-p "│  └── ▶ \\[TODO\\] Verify DB" txt)
                     "Test 26.8c: Deeply nested inspected task renders with multi-level tree connector and ▶")
        (assert-true (string-match-p "Update Docs.*│ #[0-9]+ .*:PARALLEL:" txt)
                     "Test 26.8d: Child under :PARALLEL: Phase 2 shows :PARALLEL: reason"))))
  (dolist (b '("*Org Auto Scheduler Review*" "*Org Auto Scheduler Task Inspector*"))
    (when (get-buffer b) (kill-buffer b)))
  (when (get-file-buffer test-org) (kill-buffer (get-file-buffer test-org)))
  (delete-directory temp-dir t))

(setq org-agenda-files test-orig-agenda-files)
