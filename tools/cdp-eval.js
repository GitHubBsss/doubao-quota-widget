// cdp-eval.js —— 在豆包主聊天窗口执行一段 JS，打印返回值
// 用法：node cdp-eval.js "document.title"

const CDP_LIST = 'http://127.0.0.1:9222/json/list';

async function main() {
  const expr = process.argv[2];
  if (!expr) { console.error('缺少表达式参数'); process.exit(2); }

  const list = await (await fetch(CDP_LIST)).json();
  const page = list.find(t => t.type === 'page' && /doubao-chat\/chat/.test(t.url || ''));
  if (!page) { console.error('未找到豆包主聊天窗口'); process.exit(2); }

  const ws = new WebSocket(page.webSocketDebuggerUrl);
  const pending = new Map();
  let seq = 0;

  const send = (method, params = {}) => new Promise((resolve, reject) => {
    const id = ++seq;
    pending.set(id, { resolve, reject });
    ws.send(JSON.stringify({ id, method, params }));
    setTimeout(() => { if (pending.has(id)) { pending.delete(id); reject(new Error('timeout')); } }, 8000);
  });

  ws.addEventListener('message', ev => {
    let m; try { m = JSON.parse(ev.data); } catch { return; }
    if (m.id && pending.has(m.id)) {
      const p = pending.get(m.id); pending.delete(m.id);
      m.error ? p.reject(new Error(JSON.stringify(m.error))) : p.resolve(m.result);
    }
  });

  await new Promise((res, rej) => {
    ws.addEventListener('open', res, { once: true });
    ws.addEventListener('error', rej, { once: true });
  });

  const si = process.argv.indexOf('--shot');
  const shotPath = si > -1 ? process.argv[si + 1] : null;

  const r = await send('Runtime.evaluate', { expression: expr, returnByValue: true });
  if (r.exceptionDetails) console.error('异常:', JSON.stringify(r.exceptionDetails).slice(0, 300));
  else console.log(JSON.stringify(r.result && r.result.value));

  if (shotPath) {
    const shot = await send('Page.captureScreenshot', { format: 'png' });
    require('fs').writeFileSync(shotPath, Buffer.from(shot.data, 'base64'));
    console.log('截图:', shotPath);
  }

  ws.close();
  process.exit(0);
}

main().catch(e => { console.error('失败:', e.message); process.exit(1); });
