;;; 22-option-2a-item-swapping-contextual-list-item-add.el --- Option 2a Item Swapping & Contextual List Item Addition in Focus HUD -*- lexical-binding: t -*-

;; Loaded by test/oas-suites-test.el; uses helpers from test/test-helper.el.

;;; ============================================================================
;;; ============================================================================
;;; TEST 22: Option 2a Item Swapping & Contextual List Item Addition in Focus HUD
;;; ============================================================================
(message "
--- TEST 22: Option 2a Item Swapping & Contextual List Item Addition in Focus HUD ---")
(let* ((temp-file (make-temp-file "org-focus-option2a-" nil ".org"))
       (buf (find-file-noselect temp-file))
       (hud-buf (get-buffer-create "*Org Focus HUD*")))
  (unwind-protect
      (progn
        (with-current-buffer buf
          (org-mode)
          (insert "* TODO Task With Intervening Notes And Media
"
                  "  :PROPERTIES:
"
                  "  :EFFORT:   1:00
"
                  "  :AUTOSCH:  t
"
                  "  :END:
"
                  "  - [ ] Top Item Alpha
"
                  "    Multi-line explanation for Alpha.
"
                  "    [[file:alpha_diagram.png]]
"
                  "
"
                  "  Unindented body paragraph discussing the module architecture.
"
                  "  [[file:module_architecture.png]]
"
                  "
"
                  "  - [ ] Bottom Item Omega
"
                  "    Notes for Omega.
")
          (save-buffer))

        (let ((m (with-current-buffer buf
                   (goto-char (point-min))
                   (point-marker))))
          ;; 22.1 Verify Keybindings for Option 2a
          (assert-equal (lookup-key org-auto-scheduler-focus-mode-map (kbd "M-k"))
                        #'org-auto-scheduler-focus-move-item-up
                        "Test 22.1: 'M-k' bound to org-auto-scheduler-focus-move-item-up")
          (assert-equal (lookup-key org-auto-scheduler-focus-mode-map (kbd "M-<up>"))
                        #'org-auto-scheduler-focus-move-item-up
                        "Test 22.1: 'M-<up>' bound to org-auto-scheduler-focus-move-item-up")
          (assert-equal (lookup-key org-auto-scheduler-focus-mode-map (kbd "M-j"))
                        #'org-auto-scheduler-focus-move-item-down
                        "Test 22.1: 'M-j' bound to org-auto-scheduler-focus-move-item-down")
          (assert-equal (lookup-key org-auto-scheduler-focus-mode-map (kbd "M-<down>"))
                        #'org-auto-scheduler-focus-move-item-down
                        "Test 22.1: 'M-<down>' bound to org-auto-scheduler-focus-move-item-down")
          (assert-equal (lookup-key org-auto-scheduler-focus-mode-map (kbd "M-h"))
                        #'org-auto-scheduler-focus-outdent-item
                        "Test 22.1: 'M-h' bound to org-auto-scheduler-focus-outdent-item")
          (assert-equal (lookup-key org-auto-scheduler-focus-mode-map (kbd "M-<left>"))
                        #'org-auto-scheduler-focus-outdent-item
                        "Test 22.1: 'M-<left>' bound to org-auto-scheduler-focus-outdent-item")
          (assert-equal (lookup-key org-auto-scheduler-focus-mode-map (kbd "M-l"))
                        #'org-auto-scheduler-focus-indent-item
                        "Test 22.1: 'M-l' bound to org-auto-scheduler-focus-indent-item")
          (assert-equal (lookup-key org-auto-scheduler-focus-mode-map (kbd "M-<right>"))
                        #'org-auto-scheduler-focus-indent-item
                        "Test 22.1: 'M-<right>' bound to org-auto-scheduler-focus-indent-item")

          ;; Render HUD
          (with-current-buffer hud-buf
            (org-auto-scheduler-focus-mode)
            (setq org-auto-scheduler-focus--target-marker m)
            (org-auto-scheduler-focus-refresh)

            ;; 22.2 Contextual addition below current cursor item
            (goto-char (point-min))
            (assert-true (search-forward "Top Item Alpha" nil t)
                         "Test 22.2: Found Top Item Alpha in HUD")
            (beginning-of-line)
            (assert-true (get-text-property (point) 'focus-check-pos)
                         "Test 22.2: Cursor has focus-check-pos property")
            ;; Add contextual checklist item below Alpha
            (org-auto-scheduler-focus-add-checklist "Substep Alpha Beta")
            ;; Cursor should now be anchored on the new item
            (assert-true (looking-at ".*Substep Alpha Beta")
                         "Test 22.2: Cursor anchored on newly inserted item"))

          ;; Verify source buffer layout for contextual insertion
          (with-current-buffer buf
            (let ((content (buffer-string)))
              ;; Substep Alpha Beta must be inserted below Alpha and its notes, before the unindented paragraph
              (let ((pos-alpha (string-match "Top Item Alpha" content))
                    (pos-diagram (string-match "alpha_diagram" content))
                    (pos-substep (string-match "Substep Alpha Beta" content))
                    (pos-unindented (string-match "Unindented body paragraph" content))
                    (pos-omega (string-match "Bottom Item Omega" content)))
                (assert-true (< pos-alpha pos-diagram) "Test 22.2: Alpha before its diagram")
                (assert-true (< pos-diagram pos-substep) "Test 22.2: Diagram before inserted substep")
                (assert-true (< pos-substep pos-unindented) "Test 22.2: Substep inserted before unindented paragraph")
                (assert-true (< pos-unindented pos-omega) "Test 22.2: Unindented paragraph before Omega"))))

          ;; 22.3 Fallback addition at end of list when cursor NOT on list item
          (with-current-buffer hud-buf
            (goto-char (point-min)) ; On header/timer, no focus-check-pos
            (assert-equal (get-text-property (point) 'focus-check-pos) nil
                          "Test 22.3: Point-min has no focus-check-pos")
            (org-auto-scheduler-focus-add-checklist "End Item Zeta")
            (assert-true (looking-at ".*End Item Zeta")
                         "Test 22.3: Cursor anchored on End Item Zeta"))

          (with-current-buffer buf
            (let ((content (buffer-string)))
              (let ((pos-omega (string-match "Bottom Item Omega" content))
                    (pos-zeta (string-match "End Item Zeta" content)))
                (assert-true (< pos-omega pos-zeta)
                             "Test 22.3: End Item Zeta appended after Bottom Item Omega"))))

          ;; 22.4 Option 2a: Move item DOWN across intervening body text & images
          (with-current-buffer hud-buf
            (goto-char (point-min))
            (search-forward "Top Item Alpha")
            (beginning-of-line)
            ;; Move Alpha DOWN past "Substep Alpha Beta"
            (org-auto-scheduler-focus-move-item-down)
            (assert-true (looking-at ".*Top Item Alpha")
                         "Test 22.4: Cursor anchored on Alpha after move down 1")
            ;; Move Alpha DOWN past Omega (jumping across unindented paragraph & image)
            (org-auto-scheduler-focus-move-item-down)
            (assert-true (looking-at ".*Top Item Alpha")
                         "Test 22.4: Cursor anchored on Alpha after jumping across intervening body"))

          (with-current-buffer buf
            (let ((content (buffer-string)))
              ;; Verify intervening text and image remain 100% intact
              (assert-true (string-match "Unindented body paragraph discussing the module architecture\." content)
                           "Test 22.4: Intervening paragraph completely intact")
              (assert-true (string-match "module_architecture\.png" content)
                           "Test 22.4: Intervening image link completely intact")
              ;; Alpha and its diagram have moved after Omega, before Zeta
              (let ((pos-unindented (string-match "Unindented body paragraph" content))
                    (pos-omega (string-match "Bottom Item Omega" content))
                    (pos-alpha (string-match "Top Item Alpha" content))
                    (pos-alpha-diag (string-match "alpha_diagram" content))
                    (pos-zeta (string-match "End Item Zeta" content)))
                (assert-true (< pos-unindented pos-omega) "Test 22.4: Unindented paragraph before Omega")
                (assert-true (< pos-omega pos-alpha) "Test 22.4: Omega before Alpha")
                (assert-true (< pos-alpha pos-alpha-diag) "Test 22.4: Alpha diagram moved along with Alpha")
                (assert-true (< pos-alpha pos-zeta) "Test 22.4: Alpha before Zeta"))))

          ;; 22.5 Option 2a: Move item UP across intervening body text & images
          (with-current-buffer hud-buf
            (goto-char (point-min))
            (search-forward "Top Item Alpha")
            (beginning-of-line)
            ;; Move Alpha UP past Omega
            (org-auto-scheduler-focus-move-item-up)
            (assert-true (looking-at ".*Top Item Alpha")
                         "Test 22.5: Cursor anchored on Alpha after move up 1")
            ;; Move Alpha UP past Substep Alpha Beta (jumping back across intervening paragraph & image)
            (org-auto-scheduler-focus-move-item-up)
            (assert-true (looking-at ".*Top Item Alpha")
                         "Test 22.5: Cursor anchored on Alpha after moving up past intervening body"))

          (with-current-buffer buf
            (let ((content (buffer-string)))
              ;; Intervening text and image remain 100% intact
              (assert-true (string-match "Unindented body paragraph discussing the module architecture\." content)
                           "Test 22.5: Intervening paragraph completely intact after move up")
              (assert-true (string-match "module_architecture\.png" content)
                           "Test 22.5: Intervening image link completely intact after move up")
              (let ((pos-alpha (string-match "Top Item Alpha" content))
                    (pos-substep (string-match "Substep Alpha Beta" content))
                    (pos-unindented (string-match "Unindented body paragraph" content))
                    (pos-omega (string-match "Bottom Item Omega" content)))
                (assert-true (< pos-alpha pos-substep) "Test 22.5: Alpha moved back before substep")
                (assert-true (< pos-substep pos-unindented) "Test 22.5: Substep before unindented paragraph")
                (assert-true (< pos-unindented pos-omega) "Test 22.5: Unindented paragraph before Omega"))))

          ;; 22.6 Indent ('M-l') and Outdent ('M-h')
          (with-current-buffer hud-buf
            (goto-char (point-min))
            (search-forward "Bottom Item Omega")
            (beginning-of-line)
            (org-auto-scheduler-focus-indent-item)
            (assert-true (looking-at ".*Bottom Item Omega")
                         "Test 22.6: Cursor anchored on Omega after indent"))

          (with-current-buffer buf
            (save-excursion
              (goto-char (point-min))
              (search-forward "Bottom Item Omega")
              (beginning-of-line)
              ;; Originally indent was 2 spaces; now it should be 4 spaces
              (assert-equal (current-indentation) 4 "Test 22.6: Omega indentation increased to 4 spaces")
              ;; Continuation note of Omega should also have been shifted rigidly by 2 spaces (from 4 to 6)
              (forward-line 1)
              (assert-equal (current-indentation) 6 "Test 22.6: Omega notes indentation rigidly shifted to 6 spaces")))

          (with-current-buffer hud-buf
            (goto-char (point-min))
            (search-forward "Bottom Item Omega")
            (beginning-of-line)
            (org-auto-scheduler-focus-outdent-item)
            (assert-true (looking-at ".*Bottom Item Omega")
                         "Test 22.6: Cursor anchored on Omega after outdent"))

          (with-current-buffer buf
            (save-excursion
              (goto-char (point-min))
              (search-forward "Bottom Item Omega")
              (beginning-of-line)
              (assert-equal (current-indentation) 2 "Test 22.6: Omega indentation restored to 2 spaces")
              (forward-line 1)
              (assert-equal (current-indentation) 4 "Test 22.6: Omega notes indentation restored to 4 spaces")))))
  (when (buffer-live-p buf) (kill-buffer buf))
    (when (file-exists-p temp-file) (delete-file temp-file))))
