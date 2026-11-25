;;; 42-split-blocker-dependencies.el --- Dependencies on split tasks -*- lexical-binding: t -*-

;; Loaded by test/oas-suites-test.el; uses helpers from test/test-helper.el.

(defmacro t42-with-agenda (content &rest body)
  "Run BODY with CONTENT in a temporary agenda file bound to `file'."
  (declare (indent 1))
  `(let* ((test-fixed-now (encode-time 0 0 8 5 1 2026))
          (dir (make-temp-file "oas-t42-" t))
          (file (expand-file-name "tasks.org" dir))
          (org-agenda-files (list file))
          (org-id-locations nil)
          (org-id-files nil)
          (org-auto-scheduler-lease-file (expand-file-name "lease.el" dir))
          (org-auto-scheduler-change-log-enabled nil)
          (org-auto-scheduler-silent-mode t)
          (org-auto-scheduler-sync-caldav nil)
          (org-auto-scheduler-preserve-today-scheduled t)
          (org-auto-scheduler-start-time "09:00")
          (org-auto-scheduler-end-time "12:00")
          (org-auto-scheduler-split-min-chunk 30)
          (org-auto-scheduler-task-gap 0)
          (org-auto-scheduler-excluded-days nil)
          (inhibit-message t))
     (dolist (f (directory-files oas-test-state-dir t "\\`org-auto-scheduler-"))
       (delete-file f))
     (setq org-auto-scheduler--saved-review-decisions nil
           org-auto-scheduler--deadline-risks nil)
     (with-temp-file file (insert ,content))
     (unwind-protect
         (progn
           (org-id-update-id-locations (list file))
           ,@body)
       (when (get-file-buffer file)
         (with-current-buffer (get-file-buffer file)
           (set-buffer-modified-p nil)
           (kill-buffer)))
       (delete-directory dir t))))

(defun t42-run (&optional preview)
  "Schedule the test agenda, optionally as a PREVIEW."
  (let ((org-auto-scheduler--current-run-type 'background-sync)
        (org-auto-scheduler--run-start-time (current-time))
        (org-auto-scheduler--preview-mode preview))
    (org-auto-scheduler-schedule-tasks)))

(defun t42-origin-parts (origin-id)
  "Return the scheduled placeholder entries for ORIGIN-ID."
  (cl-remove-if-not
   (lambda (entry)
     (equal (plist-get (nthcdr 11 entry) :origin-id) origin-id))
   org-auto-scheduler-completed-tasks))

(defun t42-assert-dependent-after-parts (description)
  "Assert that the dependent is scheduled after every blocker part, with DESCRIPTION."
  (let* ((parts (t42-origin-parts "blocker-id"))
         (dependent (assoc "dependent-id" org-auto-scheduler-completed-tasks))
         (start (nth 1 dependent)))
    (assert-true (>= (length parts) 2)
                 (concat description ": blocker has multiple later chunks"))
    (assert-true (and start (not (memq (nth 9 dependent) '(:blocked :failed :skipped)))
                      (cl-every (lambda (part) (not (time-less-p start (nth 2 part)))) parts))
                 (format "%s: dependent starts after every blocker chunk (dependent %S; parts %S)"
                         description dependent parts))))

(defconst t42-fresh-tasks
  "* Tasks\n:PROPERTIES:\n:ORDERED: nil\n:END:\n** TODO Blocker :SPLITTABLE:AUTOSCH:\n:PROPERTIES:\n:Effort: 7:00\n:ID: blocker-id\n:END:\n** TODO Dependent :AUTOSCH:\n:PROPERTIES:\n:Effort: 0:30\n:ID: dependent-id\n:BLOCKER: blocker-id\n:END:\n")

;; These placements have open time between their chunks, so using a parent's
;; end or the first matching preview marker is observably too early.
(with-temp-buffer
  (org-mode)
  (insert "* TODO Blocker\n:PROPERTIES:\n:ID: blocker-id\n:END:\n** TODO Part\n* TODO Dependent\n")
  (goto-char (point-min))
  (let* ((blocker (point-marker))
         (part-marker (progn (re-search-forward "Part") (copy-marker (line-beginning-position))))
         (dependent (progn (re-search-forward "Dependent") (copy-marker (line-beginning-position))))
         (first-end (encode-time 0 0 10 5 1 2026))
         (part-end (encode-time 0 0 11 6 1 2026))
         (last-end (encode-time 0 0 11 7 1 2026)))
    (cl-letf (((symbol-function 'org-auto-scheduler-get-blockers) (lambda (_marker) (list blocker))))
      (dolist (preview '(nil t))
        (let ((org-auto-scheduler-completed-tasks
               (list (list "blocker-id-remaining-1" nil part-end nil t "Part 1" nil
                           (if preview blocker part-marker) 0 :placeholder nil :origin-id "blocker-id")
                     (list "blocker-id" nil first-end nil t "Blocker" nil
                           (and preview blocker) 0 :split-today nil)
                     (list "blocker-id-remaining-2" nil last-end nil t "Part 2" nil
                           (if preview blocker part-marker) 0 :placeholder nil :origin-id "blocker-id"))))
          (assert-equal (org-auto-scheduler--evaluate-blockers dependent) (cons t last-end)
                        (format "%s dependency uses the final chunk end"
                                (if preview "Preview" "Live"))))))))

(t42-with-agenda t42-fresh-tasks
  (t42-run)
  (t42-assert-dependent-after-parts "Fresh live schedule"))

(t42-with-agenda t42-fresh-tasks
  (t42-run t)
  (t42-assert-dependent-after-parts "Fresh preview"))

(defconst t42-kept-tasks
  "* Tasks\n:PROPERTIES:\n:ORDERED: nil\n:END:\n** TODO Blocker :SPLITTABLE:AUTOSCH:\nSCHEDULED: <2026-01-05 Mon 09:00-12:00>\n:PROPERTIES:\n:Effort: 7:00\n:ID: blocker-id\n:AUTOSCH_SCHEDULED: t\n:END:\n*** TODO Blocker (Remaining) Part 1 :AUTOSCH_PLACEHOLDER:\nSCHEDULED: <2026-01-06 Tue 09:00-12:00>\n:PROPERTIES:\n:AUTOSCH_SCHEDULED: t\n:AUTOSCH_ORIGIN_ID: blocker-id\n:AUTOSCH_PLACEHOLDER: t\n:AUTOSCH_PART_NUM: 1\n:Effort: 3:00\n:ID: blocker-part-1\n:END:\n*** TODO Blocker (Remaining) Part 2 :AUTOSCH_PLACEHOLDER:\nSCHEDULED: <2026-01-07 Wed 09:00-10:00>\n:PROPERTIES:\n:AUTOSCH_SCHEDULED: t\n:AUTOSCH_ORIGIN_ID: blocker-id\n:AUTOSCH_PLACEHOLDER: t\n:AUTOSCH_PART_NUM: 2\n:Effort: 1:00\n:ID: blocker-part-2\n:END:\n** TODO Dependent :AUTOSCH:\n:PROPERTIES:\n:Effort: 0:30\n:ID: dependent-id\n:BLOCKER: blocker-id\n:END:\n")

(t42-with-agenda t42-kept-tasks
  (t42-run)
  (t42-assert-dependent-after-parts "Preserved split schedule"))

;; Later parts use a narrower time block, leaving a free gap before them.
;; A collision-only check can otherwise hide an early dependency release.
(t42-with-agenda (replace-regexp-in-string ":SPLITTABLE:AUTOSCH:" ":SPLITTABLE:AUTOSCH:AFTERNOON:"
                                         t42-kept-tasks t t)
  (let ((org-auto-scheduler-time-blocks '(("AFTERNOON" . (("10:00" . "12:00"))))))
    (t42-run)
    (t42-assert-dependent-after-parts "Preserved split with open gap")))

;; Siblings in an ordered project have an implicit dependency, without BLOCKER.
(t42-with-agenda (replace-regexp-in-string
                  ":BLOCKER: blocker-id\n" ""
                  (replace-regexp-in-string "\\* Tasks" "* Tasks :PROJECT:"
                   (replace-regexp-in-string ":ORDERED: nil" ":ORDERED: t\n:ID: project-id"
                    (replace-regexp-in-string ":SPLITTABLE:AUTOSCH:"
                                              ":SPLITTABLE:AUTOSCH:AFTERNOON:"
                                              t42-kept-tasks t t) t t) t t) t t)
  (let ((org-auto-scheduler-time-blocks '(("AFTERNOON" . (("10:00" . "12:00")))))
        (org-auto-scheduler--saved-review-decisions
         '(("blocker-id" . (:order 1)) ("dependent-id" . (:order 2)))))
    (cl-letf (((symbol-function 'org-auto-scheduler-load-review-decisions) #'ignore))
      (t42-run))
    (assert-true (member "blocker-id" (gethash "dependent-id" org-auto-scheduler--last-preds-map))
                 (format "Ordered project registers blocker as predecessor (dependent %S, blocker %S)"
                         (gethash "dependent-id" org-auto-scheduler--last-preds-map)
                         (gethash "blocker-id" org-auto-scheduler--last-preds-map)))
    (t42-assert-dependent-after-parts "Ordered sibling after preserved split")))

;; When the placement horizon is exhausted, partial work must not release the
;; dependency even if every part that could be placed has an end time.
(t42-with-agenda (replace-regexp-in-string ":Effort: 7:00" ":Effort: 20:00" t42-fresh-tasks t t)
  (let ((org-auto-scheduler-max-days-to-check 1))
    (t42-run)
    (let ((dependent (assoc "dependent-id" org-auto-scheduler-completed-tasks))
          (trace (gethash "dependent-id" org-auto-scheduler--placement-traces)))
      (assert-true (and (null dependent) (equal (plist-get trace :status) "BLOCKED"))
                   (format "Unplaced blocker effort leaves dependent blocked (entry %S; trace %S)"
                           dependent trace)))))

;; Marking one placeholder DONE must not complete the parent while another
;; chunk remains.  Cleanup runs automatically before each live schedule.
(t42-with-agenda (replace-regexp-in-string "TODO Blocker (Remaining) Part 1"
                                         "DONE Blocker (Remaining) Part 1"
                                         t42-kept-tasks t t)
  (org-auto-scheduler-cleanup-placeholders)
  (with-current-buffer (find-file-noselect file)
    (goto-char (point-min))
    (re-search-forward "^\\*\\* \\([A-Z]+\\) Blocker")
    (assert-equal (match-string 1) "TODO" "Completed chunk keeps parent TODO while another chunk remains")
    (assert-true (re-search-forward "^\\*\\*\\* TODO Blocker (Remaining) Part 2" nil t)
                 "Cleanup retains the other unfinished chunk")))

;;; 42-split-blocker-dependencies.el ends here
