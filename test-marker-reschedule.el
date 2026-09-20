;;; test-marker-reschedule.el --- Unit tests for marker cascade rescheduling -*- lexical-binding: t -*-

(setq package-user-dir "/home/saisan/.emacs.d/elpa/31.1/develop")
(package-initialize)
(require 'org)
(load-file "org-auto-scheduler.el")

(defvar test-failures 0)

(defun assert-equal (actual expected desc)
  (if (equal actual expected)
      (message "PASS: %s" desc)
    (setq test-failures (1+ test-failures))
    (message "FAIL: %s\n  Expected: %S\n  Actual:   %S" desc expected actual)))

(defun assert-true (val desc)
  (if val
      (message "PASS: %s" desc)
    (setq test-failures (1+ test-failures))
    (message "FAIL: %s (expected non-nil, got %S)" desc val)))

;; ============================================================================
;; TEST 1: Title Marker Processing & Permutations
;; ============================================================================
(message "\n--- TEST 1: Title Marker Processing ---")

(with-temp-buffer
  (org-mode)
  (insert "* TODO (-r-) Buy groceries\n")
  (insert "* TODO (-s-) Write documentation :DOCS:\n")
  (insert "* TODO (-f-) Late night hack\n")
  (insert "* TODO (-rsf-) Deploy production cluster :OPS:\n")
  (insert "* TODO (-sfr-) Run database backup\n")
  (insert "* TODO -fr- Clean up disk\n")
  (insert "* TODO (-r-all-) Overdue project task\n")
  (insert "* TODO Normal task without marker\n")

  (goto-char (point-min))
  ;; T1: (-r-)
  (let* ((m (point-marker))
         (res (org-auto-scheduler--process-title-markers m)))
    (assert-true (plist-get res :reschedule) "T1 has :reschedule")
    (assert-equal (plist-get res :title) "Buy groceries" "T1 cleaned title")
    (assert-equal (org-get-heading t t t t) "Buy groceries" "T1 heading in buffer"))

  (outline-next-heading)
  ;; T2: (-s-)
  (let* ((m (point-marker))
         (res (org-auto-scheduler--process-title-markers m)))
    (assert-true (plist-get res :splittable) "T2 has :splittable")
    (assert-true (null (plist-get res :reschedule)) "T2 has no :reschedule")
    (assert-equal (plist-get res :title) "Write documentation" "T2 cleaned title")
    (assert-true (org-auto-scheduler-task-splittable-p m) "T2 is marked splittable"))

  (outline-next-heading)
  ;; T3: (-f-)
  (let* ((m (point-marker))
         (res (org-auto-scheduler--process-title-markers m)))
    (assert-true (plist-get res :freeset) "T3 has :freeset")
    (assert-equal (plist-get res :title) "Late night hack" "T3 cleaned title")
    (assert-true (org-auto-scheduler-task-freeset-p m) "T3 is marked freeset"))

  (outline-next-heading)
  ;; T4: (-rsf-)
  (let* ((m (point-marker))
         (res (org-auto-scheduler--process-title-markers m)))
    (assert-true (plist-get res :reschedule) "T4 (-rsf-) has :reschedule")
    (assert-true (plist-get res :splittable) "T4 (-rsf-) has :splittable")
    (assert-true (plist-get res :freeset) "T4 (-rsf-) has :freeset")
    (assert-equal (plist-get res :title) "Deploy production cluster" "T4 cleaned title")
    (assert-true (org-auto-scheduler-task-splittable-p m) "T4 is marked splittable")
    (assert-true (org-auto-scheduler-task-freeset-p m) "T4 is marked freeset"))

  (outline-next-heading)
  ;; T5: (-sfr-) Permutation test
  (let* ((m (point-marker))
         (res (org-auto-scheduler--process-title-markers m)))
    (assert-true (plist-get res :reschedule) "T5 (-sfr-) has :reschedule")
    (assert-true (plist-get res :splittable) "T5 (-sfr-) has :splittable")
    (assert-true (plist-get res :freeset) "T5 (-sfr-) has :freeset")
    (assert-equal (plist-get res :title) "Run database backup" "T5 cleaned title"))

  (outline-next-heading)
  ;; T6: -fr- Without parentheses
  (let* ((m (point-marker))
         (res (org-auto-scheduler--process-title-markers m)))
    (assert-true (plist-get res :reschedule) "T6 -fr- has :reschedule")
    (assert-true (plist-get res :freeset) "T6 -fr- has :freeset")
    (assert-true (null (plist-get res :splittable)) "T6 -fr- has no :splittable")
    (assert-equal (plist-get res :title) "Clean up disk" "T6 cleaned title"))

  (outline-next-heading)
  ;; T7: (-r-all-)
  (let* ((m (point-marker))
         (res (org-auto-scheduler--process-title-markers m)))
    (assert-true (plist-get res :reschedule-all) "T7 has :reschedule-all")
    (assert-true (plist-get res :reschedule) "T7 has :reschedule")
    (assert-equal (plist-get res :title) "Overdue project task" "T7 cleaned title"))

  (outline-next-heading)
  ;; T8: Normal task without marker
  (let* ((m (point-marker))
         (res (org-auto-scheduler--process-title-markers m)))
    (assert-true (null res) "T8 returns nil for no marker")
    (assert-equal (org-get-heading t t t t) "Normal task without marker" "T8 unchanged")))

;; ============================================================================
;; TEST 2: Start Buffer & Clocking-In
;; ============================================================================
(message "\n--- TEST 2: Start Buffer Calculation ---")

(let* ((org-auto-scheduler-start-time "00:00")
       (org-auto-scheduler-end-time "23:59")
       (org-auto-scheduler-start-buffer-minutes 5)
       (now (current-time)))

  ;; Test when unclocked: buffer is 5 minutes (300 seconds)
  (let ((start-unclocked (org-auto-scheduler-get-start-time)))
    (let ((diff-sec (float-time (time-subtract start-unclocked now))))
      (assert-true (and (>= diff-sec 298) (<= diff-sec 305))
                   (format "Unclocked buffer is ~300s (actual: %.1fs)" diff-sec))))

  ;; Test when clocked in: buffer is 0 minutes (immediate now)
  (let ((org-clock-current-task "Test Clocked Task"))
    (let ((start-clocked (org-auto-scheduler-get-start-time)))
      (let ((diff-sec (float-time (time-subtract start-clocked now))))
        (assert-true (and (>= diff-sec -1) (<= diff-sec 2))
                     (format "Clocked buffer is ~0s (actual: %.1fs)" diff-sec))))))

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
       (org-auto-scheduler-end-time "23:59")
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
(message "\n==============================================")
(if (= test-failures 0)
    (message "ALL INTEGRATION & UNIT TESTS PASSED!")
  (message "FAILURES DETECTED: %d" test-failures))
(message "==============================================")


;; ============================================================================
;; TEST 5: -r-all- Reschedule of All Overdue Tasks
;; ============================================================================
(message "\n--- TEST 5: -r-all- Overdue Reschedule ---")

(let* ((temp-dir (make-temp-file "org-test-" t))
       (test-org-file (expand-file-name "test-tasks-all.org" temp-dir))
       (today-str (format-time-string "%Y-%m-%d"))
       (today-dow (format-time-string "%a"))
       (org-auto-scheduler-sync-caldav nil)
       (org-auto-scheduler-silent-mode t)
       (org-auto-scheduler-preserve-today-scheduled t)
       (org-auto-scheduler-start-time "00:00")
       (org-auto-scheduler-end-time "23:59")
       (org-auto-scheduler-task-gap 0))

  (with-temp-file test-org-file
    (insert (format "* Tasks :PROJECT:\n\
*** TODO Overdue 1 :AUTOSCH:\n\
SCHEDULED: <%s %s 08:00-09:00>\n\
:PROPERTIES:\n\
:Effort: 1:00\n\
:ID: all-id-1\n\
:END:\n\
*** TODO Overdue 2 :AUTOSCH:\n\
SCHEDULED: <%s %s 09:00-10:00>\n\
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
                    today-str today-dow
                    today-str today-dow
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

    ;; Overdue 1 must have been rescheduled away from 08:00
    (assert-true (not (string-match-p "08:00-09:00" o1-sched))
                 (format "Test 5: Overdue 1 rescheduled (actual: %s)" o1-sched))
    ;; Overdue 2 must have been rescheduled away from 09:00
    (assert-true (not (string-match-p "09:00-10:00" o2-sched))
                 (format "Test 5: Overdue 2 rescheduled (actual: %s)" o2-sched))
    ;; Trigger task 4 heading cleaned
    (assert-equal t4-heading "Trigger Task 4" "Test 5: Trigger task 4 heading cleaned"))

  (delete-directory temp-dir t))

;; ============================================================================
;; FINAL REPORT
;; ============================================================================


;; ============================================================================
;; TEST 6: Newly Added (Unscheduled) Task Displaces Upcoming Unpinned Tasks
;; ============================================================================
(message "\n--- TEST 6: Newly Added Unscheduled Task Displaces Upcoming Unpinned Tasks ---")

(let* ((temp-dir (make-temp-file "org-test-" t))
       (test-org-file (expand-file-name "test-new-task.org" temp-dir))
       (today-str (format-time-string "%Y-%m-%d"))
       (today-dow (format-time-string "%a"))
       (org-auto-scheduler-sync-caldav nil)
       (org-auto-scheduler-silent-mode t)
       (org-auto-scheduler-preserve-today-scheduled t)
       (org-auto-scheduler-start-time "00:00")
       (org-auto-scheduler-end-time "23:59")
       (org-auto-scheduler-task-gap 0))

  (with-temp-file test-org-file
    (insert (format "* Tasks :PROJECT:\n\
*** TODO Lapsed Task 1 :AUTOSCH:\n\
SCHEDULED: <%s %s 08:00-09:00>\n\
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
                    today-str today-dow
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

    ;; 1. Lapsed Task 1 must remain at 08:00-09:00
    (assert-equal t1-sched (format "<%s %s 08:00-09:00>" today-str today-dow)
                  "Test 6: Lapsed Task 1 remains preserved at 08:00-09:00")

    ;; 2. Pinned Task 3 must remain at 22:00-23:00
    (assert-true (and t3-sched (string-match-p "22:00" t3-sched))
                 (format "Test 6: Pinned Task 3 remains pinned at 22:00 (actual: %s)" t3-sched))

    ;; 3. Urgent New Task must be scheduled
    (assert-true (not (null new-sched))
                 "Test 6: Urgent New Task is scheduled")

    ;; 4. Urgent New Task (priority A) scheduled before Upcoming LowPri 2 (priority C)
    (let ((new-time (org-time-string-to-time new-sched))
          (t2-time (org-time-string-to-time t2-sched)))
      (assert-true (time-less-p new-time t2-time)
                   (format "Test 6: Urgent New Task (%s) takes the place before LowPri 2 (%s)"
                           new-sched t2-sched)))

    ;; 5. Upcoming LowPri 2 was moved away from 21:00-22:00
    (assert-true (not (equal t2-sched (format "<%s %s 21:00-22:00>" today-str today-dow)))
                 (format "Test 6: Upcoming LowPri 2 was moved by New Task (actual: %s)" t2-sched)))

  (delete-directory temp-dir t))

;; ============================================================================
;; TEST 7: When NO unscheduled task exists, upcoming unpinned tasks are PRESERVED
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
       (org-auto-scheduler-end-time "23:59")
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

(message "\n==============================================")
(if (= test-failures 0)
    (message "ALL 7 TEST SUITES PASSED PERFECTLY!")
  (message "FAILURES DETECTED: %d" test-failures))
(message "==============================================")

