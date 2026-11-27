/* widget.js —— 注入到豆包主窗口的悬浮球与额度面板
 * 由 doubao-widget-daemon.ps1 通过 CDP 执行；data 为 JSON：
 *   { badge, title, rows:[[label,value],...], trend:[累计消耗点...], week:[{d,v}...],
 *     alert:{text,level}|null, weekRows, openUrl, scale, left, top }
 * 刷新时由守护调用 window.__dbxWidgetUpdate(data) 原地更新，不重建 DOM
 * 面板里的「会话上下文 / 本轮速度」由本脚本直接读聊天 DOM 估算（不发请求）
 */

function dbxWidget(data) {
  data = data || {};

  var OLD = document.getElementById('dbx-root');
  if (OLD) OLD.remove();

  var FONT = '-apple-system,"Segoe UI","Microsoft YaHei",sans-serif';

  /* ---------- 配色：跟随系统深浅色 ---------- */
  var LIGHT = !!(window.matchMedia && window.matchMedia('(prefers-color-scheme: light)').matches);
  var P = LIGHT ? {
    ballBg: '#ffffff', ballBorder: 'rgba(0,0,0,.14)',
    panelBg: '#ffffff', panelBorder: 'rgba(0,0,0,.10)',
    shadow: '0 8px 28px rgba(0,0,0,.20)', ballShadow: '0 4px 14px rgba(0,0,0,.18)',
    track: 'rgba(0,0,0,.14)', text: '#1f2023', dim: '#70707a',
    line: 'rgba(0,0,0,.07)', accent: '#c58f18', sub: '#5d5d66'
  } : {
    ballBg: '#1f2023', ballBorder: 'rgba(255,255,255,.14)',
    panelBg: '#1f2023', panelBorder: 'rgba(255,255,255,.12)',
    shadow: '0 8px 28px rgba(0,0,0,.45)', ballShadow: '0 4px 16px rgba(0,0,0,.4)',
    track: 'rgba(255,255,255,.14)', text: '#e8e8ea', dim: '#9a9aa2',
    line: 'rgba(255,255,255,.06)', accent: '#f5c451', sub: '#c9c9cf'
  };

  var SCALE = Number(data.scale);
  if (!(SCALE >= 0.7 && SCALE <= 1.5)) SCALE = 1;

  /* 位置：优先用守护进程存下来的坐标，其次本地缓存，最后才是默认右上 */
  var POS = null;
  if (data.left != null && data.top != null) {
    POS = { left: data.left, top: data.top };
  } else {
    try { POS = JSON.parse(localStorage.getItem('dbxBallPos') || 'null'); } catch (e) { POS = null; }
  }

  var root = document.createElement('div');
  root.id = 'dbx-root';
  var rootCss = [
    'position:fixed',
    'z-index:2147483647',
    'font-family:' + FONT,
    'user-select:none',
    'pointer-events:none'
  ];
  if (POS) {
    rootCss.push('left:' + Math.round(POS.left) + 'px', 'top:' + Math.round(POS.top) + 'px');
  } else {
    rootCss.push('right:' + (data.right != null ? data.right : 14) + 'px', 'top:' + (data.top != null ? data.top : 38) + '%');
  }
  root.style.cssText = rootCss.join(';');

  /* ---------- 悬浮球：环形额度表 ---------- */
  var SVGNS = 'http://www.w3.org/2000/svg';

  var ball = document.createElement('div');
  ball.style.cssText = [
    'position:relative',
    'width:56px', 'height:56px', 'border-radius:28px', 'box-sizing:border-box',
    'background:' + P.ballBg,
    'border:1px solid ' + P.ballBorder,
    'box-shadow:' + P.ballShadow,
    'cursor:pointer', 'pointer-events:auto',
    'display:flex', 'align-items:center', 'justify-content:center',
    'transition:width .18s ease,height .18s ease'
  ].join(';');
  ball.title = '豆包额度';

  var ballSvg = document.createElementNS(SVGNS, 'svg');
  ballSvg.style.cssText = 'position:absolute;left:0;top:0;pointer-events:none';
  ball.appendChild(ballSvg);

  var centerText = document.createElement('div');
  centerText.style.cssText = [
    'position:relative', 'z-index:2',
    'color:' + P.accent, 'font-weight:600',
    'font-size:13px', 'line-height:1', 'letter-spacing:-.3px',
    'white-space:nowrap', 'pointer-events:none'
  ].join(';');
  ball.appendChild(centerText);

  /* 低额度时球体外圈呼吸提示 */
  var pulse = document.createElement('div');
  pulse.style.cssText = [
    'position:absolute', 'inset:-4px', 'border-radius:50%',
    'box-shadow:0 0 0 0 rgba(255,107,91,.55)',
    'opacity:0', 'pointer-events:none', 'transition:opacity .2s'
  ].join(';');
  ball.appendChild(pulse);
  var pulseTimer = setInterval(function () {
    if (pulse.style.opacity !== '1') return;
    var t = Date.now() % 1600;
    var p = t / 1600;
    pulse.style.transform = 'scale(' + (1 + p * 0.12) + ')';
    pulse.style.boxShadow = '0 0 0 ' + (2 + p * 8).toFixed(1) + 'px rgba(255,107,91,' + (0.45 * (1 - p)).toFixed(2) + ')';
  }, 120);

  function ringEl(cx, cy, r, stroke, color, pct) {
    var NS = 'http://www.w3.org/2000/svg';
    var c = document.createElementNS(NS, 'circle');
    c.setAttribute('cx', cx);
    c.setAttribute('cy', cy);
    c.setAttribute('r', r);
    c.setAttribute('fill', 'none');
    c.setAttribute('stroke', color);
    c.setAttribute('stroke-width', stroke);
    if (pct == null) {
      c.setAttribute('opacity', '.9');
    } else {
      var C = 2 * Math.PI * r;
      var p = Math.max(0, Math.min(100, pct));
      c.setAttribute('stroke-dasharray', (C * p / 100).toFixed(2) + ' ' + C.toFixed(2));
      c.setAttribute('stroke-dashoffset', (C * 0.25).toFixed(2));
      c.setAttribute('stroke-linecap', 'round');
    }
    return c;
  }

  function ringColor(pct) {
    if (pct <= 20) return '#ff6b5b';
    if (pct <= 50) return '#f7a14b';
    return P.accent;
  }

  function renderGauge(g) {
    g = g || {};
    var rings = (g.rings && g.rings.length) ? g.rings.slice(0, 2) : [{ pct: 100 }];
    var size = (rings.length > 1 ? 62 : 56) * SCALE;

    ball.style.width = size + 'px';
    ball.style.height = size + 'px';
    ball.style.borderRadius = (size / 2) + 'px';

    ballSvg.setAttribute('width', size);
    ballSvg.setAttribute('height', size);
    ballSvg.setAttribute('viewBox', '0 0 ' + size + ' ' + size);
    ballSvg.textContent = '';

    var cx = size / 2, cy = size / 2;

    for (var i = 0; i < rings.length; i++) {
      var stroke = (rings.length === 1 ? 4.4 : (i === 0 ? 3.6 : 2.8)) * SCALE;
      var r = cx - 3.5 * SCALE - stroke / 2 - i * (stroke + 3.2 * SCALE);
      if (r < 4) continue;

      ballSvg.appendChild(ringEl(cx, cy, r, stroke, P.track, null));

      var pct = Number(rings[i].pct);
      if (isNaN(pct)) pct = 0;
      var color = rings[i].color || ringColor(pct);
      ballSvg.appendChild(ringEl(cx, cy, r, stroke, color, pct));
    }

    var txt = g.center || '';
    centerText.textContent = txt;
    var len = txt.length;
    var base = rings.length > 1 ? (len > 5 ? 10 : 11) : (len > 6 ? 11 : (len > 4 ? 12 : 13));
    centerText.style.fontSize = (base * SCALE).toFixed(1) + 'px';
  }

  renderGauge(data.gauge);

  function setBadge(text) {
    /* 兼容旧数据：无 gauge 时退化成文字胶囊 */
    if (text) { renderGauge({ center: text, rings: [{ pct: 100 }] }); }
  }

  /* ---------- 展开面板 ---------- */
  var PW = Math.round(318 * Math.max(0.9, SCALE));

  var panel = document.createElement('div');
  panel.style.cssText = [
    'position:absolute', 'right:56px', 'top:0',
    'width:' + PW + 'px',
    'background:' + P.panelBg,
    'border:1px solid ' + P.panelBorder,
    'border-radius:10px',
    'box-shadow:' + P.shadow,
    'padding:10px 12px 10px',
    'max-height:calc(100vh - 70px)',
    'overflow-y:auto',
    'box-sizing:border-box',
    'opacity:0', 'transform:translateX(8px)',
    'transition:opacity .16s ease,transform .16s ease',
    'pointer-events:none'
  ].join(';');

  var title = document.createElement('div');
  title.style.cssText = 'color:' + P.text + ';font-size:12px;font-weight:600;margin-bottom:8px;letter-spacing:.5px;display:flex;justify-content:space-between;align-items:center';
  var titleL = document.createElement('span');
  titleL.textContent = data.title || '豆包额度';
  title.appendChild(titleL);

  /* 低额度警示条 */
  var banner = document.createElement('div');
  banner.style.cssText = [
    'display:none', 'margin:-2px 0 8px',
    'padding:6px 8px', 'border-radius:6px',
    'background:rgba(255,107,91,.14)', 'color:#ff6b5b',
    'font-size:11px', 'font-weight:600', 'line-height:1.35'
  ].join(';');
  panel.appendChild(banner);
  panel.appendChild(title);

  var rowsBox = document.createElement('div');

  function rowNode(label, value, color) {
    var row = document.createElement('div');
    row.style.cssText = 'display:flex;justify-content:space-between;align-items:center;gap:12px;' +
      'padding:6px 0;border-top:1px solid ' + P.line;

    var l = document.createElement('span');
    l.style.cssText = 'color:' + P.dim + ';font-size:12px;flex:none';
    l.textContent = label;

    var r = document.createElement('span');
    r.style.cssText = 'color:' + (color || P.text) + ';font-size:12px;font-weight:600;text-align:right';
    r.textContent = value;

    row.appendChild(l);
    row.appendChild(r);
    return row;
  }

  function renderRows(rows) {
    rowsBox.textContent = '';
    (rows || []).forEach(function (pair) {
      rowsBox.appendChild(rowNode(pair[0], pair[1], pair[2]));
    });
  }

  renderRows(data.rows);
  panel.appendChild(rowsBox);

  /* ---------- 今日消耗趋势（细折线） ---------- */
  var trendBox = document.createElement('div');
  trendBox.style.cssText = [
    'margin-top:8px', 'padding-top:8px',
    'border-top:1px solid ' + P.line,
    'display:none'
  ].join(';');

  var trendCap = document.createElement('div');
  trendCap.style.cssText = 'color:' + P.dim + ';font-size:11px;margin-bottom:2px';
  trendCap.textContent = '今日消耗趋势';

  var svg = document.createElementNS(SVGNS, 'svg');
  svg.setAttribute('height', '28');
  svg.style.cssText = 'display:block;width:100%;overflow:visible';

  var poly = document.createElementNS(SVGNS, 'polyline');
  poly.setAttribute('fill', 'none');
  poly.setAttribute('stroke', P.accent);
  poly.setAttribute('stroke-width', '1.4');
  poly.setAttribute('stroke-linecap', 'round');
  poly.setAttribute('opacity', '.9');
  svg.appendChild(poly);

  trendBox.appendChild(trendCap);
  trendBox.appendChild(svg);
  panel.appendChild(trendBox);

  function renderTrend(vals) {
    if (!vals || vals.length < 2) { trendBox.style.display = 'none'; return; }
    trendBox.style.display = 'block';

    var W = 292, H = 28, PAD = 3;
    svg.setAttribute('viewBox', '0 0 ' + W + ' ' + H);

    var max = 0, i;
    for (i = 0; i < vals.length; i++) { if (vals[i] > max) max = vals[i]; }
    var base = vals[0] || 0;
    var span = max - base;

    var pts = [];
    for (i = 0; i < vals.length; i++) {
      var x = PAD + i * (W - 2 * PAD) / (vals.length - 1);
      var y = (span <= 0)
        ? H / 2
        : (H - PAD - ((vals[i] - base) / span) * (H - 2 * PAD));
      pts.push(x.toFixed(1) + ',' + y.toFixed(1));
    }
    poly.setAttribute('points', pts.join(' '));
  }

  renderTrend(data.trend);

  /* ---------- 近 7 天用量（柱状，读到就用） ---------- */
  var weekBox = document.createElement('div');
  weekBox.style.cssText = [
    'margin-top:8px', 'padding-top:8px',
    'border-top:1px solid ' + P.line,
    'display:none'
  ].join(';');

  var weekCap = document.createElement('div');
  weekCap.style.cssText = 'color:' + P.dim + ';font-size:11px;margin-bottom:6px';
  weekCap.textContent = '近 7 天消耗';
  weekBox.appendChild(weekCap);

  var weekBars = document.createElement('div');
  weekBars.style.cssText = 'display:flex;gap:4px;align-items:flex-end;height:46px';
  weekBox.appendChild(weekBars);

  panel.appendChild(weekBox);

  function renderWeek(list) {
    if (!list || !list.length) { weekBox.style.display = 'none'; return; }
    weekBox.style.display = 'block';
    weekBars.textContent = '';

    var max = 0;
    list.forEach(function (x) { if (+x.v > max) max = +x.v; });
    if (max <= 0) max = 1;

    list.forEach(function (x) {
      var col = document.createElement('div');
      col.style.cssText = 'flex:1;display:flex;flex-direction:column;align-items:center;justify-content:flex-end;gap:3px';

      var num = document.createElement('div');
      num.style.cssText = 'font-size:9px;color:' + P.dim + ';line-height:1';
      num.textContent = (+x.v > 0 ? String(x.v) : '');

      var bar = document.createElement('div');
      var h = Math.max(2, Math.round(32 * (+x.v / max)));
      bar.style.cssText = 'width:100%;height:' + h + 'px;border-radius:3px;background:' +
        (+x.v > 0 ? P.accent : P.track) + ';opacity:' + (+x.v > 0 ? '.85' : '.5');

      var day = document.createElement('div');
      day.style.cssText = 'font-size:9px;color:' + P.dim + ';line-height:1';
      day.textContent = x.d;

      col.appendChild(num);
      col.appendChild(bar);
      col.appendChild(day);
      weekBars.appendChild(col);
    });
  }

  renderWeek(data.week);

  /* ---------- 会话统计（读聊天 DOM，纯估算） ---------- */
  var liveBox = document.createElement('div');
  liveBox.style.cssText = 'margin-top:8px;padding-top:8px;border-top:1px solid ' + P.line + ';display:none';
  panel.insertBefore(liveBox, trendBox);

  var stat = {
    lastLen: -1, growAt: 0, startAt: 0, startLen: 0, streaming: false, turns: []
  };

  function findList() {
    var ml = document.querySelector('[class*="message-list"]');
    return ml || null;
  }

  function listRows(ml) {
    var arr = [];
    var nodes = ml.querySelectorAll('div');
    for (var i = 0; i < nodes.length; i++) {
      var c = String(nodes[i].className || '');
      if (c.indexOf('flex flex-row w-full') === 0) arr.push(nodes[i]);
    }
    return arr;
  }

  function tick() {
    var ml = findList();
    if (!ml) { liveBox.style.display = 'none'; return; }

    var rows = listRows(ml);
    if (!rows.length) { liveBox.style.display = 'none'; return; }

    var chars = 0, msgs = 0, lastAssistant = null, lastLen = 0;
    for (var i = 0; i < rows.length; i++) {
      var t = (rows[i].innerText || '');
      chars += t.length;
      msgs++;
      if (String(rows[i].className).indexOf('justify-end') < 0) {
        lastAssistant = rows[i];
        lastLen = t.length;
      }
    }

    /* 流式增量 → 本轮速度 */
    var now = Date.now();
    if (lastAssistant) {
      if (stat.lastLen >= 0 && lastLen > stat.lastLen) {
        if (!stat.streaming) {
          stat.streaming = true;
          stat.startAt = now;
          stat.startLen = stat.lastLen;
        }
        stat.growAt = now;
      } else if (stat.streaming && now - stat.growAt > 1400) {
        var n = lastLen - stat.startLen;
        var sec = (stat.growAt - stat.startAt) / 1000;
        if (n > 2 && sec > 0.4) {
          stat.turns.push({ c: n, s: +(n / sec).toFixed(1), t: new Date().toLocaleTimeString('zh-CN', { hour: '2-digit', minute: '2-digit' }) });
          if (stat.turns.length > 5) stat.turns.shift();
        }
        stat.streaming = false;
      }
      stat.lastLen = lastLen;
    }

    var tok = Math.round(chars / 1.55);
    var liveRows = [
      ['会话上下文', msgs + ' 条 · ' + fmtK(chars) + ' 字 ≈ ' + fmtK(tok) + ' tok'],
      ['本轮输出', stat.streaming ? '生成中…' : (stat.turns.length ? (fmtK(stat.turns[stat.turns.length - 1].c) + ' 字 · ' + stat.turns[stat.turns.length - 1].s + ' 字/秒') : '—')]
    ];

    liveBox.textContent = '';
    liveBox.style.display = 'block';
    liveRows.forEach(function (p) { liveBox.appendChild(rowNode(p[0], p[1], P.sub)); });

    if (stat.turns.length > 1) {
      var hist = document.createElement('div');
      hist.style.cssText = 'color:' + P.dim + ';font-size:10px;line-height:1.6;padding-top:4px';
      hist.textContent = '最近 ' + stat.turns.length + ' 轮：' + stat.turns.map(function (x) { return x.t + ' ' + x.s; }).join(' · ');
      liveBox.appendChild(hist);
    }
  }

  function fmtK(n) {
    if (n >= 10000) return (n / 10000).toFixed(1) + '万';
    if (n >= 1000) return (n / 1000).toFixed(1) + 'k';
    return String(n);
  }

  /* 打开豆包时先把已有历史当成一轮，避免第一条消息速度算进整段上下文 */
  tick();
  setInterval(tick, 700);

  /* ---------- 悬停 ---------- */
  var wrap = document.createElement('div');
  wrap.style.cssText = 'position:relative;display:inline-block';

  var hideTimer = null;

  function show() {
    if (hideTimer) { clearTimeout(hideTimer); hideTimer = null; }
    panel.style.opacity = '1';
    panel.style.transform = 'translateX(0)';
    panel.style.pointerEvents = 'auto';

    /* 面板比下方空间高时，整体上移，避免底部超出窗口 */
    panel.style.top = '0px';
    var pr = panel.getBoundingClientRect(), rr = root.getBoundingClientRect();
    var over = (rr.top + pr.height + 8) - window.innerHeight;
    if (over > 0) panel.style.top = (-Math.ceil(over)) + 'px';
  }

  function hide(delay) {
    if (hideTimer) clearTimeout(hideTimer);
    hideTimer = setTimeout(function () {
      panel.style.opacity = '0';
      panel.style.transform = 'translateX(8px)';
      panel.style.pointerEvents = 'none';
      hideTimer = null;
    }, delay);
  }

  /* 面板朝向随球的位置翻转，避免贴边时展开到屏幕外 */
  function applyPanelSide(centerX) {
    var fromLeft = centerX < (window.innerWidth / 2);
    var gap = (ball.offsetWidth || 56) + 8;
    if (fromLeft) {
      panel.style.left = gap + 'px';
      panel.style.right = 'auto';
    } else {
      panel.style.right = gap + 'px';
      panel.style.left = 'auto';
    }
  }

  /* ---------- 拖动定位 ---------- */
  var drag = null;
  var dragged = false;

  ball.style.touchAction = 'none';
  ball.style.cursor = 'grab';

  ball.addEventListener('pointerdown', function (ev) {
    if (ev.button !== 0) return;
    var r = root.getBoundingClientRect();
    drag = { sx: ev.clientX, sy: ev.clientY, ox: r.left, oy: r.top, w: r.width, h: r.height };
    dragged = false;
    hide(0);
    try { ball.setPointerCapture(ev.pointerId); } catch (e) { }
    ball.style.cursor = 'grabbing';
  });

  ball.addEventListener('pointermove', function (ev) {
    if (!drag) return;
    var dx = ev.clientX - drag.sx;
    var dy = ev.clientY - drag.sy;
    if (Math.abs(dx) > 3 || Math.abs(dy) > 3) dragged = true;
    var nx = Math.max(0, Math.min(drag.ox + dx, window.innerWidth - drag.w));
    var ny = Math.max(0, Math.min(drag.oy + dy, window.innerHeight - drag.h));
    root.style.right = 'auto';
    root.style.left = nx + 'px';
    root.style.top = ny + 'px';
    applyPanelSide(nx + drag.w / 2);
  });

  function endDrag(ev) {
    if (!drag) return;
    drag = null;
    ball.style.cursor = 'grab';
    try { ball.releasePointerCapture(ev.pointerId); } catch (e) { }
    var r = root.getBoundingClientRect();
    var p = { left: Math.round(r.left), top: Math.round(r.top) };
    window.__dbxPos = p;
    try { localStorage.setItem('dbxBallPos', JSON.stringify(p)); } catch (e) { }
  }

  ball.addEventListener('pointerup', endDrag);
  ball.addEventListener('pointercancel', endDrag);

  ball.addEventListener('mouseenter', show);
  ball.addEventListener('mouseleave', function () { hide(220); });
  panel.addEventListener('mouseenter', function () { if (hideTimer) { clearTimeout(hideTimer); hideTimer = null; } });
  panel.addEventListener('mouseleave', function () { hide(120); });

  /* 双击打开额度管理页 */
  ball.addEventListener('dblclick', function () {
    if (dragged) { dragged = false; return; }
    var url = data.openUrl;
    if (!url) return;
    try { window.open(url, 'doubao_quota'); } catch (e) { }
  });

  wrap.appendChild(ball);
  wrap.appendChild(panel);
  root.appendChild(wrap);
  document.documentElement.appendChild(root);

  var r0 = root.getBoundingClientRect();
  applyPanelSide(r0.left + (ball.offsetWidth || 56) / 2);
  window.__dbxPos = { left: Math.round(r0.left), top: Math.round(r0.top) };

  /* ---------- 原地更新 ---------- */
  window.__dbxWidgetUpdate = function (d) {
    d = d || {};
    if (d.gauge) renderGauge(d.gauge);
    else if (typeof d.badge === 'string') setBadge(d.badge);
    if (typeof d.title === 'string') { titleL.textContent = d.title; }
    if (d.rows) renderRows(d.rows);
    if (d.trend) renderTrend(d.trend);
    if (d.week) renderWeek(d.week);
    if (d.alert && d.alert.text) {
      banner.style.display = 'block';
      banner.textContent = d.alert.text;
      pulse.style.opacity = '1';
    } else {
      banner.style.display = 'none';
      pulse.style.opacity = '0';
      pulse.style.transform = 'scale(1)';
    }
    if (d.openUrl) data.openUrl = d.openUrl;
    return true;
  };

  /* 首次也要应用 alert */
  window.__dbxWidgetUpdate({ alert: data.alert });

  return true;
}
