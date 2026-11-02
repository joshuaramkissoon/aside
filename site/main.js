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
        // Spaces inside a mark keep its highlight, so they get a span too.
        if (!p.trim() && !n.parentElement.closest('mark')) { frag.append(p); continue; }
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
        this.rt = setTimeout(() => this.start(this.from, this.still), 180);
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
    // `from` lets a script start part-way (the hero's steps); `still` renders the final state at once.
    async start(from = 1, still = reduce.matches) {
      this.started = true;
      this.from = from;
      const gen = ++this.gen;
      this.reset();
      this.script.layout?.(this);
      if (still) {
        this.root.classList.add('is-static');
        this.still = true;
        this.instant = true;
        await this.script.build(this);
        this.instant = false;
        return;
      }
      this.still = false;
      this.root.classList.remove('is-static');
      while (gen === this.gen) {
        await this.script.build(this);
        await this.script.out(this);
        if (gen !== this.gen) return;
        this.from = 1;
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
  // Three captioned moments: point at a word (nothing selected), select a phrase, keep asking.
  // The step buttons jump to a moment; when paused or with reduced motion they show its still.

  const hero = $('#hero-demo');
  let heroRunner = null;
  if (hero) {
    const win = $('.win', hero);
    const beam = $('.ibeam', hero);
    const word = $('[data-anchor]', hero);
    const read = $('.word-read', hero);
    const phrase = $('[data-phrase]', hero);
    const sel = $('.sel', phrase);
    const [optKey, spaceKey] = $$('.chord-a .cap', hero);
    const [cmdKey, oneKey] = $$('.chord-b .cap', hero);
    const chordA = $('.chord-a', hero), chordB = $('.chord-b', hero);
    const stepBtns = $$('.steps button', hero), caps = $$('.cap-step', hero);
    const compact = () => hero.offsetWidth < 560;
    const appear = [{ opacity: 0, transform: 'translateY(4px)' }, { opacity: 1, transform: 'none' }];
    const at = p => `translate(${p.x - 7}px, ${p.y - 12}px)`;
    let pos = {}, edges = [];

    // Bullet dots arrive with their bullet, so make them real elements.
    $$('.p-bullets li', hero).forEach(li => li.prepend(Object.assign(document.createElement('span'), { className: 'dot' })));

    function setStep(n) {
      stepBtns.forEach(b => b.classList.toggle('is-on', +b.dataset.step === n));
      caps.forEach(c => c.classList.toggle('is-on', +c.dataset.step === n));
    }

    // One Aside panel in the window, laid out at its final size. Showing content down to y
    // clips the bottom off and slides the footer up to meet it.
    function heroPanel(wrap) {
      const panel = $('.panel', wrap), foot = $('.p-foot', wrap), input = $('.p-input', wrap);
      const first = $('.p-first', wrap), follow = $('.p-follow', wrap);
      const skel = $('.p-skel', wrap), gist = $('.p-gist', first), sugs = $('.p-sugs', wrap);
      const sugA = $('.p-sug-a', wrap), sugB = $('.p-sug-b', wrap);
      let m = {}, shape = null;

      function setShape(r, y, withSugs, duration = 260) {
        const visible = y + m.padB + (withSugs ? m.sugsH : 0) + m.inputH;
        const next = { inset: m.H - visible, foot: y - m.endB, input: withSugs ? 0 : -m.sugsH };
        const prev = shape || next;
        const o = { duration, easing: 'cubic-bezier(.3,.7,.2,1)' };
        r.anim(panel, [{ clipPath: `inset(0px 0px ${prev.inset}px 0px round 16px)` }, { clipPath: `inset(0px 0px ${next.inset}px 0px round 16px)` }], o);
        r.anim(foot, [{ transform: `translateY(${prev.foot}px)` }, { transform: `translateY(${next.foot}px)` }], o);
        r.anim(input, [{ transform: `translateY(${prev.input}px)` }, { transform: `translateY(${next.input}px)` }], o);
        shape = next;
      }

      return {
        wrap,
        // Place under the anchor; returns how far down the window the panel reaches.
        layout(anchor) {
          shape = null;
          const W = win.getBoundingClientRect(), R = anchor.getBoundingClientRect();
          const top = R.bottom - W.top + 8;
          wrap.style.left = clamp(R.left - W.left - 22, 8, W.width - wrap.offsetWidth - 8) + 'px';
          wrap.style.top = top + 'px';
          const T = panel.getBoundingClientRect().top;
          const below = el => el.getBoundingClientRect().bottom - T;
          m = {
            H: panel.offsetHeight,
            padB: parseFloat(getComputedStyle($('.p-body', wrap)).paddingBottom),
            sugsH: sugs.offsetHeight,
            inputH: input.offsetHeight,
            skelB: below(skel),
            gistB: below(gist),
            firstB: below(first),
            followB: follow ? below(follow) : 0,
            endB: below(follow || first),
          };
          return top + m.H;
        },

        // ⌥ Space was pressed: open with a placeholder, then stream the answer in.
        async open(r) {
          setShape(r, m.skelB, false, 0);
          r.anim(wrap, [
            { opacity: 0, transform: 'translateY(-6px) scale(.985)' },
            { opacity: 1, transform: 'none' },
          ], { duration: 220 });
          r.fade(skel, 1, 120);
          r.cls(input, 'busy');
          await r.wait(340);
          r.fade(skel, 0, 100);
          r.fade($('.p-kind', wrap), 1, 220);
          setShape(r, m.gistB, false, 200);
          await r.stream(gist, 30);
          const bullets = $$('.p-bullets li', wrap).filter(li => li.offsetParent);
          if (bullets.length) {
            r.fade($('.p-rule', wrap), 1, 200);
            setShape(r, m.firstB, false, 320);
            for (const b of bullets) await r.stream(b, 15);
          }
          setShape(r, m.firstB, true, 220);
          r.anim(sugA, appear, { duration: 220, delay: 60 });
          r.cls(input, 'busy', false);
        },

        // ⌘1 asks the first suggestion; the panel grows to hold the follow-up.
        async ask(r) {
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
          r.anim(sugB, appear, { duration: 220, delay: 60 });
        },
      };
    }

    const A = heroPanel($('.panel-a', hero));
    const B = heroPanel($('.panel-b', hero));

    async function optionSpace(r) {
      press(r, optKey, 420);
      await r.wait(160);
      press(r, spaceKey, 200);
      await r.wait(120);
    }

    // 1. Point: the I-beam rests on "flush". Nothing is selected; once ⌥ Space is pressed,
    // a faint underline shows which word was read.
    async function point(r) {
      setStep(1);
      await r.wait(600);
      r.fade(beam, 1, 250);
      await r.wait(250);
      r.anim(beam, [{ transform: at(pos.start) }, { transform: at(pos.word) }], { duration: 1150, easing: GLIDE });
      await r.wait(1500);
      await optionSpace(r);
      r.anim(read, [{ opacity: 0, transform: 'scaleX(.4)' }, { opacity: 1, transform: 'none' }], { duration: 260 });
      await A.open(r);
      await r.wait(2600);
    }

    // 2. Select: a real drag, the selection snapping to each character as the cursor passes it.
    async function select(r, fromWord) {
      setStep(2);
      let from = pos.start;
      if (fromWord) {
        from = pos.word;
        r.fade(A.wrap, 0, 240);
        r.fade(read, 0, 240);
        await r.wait(700);
      } else {
        await r.wait(600);
        r.fade(beam, 1, 250);
        await r.wait(250);
      }
      r.anim(beam, [{ transform: at(from) }, { transform: at(pos.selFrom) }], { duration: 950, easing: GLIDE });
      await r.wait(1250);
      const W = edges[edges.length - 1], D = 1150;
      const frames = [{ width: '0px', offset: 0, easing: 'steps(1, end)' }];
      for (let i = 1; i < edges.length; i++) {
        frames.push({ width: edges[i] + 'px', offset: clamp((edges[i - 1] + edges[i]) / 2 / W, 0, 1), easing: 'steps(1, end)' });
      }
      frames.push({ width: W + 'px', offset: 1 });
      r.anim(sel, frames, { duration: D, easing: 'linear' });
      r.anim(beam, [{ transform: at(pos.selFrom) }, { transform: at(pos.selTo) }], { duration: D, easing: 'linear' });
      await r.wait(D + 500);
      await optionSpace(r);
      await B.open(r);
      await r.wait(1600);
    }

    // 3. Keep asking.
    async function ask(r) {
      setStep(3);
      await r.wait(400);
      r.fade(chordA, 0, 200);
      r.fade(chordB, 1, 200);
      await r.wait(520);
      press(r, cmdKey, 420);
      await r.wait(160);
      press(r, oneKey, 200);
      await r.wait(70);
      await B.ask(r);
      await r.wait(4400);
    }

    const script = {
      layout(r) {
        setStep(r.from || 1);
        hero.classList.toggle('is-compact', compact());
        win.style.minHeight = '';
        const reach = Math.max(A.layout(word), B.layout(phrase));
        win.style.minHeight = Math.max(compact() ? 0 : 560, reach + 28) + 'px';
        const W = win.getBoundingClientRect(), R = word.getBoundingClientRect(), PR = phrase.getBoundingClientRect();
        const y = PR.top - W.top + PR.height / 2;
        pos = {
          start: { x: W.width * 0.72, y: Math.min(W.height - 60, R.bottom - W.top + 170) },
          word: { x: R.left - W.left + R.width * 0.42, y: R.top - W.top + R.height / 2 },
          selFrom: { x: PR.left - W.left, y },
          selTo: { x: PR.right - W.left, y },
        };
        // Where each character of the phrase ends, for the selection to snap to.
        const text = [...phrase.childNodes].find(n => n.nodeType === 3);
        const range = document.createRange();
        edges = [0];
        for (let i = 1; i <= text.length; i++) {
          range.setStart(text, 0);
          range.setEnd(text, i);
          edges.push(range.getBoundingClientRect().width);
        }
        beam.style.transform = at(pos.start);
      },

      async build(r) {
        const from = r.from || 1;
        if (r.still) {
          if (from === 1) return point(r);
          await select(r, false);
          if (from === 3) await ask(r);
          return;
        }
        if (from === 3) {
          r.instant = true;
          await select(r, false);
          r.instant = false;
        }
        if (from === 1) await point(r);
        if (from <= 2) await select(r, from === 1);
        await ask(r);
      },

      async out(r) {
        r.fade(B.wrap, 0, 320);
        r.fade(beam, 0, 320);
        r.fade(sel, 0, 320);
        r.fade(chordB, 0, 300);
        r.fade(chordA, 1, 300);
        await r.wait(1100);
      },
    };

    heroRunner = new Runner(hero, script);
    runners.push(heroRunner);
    stepBtns.forEach(b => b.addEventListener('click', () => {
      heroRunner.start(+b.dataset.step, reduce.matches || userPaused);
    }));
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
      // The little ⌥ Space in the corner goes down: the cursor only points, the keys ask.
      async press(r) {
        $$('.vig-keys kbd', box).forEach((k, i) => r.anim(k, [
          { transform: 'none', color: '', borderColor: '' },
          { transform: 'translateY(1px)', color: 'var(--accent)', borderColor: 'var(--accent)', offset: .25 },
          { transform: 'translateY(1px)', color: 'var(--accent)', borderColor: 'var(--accent)', offset: .7 },
          { transform: 'none', color: '', borderColor: '' },
        ], { duration: 420, delay: i * 90, fill: 'none', easing: 'ease-out' }));
        // Then they step aside for the panel.
        const keys = $('.vig-keys', box);
        if (keys) r.fade(keys, 0, 300, { delay: 600 });
        await r.wait(220);
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
    const one = $('.vread-one', box), all = $('.vread-all', box);
    const target = $('.vword', box);
    return {
      layout() { p.layout(target); },
      async build(r) {
        await p.point(r);
        await p.press(r);
        r.anim(one, [{ opacity: 0, transform: 'scaleX(.4)' }, { opacity: 1, transform: 'none' }], { duration: 220 });
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
    const one = $('.vread-one', box);
    const target = $('.vword', box);
    return {
      layout() { p.layout(target); },
      async build(r) {
        await p.point(r);
        await p.press(r);
        r.anim(one, [{ opacity: 0, transform: 'scaleX(.4)' }, { opacity: 1, transform: 'none' }], { duration: 220 });
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
    const one = $('.vread-one', box);
    const target = $('.vword', box);
    const searching = $('.searching', box);
    return {
      layout() { p.layout(target); },
      async build(r) {
        await p.point(r);
        await p.press(r);
        r.anim(one, [{ opacity: 0, transform: 'scaleX(.4)' }, { opacity: 1, transform: 'none' }], { duration: 220 });
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
      // A step picked while paused shows its still; carry on from there.
      if (!userPaused && heroRunner?.still && !reduce.matches) heroRunner.start(heroRunner.from);
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
