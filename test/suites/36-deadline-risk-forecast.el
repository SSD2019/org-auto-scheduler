;;; 36-deadline-risk-forecast.el --- Warn when a task will miss its deadline -*- lexical-binding: t -*-

;; Loaded by test/oas-suites-test.el; uses helpers from test/test-helper.el.

(message "\n--- TEST 36: Deadline-Risk Forecast ---")

(defun t36-risks (content)
  "Schedule CONTENT as of Mon 2026-01-05 08:00 and return (ID . REASON) risks."
  (let* ((test-fixed-now (encode-time 0 0 8 5 1 2026))
         (dir (make-temp-file "oas-t36-" t))
         (file (expand-file-name "t.org" dir))
         (org-agenda-files (list file))
         (inhibit-message t))
    (with-temp-file file (insert content))
    (unwind-protect
        (progn
          (org-auto-scheduler-schedule-tasks)
          (mapcar (lambda (r) (cons (plist-get r :id) (plist-get r :reason)))
                  org-auto-scheduler--deadline-risks))
      (when (get-file-buffer file)
        (with-current-buffer (get-file-buffer file)
          (set-buffer-modified-p nil)
          (kill-buffer)))
      (delete-directory dir t))))

(defconst t36-meeting "* Planning meeting\n<2026-01-05 Mon 09:00-12:00>\n")

(assert-equal (t36-risks (concat t36-meeting
                                 "* TODO Safe task :AUTOSCH:\nDEADLINE: <2026-01-07 Wed>\n"
                                 ":PROPERTIES:\n:ID: t36-safe\n:Effort: 60\n:END:\n"))
              nil
              "Test 36.1: A task that fits before its deadline is not at risk")

(assert-equal (t36-risks (concat t36-meeting
                                 "* TODO Long report :AUTOSCH:\nDEADLINE: <2026-01-05 Mon>\n"
                                 ":PROPERTIES:\n:ID: t36-late\n:Effort: 7:00\n:END:\n"))
              '(("t36-late" . late))
              "Test 36.2: A task pushed past its deadline by a meeting is reported as late")

(assert-equal (t36-risks (concat "* TODO Too big :AUTOSCH:\nDEADLINE: <2026-01-06 Tue>\n"
                                 ":PROPERTIES:\n:ID: t36-big\n:Effort: 10:00\n:END:\n"))
              '(("t36-big" . unplaced))
              "Test 36.3: A task that can never fit a working day is reported as unplaced")

(assert-equal (t36-risks (concat t36-meeting
                                 "* TODO Split work :AUTOSCH:SPLITTABLE:\nDEADLINE: <2026-01-05 Mon>\n"
                                 ":PROPERTIES:\n:ID: t36-split\n:Effort: 6:00\n:MIN_CHUNK: 60\n:END:\n"))
              '(("t36-split" . late))
              "Test 36.4: A split task whose last chunk lands after the deadline is late")

(assert-equal (t36-risks (concat "* TODO Old deadline :AUTOSCH:\nDEADLINE: <2025-12-29 Mon>\n"
                                 ":PROPERTIES:\n:ID: t36-old\n:Effort: 60\n:END:\n"))
              nil
              "Test 36.5: A deadline already past is left to the agenda's overdue display")

(assert-equal (t36-risks (concat t36-meeting
                                 "* TODO Timed deadline :AUTOSCH:\nDEADLINE: <2026-01-05 Mon 12:30>\n"
                                 ":PROPERTIES:\n:ID: t36-timed\n:Effort: 60\n:END:\n"))
              '(("t36-timed" . late))
              "Test 36.6: A deadline with a time is compared against that time")

;; Surfacing: review header badge and the report buffer.
(let ((org-auto-scheduler--deadline-risks
       (list (list :id "x" :headline "Long report" :marker nil
                   :deadline (encode-time 0 0 17 5 1 2026)
                   :planned-end (encode-time 0 0 12 6 1 2026) :reason 'late))))
  (assert-true (string-match-p "1 will miss deadline"
                               (substring-no-properties
                                (format "%s" (org-auto-scheduler--review-header-line nil))))
               "Test 36.7: The review header shows the risk count")
  (assert-equal (org-auto-scheduler--deadline-risk-summary)
                "1 task will miss its deadline: Long report"
                "Test 36.8: The end-of-run summary names the task")
  (cl-letf (((symbol-function 'pop-to-buffer) #'ignore))
    (org-auto-scheduler-deadline-risks))
  (assert-true (with-current-buffer "*Org Auto Scheduler Deadline Risks*"
                 (string-match-p "Long report" (buffer-string)))
               "Test 36.9: The report buffer lists the task")
  (kill-buffer "*Org Auto Scheduler Deadline Risks*"))
