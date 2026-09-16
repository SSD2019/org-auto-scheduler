// Org Auto Scheduler Mobile API Client
class OrgSchedulerAPI {
  constructor() {
    this.baseUrl = localStorage.getItem('org_scheduler_server_url') || (window.location.origin.startsWith('http') ? window.location.origin : 'http://localhost:8989');
    this.token = localStorage.getItem('org_scheduler_server_token') || '';
    this.statusListeners = [];
    this.isConnected = false;
    this.latency = null;
  }

  setServerConfig(url, token) {
    this.baseUrl = url.replace(/\/$/, '');
    this.token = token || '';
    localStorage.setItem('org_scheduler_server_url', this.baseUrl);
    localStorage.setItem('org_scheduler_server_token', this.token);
    this.checkConnection();
  }

  onStatusChange(callback) {
    this.statusListeners.push(callback);
  }

  _notifyStatus(status, data) {
    this.isConnected = status === 'online';
    this.statusListeners.forEach((cb) => cb(status, data));
  }

  async _request(endpoint, options = {}) {
    const url = `${this.baseUrl}${endpoint}`;
    const headers = {
      'Content-Type': 'application/json',
      ...(options.headers || {})
    };

    if (this.token) {
      headers['Authorization'] = `Bearer ${this.token}`;
    }

    const startTime = performance.now();
    try {
      const response = await fetch(url, {
        ...options,
        headers
      });

      this.latency = Math.round(performance.now() - startTime);

      if (!response.ok) {
        const errJson = await response.json().catch(() => ({}));
        throw new Error(errJson.message || `HTTP ${response.status}: ${response.statusText}`);
      }

      const data = await response.json();
      this._notifyStatus('online', { latency: this.latency });
      return data;
    } catch (err) {
      this.latency = null;
      this._notifyStatus('offline', { error: err.message });
      throw err;
    }
  }

  async checkConnection() {
    try {
      const data = await this.getStatus();
      return { ok: true, data };
    } catch (err) {
      return { ok: false, error: err.message };
    }
  }

  // System status & health
  async getStatus() {
    return this._request('/api/status');
  }

  // Agenda view
  async getAgenda(dateStr = '', days = 1) {
    const params = new URLSearchParams();
    if (dateStr) params.append('date', dateStr);
    if (days) params.append('days', days);
    return this._request(`/api/agenda?${params.toString()}`);
  }

  // Schedule commands
  async runScheduler() {
    return this._request('/api/schedule/run', { method: 'POST' });
  }

  async bumpAgenda(taskId, minutes = 30) {
    return this._request('/api/schedule/bump', {
      method: 'POST',
      body: JSON.stringify({ task_id: taskId, minutes })
    });
  }

  // Review & Apply Buffer
  async getReviewState(force = false) {
    return this._request(`/api/review?force=${force ? '1' : '0'}`);
  }

  async reviewAction(action, taskId = null, arg = null) {
    return this._request('/api/review/action', {
      method: 'POST',
      body: JSON.stringify({ action, task_id: taskId, arg })
    });
  }

  // Task Details & Edit
  async getTask(taskId) {
    return this._request(`/api/tasks/${encodeURIComponent(taskId)}`);
  }

  async editTask(taskId, data) {
    return this._request(`/api/tasks/${encodeURIComponent(taskId)}/edit`, {
      method: 'POST',
      body: JSON.stringify(data)
    });
  }

  async clockTask(taskId, action = 'in') {
    return this._request(`/api/tasks/${encodeURIComponent(taskId)}/clock`, {
      method: 'POST',
      body: JSON.stringify({ action })
    });
  }

  async jumpTask(taskId) {
    return this._request(`/api/tasks/${encodeURIComponent(taskId)}/jump`, {
      method: 'POST'
    });
  }

  async createTask(data) {
    return this._request('/api/tasks/create', {
      method: 'POST',
      body: JSON.stringify(data)
    });
  }

  // Adherence & Insights
  async getAdherence() {
    return this._request('/api/adherence');
  }

  async takeSnapshot() {
    return this._request('/api/adherence/snapshot', { method: 'POST' });
  }

  async getInsights() {
    return this._request('/api/insights');
  }
}

// Export singleton instance
window.api = new OrgSchedulerAPI();
