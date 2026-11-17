;;; 29-caldav-sync-optimization.el --- CalDAV Sync Optimization -*- lexical-binding: t -*-

;; Loaded by test/oas-suites-test.el; uses helpers from test/test-helper.el.

;; ============================================================================
;; TEST 29: CalDAV Sync Optimization (Fast Pre-Pull + Conditional Single Push)
;; ============================================================================
(message "\n--- TEST 29: CalDAV Sync Optimization ---")

(require 'org-caldav nil t)
(when (featurep 'org-caldav)
  (let* ((temp-dir (make-temp-file "autosch-caldav-test-" t))
         (test-org (expand-file-name "tasks.org" temp-dir))
         (fake-now (encode-time 0 0 9 7 10 2026)) ; Wed Oct 7, 2026 09:00
         (org-caldav-save-directory temp-dir)
         (org-caldav-calendar-id "test-cal")
         (org-caldav-url "https://caldav.example.test")
         (org-caldav-files (list test-org))
         (org-caldav-inbox test-org)
         (org-caldav-sync-direction 'twoway)
         (org-caldav-calendars nil)
         (org-caldav-show-sync-results nil)
         (org-caldav-backup-file nil)
         (org-auto-scheduler-start-time "09:00")
         (org-auto-scheduler-end-time "17:00")
         (org-auto-scheduler-preserve-today-scheduled t)
         (org-auto-scheduler-review-state-file (expand-file-name "review-state.el" temp-dir))
         (state-file (org-caldav-sync-state-filename "test-cal"))
         (propfind-calls 0)
         (check-conn-calls 0)
         (generate-ics-calls 0)
         (update-in-org-calls 0)
         (update-from-cal-calls 0)
         (call-order '())
         (mock-remote-etags '(("cal-task-1" . "etag-1"))))

    (with-temp-file test-org
      (insert "* Tasks :PROJECT:\n\
** TODO Existing Synced Task :AUTOSCH:\n\
SCHEDULED: <2026-10-07 Wed 09:05-10:05>\n\
:PROPERTIES:\n\
:Effort: 1:00\n\
:ID: cal-task-1\n\
:END:\n"))
    (setq org-agenda-files (list test-org))
    (org-id-update-id-locations (list test-org))

    ;; Compute initial MD5 of cal-task-1 and write a clean org-caldav sync state file
    ;; with mtime >= test-org mtime.
    (let ((initial-md5 (with-current-buffer (find-file-noselect test-org)
                         (save-excursion
                           (goto-char (point-min))
                           (re-search-forward ":ID:[ \t]*cal-task-1")
                           (md5 (buffer-substring-no-properties
                                 (org-entry-beginning-position)
                                 (org-entry-end-position)))))))
      (sleep-for 0.05)
      (let ((org-caldav-event-list (list (list "cal-task-1" initial-md5 "etag-1" 1 'synced))))
        (org-caldav-save-sync-state)))

    (cl-letf (((symbol-function 'current-time) (lambda () fake-now))
              ((symbol-function 'org-caldav-check-connection)
               (lambda ()
                 (setq check-conn-calls (1+ check-conn-calls))
                 t))
              ((symbol-function 'org-caldav-get-event-etag-list)
               (lambda ()
                 (setq propfind-calls (1+ propfind-calls))
                 (cl-copy-list mock-remote-etags)))
              ((symbol-function 'org-caldav-generate-ics)
               (lambda ()
                 (setq generate-ics-calls (1+ generate-ics-calls))
                 (let ((buf (generate-new-buffer " *mock-ics*")))
                   (with-current-buffer buf
                     (setq buffer-file-name (make-temp-file "mock-ics-")))
                   buf)))
              ((symbol-function 'org-caldav-update-eventdb-from-org) #'ignore)
              ((symbol-function 'org-caldav-update-events-in-cal) #'ignore)
              ((symbol-function 'org-caldav-update-eventdb-from-cal)
               (lambda ()
                 (setq update-from-cal-calls (1+ update-from-cal-calls))))
              ((symbol-function 'org-caldav-update-events-in-org)
               (lambda ()
                 (setq update-in-org-calls (1+ update-in-org-calls)))))

      ;; 28.1: Preview mode must NEVER run CalDAV pre-pull or post-push
      (let ((org-auto-scheduler-sync-caldav t)
            (org-auto-scheduler--preview-mode t))
        (org-auto-scheduler-schedule-tasks))
      (assert-equal propfind-calls 0 "Test 29.1a: Preview mode makes 0 PROPFIND calls")
      (assert-equal generate-ics-calls 0 "Test 29.1b: Preview mode makes 0 ox-icalendar exports")

      ;; 28.2: Clean no-op run (remote ETags unchanged, 0 schedule changes, clean local files)
      ;; Should perform 1 PROPFIND in pre-pull and skip post-push completely (0 exports!)
      (let ((org-auto-scheduler-sync-caldav t)
            (org-auto-scheduler--preview-mode nil))
        (org-auto-scheduler-schedule-tasks))
      (assert-equal check-conn-calls 1 "Test 29.2a: Clean run checks connection once")
      (assert-equal propfind-calls 1 "Test 29.2b: Clean run performs only 1 PROPFIND in fast pre-pull")
      (assert-equal update-in-org-calls 0 "Test 29.2c: Clean run skips org-caldav-update-events-in-org when ETags match")
      (assert-equal generate-ics-calls 0 "Test 29.2d: Clean no-op run skips post-schedule ox-icalendar export completely")

      ;; 28.3: Remote change (mobile (-r-) edit) + pre-pull ordering before cleanup-placeholders
      ;; Simulate remote ETag change on cal-task-1 that adds (-r-) to the heading
      (setq propfind-calls 0
            check-conn-calls 0
            generate-ics-calls 0
            update-in-org-calls 0
            update-from-cal-calls 0
            call-order '()
            mock-remote-etags '(("cal-task-1" . "etag-2")))

      (let ((orig-cleanup (symbol-function 'org-auto-scheduler-cleanup-placeholders)))
        (cl-letf (((symbol-function 'org-auto-scheduler-cleanup-placeholders)
                   (lambda (&rest args)
                     (push 'cleanup-placeholders call-order)
                     (apply orig-cleanup args)))
                  ((symbol-function 'org-caldav-update-events-in-org)
                   (lambda ()
                     (push 'caldav-pull-apply call-order)
                     (setq update-in-org-calls (1+ update-in-org-calls))
                     (with-current-buffer (find-file-noselect test-org)
                       (save-excursion
                         (goto-char (point-min))
                         (when (re-search-forward "\\*\\* TODO Existing Synced Task" nil t)
                           (replace-match "** TODO (-r-) Existing Synced Task" t t)))
                       (save-buffer)))))
          (let ((org-auto-scheduler-sync-caldav t)
                (org-auto-scheduler--preview-mode nil))
            (org-auto-scheduler-schedule-tasks))))

      (setq call-order (nreverse call-order))
      (assert-equal (car call-order) 'caldav-pull-apply
                    "Test 29.3a: Pre-schedule CalDAV pull runs BEFORE cleanup-placeholders")
      (assert-true (>= update-in-org-calls 1)
                    "Test 29.3b: Changed remote ETag triggers targeted cal->org pull")
      (assert-equal generate-ics-calls 1
                    "Test 29.3c: Post-schedule push exports ICS only ONCE (not twice)")
      (assert-equal check-conn-calls 1
                    "Test 29.3d: Connection check is reused between pre-pull and post-push")
      (assert-equal propfind-calls 1
                    "Test 29.3e: ETag list is cached across session when no PUT invalidation occurs")
      (assert-equal update-from-cal-calls 1
                    "Test 29.3f: Post-schedule push runs the real update-eventdb-from-cal once (keeps deleted-in-org propagation)")

      ;; 28.4: New event on external calendar (new-in-cal) + local conflict ("Org always wins")
      (setq propfind-calls 0
            generate-ics-calls 0
            update-in-org-calls 0
            mock-remote-etags '(("cal-task-1" . "etag-3")
                                ("cal-new-meeting-1" . "etag-new-1")))
      ;; Modify cal-task-1 locally in Org so its MD5 differs from saved sync state ("Org always wins")
      (with-current-buffer (find-file-noselect test-org)
        (goto-char (point-min))
        (re-search-forward ":ID:[ \t]*cal-task-1")
        (org-back-to-heading t)
        (org-set-property "Effort" "1:30")
        (save-buffer))

      (let ((observed-new-in-cal nil)
            (observed-changed-in-cal nil))
        (cl-letf (((symbol-function 'org-caldav-update-events-in-org)
                   (lambda ()
                     (setq update-in-org-calls (1+ update-in-org-calls))
                     (setq observed-new-in-cal (delete-dups (append observed-new-in-cal (mapcar #'car (org-caldav-filter-events 'new-in-cal)))))
                     (setq observed-changed-in-cal (delete-dups (append observed-changed-in-cal (mapcar #'car (org-caldav-filter-events 'changed-in-cal))))))))
          (let ((org-auto-scheduler-sync-caldav t)
                (org-auto-scheduler--preview-mode nil))
            (org-auto-scheduler-schedule-tasks)))
        (assert-equal observed-new-in-cal '("cal-new-meeting-1")
                      "Test 29.4a: Brand-new external calendar UID is detected as new-in-cal during fast pre-pull")
        (assert-equal observed-changed-in-cal nil
                      "Test 29.4b: Locally modified Org entry preserves 'Org always wins' (not overwritten by changed-in-cal)")
        (assert-equal generate-ics-calls 1
                      "Test 29.4c: Dirty local conflict triggers single post-schedule push"))

      ;; 28.5: Two-Phase Background Daemon (no duplicate pre-pull in Phase 2, 0 exports on no-op idle run)
      (with-temp-file test-org
        (insert "* Tasks :PROJECT:\n\
** TODO Unscheduled Daemon Task :AUTOSCH:\n\
:PROPERTIES:\n\
:Effort: 1:00\n\
:ID: cal-task-1\n\
:END:\n"))
      (with-current-buffer (find-file-noselect test-org)
        (revert-buffer t t t))
      (let ((unsched-md5 (with-current-buffer (find-file-noselect test-org)
                           (save-excursion
                             (goto-char (point-min))
                             (re-search-forward ":ID:[ \t]*cal-task-1")
                             (md5 (buffer-substring-no-properties
                                   (org-entry-beginning-position)
                                   (org-entry-end-position)))))))
        (sleep-for 0.05)
        (let ((org-caldav-event-list (list (list "cal-task-1" unsched-md5 "etag-3" 1 'synced))))
          (org-caldav-save-sync-state)))

      (setq propfind-calls 0
            check-conn-calls 0
            generate-ics-calls 0
            update-in-org-calls 0
            mock-remote-etags '(("cal-task-1" . "etag-3")))

      (let ((org-auto-scheduler-sync-caldav t)
            (org-auto-scheduler-background-enabled t)
            (org-auto-scheduler-allowed-hostnames nil)
            (org-auto-scheduler-lease-file (expand-file-name "lease.el" temp-dir))
            (org-auto-scheduler--last-background-run-date "2026-10-07"))
        ;; First daemon run: Phase 1 detects unscheduled task -> Phase 2 commits -> 1 pre-pull + 1 push (not 3 syncs!)
        (org-auto-scheduler--execute-background-job)
        (assert-equal propfind-calls 1
                      "Test 29.5a: Two-phase daemon run with changes performs only 1 PROPFIND across Phase 1 & Phase 2")
        (assert-equal generate-ics-calls 1
                      "Test 29.5b: Two-phase daemon run with changes performs only 1 ox-icalendar export")

        ;; Save updated sync state so local file mtime <= state-file mtime for second daemon run
        (let ((sched-md5 (with-current-buffer (find-file-noselect test-org)
                           (save-excursion
                             (goto-char (point-min))
                             (re-search-forward ":ID:[ \t]*cal-task-1")
                             (md5 (buffer-substring-no-properties
                                   (org-entry-beginning-position)
                                   (org-entry-end-position)))))))
          (sleep-for 0.05)
          (let ((org-caldav-event-list (list (list "cal-task-1" sched-md5 "etag-3" 1 'synced))))
            (org-caldav-save-sync-state)))

        ;; Second daemon run: no changes needed -> 1 PROPFIND in pre-pull, 0 ox-icalendar exports!
        (setq propfind-calls 0
              generate-ics-calls 0)
        (org-auto-scheduler--execute-background-job)
        (assert-equal propfind-calls 1
                      "Test 29.5c: No-op background daemon run performs 1 PROPFIND pre-check")
        (assert-equal generate-ics-calls 0
                      "Test 29.5d: No-op background daemon run performs 0 ox-icalendar exports"))

      ;; 28.6: Push-only on a fresh session (e.g. review-apply) calls 0-arg org-caldav-check-connection cleanly
      (setq check-conn-calls 0
            propfind-calls 0
            generate-ics-calls 0)
      (let ((org-auto-scheduler-sync-caldav t)
            (org-auto-scheduler--preview-mode nil))
        (org-auto-scheduler--call-with-caldav-session
         (lambda ()
           (let ((org-auto-scheduler--caldav-pull-done t))
             (org-auto-scheduler--caldav-push t)))))
      (assert-equal check-conn-calls 1
                    "Test 29.6a: Fresh push-only session calls 0-arg org-caldav-check-connection without arg error")
      (assert-equal generate-ics-calls 1
                    "Test 29.6b: Fresh push-only session exports ICS once"))

    (when (get-file-buffer test-org) (kill-buffer (get-file-buffer test-org)))
    (delete-directory temp-dir t)))

;; ----------------------------------------------------------------------------
;; 28.7: Review-fix regressions (empty-calendar cache, daemon push safety, pull result)
;; ----------------------------------------------------------------------------
(when (featurep 'org-caldav)
  ;; 28.7a/b: an empty remote calendar must never be cached as 'empty'
  (let ((calls 0))
    (cl-letf (((symbol-function 'org-caldav-events-url) (lambda () "http://x/cal/")))
      (org-auto-scheduler--call-with-caldav-session
       (lambda ()
         (let ((orig (lambda (&rest _)
                       (setq calls (1+ calls))
                       (setq org-caldav-empty-calendar t)
                       t)))
           (org-auto-scheduler--org-caldav-check-connection-advice orig)
           (setq org-caldav-empty-calendar nil)
           (org-auto-scheduler--org-caldav-check-connection-advice orig)))))
    (setq org-caldav-empty-calendar nil)
    (assert-equal calls 2 "Test 29.7a: Empty-calendar connection check is not cached across a PUT"))

  ;; 28.7c/d: background push skips (no save, no sync) with a dirty agenda buffer
  ;; when background auto-save is disabled; foreground push still saves + syncs.
  (let* ((temp-dir (make-temp-file "autosch-push-safety-" t))
         (f (expand-file-name "a.org" temp-dir))
         (sync-calls 0) (save-calls 0))
    (with-temp-file f (insert "* TODO x\n"))
    (let ((buf (find-file-noselect f))
          (org-agenda-files (list f)))
      (with-current-buffer buf (insert "dirty "))
      (cl-letf (((symbol-function 'org-caldav-sync) (lambda () (setq sync-calls (1+ sync-calls))))
                ((symbol-function 'save-some-buffers) (lambda (&rest _) (setq save-calls (1+ save-calls)))))
        (let ((org-auto-scheduler-sync-caldav t)
              (org-auto-scheduler--preview-mode nil)
              (org-auto-scheduler-background-save-buffers nil)
              (org-auto-scheduler--current-run-type 'background-sync))
          (org-auto-scheduler--call-with-caldav-session
           (lambda () (org-auto-scheduler--caldav-push t))))
        (assert-equal (list sync-calls save-calls) '(0 0)
                      "Test 29.7c: Background push skipped with dirty buffer and auto-save disabled")
        (let ((org-auto-scheduler-sync-caldav t)
              (org-auto-scheduler--preview-mode nil)
              (org-auto-scheduler--current-run-type 'manual))
          (org-auto-scheduler--call-with-caldav-session
           (lambda () (org-auto-scheduler--caldav-push t))))
        (assert-equal (list sync-calls save-calls) '(1 1)
                      "Test 29.7d: Manual push still saves buffers and syncs"))
      (with-current-buffer buf (set-buffer-modified-p nil))
      (kill-buffer buf))
    (delete-directory temp-dir t))

  ;; 28.7e/f: pull returns non-nil only when remote changes were applied
  (cl-letf (((symbol-function 'org-caldav-sync) (lambda () nil)))
    (let ((org-auto-scheduler-sync-caldav t)
          (org-auto-scheduler--preview-mode nil)
          (org-caldav-event-list nil))
      (org-auto-scheduler--call-with-caldav-session
       (lambda ()
         (assert-equal (org-auto-scheduler--caldav-pull) nil
                       "Test 29.7e: Pull with no remote changes returns nil")))
      (org-auto-scheduler--call-with-caldav-session
       (lambda ()
         (cl-letf (((symbol-function 'org-caldav-sync)
                    (lambda () (setq org-auto-scheduler--caldav-pull-changed t))))
           (assert-true (org-auto-scheduler--caldav-pull)
                        "Test 29.7f: Pull that applied changes returns non-nil")))))))

;; 28.8: needs-push-p: stale event-list ignored; failure cooldown throttles background retries
(when (featurep 'org-caldav)
  (cl-letf (((symbol-function 'org-auto-scheduler--caldav-calendar-has-local-edits-p) (lambda (&rest _) nil)))
    (let ((org-caldav-event-list '(("stale" nil nil nil nil)))
          (org-caldav-calendars nil)
          (org-auto-scheduler--caldav-session-dirty nil)
          (org-auto-scheduler--caldav-last-push-failure nil)
          (org-auto-scheduler--current-run-type 'background-sync))
      (assert-equal (org-auto-scheduler--caldav-needs-push-p) nil
                    "Test 29.8a: Leftover org-caldav-event-list alone does not trigger a push")
      (setq org-auto-scheduler--caldav-session-dirty t)
      (assert-true (org-auto-scheduler--caldav-needs-push-p)
                   "Test 29.8b: Dirty session needs push")
      (setq org-auto-scheduler--caldav-last-push-failure (current-time))
      (assert-equal (org-auto-scheduler--caldav-needs-push-p) nil
                    "Test 29.8c: Background run is throttled right after a failed push")
      (assert-true (org-auto-scheduler--caldav-needs-push-p t)
                   "Test 29.8d: Forced push bypasses the cooldown")
      (let ((org-auto-scheduler--current-run-type 'manual))
        (assert-true (org-auto-scheduler--caldav-needs-push-p)
                     "Test 29.8e: Manual run is not throttled by the cooldown"))
      (setq org-auto-scheduler--caldav-last-push-failure
            (time-subtract (current-time) (seconds-to-time 1000)))
      (assert-true (org-auto-scheduler--caldav-needs-push-p)
                   "Test 29.8f: Cooldown expires")))
  ;; 28.8g: nil calendar id does not signal in local-edits check
  (let ((org-caldav-calendar-id nil)
        (org-caldav-files nil))
    (cl-letf (((symbol-function 'org-caldav-sync-do-org->cal) (lambda () t))
              ((symbol-function 'org-caldav-get-org-files-for-sync) (lambda () nil)))
      (assert-equal (condition-case nil
                        (org-auto-scheduler--caldav-calendar-has-local-edits-p nil)
                      (error 'signaled))
                    nil
                    "Test 29.8g: Local-edits check tolerates a nil calendar id"))))
