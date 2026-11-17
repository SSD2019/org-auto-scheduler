;;; 11-agenda-cache-excludes-done-tasks.el --- Agenda Cache Excludes DONE Tasks -*- lexical-binding: t -*-

;; Loaded by test/oas-suites-test.el; uses helpers from test/test-helper.el.

;; ============================================================================
;; TEST 11: Agenda Cache Excludes DONE Tasks
;; ============================================================================
(message "\n--- TEST 11: Agenda Cache Excludes DONE Tasks ---")

(let* ((temp-dir (make-temp-file "org-done-cache-" t))
       (test-org-file (expand-file-name "test-done-cache.org" temp-dir))
       (now (current-time))
       (today-str (format-time-string "%Y-%m-%d" now))
       (today-dow (format-time-string "%a" now))
       (org-todo-keywords (quote ((sequence "TODO" "IN-PROGRESS" "|" "DONE" "CANCELLED" "DROPPED")))))

  (with-temp-file test-org-file
    (insert (format "* Normal Calendar Appointment\n<%s %s 10:00-11:00>\n" today-str today-dow))
    (insert (format "* TODO Active Non-Autosch Task\nSCHEDULED: <%s %s 11:30-12:30>\n" today-str today-dow))
    (insert (format "* DONE Completed Task\nSCHEDULED: <%s %s 13:00-14:00>\n" today-str today-dow))
    (insert (format "* CANCELLED Cancelled Task\nSCHEDULED: <%s %s 14:00-15:00>\n" today-str today-dow))
    (insert (format "* DROPPED Dropped Task\nSCHEDULED: <%s %s 15:00-16:00>\n" today-str today-dow))
    (insert (format "* DONE Completed Timestamp Event\n<%s %s 16:00-17:00>\n" today-str today-dow))
    (insert (format "* TODO Active Autosch Task :AUTOSCH:\nSCHEDULED: <%s %s 17:00-18:00>\n" today-str today-dow)))

  (setq org-agenda-files (list test-org-file))

  (org-auto-scheduler--build-agenda-cache)
  (let* ((cached-items (gethash today-str org-auto-scheduler--agenda-cache))
         (cached-titles (mapcar (lambda (item) (nth 5 item)) cached-items))
         (base-items (org-auto-scheduler--fetch-base-agenda-items-for-date today-str))
         (base-titles (mapcar (lambda (item) (nth 5 item)) base-items)))

    ;; Agenda cache checks
    (assert-true (member "Normal Calendar Appointment" cached-titles)
                 "Test 11: Agenda cache retains pure calendar appointment without TODO state")
    (assert-true (member "Active Non-Autosch Task" cached-titles)
                 "Test 11: Agenda cache retains active non-AUTOSCH TODO task")
    (assert-true (not (member "Completed Task" cached-titles))
                 "Test 11: Agenda cache excludes DONE scheduled task")
    (assert-true (not (member "Cancelled Task" cached-titles))
                 "Test 11: Agenda cache excludes CANCELLED scheduled task")
    (assert-true (not (member "Dropped Task" cached-titles))
                 "Test 11: Agenda cache excludes DROPPED scheduled task")
    (assert-true (not (member "Completed Timestamp Event" cached-titles))
                 "Test 11: Agenda cache excludes DONE timestamp event")
    (assert-true (not (member "Active Autosch Task" cached-titles))
                 "Test 11: Agenda cache excludes AUTOSCH task")

    ;; Base items checks
    (assert-true (member "Normal Calendar Appointment" base-titles)
                 "Test 11: Base agenda items retain pure calendar appointment")
    (assert-true (member "Active Non-Autosch Task" base-titles)
                 "Test 11: Base agenda items retain active non-AUTOSCH task")
    (assert-true (not (member "Completed Task" base-titles))
                 "Test 11: Base agenda items exclude DONE task")
    (assert-true (not (member "Completed Timestamp Event" base-titles))
                 "Test 11: Base agenda items exclude DONE event"))

  (delete-directory temp-dir t))
