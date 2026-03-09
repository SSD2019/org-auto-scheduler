(require 'ert)
(load-file "/home/saisan/.vim/emacs_plugin/org-auto-scheduler/org-auto-scheduler.el")

(ert-deftest test-org-auto-scheduler-next-recurring-date-unsupported ()
  "Test if an unsupported recurring frequency throws an error."
  (let ((date (current-time)))
    (should-error (org-auto-scheduler-next-recurring-date date "yearly") :type 'error)))

(ert-deftest test-org-auto-scheduler-next-day-dst ()
  "Test next-day respects calendar days regardless of 24h duration during Fall Back DST (Nov 1, 2026).
In US/Eastern, 2026-11-01 falls back from EDT to EST.
Adding 24 hours (86400s) to 2026-11-01 00:00:00 yields 2026-11-01 23:00:00 (the same day).
The calendar-based method should correctly yield 2026-11-02 00:00:00."
  (let* ((system-time-locale "C")
         ;; Set timezone to US/Eastern
         (old-tz (getenv "TZ")))
    (setenv "TZ" "America/New_York")
    (unwind-protect
        (let* ((start-time (encode-time 0 0 0 1 11 2026)) ; Nov 1 2026 00:00:00 EDT
               (next-day-time (org-auto-scheduler-next-day start-time))
               (next-day-str (format-time-string "%Y-%m-%d %H:%M:%S" next-day-time)))
          ;; Should be Nov 2 2026 00:00:00 EST
          (should (string= next-day-str "2026-11-02 00:00:00")))
      (setenv "TZ" old-tz))))

;; Run tests if invoked non-interactively
(ert-run-tests-batch-and-exit)
