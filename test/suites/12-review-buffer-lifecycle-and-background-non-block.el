;;; 12-review-buffer-lifecycle-and-background-non-block.el --- Review Buffer Lifecycle and Background Non-Blocking -*- lexical-binding: t -*-

;; Loaded by test/oas-suites-test.el; uses helpers from test/test-helper.el.

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
