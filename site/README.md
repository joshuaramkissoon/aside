# Aside website

A single static page: hand-written HTML, CSS and JS. No build step.

```sh
python3 -m http.server 4417 --directory site    # then open http://localhost:4417
```

## Deploy

Point a Vercel project at this folder (Root Directory: `site`, Framework: Other, no build command). `.vercelignore` keeps the OG image source out of the deploy.

Once the domain is known, make `og:image` in `index.html` an absolute URL (`https://<domain>/og.png`); some crawlers ignore relative ones.

## Files

- `index.html`, `styles.css`, `main.js`: the page. The demos are WAAPI animations driven by small scripts in `main.js`; with `prefers-reduced-motion` they render their final state.
- `fonts/`: Newsreader (roman and italic), Latin subset, optical size pinned at 24, weights 400 to 600.
- `og.png`: social card, a screenshot of `og/og.html` at 1200x630 in light mode.
- `favicon.png`, `img/`: from `docs/icon.png`.
