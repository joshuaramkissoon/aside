// "Try it here": point at a word (or select a phrase) and press ⌥ Space, as in the app.
// On touch: tap a word, or select a phrase and tap "Look up"; the answer opens in a bottom sheet.
// The answers are the model's saved replies (answers.js), parsed the way the app parses them.
// Nothing here touches the network.

(() => {
  const DATA = window.ASIDE_ANSWERS;
  const section = document.getElementById('try');
  if (!section || !DATA) return;

  const prose = section.querySelector('[data-prose]');
  const stage = section.querySelector('.try-stage');
  const terms = [...prose.querySelectorAll('.t')];
  const reduce = matchMedia('(prefers-reduced-motion: reduce)');
  const touch = matchMedia('(hover: none) and (pointer: coarse)');
  const narrow = () => innerWidth <= 560;
  const DOWNLOAD = 'https://github.com/joshuaramkissoon/aside/releases/latest';
  const ARR = '<svg class="arr" viewBox="0 0 12 12" aria-hidden="true"><path d="M2.5 1.5v4.2a2.3 2.3 0 0 0 2.3 2.3h5.7M7.8 5.3l2.7 2.7-2.7 2.7"/></svg>';
  const clamp = (v, lo, hi) => Math.max(lo, Math.min(hi, v));
  const esc = s => s.replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));

  function h(tag, cls, html) {
    const el = document.createElement(tag);
    if (cls) el.className = cls;
    if (html != null) el.innerHTML = html;
    return el;
  }

  // ---------- The app's answer format ----------

  // TERM / EXPANDS / KIND / GIST, "- " bullets, fenced code, then NEXT with "? " lines.
  // A follow-up has no TERM, and sometimes starts its gist without the GIST: label.
  function parse(raw) {
    const a = { term: '', expands: '', kind: '', gist: '', blocks: [], next: [] };
    let inNext = false, code = null, m;
    for (const line of raw.split('\n')) {
      const t = line.trim();
      if (code) {
        if (t.startsWith('```')) { a.blocks.push({ code: code.join('\n') }); code = null; } else code.push(line);
        continue;
      }
      if (t.startsWith('```')) { code = []; continue; }
      if (!t) continue;
      if ((m = t.match(/^TERM:\s*(.*)$/))) { a.term = m[1]; continue; }
      if ((m = t.match(/^EXPANDS:\s*(.*)$/))) { a.expands = m[1]; continue; }
      if ((m = t.match(/^KIND:\s*(.*)$/))) { a.kind = m[1]; continue; }
      if (/^NEXT:/.test(t)) { inNext = true; continue; }
      if (inNext) { if (t.startsWith('?')) a.next.push(t.slice(1).trim()); continue; }
      if ((m = t.match(/^GIST:\s*(.*)$/))) { a.gist = m[1]; continue; }
      if (/^[-•]\s+/.test(t)) { a.blocks.push({ bullet: t.replace(/^[-•]\s+/, '') }); continue; }
      if (!a.gist) a.gist = t; else a.blocks.push({ para: t });
    }
    return a;
  }

  // `code`, **bold**, *italic* and ==mark==.
  function inline(s) {
    return s.split(/(`[^`]+`)/).map(p => p.length > 1 && p[0] === '`' && p.endsWith('`')
      ? `<code>${esc(p.slice(1, -1))}</code>`
      : esc(p).replace(/\*\*(.+?)\*\*/g, '<strong>$1</strong>').replace(/(^|[^*\w])\*([^*\s][^*]*?)\*(?!\w)/g, '$1<em>$2</em>')
    ).join('').replace(/==(.+?)==/g, '<mark>$1</mark>');
  }
  const plain = s => s.replace(/==|\*\*|`/g, '');

  // "Least Recently Used" with the initials picked out.
  function expansion(text) {
    return plain(text).split(' ').map(w => /^[\p{Lu}\p{N}]/u.test(w) ? `<b>${esc(w[0])}</b>${esc(w.slice(1))}` : esc(w)).join(' ');
  }

  // Wrap each word in a span so it can arrive on its own.
  function split(el) {
    const walker = document.createTreeWalker(el, NodeFilter.SHOW_TEXT);
    const nodes = [];
    while (walker.nextNode()) nodes.push(walker.currentNode);
    for (const n of nodes) {
      const frag = document.createDocumentFragment();
      for (const p of n.textContent.match(/\s+|\S+\s*/g) || []) {
        if (!p.trim() && !n.parentElement.closest('mark')) { frag.append(p); continue; }
        frag.append(h('span', 'w', esc(p)));
      }
      n.replaceWith(frag);
    }
    return el;
  }

  // One turn as a flat list of units that stream in order: gist, rule, each bullet, code, paragraphs.
  function turnUnits(a, first) {
    const units = [], nodes = [];
    const gist = split(h('p', 'p-gist stream' + (first ? '' : ' p-gist-sm'), inline(a.gist)));
    nodes.push(gist);
    units.push(gist);
    let ul = null, ruled = !first;
    for (const b of a.blocks) {
      if (b.bullet) {
        if (!ul) {
          if (!ruled) { const rule = h('span', 'p-rule'); nodes.push(rule); units.push(rule); ruled = true; }
          ul = h('ul', 'p-bullets');
          nodes.push(ul);
        }
        const li = split(h('li', 'stream', inline(b.bullet)));
        ul.append(li);
        units.push(li);
      } else if (b.code) {
        ul = null;
        const pre = h('pre', 'p-pre');
        pre.textContent = b.code.replace(/\s+$/, '');
        nodes.push(pre); units.push(pre);
      } else {
        ul = null;
        const p = split(h('p', 'p-para stream', inline(b.para)));
        nodes.push(p); units.push(p);
      }
    }
    return { nodes, units };
  }

  // ---------- The panel ----------

  const wrap = h('div', 'panel-wrap try-wrap');
  wrap.hidden = true;
  wrap.innerHTML = `
    <div class="panel" role="dialog" aria-modal="false" aria-labelledby="try-title-term" tabindex="-1">
      <button class="p-grab" type="button" aria-label="Close"><i></i></button>
      <div class="p-body">
        <div class="p-eyebrow"><span class="p-app"></span><span class="p-snip"></span></div>
        <div class="p-title"><p class="p-term" id="try-title-term"></p><span class="p-kind"></span></div>
        <p class="p-exp"></p>
        <div class="p-thread"></div>
      </div>
      <div class="p-foot">
        <div class="p-sugs"><ol class="p-sug-set"></ol></div>
        <form class="p-input">
          ${ARR}
          <input class="p-field" type="text" placeholder="Ask a follow-up" aria-label="Ask a follow-up" autocomplete="off" spellcheck="false">
          <span class="p-pulse" aria-hidden="true"><i></i><i></i><i></i></span>
          <span class="p-esc" aria-hidden="true">esc</span>
        </form>
      </div>
    </div>`;
  stage.append(wrap);
  const panel = wrap.querySelector('.panel');
  const body = wrap.querySelector('.p-body');
  const snip = wrap.querySelector('.p-snip');
  const titleRow = wrap.querySelector('.p-title');
  const title = wrap.querySelector('.p-term');
  const kind = wrap.querySelector('.p-kind');
  const exp = wrap.querySelector('.p-exp');
  const thread = wrap.querySelector('.p-thread');
  const foot = wrap.querySelector('.p-foot');
  const sugsBox = wrap.querySelector('.p-sugs');
  const sugList = wrap.querySelector('.p-sug-set');
  const form = wrap.querySelector('.p-input');
  const field = wrap.querySelector('.p-field');
  const grab = wrap.querySelector('.p-grab');

  const pill = h('button', 'try-pill', 'Look up');
  pill.type = 'button';
  pill.hidden = true;
  stage.append(pill);

  const readLine = h('span', 'try-read');
  readLine.hidden = true;
  stage.append(readLine);

  let current = null;     // what's open: { key, text, el, range, selected }
  let gen = 0;            // bumps on every open/close, so stale timers stop
  let busy = false;
  let pending = [];       // suggestions this page can still answer: { q, raw }
  let returnFocus = null;
  let lastInput = 'mouse';
  let mouse = null;
  let H = 0;              // the panel's height once fully answered (for placing it)

  const sleep = (ms, g) => new Promise((res, rej) => setTimeout(() => (g === gen ? res() : rej(new Error('stale'))), ms));
  const isOpen = () => !wrap.hidden && current;

  async function reveal(unit, step, g) {
    unit.hidden = false;
    const words = unit.querySelectorAll('.w');
    if (reduce.matches || !words.length) { words.forEach(w => w.classList.add('on')); return; }
    for (const w of words) {
      w.classList.add('on');
      await sleep(step, g);
    }
  }

  function setKindLayout() {
    titleRow.classList.remove('stacked');
    if (kind.textContent && kind.offsetTop >= title.offsetTop + title.offsetHeight - 4) titleRow.classList.add('stacked');
  }

  // The sentence the word sits in, for the line at the top of the panel.
  function snippet(t) {
    const p = (t.el || t.range.startContainer.parentElement).closest('p');
    const before = document.createRange();
    before.selectNodeContents(p);
    const start = t.el ? (() => { const r = document.createRange(); r.selectNode(t.el); return r; })() : t.range;
    before.setEnd(start.startContainer, start.startOffset);
    const pre = before.toString();
    const word = t.el ? t.el.textContent : t.range.toString();
    const post = p.textContent.slice(pre.length + word.length);
    const a = pre.slice(Math.max(pre.lastIndexOf('. ') + 2, 0));
    const stop = post.indexOf('. ');
    const b = stop < 0 ? post : post.slice(0, stop + 1);
    const left = a.length > 46 ? '…' + a.slice(-46).replace(/^\S*\s/, '') : a;
    return `<b>Storage review</b>&ensp;<i>${esc(left)}<strong>${esc(word)}</strong>${esc(b)}</i>`;
  }

  function anchorRect(t) {
    const rs = [...(t.range ? t.range.getClientRects() : t.el.getClientRects())].filter(r => r.width);
    if (!rs.length) return t.el ? t.el.getBoundingClientRect() : t.range.getBoundingClientRect();
    const first = rs[0], last = rs[rs.length - 1];
    return { left: first.left, right: last.right, top: first.top, bottom: last.bottom, height: last.bottom - first.top };
  }

  // Under the word, flipped above if there's no room; on narrow screens, a bottom sheet.
  function place() {
    const sheet = narrow();
    wrap.classList.toggle('sheet', sheet);
    wrap.style.left = wrap.style.top = wrap.style.bottom = wrap.style.width = '';
    if (sheet) {
      const cap = Math.round(Math.min(innerHeight * 0.7, 620));
      wrap.style.setProperty('--cap', cap + 'px');
      panel.style.minHeight = Math.min(H, cap) + 'px';
      return;
    }
    panel.style.minHeight = '';
    const S = stage.getBoundingClientRect(), R = anchorRect(current);
    const pw = Math.min(448, S.width - 16);
    wrap.style.width = pw + 'px';
    wrap.style.left = clamp(R.left - S.left - 22, 0, S.width - pw) + 'px';
    const below = innerHeight - R.bottom - 24, above = R.top - 24;
    const up = H > below && above > below;
    const cap = Math.round(Math.min(Math.max(up ? above : below, 300), 620));
    wrap.style.setProperty('--cap', cap + 'px');
    wrap.classList.toggle('up', up);
    if (up) { wrap.style.top = 'auto'; wrap.style.bottom = (S.bottom - R.top + 8) + 'px'; }
    else wrap.style.top = (R.bottom - S.top + 8) + 'px';
  }

  function markRead(t) {
    terms.forEach(el => el.classList.remove('is-read'));
    readLine.hidden = true;
    if (t.selected) return;
    if (t.el) { t.el.classList.add('is-read'); return; }
    const S = stage.getBoundingClientRect(), R = t.range.getBoundingClientRect();
    Object.assign(readLine.style, { left: R.left - S.left + 'px', top: R.bottom - S.top + 1 + 'px', width: R.width + 'px' });
    readLine.hidden = false;
  }

  function renderSugs() {
    sugList.innerHTML = '';
    pending.forEach((s, i) => {
      const li = h('li');
      const b = h('button', 'p-sug', `<kbd>⌘${i + 1}</kbd><span>${esc(s.q)}</span>`);
      b.type = 'button';
      b.addEventListener('click', () => ask(s.q));
      li.append(b);
      sugList.append(li);
    });
    sugsBox.hidden = !pending.length;
  }

  function sameAs(t) {
    if (!current) return false;
    return t.key ? t.key === current.key : (!current.key && t.text === current.text);
  }

  async function open(t, how) {
    const g = ++gen;
    const wasOpen = isOpen();
    current = t;
    busy = true;
    pending = [];
    returnFocus = t.el || (document.activeElement !== document.body && !wrap.contains(document.activeElement) ? document.activeElement : null);
    pill.hidden = true;
    markRead(t);

    const d = t.key && DATA[t.key];
    const a = d && parse(d.raw);
    const unknown = !d;
    panel.classList.toggle('solo', unknown);
    wrap.classList.toggle('is-unknown', unknown);
    snip.innerHTML = t.el || t.range ? snippet(t) : '';
    thread.innerHTML = '';
    body.scrollTop = 0;
    form.classList.remove('busy');
    field.value = '';
    exp.hidden = true;

    // Build the finished answer once to measure it, then strip it back to the loading state.
    let turn = null, from = null;
    if (unknown) {
      title.textContent = t.text.length > 40 ? 'This passage' : t.text;
      kind.textContent = '';
      const msg = t.text.length > 40
        ? 'This page only knows a handful of words, not whole passages. ==Aside reads any passage==, in any app on your Mac.'
        : 'This page only knows a handful of words. ==Aside knows the rest==, in any app on your Mac.';
      thread.append(h('p', 'p-gist', inline(msg)));
      thread.append(h('p', 'p-get', `<a href="${DOWNLOAD}">Download for Mac</a><span>or try an underlined word</span>`));
      foot.hidden = true;
    } else {
      foot.hidden = false;
      title.textContent = plain(a.term || t.text);
      kind.textContent = plain(a.kind);
      if (a.expands) { exp.innerHTML = expansion(a.expands); exp.hidden = false; }
      turn = turnUnits(a, true);
      turn.nodes.forEach(n => thread.append(n));
      if (d.sources) {
        from = h('div', 'p-from', '<span class="p-from-label">From</span>' +
          d.sources.map(s => `<a class="p-chip" href="${s.url}" target="_blank" rel="noopener">${esc(s.name)}</a>`).join(''));
        thread.append(from);
      }
      pending = a.next.map((q, i) => ({ q, raw: d.follow[i]?.raw })).filter(s => s.raw);
      renderSugs();
    }
    wrap.hidden = false;
    wrap.style.setProperty('--cap', 'none');
    // Measure at the width it will have: a full-width sheet, or the panel.
    wrap.classList.toggle('sheet', narrow());
    wrap.style.width = narrow() ? '' : Math.min(448, stage.getBoundingClientRect().width - 16) + 'px';
    panel.style.minHeight = '';
    setKindLayout();
    H = panel.offsetHeight;

    // The loading state: the word as captured, a placeholder, nothing else yet.
    if (!unknown) {
      title.textContent = t.text;
      kind.textContent = '';
      exp.hidden = true;
      turn.units.forEach(u => { u.hidden = true; });
      if (from) from.hidden = true;
      sugsBox.hidden = true;
      thread.prepend(h('div', 'p-skel', '<i></i><i></i>'));
      form.classList.add('busy');
    }
    place();

    const sheet = wrap.classList.contains('sheet');
    if (wasOpen) {
      // Already open on another word: the content swaps, the panel moves.
      wrap.animate([{ opacity: 0.4 }, { opacity: 1 }], { duration: 160 });
    } else {
      const frames = sheet
        ? [{ transform: 'translateY(100%)' }, { transform: 'none' }]
        : [{ opacity: 0, transform: `translateY(${wrap.classList.contains('up') ? 6 : -6}px) scale(.985)` }, { opacity: 1, transform: 'none' }];
      wrap.animate(reduce.matches ? [{ opacity: 0 }, { opacity: 1 }] : frames, { duration: sheet ? 280 : 200, easing: 'cubic-bezier(.2,.7,.2,1)' });
    }

    if (sheet) keepWordInView(t);
    if (touch.matches || how === 'tap') panel.focus({ preventScroll: true });
    else if (!unknown) field.focus({ preventScroll: true });
    else panel.focus({ preventScroll: true });

    if (unknown) { busy = false; return; }

    try {
      if (d.search) {
        await sleep(260, g);
        const skel = thread.querySelector('.p-skel');
        const s = h('div', 'p-search', `<p class="p-search-label">Searching the web</p><p class="p-search-q"><span>${esc(d.search)}</span></p><p class="p-search-note">Not one the model knows well, so Aside is reading a few pages first.</p>`);
        skel.replaceWith(s);
        await sleep(1250, g);
        s.replaceWith(h('div', 'p-skel'));
      } else {
        await sleep(300, g);
      }
      thread.querySelector('.p-skel')?.remove();
      title.textContent = plain(a.term || t.text);
      kind.textContent = plain(a.kind);
      if (a.expands) exp.hidden = false;
      setKindLayout();
      for (const u of turn.units) await reveal(u, u.tagName === 'LI' ? 12 : 22, g);
      if (from) from.hidden = false;
      form.classList.remove('busy');
      busy = false;
      renderSugs();
    } catch (e) { /* replaced or closed */ }
  }

  async function ask(question) {
    if (!isOpen() || busy || !current.key) return;
    const q = question.trim();
    if (!q) return;
    const g = gen;
    const hit = pending.find(s => s.q.toLowerCase() === q.toLowerCase().replace(/\?*$/, '?'));
    let a;
    if (hit) {
      a = parse(hit.raw);
      pending = pending.filter(s => s !== hit);
    } else {
      a = parse(pending.length
        ? 'GIST: On this page I can only answer ==the suggestions below==. In the app, ask me anything.'
        : 'GIST: That’s all I know on this page. In the app, ==ask me anything==.');
    }
    busy = true;
    sugsBox.hidden = true;
    form.classList.add('busy');
    field.value = '';
    const turnEl = h('div', 'p-turn p-follow');
    turnEl.append(h('div', 'p-q', ARR + `<span>${esc(hit ? hit.q : q)}</span>`));
    const t = turnUnits(a, false);
    t.nodes.forEach(n => turnEl.append(n));
    thread.append(turnEl);
    // Measure the finished turn. If it won't all fit, give it room to reach the top of the
    // panel (one view per question, as in the app); a sheet opens out to its full height now.
    renderSugs();
    const overflows = body.scrollHeight > body.clientHeight + 4;
    if (wrap.classList.contains('sheet')) { panel.style.minHeight = panel.offsetHeight + 'px'; keepWordInView(current, panel.offsetHeight); }
    sugsBox.hidden = true;
    if (overflows) turnEl.style.minHeight = (body.clientHeight - 12) + 'px';
    t.units.forEach(u => { u.hidden = true; });
    try {
      body.scrollTo({ top: turnEl.offsetTop + 4, behavior: reduce.matches ? 'auto' : 'smooth' });
      await sleep(320, g);
      for (const u of t.units) await reveal(u, u.tagName === 'LI' ? 12 : 22, g);
      form.classList.remove('busy');
      busy = false;
      renderSugs();
    } catch (e) { /* closed */ }
  }

  function close(restore) {
    if (wrap.hidden) return;
    gen++;
    busy = false;
    const sheet = wrap.classList.contains('sheet');
    const done = () => { if (!current) wrap.hidden = true; };
    current = null;
    terms.forEach(el => el.classList.remove('is-read'));
    readLine.hidden = true;
    const a = wrap.animate(sheet && !reduce.matches
      ? [{ transform: getComputedStyle(wrap).transform === 'none' ? 'none' : getComputedStyle(wrap).transform }, { transform: 'translateY(100%)' }]
      : [{ opacity: 1 }, { opacity: 0 }], { duration: sheet ? 220 : 140, easing: 'ease-in' });
    a.onfinish = () => { wrap.style.transform = ''; done(); };
    if (restore && returnFocus && document.contains(returnFocus)) returnFocus.focus({ preventScroll: true });
    else if (wrap.contains(document.activeElement)) document.activeElement.blur();
    returnFocus = null;
  }

  // On a phone, keep the tapped word visible above the sheet.
  function keepWordInView(t, height = H) {
    const R = anchorRect(t);
    const sheetTop = innerHeight - Math.min(height, Math.min(innerHeight * 0.7, 620));
    if (R.top > 64 && R.bottom < sheetTop - 24) return;
    const goal = Math.max(72, (sheetTop - R.height) * 0.42);
    scrollBy({ top: R.top - goal, behavior: reduce.matches ? 'auto' : 'smooth' });
  }

  // ---------- What's being pointed at ----------

  function caretAt(x, y) {
    if (document.caretPositionFromPoint) {
      const p = document.caretPositionFromPoint(x, y);
      return p && { node: p.offsetNode, offset: p.offset };
    }
    if (document.caretRangeFromPoint) {
      const r = document.caretRangeFromPoint(x, y);
      return r && { node: r.startContainer, offset: r.startOffset };
    }
    return null;
  }

  const WORD = /[\p{L}\p{N}_'’-]/u;
  function wordAt(x, y) {
    const c = caretAt(x, y);
    if (!c || c.node.nodeType !== 3 || !prose.contains(c.node)) return null;
    const s = c.node.textContent;
    let a = c.offset, b = c.offset;
    while (a > 0 && WORD.test(s[a - 1])) a--;
    while (b < s.length && WORD.test(s[b])) b++;
    while (a < b && /['’-]/.test(s[a])) a++;
    while (b > a && /['’-]/.test(s[b - 1])) b--;
    if (a === b) return null;
    const range = document.createRange();
    range.setStart(c.node, a);
    range.setEnd(c.node, b);
    // The caret APIs snap to the nearest text; only count it if the pointer is really on the word.
    const on = [...range.getClientRects()].some(r => x >= r.left - 2 && x <= r.right + 2 && y >= r.top - 3 && y <= r.bottom + 3);
    if (!on) return null;
    const el = c.node.parentElement.closest('.t');
    return el ? { key: el.dataset.look, el, text: el.textContent, range: elRange(el) } : { key: null, text: s.slice(a, b), range };
  }

  function elRange(el) {
    const r = document.createRange();
    r.selectNodeContents(el);
    return r;
  }
  const fromEl = el => ({ key: el.dataset.look, el, text: el.textContent, range: elRange(el) });

  // A selection maps to the curated look-up it overlaps most; a long one is a passage.
  function selectionTarget() {
    const sel = getSelection();
    if (!sel || sel.isCollapsed || !sel.rangeCount) return null;
    const range = sel.getRangeAt(0);
    if (!prose.contains(range.commonAncestorContainer)) return null;
    const text = sel.toString().replace(/\s+/g, ' ').trim();
    if (!text) return null;
    let best = null, most = 0;
    for (const el of terms) {
      if (!range.intersectsNode(el)) continue;
      const r = elRange(el);
      if (r.compareBoundaryPoints(Range.START_TO_START, range) < 0) r.setStart(range.startContainer, range.startOffset);
      if (r.compareBoundaryPoints(Range.END_TO_END, range) > 0) r.setEnd(range.endContainer, range.endOffset);
      const n = r.toString().trim().length;
      if (n > most) { best = el; most = n; }
    }
    if (best && text.length <= best.textContent.length + 24) return { key: best.dataset.look, el: best, text: best.textContent, range: range.cloneRange(), selected: true };
    return { key: null, text, range: range.cloneRange(), selected: true };
  }

  function resolve() {
    const sel = selectionTarget();
    if (sel) return sel;
    const focused = document.activeElement?.closest?.('.t');
    if (focused && lastInput === 'key') return fromEl(focused);
    if (mouse) {
      const w = wordAt(mouse.x, mouse.y);
      if (w) return w;
    }
    return focused ? fromEl(focused) : null;
  }

  // ---------- Input ----------

  document.addEventListener('mousemove', e => { mouse = { x: e.clientX, y: e.clientY }; lastInput = 'mouse'; }, { passive: true });

  document.addEventListener('keydown', e => {
    if (e.altKey && e.code === 'Space') {
      const t = resolve();
      if (!t) {
        if (isOpen() && wrap.contains(document.activeElement)) { e.preventDefault(); close(true); }
        return;
      }
      e.preventDefault();
      if (isOpen() && sameAs(t)) close(true); else open(t, 'key');
      return;
    }
    if (e.key === 'Tab') lastInput = 'key';
    const onTerm = e.target.closest?.('.t');
    if (onTerm && (e.key === 'Enter' || e.key === ' ') && !e.altKey && !e.metaKey && !e.ctrlKey) {
      e.preventDefault();
      lastInput = 'key';
      if (isOpen() && current.el === onTerm) close(true); else open(fromEl(onTerm), 'key');
      return;
    }
    if (!isOpen()) return;
    if (e.key === 'Escape') { e.preventDefault(); close(true); return; }
    if ((e.metaKey || e.ctrlKey) && (e.key === '1' || e.key === '2')) {
      const s = pending[+e.key - 1];
      if (s && !busy) { e.preventDefault(); ask(s.q); }
    }
  });

  // A plain click (or tap) on an underlined word works too.
  prose.addEventListener('click', e => {
    const el = e.target.closest('.t');
    if (!el) return;
    const sel = getSelection();
    if (sel && !sel.isCollapsed && sel.toString().trim()) return;
    if (isOpen() && current.el === el && !current.selected) { close(false); return; }
    open(fromEl(el), touch.matches ? 'tap' : 'click');
  });

  // Close on a click outside (a click on another word opens that instead).
  document.addEventListener('pointerdown', e => {
    if (!isOpen()) return;
    if (wrap.contains(e.target) || e.target === pill || e.target.closest?.('.t')) return;
    close(false);
  }, true);

  form.addEventListener('submit', e => { e.preventDefault(); ask(field.value); });
  grab.addEventListener('click', () => close(true));

  // ---------- Touch: the "Look up" pill and the sheet ----------

  let pillTimer = 0, pillTarget = null;
  function updatePill() {
    if (!touch.matches) return;
    const t = selectionTarget();
    if (!t) { pill.hidden = true; pillTarget = null; return; }
    pillTarget = t;
    const S = stage.getBoundingClientRect();
    const rs = [...t.range.getClientRects()].filter(r => r.width);
    const last = rs[rs.length - 1] || t.range.getBoundingClientRect();
    pill.hidden = false;
    const pw = pill.offsetWidth;
    pill.style.left = clamp(last.left + last.width / 2 - S.left - pw / 2, 8, S.width - pw - 8) + 'px';
    pill.style.top = (last.bottom - S.top + 16) + 'px';
  }
  const schedulePill = ms => { clearTimeout(pillTimer); pillTimer = setTimeout(updatePill, ms); };
  document.addEventListener('selectionchange', () => { if (touch.matches) schedulePill(220); });
  document.addEventListener('touchend', () => { if (touch.matches) schedulePill(260); }, { passive: true });
  pill.addEventListener('pointerdown', e => e.preventDefault());
  pill.addEventListener('click', () => {
    const t = pillTarget;
    if (!t) return;
    pill.hidden = true;
    getSelection().removeAllRanges();
    open(t, 'tap');
  });

  // Swipe the sheet down to close it.
  let drag = null;
  panel.addEventListener('touchstart', e => {
    if (!wrap.classList.contains('sheet')) return;
    const fromHandle = e.target.closest('.p-grab, .p-eyebrow, .p-title');
    if (!fromHandle && body.scrollTop > 0) return;
    drag = { y: e.touches[0].clientY, t: performance.now(), dy: 0, handle: !!fromHandle };
  }, { passive: true });
  panel.addEventListener('touchmove', e => {
    if (!drag) return;
    const dy = e.touches[0].clientY - drag.y;
    if (dy <= 0 && !drag.dy) { drag = null; return; }
    if (!drag.handle && body.scrollTop > 0) { drag = null; return; }
    drag.dy = Math.max(0, dy);
    e.preventDefault();
    wrap.style.transform = `translateY(${drag.dy}px)`;
  }, { passive: false });
  panel.addEventListener('touchend', () => {
    if (!drag) return;
    const v = drag.dy / (performance.now() - drag.t);
    const far = drag.dy > 90 || (drag.dy > 30 && v > 0.5);
    drag = null;
    if (far) { close(false); return; }
    wrap.animate([{ transform: wrap.style.transform }, { transform: 'none' }], { duration: 200, easing: 'cubic-bezier(.2,.7,.2,1)' });
    wrap.style.transform = '';
  });

  // ---------- Setup ----------

  terms.forEach(el => {
    el.tabIndex = 0;
    el.setAttribute('role', 'button');
    el.setAttribute('aria-haspopup', 'dialog');
  });

  let resizeTimer = 0;
  addEventListener('resize', () => {
    clearTimeout(resizeTimer);
    resizeTimer = setTimeout(() => { if (isOpen()) { place(); markRead(current); } updatePill(); }, 120);
  });
})();
