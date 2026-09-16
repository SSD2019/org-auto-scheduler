// Org Auto Scheduler Mobile Application Logic

const state = {
  activeView: 'agenda',
  currentDate: new Date(),
  agendaData: null,
  reviewData: null,
  activeTask: null,
  todoKeywords: ['TODO', 'NEXT', 'IN-PROGRESS', 'DONE'],
  isReviewRunning: false,
  clockTimer: null
};

// --- Haptic Feedback ---
function haptic(ms = 15) {
  if (navigator.vibrate) {
    try { navigator.vibrate(ms); } catch (e) {}
  }
}

// --- Toast System ---
function showToast(message, icon = 'ℹ️') {
  let container = document.getElementById('toast-container');
  if (!container) {
    container = document.createElement('div');
    container.id = 'toast-container';
    container.className = 'toast-container';
    document.body.appendChild(container);
  }
  const toast = document.createElement('div');
  toast.className = 'toast';
  toast.innerHTML = `<span>${icon}</span><span>${message}</span>`;
  container.appendChild(toast);
  setTimeout(() => {
    toast.style.opacity = '0';
    toast.style.transform = 'translateY(-10px)';
    toast.style.transition = '0.2s ease';
    setTimeout(() => toast.remove(), 200);
  }, 2800);
}

// --- Date Helpers ---
function formatDateYYYYMMDD(d) {
  const year = d.getFullYear();
  const month = String(d.getMonth() + 1).padStart(2, '0');
  const day = String(d.getDate()).padStart(2, '0');
  return `${year}-${month}-${day}`;
}

function formatDateLabel(d) {
  const todayStr = formatDateYYYYMMDD(new Date());
  const dStr = formatDateYYYYMMDD(d);
  if (dStr === todayStr) return 'Today, ' + d.toLocaleDateString(undefined, { month: 'short', day: 'numeric' });
  return d.toLocaleDateString(undefined, { weekday: 'short', month: 'short', day: 'numeric' });
}

// --- App Initialization ---
document.addEventListener('DOMContentLoaded', async () => {
  setupNavigation();
  setupEventListeners();
  initConnectionStatus();

  // Register Service Worker for PWA
  if ('serviceWorker' in navigator && window.location.protocol.startsWith('http')) {
    navigator.serviceWorker.register('./sw.js').catch((err) => {
      console.warn('Service Worker registration failed:', err);
    });
  }

  // Initial connection check & load
  await checkServerStatus();
  loadCurrentView();
});

// --- Connection Status Management ---
function initConnectionStatus() {
  const statusPill = document.getElementById('connection-pill');
  const statusDot = document.getElementById('status-dot');
  const statusText = document.getElementById('status-text');

  window.api.onStatusChange((status, data) => {
    if (status === 'online') {
      statusDot.className = 'status-dot online';
      statusText.textContent = data.latency ? `${data.latency}ms` : 'Online';
    } else {
      statusDot.className = 'status-dot offline';
      statusText.textContent = 'Offline';
    }
  });

  statusPill.addEventListener('click', () => {
    haptic();
    openSettingsModal();
  });
}

async function checkServerStatus() {
  try {
    const res = await window.api.getStatus();
    if (res.status === 'ok') {
      if (res.todo_keywords && res.todo_keywords.length > 0) {
        state.todoKeywords = res.todo_keywords;
      }
      return true;
    }
  } catch (err) {
    console.warn('Initial server connection failed:', err);
  }
  return false;
}

// --- Navigation Tabs ---
function setupNavigation() {
  const navItems = document.querySelectorAll('.nav-item');
  navItems.forEach((item) => {
    item.addEventListener('click', () => {
      const view = item.dataset.view;
      if (view && view !== state.activeView) {
        haptic();
        switchView(view);
      }
    });
  });
}

function switchView(viewName) {
  state.activeView = viewName;
  document.querySelectorAll('.nav-item').forEach((it) => {
    it.classList.toggle('active', it.dataset.view === viewName);
  });
  document.querySelectorAll('.view').forEach((vw) => {
    vw.classList.toggle('active', vw.id === `view-${viewName}`);
  });
  loadCurrentView();
}

function loadCurrentView() {
  switch (state.activeView) {
    case 'agenda':
      loadAgenda();
      break;
    case 'review':
      loadReview();
      break;
    case 'tasks':
      loadBacklog();
      break;
    case 'adherence':
      loadAdherence();
      break;
  }
}

// --- Agenda View ---
async function loadAgenda() {
  const dateStr = formatDateYYYYMMDD(state.currentDate);
  const dateLabel = document.getElementById('current-date-label');
  if (dateLabel) {
    dateLabel.textContent = formatDateLabel(state.currentDate);
  }

  const container = document.getElementById('agenda-cards-container');
  container.innerHTML = '<div style="text-align:center; padding: 40px; color: var(--text-muted);">Loading agenda from Emacs...</div>';

  try {
    const data = await window.api.getAgenda(dateStr, 1);
    state.agendaData = data;
    renderAgenda(data);
  } catch (err) {
    container.innerHTML = `
      <div style="text-align:center; padding: 40px 20px;">
        <div style="font-size: 2rem; margin-bottom: 10px;">⚠️</div>
        <div style="font-weight: 700; margin-bottom: 6px;">Unable to reach Emacs Server</div>
        <div style="color: var(--text-muted); font-size: 0.85rem; margin-bottom: 16px;">${err.message}</div>
        <button class="btn btn-secondary" onclick="loadAgenda()" style="display:inline-flex; width:auto; padding: 8px 16px;">Retry</button>
      </div>`;
  }
}

function renderAgenda(data) {
  const container = document.getElementById('agenda-cards-container');
  container.innerHTML = '';

  if (!data || !data.days || data.days.length === 0) {
    container.innerHTML = '<div style="text-align:center; padding: 40px; color: var(--text-muted);">No scheduled items for this date.</div>';
    return;
  }

  const day = data.days[0];
  const allItems = [...(day.tasks || []), ...(day.events || [])];

  if (allItems.length === 0) {
    container.innerHTML = `
      <div style="text-align:center; padding: 40px 20px; color: var(--text-muted);">
        <div style="font-size: 2rem; margin-bottom: 8px;">☀️</div>
        <div style="font-weight: 700; color: #fff;">Clear schedule</div>
        <div style="font-size: 0.85rem; margin-top: 4px;">No tasks or calendar events found for ${day.label}.</div>
      </div>`;
    return;
  }

  // Render cards
  const cardsList = document.createElement('div');
  cardsList.className = 'cards-list';

  allItems.forEach((item) => {
    if (item.is_event) {
      // Fixed Calendar Event Card
      const card = document.createElement('div');
      card.className = 'task-card event-card';
      card.innerHTML = `
        <div class="task-card-top">
          <span class="project-indicator">
            <span class="color-dot" style="background-color: var(--color-purple)"></span>
            Fixed Event
          </span>
          <span class="time-badge">${item.start_time || 'All-day'}${item.end_time ? ' – ' + item.end_time : ''}</span>
        </div>
        <div class="task-card-title">${escapeHtml(item.title)}</div>
        <div class="task-card-meta">
          <span class="badge badge-effort">${item.duration}m</span>
          <span class="badge" style="background: rgba(198,120,221,0.2); color: var(--color-purple);">CALENDAR</span>
        </div>
      `;
      cardsList.appendChild(card);
    } else {
      // Schedulable Org Task Card
      const card = document.createElement('div');
      card.className = 'task-card';

      // Dot color fallback
      const dotColor = item.project_color || '#61afef';

      card.innerHTML = `
        <div class="task-card-top">
          <span class="project-indicator">
            <span class="color-dot" style="background-color: ${dotColor}"></span>
            ${escapeHtml(item.project || 'General')}
          </span>
          <span class="time-badge">${item.start_time || '--:--'}${item.end_time ? ' – ' + item.end_time : ''}</span>
        </div>
        <div class="task-card-title">${escapeHtml(item.heading)}</div>
        <div class="task-card-meta">
          ${item.todo ? `<span class="badge badge-${getTodoBadgeClass(item.todo)}">${item.todo}</span>` : ''}
          ${item.priority ? `<span class="badge badge-priority">[#${item.priority}]</span>` : ''}
          ${item.effort ? `<span class="badge badge-effort">⏱️ ${item.effort}</span>` : ''}
          ${(item.tags || []).slice(0, 3).map((t) => `<span class="badge badge-tag">:${t}:</span>`).join('')}
        </div>
        <div class="task-quick-actions">
          <button class="action-mini-btn done-btn" data-action="done" data-id="${item.id}">
            ✓ Done
          </button>
          <button class="action-mini-btn" data-action="bump" data-id="${item.id}">
            ⏩ +30m
          </button>
          <button class="action-mini-btn" data-action="clock" data-id="${item.id}">
            ⏱️ Clock
          </button>
          <button class="action-mini-btn" data-action="edit" data-id="${item.id}">
            ✏️ Edit
          </button>
        </div>
      `;

      // Card tap opens task property editor
      card.addEventListener('click', (e) => {
        if (e.target.closest('.action-mini-btn')) return;
        haptic();
        openTaskEditor(item.id);
      });

      // Quick buttons handler
      card.querySelectorAll('.action-mini-btn').forEach((btn) => {
        btn.addEventListener('click', async (e) => {
          e.stopPropagation();
          haptic();
          const action = btn.dataset.action;
          const taskId = btn.dataset.id;
          await handleTaskQuickAction(action, taskId);
        });
      });

      cardsList.appendChild(card);
    }
  });

  container.appendChild(cardsList);
}

async function handleTaskQuickAction(action, taskId) {
  if (action === 'done') {
    try {
      await window.api.editTask(taskId, { todo: 'DONE' });
      showToast('Marked task DONE', '✅');
      loadAgenda();
    } catch (err) {
      showToast(err.message, '❌');
    }
  } else if (action === 'bump') {
    openBumpModal(taskId);
  } else if (action === 'clock') {
    try {
      const res = await window.api.clockTask(taskId, 'in');
      showToast('Clocked in to task', '⏱️');
    } catch (err) {
      showToast(err.message, '❌');
    }
  } else if (action === 'edit') {
    openTaskEditor(taskId);
  }
}

function getTodoBadgeClass(todo) {
  const t = (todo || '').toUpperCase();
  if (t === 'DONE') return 'done';
  if (t === 'NEXT') return 'next';
  if (t === 'IN-PROGRESS') return 'progress';
  if (t === 'WAITING' || t === 'LATER') return 'waiting';
  return 'todo';
}

// --- Review & Apply View ---
async function loadReview(force = false) {
  const container = document.getElementById('review-entries-container');
  container.innerHTML = '<div style="text-align:center; padding: 40px; color: var(--text-muted);">Generating review preview in Emacs...</div>';

  try {
    const data = await window.api.getReviewState(force);
    state.reviewData = data;
    renderReview(data);
  } catch (err) {
    container.innerHTML = `
      <div style="text-align:center; padding: 40px 20px;">
        <div style="font-size: 2rem; margin-bottom: 10px;">⚠️</div>
        <div style="font-weight: 700; margin-bottom: 6px;">Failed to load Review buffer</div>
        <div style="color: var(--text-muted); font-size: 0.85rem; margin-bottom: 16px;">${err.message}</div>
        <button class="btn btn-primary" onclick="loadReview(true)" style="display:inline-flex; width:auto; padding: 8px 16px;">Generate Review</button>
      </div>`;
  }
}

function renderReview(data) {
  const container = document.getElementById('review-entries-container');
  container.innerHTML = '';

  // Update Summary Stats
  const totalCount = document.getElementById('review-stat-total');
  const checkedCount = document.getElementById('review-stat-checked');
  const warnsCount = document.getElementById('review-stat-warns');

  if (totalCount) totalCount.textContent = data.summary?.total || 0;
  if (checkedCount) checkedCount.textContent = data.summary?.checked || 0;
  if (warnsCount) warnsCount.textContent = data.summary?.warnings || 0;

  const undoBtn = document.getElementById('review-undo-btn');
  if (undoBtn) {
    undoBtn.style.opacity = data.undo_available ? '1' : '0.4';
  }

  const entries = data.entries || [];
  if (entries.length === 0) {
    container.innerHTML = '<div style="text-align:center; padding: 40px; color: var(--text-muted);">No tasks in review buffer. Press Refresh to calculate.</div>';
    return;
  }

  entries.forEach((item) => {
    if (item.type === 'separator') {
      const sepEl = document.createElement('div');
      sepEl.className = 'review-item separator';
      sepEl.innerHTML = `<div class="review-sep-label">${escapeHtml(item.label)}</div>`;
      container.appendChild(sepEl);
    } else if (item.type === 'event') {
      const evEl = document.createElement('div');
      evEl.className = 'review-item';
      evEl.style.borderLeft = '3px solid var(--color-purple)';
      evEl.innerHTML = `
        <div class="review-item-main">
          <div style="color: var(--color-purple); font-size: 0.8rem; margin-top: 2px;">📅</div>
          <div class="review-item-content">
            <div class="review-item-title" style="color: var(--text-muted);">${escapeHtml(item.headline)}</div>
            <div class="review-item-details">
              <span class="time-badge">${escapeHtml(item.time_str)}</span>
              <span class="badge badge-effort">${escapeHtml(item.duration)}</span>
              <span class="badge" style="background: rgba(198,120,221,0.15); color: var(--color-purple);">Fixed Event</span>
            </div>
          </div>
        </div>
      `;
      container.appendChild(evEl);
    } else if (item.type === 'task') {
      const taskEl = document.createElement('div');
      taskEl.className = 'review-item';

      const isWarn = item.warnings && item.warnings.length > 0;
      if (isWarn) {
        taskEl.style.borderColor = 'var(--color-yellow)';
      }

      taskEl.innerHTML = `
        <div class="review-item-main">
          <div class="review-checkbox ${item.checked ? 'checked' : ''}" data-id="${item.id}">
            ${item.checked ? '✓' : ''}
          </div>
          <div class="review-item-content">
            <div class="task-card-top" style="margin-bottom: 2px;">
              <span class="project-indicator">
                <span class="color-dot" style="background-color: ${item.project_color || '#61afef'}"></span>
                ${escapeHtml(item.project || 'General')}
              </span>
              <span class="time-badge">${escapeHtml(item.time_str || '')}</span>
            </div>
            <div class="review-item-title">${escapeHtml(item.headline)}</div>
            <div class="review-item-details">
              <span class="badge badge-effort" data-action="effort" data-id="${item.id}" style="cursor: pointer;">
                ⏱️ ${escapeHtml(item.duration || '')} ✏️
              </span>
              <span class="badge" style="background: var(--bg-surface); color: var(--text-muted);">Score: ${item.score || ''}</span>
              <span class="badge" style="font-size: 0.75rem;">${item.status || ''}</span>
            </div>
            ${isWarn ? `<div style="margin-top: 4px; font-size: 0.72rem; color: var(--color-yellow); font-weight: 600;">
              ${item.warnings.map(w => `<div>⚠️ ${escapeHtml(w)}</div>`).join('')}
            </div>` : ''}
          </div>
          <div class="review-controls">
            <button class="ctrl-btn" data-action="move-up" data-id="${item.id}" title="Move Up">↑</button>
            <button class="ctrl-btn" data-action="move-down" data-id="${item.id}" title="Move Down">↓</button>
            <button class="ctrl-btn" data-action="move-day-forward" data-id="${item.id}" title="Next Day">&gt;</button>
          </div>
        </div>
      `;

      // Checkbox click
      const cb = taskEl.querySelector('.review-checkbox');
      cb.addEventListener('click', async (e) => {
        e.stopPropagation();
        haptic();
        await performReviewAction('toggle', item.id);
      });

      // Controls click
      taskEl.querySelectorAll('.ctrl-btn').forEach((btn) => {
        btn.addEventListener('click', async (e) => {
          e.stopPropagation();
          haptic();
          const act = btn.dataset.action;
          const tid = btn.dataset.id;
          await performReviewAction(act, tid);
        });
      });

      // Duration click -> What-If effort modal
      const effortChip = taskEl.querySelector('[data-action="effort"]');
      if (effortChip) {
        effortChip.addEventListener('click', (e) => {
          e.stopPropagation();
          haptic();
          openWhatIfEffortModal(item.id, item.duration);
        });
      }

      container.appendChild(taskEl);
    }
  });
}

async function performReviewAction(action, taskId = null, arg = null) {
  try {
    const res = await window.api.reviewAction(action, taskId, arg);
    if (res.status === 'applied') {
      showToast(res.message || 'Schedule applied to Org files!', '🚀');
      state.activeView = 'agenda';
      switchView('agenda');
      return;
    }
    state.reviewData = res;
    renderReview(res);
  } catch (err) {
    showToast(err.message, '❌');
  }
}

// --- Apply Review Execution ---
async function applyReviewSchedule() {
  haptic(25);
  if (!state.reviewData) return;

  const warnCount = state.reviewData.summary?.warnings || 0;
  if (warnCount > 0) {
    if (!confirm(`Warning: ${warnCount} task warnings/dependency constraints detected. Apply anyway?`)) {
      return;
    }
  }

  showToast('Applying schedule to Org files...', '⏳');
  await performReviewAction('apply');
}

// --- What-If Effort Modal ---
function openWhatIfEffortModal(taskId, currentEffort) {
  const modal = document.getElementById('effort-modal');
  const input = document.getElementById('whatif-effort-input');
  const taskIdHolder = document.getElementById('whatif-task-id');

  taskIdHolder.value = taskId;
  // Clean duration (e.g. "60m" -> "1:00")
  input.value = currentEffort.replace(/[m\[\]\?]/g, '').trim();

  modal.classList.add('active');
}

function closeWhatIfEffortModal() {
  document.getElementById('effort-modal').classList.remove('active');
}

async function submitWhatIfEffort() {
  const taskId = document.getElementById('whatif-task-id').value;
  const newEffort = document.getElementById('whatif-effort-input').value.trim();
  closeWhatIfEffortModal();
  if (taskId && newEffort) {
    showToast(`Recalculating with effort ${newEffort}...`, '⏳');
    await performReviewAction('edit-effort', taskId, newEffort);
  }
}

// --- Task Property Editor ---
async function openTaskEditor(taskId) {
  const modal = document.getElementById('task-editor-modal');
  modal.classList.add('active');

  const headlineInput = document.getElementById('edit-headline');
  const effortInput = document.getElementById('edit-effort');
  const scheduledInput = document.getElementById('edit-scheduled');
  const deadlineInput = document.getElementById('edit-deadline');
  const tagsInput = document.getElementById('edit-tags');
  const notBeforeInput = document.getElementById('edit-not-before');
  const blockerInput = document.getElementById('edit-blocker');
  const recurringSelect = document.getElementById('edit-recurring');
  const todoContainer = document.getElementById('edit-todo-chips');
  const priorityContainer = document.getElementById('edit-priority-chips');
  const clockBtn = document.getElementById('task-clock-toggle-btn');
  const taskIdHolder = document.getElementById('edit-task-id');

  taskIdHolder.value = taskId;
  headlineInput.value = 'Loading...';

  try {
    const task = await window.api.getTask(taskId);
    state.activeTask = task;

    headlineInput.value = task.heading || '';
    effortInput.value = task.effort || '';
    scheduledInput.value = task.scheduled || '';
    deadlineInput.value = task.deadline || '';
    tagsInput.value = (task.tags || []).join(' ');
    notBeforeInput.value = task.not_before || '';
    blockerInput.value = task.blocker || '';
    recurringSelect.value = task.recurring || '';

    // Render TODO chips
    todoContainer.innerHTML = '';
    state.todoKeywords.forEach((kw) => {
      const chip = document.createElement('div');
      chip.className = `selectable-chip ${task.todo === kw ? 'selected' : ''}`;
      chip.textContent = kw;
      chip.addEventListener('click', () => {
        haptic();
        todoContainer.querySelectorAll('.selectable-chip').forEach(c => c.classList.remove('selected'));
        chip.classList.add('selected');
      });
      todoContainer.appendChild(chip);
    });

    // Render Priority chips
    priorityContainer.innerHTML = '';
    ['', 'A', 'B', 'C'].forEach((p) => {
      const chip = document.createElement('div');
      chip.className = `selectable-chip ${(task.priority || '') === p ? 'selected' : ''}`;
      chip.textContent = p ? `[#${p}]` : 'None';
      chip.addEventListener('click', () => {
        haptic();
        priorityContainer.querySelectorAll('.selectable-chip').forEach(c => c.classList.remove('selected'));
        chip.classList.add('selected');
      });
      priorityContainer.appendChild(chip);
    });

  } catch (err) {
    showToast('Failed to load task details: ' + err.message, '❌');
    closeTaskEditor();
  }
}

function closeTaskEditor() {
  document.getElementById('task-editor-modal').classList.remove('active');
  state.activeTask = null;
}

async function saveTaskProperties() {
  haptic();
  const taskId = document.getElementById('edit-task-id').value;
  if (!taskId) return;

  const headline = document.getElementById('edit-headline').value.trim();
  const effort = document.getElementById('edit-effort').value.trim();
  const scheduled = document.getElementById('edit-scheduled').value.trim();
  const deadline = document.getElementById('edit-deadline').value.trim();
  const rawTags = document.getElementById('edit-tags').value.trim();
  const notBefore = document.getElementById('edit-not-before').value.trim();
  const blocker = document.getElementById('edit-blocker').value.trim();
  const recurring = document.getElementById('edit-recurring').value;

  const selectedTodo = document.querySelector('#edit-todo-chips .selectable-chip.selected');
  const todo = selectedTodo ? selectedTodo.textContent : '';

  const selectedPri = document.querySelector('#edit-priority-chips .selectable-chip.selected');
  let priority = '';
  if (selectedPri && selectedPri.textContent !== 'None') {
    priority = selectedPri.textContent.replace(/[\[\]#]/g, '');
  }

  const tags = rawTags ? rawTags.split(/[\s:,]+/).filter(Boolean) : [];

  const payload = {
    heading: headline,
    effort,
    todo,
    priority,
    scheduled,
    deadline,
    tags,
    not_before: notBefore,
    blocker,
    recurring
  };

  try {
    showToast('Saving to Org file...', '⏳');
    await window.api.editTask(taskId, payload);
    showToast('Task updated successfully!', '✅');
    closeTaskEditor();
    loadCurrentView();
  } catch (err) {
    showToast('Save failed: ' + err.message, '❌');
  }
}

async function jumpActiveTaskInEmacs() {
  haptic();
  const taskId = document.getElementById('edit-task-id').value;
  if (taskId) {
    try {
      await window.api.jumpTask(taskId);
      showToast('Jumped to task in Emacs!', '🎯');
    } catch (err) {
      showToast(err.message, '❌');
    }
  }
}

// --- Bump Agenda Modal ---
function openBumpModal(taskId = null) {
  const modal = document.getElementById('bump-modal');
  document.getElementById('bump-task-id').value = taskId || '';
  modal.classList.add('active');
}

function closeBumpModal() {
  document.getElementById('bump-modal').classList.remove('active');
}

async function executeBump(minutes) {
  haptic();
  const taskId = document.getElementById('bump-task-id').value;
  closeBumpModal();

  try {
    showToast(`Bumping agenda forward by ${minutes}m...`, '⏳');
    const res = await window.api.bumpAgenda(taskId, minutes);
    showToast(`Bumped ${res.bumped_count || 0} tasks forward!`, '⏩');
    loadAgenda();
  } catch (err) {
    showToast(err.message, '❌');
  }
}

// --- Backlog Tasks View ---
async function loadBacklog() {
  const container = document.getElementById('backlog-list-container');
  container.innerHTML = '<div style="text-align:center; padding: 40px; color: var(--text-muted);">Loading schedulable tasks...</div>';

  try {
    // In preview mode review contains all schedulable tasks
    const data = await window.api.getReviewState(false);
    renderBacklog(data.entries || []);
  } catch (err) {
    container.innerHTML = `<div style="text-align:center; padding: 40px; color: var(--text-muted);">${err.message}</div>`;
  }
}

function renderBacklog(entries) {
  const container = document.getElementById('backlog-list-container');
  container.innerHTML = '';

  const tasks = entries.filter(e => e.type === 'task');
  if (tasks.length === 0) {
    container.innerHTML = '<div style="text-align:center; padding: 40px; color: var(--text-muted);">No backlog tasks found.</div>';
    return;
  }

  tasks.forEach((t) => {
    const card = document.createElement('div');
    card.className = 'task-card';
    card.innerHTML = `
      <div class="task-card-top">
        <span class="project-indicator">
          <span class="color-dot" style="background-color: ${t.project_color || '#61afef'}"></span>
          ${escapeHtml(t.project || 'General')}
        </span>
        <span class="badge badge-effort">⏱️ ${escapeHtml(t.duration || '')}</span>
      </div>
      <div class="task-card-title">${escapeHtml(t.headline)}</div>
      <div class="task-card-meta">
        <span class="badge" style="background: var(--bg-surface); color: var(--text-muted);">Score: ${t.score || ''}</span>
        <span class="badge" style="font-size: 0.75rem;">${t.status || ''}</span>
      </div>
    `;
    card.addEventListener('click', () => {
      haptic();
      openTaskEditor(t.id);
    });
    container.appendChild(card);
  });
}

// --- Adherence View ---
async function loadAdherence() {
  try {
    const data = await window.api.getAdherence();
    const scoreVal = document.getElementById('adherence-score-val');
    const streakVal = document.getElementById('adherence-streak-val');

    if (scoreVal) scoreVal.textContent = Math.round(data.score || 0) + '%';
    if (streakVal) streakVal.textContent = (data.streak || 0) + ' Days';
  } catch (err) {
    console.warn('Adherence fetch error:', err);
  }
}

async function takeMorningSnapshot() {
  haptic();
  try {
    showToast('Capturing morning snapshot...', '📸');
    await window.api.takeSnapshot();
    showToast('Morning snapshot recorded!', '✅');
  } catch (err) {
    showToast(err.message, '❌');
  }
}

// --- Settings Modal ---
function openSettingsModal() {
  const modal = document.getElementById('settings-modal');
  document.getElementById('setting-server-url').value = window.api.baseUrl;
  document.getElementById('setting-server-token').value = window.api.token;
  modal.classList.add('active');
}

function closeSettingsModal() {
  document.getElementById('settings-modal').classList.remove('active');
}

async function saveServerSettings() {
  haptic();
  const url = document.getElementById('setting-server-url').value.trim();
  const token = document.getElementById('setting-server-token').value.trim();
  window.api.setServerConfig(url, token);
  showToast('Settings saved, reconnecting...', '🔄');
  closeSettingsModal();
  await checkServerStatus();
  loadCurrentView();
}

// --- Event Listeners Setup ---
function setupEventListeners() {
  // Date Navigation
  document.getElementById('prev-day-btn')?.addEventListener('click', () => {
    haptic();
    state.currentDate.setDate(state.currentDate.getDate() - 1);
    loadAgenda();
  });

  document.getElementById('next-day-btn')?.addEventListener('click', () => {
    haptic();
    state.currentDate.setDate(state.currentDate.getDate() + 1);
    loadAgenda();
  });

  document.getElementById('today-chip-btn')?.addEventListener('click', () => {
    haptic();
    state.currentDate = new Date();
    loadAgenda();
  });

  // Refresh Button in header
  document.getElementById('header-refresh-btn')?.addEventListener('click', () => {
    haptic();
    showToast('Refreshing...', '🔄');
    loadCurrentView();
  });

  // Settings Button in header
  document.getElementById('header-settings-btn')?.addEventListener('click', () => {
    haptic();
    openSettingsModal();
  });

  // Quick Action Buttons
  document.getElementById('quick-bump-day-btn')?.addEventListener('click', () => {
    haptic();
    openBumpModal();
  });

  document.getElementById('quick-run-scheduler-btn')?.addEventListener('click', async () => {
    haptic();
    showToast('Running full scheduler in Emacs...', '⚡');
    try {
      await window.api.runScheduler();
      showToast('Scheduled tasks successfully!', '✅');
      loadAgenda();
    } catch (err) {
      showToast(err.message, '❌');
    }
  });

  // Review toolbar buttons
  document.getElementById('review-recalc-btn')?.addEventListener('click', () => {
    haptic();
    performReviewAction('recalculate');
  });

  document.getElementById('review-refresh-btn')?.addEventListener('click', () => {
    haptic();
    loadReview(true);
  });

  document.getElementById('review-undo-btn')?.addEventListener('click', () => {
    haptic();
    performReviewAction('undo');
  });

  document.getElementById('review-mark-all-btn')?.addEventListener('click', () => {
    haptic();
    performReviewAction('mark-all');
  });

  document.getElementById('review-unmark-all-btn')?.addEventListener('click', () => {
    haptic();
    performReviewAction('unmark-all');
  });

  document.getElementById('review-mark-today-btn')?.addEventListener('click', () => {
    haptic();
    performReviewAction('mark-today');
  });

  document.getElementById('review-filter-today-btn')?.addEventListener('click', () => {
    haptic();
    performReviewAction('filter-today');
  });

  document.getElementById('review-filter-clear-btn')?.addEventListener('click', () => {
    haptic();
    performReviewAction('filter-clear');
  });

  document.getElementById('big-apply-review-btn')?.addEventListener('click', () => {
    applyReviewSchedule();
  });

  // Effort preset buttons in Task Editor
  document.querySelectorAll('#editor-effort-presets .selectable-chip').forEach((chip) => {
    chip.addEventListener('click', () => {
      haptic();
      document.getElementById('edit-effort').value = chip.dataset.effort;
    });
  });

  // Snapshot button
  document.getElementById('take-snapshot-btn')?.addEventListener('click', takeMorningSnapshot);
}

// Utility: HTML escape
function escapeHtml(str) {
  if (!str) return '';
  return String(str)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#039;');
}
