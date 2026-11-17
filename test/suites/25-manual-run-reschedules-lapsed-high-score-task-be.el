;;; 25-manual-run-reschedules-lapsed-high-score-task-be.el --- Manual Run Reschedules Lapsed High-Score Task Before Upcoming Tasks -*- lexical-binding: t -*-

;; Loaded by test/oas-suites-test.el; uses helpers from test/test-helper.el.

;; ============================================================================
;; TEST 25: Manual Run Reschedules Lapsed High-Score Task Before Today's Upcoming Tasks
;; ============================================================================
(message "\n--- TEST 25: Manual Run Reschedules Lapsed High-Score Task Before Upcoming Tasks ---")

(let* ((temp-dir (make-temp-file "org-lapsed-manual-test-" t))
       (test-org (expand-file-name "test-lapsed-manual.org" temp-dir))
       (today-str (format-time-string "%Y-%m-%d"))
       (today-dow (format-time-string "%a"))
       (fake-now (org-auto-scheduler-parse-time-string (format "%s %s 14:37" today-str today-dow)))
       (org-auto-scheduler-silent-mode t)
       (org-auto-scheduler-sync-caldav nil)
       (org-auto-scheduler-preserve-today-scheduled t)
       (org-auto-scheduler-preserve-future-scheduled t)
       (org-auto-scheduler-manual-reschedule-lapsed t)
       (org-auto-scheduler--current-run-type nil)
       (org-auto-scheduler--saved-review-decisions nil)
       (org-auto-scheduler-start-time "09:00")
       (org-auto-scheduler-end-time "21:00")
       (org-auto-scheduler-task-gap 10))

  (with-temp-file test-org
    (insert (format "* Inbox\n\
*** TODO apply for h4 today :AUTOSCH:\n\
SCHEDULED: <%s %s 14:07-15:07> DEADLINE: <%s %s>\n\
:PROPERTIES:\n\
:Effort: 2:00\n\
:ID: lapsed-h4-id\n\
:END:\n\
* Project :PROJECT:\n\
*** TODO [#A] Planning :AUTOSCH:\n\
SCHEDULED: <%s %s 15:17-15:47>\n\
:PROPERTIES:\n\
:Effort: 0:30\n\
:ID: upcoming-plan-id\n\
:END:\n\
*** TODO Abstract :AUTOSCH:\n\
SCHEDULED: <%s %s 16:26-18:26>\n\
:PROPERTIES:\n\
:Effort: 2:00\n\
:ID: upcoming-abs-id\n\
:END:\n"
                    today-str today-dow today-str today-dow
                    today-str today-dow
                    today-str today-dow)))

  (setq org-agenda-files (list test-org))

  (cl-letf (((symbol-function (quote current-time)) (lambda () fake-now)))
    (org-auto-scheduler-schedule-tasks))

  (with-current-buffer (find-file-noselect test-org)
    (goto-char (point-min))
    (re-search-forward ":ID:[ \t]*lapsed-h4-id")
    (let ((h4-sched (org-entry-get nil "SCHEDULED")))
      (goto-char (point-min))
      (re-search-forward ":ID:[ \t]*upcoming-plan-id")
      (let ((plan-sched (org-entry-get nil "SCHEDULED")))
        (assert-true (and h4-sched (string-match-p (regexp-quote today-str) h4-sched))
                     (format "Test 25.1: Lapsed high-score task scheduled today (actual: %s)" h4-sched))
        (assert-true (time-less-p (org-time-string-to-time h4-sched)
                                  (org-time-string-to-time plan-sched))
                     (format "Test 25.2: Lapsed high-score task (%s) scheduled before upcoming Planning (%s)"
                             h4-sched plan-sched)))))

  (when (get-file-buffer test-org) (kill-buffer (get-file-buffer test-org)))
  (delete-directory temp-dir t))
