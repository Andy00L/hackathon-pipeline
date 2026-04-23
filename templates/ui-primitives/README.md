# ui-primitives — auto-injected starter kit

This directory is auto-copied into every new project by
`hackathon.sh::inject_ui_primitives`. Its purpose is to give every
pipeline-bootstrapped project a consistent, working design system from
the first commit so the UI never starts from Tailwind defaults.

## Layout

```
ui-primitives/
├── DESIGN-PRINCIPLES.md   Dev-facing rulebook. Read before extending.
├── lib/
│   └── fonts.ts           Typed Inter loader. Single source of truth.
├── primitives/
│   ├── Badge.tsx          Dot + label chip, caller-owned color.
│   ├── Breadcrumb.tsx     Muted trail, last item promotes to ink.
│   ├── Button.tsx         5 variants / 3 sizes, Apple easing.
│   ├── Card.tsx           rounded-2xl surface on --color-card.
│   ├── FadeInOnView.tsx   One-shot IntersectionObserver reveal.
│   ├── Header.tsx         Fixed 48px bar, backdrop blur, hairline.
│   ├── Input.tsx          Hairline border default, ink on focus.
│   ├── Pill.tsx           Tone dot + label, 5 semantic tones.
│   ├── SearchPill.tsx     Spotlight-style command palette.
│   └── index.ts           Barrel export for `@/ui-primitives`.
└── styles/
    └── globals.css        Tailwind v4 entry + @theme tokens + keyframes.
```

## Wiring into a Next.js project

1. Import `globals.css` once in `app/layout.tsx`:
   ```ts
   import "../ui-primitives/styles/globals.css";
   import { inter } from "../ui-primitives/lib/fonts";
   ```
2. Put `inter.variable` on the `<html>` element so `--font-inter` is
   available to the `@theme` block.
3. Configure a tsconfig path alias so imports stay short:
   ```json
   { "compilerOptions": { "paths": { "@/ui-primitives": ["./ui-primitives/primitives"] } } }
   ```
4. Use the primitives:
   ```tsx
   import { Button, Card, Pill } from "@/ui-primitives";
   ```

## Re-run behavior

The injection function uses `cp -rn` (no-clobber), so per-project
edits made to files in this directory are preserved across re-runs
of `hackathon.sh`. Only files that do not yet exist in the project
get copied.

## Evolving the system

Do NOT edit this directory to improve the starter kit for the next
project — those edits live inside the project and will not propagate.
To evolve the kit for future projects, edit the files in the pipeline
repo at `templates/ui-primitives/`. New projects pick up the change
on their first `inject_ui_primitives` call; existing projects keep
their local copy.

## Extending in-place

When a project needs a primitive that isn't here, read
`DESIGN-PRINCIPLES.md` first, then add the new primitive to
`primitives/` and re-export it from `primitives/index.ts`. Do not
scatter primitives across `src/components/`.
