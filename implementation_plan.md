# Enhancing Adherence Report

This document outlines the approach for updating the Org Auto Scheduler score report to show specific unplanned tasks, allow jumping to tasks via TAB, and introduce a new visual timeline comparison.

## Approach: Compact Timeline UI

Based on feedback, we will implement a horizontally compact visual timeline. Instead of a single wide line spanning the entire day (which can easily wrap and break rendering in smaller Emacs windows), we will chunk the day into 4-hour or 6-hour visual blocks, stacked vertically.

**Compact Chunked Gantt UI**
```text
Day Timeline 
08:00       09:00       10:00       11:00       12:00
|-----------|-----------|-----------|-----------|
[======= Task A =======] [Task C] [===== Task B ...  <-- Planned
   [== Task A ==]        [Email]  [======= Task B ... <-- Actual

12:00       13:00       14:00       15:00       16:00
|-----------|-----------|-----------|-----------|
... Task B =====]        [========= Task D =========] <-- Planned
... Task B =======]      [=== Task D ===]             <-- Actual
```

*Pros:* 
- Retains the highly visual Gantt chart style where overlaps/gaps are immediately obvious.
- Stays strictly within standard 80-100 column limits by breaking the day into vertical chunks.
- Characters represent consistent units of time (e.g., 1 character = 5 minutes).
- **Handling Overlaps:** If a task spans across the end of one chunk (e.g. 12:00 edge), it will be visually truncated with an ellipsis or continuation arrows (`...`) at the edge, and seamlessly resume as the first block on the subsequent line.

---

## Proposed Changes

### [org-auto-scheduler.el](file:///home/saisan/.vim/emacs_plugin/org-auto-scheduler/org-auto-scheduler.el)

#### 1. Detailed Unplanned Tasks
- **Modify `org-auto-scheduler-score-schedule`**: Instead of simply counting `unplanned-tasks` via `cl-incf`, it will build a list of task properties `(heading id effort clocked category)`. 
- **Modify `org-auto-scheduler-adherence-report`**: Update the "Warnings" section to iterate through the unplanned tasks list and print them out by name and tracked time, similarly to how "Missed Tasks" are printed.

#### 2. Jump to Task (TAB Key)
- **Implement a custom Keymap**: Create `org-auto-scheduler-report-mode` (derived from `special-mode`) for the report buffer.
- **Bind `TAB` (and `RET`)**: Create a function `org-auto-scheduler-report-jump-to-task` bound to `TAB` and `RET`.
- **Add Text Properties**: When rendering task names in the report (Missed, Unplanned, Rescheduled), apply an `org-marker` or `org-id` text property to the string. The jump function will read this property at `point` and jump to the task in the Org agenda files window.

#### 3. Visual Timeline
- Create a function `org-auto-scheduler-get-clock-intervals` that scans the day's tasks (both from snapshot and agenda) to extract raw `CLOCK: [start]--[end]` lines that match the target score date.
- Add a rendering function based on the UI choice (Vertical or Gantt) that loops through the daily time bounds (e.g., `START_TIME` to `END_TIME`) and plots the intersecting visual data.
- Append this new UI section to the bottom of the `org-auto-scheduler-adherence-report` buffer.

## Verification Plan

- **Manual Verification:** Open [org-auto-scheduler.el](file:///home/saisan/.vim/emacs_plugin/org-auto-scheduler/org-auto-scheduler.el), load it via `eval-buffer`. 
- Generate dummy tasks with `SCHEDULED` and `CLOCK` entries.
- Run `M-x org-auto-scheduler-snapshot-schedule`.
- Run `M-x org-auto-scheduler-score-schedule`, verify that unplanned tasks are listed by name.
- Press `TAB` on a missed/unplanned task and ensure it opens the correct task in the Org file.
- Check the visual accuracy of the Timeline UI based on the dummy clock logs vs scheduled times.
