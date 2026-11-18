;;; 01-title-marker-processing.el --- Title Marker Processing -*- lexical-binding: t -*-

;; Loaded by test/oas-suites-test.el; uses helpers from test/test-helper.el.

;; ============================================================================
;; TEST 1: Title Marker Processing & Permutations
;; ============================================================================
(message "\n--- TEST 1: Title Marker Processing ---")

(with-temp-buffer
  (org-mode)
  (insert "* TODO (-r-) Buy groceries\n")
  (insert "* TODO (-s-) Write documentation :DOCS:\n")
  (insert "* TODO (-f-) Late night hack\n")
  (insert "* TODO (-rsf-) Deploy production cluster :OPS:\n")
  (insert "* TODO (-sfr-) Run database backup\n")
  (insert "* TODO -fr- Clean up disk\n")
  (insert "* TODO (-r-all-) Overdue project task\n")
  (insert "* TODO Normal task without marker\n")
  (insert "* TODO (-\\s-) Remove splittable :SPLITTABLE:\n:PROPERTIES:\n:SPLITTABLE: t\n:END:\n")
  (insert "* TODO (-\\f-) Remove freeset :FREESET:\n:PROPERTIES:\n:FREESET: t\n:END:\n")
  (insert "* TODO (-r\\s-) Resched and unsplit :SPLITTABLE:\n:PROPERTIES:\n:SPLITTABLE: t\n:END:\n")
  (insert "* TODO (-\\s\\f-) Unsplit and unfree :SPLITTABLE:FREESET:\n:PROPERTIES:\n:SPLITTABLE: t\n:FREESET: t\n:END:\n")
  (insert "* TODO (-p-) Event to pin :AUTOSCH:\nSCHEDULED: <2026-09-20 Sun 15:30-16:30>\n:PROPERTIES:\n:ID: pin-test-1\n:END:\n")
  (insert "* TODO (-\\p-) Event to unpin :AUTOSCH:PINNED:\nSCHEDULED: <2026-09-20 Sun 15:30-16:30>\n:PROPERTIES:\n:ID: pin-test-2\n:PINNED: t\n:PINNED_TIME: 2026-09-20 15:30\n:END:\n")
  (insert "* TODO (-rp-) Resched and pin :AUTOSCH:\nSCHEDULED: <2026-09-20 Sun 16:00-17:00>\n:PROPERTIES:\n:ID: pin-test-3\n:END:\n")
  (insert "* TODO (-r\\p-) Resched and unpin :AUTOSCH:PINNED:\nSCHEDULED: <2026-09-20 Sun 16:00-17:00>\n:PROPERTIES:\n:ID: pin-test-4\n:PINNED: t\n:PINNED_TIME: 2026-09-20 16:00\n:END:\n")

  (goto-char (point-min))
  ;; T1: (-r-)
  (let* ((m (point-marker))
         (res (org-auto-scheduler--process-title-markers m)))
    (assert-true (plist-get res :reschedule) "T1 has :reschedule")
    (assert-equal (plist-get res :title) "Buy groceries" "T1 cleaned title")
    (assert-equal (org-get-heading t t t t) "Buy groceries" "T1 heading in buffer"))

  (outline-next-heading)
  ;; T2: (-s-)
  (let* ((m (point-marker))
         (res (org-auto-scheduler--process-title-markers m)))
    (assert-true (plist-get res :splittable) "T2 has :splittable")
    (assert-true (null (plist-get res :reschedule)) "T2 has no :reschedule")
    (assert-equal (plist-get res :title) "Write documentation" "T2 cleaned title")
    (assert-true (org-auto-scheduler-task-splittable-p m) "T2 is marked splittable"))

  (outline-next-heading)
  ;; T3: (-f-)
  (let* ((m (point-marker))
         (res (org-auto-scheduler--process-title-markers m)))
    (assert-true (plist-get res :freeset) "T3 has :freeset")
    (assert-equal (plist-get res :title) "Late night hack" "T3 cleaned title")
    (assert-true (org-auto-scheduler-task-freeset-p m) "T3 is marked freeset"))

  (outline-next-heading)
  ;; T4: (-rsf-)
  (let* ((m (point-marker))
         (res (org-auto-scheduler--process-title-markers m)))
    (assert-true (plist-get res :reschedule) "T4 (-rsf-) has :reschedule")
    (assert-true (plist-get res :splittable) "T4 (-rsf-) has :splittable")
    (assert-true (plist-get res :freeset) "T4 (-rsf-) has :freeset")
    (assert-equal (plist-get res :title) "Deploy production cluster" "T4 cleaned title")
    (assert-true (org-auto-scheduler-task-splittable-p m) "T4 is marked splittable")
    (assert-true (org-auto-scheduler-task-freeset-p m) "T4 is marked freeset"))

  (outline-next-heading)
  ;; T5: (-sfr-) Permutation test
  (let* ((m (point-marker))
         (res (org-auto-scheduler--process-title-markers m)))
    (assert-true (plist-get res :reschedule) "T5 (-sfr-) has :reschedule")
    (assert-true (plist-get res :splittable) "T5 (-sfr-) has :splittable")
    (assert-true (plist-get res :freeset) "T5 (-sfr-) has :freeset")
    (assert-equal (plist-get res :title) "Run database backup" "T5 cleaned title"))

  (outline-next-heading)
  ;; T6: -fr- Without parentheses
  (let* ((m (point-marker))
         (res (org-auto-scheduler--process-title-markers m)))
    (assert-true (plist-get res :reschedule) "T6 -fr- has :reschedule")
    (assert-true (plist-get res :freeset) "T6 -fr- has :freeset")
    (assert-true (null (plist-get res :splittable)) "T6 -fr- has no :splittable")
    (assert-equal (plist-get res :title) "Clean up disk" "T6 cleaned title"))

  (outline-next-heading)
  ;; T7: (-r-all-)
  (let* ((m (point-marker))
         (res (org-auto-scheduler--process-title-markers m)))
    (assert-true (plist-get res :reschedule-all) "T7 has :reschedule-all")
    (assert-true (plist-get res :reschedule) "T7 has :reschedule")
    (assert-equal (plist-get res :title) "Overdue project task" "T7 cleaned title"))

  (outline-next-heading)
  ;; T8: Normal task without marker
  (let* ((m (point-marker))
         (res (org-auto-scheduler--process-title-markers m)))
    (assert-true (null res) "T8 returns nil for no marker")
    (assert-equal (org-get-heading t t t t) "Normal task without marker" "T8 unchanged"))

  (outline-next-heading)
  ;; T9: (-\s-) Remove splittable
  (let* ((m (point-marker))
         (res (org-auto-scheduler--process-title-markers m)))
    (assert-true (plist-get res :remove-splittable) "T9 has :remove-splittable")
    (assert-true (null (plist-get res :splittable)) "T9 splittable is nil")
    (assert-equal (plist-get res :title) "Remove splittable" "T9 cleaned title")
    (assert-true (null (org-auto-scheduler-task-splittable-p m)) "T9 splittable-p is nil")
    (assert-true (null (org-entry-get nil "SPLITTABLE")) "T9 SPLITTABLE property deleted")
    (assert-true (not (member "SPLITTABLE" (org-get-tags nil t))) "T9 SPLITTABLE tag removed"))

  (outline-next-heading)
  ;; T10: (-\f-) Remove freeset
  (let* ((m (point-marker))
         (res (org-auto-scheduler--process-title-markers m)))
    (assert-true (plist-get res :remove-freeset) "T10 has :remove-freeset")
    (assert-true (null (plist-get res :freeset)) "T10 freeset is nil")
    (assert-equal (plist-get res :title) "Remove freeset" "T10 cleaned title")
    (assert-true (null (org-auto-scheduler-task-freeset-p m)) "T10 freeset-p is nil")
    (assert-true (null (org-entry-get nil "FREESET")) "T10 FREESET property deleted")
    (assert-true (not (member "FREESET" (org-get-tags nil t))) "T10 FREESET tag removed"))

  (outline-next-heading)
  ;; T11: (-r\s-) Reschedule and remove splittable
  (let* ((m (point-marker))
         (res (org-auto-scheduler--process-title-markers m)))
    (assert-true (plist-get res :reschedule) "T11 has :reschedule")
    (assert-true (plist-get res :remove-splittable) "T11 has :remove-splittable")
    (assert-true (null (org-auto-scheduler-task-splittable-p m)) "T11 splittable-p is nil")
    (assert-equal (plist-get res :title) "Resched and unsplit" "T11 cleaned title"))

  (outline-next-heading)
  ;; T12: (-\s\f-) Remove both splittable and freeset
  (let* ((m (point-marker))
         (res (org-auto-scheduler--process-title-markers m)))
    (assert-true (plist-get res :remove-splittable) "T12 has :remove-splittable")
    (assert-true (plist-get res :remove-freeset) "T12 has :remove-freeset")
    (assert-true (null (org-auto-scheduler-task-splittable-p m)) "T12 splittable-p is nil")
    (assert-true (null (org-auto-scheduler-task-freeset-p m)) "T12 freeset-p is nil")
    (assert-equal (plist-get res :title) "Unsplit and unfree" "T12 cleaned title"))

  (outline-next-heading)
  ;; T13: (-p-) Pin to incoming scheduled time
  (let* ((m (point-marker))
         (res (org-auto-scheduler--process-title-markers m)))
    (assert-true (plist-get res :pinned) "T13 has :pinned")
    (assert-true (null (plist-get res :remove-pinned)) "T13 remove-pinned is nil")
    (assert-equal (plist-get res :title) "Event to pin" "T13 cleaned title")
    (assert-true (org-auto-scheduler-task-pinned-p m) "T13 task-pinned-p is t")
    (assert-true (string-match-p "15:30" (or (org-entry-get nil "PINNED_TIME") "")) "T13 PINNED_TIME is 15:30")
    (assert-true (null (org-entry-get nil "PINNED")) "T13 no legacy PINNED property (the tag is the switch)")
    (assert-true (member "PINNED" (org-get-tags nil t)) "T13 has PINNED tag"))

  (outline-next-heading)
  ;; T14: (-\p-) Unpin
  (let* ((m (point-marker))
         (res (org-auto-scheduler--process-title-markers m)))
    (assert-true (plist-get res :remove-pinned) "T14 has :remove-pinned")
    (assert-true (null (plist-get res :pinned)) "T14 pinned is nil")
    (assert-equal (plist-get res :title) "Event to unpin" "T14 cleaned title")
    (assert-true (null (org-auto-scheduler-task-pinned-p m)) "T14 task-pinned-p is nil")
    (assert-true (null (org-entry-get nil "PINNED_TIME")) "T14 PINNED_TIME property deleted")
    (assert-true (null (org-entry-get nil "PINNED")) "T14 PINNED property deleted")
    (assert-true (not (member "PINNED" (org-get-tags nil t))) "T14 PINNED tag removed"))

  (outline-next-heading)
  ;; T15: (-rp-) Reschedule cascade and pin to incoming time
  (let* ((m (point-marker))
         (res (org-auto-scheduler--process-title-markers m)))
    (assert-true (plist-get res :reschedule) "T15 has :reschedule")
    (assert-true (plist-get res :pinned) "T15 has :pinned")
    (assert-true (org-auto-scheduler-task-pinned-p m) "T15 task-pinned-p is t")
    (assert-true (string-match-p "16:00" (or (org-entry-get nil "PINNED_TIME") "")) "T15 PINNED_TIME is 16:00")
    (assert-equal (plist-get res :title) "Resched and pin" "T15 cleaned title"))

  (outline-next-heading)
  ;; T16: (-r\p-) Reschedule cascade and unpin
  (let* ((m (point-marker))
         (res (org-auto-scheduler--process-title-markers m)))
    (assert-true (plist-get res :reschedule) "T16 has :reschedule")
    (assert-true (plist-get res :remove-pinned) "T16 has :remove-pinned")
    (assert-true (null (org-auto-scheduler-task-pinned-p m)) "T16 task-pinned-p is nil")
    (assert-equal (plist-get res :title) "Resched and unpin" "T16 cleaned title")))
