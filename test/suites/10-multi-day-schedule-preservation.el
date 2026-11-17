;;; 10-multi-day-schedule-preservation.el --- Multi-Day Schedule Preservation -*- lexical-binding: t -*-

;; Loaded by test/oas-suites-test.el; uses helpers from test/test-helper.el.

;; ============================================================================
;; TEST 10: Multi-Day Schedule Preservation across Background Runs
;; ============================================================================
(message "\n--- TEST 10: Multi-Day Schedule Preservation ---")

(let* ((temp-dir (make-temp-file "org-test-" t))
       (test-org-file (expand-file-name "test-multiday.org" temp-dir))
       (now (current-time))
       (today-str (format-time-string "%Y-%m-%d" now))
       (today-dow (format-time-string "%a" now))
       (tmr (time-add now (days-to-time 1)))
       (tmr-str (format-time-string "%Y-%m-%d" tmr))
       (tmr-dow (format-time-string "%a" tmr))
       (day3 (time-add now (days-to-time 3)))
       (day3-str (format-time-string "%Y-%m-%d" day3))
       (day3-dow (format-time-string "%a" day3))
       (org-auto-scheduler-sync-caldav nil)
       (org-auto-scheduler-silent-mode t)
       (org-auto-scheduler-preserve-today-scheduled t)
       (org-auto-scheduler-preserve-future-scheduled t)
       (org-auto-scheduler-start-time "00:00")
       (org-auto-scheduler-end-time (format-time-string "%H:%M" (time-add (current-time) 7200)))
       (org-auto-scheduler-task-gap 0))

  (with-temp-file test-org-file
    (insert (format "* Tasks :PROJECT:\n*** TODO Today Task 1 :AUTOSCH:\nSCHEDULED: <%s %s 10:00-11:00>\n:PROPERTIES:\n:Effort: 1:00\n:ID: multi-id-1\n:END:\n*** TODO Tomorrow Task 2 :AUTOSCH:\nSCHEDULED: <%s %s 14:00-15:00>\n:PROPERTIES:\n:Effort: 1:00\n:ID: multi-id-2\n:END:\n*** TODO Future Task 3 :AUTOSCH:\nSCHEDULED: <%s %s 09:00-10:00>\n:PROPERTIES:\n:Effort: 1:00\n:ID: multi-id-3\n:END:\n"
                    today-str today-dow
                    tmr-str tmr-dow
                    day3-str day3-dow)))

  (setq org-agenda-files (list test-org-file))

  ;; 10.1 Background run with all tasks scheduled: 0 changes, all preserved
  (org-auto-scheduler-schedule-tasks)
  (let ((t1 (with-current-buffer (find-file-noselect test-org-file)
              (goto-char (point-min))
              (re-search-forward ":ID:[ \t]*multi-id-1")
              (org-entry-get nil "SCHEDULED")))
        (t2 (with-current-buffer (find-file-noselect test-org-file)
              (goto-char (point-min))
              (re-search-forward ":ID:[ \t]*multi-id-2")
              (org-entry-get nil "SCHEDULED")))
        (t3 (with-current-buffer (find-file-noselect test-org-file)
              (goto-char (point-min))
              (re-search-forward ":ID:[ \t]*multi-id-3")
              (org-entry-get nil "SCHEDULED"))))
    (assert-equal t1 (format "<%s %s 10:00-11:00>" today-str today-dow)
                  "Test 10.1: Today Task 1 preserved")
    (assert-equal t2 (format "<%s %s 14:00-15:00>" tmr-str tmr-dow)
                  "Test 10.1: Tomorrow Task 2 preserved")
    (assert-equal t3 (format "<%s %s 09:00-10:00>" day3-str day3-dow)
                  "Test 10.1: Future Task 3 preserved")
    (assert-equal (length org-auto-scheduler--last-run-changes) 0
                  "Test 10.1: Exactly 0 changes detected on preserved multi-day run"))

  ;; 10.2 Add an unscheduled task for today: future tasks must STILL be preserved
  (with-current-buffer (find-file-noselect test-org-file)
    (goto-char (point-max))
    (insert "* Tasks\n*** TODO Unscheduled New :AUTOSCH:\n:PROPERTIES:\n:Effort: 1:00\n:ID: multi-id-new\n:END:\n")
    (save-buffer))

  (org-auto-scheduler-schedule-tasks)
  (let ((t2 (with-current-buffer (find-file-noselect test-org-file)
              (goto-char (point-min))
              (re-search-forward ":ID:[ \t]*multi-id-2")
              (org-entry-get nil "SCHEDULED")))
        (t3 (with-current-buffer (find-file-noselect test-org-file)
              (goto-char (point-min))
              (re-search-forward ":ID:[ \t]*multi-id-3")
              (org-entry-get nil "SCHEDULED"))))
    (assert-equal t2 (format "<%s %s 14:00-15:00>" tmr-str tmr-dow)
                  "Test 10.2: Tomorrow Task 2 remains preserved after adding unscheduled task")
    (assert-equal t3 (format "<%s %s 09:00-10:00>" day3-str day3-dow)
                  "Test 10.2: Future Task 3 remains preserved after adding unscheduled task"))

  (delete-directory temp-dir t))
