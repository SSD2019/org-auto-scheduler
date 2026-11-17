;;; 27-clocked-only-mode-grace-period-blocker-eviction.el --- Clocked-Only Mode, Grace Period, BLOCKER Eviction, Re-Ranking & Clock Markers -*- lexical-binding: t -*-

;; Loaded by test/oas-suites-test.el; uses helpers from test/test-helper.el.

;; ============================================================================
;; TEST 27: Background Preserve-Today-Mode ('clocked-only vs 'all), Grace Period,
;;          Stale BLOCKER Eviction, Score-Change Re-Ranking, & Clock Markers (-ci-/-co-)
;; ============================================================================
(message "\n--- TEST 27: Clocked-Only Mode, Grace Period, BLOCKER Eviction, Re-Ranking & Clock Markers ---")

;; 27.1: 'clocked-only vs 'all, grace period ('start-or-end, 'start, 'end), short task < grace,
;;       0-change idempotency (no drift), and clocked/pinned protection
(let* ((temp-dir (make-temp-file "org-clocked-only-test-" t))
       (test-org (expand-file-name "test-clocked-only.org" temp-dir))
       (today-str "2026-10-07")
       (today-dow "Wed")
       (org-auto-scheduler-silent-mode t)
       (org-auto-scheduler-sync-caldav nil)
       (org-auto-scheduler-preserve-today-scheduled t)
       (org-auto-scheduler-background-preserve-today-mode 'clocked-only)
       (org-auto-scheduler-background-lapse-grace-minutes 30)
       (org-auto-scheduler-background-lapse-reference 'start-or-end)
       (org-auto-scheduler-start-time "09:00")
       (org-auto-scheduler-end-time "18:00")
       (org-auto-scheduler-start-buffer-minutes 5)
       (org-auto-scheduler-task-gap 0)
       (org-auto-scheduler--current-run-type 'background-sync)
       (org-auto-scheduler--saved-review-decisions nil)
       (org-auto-scheduler--last-task-fingerprints nil)
       (org-auto-scheduler--backfilled-task-slots (make-hash-table :test 'equal)))

  ;; 27.1a: Within grace period (60m task at 09:00-10:00, now is 09:20 < min(09:30, 10:00)):
  ;; Schedule is valid and in score order -> NO replanning, slots remain untouched!
  (with-temp-file test-org
    (insert "* Tasks :PROJECT:\n:PROPERTIES:\n:PARALLEL: t\n:END:\n\
** TODO [#A] High Pri Morning Task :AUTOSCH:\n\
SCHEDULED: <2026-10-07 Wed 09:00-10:00>\n\
:PROPERTIES:\n\
:Effort: 1:00\n\
:ID: co-high-a\n\
:END:\n\
** TODO [#C] Low Pri Afternoon Task :AUTOSCH:\n\
SCHEDULED: <2026-10-07 Wed 10:00-11:00>\n\
:PROPERTIES:\n\
:Effort: 1:00\n\
:ID: co-low-c\n\
:END:\n\
** TODO [#B] Pinned Task :AUTOSCH:\n\
SCHEDULED: <2026-10-07 Wed 14:00-15:00>\n\
:PROPERTIES:\n\
:Effort: 1:00\n\
:PINNED: t\n\
:PINNED_TIME: 2026-10-07 14:00\n\
:ID: co-pinned\n\
:END:\n"))
  (setq org-agenda-files (list test-org))

  ;; First run at 09:00 establishes the baseline fingerprint with 0 changes
  (let ((now-0900 (encode-time 0 0 9 7 10 2026)))
    (cl-letf (((symbol-function 'current-time) (lambda () now-0900)))
      (org-auto-scheduler-schedule-tasks)))

  ;; Second run at 09:20 (within 30m grace period of 09:00-10:00 task): must NOT drift!
  (let ((now-0920 (encode-time 0 20 9 7 10 2026)))
    (cl-letf (((symbol-function 'current-time) (lambda () now-0920)))
      (org-auto-scheduler-schedule-tasks)))

  (with-current-buffer (find-file-noselect test-org)
    (goto-char (point-min))
    (re-search-forward ":ID:[ \t]*co-high-a")
    (assert-equal (org-entry-get nil "SCHEDULED") "<2026-10-07 Wed 09:00-10:00>"
                  "Test 27.1a: Unclocked task within 30m grace period does NOT drift (stays at 09:00-10:00)")
    (goto-char (point-min))
    (re-search-forward ":ID:[ \t]*co-low-c")
    (assert-equal (org-entry-get nil "SCHEDULED") "<2026-10-07 Wed 10:00-11:00>"
                  "Test 27.1b: Upcoming task stays at 10:00-11:00 when nothing lapsed"))

  ;; 27.1c: Past grace period (now is 09:35 > min(09:30, 10:00)):
  ;; Check 2 triggers! [#A] lapsed task is re-placed at 09:40-10:40 (now + 5m),
  ;; pushing [#C] task to 10:40-11:40, while Pinned task stays at 14:00-15:00!
  (let ((now-0935 (encode-time 0 35 9 7 10 2026)))
    (cl-letf (((symbol-function 'current-time) (lambda () now-0935)))
      (org-auto-scheduler-schedule-tasks)))

  (with-current-buffer (find-file-noselect test-org)
    (goto-char (point-min))
    (re-search-forward ":ID:[ \t]*co-high-a")
    (assert-equal (org-entry-get nil "SCHEDULED") "<2026-10-07 Wed 09:40-10:40>"
                  "Test 27.1c: Lapsed [#A] task (> 30m grace) re-placed from now+5m (09:40-10:40) in rank order")
    (goto-char (point-min))
    (re-search-forward ":ID:[ \t]*co-low-c")
    (assert-equal (org-entry-get nil "SCHEDULED") "<2026-10-07 Wed 10:40-11:40>"
                  "Test 27.1d: Lower-ranked [#C] task shifted after re-placed [#A] task (10:40-11:40)")
    (goto-char (point-min))
    (re-search-forward ":ID:[ \t]*co-pinned")
    (assert-equal (org-entry-get nil "SCHEDULED") "<2026-10-07 Wed 14:00-15:00>"
                  "Test 27.1e: Pinned task remains strictly anchored at 14:00-15:00"))

  ;; 27.1f: Short task (< grace period) under 'start-or-end lapses as soon as its slot ends!
  ;; Suppose a 15-minute task is scheduled 11:00-11:15. Under 'start-or-end, min(11:30, 11:15) = 11:15.
  ;; At 11:10 it is NOT lapsed; at 11:16 it IS lapsed!
  (let ((s-1100 (encode-time 0 0 11 7 10 2026))
        (e-1115 (encode-time 0 15 11 7 10 2026))
        (now-1110 (encode-time 0 10 11 7 10 2026))
        (now-1116 (encode-time 0 16 11 7 10 2026)))
    (assert-true (null (org-auto-scheduler--task-lapsed-p s-1100 e-1115 now-1110))
                 "Test 27.1f1: 15m task (11:00-11:15) is NOT lapsed at 11:10 under 'start-or-end")
    (assert-true (org-auto-scheduler--task-lapsed-p s-1100 e-1115 now-1116)
                 "Test 27.1f2: 15m task (11:00-11:15) IS lapsed at 11:16 (past slot end) under 'start-or-end"))

  (when (get-file-buffer test-org) (kill-buffer (get-file-buffer test-org)))
  (delete-directory temp-dir t))

;; 27.2: Stale BLOCKER Inversion & Preserved-Overlap Eviction (Across ALL Modes)
(let* ((temp-dir (make-temp-file "org-blocker-evict-test-" t))
       (test-org (expand-file-name "test-blocker-evict.org" temp-dir))
       (fake-now (encode-time 0 0 9 7 10 2026))
       (org-auto-scheduler-silent-mode t)
       (org-auto-scheduler-sync-caldav nil)
       (org-auto-scheduler-preserve-today-scheduled t)
       (org-auto-scheduler-background-preserve-today-mode 'all) ;; Even in default 'all mode!
       (org-auto-scheduler-start-time "09:00")
       (org-auto-scheduler-end-time "18:00")
       (org-auto-scheduler-start-buffer-minutes 0)
       (org-auto-scheduler-task-gap 0)
       (org-auto-scheduler--current-run-type 'background-sync)
       (org-auto-scheduler--saved-review-decisions nil))
  ;; Stale schedule where [#B] Dependent (09:00-10:00) is scheduled BEFORE its [#A] Blocker (11:00-12:00),
  ;; and Transitive Child C (10:00-10:30) depends on B!
  (with-temp-file test-org
    (insert "* Tasks :PROJECT:\n:PROPERTIES:\n:PARALLEL: t\n:END:\n\
** TODO [#B] Stale Dependent B :AUTOSCH:\n\
SCHEDULED: <2026-10-07 Wed 09:00-10:00>\n\
:PROPERTIES:\n\
:Effort: 1:00\n\
:ID: stale-dep-b\n\
:BLOCKER: blocker-a\n\
:END:\n\
** TODO [#C] Transitive Dependent C :AUTOSCH:\n\
SCHEDULED: <2026-10-07 Wed 10:00-10:30>\n\
:PROPERTIES:\n\
:Effort: 0:30\n\
:ID: stale-dep-c\n\
:BLOCKER: stale-dep-b\n\
:END:\n\
** TODO [#A] Blocker A :AUTOSCH:\n\
SCHEDULED: <2026-10-07 Wed 11:00-12:00>\n\
:PROPERTIES:\n\
:Effort: 1:00\n\
:ID: blocker-a\n\
:END:\n"))
  (setq org-agenda-files (list test-org))

  (cl-letf (((symbol-function 'current-time) (lambda () fake-now)))
    (org-auto-scheduler-schedule-tasks))

  (with-current-buffer (find-file-noselect test-org)
    (goto-char (point-min))
    (re-search-forward ":ID:[ \t]*blocker-a")
    (let ((s-a (org-entry-get nil "SCHEDULED")))
      (goto-char (point-min))
      (re-search-forward ":ID:[ \t]*stale-dep-b")
      (let ((s-b (org-entry-get nil "SCHEDULED")))
        (goto-char (point-min))
        (re-search-forward ":ID:[ \t]*stale-dep-c")
        (let ((s-c (org-entry-get nil "SCHEDULED")))
          (assert-equal s-a "<2026-10-07 Wed 11:00-12:00>"
                        (format "Test 27.2a: Valid Blocker A stays preserved at 11:00-12:00 (actual: %s)" s-a))
          (assert-equal s-b "<2026-10-07 Wed 12:00-13:00>"
                        (format "Test 27.2b: Stale Dependent B evicted from preserved and moved after Blocker A (12:00-13:00) (actual: %s)" s-b))
          (assert-equal s-c "<2026-10-07 Wed 13:00-13:30>"
                        (format "Test 27.2c: Transitive Dependent C also evicted in fixed-point loop and placed after B (13:00-13:30) (actual: %s)" s-c))))))

  (when (get-file-buffer test-org) (kill-buffer (get-file-buffer test-org)))
  (delete-directory temp-dir t))

;; 27.3: Saved Review Order Invalidation on Score Change & [RE-RANKED] Badge
(let* ((temp-dir (make-temp-file "org-rerank-test-" t))
       (test-org (expand-file-name "test-rerank.org" temp-dir))
       (fake-now (encode-time 0 0 9 7 10 2026))
       (org-auto-scheduler-silent-mode t)
       (org-auto-scheduler-sync-caldav nil)
       (org-auto-scheduler-review-state-file (expand-file-name "review-state.el" temp-dir))
       (org-auto-scheduler-review-persistence-backend 'state-file)
       (org-auto-scheduler-review-order-on-score-change 'reset-task)
       (org-auto-scheduler--saved-review-decisions nil)
       (org-auto-scheduler--reranked-tasks nil))
  (with-temp-file test-org
    (insert "* Project :PROJECT:\n:PROPERTIES:\n:PARALLEL: t\n:END:\n\
** TODO [#B] Task Mid :AUTOSCH:\n\
:PROPERTIES:\n\
:Effort: 1:00\n\
:ID: rr-mid\n\
:END:\n\
** TODO [#C] Task Low :AUTOSCH:\n\
:PROPERTIES:\n\
:Effort: 1:00\n\
:ID: rr-low\n\
:END:\n"))
  (setq org-agenda-files (list test-org))

  (cl-letf (((symbol-function 'current-time) (lambda () fake-now)))
    ;; 1. Open review buffer and save initial decisions (rr-mid is order 1, rr-low is order 2)
    (org-auto-scheduler-review-and-apply)
    (org-auto-scheduler-review-save-decisions)
    (when (get-buffer "*Org Auto Scheduler Review*")
      (kill-buffer "*Org Auto Scheduler Review*"))

    ;; 2. Now upgrade rr-low to [#A] in the Org buffer so its score jumps above rr-mid!
    (with-current-buffer (find-file-noselect test-org)
      (goto-char (point-min))
      (re-search-forward ":ID:[ \t]*rr-low")
      (org-back-to-heading t)
      (org-priority ?A)
      (save-buffer))

    ;; 3. Re-open review buffer: rr-low's saved :order should be invalidated & re-ranked to #1,
    ;;    and the review buffer should show the [RE-RANKED] badge!
    (org-auto-scheduler-review-and-apply)
    (assert-true (cl-find "rr-low" org-auto-scheduler--reranked-tasks
                          :key (lambda (r) (plist-get r :task-id))
                          :test #'equal)
                 "Test 27.3a: Upgraded task rr-low recorded in org-auto-scheduler--reranked-tasks")
    (with-current-buffer "*Org Auto Scheduler Review*"
      (let ((content (buffer-string))
            (pos-low nil)
            (pos-mid nil))
        (assert-true (string-match-p "\\[RE-RANKED\\]" content)
                     "Test 27.3b: Review buffer displays [RE-RANKED] badge on score-changed task")
        (setq pos-low (string-match "Task Low" content))
        (setq pos-mid (string-match "Task Mid" content))
        (assert-true (and pos-low pos-mid (< pos-low pos-mid))
                     "Test 27.3c: Upgraded [#A] Task Low re-ranked above [#B] Task Mid"))))

  (when (get-buffer "*Org Auto Scheduler Review*")
    (kill-buffer "*Org Auto Scheduler Review*"))
  (when (get-file-buffer test-org) (kill-buffer (get-file-buffer test-org)))
  (delete-directory temp-dir t))

;; 27.4: Mobile/Calendar Clock-In & Clock-Out Title Markers (-ci- / -co- with 24h & am/pm)
(let* ((temp-dir (make-temp-file "org-clock-marker-test-" t))
       (test-org (expand-file-name "test-clock-marker.org" temp-dir))
       (fake-now (encode-time 0 0 11 7 10 2026))
       (org-auto-scheduler-silent-mode t)
       (org-auto-scheduler-sync-caldav nil)
       (org-auto-scheduler-start-time "09:00")
       (org-auto-scheduler-end-time "18:00")
       (org-auto-scheduler-start-buffer-minutes 0)
       (org-auto-scheduler-task-gap 0))

  ;; Test time parser on 24h and 12h am/pm formats
  (let ((t1 (org-auto-scheduler--parse-clock-marker-time "10:15am" fake-now))
        (t2 (org-auto-scheduler--parse-clock-marker-time "10:15pm" fake-now))
        (t3 (org-auto-scheduler--parse-clock-marker-time "2:30pm" fake-now))
        (t4 (org-auto-scheduler--parse-clock-marker-time "9am" fake-now))
        (t5 (org-auto-scheduler--parse-clock-marker-time "14:45" fake-now)))
    (assert-equal (format-time-string "%H:%M" t1) "10:15" "Test 27.4a1: Parsed 10:15am to 10:15")
    (assert-equal (format-time-string "%H:%M" t2) "22:15" "Test 27.4a2: Parsed 10:15pm to 22:15")
    (assert-equal (format-time-string "%H:%M" t3) "14:30" "Test 27.4b1: Parsed 2:30pm to 14:30")
    (assert-equal (format-time-string "%H:%M" t4) "09:00" "Test 27.4b2: Parsed 9am to 09:00")
    (assert-equal (format-time-string "%H:%M" t5) "14:45" "Test 27.4c1: Parsed 14:45 to 14:45"))

  ;; Test end-to-end execution of combined (-ci9:30am-co10:30am-) on a 2-hour task:
  ;; Should strip the marker, insert a 1:00 CLOCK entry in :LOGBOOK:, and schedule remaining 1:00 effort!
  (with-temp-file test-org
    (insert "* Tasks :PROJECT:\n\
** TODO (-ci9:30am-co10:30am-) Mobile Logged Task :AUTOSCH:\n\
SCHEDULED: <2026-10-07 Wed 09:30-11:30>\n\
:PROPERTIES:\n\
:Effort: 2:00\n\
:ID: mob-clock-1\n\
:END:\n"))
  (setq org-agenda-files (list test-org))

  (cl-letf (((symbol-function 'current-time) (lambda () fake-now)))
    (org-auto-scheduler-schedule-tasks))

  (with-current-buffer (find-file-noselect test-org)
    (goto-char (point-min))
    (re-search-forward ":ID:[ \t]*mob-clock-1")
    (org-back-to-heading t)
    (let ((heading (org-get-heading t t t t))
          (sched (org-entry-get nil "SCHEDULED"))
          (clocked-mins (org-auto-scheduler-get-clocked-time (point-marker))))
      (assert-equal heading "Mobile Logged Task"
                    (format "Test 27.4d: Marker stripped cleanly from heading (actual: %s)" heading))
      (assert-equal clocked-mins 60
                    (format "Test 27.4e: Closed 60-minute CLOCK interval recorded in LOGBOOK (actual: %d)" clocked-mins))
      (assert-equal sched "<2026-10-07 Wed 11:00-12:00>"
                    (format "Test 27.4f: Remaining 60m effort scheduled at 11:00-12:00 (actual: %s)" sched))))

  (when (get-file-buffer test-org) (kill-buffer (get-file-buffer test-org)))
  (delete-directory temp-dir t))

;; 27.5: Variable Aliases Verification
(assert-equal (indirect-variable 'org-auto-scheduler-preserve-today-mode)
              'org-auto-scheduler-background-preserve-today-mode
              "Test 27.5a: org-auto-scheduler-preserve-today-mode aliases org-auto-scheduler-background-preserve-today-mode")
(assert-equal (indirect-variable 'org-auto-scheduler-background-reschedule-past-tasks)
              'org-auto-scheduler-background-reschedule-yesterday-tasks-once
              "Test 27.5b: org-auto-scheduler-background-reschedule-past-tasks aliases org-auto-scheduler-background-reschedule-yesterday-tasks-once")
(assert-equal (indirect-variable 'org-auto-scheduler-lapse-grace-minutes)
              'org-auto-scheduler-background-lapse-grace-minutes
              "Test 27.5c: org-auto-scheduler-lapse-grace-minutes aliases org-auto-scheduler-background-lapse-grace-minutes")
(assert-equal (indirect-variable 'org-auto-scheduler-lapse-reference)
              'org-auto-scheduler-background-lapse-reference
              "Test 27.5d: org-auto-scheduler-lapse-reference aliases org-auto-scheduler-background-lapse-reference")
