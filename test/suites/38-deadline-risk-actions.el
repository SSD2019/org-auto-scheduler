;;; 38-deadline-risk-actions.el --- Fixing at-risk tasks from the risk list -*- lexical-binding: t -*-

;; Loaded by test/oas-suites-test.el; uses helpers from test/test-helper.el.

;; Each action in the deadline-risk list edits the task, re-plans with a
;; preview, redraws the list and says whether the task is still at risk.

(message "\n--- TEST 38: Deadline-Risk List Actions ---")

(defmacro t38-with-list (content &rest body)
  "Plan CONTENT as of Mon 2026-01-05 08:00, open the risk list, run BODY in it.
In BODY, `file' is the Org file and `last-msg' the last message shown."
  (declare (indent 1))
  `(let* ((test-fixed-now (encode-time 0 0 8 5 1 2026))
          (dir (make-temp-file "oas-t38-" t))
          (file (expand-file-name "t.org" dir))
          (org-agenda-files (list file))
          (inhibit-message t)
          (last-msg nil))
     (with-temp-file file (insert ,content))
     (unwind-protect
         (cl-letf (((symbol-function 'pop-to-buffer) #'ignore)
                   ((symbol-function 'message)
                    (lambda (fmt &rest args)
                      (when fmt (setq last-msg (apply #'format fmt args))))))
           (org-auto-scheduler-deadline-risks)
           (with-current-buffer org-auto-scheduler--deadline-risks-buffer
             ,@body))
       (when (get-buffer org-auto-scheduler--deadline-risks-buffer)
         (kill-buffer org-auto-scheduler--deadline-risks-buffer))
       (when (get-file-buffer file)
         (with-current-buffer (get-file-buffer file)
           (set-buffer-modified-p nil)
           (kill-buffer)))
       (delete-directory dir t))))

(defun t38-listed-ids ()
  "IDs of the tasks currently in the risk list."
  (mapcar (lambda (r) (plist-get r :id)) org-auto-scheduler--deadline-risks))

(defun t38-goto (id)
  "Move point to the list line of task ID; return non-nil if found."
  (goto-char (point-min))
  (let ((m (text-property-search-forward 'oas-risk id
                                         (lambda (i r) (equal i (plist-get r :id))))))
    (when m (goto-char (prop-match-beginning m)))))

(defun t38-prop (file id prop)
  "PROP of the entry with ID in FILE's buffer."
  (with-current-buffer (get-file-buffer file)
    (save-excursion
      (goto-char (point-min))
      (re-search-forward (concat ":ID:[ \t]*" (regexp-quote id)))
      (org-entry-get nil prop))))

(defconst t38-meeting "* Planning meeting\n<2026-01-05 Mon 09:00-12:00>\n")

;; 38.1-38.3: the list opens on the at-risk task; cutting effort fixes it.
(t38-with-list (concat t38-meeting
                       "* TODO Long report :AUTOSCH:\nDEADLINE: <2026-01-05 Mon>\n"
                       ":PROPERTIES:\n:ID: t38-late\n:Effort: 7:00\n:END:\n")
  (assert-equal (plist-get (get-text-property (line-beginning-position) 'oas-risk) :id)
                "t38-late"
                "Test 38.1: The list opens with point on the at-risk task")
  (assert-true (string-match-p "Late by" (buffer-string))
               "Test 38.2: The list shows how late each task is")
  (org-auto-scheduler-deadline-risks-set-effort "3:00")
  (assert-equal (list (t38-prop file "t38-late" "Effort") (t38-listed-ids)
                      (and last-msg (string-match-p "no longer at risk" last-msg) t))
                '("3:00" nil t)
                "Test 38.3: Cutting effort edits the task, re-plans, and reports it is fixed"))

;; 38.4: moving the deadline later fixes it.
(t38-with-list (concat t38-meeting
                       "* TODO Long report :AUTOSCH:\nDEADLINE: <2026-01-05 Mon>\n"
                       ":PROPERTIES:\n:ID: t38-late\n:Effort: 7:00\n:END:\n")
  (org-auto-scheduler-deadline-risks-set-deadline "2026-01-07")
  (assert-equal (list (and (string-match-p "2026-01-07" (or (t38-prop file "t38-late" "DEADLINE") "")) t)
                      (t38-listed-ids))
                '(t nil)
                "Test 38.4: Moving the deadline re-plans and clears the risk"))

;; 38.5: a task too big for any single day is rescued by making it splittable.
(t38-with-list (concat "* TODO Too big :AUTOSCH:\nDEADLINE: <2026-01-07 Wed>\n"
                       ":PROPERTIES:\n:ID: t38-big\n:Effort: 10:00\n:MIN_CHUNK: 60\n:END:\n")
  (assert-equal (t38-listed-ids) '("t38-big") "Test 38.5a: The oversized task starts unplaced")
  (org-auto-scheduler-deadline-risks-toggle-splittable)
  (assert-equal (list (t38-listed-ids)
                      (and (member "SPLITTABLE" (with-current-buffer (get-file-buffer file)
                                                  (goto-char (point-min))
                                                  (re-search-forward ":ID:[ \t]*t38-big")
                                                  (org-get-tags)))
                           t))
                '(nil t)
                "Test 38.5b: Making it splittable lets it finish before the deadline"))

;; 38.6-38.7: raising priority moves it ahead of a competing task; at A it refuses.
;; Only one of the two 3-hour tasks fits Monday afternoon, so fixing one makes
;; the other late, and the list shows that trade-off.
(t38-with-list (concat t38-meeting
                       "* TODO [#B] Other work :AUTOSCH:\nDEADLINE: <2026-01-05 Mon>\n"
                       ":PROPERTIES:\n:ID: t38-other\n:Effort: 3:00\n:END:\n"
                       "* TODO [#C] Report :AUTOSCH:\nDEADLINE: <2026-01-05 Mon>\n"
                       ":PROPERTIES:\n:ID: t38-report\n:Effort: 3:00\n:END:\n")
  (assert-equal (t38-listed-ids) '("t38-report")
                "Test 38.6a: The lower-priority task is the one at risk")
  (t38-goto "t38-report")
  (org-auto-scheduler-deadline-risks-raise-priority)
  (assert-equal (list (t38-prop file "t38-report" "PRIORITY") (t38-listed-ids)
                      (and last-msg (string-match-p "still late" last-msg) t))
                '("B" ("t38-report") t)
                "Test 38.6b: C -> B ties with the other task and is still reported late")
  (t38-goto "t38-report")
  (org-auto-scheduler-deadline-risks-raise-priority)
  (assert-equal (list (t38-prop file "t38-report" "PRIORITY") (t38-listed-ids))
                '("A" ("t38-other"))
                "Test 38.6c: B -> A fixes it, and the list now shows the task it displaced"))
(t38-with-list (concat "* TODO [#A] Huge :AUTOSCH:\nDEADLINE: <2026-01-06 Tue>\n"
                       ":PROPERTIES:\n:ID: t38-huge\n:Effort: 20:00\n:END:\n")
  (assert-true (condition-case nil
                   (progn (org-auto-scheduler-deadline-risks-raise-priority) nil)
                 (user-error t))
               "Test 38.7: Raising an [#A] task says it is already highest"))

;; 38.8: actions on a non-task line give a clear error, not a crash.
(t38-with-list (concat t38-meeting
                       "* TODO Long report :AUTOSCH:\nDEADLINE: <2026-01-05 Mon>\n"
                       ":PROPERTIES:\n:ID: t38-late\n:Effort: 7:00\n:END:\n")
  (goto-char (point-min))
  (assert-true (condition-case nil
                   (progn (org-auto-scheduler-deadline-risks-set-effort "1:00") nil)
                 (user-error t))
               "Test 38.8: An action on the header line reports \"No task on this line\""))
