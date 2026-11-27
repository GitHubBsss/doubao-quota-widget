/* widget.js —— 注入到豆包主窗口的悬浮球与额度面板
 * 由 doubao-widget-daemon.ps1 通过 CDP 执行；data 为 JSON：
 *   { badge, title, rows:[[label,value],...], trend:[累计消耗点...], openUrl, right, top }
 * 刷新时由守护调用 window.__dbxWidgetUpdate(data) 原地更新，不重建 DOM
 */

function dbxWidget(data) {
  data = data || {};

  var OLD = document.getElementById('dbx-root');
  if (OLD) OLD.remove();

  var FONT = '-apple-system,"Segoe UI","Microsoft YaHei",sans-serif';

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

  /* ---------- 悬浮球：环形额度表（1 格 = 剩余额度；2 格 = 5 小时 + 周） ---------- */
  var SVGNS = 'http://www.w3.org/2000/svg';

  var ball = document.createElement('div');
  ball.style.cssText = [
    'position:relative',
    'width:56px', 'height:56px', 'border-radius:28px', 'box-sizing:border-box',
    'background:#1f2023',
    'border:1px solid rgba(255,255,255,.14)',
    'box-shadow:0 4px 16px rgba(0,0,0,.4)',
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
    'color:#f5c451', 'font-weight:600',
    'font-size:13px', 'line-height:1', 'letter-spacing:-.3px',
    'white-space:nowrap', 'pointer-events:none'
  ].join(';');
  ball.appendChild(centerText);

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
    return '#f5c451';
  }

  function renderGauge(g) {
    g = g || {};
    var rings = (g.rings && g.rings.length) ? g.rings.slice(0, 2) : [{ pct: 100 }];
    var size = rings.length > 1 ? 62 : 56;

    ball.style.width = size + 'px';
    ball.style.height = size + 'px';
    ball.style.borderRadius = (size / 2) + 'px';

    ballSvg.setAttribute('width', size);
    ballSvg.setAttribute('height', size);
    ballSvg.setAttribute('viewBox', '0 0 ' + size + ' ' + size);
    ballSvg.textContent = '';

    var cx = size / 2, cy = size / 2;

    for (var i = 0; i < rings.length; i++) {
      var stroke = rings.length === 1 ? 4.4 : (i === 0 ? 3.6 : 2.8);
      var r = cx - 3.5 - stroke / 2 - i * (stroke + 3.2);
      if (r < 4) continue;

      ballSvg.appendChild(ringEl(cx, cy, r, stroke, 'rgba(255,255,255,.14)', null));

      var pct = Number(rings[i].pct);
      if (isNaN(pct)) pct = 0;
      var color = rings[i].color || ringColor(pct);
      ballSvg.appendChild(ringEl(cx, cy, r, stroke, color, pct));
    }

    var txt = g.center || '';
    centerText.textContent = txt;
    var len = txt.length;
    centerText.style.fontSize = (rings.length > 1 ? (len > 5 ? '10px' : '11px') : (len > 6 ? '11px' : (len > 4 ? '12px' : '13px')));
  }

  renderGauge(data.gauge);

  function setBadge(text) {
    /* 兼容旧数据：无 gauge 时退化成文字胶囊 */
    if (text) { renderGauge({ center: text, rings: [{ pct: 100 }] }); }
  }

  /* ---------- 展开面板 ---------- */
  var panel = document.createElement('div');
  panel.style.cssText = [
    'position:absolute', 'right:56px', 'top:0',
    'width:318px',
    'background:#1f2023',
    'border:1px solid rgba(255,255,255,.12)',
    'border-radius:10px',
    'box-shadow:0 8px 28px rgba(0,0,0,.45)',
    'padding:10px 12px 10px',
    'opacity:0', 'transform:translateX(8px)',
    'transition:opacity .16s ease,transform .16s ease',
    'pointer-events:none'
  ].join(';');

  var title = document.createElement('div');
  title.style.cssText = 'color:#e8e8ea;font-size:12px;font-weight:600;margin-bottom:8px;letter-spacing:.5px';
  title.textContent = data.title || '豆包额度';
  panel.appendChild(title);

  var rowsBox = document.createElement('div');

  function renderRows(rows) {
    rowsBox.textContent = '';
    (rows || []).forEach(function (pair) {
      var row = document.createElement('div');
      row.style.cssText = 'display:flex;justify-content:space-between;align-items:center;gap:12px;' +
        'padding:6px 0;border-top:1px solid rgba(255,255,255,.06)';

      var l = document.createElement('span');
      l.style.cssText = 'color:#9a9aa2;font-size:12px;flex:none';
      l.textContent = pair[0];

      var r = document.createElement('span');
      r.style.cssText = 'color:#e8e8ea;font-size:12px;font-weight:600;text-align:right';
      r.textContent = pair[1];

      row.appendChild(l);
      row.appendChild(r);
      rowsBox.appendChild(row);
    });
  }

  renderRows(data.rows);
  panel.appendChild(rowsBox);

  /* ---------- 今日消耗趋势（细折线） ---------- */
  var trendBox = document.createElement('div');
  trendBox.style.cssText = [
    'margin-top:8px', 'padding-top:8px',
    'border-top:1px solid rgba(255,255,255,.06)',
    'display:none'
  ].join(';');

  var trendCap = document.createElement('div');
  trendCap.style.cssText = 'color:#9a9aa2;font-size:11px;margin-bottom:2px';
  trendCap.textContent = '今日消耗趋势';

  var SVGNS = 'http://www.w3.org/2000/svg';
  var svg = document.createElementNS(SVGNS, 'svg');
  svg.setAttribute('height', '28');
  svg.style.cssText = 'display:block;width:100%;overflow:visible';

  var poly = document.createElementNS(SVGNS, 'polyline');
  poly.setAttribute('fill', 'none');
  poly.setAttribute('stroke', '#f5c451');
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

  var wrap = document.createElement('div');
  wrap.style.cssText = 'position:relative;display:inline-block';

  var hideTimer = null;

  function show() {
    if (hideTimer) { clearTimeout(hideTimer); hideTimer = null; }
    panel.style.opacity = '1';
    panel.style.transform = 'translateX(0)';
    panel.style.pointerEvents = 'auto';
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

  /* ---------- 拖动定位：松手写 localStorage，并交给守护进程落盘 ---------- */
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

  /* 双击打开额度管理页（走豆包自带 webview 窗口） */
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

  /* ---------- 原地更新（供守护进程定时刷新数据） ---------- */
  window.__dbxWidgetUpdate = function (d) {
    d = d || {};
    if (d.gauge) renderGauge(d.gauge);
    else if (typeof d.badge === 'string') setBadge(d.badge);
    if (typeof d.title === 'string') title.textContent = d.title;
    if (d.rows) renderRows(d.rows);
    if (d.trend) renderTrend(d.trend);
    if (d.openUrl) data.openUrl = d.openUrl;
    return true;
  };

  return true;
}
