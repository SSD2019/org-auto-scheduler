;;; 16-focus-hud-cockpit.el --- Focus HUD Cockpit -*- lexical-binding: t -*-

;; Loaded by test/oas-suites-test.el; uses helpers from test/test-helper.el.

;; ============================================================================
;; TEST 16: Focus HUD Cockpit (Pacing, Checklists, Notes, Subtasks, Sibling)
;; ============================================================================
(message "\n--- TEST 16: Focus HUD Cockpit ---")

;; 16.1: Standby view
(let ((buf (get-buffer-create "*Org Focus HUD*")))
  (with-current-buffer buf
    (org-auto-scheduler-focus-mode)
    (setq org-auto-scheduler-focus--target-marker nil)
    (org-auto-scheduler-focus-refresh)
    (assert-true (string-match-p "FOCUS HUD STANDBY" (buffer-string)) "Test 16.1: Standby header shown")
    (assert-true (string-match-p "NO ACTIVE OR SCHEDULED TASK DETECTED" (buffer-string)) "Test 16.1: Standby message shown")))

;; 16.2 to 16.5: Active task, checklists, notes, subtasks, sibling, controls
(with-temp-buffer
  (org-mode)
  (insert "* Project Alpha\n")
  (insert "** TODO Task One :AUTOSCH:\n")
  (insert ":PROPERTIES:\n:ID: hud-task-1\n:EFFORT: 60\n:POMODORO: 25:5\n:END:\n")
  (insert "SCHEDULED: <2026-09-25 Fri 14:00-15:00>\n")
  (insert "  - [ ] Generate PKCE code\n")
  (insert "  - [X] Add redirect URL\n")
  (insert "* TODO Task Two :AUTOSCH:\n")
  (insert ":PROPERTIES:\n:ID: hud-task-2\n:EFFORT: 30\n:END:\n")
  (insert "SCHEDULED: <2026-09-25 Fri 15:00-15:30>\n")

  (goto-char (point-min))
  (re-search-forward "\\*\\* TODO Task One")
  (beginning-of-line)
  (let* ((m1 (point-marker))
         (task-info (org-auto-scheduler-focus--resolve-task m1)))
    (assert-equal (plist-get task-info :title) "Task One" "Test 16.2: Task title is Task One")
    (assert-equal (plist-get task-info :parent) "Project Alpha" "Test 16.2: Parent project is Project Alpha")
    (assert-equal (plist-get task-info :effort) 60 "Test 16.2: Effort is 60m")
    (assert-equal (length (plist-get task-info :checklists)) 2 "Test 16.2: 2 checklist items found")
    (assert-equal (plist-get (plist-get task-info :pomodoro) :work) 25 "Test 16.2: Pomodoro work is 25")

    (let ((buf (get-buffer-create "*Org Focus HUD*")))
      (with-current-buffer buf
        (org-auto-scheduler-focus-mode)
        (setq org-auto-scheduler-focus--target-marker m1)
        (org-auto-scheduler-focus-refresh)
        (assert-true (string-match-p "FOCUS: Task One" (buffer-string)) "Test 16.2: HUD renders Task One")
        (assert-true (string-match-p "Project Alpha" (buffer-string)) "Test 16.2: HUD renders Project Alpha")
        (assert-true (string-match-p "CHECKLIST \\[1/2\\]" (buffer-string)) "Test 16.2: Checklist count 1/2")
        (assert-true (string-match-p "\\[X\\] Add redirect URL" (buffer-string)) "Test 16.2: Contains checked item")
        (assert-true (string-match-p "\\[ \\] Generate PKCE code" (buffer-string)) "Test 16.2: Contains unchecked item")
        (assert-true (string-match-p "Pomodoro: 🍅 \\[25m/5m\\]" (buffer-string)) "Test 16.2: Contains pomodoro spec")

        ;; 16.3: Toggle checklist item
        (goto-char (point-min))
        (re-search-forward "\\[ \\] Generate PKCE code")
        (beginning-of-line)
        ;; A plain toggle cycles [ ] -> [-] (in progress) -> [X]; a prefix arg forces the binary [ ] <-> [X] toggle.
        (org-auto-scheduler-focus-toggle-checklist t)
        (assert-true (string-match-p "CHECKLIST \\[2/2\\]" (buffer-string)) "Test 16.3: Checklist count updated to 2/2")
        (assert-true (string-match-p "\\[X\\] Generate PKCE code" (buffer-string)) "Test 16.3: Item is now [X]")
        ;; Verify keybindings: RET toggles checklist, SPC is preserved for Spacemacs leader / scrolling
        (assert-equal (lookup-key org-auto-scheduler-focus-mode-map (kbd "RET"))
                      #'org-auto-scheduler-focus-toggle-checklist
                      "Test 16.3: RET is bound to toggle checklist")
        (assert-equal (lookup-key org-auto-scheduler-focus-mode-map (kbd "o"))
                      #'org-auto-scheduler-focus-goto-task-other-window
                      "Test 16.3: 'o' is bound to org-auto-scheduler-focus-goto-task-other-window")
        (assert-equal (lookup-key org-auto-scheduler-focus-mode-map (kbd "O"))
                      #'org-auto-scheduler-focus-goto-task
                      "Test 16.3: 'O' is bound to org-auto-scheduler-focus-goto-task")
        (assert-true (not (eq (lookup-key org-auto-scheduler-focus-mode-map (kbd "SPC"))
                              #'org-auto-scheduler-focus-toggle-checklist))
                     "Test 16.3: SPC is NOT bound to toggle checklist (Spacemacs leader preserved)")

        ;; Verify shortcuts legend is hidden by default and toggled with '?'
        (assert-true (not (string-match-p "CAPTURE (Zero context switching)" (buffer-string)))
                     "Test 16.3: Shortcuts legend hidden by default")
        (assert-true (string-match-p "\\[\\?\\]" (buffer-string))
                     "Test 16.3: '[?] Shortcuts help' prompt shown")
        (assert-equal (lookup-key org-auto-scheduler-focus-mode-map (kbd "?"))
                      #'org-auto-scheduler-focus-toggle-help
                      "Test 16.3: '?' is bound to org-auto-scheduler-focus-toggle-help")
        (org-auto-scheduler-focus-toggle-help)
        (assert-true (string-match-p "CAPTURE (Zero context switching)" (buffer-string))
                     "Test 16.3: Shortcuts legend shown after '?'")
        (assert-true (string-match-p (regexp-quote "[?] Hide shortcuts help") (buffer-string))
                     "Test 16.3: '[?] Hide shortcuts help' shown in expanded legend")
        (org-auto-scheduler-focus-toggle-help)
        (assert-true (not (string-match-p "CAPTURE (Zero context switching)" (buffer-string)))
                     "Test 16.3: Shortcuts legend hidden again after second '?'")

        ;; 16.4: Add checklist, note, subtask, sibling
        (org-auto-scheduler-focus-add-checklist "Write unit tests")
        (assert-true (string-match-p "CHECKLIST \\[2/3\\]" (buffer-string)) "Test 16.4: Checklist count updated to 2/3")
        (assert-true (string-match-p "\\[ \\] Write unit tests" (buffer-string)) "Test 16.4: New checklist item rendered")

        (org-auto-scheduler-focus-add-note "Remember constant-time comparison")
        (assert-true (string-match-p "RECENT NOTES" (buffer-string)) "Test 16.4: Recent notes section rendered")
        (assert-true (string-match-p "Remember constant-time comparison" (buffer-string)) "Test 16.4: Note content rendered")

        (org-auto-scheduler-focus-add-subtask "Implement token exchange" "25m")
        (assert-true (string-match-p "SUBTASKS (CHILD TODOS)" (buffer-string)) "Test 16.4: Subtasks section rendered")
        (assert-true (string-match-p "Implement token exchange" (buffer-string)) "Test 16.4: Child subtask rendered")

        (org-auto-scheduler-focus-add-sibling "Deploy oauth proxy" "45m")
        (with-current-buffer (marker-buffer m1)
          (save-excursion
            (goto-char (point-min))
            (assert-true (re-search-forward "\\*\\* TODO Deploy oauth proxy.*:AUTOSCH:" nil t) "Test 16.4: Sibling task exists at level 2")))

        ;; 16.5: Controls: pause, extend, done
        (with-current-buffer (marker-buffer m1)
          (goto-char (marker-position m1))
          (org-clock-in))
        (assert-true (org-clock-is-active) "Test 16.5: Clock is active")
        (org-auto-scheduler-focus-toggle-pause)
        (assert-true (not (org-clock-is-active)) "Test 16.5: Clock paused")
        (org-auto-scheduler-focus-toggle-pause)
        (assert-true (org-clock-is-active) "Test 16.5: Clock resumed")
        (org-clock-out nil t)

        ;; Extend
        (cl-letf (((symbol-function 'org-auto-scheduler-extend-current-task)
                   (lambda (mins)
                     (with-current-buffer (marker-buffer m1)
                       (org-with-point-at m1
                         (org-entry-put nil "EFFORT" "75")
                         (org-entry-put nil "SCHEDULED" "<2026-09-25 Fri 14:00-15:15>"))))))
          (org-auto-scheduler-focus-extend 15)
          (assert-true (string-match-p "Effort: 75m" (buffer-string)) "Test 16.5: Effort extended to 75m"))

        ;; Done
        (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) t))
                  ((symbol-function 'yes-or-no-p) (lambda (&rest _) t)))
          (org-auto-scheduler-focus-done))
        (with-current-buffer (marker-buffer m1)
          (org-with-point-at m1
            (assert-equal (org-get-todo-state) "DONE" "Test 16.5: Task One marked DONE")))))))
