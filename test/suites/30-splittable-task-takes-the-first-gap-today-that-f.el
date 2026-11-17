;;; 30-splittable-task-takes-the-first-gap-today-that-f.el --- Splittable Task Takes the First Gap Today That Fits MIN_CHUNK -*- lexical-binding: t -*-

;; Loaded by test/oas-suites-test.el; uses helpers from test/test-helper.el.

;; ============================================================================
;; TEST 30: Splittable Task Takes the First Gap Today That Fits MIN_CHUNK
;; ============================================================================
(message "\n--- TEST 30: Splittable Task Takes the First Gap Today That Fits MIN_CHUNK ---")

(with-temp-buffer
  (org-mode)
  (insert "* TODO Chunk A\n:PROPERTIES:\n:MIN_CHUNK: 0:10\n:END:\n"
          "* TODO Chunk B\n:PROPERTIES:\n:MIN_CHUNK: 10\n:END:\n"
          "* TODO Chunk C\n:PROPERTIES:\n:MIN_CHUNK: soon\n:END:\n")
  (let ((org-auto-scheduler-split-min-chunk 30))
    (goto-char (point-min))
    (re-search-forward "Chunk A")
    (assert-equal (org-auto-scheduler-get-min-chunk (point-marker)) 10
                  "Test 30.1: MIN_CHUNK accepts H:MM durations like Effort")
    (re-search-forward "Chunk B")
    (assert-equal (org-auto-scheduler-get-min-chunk (point-marker)) 10
                  "Test 30.2: MIN_CHUNK accepts plain minutes")
    (re-search-forward "Chunk C")
    (assert-equal (org-auto-scheduler-get-min-chunk (point-marker)) 30
                  "Test 30.3: Unparseable MIN_CHUNK falls back to the default")))

(let* ((today-str (format-time-string "%Y-%m-%d"))
       (today-dow (format-time-string "%a"))
       (fake-now (org-auto-scheduler-parse-time-string (format "%s %s 11:00" today-str today-dow))))
  ;; A 5h splittable task at 11:00 with ID-less meetings at 11:30, 13:00 and 15:00.
  ;; No 5h gap exists today, so the task must split into the first gap that fits MIN_CHUNK:
  ;; 11:05-11:25 (20m), 11:50-12:55 (65m), 13:35-14:55 (80m), 15:35-19:00.
  (cl-flet ((get-first-chunk-with-min-chunk (min-chunk)
              (let* ((temp-dir (make-temp-file "org-split-gap-test-" t))
                     (test-org (expand-file-name "test-split-gap.org" temp-dir))
                     (org-auto-scheduler-silent-mode t)
                     (org-auto-scheduler-sync-caldav nil)
                     (org-auto-scheduler-start-time "10:00")
                     (org-auto-scheduler-end-time "19:00")
                     (org-auto-scheduler-split-min-chunk 30)
                     (org-auto-scheduler-task-gap 5)
                     (org-auto-scheduler-daily-catchup-block nil)
                     (org-auto-scheduler-excluded-days nil)
                     (org-auto-scheduler--agenda-cache nil)
                     (min-chunk-property (if min-chunk (format ":MIN_CHUNK: %s\n" min-chunk) "")))
                (with-temp-file test-org
                  (insert (format "* Meetings\n\
** Standup\nSCHEDULED: <%s %s 11:30-11:45>\n\
** Sync\nSCHEDULED: <%s %s 13:00-13:30>\n\
** Review\nSCHEDULED: <%s %s 15:00-15:30>\n\
* Tasks :PROJECT:\n\
** TODO Long Splittable Task :SPLITTABLE:AUTOSCH:\n\
:PROPERTIES:\n\
:Effort: 5:00\n\
:ID: split-gap-task-id\n\
:SPLITTABLE: t\n\
%s:END:\n"
                                  today-str today-dow today-str today-dow today-str today-dow
                                  min-chunk-property)))
                (setq org-agenda-files (list test-org))
                (cl-letf (((symbol-function (quote current-time)) (lambda () fake-now)))
                  (org-auto-scheduler-schedule-tasks))
                (prog1 (with-current-buffer (find-file-noselect test-org)
                         (goto-char (point-min))
                         (re-search-forward ":ID:[ \t]*split-gap-task-id")
                         (org-entry-get nil "SCHEDULED"))
                  (when (get-file-buffer test-org) (kill-buffer (get-file-buffer test-org)))
                  (delete-directory temp-dir t)))))

    (let ((s (get-first-chunk-with-min-chunk nil)))
      (assert-equal s (format "<%s %s 11:50-12:55>" today-str today-dow)
                    (format "Test 30.4: Default 30m min chunk skips the 20m gap and takes 11:50 today (actual: %s)" s)))
    (let ((s (get-first-chunk-with-min-chunk "0:10")))
      (assert-equal s (format "<%s %s 11:05-11:25>" today-str today-dow)
                    (format "Test 30.5: 0:10 min chunk takes the first 20m gap today (actual: %s)" s)))
    (let ((s (get-first-chunk-with-min-chunk "1:10")))
      (assert-equal s (format "<%s %s 13:35-14:55>" today-str today-dow)
                    (format "Test 30.6: 1:10 min chunk skips the 65m gap and takes 13:35 today (actual: %s)" s)))))
