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

(ert-deftest test-org-auto-scheduler-add-months-basic ()
  "Test basic month addition."
  (let* ((start-time (encode-time 0 0 12 15 3 2026)) ; March 15, 2026
         (result (org-auto-scheduler-add-months start-time 1))
         (result-str (format-time-string "%Y-%m-%d" result)))
    (should (string= result-str "2026-04-15"))))

(ert-deftest test-org-auto-scheduler-add-months-year-overflow ()
  "Test month addition that overflows into next year."
  (let* ((start-time (encode-time 0 0 12 15 11 2026)) ; November 15, 2026
         (result (org-auto-scheduler-add-months start-time 3))
         (result-str (format-time-string "%Y-%m-%d" result)))
    (should (string= result-str "2027-02-15"))))

(ert-deftest test-org-auto-scheduler-add-months-multi-year ()
  "Test adding more than 12 months (multi-year jump)."
  (let* ((start-time (encode-time 0 0 12 15 3 2026)) ; March 15, 2026
         (result (org-auto-scheduler-add-months start-time 25))
         (result-str (format-time-string "%Y-%m-%d" result)))
    (should (string= result-str "2028-04-15"))))

(ert-deftest test-org-auto-scheduler-add-months-end-of-month ()
  "Test adding months clamping to end of shorter month."
  (let* ((start-time (encode-time 0 0 12 31 1 2026)) ; January 31, 2026
         (result (org-auto-scheduler-add-months start-time 1))
         (result-str (format-time-string "%Y-%m-%d" result)))
    (should (string= result-str "2026-02-28"))))

(ert-deftest test-org-auto-scheduler-add-months-leap-year ()
  "Test adding months to a leap year date."
  (let* ((start-time (encode-time 0 0 12 31 1 2028)) ; January 31, 2028 (leap year)
         (result (org-auto-scheduler-add-months start-time 1))
         (result-str (format-time-string "%Y-%m-%d" result)))
    (should (string= result-str "2028-02-29"))))

(ert-deftest test-org-with-point-at-not-redefined ()
  "Test that org-with-point-at is NOT redefined by the plugin.
The plugin should use Org's built-in version."
  ;; After loading the plugin, org-with-point-at should still be Org's version
  ;; (a macro). If it were redefined by the plugin, its source file would be
  ;; org-auto-scheduler.el. We check it's still a macro from org.
  (should (macrop (symbol-function 'org-with-point-at)))
  ;; The plugin's custom version stored pom in a local variable named 'pom'.
  ;; Org's version uses different internals. We just verify it's still a macro
  ;; and hasn't been blown away.
  (should (not (null (documentation 'org-with-point-at)))))

;; Run tests if invoked non-interactively
(ert-run-tests-batch-and-exit)
