;;; 18-advanced-waiting-features-tickler-d-blocker-attr.el --- Advanced Waiting Features (Tickler 'd', Blocker Attribution, HUD 'w', Mobile Markers) -*- lexical-binding: t -*-

;; Loaded by test/oas-suites-test.el; uses helpers from test/test-helper.el.

;; ============================================================================
;; TEST 18: Advanced Waiting Features (Tickler 'd', Blocker Attribution, HUD 'w', Mobile Markers)
;; ============================================================================
(message "\n--- TEST 18: Advanced Waiting Features (Tickler 'd', Blocker Attribution, HUD 'w', Mobile Markers) ---")

(let* ((temp-file (make-temp-file "org-test-waiting-adv" nil ".org"))
       (state-file (make-temp-file "org-test-waiting-state" nil ".el"))
       (buf (find-file-noselect temp-file)))
  (unwind-protect
      (with-current-buffer buf
        (insert "#+TODO: TODO NEXT IN-PROGRESS WAITING HOLD | DONE CANCELLED\n")
        (org-mode)
        ;; Task for Test 18.1: Review quick-tickler 'd'
        (insert "* WAITING Waiting Task Tickler :AUTOSCH:\n:PROPERTIES:\n:ID: test-adv-tickler\n:EFFORT: 30\n:WAITING_SINCE: 2026-09-20 10:00\n:END:\n")
        ;; Tasks for Test 18.2: Blocker Attribution
        (insert "* WAITING Dependency Blocker Task :AUTOSCH:\n:PROPERTIES:\n:ID: test-adv-blocker\n:EFFORT: 60\n:WAITING_SINCE: 2026-09-25 10:00\n:END:\n")
        (insert "* TODO Blocked Downstream Task :AUTOSCH:\n:PROPERTIES:\n:ID: test-adv-downstream\n:EFFORT: 45\n:BLOCKER: test-adv-blocker\n:END:\n")
        ;; Tasks for Test 18.3: Focus HUD 'w'
        (let ((today-d (format-time-string "%Y-%m-%d %a")))
          (insert (format "* TODO Focus Current Task :AUTOSCH:\nSCHEDULED: <%s 14:00-15:00>\n:PROPERTIES:\n:ID: test-adv-focus-cur\n:EFFORT: 60\n:END:\n" today-d))
          (insert (format "* TODO Focus Next Task :AUTOSCH:\nSCHEDULED: <%s 15:00-16:00>\n:PROPERTIES:\n:ID: test-adv-focus-nxt\n:EFFORT: 60\n:END:\n" today-d)))
        (save-buffer)
        (let ((org-agenda-files (list temp-file))
              (org-auto-scheduler-review-state-file state-file)
              (org-auto-scheduler--saved-review-decisions nil)
              (org-auto-scheduler--review-overrides (make-hash-table :test 'equal)))

          ;; 18.1: Review Quick-Tickler Key ('d' and 'C-u d')
          (org-auto-scheduler-review-and-apply)
          (with-current-buffer "*Org Auto Scheduler Review*"
            (org-auto-scheduler--review-goto-task "test-adv-tickler")
            ;; Test setting follow-up date with 'd'
            (cl-letf (((symbol-function 'org-read-date) (lambda (&rest _args) "2026-10-05")))
              (org-auto-scheduler-review-move-to-date))
            (with-current-buffer buf
              (let ((m (org-id-find "test-adv-tickler" t)))
                (org-with-point-at m
                  (assert-equal (org-entry-get nil "SCHEDULED") "<2026-10-05 Mon>"
                                "Test 18.1: Set tickler date on waiting task via 'd'"))))

            ;; Test clearing follow-up date with 'C-u d'
            (org-auto-scheduler-review-move-to-date '(4))
            (with-current-buffer buf
              (let ((m (org-id-find "test-adv-tickler" t)))
                (org-with-point-at m
                  (assert-equal (org-entry-get nil "SCHEDULED") nil
                                "Test 18.1: Cleared tickler date on waiting task via 'C-u d'"))))
            (kill-buffer "*Org Auto Scheduler Review*"))

          ;; 18.2: Waiting Blocker Attribution
          (let* ((downstream-marker (org-id-find "test-adv-downstream" t))
                 (waiting-blockers (org-auto-scheduler--get-waiting-blockers downstream-marker)))
            (assert-equal (length waiting-blockers) 1
                          "Test 18.2: Detected exactly 1 waiting blocker")
            ;; Check warning attribution
            (let ((warns (org-auto-scheduler--check-task-warnings
                          (list "test-adv-downstream" nil nil '("AUTOSCH") nil "Blocked Downstream Task"
                                "BLOCKED" downstream-marker 1 :blocked)
                          downstream-marker)))
              (assert-true (cl-some (lambda (w) (string-match-p "Blocker is WAITING (WAITING)" w)) warns)
                           "Test 18.2: Warning mentions Blocker is WAITING"))
            ;; Check review buffer rendering
            (org-auto-scheduler-review-and-apply)
            (with-current-buffer "*Org Auto Scheduler Review*"
              (let ((downstream-entry (assoc "test-adv-downstream" tabulated-list-entries)))
                (assert-true downstream-entry "Test 18.2: Downstream task present in review list")
                ;; Time column reflects BLOCKED (WAITING)
                (assert-true (string-match-p "BLOCKED (WAITING)" (aref (cadr downstream-entry) 3))
                             "Test 18.2: Time column displays BLOCKED (WAITING)"))
              (kill-buffer "*Org Auto Scheduler Review*")))

          ;; 18.3: Focus HUD 'w' ("Wait on This")
          (let ((cur-m (org-id-find "test-adv-focus-cur" t))
                (nxt-m (org-id-find "test-adv-focus-nxt" t))
                (hud-buf (get-buffer-create "*Org Focus HUD*")))
            (with-current-buffer buf
              (goto-char cur-m)
              (org-clock-in))
            (assert-true (org-clock-is-active) "Test 18.3: Clocked into current task")
            ;; Launch HUD
            (with-current-buffer hud-buf
              (org-auto-scheduler-focus-mode)
              (setq org-auto-scheduler-focus--target-marker cur-m)
              (org-auto-scheduler-focus-refresh))
            (let ((org-auto-scheduler-focus-auto-clock-in-on-advance t))
              (with-current-buffer hud-buf
                (org-auto-scheduler-focus-wait "Waiting for client response" "2026-10-12")))
            ;; Verify current task transitioned to WAITING
            (with-current-buffer buf
              (org-with-point-at cur-m
                (assert-equal (org-get-todo-state) "WAITING"
                             "Test 18.3: Task transitioned to WAITING via Focus HUD 'w'")
                (assert-equal (org-entry-get nil "SCHEDULED") "<2026-10-12 Mon>"
                             "Test 18.3: Follow-up tickler scheduled date set via Focus HUD 'w'")
                (let ((task-body (buffer-substring-no-properties (point-min) (point-max))))
                  (assert-true (string-match-p "WAITING: Waiting for client response" task-body)
                               "Test 18.3: Waiting note logged in task body"))))
            ;; Verify auto-advanced and clocked into next task in HUD buffer
            (with-current-buffer hud-buf
              (assert-equal org-auto-scheduler-focus--target-marker nxt-m
                           "Test 18.3: Focus HUD auto-advanced target to next task"))
            (when (fboundp 'org-clock-is-active)
              (when (org-clock-is-active)
                (org-clock-out)))
            (when (buffer-live-p hud-buf)
              (kill-buffer hud-buf)))

          ;; 18.4: Mobile Title Modifiers
          ;; Insert fresh tasks with markers directly before marker processing
          (with-current-buffer buf
            (goto-char (point-max))
            (insert "* TODO Mobile Plain Marker Task (-w-) :AUTOSCH:\n:PROPERTIES:\n:ID: test-adv-mobile-w\n:EFFORT: 30\n:END:\n")
            (insert "* TODO Mobile Relative Dur Task (-w+3d-) :AUTOSCH:\n:PROPERTIES:\n:ID: test-adv-mobile-3d\n:EFFORT: 45\n:END:\n")
            (save-buffer))

          ;; Process Mobile Task A (-w-)
          (let ((m-w (org-id-find "test-adv-mobile-w" t)))
            (org-auto-scheduler--process-title-markers m-w)
            (with-current-buffer buf
              (org-with-point-at m-w
                (assert-equal (org-get-heading t t t t) "Mobile Plain Marker Task"
                             "Test 18.4: (-w-) stripped from headline")
                (assert-equal (org-get-todo-state) "WAITING"
                             "Test 18.4: (-w-) transitioned state to WAITING")
                (assert-true (org-entry-get nil "WAITING_SINCE")
                             "Test 18.4: WAITING_SINCE recorded for (-w-)"))))

          ;; Process Mobile Task B (-w+3d-)
          (let ((m-3d (org-id-find "test-adv-mobile-3d" t))
                (expected-date (org-auto-scheduler--parse-wait-duration "3d")))
            (org-auto-scheduler--process-title-markers m-3d)
            (with-current-buffer buf
              (org-with-point-at m-3d
                (assert-equal (org-get-heading t t t t) "Mobile Relative Dur Task"
                             "Test 18.4: (-w+3d-) stripped from headline")
                (assert-equal (org-get-todo-state) "WAITING"
                             "Test 18.4: (-w+3d-) transitioned state to WAITING")
                (let ((sched (org-entry-get nil "SCHEDULED")))
                  (assert-true (and sched (string-prefix-p (format "<%s" expected-date) sched))
                               "Test 18.4: (-w+3d-) set relative scheduled follow-up date")))))

          ;; Run scheduler to ensure mobile waiting tasks are not allocated active time slots
          (org-auto-scheduler-schedule-tasks)
          (let ((schedulable (org-auto-scheduler-get-schedulable-tasks)))
            (dolist (m schedulable)
              (with-current-buffer (marker-buffer m)
                (org-with-point-at m
                  (assert-true (not (member (org-get-todo-state) org-auto-scheduler-waiting-states))
                               "Test 18.4: Schedulable task is not in waiting-states")))))))
    (when (buffer-live-p buf) (kill-buffer buf))
    (when (file-exists-p state-file) (delete-file state-file))
    (delete-file temp-file)))
