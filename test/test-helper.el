;;; test-helper.el --- Shared setup for org-auto-scheduler tests -*- lexical-binding: t -*-

;;; Commentary:
;; Loads the package from the repository root, pins the clock, and provides the
;; `assert-equal' / `assert-true' helpers used by the files in test/suites/.
;;
;; Environment variables:
;;   TEST_REAL_CLOCK=1   use the real clock instead of 08:00 today
;;   OAS_TEST_VERBOSE=1  print a line for every passing assertion

;;; Code:

(require 'ert)
(require 'cl-lib)

(defconst oas-test-dir
  (file-name-directory (or load-file-name buffer-file-name))
  "Directory holding the test files.")

(defconst oas-test-root
  (file-name-directory (directory-file-name oas-test-dir))
  "Repository root.")

(add-to-list 'load-path oas-test-root)

;; Suites mock primitives (`current-time', `yes-or-no-p', ...) with advice and
;; `cl-letf'.  On native-comp builds each needs a trampoline.  ERT points the
;; eln cache at an empty temp directory while a test runs, forcing a recompile
;; of every trampoline; keep the session's own cache so existing ones are reused.
(defconst oas-test--eln-load-path
  (and (boundp 'native-comp-eln-load-path) native-comp-eln-load-path))

;; log4e is the only hard dependency.  Prefer whatever is already on the
;; `load-path' (e.g. `make test' passes -L); fall back to package.el.
(unless (locate-library "log4e")
  (require 'package)
  (ignore-errors (package-initialize)))

(require 'org)
(require 'org-id)

;; Keep the run hermetic: the package keeps its state files (review decisions,
;; history, adherence, change log, daemon lease) in `user-emacs-directory', and
;; org-id keeps its database there too.  Point all of it at a scratch directory
;; so tests never read or write the user's real data.
(defconst oas-test-state-dir (make-temp-file "oas-test-state-" t))
(setq user-emacs-directory (file-name-as-directory oas-test-state-dir)
      org-id-locations-file (expand-file-name ".org-id-locations" oas-test-state-dir)
      org-id-locations nil
      org-id-files nil
      org-agenda-files nil)
(add-hook 'kill-emacs-hook
          (lambda () (ignore-errors (delete-directory oas-test-state-dir t))))

(load (expand-file-name "org-auto-scheduler.el" oas-test-root) nil t)

;; Many suites assume a morning start.  Pin `current-time' to 08:00 today so the
;; run is deterministic at any time of day.  Suites that bind `current-time'
;; themselves via `cl-letf' override this.
(defvar test-fixed-now
  (let ((d (decode-time)))
    (encode-time 0 0 8 (nth 3 d) (nth 4 d) (nth 5 d))))
(unless (getenv "TEST_REAL_CLOCK")
  (advice-add 'current-time :override (lambda () test-fixed-now)))

(defvar test-failures 0
  "Number of failed assertions in the suite currently running.")
(defvar oas-test-failure-descriptions nil
  "Descriptions of failed assertions in the suite currently running.")
(defvar oas-test-assertion-count 0
  "Total assertions evaluated in this Emacs session.")
(defvar test-orig-agenda-files (copy-sequence org-agenda-files))

(defconst oas-test-verbose (getenv "OAS_TEST_VERBOSE"))

(defun oas-test--record (ok desc detail)
  "Record one assertion result.  OK non-nil means pass; DESC and DETAIL describe it."
  (cl-incf oas-test-assertion-count)
  (if ok
      (when oas-test-verbose (message "PASS: %s" desc))
    (cl-incf test-failures)
    (push (concat desc detail) oas-test-failure-descriptions)
    (message "FAIL: %s%s" desc detail)))

(defun assert-equal (actual expected desc)
  "Assert that ACTUAL is `equal' to EXPECTED; DESC names the check."
  (oas-test--record (equal actual expected) desc
                    (format "\n  Expected: %S\n  Actual:   %S" expected actual)))

(defun assert-true (val desc)
  "Assert that VAL is non-nil; DESC names the check."
  (oas-test--record val desc (format " (expected non-nil, got %S)" val)))

(defconst oas-test--default-options
  (let (acc)
    (mapatoms
     (lambda (sym)
       (when (and (custom-variable-p sym)
                  (string-prefix-p "org-auto-scheduler-" (symbol-name sym)))
         (push (cons sym (copy-tree (symbol-value sym))) acc))))
    acc)
  "Every package option with the value it had right after loading.")

(defun oas-test-reset-options ()
  "Restore every package option to its value at load time.
Suites change options with `setq'; this keeps one suite from affecting the next."
  (dolist (cell oas-test--default-options)
    (set (car cell) (copy-tree (cdr cell)))))

(defun oas-test-clock-out ()
  "Stop any running Org clock, so one suite's clock cannot leak into the next.
A running clock changes the scheduler's start buffer, shifting later suites."
  (when (and (fboundp 'org-clocking-p) (org-clocking-p))
    (let ((inhibit-message t))
      (ignore-errors (org-clock-out nil t))))
  (when (boundp 'org-clock-current-task)
    (setq org-clock-current-task nil)))

(defun oas-test-run-suite-file (file)
  "Load suite FILE and signal an ERT failure listing every failed assertion."
  (setq test-failures 0
        oas-test-failure-descriptions nil)
  (oas-test-reset-options)
  (oas-test-clock-out)
  (let ((agenda-files (copy-sequence org-agenda-files)))
    (unwind-protect
        (if oas-test--eln-load-path
            (let ((native-comp-eln-load-path oas-test--eln-load-path))
              (load file nil t))
          (load file nil t))
      (setq org-agenda-files agenda-files)
      (oas-test-clock-out)))
  (when oas-test-failure-descriptions
    (ert-fail (list (format "%d assertion(s) failed" test-failures)
                    (reverse oas-test-failure-descriptions)))))

(provide 'test-helper)

;;; test-helper.el ends here
