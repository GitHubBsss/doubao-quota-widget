// capture-stream.js —— 抓豆包主窗口的网络流，看回复里有没有 usage / cached token
// 输出 stream-dump.jsonl，每行 {url, method, status, len, body}

const LIST = 'http://127.0.0.1:9222/json/list';
const OUT = 'stream-dump.jsonl';
const DURATION_MS = 20 * 60 * 1000;
const MATCH = /chat|completion|conversation|message|sse|stream|reply|generate/i;

async function main() {
  const list = await (await fetch(LIST)).json();
  const page = list.find(t => t.type === 'page' && /doubao-chat\/chat/.test(t.url || ''));
  if (!page) { console.error('未找到聊天页'); process.exit(2); }

  const ws = new WebSocket(page.webSocketDebuggerUrl);
  const pending = new Map(); let seq = 0;
  const send = (m, p = {}) => new Promise((res, rej) => {
    const id = ++seq; pending.set(id, { res, rej });
    ws.send(JSON.stringify({ id, method: m, params: p }));
    setTimeout(() => { if (pending.has(id)) { pending.delete(id); rej(new Error(m + ' timeout')); } }, 20000);
  });

  const reqs = new Map();
  const fs = require('fs');

  ws.addEventListener('message', async ev => {
    let m; try { m = JSON.parse(ev.data); } catch { return; }
    if (m.id && pending.has(m.id)) {
      const p = pending.get(m.id); pending.delete(m.id);
      m.error ? p.rej(new Error(JSON.stringify(m.error))) : p.res(m.result);
      return;
    }
    const { method, params } = m;
    if (method === 'Network.requestWillBeSent') {
      const t = params.type;
      if ((t === 'XHR' || t === 'Fetch' || t === 'EventSource' || t === 'Other') && MATCH.test(params.request.url)) {
        reqs.set(params.requestId, {
          url: params.request.url, method: params.request.method,
          type: t, post: params.request.postData
        });
      }
    } else if (method === 'Network.loadingFinished') {
      const info = reqs.get(params.requestId);
      if (!info) return;
      reqs.delete(params.requestId);
      try {
        const r = await send('Network.getResponseBody', { requestId: params.requestId });
        const text = r.base64Encoded ? Buffer.from(r.body, 'base64').toString('utf8') : r.body;
        fs.appendFileSync(OUT, JSON.stringify({
          url: info.url, method: info.method, type: info.type,
          len: text.length, post: (info.post || '').slice(0, 500),
          body: text.slice(-4000)
        }) + '\n');
      } catch (e) {
        fs.appendFileSync(OUT, JSON.stringify({ url: info.url, err: e.message }) + '\n');
      }
    }
  });

  await new Promise((res, rej) => { ws.addEventListener('open', res, { once: true }); ws.addEventListener('error', rej, { once: true }); });
  await send('Network.enable');
  setTimeout(() => { try { ws.close(); } catch { } process.exit(0); }, DURATION_MS);
}

main().catch(e => { console.error('失败:', e.message); process.exit(1); });
