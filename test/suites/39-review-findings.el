;;; 39-review-findings.el --- Regressions from the code review of 1767d22 -*- lexical-binding: t -*-

;; Loaded by test/oas-suites-test.el; uses helpers from test/test-helper.el.
;; One section per finding; numbers match the review.

(message "\n--- TEST 39: Code Review Findings ---")

(defmacro t39-with-file (content &rest body)
  "Write CONTENT to a fresh agenda file, run BODY with `file' bound, clean up.
Time is Mon 2026-01-05 08:00 unless BODY rebinds `test-fixed-now'."
  (declare (indent 1))
  `(let* ((test-fixed-now (encode-time 0 0 8 5 1 2026))
          (dir (make-temp-file "oas-t39-" t))
          (file (expand-file-name "t.org" dir))
          (org-agenda-files (list file))
          (org-auto-scheduler-lease-file (expand-file-name "lease.el" dir))
          (inhibit-message t))
     (dolist (f (directory-files oas-test-state-dir t "\\`org-auto-scheduler-"))
       (delete-file f))
     (setq org-auto-scheduler--saved-review-decisions nil
           org-auto-scheduler--deadline-risks nil)
     (with-temp-file file (insert ,content))
     (unwind-protect (progn ,@body)
       (when (get-buffer org-auto-scheduler--deadline-risks-buffer)
         (kill-buffer org-auto-scheduler--deadline-risks-buffer))
       (when (get-file-buffer file)
         (with-current-buffer (get-file-buffer file)
           (set-buffer-modified-p nil)
           (kill-buffer)))
       (delete-directory dir t))))

(defun t39-sched (file regexp)
  "SCHEDULED of the first heading in FILE's buffer matching REGEXP."
  (with-current-buffer (find-file-noselect file)
    (save-excursion
      (goto-char (point-min))
      (re-search-forward (concat "^\\*+ .*" regexp))
      (org-entry-get nil "SCHEDULED"))))

(defun t39-disk (file)
  "Contents of FILE on disk."
  (with-temp-buffer (insert-file-contents file) (buffer-string)))

(defun t39-risk-ids ()
  (mapcar (lambda (r) (plist-get r :id)) org-auto-scheduler--deadline-risks))

(defun t39-bg-job ()
  "Run one synchronous background job with the daemon enabled."
  (let ((org-auto-scheduler-background-enabled t)
        (org-auto-scheduler-background-save-buffers t)
        (org-auto-scheduler-allowed-hostnames nil)
        (org-auto-scheduler-sync-caldav nil)
        (org-auto-scheduler--last-background-run-date (format-time-string "%Y-%m-%d" (current-time))))
    (org-auto-scheduler--execute-background-job)))

(defconst t39-meeting "* Planning meeting\n<2026-01-05 Mon 09:00-12:00>\n")

;;; #1: the placed-task index must survive `nreverse' of the list.
(let ((org-agenda-files nil)
      (org-auto-scheduler-repeater-integration nil)
      (org-auto-scheduler--agenda-cache (make-hash-table :test 'equal))
      (org-auto-scheduler-completed-tasks nil)
      (org-auto-scheduler--completed-index nil)
      (day (encode-time 0 0 10 5 1 2026))
      (mk (lambda (id h) (list id (encode-time 0 0 h 5 1 2026) (encode-time 0 0 (1+ h) 5 1 2026)
                               '("AUTOSCH") t id nil nil 0)))
      (ids (lambda () (sort (mapcar #'car (org-auto-scheduler-get-agenda-items
                                           (encode-time 0 0 10 5 1 2026)))
                            #'string<))))
  (ignore day)
  (push (funcall mk "a" 10) org-auto-scheduler-completed-tasks)
  (funcall ids)
  (push (funcall mk "b" 12) org-auto-scheduler-completed-tasks)
  (setq org-auto-scheduler-completed-tasks (nreverse org-auto-scheduler-completed-tasks))
  (assert-equal (funcall ids) '("a" "b")
                "Test 39.1a: Index sees both tasks after nreverse of a 2-entry list")
  (setq org-auto-scheduler-completed-tasks nil org-auto-scheduler--completed-index nil)
  (push (funcall mk "a" 10) org-auto-scheduler-completed-tasks)
  (push (funcall mk "b" 12) org-auto-scheduler-completed-tasks)
  (funcall ids)
  (push (funcall mk "c" 14) org-auto-scheduler-completed-tasks)
  (setq org-auto-scheduler-completed-tasks (nreverse org-auto-scheduler-completed-tasks))
  (assert-equal (funcall ids) '("a" "b" "c")
                "Test 39.1b: Index sees each task exactly once after nreverse of a 3-entry list"))

;;; #2a: a new task without :ID: must not wedge the background runner.
(t39-with-file "* TODO New task :AUTOSCH:\n:PROPERTIES:\n:Effort: 60\n:END:\n"
  (find-file-noselect file)
  (t39-bg-job)
  (assert-equal (list (buffer-modified-p (get-file-buffer file))
                      (and (string-match-p "SCHEDULED: <2026-01-05" (t39-disk file)) t))
                '(nil t)
                "Test 39.2a: A task without :ID: is scheduled and saved by the background run"))

;;; #2b: previews must not write files; the daemon still does the housekeeping.
(defconst t39-done-placeholder
  (concat "* TODO Big job :AUTOSCH:SPLITTABLE:\n:PROPERTIES:\n:ID: t39-parent\n:Effort: 4:00\n:SPLITTABLE: t\n:END:\n"
          "** DONE Big job (Remaining) :AUTOSCH_PLACEHOLDER:\n:PROPERTIES:\n:AUTOSCH_PLACEHOLDER: t\n"
          ":AUTOSCH_ORIGIN_ID: t39-parent\n:AUTOSCH_PART_NUM: 1\n:Effort: 1:00\n:END:\n"))
(t39-with-file t39-done-placeholder
  (let ((before (t39-disk file)))
    (let ((org-auto-scheduler--preview-mode t))
      (org-auto-scheduler-schedule-tasks))
    (assert-equal (t39-disk file) before
                  "Test 39.2b: A preview run leaves the file on disk untouched")))
(t39-with-file t39-done-placeholder
  (find-file-noselect file)
  (t39-bg-job)
  (assert-true (not (string-match-p "Big job (Remaining)" (t39-disk file)))
               "Test 39.2c: The background run still cleans up the DONE placeholder"))

;;; #3: a task that cannot meet its deadline must not re-trigger re-planning.
(dolist (preserve-future '(nil t))
  (t39-with-file (concat t39-meeting
                         "* TODO Long report :AUTOSCH:\nDEADLINE: <2026-01-05 Mon>\n"
                         ":PROPERTIES:\n:ID: t39-late\n:Effort: 7:00\n:END:\n"
                         "* TODO Short task :AUTOSCH:\n:PROPERTIES:\n:ID: t39-short\n:Effort: 1:00\n:END:\n")
    (let ((org-auto-scheduler-preserve-future-scheduled preserve-future))
      (org-auto-scheduler-schedule-tasks)
      ;; The user moves the short task by hand; nothing else changes.
      (with-current-buffer (get-file-buffer file)
        (goto-char (point-min))
        (re-search-forward "Short task")
        (org-schedule nil "<2026-01-05 Mon 15:00-16:00>"))
      (org-auto-scheduler-schedule-tasks)
      (assert-equal (t39-sched file "Short task") "<2026-01-05 Mon 15:00-16:00>"
                    (format "Test 39.3 (preserve-future %s): a late task does not re-plan today's other tasks"
                            preserve-future)))))

;;; #4.1: a split task kept from an earlier run is still reported late.
(t39-with-file (concat t39-meeting
                       "* TODO Split work :AUTOSCH:SPLITTABLE:\nDEADLINE: <2026-01-05 Mon>\n"
                       ":PROPERTIES:\n:ID: t39-split\n:Effort: 6:00\n:MIN_CHUNK: 60\n:END:\n")
  (org-auto-scheduler-schedule-tasks)
  (let ((first (t39-risk-ids)))
    (org-auto-scheduler-schedule-tasks)
    (assert-equal (list first (t39-risk-ids)) '(("t39-split") ("t39-split"))
                  "Test 39.4a: A kept split task's later chunk still counts for the deadline")))

;;; #4.2: an edit in the risk list re-plans a task that already has a slot.
(t39-with-file (concat t39-meeting
                       "* TODO Review :AUTOSCH:\n"
                       "SCHEDULED: <2026-01-05 Mon 12:05-16:05> DEADLINE: <2026-01-05 Mon 15:00>\n"
                       ":PROPERTIES:\n:ID: t39-timed\n:Effort: 4:00\n:AUTOSCH_SCHEDULED: t\n:END:\n")
  (cl-letf (((symbol-function 'pop-to-buffer) #'ignore))
    (org-auto-scheduler-deadline-risks)
    (with-current-buffer org-auto-scheduler--deadline-risks-buffer
      (assert-equal (t39-risk-ids) '("t39-timed")
                    "Test 39.4b: A slot ending after a timed deadline is reported")
      (assert-equal (condition-case err
                        (progn (org-auto-scheduler-deadline-risks-set-effort "2:00") (t39-risk-ids))
                      (error (list 'error err)))
                    nil
                    "Test 39.4c: Cutting effort re-plans the already-scheduled task"))))

;;; #4.3: `+' on a task without a priority cookie raises it.
(t39-with-file (concat t39-meeting
                       "* TODO Plain :AUTOSCH:\nDEADLINE: <2026-01-05 Mon>\n"
                       ":PROPERTIES:\n:ID: t39-plain\n:Effort: 7:00\n:END:\n")
  (cl-letf (((symbol-function 'pop-to-buffer) #'ignore))
    (org-auto-scheduler-deadline-risks)
    (with-current-buffer org-auto-scheduler--deadline-risks-buffer
      (condition-case err (org-auto-scheduler-deadline-risks-raise-priority)
        (error (assert-true nil (format "Test 39.4d: + raised an error %S" err))))
      (assert-equal (with-current-buffer (get-file-buffer file)
                      (goto-char (point-min))
                      (re-search-forward "Plain")
                      (org-entry-get nil "PRIORITY"))
                    "A"
                    "Test 39.4d: + on a cookie-less [#B] task raises it to A"))))

;;; #4.4: recalculating in the review buffer refreshes the risk badge.
(t39-with-file (concat t39-meeting
                       "* TODO Long report :AUTOSCH:\nDEADLINE: <2026-01-05 Mon>\n"
                       ":PROPERTIES:\n:ID: t39-late\n:Effort: 7:00\n:END:\n")
  (cl-letf (((symbol-function 'switch-to-buffer) #'ignore))
    (org-auto-scheduler-review-and-apply))
  (with-current-buffer "*Org Auto Scheduler Review*"
    (setq org-auto-scheduler--deadline-risks nil)
    (org-auto-scheduler-review-recalculate)
    (assert-equal (t39-risk-ids) '("t39-late")
                  "Test 39.4e: Review recalculation recomputes deadline risks"))
  (kill-buffer "*Org Auto Scheduler Review*"))

;;; #5: a score change between the first and second run takes effect at once.
(t39-with-file (concat "* TODO [#B] First :AUTOSCH:\n:PROPERTIES:\n:ID: t39-a\n:Effort: 1:00\n:END:\n"
                       "* TODO [#B] Second :AUTOSCH:\n:PROPERTIES:\n:ID: t39-b\n:Effort: 1:00\n:END:\n")
  (let ((org-auto-scheduler-preserve-today-scheduled nil))
    (org-auto-scheduler-schedule-tasks)
    (with-current-buffer (get-file-buffer file)
      (goto-char (point-min))
      (re-search-forward "Second")
      (org-priority ?A))
    (org-auto-scheduler-schedule-tasks)
    (assert-true (string< (t39-sched file "Second") (t39-sched file "First"))
                 "Test 39.5: Raising priority after the first run reorders on the second run")))

;;; #6a: a run started on a day off uses the next working day's morning.
(dolist (split '(nil t))
  (t39-with-file (format "* TODO Task :AUTOSCH:%s\n:PROPERTIES:\n:ID: t39-off\n:Effort: 1:00\n:END:\n"
                         (if split "SPLITTABLE:" ""))
    (let ((test-fixed-now (encode-time 0 0 14 5 1 2026)) ; Mon 14:00, Monday off
          (org-auto-scheduler-excluded-days '(1)))
      (org-auto-scheduler-schedule-tasks)
      (assert-equal (t39-sched file "Task") "<2026-01-06 Tue 09:00-10:00>"
                    (format "Test 39.6a (splittable %s): first slot after a day off is the next morning"
                            split)))))

;;; #6b: a slot kept on a date that has since become a day off is moved.
(t39-with-file "* TODO Task :AUTOSCH:\n:PROPERTIES:\n:ID: t39-moved\n:Effort: 1:00\n:END:\n"
  (org-auto-scheduler-schedule-tasks)
  (let ((before (t39-sched file "Task"))
        (org-auto-scheduler-days-off '("2026-01-05")))
    (org-auto-scheduler-schedule-tasks)
    (assert-equal (list before (t39-sched file "Task"))
                  '("<2026-01-05 Mon 09:00-10:00>" "<2026-01-06 Tue 09:00-10:00>")
                  "Test 39.6b: Adding a day off moves a task already scheduled on it")))

;;; #5 (parallel siblings): same, inside a PARALLEL project, where new tasks are
;;; slotted by score.
(t39-with-file (concat "* Project :PROJECT:PARALLEL:\n"
                       "** TODO [#B] First :AUTOSCH:\n:PROPERTIES:\n:ID: t39-pa\n:Effort: 1:00\n:END:\n"
                       "** TODO [#B] Second :AUTOSCH:\n:PROPERTIES:\n:ID: t39-pb\n:Effort: 1:00\n:END:\n")
  (let ((org-auto-scheduler-preserve-today-scheduled nil))
    (org-auto-scheduler-schedule-tasks)
    (let ((before (list (t39-sched file "First") (t39-sched file "Second"))))
      (with-current-buffer (get-file-buffer file)
        (goto-char (point-min))
        (re-search-forward "Second")
        (org-priority ?A))
      (org-auto-scheduler-schedule-tasks)
      (assert-true (and (string< (car before) (cadr before))
                        (string< (t39-sched file "Second") (t39-sched file "First")))
                   "Test 39.5b: In a parallel project, raising priority reorders on the second run"))))

;;; Follow-up A: a known-late task still moves up once time frees, without
;;; re-planning anything else (preserve-future on, as in #3).
(t39-with-file (concat t39-meeting
                       "* TODO Long report :AUTOSCH:\nDEADLINE: <2026-01-05 Mon>\n"
                       ":PROPERTIES:\n:ID: t39-late2\n:Effort: 7:00\n:END:\n")
  (let ((org-auto-scheduler-preserve-future-scheduled t))
    (org-auto-scheduler-schedule-tasks)
    (let ((first (t39-sched file "Long report")))
      (org-auto-scheduler-schedule-tasks)
      (assert-equal (list first (t39-sched file "Long report"))
                    '("<2026-01-06 Tue 09:00-16:00>" "<2026-01-06 Tue 09:00-16:00>")
                    "Test 39.7a: A late task with no better slot stays where it is")
      ;; The meeting is cancelled: today now has room.
      (with-current-buffer (get-file-buffer file)
        (goto-char (point-min))
        (re-search-forward "^\\* Planning meeting")
        (org-cut-subtree))
      (org-auto-scheduler-schedule-tasks)
      (assert-equal (list (t39-sched file "Long report") (t39-risk-ids))
                    '("<2026-01-05 Mon 09:00-16:00>" nil)
                    "Test 39.7b: Once time frees up, the late task moves before its deadline"))))

;;; Follow-up B: a re-plan request from the risk list survives a restart and
;;; is removed by the next real run.
(t39-with-file (concat t39-meeting
                       "* TODO Review :AUTOSCH:\n"
                       "SCHEDULED: <2026-01-05 Mon 12:05-16:05> DEADLINE: <2026-01-05 Mon 15:00>\n"
                       ":PROPERTIES:\n:ID: t39-hint\n:Effort: 4:00\n:AUTOSCH_SCHEDULED: t\n:END:\n")
  (cl-letf (((symbol-function 'pop-to-buffer) #'ignore))
    (org-auto-scheduler-deadline-risks)
    (with-current-buffer org-auto-scheduler--deadline-risks-buffer
      (org-auto-scheduler-deadline-risks-set-effort "2:00")))
  ;; "Restart": save, close the file, forget in-memory state, reopen.
  (with-current-buffer (get-file-buffer file) (save-buffer) (kill-buffer))
  (setq org-auto-scheduler--deadline-risks nil
        org-auto-scheduler--deadline-candidates nil)
  (assert-true (string-match-p ":AUTOSCH_REPLAN: t" (t39-disk file))
               "Test 39.8a: The re-plan request is stored in the file")
  (find-file-noselect file)
  (org-auto-scheduler-schedule-tasks)
  (assert-equal (list (t39-sched file "Review")
                      (with-current-buffer (get-file-buffer file)
                        (goto-char (point-min))
                        (and (search-forward "AUTOSCH_REPLAN" nil t) t)))
                '("<2026-01-05 Mon 12:05-14:05>" nil)
                "Test 39.8b: After a restart the next real run re-places the task and drops the request"))

;;; Follow-up C (#4.2, third point): with preserve-future-scheduled on, raising
;;; a late task's priority from the risk list may displace an unpinned
;;; lower-priority task already booked before its deadline; pinned tasks stay.
(t39-with-file (concat t39-meeting
                       "* TODO [#C] Other work :AUTOSCH:\n"
                       "SCHEDULED: <2026-01-06 Tue 09:00-13:00>\n"
                       ":PROPERTIES:\n:ID: t39-other\n:Effort: 4:00\n:AUTOSCH_SCHEDULED: t\n:END:\n"
                       "* TODO [#C] Pinned call :AUTOSCH:PINNED:\n"
                       "SCHEDULED: <2026-01-06 Tue 16:00-16:30>\n"
                       ":PROPERTIES:\n:ID: t39-pin\n:Effort: 0:30\n:PINNED: t\n"
                       ":PINNED_TIME: 2026-01-06 16:00\n:AUTOSCH_SCHEDULED: t\n:END:\n"
                       "* TODO [#B] Report :AUTOSCH:\nDEADLINE: <2026-01-06 Tue>\n"
                       ":PROPERTIES:\n:ID: t39-report\n:Effort: 6:00\n:END:\n")
  (let ((org-auto-scheduler-preserve-future-scheduled t))
    (cl-letf (((symbol-function 'pop-to-buffer) #'ignore))
      (org-auto-scheduler-deadline-risks)
      (with-current-buffer org-auto-scheduler--deadline-risks-buffer
        (assert-equal (t39-risk-ids) '("t39-report")
                      "Test 39.9a: The report is late behind a booked lower-priority task")
        (org-auto-scheduler-deadline-risks-raise-priority)
        (assert-equal (t39-risk-ids) nil
                      "Test 39.9b: Raising its priority lets it take that task's slot")))
    (org-auto-scheduler-schedule-tasks)
    (assert-equal (list (t39-sched file "Report") (t39-sched file "Other work")
                        (t39-sched file "Pinned call"))
                  '("<2026-01-06 Tue 09:00-15:00>" "<2026-01-05 Mon 12:05-16:05>"
                    "<2026-01-06 Tue 16:00-16:30>")
                  "Test 39.9c: The real run writes it; the displaced task moves, the pinned one stays")))
