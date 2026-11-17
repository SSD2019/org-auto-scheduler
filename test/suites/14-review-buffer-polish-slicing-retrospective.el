;;; 14-review-buffer-polish-slicing-retrospective.el --- Review Buffer Polish, Slicing & Retrospective -*- lexical-binding: t -*-

;; Loaded by test/oas-suites-test.el; uses helpers from test/test-helper.el.

;; ============================================================================
;; TEST 14: Review Buffer Polish, Slicing, What-If Diff & Retrospective (Step 4)
;; ============================================================================
(message "\n--- TEST 14: Review Buffer Polish, Slicing & Retrospective ---")

;; 14.1 Capacity Gauge
(let* ((g-normal (org-auto-scheduler--render-capacity-gauge 240 480))
       (g-over (org-auto-scheduler--render-capacity-gauge 600 480)))
  (assert-true (string-match-p "50%" g-normal) "Test 14.1: Normal capacity reports 50%")
  (assert-true (string-match-p "Slack: 4.0h" g-normal) "Test 14.1: Normal capacity reports 4.0h slack")
  (assert-true (string-match-p "OVERLOAD" g-over) "Test 14.1: Overload capacity reports OVERLOAD")
  (assert-true (string-match-p "125%" g-over) "Test 14.1: Overload capacity reports 125%"))

;; 14.2 Task Slicer / Chop
(let* ((temp-dir (make-temp-file "org-test-chop-" t))
       (test-org-file (expand-file-name "test-chop.org" temp-dir)))
  (with-temp-file test-org-file
    (insert "* Tasks :PROJECT:
*** TODO Big Task To Chop :AUTOSCH:
:PROPERTIES:
:Effort: 2:00
:ID: chop-task-1
:END:
"))
  (setq org-agenda-files (list test-org-file))
  (let* ((org-auto-scheduler-review-auto-recalculate-on-move nil)
         (rev-buf (get-buffer-create "*Org Auto Scheduler Review*")))
    (with-current-buffer rev-buf
      (org-auto-scheduler-review-mode)
      (setq-local org-auto-scheduler--review-overrides (make-hash-table :test 'equal))
      (setq-local org-auto-scheduler--review-undo-stack '())
      (setq tabulated-list-entries
            (list (list "chop-task-1"
                        (vector "chop-task-1" "[X]" "1" "09:00-11:00" "120" "PROJECT" "Big Task To Chop" ""))))
      (let* ((m (with-current-buffer (find-file-noselect test-org-file)
                  (goto-char (point-min))
                  (re-search-forward "Big Task To Chop")
                  (point-marker))))
        (setq org-auto-scheduler-completed-tasks
              (list (list "chop-task-1" (current-time) (current-time) '("AUTOSCH") t "Big Task To Chop" nil m 0)))
        (tabulated-list-init-header)
        (tabulated-list-print t)
        (goto-char (point-min))
        ;; Call chop with 45 minutes
        (org-auto-scheduler-review-chop 45)
        (let ((ov (gethash "chop-task-1" org-auto-scheduler--review-overrides)))
          (assert-true ov "Test 14.2: Chop created override entry")
          (assert-true (= (plist-get ov :chop-today) 45) "Test 14.2: Chop override kept 45m today")
          (assert-equal (plist-get ov :splittable) t "Test 14.2: Chop marked task splittable"))
        ;; Test Undo
        (org-auto-scheduler-review-undo)
        (let ((ov-after (gethash "chop-task-1" org-auto-scheduler--review-overrides)))
          (assert-true (null ov-after) "Test 14.2: Review undo removed chop override")))))
  (delete-directory temp-dir t))

;; 14.3 What-If Diff Buffer
(let* ((temp-dir (make-temp-file "org-test-diff-" t))
       (test-org-file (expand-file-name "test-diff.org" temp-dir))
       (now (current-time))
       (t1-start now)
       (t1-end (time-add now (seconds-to-time 3600)))
       (t2-start (time-add now (seconds-to-time 7200)))
       (t2-end (time-add now (seconds-to-time 10800))))
  (with-temp-file test-org-file
    (insert (format "* Tasks :PROJECT:
*** TODO Unchanged Task :AUTOSCH:
SCHEDULED: %s
:PROPERTIES:
:ID: diff-unchanged
:END:
*** TODO Moved Task :AUTOSCH:
SCHEDULED: %s
:PROPERTIES:
:ID: diff-moved
:END:
*** TODO Skipped Task :AUTOSCH:
SCHEDULED: %s
:PROPERTIES:
:ID: diff-skipped
:END:
"
                    (org-auto-scheduler--format-time-range t1-start t1-end)
                    (org-auto-scheduler--format-time-range t1-start t1-end)
                    (org-auto-scheduler--format-time-range t1-start t1-end))))
  (let* ((buf (find-file-noselect test-org-file))
         (m1 (with-current-buffer buf (goto-char (point-min)) (re-search-forward "Unchanged Task") (point-marker)))
         (m2 (with-current-buffer buf (goto-char (point-min)) (re-search-forward "Moved Task") (point-marker)))
         (m3 (with-current-buffer buf (goto-char (point-min)) (re-search-forward "Skipped Task") (point-marker))))
    (setq org-auto-scheduler-completed-tasks
          (list (list "diff-unchanged" t1-start t1-end '("AUTOSCH") t "Unchanged Task" nil m1 0)
                (list "diff-moved" t2-start t2-end '("AUTOSCH") t "Moved Task" nil m2 0)
                (list "diff-skipped" t1-start t1-end '("AUTOSCH") nil "Skipped Task" nil m3 0 :skipped '("User unchecked"))
                (list "diff-new" t2-start t2-end '("AUTOSCH") t "Brand New Task" nil nil 0)))
    (let ((diff-buf (org-auto-scheduler-review-diff)))
      (assert-true (get-buffer "*Org Auto Scheduler Diff*") "Test 14.3: Diff buffer created")
      (with-current-buffer "*Org Auto Scheduler Diff*"
        (let ((str (buffer-string)))
          (assert-true (string-match-p "1 moved, 1 new, 1 skipped, 1 unchanged" str)
                       (format "Test 14.3: Diff summary counts correct: %s" str))
          (assert-true (string-match-p "Unchanged Task.*UNCHANGED" str) "Test 14.3: Unchanged task detected")
          (assert-true (string-match-p "Moved Task.*MOVED" str) "Test 14.3: Moved task detected")
          (assert-true (string-match-p "Skipped Task.*SKIPPED" str) "Test 14.3: Skipped task detected")
          (assert-true (string-match-p "Brand New Task.*NEW" str) "Test 14.3: New task detected")))))
  (delete-directory temp-dir t))

;; 14.4 Weekly Retrospective Summary
(let* ((temp-dir (make-temp-file "org-test-retro-" t))
       (test-org-file (expand-file-name "test-retro.org" temp-dir))
       (now (current-time))
       (today-str (format-time-string "%Y-%m-%d" now)))
  (with-temp-file test-org-file
    (insert (format "* Work :PROJECT:
*** DONE Completed Planned Task :AUTOSCH:
CLOSED: [%s 11:00] SCHEDULED: <%s 09:00-11:00>
:PROPERTIES:
:Effort: 2:00
:ID: retro-task-1
:END:
:LOGBOOK:
CLOCK: [%s 09:00]--[%s 11:00] =>  2:00
:END:
*** TODO Rolled Planned Task :AUTOSCH:
SCHEDULED: <%s 14:00-15:00>
:PROPERTIES:
:Effort: 1:00
:ID: retro-task-2
:END:
* Personal
*** DONE Quick Unplanned Interrupt
CLOSED: [%s 12:00]
:LOGBOOK:
CLOCK: [%s 11:30]--[%s 12:00] =>  0:30
:END:
"
                    today-str today-str today-str today-str today-str today-str today-str today-str)))
  (setq org-agenda-files (list test-org-file))
  (let ((metrics (org-auto-scheduler--analyze-retrospective 7)))
    (assert-equal (plist-get metrics :done) 1 "Test 14.4: Exactly 1 planned task completed")
    (assert-equal (plist-get metrics :planned) 2 "Test 14.4: Total 2 planned tasks")
    (assert-equal (plist-get metrics :rolled) 1 "Test 14.4: Exactly 1 planned task rolled")
    (assert-equal (round (plist-get metrics :planned-effort)) 180 "Test 14.4: 180m planned effort")
    (assert-equal (plist-get metrics :planned-clocked) 120 "Test 14.4: 120m planned clocked")
    (assert-equal (plist-get metrics :unplanned-clocked) 30 "Test 14.4: 30m unplanned clocked"))
  (org-auto-scheduler-weekly-retrospective 7)
  (assert-true (get-buffer "*Org Auto Scheduler Retrospective*") "Test 14.4: Retrospective buffer created")
  (with-current-buffer "*Org Auto Scheduler Retrospective*"
    (let ((str (buffer-string)))
      (assert-true (string-match-p "Tasks Completed:  1 (50.0%)" str) "Test 14.4: Completion percentage reported")
      (assert-true (string-match-p "Planned Effort:   3.0h" str) "Test 14.4: Planned effort hours reported")
      (assert-true (string-match-p "Planned Focus:    2.0h (80.0%)" str) "Test 14.4: Planned focus reported")
      (assert-true (string-match-p "Unplanned Work:   0.5h (20.0%)" str) "Test 14.4: Unplanned work reported")))
  (delete-directory temp-dir t))
