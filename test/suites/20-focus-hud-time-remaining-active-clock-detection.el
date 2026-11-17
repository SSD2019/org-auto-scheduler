;;; 20-focus-hud-time-remaining-active-clock-detection.el --- Focus HUD Time Remaining & Active Clock Detection -*- lexical-binding: t -*-

;; Loaded by test/oas-suites-test.el; uses helpers from test/test-helper.el.

;;; ============================================================================
;;; TEST 20: Focus HUD Time Remaining Calculation & Active Clock Detection
;;; ============================================================================
(message "\n--- TEST 20: Focus HUD Time Remaining & Active Clock Detection ---")
(let* ((temp-file (make-temp-file "org-test-focus-clock-" nil ".org"))
       (buf (find-file-noselect temp-file)))
  (unwind-protect
      (with-current-buffer buf
        (org-mode)
        ;; Task 1: 4-hour task (effort 240m), scheduled 2 days in the future (e.g. 14:00-18:00)
        ;; Previously, time remaining calculated (time-subtract end-time now), giving ~2861m!
        ;; Now, remaining time must reflect actual effort remaining (240m).
        (let* ((future-date (format-time-string "%Y-%m-%d" (time-add (current-time) (* 2 86400)))))
          (insert (format "* TODO Four Hour Future Task\nSCHEDULED: <%s Thu 14:00-18:00>\n:PROPERTIES:\n:Effort:   4:00\n:END:\n:LOGBOOK:\n:END:\n\n* TODO Secondary Task\n:PROPERTIES:\n:Effort:   1:00\n:END:\n" future-date))
          (save-buffer))
        (goto-char (point-min))
        (let ((m1 (point-marker)))
          (re-search-forward "Secondary Task")
          (org-back-to-heading t)
          (let ((m2 (point-marker)))
            ;; 20.1 Test task-clocked-p and Focus HUD before clocking in
            (assert-equal (org-auto-scheduler--task-clocked-p m1) nil
                          "Test 20.1: m1 is not clocked in initially")
            (org-auto-scheduler-focus m1)
            (let ((hud-buf (get-buffer "*Org Focus HUD*")))
              (with-current-buffer hud-buf
                (assert-true (string-match-p "TIME REMAINING: 4h 00m left (240m)" (buffer-string))
                             "Test 20.1: 4-hour future task displays '4h 00m left (240m)' (not 2800+ mins)")
                (assert-true (string-match-p "\\[PAUSED / NOT CLOCKED\\]" (buffer-string))
                             "Test 20.1: [PAUSED / NOT CLOCKED] shown when not clocked in")
                (assert-true (string-match-p "14:00 – 18:00" (buffer-string))
                             "Test 20.1: Slot times rendered")
                (assert-true (not (string-match-p "14:00 – 18:00 (Today)" (buffer-string)))
                             "Test 20.1: Future slot does not claim '(Today)'")))

            ;; 20.2 Clock into m1 (drawer gets CLOCK line, org-clock-marker is inside drawer)
            (with-current-buffer buf
              (goto-char (marker-position m1))
              (org-clock-in))
            (assert-true (org-clocking-p) "Test 20.2: Clock is active")
            (assert-true (org-auto-scheduler--task-clocked-p m1)
                         "Test 20.2: org-auto-scheduler--task-clocked-p returns t for m1")
            (assert-equal (org-auto-scheduler--task-clocked-p m2) nil
                          "Test 20.2: org-auto-scheduler--task-clocked-p returns nil for m2")

            ;; 20.3 Focus HUD while clocked in
            (org-auto-scheduler-focus-refresh)
            (let ((hud-buf (get-buffer "*Org Focus HUD*")))
              (with-current-buffer hud-buf
                (assert-true (string-match-p "TIME REMAINING: 4h 00m left (240m)" (buffer-string))
                             "Test 20.3: TIME REMAINING remains 240m while clock just started")
                (assert-true (not (string-match-p "\\[PAUSED / NOT CLOCKED\\]" (buffer-string)))
                             "Test 20.3: [PAUSED / NOT CLOCKED] is NOT displayed when clocked in")))

            ;; 20.4 Toggle pause via Focus HUD 'p'
            (org-auto-scheduler-focus-toggle-pause)
            (assert-true (not (org-clocking-p)) "Test 20.4: Clock stopped after toggle pause")
            (let ((hud-buf (get-buffer "*Org Focus HUD*")))
              (with-current-buffer hud-buf
                (assert-true (string-match-p "\\[PAUSED / NOT CLOCKED\\]" (buffer-string))
                             "Test 20.4: [PAUSED / NOT CLOCKED] appears after toggle pause")))

            ;; 20.5 Resume clock via Focus HUD 'p'
            (org-auto-scheduler-focus-toggle-pause)
            (assert-true (org-clocking-p) "Test 20.5: Clock resumed after second toggle pause")
            (assert-true (org-auto-scheduler--task-clocked-p m1)
                         "Test 20.5: Task m1 is clocked in after resume")

            ;; 20.6 Active clock time inclusion in clocked-time
            ;; Mock clock having started 30 minutes ago
            (setq org-clock-start-time (time-subtract (current-time) 1800))
            (assert-equal (org-auto-scheduler-get-clocked-time m1) 30
                          "Test 20.6: Active clock 30m elapsed included in clocked time")
            (org-auto-scheduler-focus-refresh)
            (let ((hud-buf (get-buffer "*Org Focus HUD*")))
              (with-current-buffer hud-buf
                (assert-true (string-match-p "TIME REMAINING: 3h 30m left (210m)" (buffer-string))
                             "Test 20.6: TIME REMAINING updated to 3h 30m left (210m)")
                (assert-true (string-match-p "30m clocked (12%)" (buffer-string))
                             "Test 20.6: Progress shows 30m clocked (12%)")))

            ;; 20.7 Test 'o' opens task in other window and 'O' opens in current window
            (let ((hud-buf (get-buffer "*Org Focus HUD*")))
              (with-current-buffer hud-buf
                (org-auto-scheduler-focus-goto-task-other-window)
                (assert-equal (current-buffer) buf
                              "Test 20.7: Focused on original org buffer after other-window jump")
                (assert-equal (point) (marker-position m1)
                              "Test 20.7: Cursor positioned on target task headline after jump")))

            ;; Clean up clock
            (when (org-clocking-p) (org-clock-out nil t)))))
    (when (buffer-live-p buf) (kill-buffer buf))
    (when (file-exists-p temp-file) (delete-file temp-file))))
