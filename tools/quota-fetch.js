// quota-fetch.js —— 在额度管理页上下文里直接调额度接口，看是否需要签名
const MATCH_URL = /member\/quota-management/;

const API = 'https://www.doubao.com/alice/commerce/sale/subscription/overview/?' +
  'aid=' + (process.env.DOUBAO_AID || '0') +
  '&device_platform=web&doubao_device_platform=web&language=zh&region=CN' +
  '&sys_region=CN&samantha_web=1&web_platform=desktop&use-olympus-account=1&pc_version=2.38.12';

const EXPR = `
(async () => {
  try {
    const r = await fetch(${JSON.stringify(API)}, {
      method: 'POST',
      credentials: 'include',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ product_line: 'membership' })
    });
    const t = await r.text();
    return 'HTTP ' + r.status + ' :: ' + t;
  } catch (e) { return 'ERR ' + e.message; }
})()`;

async function main() {
  const list = await (await fetch('http://127.0.0.1:9222/json/list')).json();
  const t = list.find(x => MATCH_URL.test(x.url || ''))
         || list.find(x => /^https:\/\/www\.doubao\.com\//.test(x.url || ''));
  if (!t) { console.error('没有可用的 doubao.com 上下文'); process.exit(2); }
  console.error('使用上下文:', t.url.slice(0, 90));

  const ws = new WebSocket(t.webSocketDebuggerUrl);
  const pending = new Map(); let seq = 0;
  const send = (m, p = {}) => new Promise((res, rej) => {
    const id = ++seq; pending.set(id, { res, rej });
    ws.send(JSON.stringify({ id, method: m, params: p }));
    setTimeout(() => { if (pending.has(id)) { pending.delete(id); rej(new Error(m + ' timeout')); } }, 20000);
  });
  ws.addEventListener('message', ev => {
    let m; try { m = JSON.parse(ev.data); } catch { return; }
    if (m.id && pending.has(m.id)) {
      const p = pending.get(m.id); pending.delete(m.id);
      m.error ? p.rej(new Error(JSON.stringify(m.error))) : p.res(m.result);
    }
  });
  await new Promise((res, rej) => { ws.addEventListener('open', res, { once: true }); ws.addEventListener('error', rej, { once: true }); });

  const r = await send('Runtime.evaluate', { expression: EXPR, awaitPromise: true, returnByValue: true });
  const v = r.result && r.result.value ? String(r.result.value) : '';
  // 落盘完整响应，便于核对口径
  const idx = v.indexOf(':: ');
  if (idx > -1) {
    require('fs').writeFileSync('quota.json', v.slice(idx + 3), 'utf8');
    console.log('HTTP:', v.slice(0, idx), '-> quota.json', v.length, 'chars');
  } else {
    console.log(v.slice(0, 800));
  }
  ws.close(); process.exit(0);
}
main().catch(e => { console.error('失败:', e.message); process.exit(1); });
