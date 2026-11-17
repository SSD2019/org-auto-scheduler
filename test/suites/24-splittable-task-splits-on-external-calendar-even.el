;;; 24-splittable-task-splits-on-external-calendar-even.el --- Splittable Task Splits on External Calendar Event -*- lexical-binding: t -*-

;; Loaded by test/oas-suites-test.el; uses helpers from test/test-helper.el.

;; ============================================================================
;; TEST 24: Splittable Task Splits on External Calendar Event during Background Preservation
;; ============================================================================
(message "\n--- TEST 24: Splittable Task Splits on External Calendar Event ---")

(let* ((temp-dir (make-temp-file "org-split-conflict-test-" t))
       (test-org (expand-file-name "test-split-conflict.org" temp-dir))
       (test-cal (expand-file-name "test-calendar.org" temp-dir))
       (today-str (format-time-string "%Y-%m-%d"))
       (today-dow (format-time-string "%a"))
       (fake-now (org-auto-scheduler-parse-time-string (format "%s %s 14:00" today-str today-dow)))
       (org-auto-scheduler-silent-mode t)
       (org-auto-scheduler-sync-caldav nil)
       (org-auto-scheduler-preserve-today-scheduled t)
       (org-auto-scheduler-start-time "09:00")
       (org-auto-scheduler-end-time "23:00")
       (org-auto-scheduler-split-min-chunk 30)
       (org-auto-scheduler-task-gap 10))

  ;; 1. Initially create a 6-hour splittable task scheduled from 14:30 to 20:30
  (with-temp-file test-org
    (insert (format "* Tasks :PROJECT:\n\
*** TODO Long Splittable Task :SPLITTABLE:AUTOSCH:\n\
SCHEDULED: <%s %s 14:30-20:30>\n\
:PROPERTIES:\n\
:Effort: 6:00\n\
:ID: long-split-task-id\n\
:SPLITTABLE: t\n\
:END:\n" today-str today-dow)))

  ;; Calendar file is initially empty
  (with-temp-file test-cal
    (insert "* Calendar Events\n"))

  (setq org-agenda-files (list test-org test-cal))

  ;; Run 1: with no external events, preserve-today keeps the task at 14:30-20:30
  (cl-letf (((symbol-function (quote current-time)) (lambda () fake-now)))
    (org-auto-scheduler-schedule-tasks))

  (with-current-buffer (find-file-noselect test-org)
    (goto-char (point-min))
    (re-search-forward ":ID:[ \t]*long-split-task-id")
    (let ((s (org-entry-get nil "SCHEDULED")))
      (assert-equal s (format "<%s %s 14:30-20:30>" today-str today-dow)
                   (format "Test 24.1: Task initially preserved at 14:30-20:30 (actual: %s)" s))))

  ;; 2. Now add an external calendar event (meeting) from 18:00 to 21:00
  (with-current-buffer (find-file-noselect test-cal)
    (goto-char (point-max))
    (insert (format "* Meeting with Team\n<%s %s 18:00-21:00>\n" today-str today-dow))
    (save-buffer))

  ;; Run 2: Background scheduler should recognize the conflict and split the splittable task!
  (cl-letf (((symbol-function (quote current-time)) (lambda () fake-now)))
    (org-auto-scheduler-schedule-tasks))

  ;; 3. Verify task was split:
  ;; Today slice should start at 14:30 and end before 18:00 meeting (10m gap -> 17:50)
  (with-current-buffer (find-file-noselect test-org)
    (goto-char (point-min))
    (re-search-forward ":ID:[ \t]*long-split-task-id")
    (let ((s (org-entry-get nil "SCHEDULED")))
      (assert-true (and s (string-match-p "-17:50>" s))
                   (format "Test 24.2: Today slice ends before 18:00 meeting (actual: %s)" s)))
    ;; Verify placeholder was created for remaining effort
    (goto-char (point-min))
    (let ((found-ph (re-search-forward ":AUTOSCH_PLACEHOLDER:" nil t)))
      (assert-true found-ph "Test 24.3: Placeholder subtask was created for remaining effort")))

  (when (get-file-buffer test-org) (kill-buffer (get-file-buffer test-org)))
  (when (get-file-buffer test-cal) (kill-buffer (get-file-buffer test-cal)))
  (delete-directory temp-dir t))
