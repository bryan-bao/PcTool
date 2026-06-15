const token = new URLSearchParams(location.search).get('t');
const q = (s) => document.querySelector(s);
const fmt = (b) => { if (!b) return '0'; const u = ['B', 'KB', 'MB', 'GB']; let i = 0, v = b; while (v >= 1024 && i < 3) { v /= 1024; i++; } return v.toFixed(1) + u[i]; };
const stxt = (s) => ({ pending: '待确认', transferring: '传输中', paused: '已暂停', done: '已完成', failed: '失败', rejected: '已拒绝' }[s] || s);

// 连 WS 看任务进度
const ws = new WebSocket(`ws://${location.host}/ws?t=${token}`);
const taskMap = {};
ws.onmessage = (e) => {
  const msg = JSON.parse(e.data);
  if (msg.type === 'task') { taskMap[msg.data.id] = msg.data; render(); }
};

q('#picker').onchange = () => {
  const n = q('#picker').files.length;
  q('#picked').textContent = n ? `已选 ${n} 个文件` : '';
};

q('#sendBtn').onclick = async () => {
  const files = q('#picker').files;
  if (!files.length) { alert('先点上面选择文件'); return; }
  const defs = [...files].map((f, i) => ({ id: `m${Date.now()}_${i}`, name: f.name, relPath: f.name, totalBytes: f.size }));
  try {
    await fetch(`/api/offer?t=${token}`, {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ peer: '手机', files: defs }),
    });
    for (let i = 0; i < files.length; i++) { await uploadOne(files[i], defs[i].id); }
  } catch (err) {
    alert('发送出错: ' + err);
  }
};

async function uploadOne(file, id) {
  let offset = 0;
  try {
    const r = await fetch(`/api/upload/status?id=${id}&t=${token}`);
    if (r.ok) { offset = (await r.json()).offset || 0; }
  } catch (_) {}
  await fetch(`/api/upload?id=${id}&t=${token}`, {
    method: 'PUT',
    headers: { 'Content-Range': `bytes ${offset}-/${file.size}` },
    body: file.slice(offset),
  });
}

function render() {
  const ul = q('#tasks');
  const list = Object.values(taskMap);
  if (!list.length) { ul.innerHTML = '<li class="empty">还没有任务</li>'; return; }
  ul.innerHTML = '';
  list.forEach(t => {
    const pct = t.totalBytes ? Math.floor(t.transferredBytes / t.totalBytes * 100) : 0;
    const li = document.createElement('li');
    li.className = 'task';
    li.innerHTML = `<div class="trow"><b>${t.name}</b><span class="badge ${t.status}">${stxt(t.status)}</span></div>
      <div class="bar"><i style="width:${pct}%"></i></div>
      <div class="tmeta"><span>${pct}%</span><span>${t.speed ? '⚡ ' + fmt(t.speed) + '/s' : ''}</span></div>`;
    ul.appendChild(li);
  });
}

fetch('/api/health').then(r => r.json()).then(d => { q('#host').textContent = d.name; }).catch(() => {});
