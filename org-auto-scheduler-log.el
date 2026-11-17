;;; org-auto-scheduler-log.el --- Logging for org-auto-scheduler -*- lexical-binding: t; -*-

;;; Commentary:
;; Defines the package logger once so every module can use it.
;;
;; Use the starred macros (`org-auto-scheduler--log-debug*' and friends) in
;; code: their arguments are only evaluated when the message will actually be
;; written, so debug logging costs nothing while it is off.  The unstarred
;; functions are kept for compatibility.
;;
;; Logging is off unless `org-auto-scheduler-debug' is non-nil, or while
;; `M-x org-auto-scheduler-debug' runs.

;;; Code:

(require 'log4e)

(log4e:deflogger "org-auto-scheduler" "%t [%l] %m" "%H:%M:%S")
(org-auto-scheduler--log-set-level 'debug)

(defvar org-auto-scheduler-debug)

(defun org-auto-scheduler--log-sync-with-option ()
  "Turn package logging on or off to match `org-auto-scheduler-debug'."
  (if (bound-and-true-p org-auto-scheduler-debug)
      (org-auto-scheduler--log-enable-logging)
    (org-auto-scheduler--log-disable-logging)))

(defmacro org-auto-scheduler--with-logging (&rest body)
  "Run BODY with package logging enabled, restoring the previous state after."
  (declare (indent 0) (debug t))
  `(let ((was-on log4e--toggle-logging-org-auto-scheduler))
     (org-auto-scheduler--log-enable-logging)
     (unwind-protect (progn ,@body)
       (unless was-on (org-auto-scheduler--log-disable-logging)))))

(provide 'org-auto-scheduler-log)

;;; org-auto-scheduler-log.el ends here
