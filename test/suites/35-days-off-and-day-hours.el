;;; 35-days-off-and-day-hours.el --- Date-specific days off and working hours -*- lexical-binding: t -*-

;; Loaded by test/oas-suites-test.el; uses helpers from test/test-helper.el.

(message "\n--- TEST 35: Days Off and Per-Day Working Hours ---")

(require 'holidays)

(defun t35-first-slot (&rest bindings)
  "Schedule one 60-minute task on Mon 2026-01-05 08:00 under BINDINGS.
BINDINGS is a plist of option symbols and values.  Return its SCHEDULED string."
  (let* ((test-fixed-now (encode-time 0 0 8 5 1 2026))
         (dir (make-temp-file "oas-t35-" t))
         (file (expand-file-name "t.org" dir))
         (org-agenda-files (list file))
         (inhibit-message t)
         (syms '()) (vals '()))
    (while bindings
      (push (pop bindings) syms)
      (push (pop bindings) vals))
    (with-temp-file file
      (insert "* TODO Write report :AUTOSCH:\n:PROPERTIES:\n:ID: t35-task\n:Effort: 60\n:END:\n"))
    (unwind-protect
        (cl-progv syms vals
          (clrhash org-auto-scheduler--holiday-cache)
          (org-auto-scheduler-schedule-tasks)
          (with-current-buffer (find-file-noselect file)
            (goto-char (point-min))
            (prog1 (org-entry-get nil "SCHEDULED")
              (set-buffer-modified-p nil)
              (kill-buffer))))
      (delete-directory dir t))))

(assert-equal (t35-first-slot)
              "<2026-01-05 Mon 09:00-10:00>"
              "Test 35.1: Baseline lands on Monday at the start time")
(assert-equal (t35-first-slot 'org-auto-scheduler-excluded-days '(1))
              "<2026-01-06 Tue 09:00-10:00>"
              "Test 35.1b: An excluded weekday is skipped even when the run starts on it")
(assert-equal (t35-first-slot 'org-auto-scheduler-days-off '("2026-01-05"))
              "<2026-01-06 Tue 09:00-10:00>"
              "Test 35.2: A single day off moves the task to the next day")
(assert-equal (t35-first-slot 'org-auto-scheduler-days-off '(("2026-01-05" . "2026-01-07")))
              "<2026-01-08 Thu 09:00-10:00>"
              "Test 35.3: A date range is skipped inclusively")
(assert-equal (t35-first-slot 'org-auto-scheduler-skip-holidays t
                              'calendar-holidays '((holiday-fixed 1 5 "Test holiday")))
              "<2026-01-06 Tue 09:00-10:00>"
              "Test 35.4: A calendar holiday is a day off when skip-holidays is on")
(assert-equal (t35-first-slot 'org-auto-scheduler-skip-holidays nil
                              'calendar-holidays '((holiday-fixed 1 5 "Test holiday")))
              "<2026-01-05 Mon 09:00-10:00>"
              "Test 35.5: Holidays are ignored when skip-holidays is off")
(assert-equal (t35-first-slot 'org-auto-scheduler-day-hours '((1 . ("13:00" . "17:00"))))
              "<2026-01-05 Mon 13:00-14:00>"
              "Test 35.6: A weekday hours override sets that day's start")
(assert-equal (t35-first-slot 'org-auto-scheduler-day-hours '((1 . ("13:00" . "17:00"))
                                                              ("2026-01-05" . ("10:30" . "12:00"))))
              "<2026-01-05 Mon 10:30-11:30>"
              "Test 35.7: A date override wins over a weekday override")
(assert-equal (t35-first-slot 'org-auto-scheduler-day-hours '(("2026-01-05" . ("09:00" . "09:30"))))
              "<2026-01-06 Tue 09:00-10:00>"
              "Test 35.8: A task that does not fit a short day moves to the next day")

;; Review-buffer day stepping skips days off.
(let ((org-auto-scheduler-days-off '("2026-01-06"))
      (org-auto-scheduler-excluded-days '(0 6)))
  (assert-equal (org-auto-scheduler--next-day-date-string "2026-01-05") "2026-01-07"
                "Test 35.9: Next-day stepping skips a day off")
  (assert-equal (org-auto-scheduler--next-day-date-string "2026-01-09") "2026-01-12"
                "Test 35.10: Next-day stepping still skips excluded weekdays")
  (assert-equal (org-auto-scheduler--prev-day-date-string "2026-01-07") "2026-01-05"
                "Test 35.11: Previous-day stepping skips a day off"))

;; Config validation rejects malformed entries.
(dolist (case '((org-auto-scheduler-days-off ("2026-1-5"))
                (org-auto-scheduler-days-off (("2026-01-07" . "2026-01-05")))
                (org-auto-scheduler-day-hours ((9 . ("09:00" . "17:00"))))
                (org-auto-scheduler-day-hours ((1 . ("17:00" . "09:00"))))))
  (assert-true (cl-progv (list (car case)) (list (cadr case))
                 (condition-case nil (progn (org-auto-scheduler-validate-config) nil)
                   (error t)))
               (format "Test 35.12: validate-config rejects %S = %S" (car case) (cadr case))))
(assert-true (let ((org-auto-scheduler-days-off '("2026-01-05" ("2026-02-01" . "2026-02-03")))
                   (org-auto-scheduler-day-hours '((5 . ("09:00" . "13:00")))))
               (condition-case nil (progn (org-auto-scheduler-validate-config) t)
                 (error nil)))
             "Test 35.13: validate-config accepts well-formed entries")

;; The working-hours bounds are cached per day.  Changing an option must be
;; picked up at once, even between runs (callers such as the review buffer and
;; the Task Inspector ask outside a run).
(let ((mon (encode-time 0 0 8 5 1 2026))
      (hh (lambda (tm) (format-time-string "%H:%M" tm))))
  (let ((org-auto-scheduler-day-hours nil))
    (assert-equal (funcall hh (org-auto-scheduler--day-start mon)) "09:00"
                  "Test 35.14a: Default start before any override"))
  (let ((org-auto-scheduler-day-hours '((1 . ("13:00" . "17:00")))))
    (assert-equal (funcall hh (org-auto-scheduler--day-start mon)) "13:00"
                  "Test 35.14b: A new weekday override is used immediately"))
  (let ((org-auto-scheduler-day-hours nil)
        (org-auto-scheduler-start-time "07:30"))
    (assert-equal (funcall hh (org-auto-scheduler--day-start mon)) "07:30"
                  "Test 35.14c: A changed start time is used immediately"))
  (let ((org-auto-scheduler-day-hours nil))
    (assert-equal (list (funcall hh (org-auto-scheduler--day-start mon))
                        (funcall hh (org-auto-scheduler--day-end (time-add mon (days-to-time 1)))))
                  '("09:00" "17:00")
                  "Test 35.14d: Back to defaults, and a different day is not served from the cache")))
