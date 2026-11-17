;;; 08-background-run-change-logging.el --- Background Run Change Logging -*- lexical-binding: t -*-

;; Loaded by test/oas-suites-test.el; uses helpers from test/test-helper.el.

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
                   "Test 8.2: File contains Task Two")
      (assert-true (not (string-match-p "<[0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\}[^>\n]*>" file-str))
                   "Test 8.2: Change log file contains no active timestamps")
      (assert-true (string-match-p "Schedule: .*\\[[0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\}" file-str)
                   "Test 8.2: Change log file uses inactive timestamps for schedules")))

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
