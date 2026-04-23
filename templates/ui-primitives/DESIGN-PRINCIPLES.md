# Design principles (auto-injected starter kit)

## The three moves that make the aesthetic
1. Warm off-white canvas `#FAFAF8` with hairline borders
   `rgba(0,0,0,0.06)` instead of gray lines.
2. Single font (Inter) with Apple easing `cubic-bezier(0.32, 0.72, 0, 1)`
   on every transition. Overshoot animations use
   `cubic-bezier(0.34, 1.56, 0.64, 1)`.
3. Scroll reveals at card granularity via `<FadeInOnView>` — never
   row-level, never content-level, never hero headlines.

## Design tokens

```css
@theme {
  --font-sans: var(--font-inter), ui-sans-serif, system-ui, sans-serif;

  /* Off-white warm neutral — beige stripped ~90% */
  --color-bg: #FAFAF8;
  --color-card: #FFFFFF;

  /* Apple-style neutrals */
  --color-ink: #1D1D1F;
  --color-muted: #86868B;
  --color-hairline: rgba(0, 0, 0, 0.06);

  /* Map base */
  --color-map-neutral: #ECECEC;
  --color-map-stroke: #D2D2D2;

  /* Stance — muted diverging palette: rose → amber → gold → neutral → mint.
     Ordered from most restrictive to most favorable. Shared across map fills,
     badges, and summary bar segments. */
  --color-stance-restrictive: #D98080;
  --color-stance-concerning: #D9A766;
  --color-stance-review: #D9C980;
  --color-stance-none: #C9CBD1;
  --color-stance-favorable: #7EBC8E;
}
```

## Keyframes available in styles/globals.css
- `drill-in` — entrance cue when zooming into a nested region (scale 0.92 → 1).
- `drill-out` — entrance cue when zooming out of a region (scale 1.08 → 1).
- `fade-rise` — soft cross-fade with a 6px upward translate for summary swaps.
- `highlight-sweep` — gold underline grows left-to-right behind bolded phrases.
- `live-dot-breath` — breathing halo around a "live" status dot (2s loop).
- `popup-enter` — scale+translate entrance with gentle overshoot (1.56 easing).
- `shake` — horizontal shake for rejected-input or invalid-action feedback.

Helper classes already wired in globals.css: `.animate-drill-in`,
`.animate-drill-out`, `.animate-fade-rise`, `.animate-popup-enter`,
`.animate-shake`, `.highlight-sweep`, `.live-dot`, plus the grid-rows
`.accordion` pattern and the `.chevron[data-open]` rotation.

## Primitives in the kit
- `Button`, `Input` — form chrome, 5 variants / 3 sizes, focus ring on ink.
- `Card` — rounded-2xl surface on `--color-card` with a 1px shadow.
- `Pill` — tone dot + label; tones map to the muted diverging palette.
- `Badge` — generic dot + label; color is caller-owned (any CSS color).
- `Header` — fixed 48px bar with backdrop blur and hairline bottom border.
- `Breadcrumb` — muted trail; last item promotes to ink.
- `SearchPill` — Spotlight-style command palette with keyboard nav.
- `FadeInOnView` — single IntersectionObserver, one-shot reveal.

## Rules
- No saturated brand colors in primitives. Domain colors (status,
  stance, priority) are defined per-project by wrapping Badge/Pill.
- Every interactive element has visible focus + hover + active +
  disabled states.
- Respect prefers-reduced-motion — FadeInOnView already does.
- Data-viz: muted palette on neutral ground. Saturation implies
  marketing, not data.
- No em-dashes, no "seamlessly", no "unprecedented", no
  "revolutionary" in UI copy.

## Extending the system
When you need a component not in primitives/:
1. Start from Button or Card. Same easing, hairline borders, padding.
2. New colors go into styles/globals.css @theme block, not inline.
3. Put the new primitive in primitives/ (not scattered across
   src/components/).

## Forbidden patterns (anti-AI-slop)
- Tailwind's default color palette for anything meaningful
- Grid-of-3-equal-cards hero
- "Welcome to <AppName>" hero
- Gradient buttons
- Violet-to-blue gradient anywhere
- Black bg + neon green text
