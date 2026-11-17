;;; 06-newly-added-unscheduled-task-displaces-upcoming.el --- Newly Added Unscheduled Task Displaces Upcoming Unpinned Tasks -*- lexical-binding: t -*-

;; Loaded by test/oas-suites-test.el; uses helpers from test/test-helper.el.

;; ============================================================================
(message "\n--- TEST 6: Newly Added Unscheduled Task Displaces Upcoming Unpinned Tasks ---")

(let* ((today-parts (decode-time))
       (fake-now (encode-time 0 30 20 (nth 3 today-parts) (nth 4 today-parts) (nth 5 today-parts))))
  (cl-letf (((symbol-function (quote current-time)) (lambda () fake-now)))
    (let* ((temp-dir (make-temp-file "org-test-" t))
           (test-org-file (expand-file-name "test-new-task.org" temp-dir))
           (now fake-now)
           (today-str (format-time-string "%Y-%m-%d" fake-now))
           (today-dow (format-time-string "%a" fake-now))
           (lapsed-start (format-time-string "%H:%M" (time-subtract fake-now (seconds-to-time 3600))))
           (lapsed-end (format-time-string "%H:%M" (time-subtract fake-now (seconds-to-time 1800))))
           ;; Lapsed tasks are only left in place by background runs; manual runs replan them.
           (org-auto-scheduler--current-run-type 'background-sync)
       (org-auto-scheduler-sync-caldav nil)
       (org-auto-scheduler-silent-mode t)
       (org-auto-scheduler-preserve-today-scheduled t)
       (org-auto-scheduler-start-time "00:00")
       (org-auto-scheduler-end-time (format-time-string "%H:%M" (time-add (current-time) 7200)))
       (org-auto-scheduler-task-gap 0))

  (with-temp-file test-org-file
    (insert (format "* Tasks :PROJECT:\n\
*** TODO Lapsed Task 1 :AUTOSCH:\n\
SCHEDULED: <%s %s %s-%s>\n\
:PROPERTIES:\n\
:Effort: 1:00\n\
:ID: newtest-id-1\n\
:END:\n\
*** TODO [#C] Upcoming LowPri 2 :AUTOSCH:\n\
SCHEDULED: <%s %s 21:00-22:00>\n\
:PROPERTIES:\n\
:Effort: 1:00\n\
:ID: newtest-id-2\n\
:END:\n\
*** TODO Upcoming Pinned 3 :AUTOSCH:\n\
SCHEDULED: <%s %s 22:00-23:00>\n\
:PROPERTIES:\n\
:Effort: 1:00\n\
:PINNED: t\n\
:PINNED_TIME: 22:00\n\
:ID: newtest-id-3\n\
:END:\n\
*** TODO [#C] Upcoming LowPri 4 :AUTOSCH:\n\
SCHEDULED: <%s %s 23:00-23:59>\n\
:PROPERTIES:\n\
:Effort: 0:30\n\
:ID: newtest-id-4\n\
:END:\n\
*** TODO [#A] Urgent New Task :AUTOSCH:\n\
:PROPERTIES:\n\
:Effort: 1:00\n\
:ID: newtest-id-new\n\
:END:\n"
                    today-str today-dow lapsed-start lapsed-end
                    today-str today-dow
                    today-str today-dow
                    today-str today-dow)))

  (setq org-agenda-files (list test-org-file))

  (org-auto-scheduler-schedule-tasks)

  (let ((t1-sched (with-current-buffer (find-file-noselect test-org-file)
                    (goto-char (point-min))
                    (re-search-forward ":ID:[ \t]*newtest-id-1")
                    (org-entry-get nil "SCHEDULED")))
        (t2-sched (with-current-buffer (find-file-noselect test-org-file)
                    (goto-char (point-min))
                    (re-search-forward ":ID:[ \t]*newtest-id-2")
                    (org-entry-get nil "SCHEDULED")))
        (t3-sched (with-current-buffer (find-file-noselect test-org-file)
                    (goto-char (point-min))
                    (re-search-forward ":ID:[ \t]*newtest-id-3")
                    (org-entry-get nil "SCHEDULED")))
        (t4-sched (with-current-buffer (find-file-noselect test-org-file)
                    (goto-char (point-min))
                    (re-search-forward ":ID:[ \t]*newtest-id-4")
                    (org-entry-get nil "SCHEDULED")))
        (new-sched (with-current-buffer (find-file-noselect test-org-file)
                     (goto-char (point-min))
                     (re-search-forward ":ID:[ \t]*newtest-id-new")
                     (org-entry-get nil "SCHEDULED"))))

    (assert-equal t1-sched (format "<%s %s %s-%s>" today-str today-dow lapsed-start lapsed-end)
                  "Test 6: Lapsed Task 1 remains preserved at past time")
    (assert-true (and t3-sched (string-match-p "22:00" t3-sched))
                 (format "Test 6: Pinned Task 3 remains pinned at 22:00 (actual: %s)" t3-sched))
    (assert-true (not (null new-sched))
                 "Test 6: Urgent New Task is scheduled")
    (let ((new-time (org-time-string-to-time new-sched))
          (t2-time (org-time-string-to-time t2-sched)))
      (assert-true (time-less-p new-time t2-time)
                   (format "Test 6: Urgent New Task (%s) takes the place before LowPri 2 (%s)"
                           new-sched t2-sched)))
    (assert-true (not (equal t2-sched (format "<%s %s 21:00-22:00>" today-str today-dow)))
                 (format "Test 6: Upcoming LowPri 2 was moved by New Task (actual: %s)" t2-sched)))

      (delete-directory temp-dir t))))
