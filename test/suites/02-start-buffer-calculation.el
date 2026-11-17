;;; 02-start-buffer-calculation.el --- Start Buffer Calculation -*- lexical-binding: t -*-

;; Loaded by test/oas-suites-test.el; uses helpers from test/test-helper.el.

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
