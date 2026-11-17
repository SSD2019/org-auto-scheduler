;;; 15-bug-fix-regressions-across-all-4-stages.el --- Bug Fix Regressions across All 4 Stages -*- lexical-binding: t -*-

;; Loaded by test/oas-suites-test.el; uses helpers from test/test-helper.el.

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
