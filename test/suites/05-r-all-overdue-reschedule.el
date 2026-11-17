;;; 05-r-all-overdue-reschedule.el --- -r-all- Overdue Reschedule -*- lexical-binding: t -*-

;; Loaded by test/oas-suites-test.el; uses helpers from test/test-helper.el.

;; ============================================================================
;; TEST 5: -r-all- Reschedule of All Overdue Tasks
;; ============================================================================
(message "\n--- TEST 5: -r-all- Overdue Reschedule ---")

(let* ((temp-dir (make-temp-file "org-test-" t))
       (test-org-file (expand-file-name "test-tasks-all.org" temp-dir))
       (now (current-time))
       (today-str (format-time-string "%Y-%m-%d"))
       (today-dow (format-time-string "%a"))
       (o1-start (format-time-string "%H:%M" (time-subtract now (seconds-to-time 7200))))
       (o1-end (format-time-string "%H:%M" (time-subtract now (seconds-to-time 3600))))
       (o2-start (format-time-string "%H:%M" (time-subtract now (seconds-to-time 3500))))
       (o2-end (format-time-string "%H:%M" (time-subtract now (seconds-to-time 1800))))
       (org-auto-scheduler-sync-caldav nil)
       (org-auto-scheduler-silent-mode t)
       (org-auto-scheduler-preserve-today-scheduled t)
       (org-auto-scheduler-start-time "00:00")
       (org-auto-scheduler-end-time (format-time-string "%H:%M" (time-add (current-time) 7200)))
       (org-auto-scheduler-task-gap 0))

  (with-temp-file test-org-file
    (insert (format "* Tasks :PROJECT:\n\
*** TODO Overdue 1 :AUTOSCH:\n\
SCHEDULED: <%s %s %s-%s>\n\
:PROPERTIES:\n\
:Effort: 1:00\n\
:ID: all-id-1\n\
:END:\n\
*** TODO Overdue 2 :AUTOSCH:\n\
SCHEDULED: <%s %s %s-%s>\n\
:PROPERTIES:\n\
:Effort: 1:00\n\
:ID: all-id-2\n\
:END:\n\
*** TODO Future Task 3 :AUTOSCH:\n\
SCHEDULED: <%s %s 22:00-23:00>\n\
:PROPERTIES:\n\
:Effort: 1:00\n\
:ID: all-id-3\n\
:END:\n\
*** TODO Trigger Task 4 :AUTOSCH:\n\
SCHEDULED: <%s %s 23:00-23:59>\n\
:PROPERTIES:\n\
:Effort: 0:30\n\
:ID: all-id-4\n\
:END:\n"
                    today-str today-dow o1-start o1-end
                    today-str today-dow o2-start o2-end
                    today-str today-dow
                    today-str today-dow)))

  (setq org-agenda-files (list test-org-file))

  ;; Add (-r-all-) to Task 4
  (with-current-buffer (find-file-noselect test-org-file)
    (goto-char (point-min))
    (re-search-forward "Trigger Task 4")
    (replace-match "(-r-all-) Trigger Task 4")
    (save-buffer))

  (org-auto-scheduler-schedule-tasks)

  (let ((o1-sched (with-current-buffer (find-file-noselect test-org-file)
                    (goto-char (point-min))
                    (re-search-forward ":ID:[ \t]*all-id-1")
                    (org-entry-get nil "SCHEDULED")))
        (o2-sched (with-current-buffer (find-file-noselect test-org-file)
                    (goto-char (point-min))
                    (re-search-forward ":ID:[ \t]*all-id-2")
                    (org-entry-get nil "SCHEDULED")))
        (t4-heading (with-current-buffer (find-file-noselect test-org-file)
                      (goto-char (point-min))
                      (re-search-forward ":ID:[ \t]*all-id-4")
                      (org-get-heading t t t t))))

    ;; Overdue 1 must have been rescheduled away from o1-start
    (assert-true (not (string-match-p o1-start o1-sched))
                 (format "Test 5: Overdue 1 rescheduled (actual: %s)" o1-sched))
    ;; Overdue 2 must have been rescheduled away from o2-start
    (assert-true (not (string-match-p o2-start o2-sched))
                 (format "Test 5: Overdue 2 rescheduled (actual: %s)" o2-sched))
    ;; Trigger task 4 heading cleaned
    (assert-equal t4-heading "Trigger Task 4" "Test 5: Trigger task 4 heading cleaned"))

  (delete-directory temp-dir t))
