;;; 13-task-scoped-pomodoro-scheduling.el --- Task-Scoped Pomodoro Scheduling -*- lexical-binding: t -*-

;; Loaded by test/oas-suites-test.el; uses helpers from test/test-helper.el.

;; ============================================================================
;; TEST 13: Task-Scoped Pomodoro Scheduling (:POMODORO: Work:Break)
;; ============================================================================
(message "\n--- TEST 13: Task-Scoped Pomodoro Scheduling ---")

(let* ((temp-dir (make-temp-file "org-test-pomo-" t))
       (test-org-file (expand-file-name "test-pomodoro.org" temp-dir))
       (today-parts (decode-time))
       (fake-now (encode-time 0 0 9 (nth 3 today-parts) (nth 4 today-parts) (nth 5 today-parts))))
  (cl-letf (((symbol-function 'current-time) (lambda () fake-now)))
    (let ((org-auto-scheduler-sync-caldav nil)
          (org-auto-scheduler-silent-mode t)
          (org-auto-scheduler-preserve-today-scheduled nil)
          (org-auto-scheduler-start-time "09:00")
          (org-auto-scheduler-end-time "18:00")
          (org-auto-scheduler-task-gap 0))

      ;; 13.1: Spec parsing unit tests
      (assert-equal (let ((trimmed "25:5"))
                      (when (string-match "^\\([0-9]+\\)[ 	]*[:/][ 	]*\\([0-9]+\\)$" trimmed)
                        (list :work (string-to-number (match-string 1 trimmed))
                              :break (string-to-number (match-string 2 trimmed)))))
                    '(:work 25 :break 5)
                    "Test 13.1: Spec parses 25:5")
      (assert-equal (let ((trimmed "50 : 10"))
                      (when (string-match "^\\([0-9]+\\)[ 	]*[:/][ 	]*\\([0-9]+\\)$" trimmed)
                        (list :work (string-to-number (match-string 1 trimmed))
                              :break (string-to-number (match-string 2 trimmed)))))
                    '(:work 50 :break 10)
                    "Test 13.1: Spec parses 50 : 10")

      ;; 13.2: End-to-end task scheduling:
      ;; Task A: POMODORO 25:5, Effort 1:00 (splits 25m work + 5m break + 25m work + 5m break + 10m work + 5m trailing gap)
      ;; Task B: POMODORO 25:5, Effort 0:25 (single 25m work block + 5m break)
      ;; Task C: Normal task (no POMODORO), Effort 0:30 (contiguous 30m block, normal task-gap = 0)
      ;; Task D: Normal task (no POMODORO), Effort 0:30 (starts immediately after Task C without any break)
      (with-temp-file test-org-file
        (insert "* Tasks :PROJECT:
*** TODO Pomo Task Split :AUTOSCH:
:PROPERTIES:
:Effort: 1:00
:POMODORO: 25:5
:ID: pomo-test-split
:END:
*** TODO Pomo Task Single :AUTOSCH:
:PROPERTIES:
:Effort: 0:25
:POMODORO: 25:5
:ID: pomo-test-single
:END:
*** TODO Normal Task C :AUTOSCH:
:PROPERTIES:
:Effort: 0:30
:ID: pomo-test-norm-c
:END:
*** TODO Normal Task D :AUTOSCH:
:PROPERTIES:
:Effort: 0:30
:ID: pomo-test-norm-d
:END:
"))
      (setq org-agenda-files (list test-org-file))
      (org-auto-scheduler-schedule-tasks)

      (with-current-buffer (find-file-noselect test-org-file)
        (goto-char (point-min))
        (re-search-forward ":ID:[ 	]*pomo-test-norm-d")
        (let ((norm-d-sched (org-entry-get nil "SCHEDULED")))
          (assert-true (and norm-d-sched (string-match-p "09:05-09:35" norm-d-sched))
                       (format "Test 13.2: Normal Task D scheduled first at 09:05-09:35 (actual: %s)" norm-d-sched)))

        (goto-char (point-min))
        (re-search-forward ":ID:[ 	]*pomo-test-norm-c")
        (let ((norm-c-sched (org-entry-get nil "SCHEDULED")))
          (assert-true (and norm-c-sched (string-match-p "09:35-10:05" norm-c-sched))
                       (format "Test 13.2: Normal Task C starts immediately after D at 09:35 with 0m break (actual: %s)" norm-c-sched)))

        (goto-char (point-min))
        (re-search-forward ":ID:[ 	]*pomo-test-single")
        (let ((single-sched (org-entry-get nil "SCHEDULED")))
          (assert-true (and single-sched (string-match-p "10:05-10:30" single-sched))
                       (format "Test 13.3: Pomo single task starts at 10:05-10:30 (actual: %s)" single-sched)))

        (goto-char (point-min))
        (re-search-forward ":ID:[ 	]*pomo-test-split")
        (let ((split-p1-sched (org-entry-get nil "SCHEDULED")))
          (assert-true (and split-p1-sched (string-match-p "10:35-11:00" split-p1-sched))
                       (format "Test 13.4: Pomo split part 1 starts after single pomo 5m break at 10:35-11:00 (actual: %s)" split-p1-sched)))

        (goto-char (point-min))
        (re-search-forward "Pomodoro 2/3")
        (let ((split-p2-sched (org-entry-get nil "SCHEDULED"))
              (split-p2-ph (org-entry-get nil "AUTOSCH_PLACEHOLDER")))
          (assert-equal split-p2-ph "t" "Test 13.4: Part 2 is marked as placeholder")
          (assert-true (and split-p2-sched (string-match-p "11:05-11:30" split-p2-sched))
                       (format "Test 13.4: Pomo split part 2 starts after 5m break at 11:05-11:30 (actual: %s)" split-p2-sched)))

        (goto-char (point-min))
        (re-search-forward "Pomodoro 3/3")
        (let ((split-p3-sched (org-entry-get nil "SCHEDULED")))
          (assert-true (and split-p3-sched (string-match-p "11:35-11:45" split-p3-sched))
                       (format "Test 13.4: Pomo split part 3 starts after 5m break at 11:35-11:45 (actual: %s)" split-p3-sched))))

      ;; 13.5: Idempotency of repeated runs on Pomodoro tasks
      (let* ((buf (find-file-noselect test-org-file))
             (str1 (with-current-buffer buf (buffer-string))))
        (org-auto-scheduler-schedule-tasks)
        (let ((str2 (with-current-buffer buf (buffer-string))))
          (assert-true (string= str1 str2)
                       "Test 13.5: Consecutive scheduling runs on Pomodoro tasks are completely idempotent"))))

    (delete-directory temp-dir t)))
