;;; 09-consecutive-background-runs-on-splittable-tasks.el --- Consecutive Background Runs on SPLITTABLE Tasks -*- lexical-binding: t -*-

;; Loaded by test/oas-suites-test.el; uses helpers from test/test-helper.el.

;; ============================================================================
;; TEST 9: Consecutive Background Runs on SPLITTABLE Tasks (No Placeholder Churn)
;; ============================================================================
(message "\n--- TEST 9: Consecutive Background Runs on SPLITTABLE Tasks ---")

(let* ((temp-dir (make-temp-file "org-split-test-" t))
       (test-org-file (expand-file-name "test-split.org" temp-dir))
       (test-log-file (expand-file-name "test-split-log.org" temp-dir))
       (today-str (format-time-string "%Y-%m-%d"))
       (today-dow (format-time-string "%a"))
       (org-auto-scheduler-change-log-file test-log-file)
       (org-auto-scheduler-change-log-enabled t)
       (org-auto-scheduler-change-log-background-only nil)
       (org-auto-scheduler-change-log-record-empty nil)
       (org-auto-scheduler-silent-mode t)
       (org-auto-scheduler-sync-caldav nil)
       (org-auto-scheduler-preserve-today-scheduled t)
       (org-auto-scheduler-start-time "00:00")
       (org-auto-scheduler-end-time (format-time-string "%H:%M" (time-add (current-time) 7200)))
       (org-auto-scheduler-split-min-chunk 30)
       (org-auto-scheduler-task-gap 0))

  (org-auto-scheduler-clear-change-log t)

  ;; Create a splittable task with 5h effort in a 3h workday (splits 3h today, 2h tomorrow)
  (with-temp-file test-org-file
    (insert (format "* Tasks :PROJECT:\n\
*** TODO Big Split Task :SPLITTABLE:AUTOSCH:\n\
:PROPERTIES:\n\
:Effort: 5:00\n\
:ID: split-parent-id\n\
:SPLITTABLE: t\n\
:END:\n")))

  (setq org-agenda-files (list test-org-file))

  ;; 9.1 First run: initial scheduling
  (let ((org-auto-scheduler--current-run-type 'background-sync)
        (org-auto-scheduler--run-start-time (current-time)))
    (org-auto-scheduler-schedule-tasks))

  ;; Save the buffer so it is clean on disk
  (with-current-buffer (find-file-noselect test-org-file)
    (save-buffer))

  ;; Verify placeholder was created
  (let* ((buf (find-file-noselect test-org-file))
         (ph-info (with-current-buffer buf
                    (save-excursion
                      (goto-char (point-min))
                      (when (re-search-forward ":AUTOSCH_PLACEHOLDER:" nil t)
                        (org-back-to-heading t)
                        (list :id (org-id-get)
                              :sched (org-entry-get nil "SCHEDULED")
                              :effort (org-entry-get nil "Effort")
                              :headline (org-get-heading t t t t)))))))
    (assert-true ph-info "Test 9.1: Placeholder subtask was created on first run")
    (assert-true (plist-get ph-info :id) "Test 9.1: Placeholder has an Org ID")
    (assert-true (string-match-p "(Remaining)" (plist-get ph-info :headline))
                 "Test 9.1: Placeholder headline contains (Remaining)")

    (let ((ph-id-run1 (plist-get ph-info :id)))

      ;; 9.2 Second run: background run 5 minutes later (no changes to task)
      (with-current-buffer buf
        (set-buffer-modified-p nil))
      (setq org-auto-scheduler--last-run-changes nil)

      (let ((org-auto-scheduler--current-run-type 'background-sync)
            (org-auto-scheduler--run-start-time (current-time)))
        (org-auto-scheduler-schedule-tasks))

      ;; Assertions for second run:
      ;; a) No tasks changed!
      (assert-equal (length org-auto-scheduler--last-run-changes) 0
                    "Test 9.2: Second background run has 0 changed tasks")
      ;; b) No placeholders cleaned!
      (assert-equal org-auto-scheduler--session-cleaned-placeholders 0
                    "Test 9.2: Second background run cleaned 0 placeholders")
      ;; c) Placeholder ID was preserved!
      (let ((ph-id-run2 (with-current-buffer buf
                          (save-excursion
                            (goto-char (point-min))
                            (re-search-forward ":AUTOSCH_PLACEHOLDER:" nil t)
                            (org-back-to-heading t)
                            (org-id-get)))))
        (assert-equal ph-id-run1 ph-id-run2
                      "Test 9.2: Placeholder Org ID preserved across runs without churn"))
      ;; d) Buffer was not modified!
      (assert-true (not (buffer-modified-p buf))
                   "Test 9.2: Agenda buffer was not modified during 0-change run")

      ;; 9.3 Third run: another consecutive run (still 0 changes)
      (let ((org-auto-scheduler--current-run-type 'background-async)
            (org-auto-scheduler--run-start-time (current-time)))
        (org-auto-scheduler-schedule-tasks))
      (assert-equal (length org-auto-scheduler--last-run-changes) 0
                    "Test 9.3: Third background run still has 0 changed tasks")
      (assert-equal org-auto-scheduler--session-cleaned-placeholders 0
                    "Test 9.3: Third background run cleaned 0 placeholders")

      ;; 9.4 Force replan (C-u): explicitly replan all
      (org-auto-scheduler-schedule-tasks t)
      (assert-true (> org-auto-scheduler--session-cleaned-placeholders 0)
                   "Test 9.4: Force replan (C-u) cleans placeholders for fresh replan")))

  (delete-directory temp-dir t))
