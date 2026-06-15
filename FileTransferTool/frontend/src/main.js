import './app.css';
import * as api from './api.js';

const q = (s) => document.querySelector(s);
const fmt = (b) => { if (!b) return '0'; const u = ['B', 'KB', 'MB', 'GB']; let i = 0, v = b; while (v >= 1024 && i < 3) { v /= 1024; i++; } return v.toFixed(1) + u[i]; };
const fmtEta = (s) => { if (!s) return ''; if (s < 60) return '约' + s + '秒'; return '约' + Math.floor(s / 60) + '分' + (s % 60) + '秒'; };

async function initInfo() {
  try {
    q('#qr').src = await api.mobileQR();
    q('#url').textContent = await api.mobileURL();
    q('#savedir').textContent = await api.saveDir();
    q('#myaddr').textContent = await api.localAddr();
    shareSt = await api.shareState();
    renderShare();
  } catch (e) {
    q('#url').textContent = '初始化中…';
  }
}

q('#preset').onchange = (e) => api.setGlobalLimit(parseInt(e.target.value, 10));

q('#copyurl').onclick = async () => {
  try {
    await api.copyURL();
    const b = q('#copyurl'); const old = b.textContent;
    b.textContent = '✓ 已复制'; setTimeout(() => b.textContent = old, 1500);
  } catch (e) { console.error(e); }
};

q('#changedir').onclick = async () => {
  try {
    const dir = await api.pickSaveDir();
    if (dir) q('#savedir').textContent = dir;
  } catch (e) { console.error(e); }
};

q('#opendir').onclick = () => api.openSaveDir();

// askKind 在按钮下方弹个小菜单:选「文件」还是「文件夹」,点旁边取消。
// 系统对话框没法一次同时选两种,所以用这个小菜单合成一个按钮。
function askKind(anchorBtn) {
  return new Promise(resolve => {
    const old = document.querySelector('.pickmenu');
    if (old) old.remove();
    const m = document.createElement('div');
    m.className = 'pickmenu';
    m.innerHTML = `<button data-k="file">📄 选文件(可多选)</button><button data-k="dir">📁 选文件夹</button>`;
    document.body.appendChild(m);
    const r = anchorBtn.getBoundingClientRect();
    m.style.left = r.left + 'px';
    m.style.top = (r.bottom + 4) + 'px';
    const done = (k) => { m.remove(); document.removeEventListener('click', onDoc, true); resolve(k); };
    m.querySelectorAll('button').forEach(b => b.onclick = (e) => { e.stopPropagation(); done(b.dataset.k); });
    const onDoc = (e) => { if (!m.contains(e.target)) done(null); };
    setTimeout(() => document.addEventListener('click', onDoc, true), 0);
  });
}

// pickPaths 按用户选的类型弹对应的系统选择框,统一返回路径数组(取消返回空数组)。
async function pickPaths(kind) {
  if (kind === 'dir') {
    const dir = await api.pickFolder();
    return dir ? [dir] : [];
  }
  return (await api.pickFiles()) || [];
}

// ---- 局域网电脑发现 + 选中 + 发送 ----
let selectedPeer = null;

q('#scan').onclick = async () => {
  q('#peers').innerHTML = '<li class="muted">扫描中…</li>';
  try {
    const peers = await api.discoverPeers();
    if (!peers || !peers.length) { q('#peers').innerHTML = '<li class="muted">没发现其他电脑</li>'; return; }
    q('#peers').innerHTML = '';
    peers.forEach(p => {
      const li = document.createElement('li');
      li.className = 'peer';
      li.innerHTML = `<span class="dot"></span><b>${p.name}</b><span class="mono small">${p.host}:${p.port}</span>`;
      li.onclick = () => {
        selectedPeer = p;
        document.querySelectorAll('#peers .peer').forEach(x => x.classList.remove('on'));
        li.classList.add('on');
        q('#selpeer').textContent = `${p.name} (${p.host})`;
        q('#sendbar').classList.remove('hidden');
      };
      q('#peers').appendChild(li);
    });
  } catch (e) {
    q('#peers').innerHTML = '<li class="muted">扫描失败</li>';
  }
};

q('#sendfiles').onclick = async (e) => {
  if (!selectedPeer) return;
  const kind = await askKind(e.currentTarget);
  if (!kind) return;
  try {
    const paths = await pickPaths(kind);
    if (paths.length) await api.sendToPeer(selectedPeer.host, selectedPeer.port, paths);
  } catch (err) { console.error(err); }
};

// ---- 发文件链接:文件/文件夹共用一个分享链接,可增可删,列表整体刷新 ----
let shareSt = null;

async function flashCopy(btn, text) {
  await api.copyText(text);
  const old = btn.textContent;
  btn.textContent = '✓ 已复制'; setTimeout(() => btn.textContent = old, 1500);
}

function renderShare() {
  const st = shareSt;
  const box = q('#sharebox');
  if (!st || !st.entries || !st.entries.length) { box.classList.add('hidden'); return; }
  box.classList.remove('hidden');
  q('#shareurl').textContent = st.url;
  q('#cpLan').onclick = () => flashCopy(q('#cpLan'), st.url);
  const ts = q('#cpTs');
  if (st.tsUrl) { ts.classList.remove('hidden'); ts.onclick = () => flashCopy(ts, st.tsUrl); }
  else ts.classList.add('hidden');
  const ul = q('#shareitems');
  ul.innerHTML = '';
  st.entries.forEach(e => {
    const li = document.createElement('li');
    li.className = 'shareitem';
    li.innerHTML = `
      <span class="icon">${e.isDir ? '📁' : '📄'}</span><b>${e.name}</b>
      <span class="muted small">${e.isDir ? e.count + ' 个文件 · ' : ''}${fmt(e.size)}</span>
      <button class="btn-x" data-del="${e.id}" title="移除">✕</button>`;
    ul.appendChild(li);
  });
  ul.querySelectorAll('[data-del]').forEach(b => b.onclick = async () => {
    shareSt = await api.shareRemove(b.dataset.del);
    renderShare();
  });
}

q('#mkadd').onclick = async (e) => {
  const kind = await askKind(e.currentTarget);
  if (!kind) return;
  try {
    shareSt = kind === 'dir' ? await api.shareAddFolder() : await api.shareAddFiles();
    renderShare();
  } catch (err) { console.error(err); }
};

// 一键安装 Tailscale
q('#instTS').onclick = async () => {
  const b = q('#instTS'); const old = b.textContent;
  b.disabled = true; b.textContent = '安装中…(若弹权限确认请点"是")';
  q('#tsmsg').textContent = '';
  try {
    q('#tsmsg').textContent = await api.installTailscale();
  } catch (e) {
    q('#tsmsg').textContent = '安装出错:' + e;
  }
  b.textContent = old; b.disabled = false;
};

// 远程/手动发送:填对方地址直接发(配合 Tailscale)
function manualTarget() {
  const host = q('#mhost').value.trim();
  if (!host) { alert('先填对方的地址'); return null; }
  return { host, port: parseInt(q('#mport').value, 10) || 52718 };
}

q('#msend').onclick = async (e) => {
  const t = manualTarget();
  if (!t) return;
  const kind = await askKind(e.currentTarget);
  if (!kind) return;
  try {
    const paths = await pickPaths(kind);
    if (paths.length) await api.sendToPeer(t.host, t.port, paths);
  } catch (err) { console.error(err); }
};

// ---- 传输任务 ----
const taskMap = {};
function renderTasks() {
  const box = q('#tasks');
  const list = Object.values(taskMap);
  if (!list.length) { box.innerHTML = '<p class="empty">还没有任务。手机扫码、或在下面给某台电脑发文件。</p>'; return; }
  box.innerHTML = '';
  list.sort((a, b) => (a.status === 'pending' ? -1 : 0));
  list.forEach(t => {
    const pct = t.totalBytes ? Math.floor(t.transferredBytes / t.totalBytes * 100) : 0;
    const arrow = t.direction === 'send' ? '⬆' : '⬇';
    const div = document.createElement('div');
    div.className = 'task' + (t.status === 'pending' ? ' pending' : '') + (t.status === 'done' ? ' done' : '');
    let actions = '';
    if (t.status === 'pending' && t.direction === 'recv') {
      actions = `<button class="btn-accent" data-acc="${t.id}">同意接收</button><button class="btn-ghost" data-rej="${t.id}">拒绝</button>`;
    }
    div.innerHTML = `
      <div class="row"><b>${arrow} ${t.name}</b><span class="badge ${t.status}">${statusText(t.status)}</span></div>
      <div class="bar"><i style="width:${pct}%"></i></div>
      <div class="meta">
        <span>${pct}% · ${fmt(t.transferredBytes)} / ${fmt(t.totalBytes)}</span>
        <span class="spd">${t.speed ? '⚡ ' + fmt(t.speed) + '/s' : ''} ${t.etaSeconds ? '· ' + fmtEta(t.etaSeconds) : ''}</span>
      </div>
      <div class="actions">${actions}
        <input type="number" min="0" placeholder="本任务限速 KB/s" data-lim="${t.id}"></div>`;
    box.appendChild(div);
  });
  box.querySelectorAll('[data-acc]').forEach(b => b.onclick = () => api.accept(b.dataset.acc));
  box.querySelectorAll('[data-rej]').forEach(b => b.onclick = () => api.reject(b.dataset.rej));
  box.querySelectorAll('[data-lim]').forEach(inp => inp.onchange = () => {
    api.setTaskLimit(inp.dataset.lim, (parseInt(inp.value, 10) || 0) * 1024);
  });
}

function statusText(s) {
  return { pending: '待确认', transferring: '传输中', paused: '已暂停', done: '已完成', failed: '失败', rejected: '已拒绝' }[s] || s;
}

window.runtime.EventsOn('task', (t) => { taskMap[t.id] = t; renderTasks(); });

initInfo();
