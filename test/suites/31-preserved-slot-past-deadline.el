;;; 31-preserved-slot-past-deadline.el --- Preserved Slot Past Deadline -*- lexical-binding: t -*-

;; Loaded by test/oas-suites-test.el; uses helpers from test/test-helper.el.

;; ============================================================================
;; TEST 31: Preserved future slot after a still-reachable deadline is re-placed
;; ============================================================================
(message "\n--- TEST 31: Preserved Slot Past Deadline ---")

(with-temp-buffer
  (org-mode)
  (let* ((now (current-time))
         (today-str (format-time-string "%Y-%m-%d" now))
         (tmr (time-add now (days-to-time 1)))
         (yesterday (time-subtract now (days-to-time 1))))
    (insert (format "* TODO Due today\nDEADLINE: <%s>\n* TODO Due yesterday\nDEADLINE: <%s>\n* TODO Pinned due today :PINNED:\nDEADLINE: <%s>\n* TODO No deadline\n"
                    today-str
                    (format-time-string "%Y-%m-%d" yesterday)
                    today-str))
    (goto-char (point-min))
    (assert-true (org-auto-scheduler--slot-misses-deadline-p (point-marker) nil tmr today-str)
                 "Test 31.1: Slot tomorrow misses a deadline of today")
    (assert-equal (org-auto-scheduler--slot-misses-deadline-p (point-marker) nil now today-str) nil
                  "Test 31.2: Slot today meets a deadline of today")
    (outline-next-heading)
    (assert-equal (org-auto-scheduler--slot-misses-deadline-p (point-marker) nil tmr today-str) nil
                  "Test 31.3: Already-missed deadline does not force a reshuffle")
    (outline-next-heading)
    (assert-equal (org-auto-scheduler--slot-misses-deadline-p (point-marker) nil tmr today-str) nil
                  "Test 31.4: Pinned task keeps its slot past the deadline")
    (outline-next-heading)
    (assert-equal (org-auto-scheduler--slot-misses-deadline-p (point-marker) nil tmr today-str) nil
                  "Test 31.5: Task without a deadline is unaffected")))

(let* ((temp-dir (make-temp-file "org-test-" t))
       (test-org-file (expand-file-name "test-deadline.org" temp-dir))
       (now (current-time))
       (today-str (format-time-string "%Y-%m-%d" now))
       (today-dow (format-time-string "%a" now))
       (tmr (time-add now (days-to-time 1)))
       (tmr-str (format-time-string "%Y-%m-%d" tmr))
       (tmr-dow (format-time-string "%a" tmr))
       (org-auto-scheduler-sync-caldav nil)
       (org-auto-scheduler-silent-mode t)
       (org-auto-scheduler-preserve-today-scheduled t)
       (org-auto-scheduler-preserve-future-scheduled t)
       (org-auto-scheduler-start-time "00:00")
       (org-auto-scheduler-end-time "23:59")
       (org-auto-scheduler-task-gap 0))

  (with-temp-file test-org-file
    (insert (format "* Tasks :PROJECT:\n*** TODO Due Today :AUTOSCH:\nSCHEDULED: <%s %s 10:00-10:30> DEADLINE: <%s %s>\n:PROPERTIES:\n:Effort: 0:30\n:ID: deadline-id-1\n:END:\n*** TODO Tomorrow No Deadline :AUTOSCH:\nSCHEDULED: <%s %s 14:00-15:00>\n:PROPERTIES:\n:Effort: 1:00\n:ID: deadline-id-2\n:END:\n"
                    tmr-str tmr-dow today-str today-dow
                    tmr-str tmr-dow)))

  (setq org-agenda-files (list test-org-file))
  (org-auto-scheduler-schedule-tasks)

  (let ((t1 (with-current-buffer (find-file-noselect test-org-file)
              (goto-char (point-min))
              (re-search-forward ":ID:[ \t]*deadline-id-1")
              (org-entry-get nil "SCHEDULED")))
        (t2 (with-current-buffer (find-file-noselect test-org-file)
              (goto-char (point-min))
              (re-search-forward ":ID:[ \t]*deadline-id-2")
              (org-entry-get nil "SCHEDULED"))))
    (assert-true (and t1 (string-match-p (regexp-quote today-str) t1))
                 (format "Test 31.6: Task booked tomorrow with deadline today moves to today (actual: %s)" t1))
    (assert-equal t2 (format "<%s %s 14:00-15:00>" tmr-str tmr-dow)
                  "Test 31.7: Future task without a deadline stays preserved"))

  (when (get-file-buffer test-org-file) (kill-buffer (get-file-buffer test-org-file)))
  (delete-directory temp-dir t))
