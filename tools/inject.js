// inject.js —— 通过 CDP 往豆包主窗口注入悬浮球（一次性验证版）
// 用法：node inject.js [--shot out.png]

const CDP_LIST = 'http://127.0.0.1:9222/json/list';

/* 注入到页面里的 DOM 构建函数（会被序列化后执行） */
function buildWidget() {
  const OLD = document.getElementById('dbx-root');
  if (OLD) OLD.remove();

  const root = document.createElement('div');
  root.id = 'dbx-root';
  root.style.cssText = [
    'position:fixed', 'right:14px', 'top:38%', 'z-index:2147483647',
    'font-family:-apple-system,"Segoe UI","Microsoft YaHei",sans-serif',
    'user-select:none', 'pointer-events:none'
  ].join(';');

  // 悬浮球
  const ball = document.createElement('div');
  ball.style.cssText = [
    'width:44px', 'height:44px', 'border-radius:22px',
    'background:#1f2023', 'border:1px solid rgba(255,255,255,.14)',
    'box-shadow:0 4px 16px rgba(0,0,0,.4)',
    'display:flex', 'align-items:center', 'justify-content:center',
    'cursor:pointer', 'pointer-events:auto',
    'color:#f5c451', 'font-size:15px', 'font-weight:600'
  ].join(';');
  ball.textContent = '75%';

  // 面板
  const panel = document.createElement('div');
  panel.style.cssText = [
    'position:absolute', 'right:56px', 'top:0',
    'width:300px', 'background:#1f2023',
    'border:1px solid rgba(255,255,255,.12)', 'border-radius:10px',
    'box-shadow:0 8px 28px rgba(0,0,0,.45)',
    'padding:10px 12px', 'opacity:0', 'transform:translateX(8px)',
    'transition:opacity .16s ease, transform .16s ease',
    'pointer-events:none'
  ].join(';');

  const title = document.createElement('div');
  title.style.cssText = 'color:#e8e8ea;font-size:12px;font-weight:600;margin-bottom:8px;letter-spacing:.5px';
  title.textContent = '豆包用量';
  panel.appendChild(title);

  const rows = [
    ['模型额度', '75% · 7d'],
    ['Token 累计', '413.6K'],
    ['输出速度', '-- tok/s'],
    ['上下文', '--']
  ];
  for (const [k, v] of rows) {
    const row = document.createElement('div');
    row.style.cssText = 'display:flex;justify-content:space-between;padding:5px 0;border-top:1px solid rgba(255,255,255,.06)';
    const l = document.createElement('span');
    l.style.cssText = 'color:#9a9aa2;font-size:12px';
    l.textContent = k;
    const r = document.createElement('span');
    r.style.cssText = 'color:#e8e8ea;font-size:12px;font-weight:600';
    r.textContent = v;
    row.appendChild(l);
    row.appendChild(r);
    panel.appendChild(row);
  }

  const wrap = document.createElement('div');
  wrap.style.cssText = 'position:relative;display:inline-block';

  ball.addEventListener('mouseenter', () => {
    panel.style.opacity = '1';
    panel.style.transform = 'translateX(0)';
    panel.style.pointerEvents = 'auto';
  });
  ball.addEventListener('mouseleave', () => {
    setTimeout(() => {
      if (!panel.matches(':hover')) {
        panel.style.opacity = '0';
        panel.style.transform = 'translateX(8px)';
        panel.style.pointerEvents = 'none';
      }
    }, 220);
  });
  panel.addEventListener('mouseleave', () => {
    panel.style.opacity = '0';
    panel.style.transform = 'translateX(8px)';
    panel.style.pointerEvents = 'none';
  });

  wrap.appendChild(ball);
  wrap.appendChild(panel);
  root.appendChild(wrap);
  document.documentElement.appendChild(root);

  return { ok: true, href: location.href };
}

async function main() {
  const shotIdx = process.argv.indexOf('--shot');
  const shotPath = shotIdx > -1 ? process.argv[shotIdx + 1] : null;

  const list = await (await fetch(CDP_LIST)).json();
  const page = list.find(t => t.type === 'page' && /doubao-chat\/chat/.test(t.url || ''));
  if (!page) {
    console.error('未找到豆包主聊天窗口，当前目标：');
    list.forEach(t => console.error(' -', t.type, t.url));
    process.exit(2);
  }
  console.log('目标页面:', page.title, '|', page.url);

  const ws = new WebSocket(page.webSocketDebuggerUrl);
  const pending = new Map();
  let seq = 0;

  const send = (method, params = {}) => new Promise((resolve, reject) => {
    const id = ++seq;
    pending.set(id, { resolve, reject });
    ws.send(JSON.stringify({ id, method, params }));
    setTimeout(() => {
      if (pending.has(id)) { pending.delete(id); reject(new Error('timeout: ' + method)); }
    }, 12000);
  });

  ws.addEventListener('message', ev => {
    let msg;
    try { msg = JSON.parse(ev.data); } catch { return; }
    if (msg.id && pending.has(msg.id)) {
      const { resolve, reject } = pending.get(msg.id);
      pending.delete(msg.id);
      msg.error ? reject(new Error(JSON.stringify(msg.error))) : resolve(msg.result);
    }
  });

  await new Promise((res, rej) => {
    ws.addEventListener('open', res, { once: true });
    ws.addEventListener('error', rej, { once: true });
  });

  await send('Runtime.enable');

  const expr = '(' + buildWidget.toString() + ')()';
  const r = await send('Runtime.evaluate', {
    expression: expr,
    returnByValue: true,
    awaitPromise: false
  });

  const val = r.result && r.result.value;
  console.log('注入结果:', JSON.stringify(val));
  if (r.exceptionDetails) {
    console.error('页面内异常:', JSON.stringify(r.exceptionDetails).slice(0, 400));
  }

  const check = await send('Runtime.evaluate', {
    expression: "!!document.getElementById('dbx-root')",
    returnByValue: true
  });
  console.log('DOM 存在:', check.result && check.result.value);

  if (shotPath) {
    const shot = await send('Page.captureScreenshot', { format: 'png' });
    const fs = require('fs');
    fs.writeFileSync(shotPath, Buffer.from(shot.data, 'base64'));
    console.log('截图已保存:', shotPath);
  }

  ws.close();
  process.exit(0);
}

main().catch(e => { console.error('失败:', e.message); process.exit(1); });
