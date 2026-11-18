;;; 23-background-scheduler-past-tasks-rescheduling-to.el --- Background Scheduler Past Tasks Rescheduling to Today -*- lexical-binding: t -*-

;; Loaded by test/oas-suites-test.el; uses helpers from test/test-helper.el.

;; ============================================================================
;; TEST 23: Background Scheduler Past Tasks Rescheduling to Today
;; ============================================================================

(message "\n--- TEST 23: Background Scheduler Past Tasks Rescheduling to Today ---")

(let* ((temp-dir (make-temp-file "org-resched-test-" t))
       (test-org (expand-file-name "test-past.org" temp-dir))
       (today-str "2026-10-07")
       (org-agenda-files nil))

  (when (get-file-buffer test-org) (kill-buffer (get-file-buffer test-org)))
  (with-temp-file test-org
    (insert "* Tasks :PROJECT:\n*** TODO Past Uncompleted 1 :AUTOSCH:\nSCHEDULED: <2026-10-05 Mon 14:00-15:00>\n:PROPERTIES:\n:Effort: 1:00\n:ID: past-1\n:END:\n*** NEXT Past Uncompleted 2 :AUTOSCH:\nSCHEDULED: <2026-10-06 Tue>\n:PROPERTIES:\n:Effort: 0:30\n:ID: past-2\n:END:\n*** TODO Past Pinned :AUTOSCH:PINNED:\nSCHEDULED: <2026-10-05 Mon 15:00-16:00>\n:PROPERTIES:\n:Effort: 1:00\n:PINNED: t\n:PINNED_TIME: 2026-10-05 15:00\n:ID: past-pinned\n:END:\n*** DONE Past Done :AUTOSCH:\nSCHEDULED: <2026-10-05 Mon 10:00-11:00>\n:PROPERTIES:\n:ID: past-done\n:END:\n*** CANCELLED Past Cancelled :AUTOSCH:\nSCHEDULED: <2026-10-05 Mon 11:00-12:00>\n:PROPERTIES:\n:ID: past-cancelled\n:END:\n*** DROPPED Past Dropped :AUTOSCH:\nSCHEDULED: <2026-10-05 Mon 12:00-13:00>\n:PROPERTIES:\n:ID: past-dropped\n:END:\n*** TODO Past Non-Autosch\nSCHEDULED: <2026-10-05 Mon 13:00-14:00>\n:PROPERTIES:\n:ID: past-non-autosch\n:END:\n*** TODO Past Archive :AUTOSCH:ARCHIVE:\nSCHEDULED: <2026-10-05 Mon 16:00-17:00>\n:PROPERTIES:\n:ID: past-archive\n:END:\n*** TODO Past Placeholder :AUTOSCH:\nSCHEDULED: <2026-10-05 Mon 17:00-18:00>\n:PROPERTIES:\n:AUTOSCH_PLACEHOLDER: t\n:ID: past-placeholder\n:END:\n*** WAITING Past Waiting :AUTOSCH:\nSCHEDULED: <2026-10-05 Mon 18:00-19:00>\n:PROPERTIES:\n:ID: past-waiting\n:END:\n*** TODO Past Repeater :AUTOSCH:\nSCHEDULED: <2026-10-05 Mon 09:00 +1d>\n:PROPERTIES:\n:ID: past-repeater\n:END:\n*** TODO Today Task :AUTOSCH:\nSCHEDULED: <2026-10-07 Wed 10:00-11:00>\n:PROPERTIES:\n:ID: today-task\n:END:\n*** TODO Future Task :AUTOSCH:\nSCHEDULED: <2026-10-08 Thu 10:00-11:00>\n:PROPERTIES:\n:ID: future-task\n:END:\n"))

  (setq org-agenda-files (list test-org))

  ;; 23.1: Run rescheduling targeting today-str
  (let ((count (org-auto-scheduler-reschedule-past-tasks-to-today today-str)))
    (assert-equal count 3 "Test 23.1: Rescheduled count is exactly 3")

    (with-current-buffer (find-file-noselect test-org)
      (goto-char (point-min))
      (re-search-forward ":ID:[ \t]*past-1")
      (let ((s (org-entry-get nil "SCHEDULED")))
        (assert-true (string-prefix-p "<2026-10-07" s) (format "Test 23.1: past-1 scheduled for today (actual: %s)" s)))

      (goto-char (point-min))
      (re-search-forward ":ID:[ \t]*past-2")
      (let ((s (org-entry-get nil "SCHEDULED")))
        (assert-true (string-prefix-p "<2026-10-07" s) (format "Test 23.1: past-2 scheduled for today (actual: %s)" s)))

      (goto-char (point-min))
      (re-search-forward ":ID:[ \t]*past-pinned")
      (let ((s (org-entry-get nil "SCHEDULED"))
            (pt (org-entry-get nil "PINNED_TIME")))
        (assert-true (string-prefix-p "<2026-10-07" s) (format "Test 23.1: past-pinned scheduled for today (actual: %s)" s))
        (assert-equal pt "2026-10-07 15:00" "Test 23.1: past-pinned PINNED_TIME updated to today 15:00"))

      (goto-char (point-min))
      (re-search-forward ":ID:[ \t]*past-done")
      (let ((s (org-entry-get nil "SCHEDULED")))
        (assert-true (string-prefix-p "<2026-10-05" s) (format "Test 23.1: past-done retained 2026-10-05 (actual: %s)" s)))

      (goto-char (point-min))
      (re-search-forward ":ID:[ \t]*past-cancelled")
      (let ((s (org-entry-get nil "SCHEDULED")))
        (assert-true (string-prefix-p "<2026-10-05" s) (format "Test 23.1: past-cancelled retained 2026-10-05 (actual: %s)" s)))

      (goto-char (point-min))
      (re-search-forward ":ID:[ \t]*past-dropped")
      (let ((s (org-entry-get nil "SCHEDULED")))
        (assert-true (string-prefix-p "<2026-10-05" s) (format "Test 23.1: past-dropped retained 2026-10-05 (actual: %s)" s)))

      (goto-char (point-min))
      (re-search-forward ":ID:[ \t]*past-non-autosch")
      (let ((s (org-entry-get nil "SCHEDULED")))
        (assert-true (string-prefix-p "<2026-10-05" s) (format "Test 23.1: past-non-autosch retained 2026-10-05 (actual: %s)" s)))

      (goto-char (point-min))
      (re-search-forward ":ID:[ \t]*past-archive")
      (let ((s (org-entry-get nil "SCHEDULED")))
        (assert-true (string-prefix-p "<2026-10-05" s) (format "Test 23.1: past-archive retained 2026-10-05 (actual: %s)" s)))

      (goto-char (point-min))
      (re-search-forward ":ID:[ \t]*past-placeholder")
      (let ((s (org-entry-get nil "SCHEDULED")))
        (assert-true (string-prefix-p "<2026-10-05" s) (format "Test 23.1: past-placeholder retained 2026-10-05 (actual: %s)" s)))

      (goto-char (point-min))
      (re-search-forward ":ID:[ \t]*past-waiting")
      (let ((s (org-entry-get nil "SCHEDULED")))
        (assert-true (string-prefix-p "<2026-10-05" s) (format "Test 23.1: past-waiting retained 2026-10-05 (actual: %s)" s)))

      (goto-char (point-min))
      (re-search-forward ":ID:[ \t]*past-repeater")
      (let ((s (org-entry-get nil "SCHEDULED")))
        (assert-true (string-prefix-p "<2026-10-05" s) (format "Test 23.1: past-repeater retained 2026-10-05 (actual: %s)" s)))

      (goto-char (point-min))
      (re-search-forward ":ID:[ \t]*today-task")
      (let ((s (org-entry-get nil "SCHEDULED")))
        (assert-equal s "<2026-10-07 Wed 10:00-11:00>" (format "Test 23.1: today-task untouched (actual: %s)" s)))

      (goto-char (point-min))
      (re-search-forward ":ID:[ \t]*future-task")
      (let ((s (org-entry-get nil "SCHEDULED")))
        (assert-equal s "<2026-10-08 Thu 10:00-11:00>" (format "Test 23.1: future-task untouched (actual: %s)" s)))))

  (when (get-file-buffer test-org) (kill-buffer (get-file-buffer test-org)))
  (delete-directory temp-dir t))

;; 23.2: Background Scheduler First Run vs Subsequent Runs
(let* ((temp-dir (make-temp-file "org-bg-test-" t))
       (test-org (expand-file-name "test-bg.org" temp-dir))
       (fake-day-1 (encode-time 0 0 9 7 10 2026))
       (fake-day-2 (encode-time 0 0 9 8 10 2026)))

  (defun test23--setup-file ()
    (when (get-file-buffer test-org) (kill-buffer (get-file-buffer test-org)))
    (with-temp-file test-org
      (insert "* Tasks :PROJECT:\n*** TODO [#C] Today LowPri :AUTOSCH:\nSCHEDULED: <2026-10-07 Wed 09:05-10:05>\n:PROPERTIES:\n:Effort: 1:00\n:ID: today-low\n:END:\n*** TODO [#A] Yesterday HighPri :AUTOSCH:\nSCHEDULED: <2026-10-06 Mon 14:00-15:00>\n:PROPERTIES:\n:Effort: 1:00\n:ID: yesterday-high\n:END:\n")))

  (test23--setup-file)
  (setq org-agenda-files (list test-org))
  (setq org-auto-scheduler-background-enabled t)
  (setq org-auto-scheduler-background-async nil)
  (setq org-auto-scheduler-background-save-buffers t)
  (setq org-auto-scheduler-preserve-today-scheduled t)
  (setq org-auto-scheduler-start-time "09:00")
  (setq org-auto-scheduler-end-time "17:00")
  (setq org-auto-scheduler-sync-caldav nil)

  ;; SCENARIO A: Option is NIL (disabled)
  (setq org-auto-scheduler-background-reschedule-past-tasks nil)
  (setq org-auto-scheduler--last-background-run-date nil)

  (cl-letf (((symbol-function 'current-time) (lambda () fake-day-1)))
    (org-auto-scheduler--execute-background-job))

  (with-current-buffer (find-file-noselect test-org)
    (goto-char (point-min))
    (re-search-forward ":ID:[ \t]*today-low")
    (let ((s (org-entry-get nil "SCHEDULED")))
      (assert-equal s "<2026-10-07 Wed 09:05-10:05>"
                    (format "Test 23.2: When option nil, Today LowPri is preserved at 09:05-10:05 (actual: %s)" s)))
    (goto-char (point-min))
    (re-search-forward ":ID:[ \t]*yesterday-high")
    (let ((s (org-entry-get nil "SCHEDULED")))
      (assert-equal s "<2026-10-07 Wed 10:10-11:10>"
                    (format "Test 23.2: When option nil, Yesterday HighPri was appended after Today LowPri (actual: %s)" s))))

  ;; SCENARIO B: Option is T (enabled), first run of 2026-10-07
  (test23--setup-file)
  (setq org-auto-scheduler-background-reschedule-past-tasks t)
  (setq org-auto-scheduler--last-background-run-date nil)

  (cl-letf (((symbol-function 'current-time) (lambda () fake-day-1)))
    (org-auto-scheduler--execute-background-job))

  (with-current-buffer (find-file-noselect test-org)
    (goto-char (point-min))
    (re-search-forward ":ID:[ \t]*yesterday-high")
    (let ((s (org-entry-get nil "SCHEDULED")))
      (assert-equal s "<2026-10-07 Wed 09:05-10:05>"
                   (format "Test 23.2: On first run with option t, Yesterday HighPri got 09:05-10:05 (actual: %s)" s)))
    (goto-char (point-min))
    (re-search-forward ":ID:[ \t]*today-low")
    (let ((s (org-entry-get nil "SCHEDULED")))
      (assert-equal s "<2026-10-07 Wed 10:10-11:10>"
                   (format "Test 23.2: Today LowPri was displaced to 10:10-11:10 (actual: %s)" s)))
    (assert-true (not (buffer-modified-p)) "Test 23.2: Buffer was saved to disk"))

  (assert-equal org-auto-scheduler--last-background-run-date "2026-10-07"
                "Test 23.2: org-auto-scheduler--last-background-run-date set to today")

  ;; SCENARIO C: Second run on 2026-10-07 (same day)
  (with-current-buffer (find-file-noselect test-org)
    (goto-char (point-max))
    (insert "*** TODO [#A] Second Old Task :AUTOSCH:\nSCHEDULED: <2026-10-05 Mon 10:00-11:00>\n:PROPERTIES:\n:Effort: 1:00\n:ID: second-old\n:END:\n")
    (save-buffer))

  (cl-letf (((symbol-function 'current-time) (lambda () fake-day-1)))
    (org-auto-scheduler--execute-background-job))

  (with-current-buffer (find-file-noselect test-org)
    (goto-char (point-min))
    (re-search-forward ":ID:[ \t]*today-low")
    (let ((s (org-entry-get nil "SCHEDULED")))
      (assert-equal s "<2026-10-07 Wed 10:10-11:10>"
                   (format "Test 23.2: Second run on same day keeps today-low at 10:10-11:10 (actual: %s)" s)))
    (goto-char (point-min))
    (re-search-forward ":ID:[ \t]*second-old")
    (let ((s (org-entry-get nil "SCHEDULED")))
      (assert-equal s "<2026-10-07 Wed 11:15-12:15>"
                   (format "Test 23.2: Second old task scheduled after today-low at 11:15-12:15 (actual: %s)" s))))

  ;; SCENARIO D: Date advances to 2026-10-08 (new day)
  (cl-letf (((symbol-function 'current-time) (lambda () fake-day-2)))
    (org-auto-scheduler--execute-background-job))

  (assert-equal org-auto-scheduler--last-background-run-date "2026-10-08"
                "Test 23.2: org-auto-scheduler--last-background-run-date updated to new day")

  (when (get-file-buffer test-org) (kill-buffer (get-file-buffer test-org)))
  (delete-directory temp-dir t))
