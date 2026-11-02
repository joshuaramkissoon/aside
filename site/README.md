# Aside website

A single static page: hand-written HTML, CSS and JS. No build step.

```sh
python3 -m http.server 4417 --directory site    # then open http://localhost:4417
```

## Deploy

Point a Vercel project at this folder (Root Directory: `site`, Framework: Other, no build command). `.vercelignore` keeps the OG image source out of the deploy.

Once the domain is known, make `og:image` in `index.html` an absolute URL (`https://<domain>/og.png`); some crawlers ignore relative ones.

## Files

- `index.html`, `styles.css`, `main.js`: the page. The demos are WAAPI animations driven by small scripts in `main.js`; with `prefers-reduced-motion` they render their final state. The hero plays three captioned moments (point, select, keep asking); its step buttons jump to one, and show it as a still when paused or with reduced motion.
- `try.js`, `answers.js`: "Try it here". Hover a word and press ⌥ Space, select a phrase and press it, or click; on touch, tap a word or select and tap "Look up", and the answer opens as a bottom sheet. `answers.js` holds the model's raw replies in the app's format, made with the app's prompt (`bench/cases.json`, cases `try-*`; Glasswing through the app's search flow, `Aside --ask`), and `try.js` parses them like the app. No network calls. To add a word, wrap it in `<span class="t" data-look="id">` and add its reply and both follow-ups under that id.
- `fonts/`: Newsreader (roman and italic), Latin subset, optical size pinned at 24, weights 400 to 600.
- `og.png`: social card, a screenshot of `og/og.html` at 1200x630 in light mode.
- `favicon.png`, `img/`: from `docs/icon.png`.
