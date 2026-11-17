;;; 21-focus-hud-nested-bullets-checklists-refresh-r-an.el --- Focus HUD Nested Bullets/Checklists, Refresh ('r'), and Work Log ('l' & Scroll) -*- lexical-binding: t -*-

;; Loaded by test/oas-suites-test.el; uses helpers from test/test-helper.el.

;;; ============================================================================
;;; TEST 21: Focus HUD Nested Bullets/Checklists, Refresh ('r'), and Work Log ('l' & Scroll)
;;; ============================================================================
(message "\n--- TEST 21: Focus HUD Nested Bullets/Checklists, Refresh ('r'), and Work Log ('l' & Scroll) ---")
(let* ((temp-file (make-temp-file "org-test-focus-nested-" nil ".org"))
       (buf (find-file-noselect temp-file)))
  (unwind-protect
      (with-current-buffer buf
        (org-mode)
        (insert "* TODO Multi-Level Feature Implementation\n")
        (insert "SCHEDULED: <2026-09-30 Wed 10:00-11:30>\n")
        (insert ":PROPERTIES:\n:Effort:   1:30\n:END:\n")
        (insert ":LOGBOOK:\n:END:\n\n")
        (insert "- [ ] Root checklist item A\n")
        (insert "  - Plain sub-bullet 1 (no checkbox)\n")
        (insert "  - [X] Completed sub-checklist item 2\n")
        (insert "    - [ ] Deeply nested sub-item 3\n")
        (insert "- Plain root bullet B\n\n")
        (save-buffer)

        (let* ((m (point-min-marker))
               (items (org-auto-scheduler-focus--get-checklists m))
               (hud-buf (get-buffer-create "*Org Focus HUD*")))
          ;; 21.1 Checklists and bullets extraction with nested levels
          (assert-equal (length items) 5 "Test 21.1: All 5 list items extracted across body")
          (assert-equal (plist-get (nth 0 items) :level) 0 "Test 21.1: Root item A level 0")
          (assert-equal (plist-get (nth 0 items) :state) "[ ]" "Test 21.1: Root item A checkbox [ ]")
          (assert-equal (plist-get (nth 1 items) :level) 1 "Test 21.1: Plain sub-bullet 1 level 1")
          (assert-equal (plist-get (nth 1 items) :state) nil "Test 21.1: Plain sub-bullet 1 has no checkbox")
          (assert-equal (plist-get (nth 2 items) :level) 1 "Test 21.1: Sub-checklist item 2 level 1")
          (assert-equal (plist-get (nth 2 items) :state) "[X]" "Test 21.1: Sub-checklist item 2 checkbox [X]")
          (assert-equal (plist-get (nth 3 items) :level) 2 "Test 21.1: Deeply nested sub-item 3 level 2")
          (assert-equal (plist-get (nth 3 items) :state) "[ ]" "Test 21.1: Deeply nested sub-item 3 checkbox [ ]")
          (assert-equal (plist-get (nth 4 items) :level) 0 "Test 21.1: Plain root bullet B level 0")
          (assert-equal (plist-get (nth 4 items) :state) nil "Test 21.1: Plain root bullet B has no checkbox")

          ;; Render HUD
          (with-current-buffer hud-buf
            (org-auto-scheduler-focus-mode)
            (setq org-auto-scheduler-focus--target-marker m)
            (setq org-auto-scheduler-focus--log-offset 0)
            (org-auto-scheduler-focus-refresh)
            (let ((hud-str (buffer-string)))
              ;; Checklists/Bullets box rendering with indentation & plain bullet icon
              (assert-true (string-match-p "CHECKLIST \\[1/3\\]" hud-str)
                           "Test 21.1: Checklist counter shows [1/3]")
              (assert-true (string-match-p "\\[ \\] Root checklist item A" hud-str)
                           "Test 21.1: Root checklist item rendered")
              (assert-true (string-match-p "Plain sub-bullet 1 (no checkbox)" hud-str)
                           "Test 21.1: Indented plain bullet rendered")
              (assert-true (string-match-p "\\[X\\] Completed sub-checklist item 2" hud-str)
                           "Test 21.1: Nested checked item rendered")
              (assert-true (string-match-p "\\[ \\] Deeply nested sub-item 3" hud-str)
                           "Test 21.1: Deeply nested checklist item rendered")
              (assert-true (string-match-p "Plain root bullet B" hud-str)
                           "Test 21.1: Plain root bullet rendered without checkbox")
              ;; Initial Work Log empty display
              (assert-true (string-match-p "WORK LOG \\[0\\]" hud-str)
                           "Test 21.1: Work log shows 0 entries initially"))

            ;; 21.2 Toggle plain bullet to add checkbox
            (goto-char (point-min))
            (re-search-forward "Plain root bullet B")
            (beginning-of-line)
            (org-auto-scheduler-focus-toggle-checklist))
          (with-current-buffer buf
            (save-excursion
              (goto-char (point-min))
              (assert-true (re-search-forward "- \\[[ Xx]\\] Plain root bullet B" nil t)
                           "Test 21.2: Plain bullet toggled into checkbox in source buffer")))

          ;; 21.3 Refresh keybinding ('r') updates HUD when external notes/time changes occur
          (assert-equal (lookup-key org-auto-scheduler-focus-mode-map (kbd "r"))
                        #'org-auto-scheduler-focus-refresh
                        "Test 21.3: 'r' key bound to org-auto-scheduler-focus-refresh")
          ;; Directly change effort in org buffer
          (with-current-buffer buf
            (save-excursion
              (goto-char (point-min))
              (org-entry-put nil "EFFORT" "2:30")
              (save-buffer)))
          ;; Invoke refresh
          (with-current-buffer hud-buf
            (org-auto-scheduler-focus-refresh)
            (assert-true (string-match-p "Effort: 150m" (buffer-string))
                         "Test 21.3: Refresh updated Effort to 150m in HUD"))

          ;; 21.4 Work Log capture ('l') with inactive timestamp
          (assert-equal (lookup-key org-auto-scheduler-focus-mode-map (kbd "l"))
                        #'org-auto-scheduler-focus-log-work
                        "Test 21.4: 'l' key bound to org-auto-scheduler-focus-log-work")
          (assert-equal (lookup-key org-auto-scheduler-focus-mode-map (kbd "["))
                        #'org-auto-scheduler-focus-log-scroll-up
                        "Test 21.4: '[' key bound to org-auto-scheduler-focus-log-scroll-up")
          (assert-equal (lookup-key org-auto-scheduler-focus-mode-map (kbd "]"))
                        #'org-auto-scheduler-focus-log-scroll-down
                        "Test 21.4: ']' key bound to org-auto-scheduler-focus-log-scroll-down")

          (with-current-buffer hud-buf
            (org-auto-scheduler-focus-log-work "Implemented nested checklist support"))
          ;; Check that source buffer has inactive timestamp in LOGBOOK
          (with-current-buffer buf
            (save-excursion
              (goto-char (point-min))
              (assert-true (re-search-forward "- \\[[0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\} [A-Za-z]+ [0-9]\\{2\\}:[0-9]\\{2\\}\\] Implemented nested checklist support" nil t)
                           "Test 21.4: Work log entry saved with inactive timestamp in LOGBOOK")))
          ;; Check HUD reflects the new log entry
          (with-current-buffer hud-buf
            (let ((hud-str (buffer-string)))
              (assert-true (string-match-p "WORK LOG \\[1\\]" hud-str)
                           "Test 21.4: Work log header shows 1 entry")
              (assert-true (string-match-p "Implemented nested checklist support" hud-str)
                           "Test 21.4: Work log entry rendered in HUD")))

          ;; 21.5 Scrollable Work Log when entries exceed log height
          (with-current-buffer hud-buf
            ;; Add 6 more log entries (total 7 > default height 5)
            (dotimes (i 6)
              (org-auto-scheduler-focus-log-work (format "Progress milestone step #%d" (1+ i))))
            (let ((hud-str (buffer-string)))
              (assert-true (string-match-p "WORK LOG \\[1-5 of 7\\]" hud-str)
                           "Test 21.5: Work log header shows [1-5 of 7] (newest five) entries visible")
              (assert-true (string-match-p "Progress milestone step #6" hud-str)
                           "Test 21.5: Latest milestone #6 visible at offset 0"))
            ;; Scroll up to view older logs
            (org-auto-scheduler-focus-log-scroll-up)
            (let ((hud-str (buffer-string)))
              (assert-true (string-match-p "WORK LOG \\[2-6 of 7\\]" hud-str)
                           "Test 21.5: Scroll up shifted visible window to [2-6 of 7]"))
            ;; Scroll up again
            (org-auto-scheduler-focus-log-scroll-up)
            (let ((hud-str (buffer-string)))
              (assert-true (string-match-p "WORK LOG \\[3-7 of 7\\]" hud-str)
                           "Test 21.5: Scroll up shifted to oldest window [3-7 of 7]")
              (assert-true (string-match-p "Implemented nested checklist support" hud-str)
                           "Test 21.5: Oldest work log entry visible after scroll"))
            ;; Scroll down back toward newest
            (org-auto-scheduler-focus-log-scroll-down)
            (let ((hud-str (buffer-string)))
              (assert-true (string-match-p "WORK LOG \\[2-6 of 7\\]" hud-str)
                           "Test 21.5: Scroll down shifted window to [2-6 of 7]")))))
    (when (buffer-live-p buf) (kill-buffer buf))
    (when (file-exists-p temp-file) (delete-file temp-file))))
