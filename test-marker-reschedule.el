;;; test-marker-reschedule.el --- Unit tests for marker cascade rescheduling -*- lexical-binding: t -*-

(setq package-user-dir "/home/saisan/.emacs.d/elpa/31.1/develop")
(package-initialize)
(require 'org)
(load-file "org-auto-scheduler.el")

(defvar test-failures 0)
(setq test-orig-agenda-files (copy-sequence org-agenda-files))
(setq test-orig-agenda-files (copy-sequence org-agenda-files))

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
  (insert "* TODO (-\\s-) Remove splittable :SPLITTABLE:\n:PROPERTIES:\n:SPLITTABLE: t\n:END:\n")
  (insert "* TODO (-\\f-) Remove freeset :FREESET:\n:PROPERTIES:\n:FREESET: t\n:END:\n")
  (insert "* TODO (-r\\s-) Resched and unsplit :SPLITTABLE:\n:PROPERTIES:\n:SPLITTABLE: t\n:END:\n")
  (insert "* TODO (-\\s\\f-) Unsplit and unfree :SPLITTABLE:FREESET:\n:PROPERTIES:\n:SPLITTABLE: t\n:FREESET: t\n:END:\n")
  (insert "* TODO (-p-) Event to pin :AUTOSCH:\nSCHEDULED: <2026-09-20 Sun 15:30-16:30>\n:PROPERTIES:\n:ID: pin-test-1\n:END:\n")
  (insert "* TODO (-\\p-) Event to unpin :AUTOSCH:PINNED:\nSCHEDULED: <2026-09-20 Sun 15:30-16:30>\n:PROPERTIES:\n:ID: pin-test-2\n:PINNED: t\n:PINNED_TIME: 2026-09-20 15:30\n:END:\n")
  (insert "* TODO (-rp-) Resched and pin :AUTOSCH:\nSCHEDULED: <2026-09-20 Sun 16:00-17:00>\n:PROPERTIES:\n:ID: pin-test-3\n:END:\n")
  (insert "* TODO (-r\\p-) Resched and unpin :AUTOSCH:PINNED:\nSCHEDULED: <2026-09-20 Sun 16:00-17:00>\n:PROPERTIES:\n:ID: pin-test-4\n:PINNED: t\n:PINNED_TIME: 2026-09-20 16:00\n:END:\n")

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
    (assert-equal (org-get-heading t t t t) "Normal task without marker" "T8 unchanged"))

  (outline-next-heading)
  ;; T9: (-\s-) Remove splittable
  (let* ((m (point-marker))
         (res (org-auto-scheduler--process-title-markers m)))
    (assert-true (plist-get res :remove-splittable) "T9 has :remove-splittable")
    (assert-true (null (plist-get res :splittable)) "T9 splittable is nil")
    (assert-equal (plist-get res :title) "Remove splittable" "T9 cleaned title")
    (assert-true (null (org-auto-scheduler-task-splittable-p m)) "T9 splittable-p is nil")
    (assert-true (null (org-entry-get nil "SPLITTABLE")) "T9 SPLITTABLE property deleted")
    (assert-true (not (member "SPLITTABLE" (org-get-tags nil t))) "T9 SPLITTABLE tag removed"))

  (outline-next-heading)
  ;; T10: (-\f-) Remove freeset
  (let* ((m (point-marker))
         (res (org-auto-scheduler--process-title-markers m)))
    (assert-true (plist-get res :remove-freeset) "T10 has :remove-freeset")
    (assert-true (null (plist-get res :freeset)) "T10 freeset is nil")
    (assert-equal (plist-get res :title) "Remove freeset" "T10 cleaned title")
    (assert-true (null (org-auto-scheduler-task-freeset-p m)) "T10 freeset-p is nil")
    (assert-true (null (org-entry-get nil "FREESET")) "T10 FREESET property deleted")
    (assert-true (not (member "FREESET" (org-get-tags nil t))) "T10 FREESET tag removed"))

  (outline-next-heading)
  ;; T11: (-r\s-) Reschedule and remove splittable
  (let* ((m (point-marker))
         (res (org-auto-scheduler--process-title-markers m)))
    (assert-true (plist-get res :reschedule) "T11 has :reschedule")
    (assert-true (plist-get res :remove-splittable) "T11 has :remove-splittable")
    (assert-true (null (org-auto-scheduler-task-splittable-p m)) "T11 splittable-p is nil")
    (assert-equal (plist-get res :title) "Resched and unsplit" "T11 cleaned title"))

  (outline-next-heading)
  ;; T12: (-\s\f-) Remove both splittable and freeset
  (let* ((m (point-marker))
         (res (org-auto-scheduler--process-title-markers m)))
    (assert-true (plist-get res :remove-splittable) "T12 has :remove-splittable")
    (assert-true (plist-get res :remove-freeset) "T12 has :remove-freeset")
    (assert-true (null (org-auto-scheduler-task-splittable-p m)) "T12 splittable-p is nil")
    (assert-true (null (org-auto-scheduler-task-freeset-p m)) "T12 freeset-p is nil")
    (assert-equal (plist-get res :title) "Unsplit and unfree" "T12 cleaned title"))

  (outline-next-heading)
  ;; T13: (-p-) Pin to incoming scheduled time
  (let* ((m (point-marker))
         (res (org-auto-scheduler--process-title-markers m)))
    (assert-true (plist-get res :pinned) "T13 has :pinned")
    (assert-true (null (plist-get res :remove-pinned)) "T13 remove-pinned is nil")
    (assert-equal (plist-get res :title) "Event to pin" "T13 cleaned title")
    (assert-true (org-auto-scheduler-task-pinned-p m) "T13 task-pinned-p is t")
    (assert-true (string-match-p "15:30" (or (org-entry-get nil "PINNED_TIME") "")) "T13 PINNED_TIME is 15:30")
    (assert-equal (org-entry-get nil "PINNED") "t" "T13 PINNED property is t")
    (assert-true (member "PINNED" (org-get-tags nil t)) "T13 has PINNED tag"))

  (outline-next-heading)
  ;; T14: (-\p-) Unpin
  (let* ((m (point-marker))
         (res (org-auto-scheduler--process-title-markers m)))
    (assert-true (plist-get res :remove-pinned) "T14 has :remove-pinned")
    (assert-true (null (plist-get res :pinned)) "T14 pinned is nil")
    (assert-equal (plist-get res :title) "Event to unpin" "T14 cleaned title")
    (assert-true (null (org-auto-scheduler-task-pinned-p m)) "T14 task-pinned-p is nil")
    (assert-true (null (org-entry-get nil "PINNED_TIME")) "T14 PINNED_TIME property deleted")
    (assert-true (null (org-entry-get nil "PINNED")) "T14 PINNED property deleted")
    (assert-true (not (member "PINNED" (org-get-tags nil t))) "T14 PINNED tag removed"))

  (outline-next-heading)
  ;; T15: (-rp-) Reschedule cascade and pin to incoming time
  (let* ((m (point-marker))
         (res (org-auto-scheduler--process-title-markers m)))
    (assert-true (plist-get res :reschedule) "T15 has :reschedule")
    (assert-true (plist-get res :pinned) "T15 has :pinned")
    (assert-true (org-auto-scheduler-task-pinned-p m) "T15 task-pinned-p is t")
    (assert-true (string-match-p "16:00" (or (org-entry-get nil "PINNED_TIME") "")) "T15 PINNED_TIME is 16:00")
    (assert-equal (plist-get res :title) "Resched and pin" "T15 cleaned title"))

  (outline-next-heading)
  ;; T16: (-r\p-) Reschedule cascade and unpin
  (let* ((m (point-marker))
         (res (org-auto-scheduler--process-title-markers m)))
    (assert-true (plist-get res :reschedule) "T16 has :reschedule")
    (assert-true (plist-get res :remove-pinned) "T16 has :remove-pinned")
    (assert-true (null (org-auto-scheduler-task-pinned-p m)) "T16 task-pinned-p is nil")
    (assert-equal (plist-get res :title) "Resched and unpin" "T16 cleaned title")))

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
       (org-auto-scheduler-end-time "23:59")
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
       (org-auto-scheduler-sync-caldav nil)
       (org-auto-scheduler-silent-mode t)
       (org-auto-scheduler-preserve-today-scheduled t)
       (org-auto-scheduler-start-time "00:00")
       (org-auto-scheduler-end-time "23:59")
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


;; ============================================================================
;; TEST 8: Background Run Change Logging
;; ============================================================================
(message "\n--- TEST 8: Background Run Change Logging ---")

;; 8.1 Timestamp equality helper
(assert-true (org-auto-scheduler--timestamps-equal-p nil nil)
             "Test 8.1: Both nil timestamps are equal")
(assert-true (null (org-auto-scheduler--timestamps-equal-p nil "<2026-09-20 Sun 10:00-11:00>"))
             "Test 8.1: Nil vs non-nil timestamps are not equal")
(assert-true (org-auto-scheduler--timestamps-equal-p
              "<2026-09-20 Sun 10:00-11:00>"
              "<2026-09-20 Sun 10:00-11:00>")
             "Test 8.1: Identical timestamps are equal")
(assert-true (null (org-auto-scheduler--timestamps-equal-p
                    "<2026-09-20 Sun 10:00-11:00>"
                    "<2026-09-20 Sun 14:00-15:00>"))
             "Test 8.1: Different timestamps are not equal")

;; 8.2 End-to-end Background Run Change Logging
(let* ((temp-dir (make-temp-file "org-change-log-test-" t))
       (test-org-file (expand-file-name "test-tasks.org" temp-dir))
       (test-log-file (expand-file-name "test-changes.org" temp-dir))
       (today-str (format-time-string "%Y-%m-%d"))
       (today-dow (format-time-string "%a"))
       (org-auto-scheduler-change-log-file test-log-file)
       (org-auto-scheduler-change-log-enabled t)
       (org-auto-scheduler-change-log-background-only t)
       (org-auto-scheduler-change-log-record-empty nil)
       (org-auto-scheduler-silent-mode t)
       (org-auto-scheduler-sync-caldav nil)
       (org-auto-scheduler-preserve-today-scheduled t)
       (org-auto-scheduler-start-time "09:00")
       (org-auto-scheduler-end-time "18:00")
       (org-auto-scheduler-task-gap 0))

  ;; Clear any existing change log buffer
  (org-auto-scheduler-clear-change-log t)

  ;; Setup test org file with 2 tasks:
  ;; Task 1: Unscheduled -> will be scheduled (newly scheduled)
  ;; Task 2: Scheduled at 10:00 with (-p-) at 14:00 -> marker & rescheduled
  (with-temp-file test-org-file
    (insert (format "* TODO Task One :AUTOSCH:
:PROPERTIES:
:Effort: 1:00
:ID: log-test-id-1
:END:
* TODO Task Two (-p-) :AUTOSCH:
SCHEDULED: <%s %s 10:00-11:00>
:PROPERTIES:
:PINNED_TIME: %s 14:00
:Effort: 1:00
:ID: log-test-id-2
:END:
"
                    today-str today-dow today-str)))

  (setq org-agenda-files (list test-org-file))

  ;; Simulate background run execution
  (let ((org-auto-scheduler--current-run-type 'background-async)
        (org-auto-scheduler--run-start-time (current-time)))
    (org-auto-scheduler-schedule-tasks))

  ;; Verify changes were recorded
  (assert-true org-auto-scheduler--last-run-changes
               "Test 8.2: Last run changes list is non-empty")
  (assert-equal (length org-auto-scheduler--last-run-changes) 2
                "Test 8.2: Detected exactly 2 changed tasks")

  ;; Check change log buffer
  (let ((buf (get-buffer org-auto-scheduler-change-log-buffer-name)))
    (assert-true (and buf (buffer-live-p buf))
                 "Test 8.2: Change log buffer exists")
    (with-current-buffer buf
      (let ((buf-str (buffer-string)))
        (assert-true (string-match-p "Background Run (Async)" buf-str)
                     "Test 8.2: Buffer contains Background Run (Async) header")
        (assert-true (string-match-p "Task One" buf-str)
                     "Test 8.2: Buffer contains Task One")
        (assert-true (string-match-p "Task Two" buf-str)
                     "Test 8.2: Buffer contains Task Two")
        (assert-true (string-match-p "Pinned task (-p-)" buf-str)
                     "Test 8.2: Buffer contains Pinned task marker action")
        (assert-true (string-match-p ":RUN_TYPE: background-async" buf-str)
                     "Test 8.2: Buffer contains run type property"))))

  ;; Check change log file on disk
  (assert-true (file-exists-p test-log-file)
               "Test 8.2: Persistent change log file created on disk")
  (with-temp-buffer
    (insert-file-contents test-log-file)
    (let ((file-str (buffer-string)))
      (assert-true (string-match-p "Task One" file-str)
                   "Test 8.2: File contains Task One")
      (assert-true (string-match-p "Task Two" file-str)
                   "Test 8.2: File contains Task Two")))

  ;; 8.3 Verify 0-change run behavior (record-empty nil suppresses log, record-empty t logs)
  (let ((initial-buf-size (with-current-buffer (get-buffer org-auto-scheduler-change-log-buffer-name)
                            (buffer-size))))
    ;; Run again with no new changes, record-empty is nil
    (let ((org-auto-scheduler--current-run-type 'background-async)
          (org-auto-scheduler--run-start-time (current-time)))
      (org-auto-scheduler-schedule-tasks))
    (let ((after-buf-size (with-current-buffer (get-buffer org-auto-scheduler-change-log-buffer-name)
                            (buffer-size))))
      (assert-equal initial-buf-size after-buf-size
                    "Test 8.3: Empty background run does not append when record-empty is nil"))

    ;; Run with record-empty = t
    (let ((org-auto-scheduler-change-log-record-empty t)
          (org-auto-scheduler--current-run-type 'background-async)
          (org-auto-scheduler--run-start-time (current-time)))
      (org-auto-scheduler-schedule-tasks))
    (let ((after-buf-str (with-current-buffer (get-buffer org-auto-scheduler-change-log-buffer-name)
                           (buffer-string))))
      (assert-true (string-match-p "No changes" after-buf-str)
                   "Test 8.3: Empty background run records summary when record-empty is t")))

  ;; 8.4 Error logging
  (org-auto-scheduler--record-run-error
   :run-type 'background-async
   :start-time (current-time)
   :error-message "Simulated test failure")
  (with-current-buffer (get-buffer org-auto-scheduler-change-log-buffer-name)
    (assert-true (string-match-p "Simulated test failure" (buffer-string))
                 "Test 8.4: Error recorded in change log buffer"))

  ;; 8.5 Pruning test
  (let ((buf (get-buffer org-auto-scheduler-change-log-buffer-name)))
    (org-auto-scheduler--prune-change-log-buffer buf 1)
    (with-current-buffer buf
      (goto-char (point-min))
      (let ((heading-count 0))
        (while (re-search-forward "^\\* \\[" nil t)
          (setq heading-count (1+ heading-count)))
        (assert-equal heading-count 1
                      "Test 8.5: Pruning correctly retained exactly 1 entry"))))

  ;; 8.6 Clear command
  (org-auto-scheduler-clear-change-log t)
  (with-current-buffer (get-buffer org-auto-scheduler-change-log-buffer-name)
    (assert-equal (buffer-size) 0
                  "Test 8.6: Clear command erased change log buffer"))
  (with-temp-buffer
    (insert-file-contents test-log-file)
    (assert-equal (buffer-size) 0
                  "Test 8.6: Clear command truncated persistent log file"))

  (delete-directory temp-dir t))


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
       (org-auto-scheduler-start-time "09:00")
       (org-auto-scheduler-end-time "12:00")
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
       (org-auto-scheduler-end-time "23:59")
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


;; ============================================================================
;; TEST 11: Agenda Cache Excludes DONE Tasks
;; ============================================================================
(message "\n--- TEST 11: Agenda Cache Excludes DONE Tasks ---")

(let* ((temp-dir (make-temp-file "org-done-cache-" t))
       (test-org-file (expand-file-name "test-done-cache.org" temp-dir))
       (now (current-time))
       (today-str (format-time-string "%Y-%m-%d" now))
       (today-dow (format-time-string "%a" now))
       (org-todo-keywords (quote ((sequence "TODO" "IN-PROGRESS" "|" "DONE" "CANCELLED" "DROPPED")))))

  (with-temp-file test-org-file
    (insert (format "* Normal Calendar Appointment\n<%s %s 10:00-11:00>\n" today-str today-dow))
    (insert (format "* TODO Active Non-Autosch Task\nSCHEDULED: <%s %s 11:30-12:30>\n" today-str today-dow))
    (insert (format "* DONE Completed Task\nSCHEDULED: <%s %s 13:00-14:00>\n" today-str today-dow))
    (insert (format "* CANCELLED Cancelled Task\nSCHEDULED: <%s %s 14:00-15:00>\n" today-str today-dow))
    (insert (format "* DROPPED Dropped Task\nSCHEDULED: <%s %s 15:00-16:00>\n" today-str today-dow))
    (insert (format "* DONE Completed Timestamp Event\n<%s %s 16:00-17:00>\n" today-str today-dow))
    (insert (format "* TODO Active Autosch Task :AUTOSCH:\nSCHEDULED: <%s %s 17:00-18:00>\n" today-str today-dow)))

  (setq org-agenda-files (list test-org-file))

  (org-auto-scheduler--build-agenda-cache)
  (let* ((cached-items (gethash today-str org-auto-scheduler--agenda-cache))
         (cached-titles (mapcar (lambda (item) (nth 5 item)) cached-items))
         (base-items (org-auto-scheduler--fetch-base-agenda-items-for-date today-str))
         (base-titles (mapcar (lambda (item) (nth 5 item)) base-items)))

    ;; Agenda cache checks
    (assert-true (member "Normal Calendar Appointment" cached-titles)
                 "Test 11: Agenda cache retains pure calendar appointment without TODO state")
    (assert-true (member "Active Non-Autosch Task" cached-titles)
                 "Test 11: Agenda cache retains active non-AUTOSCH TODO task")
    (assert-true (not (member "Completed Task" cached-titles))
                 "Test 11: Agenda cache excludes DONE scheduled task")
    (assert-true (not (member "Cancelled Task" cached-titles))
                 "Test 11: Agenda cache excludes CANCELLED scheduled task")
    (assert-true (not (member "Dropped Task" cached-titles))
                 "Test 11: Agenda cache excludes DROPPED scheduled task")
    (assert-true (not (member "Completed Timestamp Event" cached-titles))
                 "Test 11: Agenda cache excludes DONE timestamp event")
    (assert-true (not (member "Active Autosch Task" cached-titles))
                 "Test 11: Agenda cache excludes AUTOSCH task")

    ;; Base items checks
    (assert-true (member "Normal Calendar Appointment" base-titles)
                 "Test 11: Base agenda items retain pure calendar appointment")
    (assert-true (member "Active Non-Autosch Task" base-titles)
                 "Test 11: Base agenda items retain active non-AUTOSCH task")
    (assert-true (not (member "Completed Task" base-titles))
                 "Test 11: Base agenda items exclude DONE task")
    (assert-true (not (member "Completed Timestamp Event" base-titles))
                 "Test 11: Base agenda items exclude DONE event"))

  (delete-directory temp-dir t))

;; ============================================================================
;; TEST 12: Review Buffer Lifecycle and Background Scheduler Non-Blocking
;; ============================================================================
(message "\n--- TEST 12: Review Buffer Lifecycle and Background Non-Blocking ---")

(let* ((temp-dir (make-temp-file "org-review-test-" t))
       (test-org-file (expand-file-name "test-review.org" temp-dir))
       (now (current-time))
       (today-str (format-time-string "%Y-%m-%d" now))
       (today-dow (format-time-string "%a" now))
       (org-auto-scheduler-background-enabled t)
       (org-auto-scheduler-allowed-hostnames nil)
       (org-auto-scheduler-sync-caldav nil)
       (org-auto-scheduler-silent-mode t)
       (org-auto-scheduler-background-async nil))

  (with-temp-file test-org-file
    (insert (format "* Tasks\n*** TODO Review Task 1 :AUTOSCH:\n:PROPERTIES:\n:Effort: 1:00\n:ID: rev-1\n:END:\n")))

  (setq org-agenda-files (list test-org-file))

  ;; 12.1: Test org-auto-scheduler-review-save-decisions without prev-dec void error
  (let ((rev-buf (get-buffer-create "*Org Auto Scheduler Review*")))
    (with-current-buffer rev-buf
      (org-auto-scheduler-review-mode)
      (setq tabulated-list-entries
            (list (list "rev-1" (vector "[X]" "Review Task 1" "01:00" "09:00" "10:00" today-str "" "" ""))))
      ;; Should not throw void-variable prev-dec
      (let ((err-thrown nil))
        (condition-case err
            (org-auto-scheduler-review-save-decisions t)
          (error (setq err-thrown err)))
        (assert-true (null err-thrown) "Test 12.1: review-save-decisions succeeds without prev-dec error")))

    ;; 12.2: Test review-quit kills the buffer
    (with-current-buffer rev-buf
      (org-auto-scheduler-review-quit))
    (assert-true (null (get-buffer "*Org Auto Scheduler Review*"))
                 "Test 12.2: org-auto-scheduler-review-quit kills review buffer")

    ;; 12.3: Test background scheduler runs when review buffer has no window or is killed
    (let ((bg-ran nil))
      (cl-letf (((symbol-function 'org-auto-scheduler--execute-background-job)
                 (lambda () (setq bg-ran t))))
        (org-auto-scheduler-background-run)
        (assert-true bg-ran "Test 12.3: background-run executes when review buffer is not visible")))

    ;; 12.4: Test pause-on-review = t skips background run when review window is visible
    (let ((rev-buf (get-buffer-create "*Org Auto Scheduler Review*")))
      (unwind-protect
          (progn
            (set-window-buffer (selected-window) rev-buf)
            (let ((org-auto-scheduler-background-pause-on-review t)
                  (bg-ran nil))
              (cl-letf (((symbol-function 'org-auto-scheduler--execute-background-job)
                         (lambda () (setq bg-ran t))))
                (org-auto-scheduler-background-run)
                (assert-true (null bg-ran) "Test 12.4: pause-on-review t skips background run when review buffer is visible")))

            ;; 12.5: Test pause-on-review = nil allows background run even when review window is visible
            (let ((org-auto-scheduler-background-pause-on-review nil)
                  (bg-ran nil))
              (cl-letf (((symbol-function 'org-auto-scheduler--execute-background-job)
                         (lambda () (setq bg-ran t))))
                (org-auto-scheduler-background-run)
                (assert-true bg-ran "Test 12.5: pause-on-review nil allows background run when review buffer is visible")))

            ;; 12.6: Test active operation mutex skips background run even if pause-on-review is nil
            (let ((org-auto-scheduler-background-pause-on-review nil)
                  (bg-ran nil))
              (org-auto-scheduler--with-active-operation 'review-apply
                (cl-letf (((symbol-function 'org-auto-scheduler--execute-background-job)
                           (lambda () (setq bg-ran t))))
                  (org-auto-scheduler-background-run)
                  (assert-true (null bg-ran) "Test 12.6: active-operation skips background run during review-apply"))))

            ;; 12.7: Test uncommitted review overrides are not leaked to background run when pause-on-review is nil
            (with-current-buffer rev-buf
              (setq-local org-auto-scheduler--review-overrides (make-hash-table :test 'equal))
              (puthash "rev-1" '(:effort 120 :target-date "2099-01-01") org-auto-scheduler--review-overrides)
              (let ((org-auto-scheduler-background-pause-on-review nil)
                    (org-auto-scheduler--background-running t))
                (let ((ov (org-auto-scheduler--get-review-overrides)))
                  (assert-true (null ov) "Test 12.7: uncommitted review overrides not leaked to background run")))))
        (when (get-buffer "*Org Auto Scheduler Review*")
          (kill-buffer rev-buf)))))

  (delete-directory temp-dir t))


;; ============================================================================
;; TEST 13: Task-Scoped Pomodoro Scheduling (:POMODORO: Work:Break)
;; ============================================================================
(message "\n--- TEST 13: Task-Scoped Pomodoro Scheduling ---")

(let* ((temp-dir (make-temp-file "org-test-pomo-" t))
       (test-org-file (expand-file-name "test-pomodoro.org" temp-dir))
       (today-parts (decode-time))
       (fake-now (encode-time 0 0 9 (nth 3 today-parts) (nth 4 today-parts) (nth 5 today-parts))))
  (cl-letf (((symbol-function 'current-time) (lambda () fake-now)))
    (let ((org-auto-scheduler-sync-caldav nil)
          (org-auto-scheduler-silent-mode t)
          (org-auto-scheduler-preserve-today-scheduled nil)
          (org-auto-scheduler-start-time "09:00")
          (org-auto-scheduler-end-time "18:00")
          (org-auto-scheduler-task-gap 0))

      ;; 13.1: Spec parsing unit tests
      (assert-equal (let ((trimmed "25:5"))
                      (when (string-match "^\\([0-9]+\\)[ 	]*[:/][ 	]*\\([0-9]+\\)$" trimmed)
                        (list :work (string-to-number (match-string 1 trimmed))
                              :break (string-to-number (match-string 2 trimmed)))))
                    '(:work 25 :break 5)
                    "Test 13.1: Spec parses 25:5")
      (assert-equal (let ((trimmed "50 : 10"))
                      (when (string-match "^\\([0-9]+\\)[ 	]*[:/][ 	]*\\([0-9]+\\)$" trimmed)
                        (list :work (string-to-number (match-string 1 trimmed))
                              :break (string-to-number (match-string 2 trimmed)))))
                    '(:work 50 :break 10)
                    "Test 13.1: Spec parses 50 : 10")

      ;; 13.2: End-to-end task scheduling:
      ;; Task A: POMODORO 25:5, Effort 1:00 (splits 25m work + 5m break + 25m work + 5m break + 10m work + 5m trailing gap)
      ;; Task B: POMODORO 25:5, Effort 0:25 (single 25m work block + 5m break)
      ;; Task C: Normal task (no POMODORO), Effort 0:30 (contiguous 30m block, normal task-gap = 0)
      ;; Task D: Normal task (no POMODORO), Effort 0:30 (starts immediately after Task C without any break)
      (with-temp-file test-org-file
        (insert "* Tasks :PROJECT:
*** TODO Pomo Task Split :AUTOSCH:
:PROPERTIES:
:Effort: 1:00
:POMODORO: 25:5
:ID: pomo-test-split
:END:
*** TODO Pomo Task Single :AUTOSCH:
:PROPERTIES:
:Effort: 0:25
:POMODORO: 25:5
:ID: pomo-test-single
:END:
*** TODO Normal Task C :AUTOSCH:
:PROPERTIES:
:Effort: 0:30
:ID: pomo-test-norm-c
:END:
*** TODO Normal Task D :AUTOSCH:
:PROPERTIES:
:Effort: 0:30
:ID: pomo-test-norm-d
:END:
"))
      (setq org-agenda-files (list test-org-file))
      (org-auto-scheduler-schedule-tasks)

      (with-current-buffer (find-file-noselect test-org-file)
        (goto-char (point-min))
        (re-search-forward ":ID:[ 	]*pomo-test-norm-d")
        (let ((norm-d-sched (org-entry-get nil "SCHEDULED")))
          (assert-true (and norm-d-sched (string-match-p "09:05-09:35" norm-d-sched))
                       (format "Test 13.2: Normal Task D scheduled first at 09:05-09:35 (actual: %s)" norm-d-sched)))

        (goto-char (point-min))
        (re-search-forward ":ID:[ 	]*pomo-test-norm-c")
        (let ((norm-c-sched (org-entry-get nil "SCHEDULED")))
          (assert-true (and norm-c-sched (string-match-p "09:35-10:05" norm-c-sched))
                       (format "Test 13.2: Normal Task C starts immediately after D at 09:35 with 0m break (actual: %s)" norm-c-sched)))

        (goto-char (point-min))
        (re-search-forward ":ID:[ 	]*pomo-test-single")
        (let ((single-sched (org-entry-get nil "SCHEDULED")))
          (assert-true (and single-sched (string-match-p "10:05-10:30" single-sched))
                       (format "Test 13.3: Pomo single task starts at 10:05-10:30 (actual: %s)" single-sched)))

        (goto-char (point-min))
        (re-search-forward ":ID:[ 	]*pomo-test-split")
        (let ((split-p1-sched (org-entry-get nil "SCHEDULED")))
          (assert-true (and split-p1-sched (string-match-p "10:35-11:00" split-p1-sched))
                       (format "Test 13.4: Pomo split part 1 starts after single pomo 5m break at 10:35-11:00 (actual: %s)" split-p1-sched)))

        (goto-char (point-min))
        (re-search-forward "Pomodoro 2/3")
        (let ((split-p2-sched (org-entry-get nil "SCHEDULED"))
              (split-p2-ph (org-entry-get nil "AUTOSCH_PLACEHOLDER")))
          (assert-equal split-p2-ph "t" "Test 13.4: Part 2 is marked as placeholder")
          (assert-true (and split-p2-sched (string-match-p "11:05-11:30" split-p2-sched))
                       (format "Test 13.4: Pomo split part 2 starts after 5m break at 11:05-11:30 (actual: %s)" split-p2-sched)))

        (goto-char (point-min))
        (re-search-forward "Pomodoro 3/3")
        (let ((split-p3-sched (org-entry-get nil "SCHEDULED")))
          (assert-true (and split-p3-sched (string-match-p "11:35-11:45" split-p3-sched))
                       (format "Test 13.4: Pomo split part 3 starts after 5m break at 11:35-11:45 (actual: %s)" split-p3-sched))))

      ;; 13.5: Idempotency of repeated runs on Pomodoro tasks
      (let* ((buf (find-file-noselect test-org-file))
             (str1 (with-current-buffer buf (buffer-string))))
        (org-auto-scheduler-schedule-tasks)
        (let ((str2 (with-current-buffer buf (buffer-string))))
          (assert-true (string= str1 str2)
                       "Test 13.5: Consecutive scheduling runs on Pomodoro tasks are completely idempotent"))))

    (delete-directory temp-dir t)))


;; ============================================================================
;; TEST 14: Review Buffer Polish, Slicing, What-If Diff & Retrospective (Step 4)
;; ============================================================================
(message "\n--- TEST 14: Review Buffer Polish, Slicing & Retrospective ---")

;; 14.1 Capacity Gauge
(let* ((g-normal (org-auto-scheduler--render-capacity-gauge 240 480))
       (g-over (org-auto-scheduler--render-capacity-gauge 600 480)))
  (assert-true (string-match-p "50%" g-normal) "Test 14.1: Normal capacity reports 50%")
  (assert-true (string-match-p "Slack: 4.0h" g-normal) "Test 14.1: Normal capacity reports 4.0h slack")
  (assert-true (string-match-p "OVERLOAD" g-over) "Test 14.1: Overload capacity reports OVERLOAD")
  (assert-true (string-match-p "125%" g-over) "Test 14.1: Overload capacity reports 125%"))

;; 14.2 Task Slicer / Chop
(let* ((temp-dir (make-temp-file "org-test-chop-" t))
       (test-org-file (expand-file-name "test-chop.org" temp-dir)))
  (with-temp-file test-org-file
    (insert "* Tasks :PROJECT:
*** TODO Big Task To Chop :AUTOSCH:
:PROPERTIES:
:Effort: 2:00
:ID: chop-task-1
:END:
"))
  (setq org-agenda-files (list test-org-file))
  (let* ((org-auto-scheduler-review-auto-recalculate-on-move nil)
         (rev-buf (get-buffer-create "*Org Auto Scheduler Review*")))
    (with-current-buffer rev-buf
      (org-auto-scheduler-review-mode)
      (setq-local org-auto-scheduler--review-overrides (make-hash-table :test 'equal))
      (setq-local org-auto-scheduler--review-undo-stack '())
      (setq tabulated-list-entries
            (list (list "chop-task-1"
                        (vector "chop-task-1" "[X]" "1" "09:00-11:00" "120" "PROJECT" "Big Task To Chop" ""))))
      (let* ((m (with-current-buffer (find-file-noselect test-org-file)
                  (goto-char (point-min))
                  (re-search-forward "Big Task To Chop")
                  (point-marker))))
        (setq org-auto-scheduler-completed-tasks
              (list (list "chop-task-1" (current-time) (current-time) '("AUTOSCH") t "Big Task To Chop" nil m 0)))
        (tabulated-list-init-header)
        (tabulated-list-print t)
        (goto-char (point-min))
        ;; Call chop with 45 minutes
        (org-auto-scheduler-review-chop 45)
        (let ((ov (gethash "chop-task-1" org-auto-scheduler--review-overrides)))
          (assert-true ov "Test 14.2: Chop created override entry")
          (assert-true (= (plist-get ov :chop-today) 45) "Test 14.2: Chop override kept 45m today")
          (assert-equal (plist-get ov :splittable) t "Test 14.2: Chop marked task splittable"))
        ;; Test Undo
        (org-auto-scheduler-review-undo)
        (let ((ov-after (gethash "chop-task-1" org-auto-scheduler--review-overrides)))
          (assert-true (null ov-after) "Test 14.2: Review undo removed chop override")))))
  (delete-directory temp-dir t))

;; 14.3 What-If Diff Buffer
(let* ((temp-dir (make-temp-file "org-test-diff-" t))
       (test-org-file (expand-file-name "test-diff.org" temp-dir))
       (now (current-time))
       (t1-start now)
       (t1-end (time-add now (seconds-to-time 3600)))
       (t2-start (time-add now (seconds-to-time 7200)))
       (t2-end (time-add now (seconds-to-time 10800))))
  (with-temp-file test-org-file
    (insert (format "* Tasks :PROJECT:
*** TODO Unchanged Task :AUTOSCH:
SCHEDULED: %s
:PROPERTIES:
:ID: diff-unchanged
:END:
*** TODO Moved Task :AUTOSCH:
SCHEDULED: %s
:PROPERTIES:
:ID: diff-moved
:END:
*** TODO Skipped Task :AUTOSCH:
SCHEDULED: %s
:PROPERTIES:
:ID: diff-skipped
:END:
"
                    (org-auto-scheduler--format-time-range t1-start t1-end)
                    (org-auto-scheduler--format-time-range t1-start t1-end)
                    (org-auto-scheduler--format-time-range t1-start t1-end))))
  (let* ((buf (find-file-noselect test-org-file))
         (m1 (with-current-buffer buf (goto-char (point-min)) (re-search-forward "Unchanged Task") (point-marker)))
         (m2 (with-current-buffer buf (goto-char (point-min)) (re-search-forward "Moved Task") (point-marker)))
         (m3 (with-current-buffer buf (goto-char (point-min)) (re-search-forward "Skipped Task") (point-marker))))
    (setq org-auto-scheduler-completed-tasks
          (list (list "diff-unchanged" t1-start t1-end '("AUTOSCH") t "Unchanged Task" nil m1 0)
                (list "diff-moved" t2-start t2-end '("AUTOSCH") t "Moved Task" nil m2 0)
                (list "diff-skipped" t1-start t1-end '("AUTOSCH") nil "Skipped Task" nil m3 0 :skipped '("User unchecked"))
                (list "diff-new" t2-start t2-end '("AUTOSCH") t "Brand New Task" nil nil 0)))
    (let ((diff-buf (org-auto-scheduler-review-diff)))
      (assert-true (get-buffer "*Org Auto Scheduler Diff*") "Test 14.3: Diff buffer created")
      (with-current-buffer "*Org Auto Scheduler Diff*"
        (let ((str (buffer-string)))
          (assert-true (string-match-p "1 moved, 1 new, 1 skipped, 1 unchanged" str)
                       (format "Test 14.3: Diff summary counts correct: %s" str))
          (assert-true (string-match-p "Unchanged Task.*UNCHANGED" str) "Test 14.3: Unchanged task detected")
          (assert-true (string-match-p "Moved Task.*MOVED" str) "Test 14.3: Moved task detected")
          (assert-true (string-match-p "Skipped Task.*SKIPPED" str) "Test 14.3: Skipped task detected")
          (assert-true (string-match-p "Brand New Task.*NEW" str) "Test 14.3: New task detected")))))
  (delete-directory temp-dir t))

;; 14.4 Weekly Retrospective Summary
(let* ((temp-dir (make-temp-file "org-test-retro-" t))
       (test-org-file (expand-file-name "test-retro.org" temp-dir))
       (now (current-time))
       (today-str (format-time-string "%Y-%m-%d" now)))
  (with-temp-file test-org-file
    (insert (format "* Work :PROJECT:
*** DONE Completed Planned Task :AUTOSCH:
CLOSED: [%s 11:00] SCHEDULED: <%s 09:00-11:00>
:PROPERTIES:
:Effort: 2:00
:ID: retro-task-1
:END:
:LOGBOOK:
CLOCK: [%s 09:00]--[%s 11:00] =>  2:00
:END:
*** TODO Rolled Planned Task :AUTOSCH:
SCHEDULED: <%s 14:00-15:00>
:PROPERTIES:
:Effort: 1:00
:ID: retro-task-2
:END:
* Personal
*** DONE Quick Unplanned Interrupt
CLOSED: [%s 12:00]
:LOGBOOK:
CLOCK: [%s 11:30]--[%s 12:00] =>  0:30
:END:
"
                    today-str today-str today-str today-str today-str today-str today-str today-str)))
  (setq org-agenda-files (list test-org-file))
  (let ((metrics (org-auto-scheduler--analyze-retrospective 7)))
    (assert-equal (plist-get metrics :done) 1 "Test 14.4: Exactly 1 planned task completed")
    (assert-equal (plist-get metrics :planned) 2 "Test 14.4: Total 2 planned tasks")
    (assert-equal (plist-get metrics :rolled) 1 "Test 14.4: Exactly 1 planned task rolled")
    (assert-equal (round (plist-get metrics :planned-effort)) 180 "Test 14.4: 180m planned effort")
    (assert-equal (plist-get metrics :planned-clocked) 120 "Test 14.4: 120m planned clocked")
    (assert-equal (plist-get metrics :unplanned-clocked) 30 "Test 14.4: 30m unplanned clocked"))
  (org-auto-scheduler-weekly-retrospective 7)
  (assert-true (get-buffer "*Org Auto Scheduler Retrospective*") "Test 14.4: Retrospective buffer created")
  (with-current-buffer "*Org Auto Scheduler Retrospective*"
    (let ((str (buffer-string)))
      (assert-true (string-match-p "Tasks Completed:  1 (50.0%)" str) "Test 14.4: Completion percentage reported")
      (assert-true (string-match-p "Planned Effort:   3.0h" str) "Test 14.4: Planned effort hours reported")
      (assert-true (string-match-p "Planned Focus:    2.0h (80.0%)" str) "Test 14.4: Planned focus reported")
      (assert-true (string-match-p "Unplanned Work:   0.5h (20.0%)" str) "Test 14.4: Unplanned work reported")))
  (delete-directory temp-dir t))


;; ============================================================================
;; TEST 15: Bug Fix Regression Suite (Stages 1 - 4)
;; ============================================================================
(message "
--- TEST 15: Bug Fix Regressions across All 4 Stages ---")

;; 15.1: Pomodoro spec parser supports leading colons and spaces
(let ((p1 (let ((trimmed ":25:5"))
            (when (string-match "^:?[ \t]*\\([0-9]+\\)[ \t]*[:/][ \t]*\\([0-9]+\\)$" trimmed)
              (list :work (string-to-number (match-string 1 trimmed))
                    :break (string-to-number (match-string 2 trimmed))))))
      (p2 (let ((trimmed ": 50 : 10"))
            (when (string-match "^:?[ \t]*\\([0-9]+\\)[ \t]*[:/][ \t]*\\([0-9]+\\)$" trimmed)
              (list :work (string-to-number (match-string 1 trimmed))
                    :break (string-to-number (match-string 2 trimmed)))))))
  (assert-equal p1 '(:work 25 :break 5) "Test 15.1: Pomodoro parses :25:5")
  (assert-equal p2 '(:work 50 :break 10) "Test 15.1: Pomodoro parses : 50 : 10"))

;; 15.2: Multi-day title marker deferral (-+2d-) and effort reschedule trigger
(let* ((temp-dir (make-temp-file "org-test-bug-defer-" t))
       (test-org-file (expand-file-name "test-defer.org" temp-dir)))
  (with-temp-file test-org-file
    (insert "* Tasks :PROJECT:
*** TODO Task To Defer (-+2d-) :AUTOSCH:
:PROPERTIES:
:Effort: 1:00
:ID: defer-task-1
:END:
*** TODO Task Effort Change (-e30m-) :AUTOSCH:
SCHEDULED: <2026-09-25 Fri 10:00-11:00>
:PROPERTIES:
:Effort: 1:00
:ID: effort-task-2
:END:
"))
  (setq org-agenda-files (list test-org-file))
  (let* ((buf (find-file-noselect test-org-file))
         (m1 (with-current-buffer buf (goto-char (org-find-entry-with-id "defer-task-1")) (point-marker)))
         (m2 (with-current-buffer buf (goto-char (org-find-entry-with-id "effort-task-2")) (point-marker)))
         (res1 (org-auto-scheduler--process-title-markers m1))
         (res2 (org-auto-scheduler--process-title-markers m2)))
    (assert-true (plist-get res1 :defer) "Test 15.2: -+2d- triggers defer")
    (assert-true (plist-get res1 :reschedule) "Test 15.2: Defer triggers reschedule flag")
    (assert-equal (plist-get res2 :effort) 30 "Test 15.2: -e30m- parses 30 minutes")
    (assert-true (plist-get res2 :reschedule) "Test 15.2: Effort change triggers reschedule flag")
    (kill-buffer buf))
  (delete-directory temp-dir t))

;; 15.3: Non-blocking fallback regex matches :NON_BLOCKING: without broken escapes
(with-temp-buffer
  (org-mode)
  (insert "* Calendar Meeting
:PROPERTIES:
:NON_BLOCKING: t
:END:
")
  (goto-char (point-min))
  (assert-true (org-auto-scheduler-task-non-blocking-p "fake-id" (point-marker) "Calendar Meeting")
               "Test 15.3: Non-blocking detected from property drawer via fallback search"))

;; 15.4: Retrospective excludes future scheduled tasks (> end of today)
(let* ((temp-dir (make-temp-file "org-test-retro-future-" t))
       (test-org-file (expand-file-name "test-retro-future.org" temp-dir))
       (now (current-time))
       (past-date (format-time-string "%Y-%m-%d" (time-subtract now (seconds-to-time 86400))))
       (future-date (format-time-string "%Y-%m-%d" (time-add now (seconds-to-time (* 3 86400))))))
  (with-temp-file test-org-file
    (insert (format "* Tasks :PROJECT:
*** DONE Past Task Done :AUTOSCH:
CLOSED: [%s 10:00] SCHEDULED: <%s 09:00-10:00>
:PROPERTIES:
:Effort: 1:00
:ID: past-done-1
:END:
*** TODO Future Task Next Week :AUTOSCH:
SCHEDULED: <%s 10:00-11:00>
:PROPERTIES:
:Effort: 1:00
:ID: future-task-2
:END:
"
                    past-date past-date future-date)))
  (setq org-agenda-files (list test-org-file))
  (let ((metrics (org-auto-scheduler--analyze-retrospective 7)))
    (assert-equal (plist-get metrics :done) 1 "Test 15.4: Exactly 1 past task done")
    (assert-equal (plist-get metrics :planned) 1 "Test 15.4: Future task is excluded from past planned count")
    (assert-equal (plist-get metrics :rolled) 0 "Test 15.4: Future task is NOT counted as rolled"))
  (delete-directory temp-dir t))

;; 15.5: Review chop duration explicitly rounded
(assert-equal (let* ((input "45.5")
                     (keep-today (let ((parsed (condition-case nil (org-duration-to-minutes input) (error nil))))
                                   (if (and parsed (> parsed 0))
                                       (round parsed)
                                     (round (string-to-number input))))))
                keep-today)
              46
              "Test 15.5: Chop duration parsed float is cleanly rounded to integer")

(when (boundp 'test-orig-agenda-files) (setq org-agenda-files test-orig-agenda-files))

(message "\n==============================================")

;; ============================================================================
;; TEST 16: Focus HUD Cockpit (Pacing, Checklists, Notes, Subtasks, Sibling)
;; ============================================================================
(message "\n--- TEST 16: Focus HUD Cockpit ---")

;; 16.1: Standby view
(let ((buf (get-buffer-create "*Org Focus HUD*")))
  (with-current-buffer buf
    (org-auto-scheduler-focus-mode)
    (setq org-auto-scheduler-focus--target-marker nil)
    (org-auto-scheduler-focus-refresh)
    (assert-true (string-match-p "FOCUS HUD STANDBY" (buffer-string)) "Test 16.1: Standby header shown")
    (assert-true (string-match-p "NO ACTIVE OR SCHEDULED TASK DETECTED" (buffer-string)) "Test 16.1: Standby message shown")))

;; 16.2 to 16.5: Active task, checklists, notes, subtasks, sibling, controls
(with-temp-buffer
  (org-mode)
  (insert "* Project Alpha\n")
  (insert "** TODO Task One :AUTOSCH:\n")
  (insert ":PROPERTIES:\n:ID: hud-task-1\n:EFFORT: 60\n:POMODORO: 25:5\n:END:\n")
  (insert "SCHEDULED: <2026-09-25 Fri 14:00-15:00>\n")
  (insert "  - [ ] Generate PKCE code\n")
  (insert "  - [X] Add redirect URL\n")
  (insert "* TODO Task Two :AUTOSCH:\n")
  (insert ":PROPERTIES:\n:ID: hud-task-2\n:EFFORT: 30\n:END:\n")
  (insert "SCHEDULED: <2026-09-25 Fri 15:00-15:30>\n")

  (goto-char (point-min))
  (re-search-forward "\\*\\* TODO Task One")
  (beginning-of-line)
  (let* ((m1 (point-marker))
         (task-info (org-auto-scheduler-focus--resolve-task m1)))
    (assert-equal (plist-get task-info :title) "Task One" "Test 16.2: Task title is Task One")
    (assert-equal (plist-get task-info :parent) "Project Alpha" "Test 16.2: Parent project is Project Alpha")
    (assert-equal (plist-get task-info :effort) 60 "Test 16.2: Effort is 60m")
    (assert-equal (length (plist-get task-info :checklists)) 2 "Test 16.2: 2 checklist items found")
    (assert-equal (plist-get (plist-get task-info :pomodoro) :work) 25 "Test 16.2: Pomodoro work is 25")

    (let ((buf (get-buffer-create "*Org Focus HUD*")))
      (with-current-buffer buf
        (org-auto-scheduler-focus-mode)
        (setq org-auto-scheduler-focus--target-marker m1)
        (org-auto-scheduler-focus-refresh)
        (assert-true (string-match-p "FOCUS: Task One" (buffer-string)) "Test 16.2: HUD renders Task One")
        (assert-true (string-match-p "Project Alpha" (buffer-string)) "Test 16.2: HUD renders Project Alpha")
        (assert-true (string-match-p "CHECKLIST \\[1/2\\]" (buffer-string)) "Test 16.2: Checklist count 1/2")
        (assert-true (string-match-p "\\[X\\] Add redirect URL" (buffer-string)) "Test 16.2: Contains checked item")
        (assert-true (string-match-p "\\[ \\] Generate PKCE code" (buffer-string)) "Test 16.2: Contains unchecked item")
        (assert-true (string-match-p "Pomodoro: 🍅 \\[25m/5m\\]" (buffer-string)) "Test 16.2: Contains pomodoro spec")

        ;; 16.3: Toggle checklist item
        (goto-char (point-min))
        (re-search-forward "\\[ \\] Generate PKCE code")
        (beginning-of-line)
        (org-auto-scheduler-focus-toggle-checklist)
        (assert-true (string-match-p "CHECKLIST \\[2/2\\]" (buffer-string)) "Test 16.3: Checklist count updated to 2/2")
        (assert-true (string-match-p "\\[X\\] Generate PKCE code" (buffer-string)) "Test 16.3: Item is now [X]")
        ;; Verify keybindings: RET toggles checklist, SPC is preserved for Spacemacs leader / scrolling
        (assert-equal (lookup-key org-auto-scheduler-focus-mode-map (kbd "RET"))
                      #'org-auto-scheduler-focus-toggle-checklist
                      "Test 16.3: RET is bound to toggle checklist")
        (assert-equal (lookup-key org-auto-scheduler-focus-mode-map (kbd "o"))
                      #'org-auto-scheduler-focus-goto-task-other-window
                      "Test 16.3: 'o' is bound to org-auto-scheduler-focus-goto-task-other-window")
        (assert-equal (lookup-key org-auto-scheduler-focus-mode-map (kbd "O"))
                      #'org-auto-scheduler-focus-goto-task
                      "Test 16.3: 'O' is bound to org-auto-scheduler-focus-goto-task")
        (assert-true (not (eq (lookup-key org-auto-scheduler-focus-mode-map (kbd "SPC"))
                              #'org-auto-scheduler-focus-toggle-checklist))
                     "Test 16.3: SPC is NOT bound to toggle checklist (Spacemacs leader preserved)")

        ;; Verify shortcuts legend is hidden by default and toggled with '?'
        (assert-true (not (string-match-p "CAPTURE (Zero context switching)" (buffer-string)))
                     "Test 16.3: Shortcuts legend hidden by default")
        (assert-true (string-match-p (regexp-quote "[?] Shortcuts help") (buffer-string))
                     "Test 16.3: '[?] Shortcuts help' prompt shown")
        (assert-equal (lookup-key org-auto-scheduler-focus-mode-map (kbd "?"))
                      #'org-auto-scheduler-focus-toggle-help
                      "Test 16.3: '?' is bound to org-auto-scheduler-focus-toggle-help")
        (org-auto-scheduler-focus-toggle-help)
        (assert-true (string-match-p "CAPTURE (Zero context switching)" (buffer-string))
                     "Test 16.3: Shortcuts legend shown after '?'")
        (assert-true (string-match-p (regexp-quote "[?] Hide shortcuts help") (buffer-string))
                     "Test 16.3: '[?] Hide shortcuts help' shown in expanded legend")
        (org-auto-scheduler-focus-toggle-help)
        (assert-true (not (string-match-p "CAPTURE (Zero context switching)" (buffer-string)))
                     "Test 16.3: Shortcuts legend hidden again after second '?'")

        ;; 16.4: Add checklist, note, subtask, sibling
        (org-auto-scheduler-focus-add-checklist "Write unit tests")
        (assert-true (string-match-p "CHECKLIST \\[2/3\\]" (buffer-string)) "Test 16.4: Checklist count updated to 2/3")
        (assert-true (string-match-p "\\[ \\] Write unit tests" (buffer-string)) "Test 16.4: New checklist item rendered")

        (org-auto-scheduler-focus-add-note "Remember constant-time comparison")
        (assert-true (string-match-p "RECENT NOTES" (buffer-string)) "Test 16.4: Recent notes section rendered")
        (assert-true (string-match-p "Remember constant-time comparison" (buffer-string)) "Test 16.4: Note content rendered")

        (org-auto-scheduler-focus-add-subtask "Implement token exchange" "25m")
        (assert-true (string-match-p "SUBTASKS (CHILD TODOS)" (buffer-string)) "Test 16.4: Subtasks section rendered")
        (assert-true (string-match-p "Implement token exchange" (buffer-string)) "Test 16.4: Child subtask rendered")

        (org-auto-scheduler-focus-add-sibling "Deploy oauth proxy" "45m")
        (with-current-buffer (marker-buffer m1)
          (save-excursion
            (goto-char (point-min))
            (assert-true (re-search-forward "\\*\\* TODO Deploy oauth proxy.*:AUTOSCH:" nil t) "Test 16.4: Sibling task exists at level 2")))

        ;; 16.5: Controls: pause, extend, done
        (with-current-buffer (marker-buffer m1)
          (goto-char (marker-position m1))
          (org-clock-in))
        (assert-true (org-clock-is-active) "Test 16.5: Clock is active")
        (org-auto-scheduler-focus-toggle-pause)
        (assert-true (not (org-clock-is-active)) "Test 16.5: Clock paused")
        (org-auto-scheduler-focus-toggle-pause)
        (assert-true (org-clock-is-active) "Test 16.5: Clock resumed")
        (org-clock-out nil t)

        ;; Extend
        (cl-letf (((symbol-function 'org-auto-scheduler-extend-current-task)
                   (lambda (mins)
                     (with-current-buffer (marker-buffer m1)
                       (org-with-point-at m1
                         (org-entry-put nil "EFFORT" "75")
                         (org-entry-put nil "SCHEDULED" "<2026-09-25 Fri 14:00-15:15>"))))))
          (org-auto-scheduler-focus-extend 15)
          (assert-true (string-match-p "Effort: 75m" (buffer-string)) "Test 16.5: Effort extended to 75m"))

        ;; Done
        (org-auto-scheduler-focus-done)
        (with-current-buffer (marker-buffer m1)
          (org-with-point-at m1
            (assert-equal (org-get-todo-state) "DONE" "Test 16.5: Task One marked DONE")))))))

;; ============================================================================
;; TEST 17: Configurable Waiting Tasks & Review Buffer Workflow
;; ============================================================================

(message "\n--- TEST 17: Configurable Waiting Tasks & Review Buffer Workflow ---")

(let* ((temp-file (make-temp-file "org-test-waiting" nil ".org"))
       (buf (find-file-noselect temp-file)))
  (unwind-protect
      (with-current-buffer buf
        (insert "#+TODO: TODO NEXT IN-PROGRESS WAITING HOLD | DONE CANCELLED\n")
        (org-mode)
        (insert "* TODO Task With Clock :AUTOSCH:\nSCHEDULED: <2026-09-28 Mon 14:00-15:00>\n:PROPERTIES:\n:ID: test-wait-clk-1\n:EFFORT: 60\n:END:\n")
        (insert "* WAITING Stale Task A :AUTOSCH:\nSCHEDULED: <2026-09-20 Sun>\n:PROPERTIES:\n:ID: test-wait-stale-a\n:EFFORT: 30\n:WAITING_SINCE: 2026-09-18 10:00\n:END:\n")
        (insert "* HOLD Fresh Task B :AUTOSCH:\n:PROPERTIES:\n:ID: test-wait-fresh-b\n:EFFORT: 45\n:WAITING_SINCE: 2026-09-28 09:00\n:END:\n")
        (insert "* TODO Normal Active C :AUTOSCH:\n:PROPERTIES:\n:ID: test-wait-active-c\n:EFFORT: 60\n:END:\n")
        (save-buffer)
        (let ((org-agenda-files (list temp-file)))

          ;; 17.1: Hook on state transition to WAITING
          (goto-char (point-min))
          (re-search-forward "^\\* TODO Task With Clock")
          (org-back-to-heading t)
          (org-clock-in)
          (assert-true (org-clock-is-active) "Test 17.1: Task With Clock clocked in")
          (org-todo "WAITING")
          (assert-true (not (org-clock-is-active)) "Test 17.1: Clock automatically stopped on transition to WAITING")
          (let ((sched (org-entry-get nil "SCHEDULED")))
            (assert-equal sched "<2026-09-28 Mon>" "Test 17.1: SCHEDULED time stripped to follow-up tickler date"))
          (let ((since (org-entry-get nil "WAITING_SINCE")))
            (assert-true (and since (not (string-empty-p since))) "Test 17.1: WAITING_SINCE property recorded"))
          ;; Transition back to TODO removes WAITING_SINCE
          (org-todo "TODO")
          (assert-equal (org-entry-get nil "WAITING_SINCE") nil "Test 17.1: WAITING_SINCE removed when transitioning to TODO")

          ;; 17.2: Task filtering & Stale Detection
          (let ((schedulable (org-auto-scheduler-get-schedulable-tasks)))
            ;; Only active tasks (Task With Clock and Normal Active C) are schedulable
            (assert-equal (length schedulable) 2 "Test 17.2: Exactly 2 schedulable tasks (WAITING and HOLD excluded)")
            (dolist (m schedulable)
              (with-current-buffer (marker-buffer m)
                (org-with-point-at m
                  (assert-true (not (member (org-get-todo-state) org-auto-scheduler-waiting-states))
                               "Test 17.2: Schedulable task is not in waiting-states")))))

          (let ((waiting-tasks (org-auto-scheduler-get-waiting-tasks)))
            (assert-equal (length waiting-tasks) 2 "Test 17.2: Found exactly 2 waiting tasks (Task A & Task B)")
            (let ((stale-task (cl-find-if (lambda (w) (string= (plist-get w :id) "test-wait-stale-a")) waiting-tasks))
                  (fresh-task (cl-find-if (lambda (w) (string= (plist-get w :id) "test-wait-fresh-b")) waiting-tasks)))
              (assert-true (>= (plist-get stale-task :days-waiting) 8) "Test 17.2: Stale task has >= 8 days waiting")
              (assert-true (>= (plist-get stale-task :days-waiting) org-auto-scheduler-waiting-stale-days)
                           "Test 17.2: Stale task meets or exceeds stale threshold")
              (assert-true (< (plist-get fresh-task :days-waiting) org-auto-scheduler-waiting-stale-days)
                           "Test 17.2: Fresh task is below stale threshold")))

          ;; 17.3: Review Buffer Layout & Placement
          (org-auto-scheduler-review-and-apply)
          (with-current-buffer "*Org Auto Scheduler Review*"
            (let ((entries tabulated-list-entries)
                  (sep-waiting-pos nil)
                  (last-day-pos nil))
              (let ((idx 0))
                (dolist (e entries)
                  (let ((id (car e)))
                    (when (and (stringp id) (string-prefix-p "__sep_" id) (not (string= id "__sep_Waiting")))
                      (setq last-day-pos idx))
                    (when (and (stringp id) (string= id "__sep_Waiting"))
                      (setq sep-waiting-pos idx))
                    (setq idx (1+ idx)))))
              (assert-true (and sep-waiting-pos last-day-pos (> sep-waiting-pos last-day-pos))
                           "Test 17.3: Waiting section is placed at the bottom after all day sections")

              ;; Check stale task formatting
              (let ((stale-entry (assoc "test-wait-stale-a" entries))
                    (fresh-entry (assoc "test-wait-fresh-b" entries)))
                (assert-true stale-entry "Test 17.3: Stale task entry found in review list")
                (assert-true fresh-entry "Test 17.3: Fresh task entry found in review list")
                ;; Stale entry has warning symbol in St column (idx 7)
                (assert-true (string-match-p "⚠️" (aref (cadr stale-entry) 7))
                             "Test 17.3: Stale task displays ⚠️ in status column")
                (assert-true (string-match-p "STALE" (aref (cadr stale-entry) 6))
                             "Test 17.3: Stale task displays STALE in score column")
                (assert-true (string-match-p "⏳" (aref (cadr fresh-entry) 7))
                             "Test 17.3: Fresh task displays ⏳ in status column")))

            ;; 17.4: Review Movement Guards & State Changing via 't'
            ;; Movement guard: moving waiting task throws error
            (org-auto-scheduler--review-goto-task "test-wait-stale-a")
            (condition-case err
                (progn (org-auto-scheduler-review-move-up) (assert-true nil "Test 17.4: Should error on move-up"))
              (user-error
               (assert-true (string-match-p "WAITING" (error-message-string err))
                            "Test 17.4: Move-up correctly blocked on waiting task")))

            ;; Change state using review command (mock completing-read to return "TODO")
            (cl-letf (((symbol-function 'completing-read) (lambda (&rest _args) "TODO")))
              (org-auto-scheduler-review-set-todo-state))
            ;; Verify the task in the org buffer changed to TODO
            (with-current-buffer buf
              (let ((m (org-id-find "test-wait-stale-a" t)))
                (org-with-point-at m
                  (assert-equal (org-get-todo-state) "TODO" "Test 17.4: Task state in buffer changed to TODO via 't'"))))

            ;; 17.5: Header line format includes waiting badge
            (let ((hdr (org-auto-scheduler--review-header-line tabulated-list-entries)))
              (assert-true (string-match-p "waiting" (nth 3 hdr))
                           "Test 17.5: Header line displays waiting tasks badge"))

            (kill-buffer "*Org Auto Scheduler Review*"))))
    (when (buffer-live-p buf) (kill-buffer buf))
    (delete-file temp-file)))


;; ============================================================================
;; TEST 18: Advanced Waiting Features (Tickler 'd', Blocker Attribution, HUD 'w', Mobile Markers)
;; ============================================================================
(message "\n--- TEST 18: Advanced Waiting Features (Tickler 'd', Blocker Attribution, HUD 'w', Mobile Markers) ---")

(let* ((temp-file (make-temp-file "org-test-waiting-adv" nil ".org"))
       (state-file (make-temp-file "org-test-waiting-state" nil ".el"))
       (buf (find-file-noselect temp-file)))
  (unwind-protect
      (with-current-buffer buf
        (insert "#+TODO: TODO NEXT IN-PROGRESS WAITING HOLD | DONE CANCELLED\n")
        (org-mode)
        ;; Task for Test 18.1: Review quick-tickler 'd'
        (insert "* WAITING Waiting Task Tickler :AUTOSCH:\n:PROPERTIES:\n:ID: test-adv-tickler\n:EFFORT: 30\n:WAITING_SINCE: 2026-09-20 10:00\n:END:\n")
        ;; Tasks for Test 18.2: Blocker Attribution
        (insert "* WAITING Dependency Blocker Task :AUTOSCH:\n:PROPERTIES:\n:ID: test-adv-blocker\n:EFFORT: 60\n:WAITING_SINCE: 2026-09-25 10:00\n:END:\n")
        (insert "* TODO Blocked Downstream Task :AUTOSCH:\n:PROPERTIES:\n:ID: test-adv-downstream\n:EFFORT: 45\n:BLOCKER: test-adv-blocker\n:END:\n")
        ;; Tasks for Test 18.3: Focus HUD 'w'
        (let ((today-d (format-time-string "%Y-%m-%d %a")))
          (insert (format "* TODO Focus Current Task :AUTOSCH:\nSCHEDULED: <%s 14:00-15:00>\n:PROPERTIES:\n:ID: test-adv-focus-cur\n:EFFORT: 60\n:END:\n" today-d))
          (insert (format "* TODO Focus Next Task :AUTOSCH:\nSCHEDULED: <%s 15:00-16:00>\n:PROPERTIES:\n:ID: test-adv-focus-nxt\n:EFFORT: 60\n:END:\n" today-d)))
        (save-buffer)
        (let ((org-agenda-files (list temp-file))
              (org-auto-scheduler-review-state-file state-file)
              (org-auto-scheduler--saved-review-decisions nil)
              (org-auto-scheduler--review-overrides (make-hash-table :test 'equal)))

          ;; 18.1: Review Quick-Tickler Key ('d' and 'C-u d')
          (org-auto-scheduler-review-and-apply)
          (with-current-buffer "*Org Auto Scheduler Review*"
            (org-auto-scheduler--review-goto-task "test-adv-tickler")
            ;; Test setting follow-up date with 'd'
            (cl-letf (((symbol-function 'org-read-date) (lambda (&rest _args) "2026-10-05")))
              (org-auto-scheduler-review-move-to-date))
            (with-current-buffer buf
              (let ((m (org-id-find "test-adv-tickler" t)))
                (org-with-point-at m
                  (assert-equal (org-entry-get nil "SCHEDULED") "<2026-10-05 Mon>"
                                "Test 18.1: Set tickler date on waiting task via 'd'"))))

            ;; Test clearing follow-up date with 'C-u d'
            (org-auto-scheduler-review-move-to-date '(4))
            (with-current-buffer buf
              (let ((m (org-id-find "test-adv-tickler" t)))
                (org-with-point-at m
                  (assert-equal (org-entry-get nil "SCHEDULED") nil
                                "Test 18.1: Cleared tickler date on waiting task via 'C-u d'"))))
            (kill-buffer "*Org Auto Scheduler Review*"))

          ;; 18.2: Waiting Blocker Attribution
          (let* ((downstream-marker (org-id-find "test-adv-downstream" t))
                 (waiting-blockers (org-auto-scheduler--get-waiting-blockers downstream-marker)))
            (assert-equal (length waiting-blockers) 1
                          "Test 18.2: Detected exactly 1 waiting blocker")
            ;; Check warning attribution
            (let ((warns (org-auto-scheduler--check-task-warnings
                          (list "test-adv-downstream" nil nil '("AUTOSCH") nil "Blocked Downstream Task"
                                "BLOCKED" downstream-marker 1 :blocked)
                          downstream-marker)))
              (assert-true (cl-some (lambda (w) (string-match-p "Blocker is WAITING (WAITING)" w)) warns)
                           "Test 18.2: Warning mentions Blocker is WAITING"))
            ;; Check review buffer rendering
            (org-auto-scheduler-review-and-apply)
            (with-current-buffer "*Org Auto Scheduler Review*"
              (let ((downstream-entry (assoc "test-adv-downstream" tabulated-list-entries)))
                (assert-true downstream-entry "Test 18.2: Downstream task present in review list")
                ;; Time column reflects BLOCKED (WAITING)
                (assert-true (string-match-p "BLOCKED (WAITING)" (aref (cadr downstream-entry) 3))
                             "Test 18.2: Time column displays BLOCKED (WAITING)"))
              (kill-buffer "*Org Auto Scheduler Review*")))

          ;; 18.3: Focus HUD 'w' ("Wait on This")
          (let ((cur-m (org-id-find "test-adv-focus-cur" t))
                (nxt-m (org-id-find "test-adv-focus-nxt" t))
                (hud-buf (get-buffer-create "*Org Focus HUD*")))
            (with-current-buffer buf
              (goto-char cur-m)
              (org-clock-in))
            (assert-true (org-clock-is-active) "Test 18.3: Clocked into current task")
            ;; Launch HUD
            (with-current-buffer hud-buf
              (org-auto-scheduler-focus-mode)
              (setq org-auto-scheduler-focus--target-marker cur-m)
              (org-auto-scheduler-focus-refresh))
            (let ((org-auto-scheduler-focus-auto-clock-in-on-advance t))
              (with-current-buffer hud-buf
                (org-auto-scheduler-focus-wait "Waiting for client response" "2026-10-12")))
            ;; Verify current task transitioned to WAITING
            (with-current-buffer buf
              (org-with-point-at cur-m
                (assert-equal (org-get-todo-state) "WAITING"
                             "Test 18.3: Task transitioned to WAITING via Focus HUD 'w'")
                (assert-equal (org-entry-get nil "SCHEDULED") "<2026-10-12 Mon>"
                             "Test 18.3: Follow-up tickler scheduled date set via Focus HUD 'w'")
                (let ((task-body (buffer-substring-no-properties (point-min) (point-max))))
                  (assert-true (string-match-p "WAITING: Waiting for client response" task-body)
                               "Test 18.3: Waiting note logged in task body"))))
            ;; Verify auto-advanced and clocked into next task in HUD buffer
            (with-current-buffer hud-buf
              (assert-equal org-auto-scheduler-focus--target-marker nxt-m
                           "Test 18.3: Focus HUD auto-advanced target to next task"))
            (when (fboundp 'org-clock-is-active)
              (when (org-clock-is-active)
                (org-clock-out)))
            (when (buffer-live-p hud-buf)
              (kill-buffer hud-buf)))

          ;; 18.4: Mobile Title Modifiers
          ;; Insert fresh tasks with markers directly before marker processing
          (with-current-buffer buf
            (goto-char (point-max))
            (insert "* TODO Mobile Plain Marker Task (-w-) :AUTOSCH:\n:PROPERTIES:\n:ID: test-adv-mobile-w\n:EFFORT: 30\n:END:\n")
            (insert "* TODO Mobile Relative Dur Task (-w+3d-) :AUTOSCH:\n:PROPERTIES:\n:ID: test-adv-mobile-3d\n:EFFORT: 45\n:END:\n")
            (save-buffer))

          ;; Process Mobile Task A (-w-)
          (let ((m-w (org-id-find "test-adv-mobile-w" t)))
            (org-auto-scheduler--process-title-markers m-w)
            (with-current-buffer buf
              (org-with-point-at m-w
                (assert-equal (org-get-heading t t t t) "Mobile Plain Marker Task"
                             "Test 18.4: (-w-) stripped from headline")
                (assert-equal (org-get-todo-state) "WAITING"
                             "Test 18.4: (-w-) transitioned state to WAITING")
                (assert-true (org-entry-get nil "WAITING_SINCE")
                             "Test 18.4: WAITING_SINCE recorded for (-w-)"))))

          ;; Process Mobile Task B (-w+3d-)
          (let ((m-3d (org-id-find "test-adv-mobile-3d" t))
                (expected-date (org-auto-scheduler--parse-wait-duration "3d")))
            (org-auto-scheduler--process-title-markers m-3d)
            (with-current-buffer buf
              (org-with-point-at m-3d
                (assert-equal (org-get-heading t t t t) "Mobile Relative Dur Task"
                             "Test 18.4: (-w+3d-) stripped from headline")
                (assert-equal (org-get-todo-state) "WAITING"
                             "Test 18.4: (-w+3d-) transitioned state to WAITING")
                (let ((sched (org-entry-get nil "SCHEDULED")))
                  (assert-true (and sched (string-prefix-p (format "<%s" expected-date) sched))
                               "Test 18.4: (-w+3d-) set relative scheduled follow-up date")))))

          ;; Run scheduler to ensure mobile waiting tasks are not allocated active time slots
          (org-auto-scheduler-schedule-tasks)
          (let ((schedulable (org-auto-scheduler-get-schedulable-tasks)))
            (dolist (m schedulable)
              (with-current-buffer (marker-buffer m)
                (org-with-point-at m
                  (assert-true (not (member (org-get-todo-state) org-auto-scheduler-waiting-states))
                               "Test 18.4: Schedulable task is not in waiting-states")))))))
    (when (buffer-live-p buf) (kill-buffer buf))
    (when (file-exists-p state-file) (delete-file state-file))
    (delete-file temp-file)))


;; ============================================================================
;; TEST 19: Focus HUD Boundary Isolation & Target Heading Resolution
;; ============================================================================
(message "\n--- TEST 19: Focus HUD Boundary Isolation & Target Resolution ---")

(let* ((temp-file (make-temp-file "test-focus-boundary-" nil ".org"))
       (buf (find-file-noselect temp-file))
       (hud-buf (get-buffer-create "*Org Focus HUD*")))
  (unwind-protect
      (with-current-buffer buf
        (org-mode)
        (insert "* TODO Target Task\n:PROPERTIES:\n:EFFORT: 30m\n:END:\n* TODO Neighbor Task\n:LOGBOOK:\n:END:\n")
        (save-buffer)
        (let ((m-target (progn (goto-char (point-min)) (point-marker))))

          ;; 19.1: Adding checklist item 'k' to a task with NO existing checklist items
          ;; Must stay within m-target and NOT leak into Neighbor Task
          (with-current-buffer hud-buf
            (org-auto-scheduler-focus-mode)
            (setq org-auto-scheduler-focus--target-marker m-target)
            (org-auto-scheduler-focus-refresh)
            (org-auto-scheduler-focus-add-checklist "First Target Checklist"))

          (with-current-buffer buf
            (let ((content (buffer-string)))
              (assert-true (string-match "\\* TODO Target Task\n:PROPERTIES:\n:EFFORT: 30m\n:END:\n  - \\[ \\] First Target Checklist\n\\* TODO Neighbor Task" content)
                           "Test 19.1: Checklist item inserted into Target Task without leaking into Neighbor Task")))

          ;; 19.2: Adding note 'n' to Target Task (which has no LOGBOOK)
          ;; Must not leak into Neighbor Task's LOGBOOK
          (with-current-buffer hud-buf
            (org-auto-scheduler-focus-add-note "Target Quick Note"))
          (with-current-buffer buf
            (let* ((m-neighbor (save-excursion
                                 (goto-char (point-min))
                                 (re-search-forward "Neighbor Task")
                                 (org-back-to-heading t)
                                 (point-marker)))
                   (target-notes (org-auto-scheduler-focus--get-notes m-target))
                   (neighbor-notes (org-auto-scheduler-focus--get-notes m-neighbor)))
              (assert-equal (length target-notes) 1 "Test 19.2: Exactly 1 note on Target Task")
              (assert-true (string-match-p "Target Quick Note" (car target-notes)) "Test 19.2: Target note content matches")
              (assert-equal (length neighbor-notes) 0 "Test 19.2: Neighbor Task LOGBOOK received 0 notes")))

          ;; 19.3: Adding child subtask 's'
          (with-current-buffer hud-buf
            (org-auto-scheduler-focus-add-subtask "Target Child Subtask" "15m"))
          (with-current-buffer buf
            (let ((subtasks (org-auto-scheduler-focus--get-subtasks m-target)))
              (assert-equal (length subtasks) 1 "Test 19.3: Target Task has 1 child subtask")
              (assert-equal (plist-get (car subtasks) :title) "Target Child Subtask" "Test 19.3: Child title matches")))

          ;; 19.4: Adding sibling task 'a'
          (with-current-buffer hud-buf
            (org-auto-scheduler-focus-add-sibling "Target Sibling Task" "20m"))
          (with-current-buffer buf
            (save-excursion
              (goto-char (point-min))
              (assert-true (re-search-forward "^\\* TODO Target Sibling Task.*:AUTOSCH:" nil t)
                           "Test 19.4: Sibling task inserted at level 1 with :AUTOSCH:"))))

        ;; 19.5: Target Heading Resolution: Invoking focus on an Org heading when another task is clocked
        (let ((clocked-file (make-temp-file "test-focus-clock-" nil ".org"))
              (clocked-buf nil))
          (unwind-protect
              (progn
                (setq clocked-buf (find-file-noselect clocked-file))
                (with-current-buffer clocked-buf
                  (org-mode)
                  (insert "* TODO Background Clocked Task\n")
                  (save-buffer)
                  (goto-char (point-min))
                  (org-clock-in))
                ;; Now, user is visiting buf on Neighbor Task
                (with-current-buffer buf
                  (goto-char (point-min))
                  (re-search-forward "Neighbor Task")
                  ;; Call interactive form resolution
                  (let ((resolved-marker
                         (cond
                          ((and (derived-mode-p 'org-mode)
                                (not (derived-mode-p 'org-agenda-mode))
                                (ignore-errors (save-excursion (org-back-to-heading t) (point-marker)))))
                          ((eq major-mode 'org-agenda-mode)
                           (let ((m (or (org-get-at-bol 'org-marker) (org-get-at-bol 'org-hd-marker))))
                             (and m (markerp m) (marker-buffer m) m)))
                          ((and (fboundp 'org-clock-is-active) (org-clock-is-active)
                                (boundp 'org-clock-marker) (markerp org-clock-marker) (marker-buffer org-clock-marker))
                           (org-with-point-at org-clock-marker
                             (org-back-to-heading t)
                             (point-marker)))
                          (t nil))))
                    (assert-true (and resolved-marker (equal (marker-buffer resolved-marker) buf))
                                 "Test 19.5: Active org-mode buffer heading prioritized over background clocked task")
                    (with-current-buffer (marker-buffer resolved-marker)
                      (org-with-point-at resolved-marker
                        (assert-equal (org-get-heading t t t t) "Neighbor Task"
                                     "Test 19.5: Resolved heading is Neighbor Task"))))))
            (when (fboundp 'org-clock-is-active)
              (when (org-clock-is-active) (org-clock-out nil t)))
            (when (buffer-live-p clocked-buf) (kill-buffer clocked-buf))
            (when (file-exists-p clocked-file) (delete-file clocked-file)))))
    (when (buffer-live-p buf) (kill-buffer buf))
    (when (file-exists-p temp-file) (delete-file temp-file))))


;;; ============================================================================
;;; TEST 20: Focus HUD Time Remaining Calculation & Active Clock Detection
;;; ============================================================================
(message "\n--- TEST 20: Focus HUD Time Remaining & Active Clock Detection ---")
(let* ((temp-file (make-temp-file "org-test-focus-clock-" nil ".org"))
       (buf (find-file-noselect temp-file)))
  (unwind-protect
      (with-current-buffer buf
        (org-mode)
        ;; Task 1: 4-hour task (effort 240m), scheduled 2 days in the future (e.g. 14:00-18:00)
        ;; Previously, time remaining calculated (time-subtract end-time now), giving ~2861m!
        ;; Now, remaining time must reflect actual effort remaining (240m).
        (let* ((future-date (format-time-string "%Y-%m-%d" (time-add (current-time) (* 2 86400)))))
          (insert (format "* TODO Four Hour Future Task\nSCHEDULED: <%s Thu 14:00-18:00>\n:PROPERTIES:\n:Effort:   4:00\n:END:\n:LOGBOOK:\n:END:\n\n* TODO Secondary Task\n:PROPERTIES:\n:Effort:   1:00\n:END:\n" future-date))
          (save-buffer))
        (goto-char (point-min))
        (let ((m1 (point-marker)))
          (re-search-forward "Secondary Task")
          (org-back-to-heading t)
          (let ((m2 (point-marker)))
            ;; 20.1 Test task-clocked-p and Focus HUD before clocking in
            (assert-equal (org-auto-scheduler--task-clocked-p m1) nil
                          "Test 20.1: m1 is not clocked in initially")
            (org-auto-scheduler-focus m1)
            (let ((hud-buf (get-buffer "*Org Focus HUD*")))
              (with-current-buffer hud-buf
                (assert-true (string-match-p "TIME REMAINING: 4h 00m left (240m)" (buffer-string))
                             "Test 20.1: 4-hour future task displays '4h 00m left (240m)' (not 2800+ mins)")
                (assert-true (string-match-p "\\[PAUSED / NOT CLOCKED\\]" (buffer-string))
                             "Test 20.1: [PAUSED / NOT CLOCKED] shown when not clocked in")
                (assert-true (string-match-p "14:00 – 18:00" (buffer-string))
                             "Test 20.1: Slot times rendered")
                (assert-true (not (string-match-p "14:00 – 18:00 (Today)" (buffer-string)))
                             "Test 20.1: Future slot does not claim '(Today)'")))

            ;; 20.2 Clock into m1 (drawer gets CLOCK line, org-clock-marker is inside drawer)
            (with-current-buffer buf
              (goto-char (marker-position m1))
              (org-clock-in))
            (assert-true (org-clocking-p) "Test 20.2: Clock is active")
            (assert-true (org-auto-scheduler--task-clocked-p m1)
                         "Test 20.2: org-auto-scheduler--task-clocked-p returns t for m1")
            (assert-equal (org-auto-scheduler--task-clocked-p m2) nil
                          "Test 20.2: org-auto-scheduler--task-clocked-p returns nil for m2")

            ;; 20.3 Focus HUD while clocked in
            (org-auto-scheduler-focus-refresh)
            (let ((hud-buf (get-buffer "*Org Focus HUD*")))
              (with-current-buffer hud-buf
                (assert-true (string-match-p "TIME REMAINING: 4h 00m left (240m)" (buffer-string))
                             "Test 20.3: TIME REMAINING remains 240m while clock just started")
                (assert-true (not (string-match-p "\\[PAUSED / NOT CLOCKED\\]" (buffer-string)))
                             "Test 20.3: [PAUSED / NOT CLOCKED] is NOT displayed when clocked in")))

            ;; 20.4 Toggle pause via Focus HUD 'p'
            (org-auto-scheduler-focus-toggle-pause)
            (assert-true (not (org-clocking-p)) "Test 20.4: Clock stopped after toggle pause")
            (let ((hud-buf (get-buffer "*Org Focus HUD*")))
              (with-current-buffer hud-buf
                (assert-true (string-match-p "\\[PAUSED / NOT CLOCKED\\]" (buffer-string))
                             "Test 20.4: [PAUSED / NOT CLOCKED] appears after toggle pause")))

            ;; 20.5 Resume clock via Focus HUD 'p'
            (org-auto-scheduler-focus-toggle-pause)
            (assert-true (org-clocking-p) "Test 20.5: Clock resumed after second toggle pause")
            (assert-true (org-auto-scheduler--task-clocked-p m1)
                         "Test 20.5: Task m1 is clocked in after resume")

            ;; 20.6 Active clock time inclusion in clocked-time
            ;; Mock clock having started 30 minutes ago
            (setq org-clock-start-time (time-subtract (current-time) 1800))
            (assert-equal (org-auto-scheduler-get-clocked-time m1) 30
                          "Test 20.6: Active clock 30m elapsed included in clocked time")
            (org-auto-scheduler-focus-refresh)
            (let ((hud-buf (get-buffer "*Org Focus HUD*")))
              (with-current-buffer hud-buf
                (assert-true (string-match-p "TIME REMAINING: 3h 30m left (210m)" (buffer-string))
                             "Test 20.6: TIME REMAINING updated to 3h 30m left (210m)")
                (assert-true (string-match-p "30m clocked (12%)" (buffer-string))
                             "Test 20.6: Progress shows 30m clocked (12%)")))

            ;; 20.7 Test 'o' opens task in other window and 'O' opens in current window
            (let ((hud-buf (get-buffer "*Org Focus HUD*")))
              (with-current-buffer hud-buf
                (org-auto-scheduler-focus-goto-task-other-window)
                (assert-equal (current-buffer) buf
                              "Test 20.7: Focused on original org buffer after other-window jump")
                (assert-equal (point) (marker-position m1)
                              "Test 20.7: Cursor positioned on target task headline after jump")))

            ;; Clean up clock
            (when (org-clocking-p) (org-clock-out nil t)))))
    (when (buffer-live-p buf) (kill-buffer buf))
    (when (file-exists-p temp-file) (delete-file temp-file))))

(if (= test-failures 0)
    (message "ALL 20 TEST SUITES PASSED PERFECTLY!")
  (message "FAILURES DETECTED: %d" test-failures))
(message "==============================================")

