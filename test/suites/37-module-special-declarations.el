;;; 37-module-special-declarations.el --- Let-bound package variables are declared -*- lexical-binding: t -*-

;; Loaded by test/oas-suites-test.el; uses helpers from test/test-helper.el.

;; Every module uses lexical binding.  When a module let-binds a package
;; variable (to turn on preview mode, silence a run, ...) that is only
;; `defvar'ed in another file, the byte compiler makes the binding lexical and
;; the callee never sees it.  Interpreted tests cannot notice, so check the
;; source directly: each let-bound `org-auto-scheduler-*' variable must be
;; declared in the same file.

(message "\n--- TEST 37: Module Special-Variable Declarations ---")

(defun t37-read-forms (file)
  "Return all top-level forms in FILE."
  (with-temp-buffer
    (insert-file-contents file)
    (goto-char (point-min))
    (let (forms)
      (condition-case nil
          (while t (push (read (current-buffer)) forms))
        (end-of-file nil))
      (nreverse forms))))

(defun t37-declared (forms)
  "Return symbols declared special by FORMS (also inside progn/eval-and-compile)."
  (let (acc)
    (dolist (f forms)
      (when (consp f)
        (pcase (car f)
          ((or 'defvar 'defcustom 'defvar-local 'defconst) (push (cadr f) acc))
          ((or 'progn 'eval-and-compile 'eval-when-compile)
           (setq acc (append (t37-declared (cdr f)) acc))))))
    acc))

(defun t37-let-bound (form)
  "Return package symbols bound by any let/let* inside FORM."
  (let (acc)
    (cl-labels ((walk (f)
                  (when (consp f)
                    (when (and (memq (car f) '(let let*)) (listp (cadr f)))
                      (dolist (b (cadr f))
                        (let ((s (if (consp b) (car b) b)))
                          (when (and (symbolp s)
                                     (string-prefix-p "org-auto-scheduler" (symbol-name s)))
                            (push s acc)))))
                    (while (consp f)
                      (walk (car f))
                      (setq f (cdr f))))))
      (walk form))
    acc))

(dolist (file '("org-auto-scheduler.el" "org-auto-scheduler-daemon.el"
                "org-auto-scheduler-review.el" "org-auto-scheduler-analytics.el"
                "org-auto-scheduler-log.el"))
  (let* ((forms (t37-read-forms (expand-file-name file oas-test-root)))
         (declared (t37-declared forms))
         (missing (delete-dups
                   (cl-remove-if (lambda (s) (memq s declared))
                                 (apply #'append (mapcar #'t37-let-bound forms))))))
    (assert-equal (sort missing #'string<) nil
                  (format "Test 37: %s declares every package variable it let-binds" file))))
