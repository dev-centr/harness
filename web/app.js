/**
 * Harness desk — discussion vs work separation + three view modes.
 *
 * UX contract:
 * 1. Main chat = discussion cadence only (coordinator + discussion nodes via /api/nodes/{id}/chat).
 *    Worker tool noise must NOT appear here — tasks never load into main-lines.
 * 2. Workers panel = task tiles (status + summary mailbox). Full transcript in fork on drill-in.
 * 3. Temporal scrubber = cross-cutting; scope global|node:*; not a fourth primary mode.
 * 4. View modes: linear | grid | tree (body[data-view]).
 */

let selectedDiscussionId = 'coordinator';
let forkNodeId = null;
let viewMode = 'linear';
let graphData = { nodes: [], graph: { root: 'coordinator' } };
let temporalAt = null;

const $ = (id) => document.getElementById(id);

const DISCUSSION_TYPES = new Set(['coordinator', 'discussion', 'disambiguation']);
const STATUS_STRIP = {
  linear: 'Linear — discussion in center, compact worker strip.',
  grid: 'Grid — spatial task tiles; discussion stays visible.',
  tree: 'Tree — spawn/dependency canvas; click node to fork.',
};

async function api(path, opts = {}) {
  const res = await fetch(path, {
    headers: { 'Content-Type': 'application/json' },
    ...opts,
  });
  return res.json();
}

function esc(s) {
  return String(s)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;');
}

function statusLabel(s) {
  const map = {
    awaiting_user: 'Needs you',
    running: 'Working',
    done: 'Completed',
    blocked: 'Blocked',
    failed: 'Failed',
    idle: 'Idle',
  };
  return map[s] || ((s || 'idle').charAt(0).toUpperCase() + (s || 'idle').slice(1));
}

/** Discussion cadence lines only — hide system/worker scrap from main panel. */
function isDiscussionLine(line) {
  if (line.role === 'system') return false;
  return true;
}

function discussionNodes(nodes) {
  return nodes
    .filter((n) => !n.hidden && DISCUSSION_TYPES.has(n.type))
    .sort((a, b) => {
      if (a.type === 'coordinator') return -1;
      if (b.type === 'coordinator') return 1;
      return (a.title || a.id).localeCompare(b.title || b.id);
    });
}

function taskNodes(nodes) {
  return nodes.filter((n) => n.type === 'task' && !n.hidden);
}

function setViewMode(mode) {
  viewMode = mode;
  document.body.dataset.view = mode;
  document.querySelectorAll('.view-mode-btn').forEach((btn) => {
    btn.classList.toggle('is-active', btn.dataset.view === mode);
  });
  $('workers-panel').hidden = viewMode === 'tree';
  $('tree-panel').hidden = viewMode !== 'tree';
  $('status-strip').textContent = STATUS_STRIP[mode] || '';
  renderWorkers(graphData.nodes);
  if (viewMode === 'tree') renderTree(graphData.nodes);
}

function renderDiscussionNav(nodes) {
  const list = $('discussion-list');
  const items = discussionNodes(nodes);
  list.innerHTML = items
    .map(
      (n) => `<li>
        <button type="button" class="discussion-item${selectedDiscussionId === n.id ? ' is-active' : ''}"
          data-id="${esc(n.id)}">
          <span class="type-badge type-${esc(n.type)}">${esc(n.type)}</span>
          <span class="discussion-item-title">${esc(n.title || n.id)}</span>
          <span class="status-dot status-${esc(n.status)}" title="${esc(statusLabel(n.status))}"></span>
        </button>
      </li>`,
    )
    .join('');

  list.querySelectorAll('.discussion-item').forEach((btn) => {
    btn.addEventListener('click', () => loadDiscussionChat(btn.dataset.id));
  });
}

async function loadDiscussionChat(nodeId) {
  let node = graphData.nodes.find((n) => n.id === nodeId);
  if (!node) {
    node = graphData.nodes.find((n) => n.type === 'coordinator');
    nodeId = node?.id || 'coordinator';
  }
  selectedDiscussionId = nodeId;
  if (!node) return;

  $('chat-title').textContent = node.title || node.id;
  $('thread-meta').textContent = `${node.type} · ${statusLabel(node.status)}`;
  $('main-input').placeholder = `Message ${node.title || node.id}…`;

  const { lines } = await api(`/api/nodes/${nodeId}/chat`);
  $('main-lines').innerHTML = (lines || [])
    .filter(isDiscussionLine)
    .map((l) => `<li class="is-${esc(l.role)}">${esc(l.text)}</li>`)
    .join('');

  renderDiscussionNav(graphData.nodes);
}

function taskCardHtml(t, opacities = {}) {
  const op = opacities[t.id] ?? 1;
  return `<button type="button" class="task-card status-${esc(t.status)}${forkNodeId === t.id ? ' is-selected' : ''}"
    data-id="${esc(t.id)}" style="opacity:${op}" role="listitem">
    <span class="task-title">${esc(t.title || t.id)}</span>
    <span class="task-summary">${esc(t.summary || '')}</span>
    <span class="task-foot">
      <span class="status-dot status-${esc(t.status)}" aria-hidden="true"></span>
      <span>${esc(statusLabel(t.status))}</span>
      ${t.mixrModel ? `<span title="${esc(t.mixrReason || '')}">· ${esc(t.mixrModel.split('/').pop())}</span>` : ''}
    </span>
  </button>`;
}

function renderWorkers(nodes, opacities = {}) {
  const tasks = taskNodes(nodes);
  const grid = $('workers-grid');
  grid.innerHTML = tasks.map((t) => taskCardHtml(t, opacities)).join('');

  grid.querySelectorAll('.task-card').forEach((btn) => {
    btn.addEventListener('click', () => openFork(btn.dataset.id));
  });

  const running = tasks.filter((t) => t.status === 'running').length;
  $('run-chip').textContent = tasks.length ? `${running} of ${tasks.length} running` : 'coordinator';
  $('workers-meta').textContent = `${tasks.length} task${tasks.length === 1 ? '' : 's'}`;
}

function buildChildrenMap(nodes) {
  const byId = Object.fromEntries(nodes.map((n) => [n.id, n]));
  const children = {};
  nodes.forEach((n) => {
    children[n.id] = (n.spawned || []).filter((id) => byId[id] && !byId[id].hidden);
  });
  return { byId, children };
}

function renderTree(nodes) {
  const root = graphData.graph?.root || 'coordinator';
  const { byId, children } = buildChildrenMap(nodes);
  if (!byId[root]) return;

  const depths = [];
  const depthOf = {};
  const queue = [{ id: root, depth: 0 }];
  while (queue.length) {
    const { id, depth } = queue.shift();
    if (depthOf[id] != null) continue;
    depthOf[id] = depth;
    if (!depths[depth]) depths[depth] = [];
    depths[depth].push(id);
    (children[id] || []).forEach((cid) => queue.push({ id: cid, depth: depth + 1 }));
  }

  const columns = $('tree-columns');
  columns.innerHTML = depths
    .map((col, depth) => {
      const cells = col
        .map((id) => {
          const n = byId[id];
          return `<div class="tree-cell" data-id="${esc(id)}">
            <button type="button" class="tree-node${forkNodeId === id ? ' is-selected' : ''}" data-id="${esc(id)}">
              <span class="type-badge type-${esc(n.type)}">${esc(n.type)}</span>
              <span class="tree-node-title">${esc(n.title || n.id)}</span>
              <span class="status-dot status-${esc(n.status)}" title="${esc(statusLabel(n.status))}"></span>
            </button>
            <button type="button" class="tree-spawn" data-parent="${esc(id)}" title="Spawn child">+</button>
          </div>`;
        })
        .join('');
      return `<div class="tree-column" data-depth="${depth}">${cells}</div>`;
    })
    .join('');

  columns.querySelectorAll('.tree-node').forEach((btn) => {
    btn.addEventListener('click', () => openFork(btn.dataset.id));
  });
  columns.querySelectorAll('.tree-spawn').forEach((btn) => {
    btn.addEventListener('click', (e) => {
      e.stopPropagation();
      promptSpawn(btn.dataset.parent);
    });
  });

  requestAnimationFrame(() => drawTreeEdges());
}

function drawTreeEdges() {
  const svg = $('tree-edges');
  const scroll = svg.parentElement;
  const { children } = buildChildrenMap(graphData.nodes);
  const w = scroll.scrollWidth;
  const h = scroll.scrollHeight;
  svg.setAttribute('width', w);
  svg.setAttribute('height', h);
  svg.setAttribute('viewBox', `0 0 ${w} ${h}`);
  svg.innerHTML = '';

  const rootRect = scroll.getBoundingClientRect();
  const pos = (id) => {
    const el = scroll.querySelector(`.tree-node[data-id="${CSS.escape(id)}"]`);
    if (!el) return null;
    const r = el.getBoundingClientRect();
    return {
      x: r.left - rootRect.left + scroll.scrollLeft + r.width,
      y: r.top - rootRect.top + scroll.scrollTop + r.height / 2,
      xIn: r.left - rootRect.left + scroll.scrollLeft,
      yIn: r.top - rootRect.top + scroll.scrollTop + r.height / 2,
    };
  };

  Object.entries(children).forEach(([parentId, kids]) => {
    const p = pos(parentId);
    if (!p) return;
    kids.forEach((childId) => {
      const c = pos(childId);
      if (!c) return;
      const path = document.createElementNS('http://www.w3.org/2000/svg', 'path');
      const mid = (p.x + c.xIn) / 2;
      path.setAttribute(
        'd',
        `M ${p.x} ${p.y} C ${mid} ${p.y}, ${mid} ${c.yIn}, ${c.xIn} ${c.yIn}`,
      );
      path.setAttribute('class', 'tree-edge');
      svg.appendChild(path);
    });
  });
}

async function promptSpawn(parentId) {
  const typeRaw = prompt('Spawn type: task or discussion', 'task');
  if (!typeRaw) return;
  const type = typeRaw.trim().toLowerCase();
  if (!['task', 'discussion'].includes(type)) return;
  const title = prompt('Title', type === 'task' ? 'new-task' : 'new-discussion');
  if (!title) return;
  await api('/api/spawn', {
    method: 'POST',
    body: JSON.stringify({
      parentId,
      type,
      title,
      reason: 'User spawned from desk',
    }),
  });
  await loadGraph();
}

async function openFork(nodeId) {
  forkNodeId = nodeId;
  const node = graphData.nodes.find((n) => n.id === nodeId);
  if (!node) return;

  $('fork-panel').classList.remove('is-hidden');
  $('fork-title').textContent = node.title || node.id;
  $('fork-status').textContent = `${node.type} · ${statusLabel(node.status)} · ${node.mixrModel || 'unrouted'}`;

  const { lines } = await api(`/api/nodes/${nodeId}/chat`);
  $('fork-lines').innerHTML = (lines || [])
    .map((l) => `<li class="is-${esc(l.role)}">${esc(l.text)}</li>`)
    .join('');

  renderWorkers(graphData.nodes);
  if (viewMode === 'tree') renderTree(graphData.nodes);
}

async function loadGraph() {
  graphData = await api('/api/graph');
  const op = {};
  graphData.nodes.forEach((n) => {
    if (n.opacity != null) op[n.id] = n.opacity;
  });

  renderDiscussionNav(graphData.nodes);
  await loadDiscussionChat(selectedDiscussionId);
  renderWorkers(graphData.nodes, op);
  if (viewMode === 'tree') renderTree(graphData.nodes);

  const scope = $('timeline-scope');
  scope.innerHTML = '<option value="global">Global</option>';
  graphData.nodes.forEach((n) => {
    const opt = document.createElement('option');
    opt.value = `node:${n.id}`;
    opt.textContent = `Subtree: ${n.title || n.id}`;
    scope.appendChild(opt);
  });
}

async function loadTemporal() {
  const scope = $('timeline-scope').value;
  const zoom = $('timeline-zoom').value;
  const q = new URLSearchParams({ scope, zoom });
  if (temporalAt) q.set('at', temporalAt);
  const data = await api(`/api/temporal?${q}`);
  drawHeatmap(data.heatmap || []);

  const op = {};
  (data.nodes || []).forEach((n) => {
    op[n.id] = n.opacity;
  });
  renderWorkers(graphData.nodes, op);

  const bm = $('timeline-bookmarks');
  bm.innerHTML = (data.bookmarks || [])
    .flatMap((b) => (b.keywords || []).map((k) => `<li>${esc(k)}</li>`))
    .join('');
}

function drawHeatmap(buckets) {
  const canvas = $('timeline-heatmap');
  const ctx = canvas.getContext('2d');
  const w = canvas.clientWidth || 600;
  canvas.width = w;
  const h = canvas.height;
  if (!buckets.length) {
    ctx.clearRect(0, 0, w, h);
    return;
  }
  const bw = w / buckets.length;
  ctx.clearRect(0, 0, w, h);
  buckets.forEach((v, i) => {
    ctx.fillStyle = `rgba(110, 181, 255, ${0.08 + v * 0.45})`;
    ctx.fillRect(i * bw, h - v * h, bw - 1, v * h);
  });
}

document.querySelectorAll('.view-mode-btn').forEach((btn) => {
  btn.addEventListener('click', () => setViewMode(btn.dataset.view));
});

$('fork-close').addEventListener('click', () => {
  forkNodeId = null;
  $('fork-panel').classList.add('is-hidden');
  loadGraph();
});

$('btn-mark-complete').addEventListener('click', async () => {
  if (!forkNodeId) return;
  await api('/api/status', {
    method: 'POST',
    body: JSON.stringify({ nodeId: forkNodeId, status: 'done', summary: 'User marked completed' }),
  });
  await openFork(forkNodeId);
});

$('btn-archive').addEventListener('click', async () => {
  if (!forkNodeId) return;
  await api('/api/hide', {
    method: 'POST',
    body: JSON.stringify({ nodeId: forkNodeId, hidden: true }),
  });
  forkNodeId = null;
  $('fork-panel').classList.add('is-hidden');
  await loadGraph();
});

$('fork-compose').addEventListener('submit', async (e) => {
  e.preventDefault();
  const text = $('fork-input').value.trim();
  if (!text || !forkNodeId) return;
  await api('/api/message', {
    method: 'POST',
    body: JSON.stringify({ nodeId: forkNodeId, text }),
  });
  $('fork-input').value = '';
  openFork(forkNodeId);
});

$('main-compose').addEventListener('submit', async (e) => {
  e.preventDefault();
  const text = $('main-input').value.trim();
  if (!text || !selectedDiscussionId) return;
  await api('/api/message', {
    method: 'POST',
    body: JSON.stringify({ nodeId: selectedDiscussionId, text }),
  });
  $('main-input').value = '';
  await loadDiscussionChat(selectedDiscussionId);
});

$('btn-spawn-task').addEventListener('click', () => promptSpawn('coordinator'));

$('timeline-scope').addEventListener('change', loadTemporal);
$('timeline-zoom').addEventListener('input', loadTemporal);
$('timeline-scrub').addEventListener('input', () => {
  const pct = Number($('timeline-scrub').value) / 100;
  const now = Date.now();
  temporalAt = new Date(now - (1 - pct) * 7 * 24 * 3600 * 1000).toISOString();
  loadTemporal();
});

window.addEventListener('resize', () => {
  if (viewMode === 'tree') drawTreeEdges();
});

function pqCellHeight(ms) {
  const min = 22;
  const max = 96;
  return Math.round(Math.min(max, Math.max(min, min + (Number(ms) || 0) * 0.0002)));
}

async function loadPlanQueue() {
  const cols = $('plan-queue-columns');
  const meta = $('plan-queue-meta');
  if (!cols) return;
  try {
    const data = await api('/api/plan-queue');
    if (data.offline) {
      meta.textContent = 'plan-stackd offline · :17358';
      cols.innerHTML = '<p class="pq-empty">Start plan-stackd for the speculative wait queue.</p>';
      return;
    }
    meta.textContent = 'live · client devcentr-harness';
    cols.innerHTML = '';
    const windows = data.overview?.windows || [];
    const sessions = [];
    for (const win of windows) {
      for (const sess of win.sessions || []) {
        sessions.push({ ...sess, harnessLabel: win.label || win.harnessId });
      }
    }
    if (!sessions.length) {
      cols.innerHTML = '<p class="pq-empty">No plans yet — <code>plan-stack seed</code>.</p>';
      return;
    }
    for (const sess of sessions) {
      const col = document.createElement('div');
      col.className = 'pq-col';
      const head = document.createElement('div');
      head.className = 'pq-col-title';
      head.textContent = `${sess.harnessLabel} / ${sess.title || sess.sessionId}`;
      col.appendChild(head);
      for (const ph of sess.phases || []) {
        const el = document.createElement('div');
        el.className = 'pq-phase';
        el.dataset.status = ph.status;
        el.style.minHeight = `${pqCellHeight(ph.estimatedWaitMs)}px`;
        el.textContent = ph.title;
        col.appendChild(el);
      }
      cols.appendChild(col);
    }
  } catch (err) {
    meta.textContent = 'error';
    cols.innerHTML = `<p class="pq-empty">${String(err.message || err)}</p>`;
  }
}

setViewMode('linear');
loadGraph();
loadTemporal();
loadPlanQueue();
setInterval(loadGraph, 8000);
setInterval(loadPlanQueue, 3000);
