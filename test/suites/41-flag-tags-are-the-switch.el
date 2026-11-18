;;; 41-flag-tags-are-the-switch.el --- FREESET, PINNED and INDEPENDENT follow their tags -*- lexical-binding: t -*-

;; Loaded by test/oas-suites-test.el; uses helpers from test/test-helper.el.
;; Removing one of these tags by hand used to leave the flag on, because a
;; leftover property (or a saved review decision) still counted.  The tag is
;; now the switch, as for SPLITTABLE (suite 40.11).

(message "\n--- TEST 41: Flag Tags Are the Switch ---")

(defmacro t41-with-heading (text &rest body)
  "Insert TEXT in a fresh Org file buffer, go to its first heading, run BODY."
  (declare (indent 1))
  `(let* ((dir (make-temp-file "oas-t41-" t))
          (file (expand-file-name "t.org" dir))
          (org-agenda-files (list file))
          (org-auto-scheduler--review-overrides (make-hash-table :test 'equal))
          (org-auto-scheduler--saved-review-decisions nil)
          (org-auto-scheduler--saved-decision-cache nil))
     (with-temp-file file (insert ,text))
     (unwind-protect
         (with-current-buffer (find-file-noselect file)
           (org-id-update-id-locations (list file) t)
           (goto-char (point-min))
           (org-back-to-heading t)
           (let ((m (point-marker)))
             ,@body))
       (when (get-file-buffer file)
         (with-current-buffer (get-file-buffer file)
           (set-buffer-modified-p nil)
           (kill-buffer)))
       (delete-directory dir t))))

;;; 41.1 FREESET
(t41-with-heading "* TODO Free :AUTOSCH:\n:PROPERTIES:\n:ID: t41-free\n:FREESET: t\n:PINNABLE: t\n:END:\n"
  (assert-true (not (org-auto-scheduler-task-freeset-p m))
               "Test 41.1: leftover FREESET/PINNABLE properties alone are not FREESET"))

(t41-with-heading "* TODO Free :AUTOSCH:FREESET:\n:PROPERTIES:\n:ID: t41-free\n:END:\n"
  (assert-true (org-auto-scheduler-task-freeset-p m)
               "Test 41.1: the FREESET tag alone is FREESET"))

(t41-with-heading "* TODO Free :AUTOSCH:\n:PROPERTIES:\n:ID: t41-free\n:END:\n"
  (setq org-auto-scheduler--saved-review-decisions
        '(("t41-free" :freeset t :pinnable t)))
  (assert-true (not (org-auto-scheduler-task-freeset-p m "t41-free"))
               "Test 41.1: a saved FREESET decision without the tag does not count")
  (assert-true (not (org-auto-scheduler-task-freeset-p nil "t41-free"))
               "Test 41.1: ...also when only the task ID is known"))

;;; 41.2 PINNED
(t41-with-heading "* TODO Pin :AUTOSCH:\n:PROPERTIES:\n:ID: t41-pin\n:PINNED: t\n:PINNED_TIME: 2026-01-06 14:00\n:END:\n"
  (assert-true (not (org-auto-scheduler-task-pinned-p m))
               "Test 41.2: PINNED_TIME without the tag is not pinned")
  (assert-equal (org-auto-scheduler-task-pinned-time m) nil
                "Test 41.2: ...and has no pin time")
  (assert-equal (org-auto-scheduler--compute-pinned-tasks-reservations "2026-01-06") nil
                "Test 41.2: ...and reserves no slot"))

(t41-with-heading "* TODO Pin :AUTOSCH:PINNED:\n:PROPERTIES:\n:ID: t41-pin\n:PINNED_TIME: 2026-01-06 14:00\n:END:\n"
  (assert-true (org-auto-scheduler-task-pinned-p m)
               "Test 41.2: tag plus PINNED_TIME is pinned")
  (assert-equal (format-time-string "%Y-%m-%d %H:%M" (org-auto-scheduler-task-pinned-time m))
                "2026-01-06 14:00"
                "Test 41.2: ...at its PINNED_TIME"))

(t41-with-heading "* TODO Pin :AUTOSCH:PINNED:\n:PROPERTIES:\n:ID: t41-pin\n:END:\n"
  (assert-true (not (org-auto-scheduler-task-pinned-p m))
               "Test 41.2: the tag without a pin time anchors nothing"))

(t41-with-heading "* TODO Pin :AUTOSCH:\n:PROPERTIES:\n:ID: t41-pin\n:END:\n"
  (setq org-auto-scheduler--saved-review-decisions
        '(("t41-pin" :pinned t :pinned-time "2026-01-06 14:00")))
  (assert-true (not (org-auto-scheduler-task-pinned-p nil "t41-pin"))
               "Test 41.2: a saved review pin without the tag does not count (ID only)")
  (assert-true (not (org-auto-scheduler-task-pinned-p m "t41-pin"))
               "Test 41.2: ...nor with the marker")
  (assert-equal (org-auto-scheduler--compute-pinned-tasks-reservations "2026-01-06") nil
                "Test 41.2: ...and reserves no slot"))

(t41-with-heading "* TODO Pin :AUTOSCH:PINNED:\n:PROPERTIES:\n:ID: t41-pin\n:END:\n"
  (setq org-auto-scheduler--saved-review-decisions
        '(("t41-pin" :pinned t :pinned-time "2026-01-06 14:00")))
  (assert-true (org-auto-scheduler-task-pinned-p nil "t41-pin")
               "Test 41.2: a saved review pin with the tag still counts"))

(t41-with-heading "* TODO Pin :AUTOSCH:\n:PROPERTIES:\n:ID: t41-pin\n:END:\n"
  (puthash "t41-pin" (list :pinned t :pinned-time "2026-01-06 14:00")
           org-auto-scheduler--review-overrides)
  (assert-true (org-auto-scheduler-task-pinned-p m "t41-pin")
               "Test 41.2: a pin made in the open review session counts before saving"))

;;; 41.3 INDEPENDENT
(t41-with-heading "* TODO Ind :AUTOSCH:\n:PROPERTIES:\n:ID: t41-ind\n:INDEPENDENT: t\n:PARALLEL: t\n:END:\n"
  (assert-true (not (org-auto-scheduler-task-independent-p m))
               "Test 41.3: leftover INDEPENDENT/PARALLEL properties alone are not independent"))

(t41-with-heading "* TODO Ind :AUTOSCH:INDEPENDENT:\n:PROPERTIES:\n:ID: t41-ind\n:END:\n"
  (assert-true (org-auto-scheduler-task-independent-p m)
               "Test 41.3: the INDEPENDENT tag alone is independent"))

;;; 41.4 Turning a flag on writes only the tag (plus the pin time).
(t41-with-heading "* TODO Flags :AUTOSCH:\nSCHEDULED: <2026-01-06 Tue 14:00-15:00>\n:PROPERTIES:\n:ID: t41-flags\n:END:\n"
  (org-auto-scheduler-task-toggle-freeset m "t41-flags")
  (org-auto-scheduler-task-set-pinned-time m "t41-flags" "2026-01-06 14:00")
  (assert-true (member "FREESET" (org-get-tags m t)) "Test 41.4: FREESET toggle adds the tag")
  (assert-equal (org-entry-get m "FREESET") nil "Test 41.4: ...and no FREESET property")
  (assert-true (member "PINNED" (org-get-tags m t)) "Test 41.4: pinning adds the tag")
  (assert-equal (org-entry-get m "PINNED") nil "Test 41.4: ...and no PINNED property")
  (assert-true (string-match-p "14:00" (or (org-entry-get m "PINNED_TIME") ""))
               "Test 41.4: ...but keeps the pin time"))

;;; 41-flag-tags-are-the-switch.el ends here
