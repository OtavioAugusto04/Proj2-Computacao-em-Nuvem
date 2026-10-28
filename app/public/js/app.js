const API = '/api';

const state = {
  environmentsTimer: null,
  outputTimer: null,
  currentOutputId: null,
};

function showToast(message, isError = false) {
  const toast = document.getElementById('toast');
  toast.textContent = message;
  toast.classList.toggle('error', isError);
  toast.classList.remove('hidden');
  clearTimeout(toast._hideTimer);
  toast._hideTimer = setTimeout(() => toast.classList.add('hidden'), 4000);
}

async function api(path, options = {}) {
  const res = await fetch(`${API}${path}`, options);
  const contentType = res.headers.get('content-type') || '';
  const body = contentType.includes('application/json') ? await res.json() : await res.text();
  if (!res.ok) {
    const message = typeof body === 'object' && body.error ? body.error : String(body);
    throw new Error(message || `erro HTTP ${res.status}`);
  }
  return body;
}

// ---------- navegação entre telas ----------

function showView(viewName) {
  document.querySelectorAll('.view').forEach((el) => el.classList.remove('active'));
  document.getElementById(`view-${viewName}`).classList.add('active');
  document.querySelectorAll('.tab-btn').forEach((btn) => {
    btn.classList.toggle('active', btn.dataset.view === viewName);
  });

  stopEnvironmentsPolling();
  stopOutputPolling();

  if (viewName === 'environments') {
    loadEnvironments();
    startEnvironmentsPolling();
  } else if (viewName === 'new-environment') {
    loadScriptOptions();
  } else if (viewName === 'scripts') {
    loadScripts();
  }
}

document.querySelectorAll('.tab-btn').forEach((btn) => {
  btn.addEventListener('click', () => showView(btn.dataset.view));
});

document.getElementById('back-to-environments').addEventListener('click', () => showView('environments'));

// ---------- tela: ambientes ----------

function statusLabel(status) {
  return status || 'desconhecido';
}

function renderEnvironments(rows) {
  const body = document.getElementById('environments-body');
  const empty = document.getElementById('environments-empty');
  body.innerHTML = '';

  if (!rows.length) {
    empty.classList.remove('hidden');
    return;
  }
  empty.classList.add('hidden');

  for (const env of rows) {
    const tr = document.createElement('tr');
    tr.innerHTML = `
      <td>${env.id}</td>
      <td>${env.name}</td>
      <td>${env.cpu_percent}%</td>
      <td>${env.memory_mb} MB</td>
      <td>${env.io_mbps} MB/s</td>
      <td><span class="status-badge status-${env.status}">${statusLabel(env.status)}</span></td>
      <td>
        <button class="btn secondary" data-action="logs" data-id="${env.id}">Ver output</button>
        <button class="btn secondary" data-action="stop" data-id="${env.id}">Terminar</button>
        <button class="btn danger" data-action="remove" data-id="${env.id}">Remover</button>
      </td>
    `;
    body.appendChild(tr);
  }
}

async function loadEnvironments() {
  try {
    const rows = await api('/environments');
    renderEnvironments(rows);
  } catch (err) {
    showToast(err.message, true);
  }
}

document.getElementById('environments-body').addEventListener('click', async (ev) => {
  const btn = ev.target.closest('button[data-action]');
  if (!btn) return;
  const { action, id } = btn.dataset;

  try {
    if (action === 'logs') {
      showOutput(id);
    } else if (action === 'stop') {
      await api(`/environments/${id}/stop`, { method: 'POST' });
      showToast(`Ambiente ${id} encerrado`);
      loadEnvironments();
    } else if (action === 'remove') {
      if (!confirm(`Remover o ambiente ${id}?`)) return;
      await api(`/environments/${id}`, { method: 'DELETE' });
      showToast(`Ambiente ${id} removido`);
      loadEnvironments();
    }
  } catch (err) {
    showToast(err.message, true);
  }
});

document.getElementById('refresh-environments').addEventListener('click', loadEnvironments);

function startEnvironmentsPolling() {
  stopEnvironmentsPolling();
  state.environmentsTimer = setInterval(loadEnvironments, 4000);
}

function stopEnvironmentsPolling() {
  if (state.environmentsTimer) clearInterval(state.environmentsTimer);
  state.environmentsTimer = null;
}

// ---------- tela: novo ambiente ----------

const form = document.getElementById('form-new-environment');

form.querySelectorAll('input[name="mode"]').forEach((radio) => {
  radio.addEventListener('change', () => {
    const isScript = form.mode.value === 'script';
    document.getElementById('mode-cmd-fields').classList.toggle('hidden', isScript);
    document.getElementById('mode-script-fields').classList.toggle('hidden', !isScript);
  });
});

async function loadScriptOptions() {
  const select = form.script_id;
  select.innerHTML = '';
  try {
    const scripts = await api('/scripts');
    for (const s of scripts) {
      const opt = document.createElement('option');
      opt.value = s.id;
      opt.textContent = s.name;
      select.appendChild(opt);
    }
  } catch (err) {
    showToast(err.message, true);
  }
}

form.addEventListener('submit', async (ev) => {
  ev.preventDefault();
  const mode = form.mode.value;

  const payload = {
    name: form.name.value,
    cpu_percent: Number(form.cpu_percent.value),
    memory_mb: Number(form.memory_mb.value),
    io_mbps: Number(form.io_mbps.value),
    mode,
  };
  if (mode === 'cmd') payload.command = form.command.value;
  else payload.script_id = Number(form.script_id.value);

  try {
    await api('/environments', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(payload),
    });
    showToast('Ambiente criado com sucesso');
    form.reset();
    showView('environments');
  } catch (err) {
    showToast(err.message, true);
  }
});

// ---------- tela: scripts ----------

function renderScripts(rows) {
  const body = document.getElementById('scripts-body');
  const empty = document.getElementById('scripts-empty');
  body.innerHTML = '';

  if (!rows.length) {
    empty.classList.remove('hidden');
    return;
  }
  empty.classList.add('hidden');

  for (const s of rows) {
    const tr = document.createElement('tr');
    const createdAt = s.created_at ? new Date(s.created_at).toLocaleString() : '';
    tr.innerHTML = `
      <td>${s.id}</td>
      <td>${s.name}</td>
      <td>${s.description || ''}</td>
      <td>${createdAt}</td>
      <td><button class="btn danger" data-id="${s.id}">Remover</button></td>
    `;
    body.appendChild(tr);
  }
}

async function loadScripts() {
  try {
    const rows = await api('/scripts');
    renderScripts(rows);
  } catch (err) {
    showToast(err.message, true);
  }
}

document.getElementById('scripts-body').addEventListener('click', async (ev) => {
  const btn = ev.target.closest('button[data-id]');
  if (!btn) return;
  const id = btn.dataset.id;

  if (!confirm(`Remover o script ${id}?`)) return;
  try {
    await api(`/scripts/${id}`, { method: 'DELETE' });
    showToast(`Script ${id} removido`);
    loadScripts();
  } catch (err) {
    showToast(err.message, true);
  }
});

document.getElementById('form-upload-script').addEventListener('submit', async (ev) => {
  ev.preventDefault();
  const formEl = ev.target;
  const formData = new FormData(formEl);

  try {
    await api('/scripts', { method: 'POST', body: formData });
    showToast('Script enviado com sucesso');
    formEl.reset();
    loadScripts();
  } catch (err) {
    showToast(err.message, true);
  }
});

// ---------- tela: output ----------
// Tratada fora de showView() porque depende de um :id dinamico, nao so do
// nome da tela.

async function showOutput(id) {
  stopEnvironmentsPolling();
  stopOutputPolling();

  document.querySelectorAll('.view').forEach((el) => el.classList.remove('active'));
  document.getElementById('view-output').classList.add('active');
  document.querySelectorAll('.tab-btn').forEach((btn) => btn.classList.remove('active'));

  state.currentOutputId = id;
  document.getElementById('output-env-id').textContent = `#${id}`;

  await refreshOutput();
  state.outputTimer = setInterval(refreshOutput, 3000);
}

async function refreshOutput() {
  const id = state.currentOutputId;
  if (!id) return;

  try {
    const env = await api(`/environments/${id}`);
    const statusEl = document.getElementById('output-status');
    statusEl.textContent = statusLabel(env.status);
    statusEl.className = `status-badge status-${env.status}`;

    const logRes = await fetch(`${API}/environments/${id}/logs`);
    const text = await logRes.text();
    const logBox = document.getElementById('output-log');
    const wasAtBottom = logBox.scrollTop + logBox.clientHeight >= logBox.scrollHeight - 10;
    logBox.textContent = text;
    if (wasAtBottom) logBox.scrollTop = logBox.scrollHeight;

    if (env.status !== 'running' && env.status !== 'creating') {
      stopOutputPolling();
    }
  } catch (err) {
    showToast(err.message, true);
    stopOutputPolling();
  }
}

function stopOutputPolling() {
  if (state.outputTimer) clearInterval(state.outputTimer);
  state.outputTimer = null;
}

// ---------- inicializacao ----------

showView('environments');
