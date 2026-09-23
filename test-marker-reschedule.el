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
        (assert-true bg-ran "Test 12.3: background-run executes when review buffer is not visible"))))

  (delete-directory temp-dir t))

(when (boundp 'test-orig-agenda-files) (setq org-agenda-files test-orig-agenda-files))

(message "\n==============================================")
(if (= test-failures 0)
    (message "ALL 12 TEST SUITES PASSED PERFECTLY!")
  (message "FAILURES DETECTED: %d" test-failures))
(message "==============================================")

