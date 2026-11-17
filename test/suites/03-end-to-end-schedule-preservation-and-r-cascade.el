;;; 03-end-to-end-schedule-preservation-and-r-cascade.el --- End-to-End Schedule Preservation and -r- Cascade -*- lexical-binding: t -*-

;; Loaded by test/oas-suites-test.el; uses helpers from test/test-helper.el.

;; ============================================================================
;; TEST 3 & 4: Full Schedule Preservation & Cascade Rescheduling
;; ============================================================================
(message "\n--- TEST 3 & 4: End-to-End Schedule Preservation and -r- Cascade ---")

(let* ((temp-dir (make-temp-file "org-test-" t))
       (test-org-file (expand-file-name "test-tasks.org" temp-dir))
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
*** TODO Task 1 :AUTOSCH:\n\
SCHEDULED: <%s %s 09:00-10:00>\n\
:PROPERTIES:\n\
:Effort: 1:00\n\
:ID: test-id-1\n\
:END:\n\
*** TODO Task 2 :AUTOSCH:\n\
SCHEDULED: <%s %s 10:00-11:00>\n\
:PROPERTIES:\n\
:Effort: 1:00\n\
:ID: test-id-2\n\
:END:\n\
*** TODO Task 3 :AUTOSCH:\n\
SCHEDULED: <%s %s 11:00-12:00>\n\
:PROPERTIES:\n\
:Effort: 1:00\n\
:ID: test-id-3\n\
:END:\n\
*** TODO Task 4 :AUTOSCH:PINNED:\n\
SCHEDULED: <%s %s 14:00-15:00>\n\
:PROPERTIES:\n\
:Effort: 1:00\n\
:PINNED: t\n\
:PINNED_TIME: 14:00\n\
:ID: test-id-4\n\
:END:\n\
*** TODO Task 5 :AUTOSCH:\n\
SCHEDULED: <%s %s 15:00-16:00>\n\
:PROPERTIES:\n\
:Effort: 1:00\n\
:ID: test-id-5\n\
:END:\n"
                    today-str today-dow
                    today-str today-dow
                    today-str today-dow today-str today-dow
                    today-str today-dow
                    today-str today-dow
                    today-str today-dow)))

  (setq org-agenda-files (list test-org-file))

  ;; Helper to read SCHEDULED string of task by ID
  (defun get-task-scheduled (tid)
    (with-current-buffer (find-file-noselect test-org-file)
      (save-excursion
        (goto-char (point-min))
        (re-search-forward (format ":ID:[ \t]*%s" (regexp-quote tid)))
        (org-entry-get nil "SCHEDULED"))))

  ;; Helper to read heading text by ID
  (defun get-task-heading (tid)
    (with-current-buffer (find-file-noselect test-org-file)
      (save-excursion
        (goto-char (point-min))
        (re-search-forward (format ":ID:[ \t]*%s" (regexp-quote tid)))
        (org-get-heading t t t t))))

  ;; --------------------------------------------------------------------------
  ;; TEST 3: No-marker run -> All 5 tasks must remain PRESERVED exactly as scheduled!
  ;; --------------------------------------------------------------------------
  (org-auto-scheduler-schedule-tasks)

  (assert-equal (get-task-scheduled "test-id-1")
                (format "<%s %s 09:00-10:00>" today-str today-dow)
                "Test 3: Task 1 preserved at 09:00")
  (assert-equal (get-task-scheduled "test-id-2")
                (format "<%s %s 10:00-11:00>" today-str today-dow)
                "Test 3: Task 2 preserved at 10:00")
  (assert-equal (get-task-scheduled "test-id-3")
                (format "<%s %s 11:00-12:00>" today-str today-dow)
                "Test 3: Task 3 preserved at 11:00")
  (assert-equal (get-task-scheduled "test-id-4")
                (format "<%s %s 14:00-15:00>" today-str today-dow)
                "Test 3: Task 4 preserved at 14:00 (pinned)")
  (assert-equal (get-task-scheduled "test-id-5")
                (format "<%s %s 15:00-16:00>" today-str today-dow)
                "Test 3: Task 5 preserved at 15:00")

  ;; --------------------------------------------------------------------------
  ;; TEST 4: Add (-r-) to Task 2 ->
  ;; - Task 1 (scheduled before Task 2) remains PRESERVED at 09:00
  ;; - Task 2 headline is stripped of (-r-)
  ;; - Task 4 remains PINNED at 14:00
  ;; - Task 2, Task 3, Task 5 are rescheduled starting at now + 5m in relative order
  ;; --------------------------------------------------------------------------
  (with-current-buffer (find-file-noselect test-org-file)
    (goto-char (point-min))
    (re-search-forward "Task 2")
    (replace-match "(-r-) Task 2")
    (save-buffer))

  (org-auto-scheduler-schedule-tasks)

  ;; Task 1 was before Task 2: must still be preserved at 09:00!
  (assert-equal (get-task-scheduled "test-id-1")
                (format "<%s %s 09:00-10:00>" today-str today-dow)
                "Test 4: Task 1 before trigger remains preserved at 09:00")

  ;; Task 2 heading must be cleaned
  (assert-equal (get-task-heading "test-id-2")
                "Task 2"
                "Test 4: Task 2 heading cleaned of (-r-)")

  ;; Task 4 must still be pinned at 14:00
  (let ((t4-sched (get-task-scheduled "test-id-4")))
    (assert-true (and t4-sched (string-match-p "14:00" t4-sched))
                 (format "Test 4: Pinned Task 4 remains at 14:00 (actual: %s)" t4-sched)))

  ;; Task 2, Task 3, Task 5 rescheduled times
  (let ((t2-sched (get-task-scheduled "test-id-2"))
        (t3-sched (get-task-scheduled "test-id-3"))
        (t5-sched (get-task-scheduled "test-id-5")))
    (assert-true (not (equal t2-sched (format "<%s %s 10:00-11:00>" today-str today-dow)))
                 (format "Test 4: Task 2 was rescheduled to a new time (actual: %s)" t2-sched))
    ;; Verify relative chronological order: Task 2 start < Task 3 start < Task 5 start
    (let ((t2-time (org-time-string-to-time t2-sched))
          (t3-time (org-time-string-to-time t3-sched))
          (t5-time (org-time-string-to-time t5-sched)))
      (assert-true (time-less-p t2-time t3-time)
                   (format "Test 4: Task 2 (%s) comes before Task 3 (%s)"
                           t2-sched t3-sched))
      (assert-true (time-less-p t3-time t5-time)
                   (format "Test 4: Task 3 (%s) comes before Task 5 (%s)"
                           t3-sched t5-sched))))

  ;; Cleanup temp files
  (delete-directory temp-dir t))


;; ============================================================================
;; FINAL REPORT
;; ============================================================================
(setq org-agenda-files test-orig-agenda-files)

(message "\n==============================================")
(if (= test-failures 0)
    (message "ALL INTEGRATION & UNIT TESTS PASSED!")
  (message "FAILURES DETECTED: %d" test-failures))
(message "==============================================")
