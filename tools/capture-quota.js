// capture-quota.js —— attach 到额度管理页，抓它加载时的接口请求
// 用法：node capture-quota.js [过滤关键词] [等待毫秒]

const MATCH_URL = /member\/quota-management/;
const KEYWORD = process.argv[2] || 'quota|benefit|balance|credit|subscri|entitle|sku|member|vip|usage';
const WAIT_MS = parseInt(process.argv[3] || '9000', 10);

async function main() {
  const list = await (await fetch('http://127.0.0.1:9222/json/list')).json();
  const target = list.find(t => MATCH_URL.test(t.url || ''));
  if (!target) { console.error('未找到额度管理页，请先在豆包打开“设置 → 订阅与额度管理”'); process.exit(2); }
  console.error('目标:', target.title, '\nURL:', target.url.slice(0, 120));

  const ws = new WebSocket(target.webSocketDebuggerUrl);
  const pending = new Map();
  let seq = 0;
  const send = (method, params = {}) => new Promise((resolve, reject) => {
    const id = ++seq; pending.set(id, { resolve, reject });
    ws.send(JSON.stringify({ id, method, params }));
    setTimeout(() => { if (pending.has(id)) { pending.delete(id); reject(new Error(method + ' timeout')); } }, 15000);
  });

  const reqMap = new Map();      // requestId -> {url, method, postData, type}
  const hits = [];               // 命中的 JSON 接口

  ws.addEventListener('message', async ev => {
    let m; try { m = JSON.parse(ev.data); } catch { return; }
    if (m.id && pending.has(m.id)) {
      const p = pending.get(m.id); pending.delete(m.id);
      m.error ? p.reject(new Error(JSON.stringify(m.error))) : p.resolve(m.result);
      return;
    }
    const { method, params } = m;
    if (method === 'Network.requestWillBeSent') {
      reqMap.set(params.requestId, {
        url: params.request.url, method: params.request.method,
        postData: params.request.postData, type: params.type
      });
    } else if (method === 'Network.responseReceived') {
      const info = reqMap.get(params.requestId) || { url: params.response.url, method: '?' };
      const mime = params.response.mimeType || '';
      const re = new RegExp(KEYWORD, 'i');
      if (info.url && (mime.includes('json') || re.test(info.url))) {
        hits.push({ requestId: params.requestId, ...info, status: params.response.status, mime });
      }
    }
  });

  await new Promise((res, rej) => {
    ws.addEventListener('open', res, { once: true });
    ws.addEventListener('error', rej, { once: true });
  });

  await send('Network.enable');
  await send('Runtime.enable');
  // iframe 目标不允许 Page.reload，改用页面内 location.reload()
  await send('Runtime.evaluate', { expression: 'location.reload()' });
  await new Promise(r => setTimeout(r, WAIT_MS));

  const seen = new Map();
  for (const h of hits) {
    if (seen.has(h.url)) continue;
    seen.set(h.url, h);
  }

  console.log('\n=== 命中接口 ' + seen.size + ' 条 ===');
  for (const [url, h] of seen) {
    const body = h.body;
    let text = '';
    try {
      const r = await send('Network.getResponseBody', { requestId: h.requestId }).catch(() => null);
      if (r && r.body) text = r.base64Encoded ? Buffer.from(r.body, 'base64').toString('utf8') : r.body;
    } catch { }
    console.log('\n---');
    console.log('[' + h.method + '] ' + h.status + ' ' + (h.mime || ''));
    console.log(url);
    if (h.postData) console.log('POST: ' + String(h.postData).slice(0, 600));
    if (text) console.log('RESP: ' + text.slice(0, 1200));
  }

  ws.close();
  process.exit(0);
}

main().catch(e => { console.error('失败:', e.message); process.exit(1); });
