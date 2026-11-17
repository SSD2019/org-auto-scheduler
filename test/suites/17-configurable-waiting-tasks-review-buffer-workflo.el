;;; 17-configurable-waiting-tasks-review-buffer-workflo.el --- Configurable Waiting Tasks & Review Buffer Workflow -*- lexical-binding: t -*-

;; Loaded by test/oas-suites-test.el; uses helpers from test/test-helper.el.

;; ============================================================================
;; TEST 17: Configurable Waiting Tasks & Review Buffer Workflow
;; ============================================================================

(message "\n--- TEST 17: Configurable Waiting Tasks & Review Buffer Workflow ---")

(let* ((temp-file (make-temp-file "org-test-waiting" nil ".org"))
       (buf (find-file-noselect temp-file)))
  (unwind-protect
      (with-current-buffer buf
        (insert "#+TODO: TODO NEXT IN-PROGRESS WAITING HOLD | DONE CANCELLED\n")
        (org-mode)
        (insert "* TODO Task With Clock :AUTOSCH:\nSCHEDULED: <2026-09-28 Mon 14:00-15:00>\n:PROPERTIES:\n:ID: test-wait-clk-1\n:EFFORT: 60\n:END:\n")
        (insert (format "* WAITING Stale Task A :AUTOSCH:\nSCHEDULED: <2026-09-20 Sun>\n:PROPERTIES:\n:ID: test-wait-stale-a\n:EFFORT: 30\n:WAITING_SINCE: %s 10:00\n:END:\n"
                       ;; relative to the (pinned) current time so the test does not rot as the calendar advances
                       (format-time-string "%Y-%m-%d" (time-subtract (current-time) (* 10 86400)))))
        (insert (format "* HOLD Fresh Task B :AUTOSCH:\n:PROPERTIES:\n:ID: test-wait-fresh-b\n:EFFORT: 45\n:WAITING_SINCE: %s 09:00\n:END:\n"
                       (format-time-string "%Y-%m-%d" (time-subtract (current-time) 86400))))
        (insert "* TODO Normal Active C :AUTOSCH:\n:PROPERTIES:\n:ID: test-wait-active-c\n:EFFORT: 60\n:END:\n")
        (save-buffer)
        (let ((org-agenda-files (list temp-file)))

          ;; 17.1: Hook on state transition to WAITING
          (goto-char (point-min))
          (re-search-forward "^\\* TODO Task With Clock")
          (org-back-to-heading t)
          (org-clock-in)
          (assert-true (org-clock-is-active) "Test 17.1: Task With Clock clocked in")
          (org-todo "WAITING")
          (assert-true (not (org-clock-is-active)) "Test 17.1: Clock automatically stopped on transition to WAITING")
          (let ((sched (org-entry-get nil "SCHEDULED")))
            (assert-equal sched "<2026-09-28 Mon>" "Test 17.1: SCHEDULED time stripped to follow-up tickler date"))
          (let ((since (org-entry-get nil "WAITING_SINCE")))
            (assert-true (and since (not (string-empty-p since))) "Test 17.1: WAITING_SINCE property recorded"))
          ;; Transition back to TODO removes WAITING_SINCE
          (org-todo "TODO")
          (assert-equal (org-entry-get nil "WAITING_SINCE") nil "Test 17.1: WAITING_SINCE removed when transitioning to TODO")

          ;; 17.2: Task filtering & Stale Detection
          (let ((schedulable (org-auto-scheduler-get-schedulable-tasks)))
            ;; Only active tasks (Task With Clock and Normal Active C) are schedulable
            (assert-equal (length schedulable) 2 "Test 17.2: Exactly 2 schedulable tasks (WAITING and HOLD excluded)")
            (dolist (m schedulable)
              (with-current-buffer (marker-buffer m)
                (org-with-point-at m
                  (assert-true (not (member (org-get-todo-state) org-auto-scheduler-waiting-states))
                               "Test 17.2: Schedulable task is not in waiting-states")))))

          (let ((waiting-tasks (org-auto-scheduler-get-waiting-tasks)))
            (assert-equal (length waiting-tasks) 2 "Test 17.2: Found exactly 2 waiting tasks (Task A & Task B)")
            (let ((stale-task (cl-find-if (lambda (w) (string= (plist-get w :id) "test-wait-stale-a")) waiting-tasks))
                  (fresh-task (cl-find-if (lambda (w) (string= (plist-get w :id) "test-wait-fresh-b")) waiting-tasks)))
              (assert-true (>= (plist-get stale-task :days-waiting) 8) "Test 17.2: Stale task has >= 8 days waiting")
              (assert-true (>= (plist-get stale-task :days-waiting) org-auto-scheduler-waiting-stale-days)
                           "Test 17.2: Stale task meets or exceeds stale threshold")
              (assert-true (< (plist-get fresh-task :days-waiting) org-auto-scheduler-waiting-stale-days)
                           "Test 17.2: Fresh task is below stale threshold")))

          ;; 17.3: Review Buffer Layout & Placement
          (org-auto-scheduler-review-and-apply)
          (with-current-buffer "*Org Auto Scheduler Review*"
            (let ((entries tabulated-list-entries)
                  (sep-waiting-pos nil)
                  (last-day-pos nil))
              (let ((idx 0))
                (dolist (e entries)
                  (let ((id (car e)))
                    (when (and (stringp id) (string-prefix-p "__sep_" id) (not (string= id "__sep_Waiting")))
                      (setq last-day-pos idx))
                    (when (and (stringp id) (string= id "__sep_Waiting"))
                      (setq sep-waiting-pos idx))
                    (setq idx (1+ idx)))))
              (assert-true (and sep-waiting-pos last-day-pos (> sep-waiting-pos last-day-pos))
                           "Test 17.3: Waiting section is placed at the bottom after all day sections")

              ;; Check stale task formatting
              (let ((stale-entry (assoc "test-wait-stale-a" entries))
                    (fresh-entry (assoc "test-wait-fresh-b" entries)))
                (assert-true stale-entry "Test 17.3: Stale task entry found in review list")
                (assert-true fresh-entry "Test 17.3: Fresh task entry found in review list")
                ;; Stale entry has warning symbol in St column (idx 7)
                (assert-true (string-match-p "⚠️" (aref (cadr stale-entry) 7))
                             "Test 17.3: Stale task displays ⚠️ in status column")
                (assert-true (string-match-p "STALE" (aref (cadr stale-entry) 6))
                             "Test 17.3: Stale task displays STALE in score column")
                (assert-true (string-match-p "⏳" (aref (cadr fresh-entry) 7))
                             "Test 17.3: Fresh task displays ⏳ in status column")))

            ;; 17.4: Review Movement Guards & State Changing via 't'
            ;; Movement guard: moving waiting task throws error
            (org-auto-scheduler--review-goto-task "test-wait-stale-a")
            (condition-case err
                (progn (org-auto-scheduler-review-move-up) (assert-true nil "Test 17.4: Should error on move-up"))
              (user-error
               (assert-true (string-match-p "WAITING" (error-message-string err))
                            "Test 17.4: Move-up correctly blocked on waiting task")))

            ;; Change state using review command (mock completing-read to return "TODO")
            (cl-letf (((symbol-function 'completing-read) (lambda (&rest _args) "TODO")))
              (org-auto-scheduler-review-set-todo-state))
            ;; Verify the task in the org buffer changed to TODO
            (with-current-buffer buf
              (let ((m (org-id-find "test-wait-stale-a" t)))
                (org-with-point-at m
                  (assert-equal (org-get-todo-state) "TODO" "Test 17.4: Task state in buffer changed to TODO via 't'"))))

            ;; 17.5: Header line format includes waiting badge
            (let ((hdr (org-auto-scheduler--review-header-line tabulated-list-entries)))
              (assert-true (string-match-p "waiting" (nth 3 hdr))
                           "Test 17.5: Header line displays waiting tasks badge"))

            (kill-buffer "*Org Auto Scheduler Review*"))))
    (when (buffer-live-p buf) (kill-buffer buf))
    (delete-file temp-file)))
