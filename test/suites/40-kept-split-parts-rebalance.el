;;; 40-kept-split-parts-rebalance.el --- Remaining parts of a kept split task are re-placed -*- lexical-binding: t -*-

;; Loaded by test/oas-suites-test.el; uses helpers from test/test-helper.el.
;; When a split task's first chunk is kept (scheduled today), its
;; "(Remaining)" placeholder children used to be left as they were: they
;; never merged, never followed effort/clock changes, and other tasks were
;; booked on top of them because their slots were not seen as occupied.

(message "\n--- TEST 40: Kept Split Task Remaining Parts Rebalance ---")

(defmacro t40-with-file (content &rest body)
  "Write CONTENT to a fresh agenda file, run BODY with `file' bound, clean up.
Time is Mon 2026-01-05 08:00, workday 09:00-17:00, no gaps."
  (declare (indent 1))
  `(let* ((test-fixed-now (encode-time 0 0 8 5 1 2026))
          (dir (make-temp-file "oas-t40-" t))
          (file (expand-file-name "t.org" dir))
          (org-agenda-files (list file))
          (org-auto-scheduler-lease-file (expand-file-name "lease.el" dir))
          (org-auto-scheduler-change-log-enabled nil)
          (org-auto-scheduler-silent-mode t)
          (org-auto-scheduler-sync-caldav nil)
          (org-auto-scheduler-preserve-today-scheduled t)
          (org-auto-scheduler-start-time "09:00")
          (org-auto-scheduler-end-time "17:00")
          (org-auto-scheduler-split-min-chunk 30)
          (org-auto-scheduler-task-gap 0)
          (inhibit-message t))
     (dolist (f (directory-files oas-test-state-dir t "\\`org-auto-scheduler-"))
       (delete-file f))
     (setq org-auto-scheduler--saved-review-decisions nil
           org-auto-scheduler--deadline-risks nil)
     (with-temp-file file (insert ,content))
     (unwind-protect
         (progn
           (let ((org-auto-scheduler--current-run-type 'background-sync)
                 (org-auto-scheduler--run-start-time (current-time)))
             (org-auto-scheduler-schedule-tasks))
           ,@body)
       (when (get-file-buffer file)
         (with-current-buffer (get-file-buffer file)
           (set-buffer-modified-p nil)
           (kill-buffer)))
       (delete-directory dir t))))

(defun t40-parts (file)
  "List of (SCHEDULED . Effort) for every placeholder in FILE, in file order."
  (with-current-buffer (find-file-noselect file)
    (let (acc)
      (org-map-entries
       (lambda ()
         (when (org-entry-get nil "AUTOSCH_PLACEHOLDER")
           (push (cons (org-entry-get nil "SCHEDULED") (org-entry-get nil "Effort")) acc))))
      (nreverse acc))))

(defun t40-sched (file regexp)
  "SCHEDULED of the first heading in FILE's buffer matching REGEXP."
  (with-current-buffer (find-file-noselect file)
    (save-excursion
      (goto-char (point-min))
      (re-search-forward (concat "^\\*+ .*" regexp))
      (org-entry-get nil "SCHEDULED"))))

(defun t40-part (n sched effort)
  "Org text for placeholder part N of task big-id."
  (format "*** TODO Big (Remaining) Part %d :AUTOSCH_PLACEHOLDER:
SCHEDULED: %s
:PROPERTIES:
:AUTOSCH_SCHEDULED: t
:AUTOSCH_ORIGIN_ID: big-id
:AUTOSCH_PLACEHOLDER: t
:AUTOSCH_PART_NUM: %d
:Effort: %s
:ID: big-ph-%d
:END:
" n sched n effort n))

(defun t40-parent (effort &optional logbook)
  "Org text for the kept split parent, today 09:00-17:00 with EFFORT."
  (format "* Tasks
** TODO Big :SPLITTABLE:AUTOSCH:
SCHEDULED: <2026-01-05 Mon 09:00-17:00>
:PROPERTIES:
:Effort: %s
:ID: big-id
:AUTOSCH_SCHEDULED: t
:END:
%s" effort (or logbook "")))

(defconst t40-fragmented
  (concat (t40-part 1 "<2026-01-06 Tue 09:00-10:00>" "1:00")
          (t40-part 2 "<2026-01-07 Wed 09:00-11:00>" "2:00")))

;;; 40.1 Fragmented parts merge into one chunk when a large enough gap exists.
(t40-with-file (concat (t40-parent "11:00") t40-fragmented)
  (assert-equal (t40-sched file "Big :") "<2026-01-05 Mon 09:00-17:00>"
                "Test 40.1: kept first chunk is unchanged")
  (assert-equal (t40-parts file) '(("<2026-01-06 Tue 09:00-12:00>" . "3:00"))
                "Test 40.1: two remaining parts merge into one 3h chunk on Tuesday"))

;;; 40.2 Lower effort shrinks the remaining parts.
(t40-with-file (concat (t40-parent "9:00") t40-fragmented)
  (assert-equal (t40-parts file) '(("<2026-01-06 Tue 09:00-10:00>" . "1:00"))
                "Test 40.2: effort cut to 9h leaves a single 1h part"))

;;; 40.3 Time clocked outside the kept slot is taken off the remaining parts.
(t40-with-file (concat (t40-parent "11:00" ":LOGBOOK:
CLOCK: [2026-01-02 Fri 09:00]--[2026-01-02 Fri 11:00] =>  2:00
:END:
")
                       t40-fragmented)
  (assert-equal (t40-parts file) '(("<2026-01-06 Tue 09:00-10:00>" . "1:00"))
                "Test 40.3: 2h clocked earlier leaves a single 1h part"))

;;; 40.4 Remaining fits inside the kept slot: parts are removed.
(t40-with-file (concat (t40-parent "8:00") t40-fragmented)
  (assert-equal (t40-parts file) nil
                "Test 40.4: no parts remain when the kept slot covers the effort"))

;;; 40.5 Other tasks are not booked on top of the remaining parts.
(t40-with-file (concat (t40-parent "11:00") t40-fragmented
                       "** TODO Other :AUTOSCH:
SCHEDULED: <2026-01-06 Tue 09:00-11:00>
:PROPERTIES:
:Effort: 2:00
:ID: other-id
:AUTOSCH_SCHEDULED: t
:END:
")
  (assert-equal (t40-parts file) '(("<2026-01-06 Tue 09:00-12:00>" . "3:00"))
                "Test 40.5: remaining part keeps Tuesday morning")
  (assert-equal (t40-sched file "Other") "<2026-01-06 Tue 12:00-14:00>"
                "Test 40.5: other task is placed after the remaining part, not over it"))

;;; 40.6 The background daemon (dry run, then commit) applies the same changes,
;;; including parts that only need deleting.
(defmacro t40-with-daemon-file (content &rest body)
  "Like `t40-with-file' but run one background daemon job instead."
  (declare (indent 1))
  `(let* ((test-fixed-now (encode-time 0 0 8 5 1 2026))
          (dir (make-temp-file "oas-t40d-" t))
          (file (expand-file-name "t.org" dir))
          (org-agenda-files (list file))
          (org-auto-scheduler-lease-file (expand-file-name "lease.el" dir))
          (org-auto-scheduler-change-log-enabled nil)
          (org-auto-scheduler-silent-mode t)
          (org-auto-scheduler-preserve-today-scheduled t)
          (org-auto-scheduler-start-time "09:00")
          (org-auto-scheduler-end-time "17:00")
          (org-auto-scheduler-split-min-chunk 30)
          (org-auto-scheduler-task-gap 0)
          (inhibit-message t))
     (dolist (f (directory-files oas-test-state-dir t "\\`org-auto-scheduler-"))
       (delete-file f))
     (setq org-auto-scheduler--saved-review-decisions nil
           org-auto-scheduler--deadline-risks nil)
     (with-temp-file file (insert ,content))
     (unwind-protect
         (progn
           (let ((org-auto-scheduler-background-enabled t)
                 (org-auto-scheduler-background-save-buffers t)
                 (org-auto-scheduler-allowed-hostnames nil)
                 (org-auto-scheduler-sync-caldav nil)
                 (org-auto-scheduler--last-background-run-date
                  (format-time-string "%Y-%m-%d" (current-time))))
             (org-auto-scheduler--execute-background-job))
           ,@body)
       (when (get-file-buffer file)
         (with-current-buffer (get-file-buffer file)
           (set-buffer-modified-p nil)
           (kill-buffer)))
       (delete-directory dir t))))

(t40-with-daemon-file (concat (t40-parent "11:00") t40-fragmented)
  (assert-equal (t40-parts file) '(("<2026-01-06 Tue 09:00-12:00>" . "3:00"))
                "Test 40.6: daemon merges the remaining parts"))

(t40-with-daemon-file (concat (t40-parent "9:00") t40-fragmented)
  (assert-equal (t40-parts file) '(("<2026-01-06 Tue 09:00-10:00>" . "1:00"))
                "Test 40.6: daemon deletes a part that is no longer needed"))

(t40-with-daemon-file (concat (t40-parent "8:00") t40-fragmented)
  (assert-equal (t40-parts file) nil
                "Test 40.6: daemon deletes all parts when the kept slot covers the effort"))

;;; 40.7 Repeat daemon runs on split and Pomodoro tasks report no changes.
;;; The daemon's snapshot used `-remaining-N' ids for Pomodoro parts, which the
;;; scheduler names `-pomodoro-N', so every run saw them as new and rewrote.
(defun t40-daemon-job ()
  (let ((org-auto-scheduler-background-enabled t)
        (org-auto-scheduler-background-save-buffers t)
        (org-auto-scheduler-allowed-hostnames nil)
        (org-auto-scheduler-sync-caldav nil)
        (org-auto-scheduler--last-background-run-date
         (format-time-string "%Y-%m-%d" (current-time))))
    (org-auto-scheduler--execute-background-job)))

(t40-with-daemon-file "* Tasks
** TODO Long :SPLITTABLE:AUTOSCH:
:PROPERTIES:
:Effort: 10:00
:ID: long-id
:END:
** TODO Pomo :AUTOSCH:
:PROPERTIES:
:Effort: 1:30
:POMODORO: 30:5
:ID: pomo-id
:END:
"
  (let ((parts-1 (t40-parts file)))
    (assert-true (>= (length parts-1) 2)
                 "Test 40.7: first run created split and Pomodoro parts")
    (setq org-auto-scheduler--last-run-changes nil)
    (t40-daemon-job)
    (assert-equal (mapcar (lambda (c) (plist-get c :task-id)) org-auto-scheduler--last-run-changes)
                  nil
                  "Test 40.7: second daemon run finds no changes")
    (assert-equal (t40-parts file) parts-1
                  "Test 40.7: parts are unchanged by the second run")))

;;; 40.8 A kept Pomodoro task's later intervals follow an effort cut.
(t40-with-daemon-file "* Tasks
** TODO Pomo :AUTOSCH:
SCHEDULED: <2026-01-05 Mon 09:00-09:30>
:PROPERTIES:
:Effort: 1:00
:POMODORO: 30:5
:ID: pomo-id
:AUTOSCH_SCHEDULED: t
:END:
*** TODO Pomo (Pomodoro 2/3) :AUTOSCH_PLACEHOLDER:
SCHEDULED: <2026-01-05 Mon 09:35-10:05>
:PROPERTIES:
:AUTOSCH_SCHEDULED: t
:AUTOSCH_ORIGIN_ID: pomo-id
:AUTOSCH_PLACEHOLDER: t
:AUTOSCH_PART_NUM: 2
:Effort: 0:30
:ID: pomo-ph-2
:END:
*** TODO Pomo (Pomodoro 3/3) :AUTOSCH_PLACEHOLDER:
SCHEDULED: <2026-01-05 Mon 10:10-10:40>
:PROPERTIES:
:AUTOSCH_SCHEDULED: t
:AUTOSCH_ORIGIN_ID: pomo-id
:AUTOSCH_PLACEHOLDER: t
:AUTOSCH_PART_NUM: 3
:Effort: 0:30
:ID: pomo-ph-3
:END:
"
  (assert-equal (mapcar #'car (t40-parts file)) '("<2026-01-05 Mon 09:35-10:05>")
                "Test 40.8: effort 1h leaves one Pomodoro interval after the kept one"))

;;; 40.9 Same for a Pomodoro task placed on a later day (re-placed every run).
(t40-with-daemon-file "* Busy all day
<2026-01-05 Mon 09:00-17:00>
* Tasks
** TODO Pomo :AUTOSCH:
:PROPERTIES:
:Effort: 1:30
:POMODORO: 30:5
:ID: pomo-id
:END:
"
  (let ((parts-1 (t40-parts file)))
    (assert-true (string-match-p "2026-01-06" (or (caar parts-1) ""))
                 "Test 40.9: Pomodoro parts are on Tuesday")
    (setq org-auto-scheduler--last-run-changes nil)
    (t40-daemon-job)
    (assert-equal (mapcar (lambda (c) (plist-get c :task-id)) org-auto-scheduler--last-run-changes)
                  nil
                  "Test 40.9: second daemon run finds no changes")))

;;; 40.10 Parts of a task that went WAITING (or lost AUTOSCH) are removed:
;;; nothing re-places them, and they do not block time for other tasks.
(t40-with-daemon-file (concat "#+TODO: TODO WAITING | DONE\n"
                              (replace-regexp-in-string "TODO Big" "WAITING Big" (t40-parent "11:00") t)
                              t40-fragmented)
  (assert-equal (t40-parts file) nil
                "Test 40.10: WAITING parent's remaining parts are removed"))

(t40-with-daemon-file (concat (replace-regexp-in-string ":SPLITTABLE:AUTOSCH:" ":SPLITTABLE:"
                                                        (t40-parent "11:00") t)
                              t40-fragmented)
  (assert-equal (t40-parts file) nil
                "Test 40.10: parts are removed once the parent loses AUTOSCH"))

;;; 40.11 The tag is the switch: removing it by hand turns splitting off even
;;; when an older :SPLITTABLE: t property is still in the drawer.
(defconst t40-untagged-with-prop
  (concat (replace-regexp-in-string
           ":SPLITTABLE:AUTOSCH:" ":AUTOSCH:"
           (replace-regexp-in-string ":AUTOSCH_SCHEDULED: t\n" ":AUTOSCH_SCHEDULED: t\n:SPLITTABLE: t\n"
                                     (t40-parent "11:00") t)
           t)
          t40-fragmented))

(t40-with-file t40-untagged-with-prop
  (assert-equal (t40-parts file) nil
                "Test 40.11: parts are removed once the tag is gone (direct run)")
  (assert-true (not (org-auto-scheduler-task-splittable-p
                     (with-current-buffer (find-file-noselect file)
                       (goto-char (point-min))
                       (re-search-forward "^\\*\\* TODO Big")
                       (point-marker))))
               "Test 40.11: a leftover :SPLITTABLE: t property alone is not splittable"))

(t40-with-daemon-file t40-untagged-with-prop
  (assert-equal (t40-parts file) nil
                "Test 40.11: parts are removed once the tag is gone (daemon run)"))

;;; 40-kept-split-parts-rebalance.el ends here
