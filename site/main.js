// Aside site: the hero demo and the four small vignettes.
// Everything animates with the Web Animations API on transform/opacity (plus a clip-path
// when the panel grows for a follow-up). Each demo is a short script that a Runner loops
// while it's on screen. With reduced motion the same script runs instantly, so the final
// state is shown, still.

(() => {
  const reduce = matchMedia('(prefers-reduced-motion: reduce)');
  const EASE = 'cubic-bezier(.2,.7,.2,1)';
  const GLIDE = 'cubic-bezier(.55,0,.2,1)';
  const runners = [];
  let userPaused = false;

  const $ = (sel, root = document) => root.querySelector(sel);
  const $$ = (sel, root = document) => [...root.querySelectorAll(sel)];
  const clamp = (v, lo, hi) => Math.max(lo, Math.min(hi, v));

  // Wrap each word of a streaming element in a span so it can arrive on its own.
  function split(el) {
    const walker = document.createTreeWalker(el, NodeFilter.SHOW_TEXT);
    const nodes = [];
    while (walker.nextNode()) nodes.push(walker.currentNode);
    for (const n of nodes) {
      const parts = n.textContent.match(/\s+|\S+\s*/g) || [];
      const frag = document.createDocumentFragment();
      for (const p of parts) {
        if (!p.trim()) { frag.append(p); continue; }
        const s = document.createElement('span');
        s.className = 'w';
        s.textContent = p;
        frag.append(s);
      }
      n.replaceWith(frag);
    }
  }
  $$('.stream').forEach(split);

  class Runner {
    constructor(root, script) {
      this.root = root;
      this.script = script;
      this.anims = [];
      this.classes = [];
      this.visible = false;
      this.instant = false;
      this.gen = 0;
      this.width = 0;
      new IntersectionObserver(([e]) => { this.visible = e.isIntersecting; this.sync(); }, { threshold: 0.2 }).observe(root);
      new ResizeObserver(() => {
        const w = root.offsetWidth;
        if (Math.abs(w - this.width) < 1) return;
        this.width = w;
        if (!this.started) return;
        clearTimeout(this.rt);
        this.rt = setTimeout(() => this.start(), 180);
      }).observe(root);
    }
    get running() { return this.visible && !userPaused && !document.hidden; }

    // Waits only count time while the demo is visible and not paused.
    wait(ms) {
      if (this.instant) return Promise.resolve();
      const gen = this.gen;
      return new Promise(res => {
        let left = ms, last = performance.now();
        const tick = now => {
          if (gen !== this.gen) return;
          const dt = Math.min(now - last, 64);
          last = now;
          if (this.running) left -= dt;
          if (left <= 0) res(); else requestAnimationFrame(tick);
        };
        requestAnimationFrame(tick);
      });
    }
    anim(el, frames, opts = {}) {
      const o = { fill: 'forwards', easing: EASE, duration: 200, ...opts };
      if (this.instant) { o.duration = 0; o.delay = 0; }
      const a = el.animate(frames, o);
      this.anims.push(a);
      return a;
    }
    fade(el, to = 1, duration = 200, extra = {}) {
      return this.anim(el, [{ opacity: to ? 0 : 1 }, { opacity: to }], { duration, ...extra });
    }
    cls(el, name, on = true) {
      el.classList.toggle(name, on);
      if (on) this.classes.push([el, name]);
    }
    stream(el, step = 32) {
      const words = $$('.w', el);
      const dot = $('.dot', el);
      if (dot) this.anim(dot, [{ opacity: 0 }, { opacity: 0.75 }], { duration: 160 });
      words.forEach((w, i) => this.anim(w, [{ opacity: 0 }, { opacity: 1 }], { duration: 160, delay: i * step, easing: 'linear' }));
      return this.wait(words.length * step + 60);
    }
    reset() {
      this.anims.forEach(a => a.cancel());
      this.anims = [];
      this.classes.forEach(([el, n]) => el.classList.remove(n));
      this.classes = [];
    }
    sync() {
      if (this.running) this.anims.forEach(a => { if (a.held) { a.held = false; a.play(); } });
      else this.anims.forEach(a => { if (a.playState === 'running') { a.pause(); a.held = true; } });
    }
    async start() {
      this.started = true;
      const gen = ++this.gen;
      this.reset();
      this.script.layout?.(this);
      if (reduce.matches) {
        this.root.classList.add('is-static');
        this.instant = true;
        await this.script.build(this);
        this.instant = false;
        return;
      }
      this.root.classList.remove('is-static');
      while (gen === this.gen) {
        await this.script.build(this);
        await this.script.out(this);
        if (gen !== this.gen) return;
        this.reset();
        this.script.layout?.(this);
      }
    }
  }

  // A key cap going down and up. Translate only; the darker base underneath stays put.
  function press(r, cap, hold = 240) {
    const total = hold + 150;
    r.anim(cap, [
      { transform: 'translateY(0)', color: '' },
      { transform: 'translateY(3px)', color: 'var(--accent)', offset: 70 / total },
      { transform: 'translateY(3px)', color: 'var(--accent)', offset: (70 + hold) / total },
      { transform: 'translateY(0)', color: '' },
    ], { duration: total, fill: 'none', easing: 'ease-out' });
  }

  // Place an I-beam over a word, from somewhere to its lower right.
  function cursorPath(box, word, from) {
    const B = box.getBoundingClientRect(), R = word.getBoundingClientRect();
    const to = { x: R.left - B.left + R.width * 0.42 - 7, y: R.top - B.top + R.height / 2 - 12 };
    return {
      from: `translate(${from.x}px, ${from.y}px)`,
      to: `translate(${to.x}px, ${to.y}px)`,
    };
  }

  // ---------- Hero ----------

  const hero = $('#hero-demo');
  if (hero) {
    const win = $('.win', hero);
    const word = $('[data-anchor]', hero);
    const mark = $('.word-mark', hero);
    const beam = $('.ibeam', hero);
    const wrap = $('.panel-wrap', hero);
    const panel = $('.panel', hero);
    const foot = $('.p-foot', hero);
    const first = $('.p-first', hero);
    const follow = $('.p-follow', hero);
    const input = $('.p-input', hero);
    const sugA = $('.p-sug-a', hero), sugB = $('.p-sug-b', hero);
    const [optKey, spaceKey] = $$('.chord-a .cap', hero);
    const [cmdKey, oneKey] = $$('.chord-b .cap', hero);
    const chordA = $('.chord-a', hero), chordB = $('.chord-b', hero);
    const skel = $('.p-skel', hero), gist = $('.p-gist', first);
    const sugs = $('.p-sugs', hero);
    const compact = () => hero.offsetWidth < 560;
    let path, m = {}, shape = null;

    // Bullet dots arrive with their bullet, so make them real elements.
    $$('.p-bullets li', hero).forEach(li => li.prepend(Object.assign(document.createElement('span'), { className: 'dot' })));

    // The panel is laid out at its final size. Showing content down to y (and the
    // suggestions or not) clips the bottom off and slides the footer up to meet it.
    function setShape(r, y, withSugs, duration = 260) {
      const visible = y + m.padB + (withSugs ? m.sugsH : 0) + m.inputH;
      const next = { inset: m.H - visible, foot: y - m.followB, input: withSugs ? 0 : -m.sugsH };
      const prev = shape || next;
      const o = { duration, easing: 'cubic-bezier(.3,.7,.2,1)' };
      r.anim(panel, [{ clipPath: `inset(0px 0px ${prev.inset}px 0px round 16px)` }, { clipPath: `inset(0px 0px ${next.inset}px 0px round 16px)` }], o);
      r.anim(foot, [{ transform: `translateY(${prev.foot}px)` }, { transform: `translateY(${next.foot}px)` }], o);
      r.anim(input, [{ transform: `translateY(${prev.input}px)` }, { transform: `translateY(${next.input}px)` }], o);
      shape = next;
    }

    const script = {
      layout() {
        shape = null;
        win.style.minHeight = '';
        const W = win.getBoundingClientRect(), R = word.getBoundingClientRect();
        const pw = wrap.offsetWidth;
        const left = clamp(R.left - W.left - 22, 8, W.width - pw - 8);
        const top = R.bottom - W.top + 8;
        wrap.style.left = left + 'px';
        wrap.style.top = top + 'px';
        const P = panel.getBoundingClientRect().top;
        const below = el => el.getBoundingClientRect().bottom - P;
        m = {
          H: panel.offsetHeight,
          padB: parseFloat(getComputedStyle($('.p-body', hero)).paddingBottom),
          sugsH: sugs.offsetHeight,
          inputH: input.offsetHeight,
          skelB: below(skel),
          gistB: below(gist),
          firstB: below(first),
          followB: below(follow),
        };
        const finalH = compact() ? m.firstB + m.padB + m.sugsH + m.inputH : m.H;
        win.style.minHeight = Math.max(compact() ? 0 : 560, top + finalH + 28) + 'px';
        path = cursorPath(win, word, { x: W.width * 0.72, y: Math.min(W.height - 60, top + 170) });
        beam.style.transform = path.from;
      },

      async build(r) {
        await r.wait(500);
        r.fade(beam, 1, 250);
        await r.wait(250);
        r.anim(beam, [{ transform: path.from }, { transform: path.to }], { duration: 1150, easing: GLIDE });
        await r.wait(1350);

        // ⌥ Space
        press(r, optKey, 420);
        await r.wait(160);
        press(r, spaceKey, 200);
        await r.wait(120);

        // The panel opens under the word with a placeholder, then the answer streams in.
        r.fade(mark, 1, 200);
        setShape(r, m.skelB, false, 0);
        r.anim(wrap, [
          { opacity: 0, transform: 'translateY(-6px) scale(.985)' },
          { opacity: 1, transform: 'none' },
        ], { duration: 220 });
        r.fade(skel, 1, 120);
        r.cls(input, 'busy');
        await r.wait(340);
        r.fade($('.p-ms', hero), 1, 200);
        r.fade(skel, 0, 100);
        r.fade($('.p-kind', hero), 1, 220);
        setShape(r, m.gistB, false, 200);
        await r.stream(gist, 30);
        r.fade($('.p-rule', hero), 1, 200);
        setShape(r, m.firstB, false, 320);
        const [b1, b2] = $$('.p-bullets li', hero);
        await r.stream(b1, 15);
        await r.stream(b2, 15);
        setShape(r, m.firstB, true, 220);
        r.anim(sugA, [{ opacity: 0, transform: 'translateY(4px)' }, { opacity: 1, transform: 'none' }], { duration: 220, delay: 60 });
        r.cls(input, 'busy', false);

        if (compact()) { await r.wait(4200); return; }

        // ⌘1 asks the first suggestion; the panel grows to hold the follow-up.
        await r.wait(2200);
        r.fade(chordA, 0, 200);
        r.fade(chordB, 1, 200);
        await r.wait(420);
        press(r, cmdKey, 420);
        await r.wait(160);
        press(r, oneKey, 200);
        await r.wait(70);
        r.cls($('li', sugA), 'lit');
        await r.wait(260);
        r.cls(input, 'busy');
        r.fade(sugA, 0, 120);
        setShape(r, m.followB, false, 420);
        r.fade($('.p-q', follow), 1, 220, { delay: 120 });
        await r.wait(420);
        await r.stream($('.p-gist', follow), 30);
        r.cls(input, 'busy', false);
        setShape(r, m.followB, true, 220);
        r.anim(sugB, [{ opacity: 0, transform: 'translateY(4px)' }, { opacity: 1, transform: 'none' }], { duration: 220, delay: 60 });
        if (r.instant) { r.fade(chordB, 0); r.fade(chordA, 1); }
        await r.wait(4200);
      },

      async out(r) {
        r.fade(wrap, 0, 320);
        r.fade(mark, 0, 320);
        r.fade(beam, 0, 320);
        if (!compact()) { r.fade(chordB, 0, 300); r.fade(chordA, 1, 300); }
        await r.wait(1100);
      },
    };

    const r = new Runner(hero, script);
    runners.push(r);
  }

  // ---------- Vignettes ----------

  function vignette(id, make) {
    const art = document.getElementById(id);
    if (!art) return;
    const box = $('.vig', art);
    const r = new Runner(box, make(box));
    runners.push(r);
  }

  // Shared: glide the I-beam to a word, open the mini panel under the line.
  function pointAndOpen(box) {
    const beam = $('.ibeam', box), panel = $('.vig-panel', box), line = $('.vig-line', box);
    let path;
    return {
      beam, panel,
      layout(target) {
        const B = box.getBoundingClientRect(), L = line.getBoundingClientRect(), T = target.getBoundingClientRect();
        panel.style.top = Math.round(L.bottom - B.top + 14) + 'px';
        const pw = panel.offsetWidth;
        panel.style.left = Math.round(clamp(T.left - B.left - 18, 12, B.width - pw - 12)) + 'px';
        path = cursorPath(box, target, { x: B.width * 0.8, y: B.height - 40 });
        beam.style.transform = path.from;
      },
      async point(r) {
        await r.wait(500);
        r.fade(beam, 1, 220);
        await r.wait(200);
        r.anim(beam, [{ transform: path.from }, { transform: path.to }], { duration: 950, easing: GLIDE });
        await r.wait(1150);
      },
      open(r) {
        r.anim(panel, [{ opacity: 0, transform: 'translateY(-5px)' }, { opacity: 1, transform: 'none' }], { duration: 220 });
      },
      async close(r, marks) {
        r.fade(panel, 0, 300);
        r.fade(beam, 0, 300);
        marks.forEach(m => r.fade(m, 0, 300));
        await r.wait(1000);
      },
    };
  }

  vignette('v-point', box => {
    const p = pointAndOpen(box);
    const one = $('.vmark-one', box), all = $('.vmark-all', box);
    const target = $('.vword', box);
    return {
      layout() { p.layout(target); },
      async build(r) {
        await p.point(r);
        r.fade(one, 1, 160);
        await r.wait(420);
        // From the word you pointed at to the whole term.
        r.fade(one, 0, 260);
        r.anim(all, [{ opacity: 0, transform: 'scaleX(.55)' }, { opacity: 1, transform: 'none' }], { duration: 360 });
        await r.wait(320);
        p.open(r);
        await r.wait(300);
        r.fade($('.p-kind', box), 1, 200);
        await r.stream($('.p-gist', box), 34);
        await r.wait(3000);
      },
      out(r) { return p.close(r, [all]); },
    };
  });

  vignette('v-acro', box => {
    const p = pointAndOpen(box);
    const one = $('.vmark-one', box);
    const target = $('.vword', box);
    return {
      layout() { p.layout(target); },
      async build(r) {
        await p.point(r);
        r.fade(one, 1, 160);
        await r.wait(160);
        p.open(r);
        await r.wait(520);
        // The initials are already there; the rest of each word fills in after them.
        $$('.p-exp i', box).forEach((el, i) => r.fade(el, 1, 260, { delay: i * 120 }));
        await r.wait(620);
        r.fade($('.p-kind', box), 1, 200);
        await r.stream($('.p-gist', box), 34);
        await r.wait(3000);
      },
      out(r) { return p.close(r, [one]); },
    };
  });

  vignette('v-web', box => {
    const p = pointAndOpen(box);
    const one = $('.vmark-one', box);
    const target = $('.vword', box);
    const searching = $('.searching', box);
    return {
      layout() { p.layout(target); },
      async build(r) {
        await p.point(r);
        r.fade(one, 1, 160);
        await r.wait(160);
        p.open(r);
        await r.wait(250);
        r.fade(searching, 1, 200);
        await r.wait(1500);
        r.fade(searching, 0, 160);
        await r.wait(160);
        r.fade($('.p-kind', box), 1, 200);
        await r.stream($('.p-gist', box), 34);
        r.anim($('.sources', box), [{ opacity: 0, transform: 'translateY(3px)' }, { opacity: 1, transform: 'none' }], { duration: 240 });
        await r.wait(3200);
      },
      out(r) { return p.close(r, [one]); },
    };
  });

  vignette('v-ask', box => {
    const input = $('.p-input', box);
    const typed = $('.typed', box);
    const inner = $('.thread-inner', box), view = $('.thread-view', box);
    const follow = $('.p-follow', box);
    const question = $('.p-q span', box).textContent;
    return {
      layout() { typed.textContent = ''; },
      async build(r) {
        await r.wait(900);
        r.cls(input, 'has-text');
        for (let i = 1; i <= question.length; i++) {
          typed.textContent = question.slice(0, i);
          await r.wait(48 + (question[i - 1] === ' ' ? 40 : 0) + ((i * 37) % 23));
        }
        await r.wait(450);
        typed.textContent = '';
        r.cls(input, 'has-text', false);
        r.cls(input, 'busy');
        r.fade(follow, 1, 200);
        const shift = Math.max(0, inner.offsetHeight - view.offsetHeight);
        r.anim(inner, [{ transform: 'translateY(0)' }, { transform: `translateY(${-shift}px)` }], { duration: 380 });
        await r.wait(300);
        await r.stream($('.p-gist-sm', box), 34);
        r.cls(input, 'busy', false);
        await r.wait(3400);
      },
      async out(r) {
        r.fade(follow, 0, 300);
        r.anim(inner, [{ transform: getComputedStyle(inner).transform }, { transform: 'translateY(0)' }], { duration: 500 });
        await r.wait(700);
      },
    };
  });

  // ---------- Pause control and environment changes ----------

  const toggle = $('.motion-toggle');
  if (toggle) {
    if (reduce.matches) toggle.hidden = true;
    toggle.addEventListener('click', () => {
      userPaused = !userPaused;
      toggle.textContent = userPaused ? 'Play' : 'Pause';
      toggle.setAttribute('aria-pressed', String(userPaused));
      runners.forEach(r => r.sync());
    });
  }
  document.addEventListener('visibilitychange', () => runners.forEach(r => r.sync()));
  reduce.addEventListener('change', () => {
    if (toggle) toggle.hidden = reduce.matches;
    runners.forEach(r => r.start());
  });

  // Start once fonts are in, so measurements match what's drawn.
  (document.fonts ? document.fonts.ready : Promise.resolve()).then(() => runners.forEach(r => { if (!r.started) r.start(); }));
})();
