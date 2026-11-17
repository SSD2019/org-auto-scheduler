;;; 32-golden-demo-schedule.el --- Golden schedule for demo/demo-tasks.org -*- lexical-binding: t -*-

;; Loaded by test/oas-suites-test.el; uses helpers from test/test-helper.el.

;; Schedules a copy of demo/demo-tasks.org with default settings on a fixed
;; Monday and compares every resulting SCHEDULED timestamp with a recorded
;; list.  Any change to placement logic or defaults shows up here as a diff.
;;
;; If a change is intended, print the new list and paste it below:
;;   OAS_GOLDEN_PRINT=1 make test SELECTOR=oas-suite-32

(message "\n--- TEST 32: Golden Demo Schedule ---")

(defconst t32-expected
  '(("Architecture RFC: Real-time Event Streaming" . "+0 11:25-13:55")
    ("Architecture RFC: Real-time Event Streaming (Remaining)" . "+1 09:00-10:00")
    ("Fast CI/CD Build Pipeline Migration" . "+0 09:00-10:15")
    ("Update Developer Onboarding & API Docs" . "+0 14:50-15:35")
    ("Security Audit & Incident Post-Mortem Review" . "+0 14:00-14:45")
    ("Kubernetes Cluster Node Pool Scaling" . "+0 10:20-11:20"))
  "Expected (HEADING . \"+DAYS HH:MM-HH:MM\") pairs, in buffer order.")

(defun t32-demo-schedule (now)
  "Schedule a temp copy of the demo file as if the time were NOW.
Return (HEADING . \"+DAYS HH:MM-HH:MM\") for every scheduled entry, in buffer order."
  (let* ((temp-dir (make-temp-file "oas-golden-" t))
         (file (expand-file-name "demo-tasks.org" temp-dir))
         (test-fixed-now now)
         (org-agenda-files (list file))
         (day0 (time-to-days now))
         (result '()))
    ;; Start from clean state: a run saves review decisions (task order) that
    ;; the next run would otherwise pick up.
    (dolist (f (directory-files oas-test-state-dir t "\\`org-auto-scheduler-"))
      (delete-file f))
    (setq org-auto-scheduler--saved-review-decisions nil)
    (unwind-protect
        (progn
          (copy-file (expand-file-name "demo/demo-tasks.org" oas-test-root) file)
          (org-auto-scheduler-schedule-tasks)
          (with-current-buffer (find-file-noselect file)
            (org-map-entries
             (lambda ()
               (let ((sched (org-entry-get nil "SCHEDULED")))
                 (when sched
                   (push (cons (substring-no-properties (org-get-heading t t t t))
                               (format "+%d %s"
                                       (- (time-to-days (org-time-string-to-time sched)) day0)
                                       (if (string-match "[0-9]+:[0-9]+\\(-[0-9]+:[0-9]+\\)?" sched)
                                           (match-string 0 sched)
                                         "all-day")))
                         result)))))
            (set-buffer-modified-p nil)
            (kill-buffer)))
      (delete-directory temp-dir t))
    (nreverse result)))

(let ((actual (t32-demo-schedule (encode-time 0 0 8 5 1 2026)))) ; Mon 2026-01-05 08:00
  (when (getenv "OAS_GOLDEN_PRINT")
    (message "GOLDEN:\n%s" (pp-to-string actual)))
  (assert-true (>= (length actual) 5) "Test 32.1: Demo file produces a schedule")
  (assert-equal actual t32-expected "Test 32.2: Demo schedule matches the recorded golden list")
  (assert-equal (t32-demo-schedule (encode-time 0 0 8 1 3 2027)) ; Mon 2027-03-01 08:00
                actual
                "Test 32.3: Schedule is the same relative to any Monday"))
