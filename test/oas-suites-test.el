;;; oas-suites-test.el --- ERT entry point for the integration suites -*- lexical-binding: t -*-

;;; Commentary:
;; Defines one ERT test per file in test/suites/, named `oas-suite-NN-...'.
;; Run everything with `make test', or one suite with
;;   make test SELECTOR=oas-suite-13

;;; Code:

(require 'test-helper
         (expand-file-name "test-helper.el"
                           (file-name-directory (or load-file-name buffer-file-name))))

(defun oas-test--needs-focus-hud-p (file)
  "Return non-nil if suite FILE exercises the optional org-focus-hud package."
  (with-temp-buffer
    (insert-file-contents file)
    (re-search-forward "org-auto-scheduler-focus\\|org-focus-hud" nil t)))

(dolist (file (directory-files (expand-file-name "suites" oas-test-dir) t "\\`[0-9]+-.*\\.el\\'"))
  (let ((name (intern (concat "oas-suite-" (file-name-base file))))
        (needs-hud (oas-test--needs-focus-hud-p file)))
    (ert-set-test
     name
     (make-ert-test
      :name name
      :documentation (format "Run every assertion in suites/%s." (file-name-nondirectory file))
      :body (lambda ()
              ;; org-focus-hud is optional: org-auto-scheduler.el loads it from
              ;; ../org-focus-hud or the load path when present.
              (when (and needs-hud (not (featurep 'org-focus-hud)))
                (ert-skip "org-focus-hud not found (../org-focus-hud or load path)"))
              (oas-test-run-suite-file file))))))

(defun oas-test-run-batch ()
  "Run the tests selected by $SELECTOR (default: all) and exit non-zero on failure."
  (let ((selector (getenv "SELECTOR")))
    (add-hook 'kill-emacs-hook
              (lambda () (message "%d assertions evaluated" oas-test-assertion-count)))
    (ert-run-tests-batch-and-exit
     (if (and selector (not (string= selector ""))) selector t))))

;;; oas-suites-test.el ends here
