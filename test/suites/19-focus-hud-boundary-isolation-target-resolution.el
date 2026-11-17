;;; 19-focus-hud-boundary-isolation-target-resolution.el --- Focus HUD Boundary Isolation & Target Resolution -*- lexical-binding: t -*-

;; Loaded by test/oas-suites-test.el; uses helpers from test/test-helper.el.

;; ============================================================================
;; TEST 19: Focus HUD Boundary Isolation & Target Heading Resolution
;; ============================================================================
(message "\n--- TEST 19: Focus HUD Boundary Isolation & Target Resolution ---")

(let* ((temp-file (make-temp-file "test-focus-boundary-" nil ".org"))
       (buf (find-file-noselect temp-file))
       (hud-buf (get-buffer-create "*Org Focus HUD*")))
  (unwind-protect
      (with-current-buffer buf
        (org-mode)
        (insert "* TODO Target Task\n:PROPERTIES:\n:EFFORT: 30m\n:END:\n* TODO Neighbor Task\n:LOGBOOK:\n:END:\n")
        (save-buffer)
        (let ((m-target (progn (goto-char (point-min)) (point-marker))))

          ;; 19.1: Adding checklist item 'k' to a task with NO existing checklist items
          ;; Must stay within m-target and NOT leak into Neighbor Task
          (with-current-buffer hud-buf
            (org-auto-scheduler-focus-mode)
            (setq org-auto-scheduler-focus--target-marker m-target)
            (org-auto-scheduler-focus-refresh)
            (org-auto-scheduler-focus-add-checklist "First Target Checklist"))

          (with-current-buffer buf
            (let ((content (buffer-string)))
              (assert-true (string-match "\\* TODO Target Task\n:PROPERTIES:\n:EFFORT: 30m\n:END:\n  - \\[ \\] First Target Checklist\n\\* TODO Neighbor Task" content)
                           "Test 19.1: Checklist item inserted into Target Task without leaking into Neighbor Task")))

          ;; 19.2: Adding note 'n' to Target Task (which has no LOGBOOK)
          ;; Must not leak into Neighbor Task's LOGBOOK
          (with-current-buffer hud-buf
            (org-auto-scheduler-focus-add-note "Target Quick Note"))
          (with-current-buffer buf
            (let* ((m-neighbor (save-excursion
                                 (goto-char (point-min))
                                 (re-search-forward "Neighbor Task")
                                 (org-back-to-heading t)
                                 (point-marker)))
                   (target-notes (org-auto-scheduler-focus--get-notes m-target))
                   (neighbor-notes (org-auto-scheduler-focus--get-notes m-neighbor)))
              (assert-equal (length target-notes) 1 "Test 19.2: Exactly 1 note on Target Task")
              (assert-true (string-match-p "Target Quick Note" (car target-notes)) "Test 19.2: Target note content matches")
              (assert-equal (length neighbor-notes) 0 "Test 19.2: Neighbor Task LOGBOOK received 0 notes")))

          ;; 19.3: Adding child subtask 's'
          (with-current-buffer hud-buf
            (org-auto-scheduler-focus-add-subtask "Target Child Subtask" "15m"))
          (with-current-buffer buf
            (let ((subtasks (org-auto-scheduler-focus--get-subtasks m-target)))
              (assert-equal (length subtasks) 1 "Test 19.3: Target Task has 1 child subtask")
              (assert-equal (plist-get (car subtasks) :title) "Target Child Subtask" "Test 19.3: Child title matches")))

          ;; 19.4: Adding sibling task 'a'
          (with-current-buffer hud-buf
            (org-auto-scheduler-focus-add-sibling "Target Sibling Task" "20m"))
          (with-current-buffer buf
            (save-excursion
              (goto-char (point-min))
              (assert-true (re-search-forward "^\\* TODO Target Sibling Task.*:AUTOSCH:" nil t)
                           "Test 19.4: Sibling task inserted at level 1 with :AUTOSCH:"))))

        ;; 19.5: Target Heading Resolution: Invoking focus on an Org heading when another task is clocked
        (let ((clocked-file (make-temp-file "test-focus-clock-" nil ".org"))
              (clocked-buf nil))
          (unwind-protect
              (progn
                (setq clocked-buf (find-file-noselect clocked-file))
                (with-current-buffer clocked-buf
                  (org-mode)
                  (insert "* TODO Background Clocked Task\n")
                  (save-buffer)
                  (goto-char (point-min))
                  (org-clock-in))
                ;; Now, user is visiting buf on Neighbor Task
                (with-current-buffer buf
                  (goto-char (point-min))
                  (re-search-forward "Neighbor Task")
                  ;; Call interactive form resolution
                  (let ((resolved-marker
                         (cond
                          ((and (derived-mode-p 'org-mode)
                                (not (derived-mode-p 'org-agenda-mode))
                                (ignore-errors (save-excursion (org-back-to-heading t) (point-marker)))))
                          ((eq major-mode 'org-agenda-mode)
                           (let ((m (or (org-get-at-bol 'org-marker) (org-get-at-bol 'org-hd-marker))))
                             (and m (markerp m) (marker-buffer m) m)))
                          ((and (fboundp 'org-clock-is-active) (org-clock-is-active)
                                (boundp 'org-clock-marker) (markerp org-clock-marker) (marker-buffer org-clock-marker))
                           (org-with-point-at org-clock-marker
                             (org-back-to-heading t)
                             (point-marker)))
                          (t nil))))
                    (assert-true (and resolved-marker (equal (marker-buffer resolved-marker) buf))
                                 "Test 19.5: Active org-mode buffer heading prioritized over background clocked task")
                    (with-current-buffer (marker-buffer resolved-marker)
                      (org-with-point-at resolved-marker
                        (assert-equal (org-get-heading t t t t) "Neighbor Task"
                                     "Test 19.5: Resolved heading is Neighbor Task"))))))
            (when (fboundp 'org-clock-is-active)
              (when (org-clock-is-active) (org-clock-out nil t)))
            (when (buffer-live-p clocked-buf) (kill-buffer clocked-buf))
            (when (file-exists-p clocked-file) (delete-file clocked-file)))))
    (when (buffer-live-p buf) (kill-buffer buf))
    (when (file-exists-p temp-file) (delete-file temp-file))))
