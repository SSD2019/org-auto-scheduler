;;; 34-background-write-safety.el --- Background runs never write over user edits -*- lexical-binding: t -*-

;; Loaded by test/oas-suites-test.el; uses helpers from test/test-helper.el.

;; The background runner first does a dry run, which may yield to the UI in
;; an async run.  If the user edits an agenda buffer meanwhile, the commit
;; must be skipped and the buffer must not be saved (it holds the user's own
;; unsaved edits).  When the commit does happen, it must not yield, so edits
;; cannot interleave with a half-written schedule.

(message "\n--- TEST 34: Background Write Safety ---")

(defun t34-setup (dir)
  "Write a one-task agenda file in DIR and return its path."
  (let ((file (expand-file-name "bg.org" dir)))
    (with-temp-file file
      (insert "* TODO Write report :AUTOSCH:\n:PROPERTIES:\n:ID: t34-task\n:Effort: 60\n:END:\n"))
    file))

(defmacro t34-with-daemon (file &rest body)
  "Run BODY with FILE as the only agenda file and the daemon enabled."
  (declare (indent 1))
  `(let ((org-agenda-files (list ,file))
         (org-auto-scheduler-background-enabled t)
         (org-auto-scheduler-background-save-buffers t)
         (org-auto-scheduler-allowed-hostnames nil)
         (org-auto-scheduler-sync-caldav nil)
         (org-auto-scheduler-lease-file (expand-file-name "lease.el" (file-name-directory ,file)))
         (org-auto-scheduler--last-background-run-date (format-time-string "%Y-%m-%d" (current-time)))
         (inhibit-message t))
     ,@body))

;; 34.1-34.3: an edit made during the dry run blocks the commit and the save.
(let* ((dir (make-temp-file "oas-t34a-" t))
       (file (t34-setup dir))
       (buf (find-file-noselect file))
       (committed nil))
  (unwind-protect
      (t34-with-daemon file
        (cl-letf* ((orig (symbol-function 'org-auto-scheduler-schedule-tasks))
                   ((symbol-function 'org-auto-scheduler-schedule-tasks)
                    (lambda (&rest args)
                      (if org-auto-scheduler--preview-mode
                          (prog1 (apply orig args)
                            ;; The user types while the dry run yields.
                            (with-current-buffer buf
                              (goto-char (point-max))
                              (insert "user note\n")))
                        (setq committed t)
                        (apply orig args)))))
          (org-auto-scheduler--execute-background-job))
        (assert-true (not committed)
                     "Test 34.1: Commit is skipped when a buffer was edited during the dry run")
        (assert-true (buffer-modified-p buf)
                     "Test 34.2: The user's unsaved edit is not saved by the background run")
        (assert-true (not (string-match-p "SCHEDULED"
                                          (with-temp-buffer (insert-file-contents file) (buffer-string))))
                     "Test 34.3: The file on disk is untouched"))
    (with-current-buffer buf (set-buffer-modified-p nil) (kill-buffer))
    (delete-directory dir t)))

;; 34.4-34.5: an undisturbed run commits, saves, and does not yield while writing.
(let* ((dir (make-temp-file "oas-t34b-" t))
       (file (t34-setup dir))
       (buf (find-file-noselect file))
       (yield-allowed-during-commit 'unset))
  (unwind-protect
      (t34-with-daemon file
        (cl-letf* ((orig (symbol-function 'org-auto-scheduler-schedule-tasks))
                   ((symbol-function 'org-auto-scheduler-schedule-tasks)
                    (lambda (&rest args)
                      (unless org-auto-scheduler--preview-mode
                        (setq yield-allowed-during-commit (not org-auto-scheduler--inhibit-yield)))
                      (apply orig args))))
          (org-auto-scheduler--execute-background-job))
        (assert-equal yield-allowed-during-commit nil
                      "Test 34.4: The commit runs with yielding disabled")
        (assert-true (and (not (buffer-modified-p buf))
                          (string-match-p "SCHEDULED: <"
                                          (with-temp-buffer (insert-file-contents file) (buffer-string))))
                     "Test 34.5: An undisturbed run commits and saves the schedule"))
    (with-current-buffer buf (set-buffer-modified-p nil) (kill-buffer))
    (delete-directory dir t)))
