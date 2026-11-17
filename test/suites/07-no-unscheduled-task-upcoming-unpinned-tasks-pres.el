;;; 07-no-unscheduled-task-upcoming-unpinned-tasks-pres.el --- No unscheduled task -> Upcoming unpinned tasks preserved -*- lexical-binding: t -*-

;; Loaded by test/oas-suites-test.el; uses helpers from test/test-helper.el.

;; ============================================================================
(message "\n--- TEST 7: No unscheduled task -> Upcoming unpinned tasks preserved ---")

(let* ((temp-dir (make-temp-file "org-test-" t))
       (test-org-file (expand-file-name "test-no-new.org" temp-dir))
       (today-str (format-time-string "%Y-%m-%d"))
       (today-dow (format-time-string "%a"))
       (org-auto-scheduler-sync-caldav nil)
       (org-auto-scheduler-silent-mode t)
       (org-auto-scheduler-preserve-today-scheduled t)
       (org-auto-scheduler-start-time "00:00")
       (org-auto-scheduler-end-time (format-time-string "%H:%M" (time-add (current-time) 7200)))
       (org-auto-scheduler-task-gap 0))

  (with-temp-file test-org-file
    (insert (format "* Tasks :PROJECT:\n\
*** TODO Lapsed Task 1 :AUTOSCH:\n\
SCHEDULED: <%s %s 08:00-09:00>\n\
:PROPERTIES:\n\
:Effort: 1:00\n\
:ID: nonew-id-1\n\
:END:\n\
*** TODO Upcoming Task 2 :AUTOSCH:\n\
SCHEDULED: <%s %s 21:00-22:00>\n\
:PROPERTIES:\n\
:Effort: 1:00\n\
:ID: nonew-id-2\n\
:END:\n"
                    today-str today-dow
                    today-str today-dow)))

  (setq org-agenda-files (list test-org-file))

  ;; Run scheduler without adding any unscheduled task and without -r-
  (org-auto-scheduler-schedule-tasks)

  (let ((t1-sched (with-current-buffer (find-file-noselect test-org-file)
                    (goto-char (point-min))
                    (re-search-forward ":ID:[ \t]*nonew-id-1")
                    (org-entry-get nil "SCHEDULED")))
        (t2-sched (with-current-buffer (find-file-noselect test-org-file)
                    (goto-char (point-min))
                    (re-search-forward ":ID:[ \t]*nonew-id-2")
                    (org-entry-get nil "SCHEDULED"))))

    (assert-equal t1-sched (format "<%s %s 08:00-09:00>" today-str today-dow)
                  "Test 7: Lapsed Task 1 preserved")
    (assert-equal t2-sched (format "<%s %s 21:00-22:00>" today-str today-dow)
                  "Test 7: Upcoming Task 2 preserved when no new task added"))

  (delete-directory temp-dir t))
