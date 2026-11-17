;;; bench.el --- Scheduler benchmark -*- lexical-binding: t -*-

;;; Commentary:
;; `make bench' generates a deterministic Org file with OAS_BENCH_TASKS tasks
;; (default 500) spread over 20 projects, runs a preview (no buffer writes) of
;; the scheduler OAS_BENCH_RUNS times (default 3), and prints wall-clock times.
;; Use it to compare before/after when changing the engine.

;;; Code:

(require 'test-helper
         (expand-file-name "test-helper.el"
                           (file-name-directory (or load-file-name buffer-file-name))))

(defun oas-bench--write-fixture (file n)
  "Write N deterministic tasks to FILE."
  (with-temp-file file
    (insert "#+TITLE: Benchmark\n\n")
    (dotimes (i n)
      (when (zerop (% i 25))
        (insert (format "* Project %02d :PROJECT:\n" (/ i 25))))
      (insert (format "** TODO [#%c] Bench task %04d :AUTOSCH:%s\n"
                      (aref "ABC" (% i 3)) i
                      (if (zerop (% i 10)) "SPLITTABLE:" ""))
              (if (zerop (% i 7))
                  (format-time-string "DEADLINE: <%Y-%m-%d %a>\n"
                                      (time-add test-fixed-now (days-to-time (+ 3 (% i 40)))))
                "")
              (format ":PROPERTIES:\n:ID: bench-%04d\n:EFFORT: %d\n:END:\n"
                      i (* 15 (1+ (% i 8))))))))

(defun oas-bench-run ()
  "Generate the fixture, time preview runs, and print the results."
  (let* ((n (string-to-number (or (getenv "OAS_BENCH_TASKS") "500")))
         (runs (string-to-number (or (getenv "OAS_BENCH_RUNS") "3")))
         (dir (make-temp-file "oas-bench-" t))
         (file (expand-file-name "bench.org" dir))
         (org-agenda-files (list file))
         (inhibit-message t)
         (times '()))
    (unwind-protect
        (progn
          (oas-bench--write-fixture file n)
          (find-file-noselect file)
          (dotimes (_ runs)
            ;; `current-time' is pinned by the helper; `float-time' reads the real clock.
            (let ((start (float-time))
                  (org-auto-scheduler--preview-mode t))
              (org-auto-scheduler-schedule-tasks)
              (push (- (float-time) start) times)))
          (let ((inhibit-message nil))
            (message "org-auto-scheduler bench: %d tasks, %d placed, runs: %s (best %.2fs)"
                     n (length org-auto-scheduler-completed-tasks)
                     (mapconcat (lambda (s) (format "%.2fs" s)) (nreverse times) " ")
                     (apply #'min times))))
      (delete-directory dir t))))

;;; bench.el ends here
