# Landing "More than dictation" Section — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Surface the nine non-dictation features on `omwhisper.in` in one restrained section, per `docs/superpowers/specs/2026-08-01-landing-beyond-dictation-section-design.md`.

**Architecture:** One new component (`BeyondDictation.tsx`) in the **web repo**, rendered from `Landing.tsx` between how-it-works and faq. Three full cards + six compact rows linking to `/docs/beyond`. Reuses the repo's existing vocabulary — shared `SectionHeader`, `--neo-*` CSS variables, `framer-motion` + `useInView` reveals, emoji tiles. No new dependencies, no new tokens, no edits to existing components beyond the one import + render in `Landing.tsx`.

**Tech Stack:** React + TypeScript + Vite, Tailwind utility classes, framer-motion, react-router-dom.

## Global Constraints

- **Work in `~/Documents/PersonalProjects/omWhisperWebApp`**, not the app repo. That repo has no test suite; `npm run build` is the gate.
- **Copy is load-bearing. These claims must not drift:**
  - Vocabulary: **never** "teach it your jargon" — engine biasing is measured inert on Apple and Parakeet; only replacement rules + fuzzy correction can be claimed.
  - Cross-lingual: no key, no network required.
  - Meetings: on-device regardless of the dictation backend.
  - No invented numbers or non-existent features (S6 found a fabricated 99.2% accuracy stat and a "Voice Analysis" panel).
- Do not touch `Hero`, `BentoFeatures`, `HowItWorks`, `FAQ`.
- Commit style: emoji conventional commits. **Do not push** — the user decides when the site deploys.

---

### Task 1: The `BeyondDictation` component

**Files:**
- Create: `src/components/BeyondDictation.tsx`

**Interfaces:**
- Produces: `export default function BeyondDictation()` — a self-contained section, no props.
- Consumes: `./shared/SectionHeader`, `framer-motion`, `react-router-dom`'s `Link`.

- [ ] **Step 1: Write the component**

Create `src/components/BeyondDictation.tsx`:

```tsx
import { useRef } from 'react';
import { motion, useInView } from 'framer-motion';
import { Link } from 'react-router-dom';
import SectionHeader from './shared/SectionHeader';

/** The three worth a card: the competitive headline, the one closest to
 *  dictation itself, and the one nobody else does. */
const CARDS = [
  {
    icon: '👥',
    title: 'Meetings',
    desc: 'Records a call after asking you, then transcribes it, separates the speakers and writes the notes — entirely on your Mac, even if you dictate through a cloud engine.',
  },
  {
    icon: '✨',
    title: 'AI polish',
    desc: 'Removes filler and fixes self-corrections in a style you choose. Runs on-device, or through Ollama, or a provider you configure.',
  },
  {
    icon: '🌏',
    title: 'Cross-lingual',
    desc: 'Speak Telugu, Hindi or Hinglish, get polished English. No key, no network.',
  },
];

/** Everything else, one line each. "Vocabulary" deliberately claims only
 *  replacement rules and fuzzy correction — engine biasing measurably does
 *  nothing on Apple Speech or Parakeet, so "teach it your jargon" would be a
 *  claim the app cannot keep. */
const ROWS = [
  { icon: '🧠', title: 'Memory', desc: 'Search what was on your screen later, with a written summary of each day.' },
  { icon: '↩️', title: 'Reply assist', desc: 'Double-tap right ⌥ to draft a reply from the conversation in front of you.' },
  { icon: '🗂', title: 'Brain-dump', desc: 'Talk for a while, get structure back instead of a wall of text.' },
  { icon: '📖', title: 'Vocabulary', desc: 'Replacement rules and fuzzy correction fix the words that always come out wrong.' },
  { icon: '🕘', title: 'History', desc: 'Every transcript, searchable and local, exportable whenever you want.' },
  { icon: '🔌', title: 'MCP server', desc: 'Give Claude Desktop read-only access to your own history, memory and meetings.' },
];

export default function BeyondDictation() {
  const ref = useRef<HTMLDivElement>(null);
  const isInView = useInView(ref, { once: true, margin: '-80px' });

  return (
    <div className="py-16 md:py-24 px-6">
      <div className="max-w-5xl mx-auto">
        <SectionHeader
          eyebrow="More than dictation"
          heading="It does more. It just doesn't do it uninvited."
          subtext="Every one of these is off until you turn it on."
          align="center"
          className="mb-10 md:mb-16"
        />

        <div ref={ref} className="grid grid-cols-1 md:grid-cols-3 gap-5 mb-5">
          {CARDS.map((card, i) => (
            <motion.div
              key={card.title}
              initial={{ opacity: 0, y: 24 }}
              animate={isInView ? { opacity: 1, y: 0 } : { opacity: 0, y: 24 }}
              transition={{ duration: 0.55, ease: [0.22, 1, 0.36, 1], delay: i * 0.1 }}
              className="flex flex-col gap-3 p-6 rounded-3xl"
              style={{
                background: 'var(--neo-bg)',
                boxShadow: '8px 8px 16px var(--neo-shadow-dark), -8px -8px 16px var(--neo-shadow-light)',
              }}
            >
              <div
                className="flex items-center justify-center w-14 h-14 rounded-2xl"
                style={{
                  background: 'var(--neo-inset-bg)',
                  boxShadow: 'inset 4px 4px 8px var(--neo-shadow-dark), inset -4px -4px 8px var(--neo-shadow-light)',
                  fontSize: 24,
                }}
              >
                {card.icon}
              </div>
              <h3 className="font-display font-bold text-lg" style={{ color: 'var(--neo-text)' }}>
                {card.title}
              </h3>
              <p className="text-sm leading-relaxed" style={{ color: 'var(--neo-text-muted)' }}>
                {card.desc}
              </p>
            </motion.div>
          ))}
        </div>

        <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
          {ROWS.map((row, i) => (
            <motion.div
              key={row.title}
              initial={{ opacity: 0, y: 16 }}
              animate={isInView ? { opacity: 1, y: 0 } : { opacity: 0, y: 16 }}
              transition={{ duration: 0.5, ease: [0.22, 1, 0.36, 1], delay: 0.3 + i * 0.06 }}
              className="flex items-start gap-4 p-4 rounded-2xl"
              style={{
                background: 'var(--neo-bg)',
                boxShadow: '5px 5px 10px var(--neo-shadow-dark), -5px -5px 10px var(--neo-shadow-light)',
              }}
            >
              <span className="flex-shrink-0 text-xl leading-none pt-0.5">{row.icon}</span>
              <div>
                <h4 className="font-display font-bold text-sm mb-0.5" style={{ color: 'var(--neo-text)' }}>
                  {row.title}
                </h4>
                <p className="text-sm leading-relaxed" style={{ color: 'var(--neo-text-muted)' }}>
                  {row.desc}
                </p>
              </div>
            </motion.div>
          ))}
        </div>

        <motion.p
          initial={{ opacity: 0 }}
          animate={isInView ? { opacity: 1 } : { opacity: 0 }}
          transition={{ duration: 0.5, delay: 0.7 }}
          className="text-center text-sm mt-10"
          style={{ color: 'var(--neo-text-muted)' }}
        >
          <Link
            to="/docs/beyond"
            className="underline underline-offset-4 hover:opacity-80"
            style={{ color: 'var(--neo-accent)' }}
          >
            How each one works, and what it stores
          </Link>
        </motion.p>
      </div>
    </div>
  );
}
```

- [ ] **Step 2: Verify the CSS variables used actually exist**

The component uses `--neo-bg`, `--neo-inset-bg`, `--neo-shadow-dark`, `--neo-shadow-light`, `--neo-text`, `--neo-text-muted`, `--neo-accent`. Confirm each is defined rather than assuming — an undefined variable renders as a transparent/black surface and looks broken:

```bash
cd ~/Documents/PersonalProjects/omWhisperWebApp
for v in neo-bg neo-inset-bg neo-shadow-dark neo-shadow-light neo-text neo-text-muted neo-accent; do
  printf "%-20s %s\n" "$v" "$(grep -rc -- "--$v:" src/ | grep -v ':0' | head -1)"
done
```

Expected: every variable has at least one definition. If `--neo-inset-bg` is absent, substitute the value `HowItWorks.tsx` uses for its inset step-number circle (read that file and match it exactly).

- [ ] **Step 3: Commit**

```bash
git add src/components/BeyondDictation.tsx
git commit -m "✨ feat(landing): a section for what the app does beyond dictation"
```

---

### Task 2: Render it from `Landing.tsx`

**Files:**
- Modify: `src/pages/Landing.tsx`

**Interfaces:**
- Consumes: Task 1's component.

- [ ] **Step 1: Import and render**

Add the import alongside the others:

```tsx
import BeyondDictation from '../components/BeyondDictation';
```

Insert the section between how-it-works and faq:

```tsx
        <section id="how-it-works">
          <HowItWorks />
        </section>
        <section id="beyond">
          <BeyondDictation />
        </section>
        <section id="faq">
          <FAQ />
        </section>
```

- [ ] **Step 2: Build**

```bash
cd ~/Documents/PersonalProjects/omWhisperWebApp && npm run build 2>&1 | tail -8
```

Expected: `✓ built in …`, no TypeScript errors.

- [ ] **Step 3: Commit**

```bash
git add src/pages/Landing.tsx
git commit -m "✨ feat(landing): render the beyond-dictation section between how-it-works and faq"
```

---

### Task 3: Look at the rendered page

**This task is not optional and cannot be replaced by reading the source.** Both landmines S6 found — a fabricated "Voice Analysis" panel and an invented 99.2% accuracy figure — were invisible in source review and obvious on screen.

- [ ] **Step 1: Serve the built site locally**

```bash
cd ~/Documents/PersonalProjects/omWhisperWebApp && npm run preview 2>&1 | tail -3
```

- [ ] **Step 2: Open it and check, at desktop and at ~390px wide**

1. The section sits between How It Works and FAQ.
2. Three cards read as a row on desktop and stack cleanly on mobile; six rows are two columns on desktop, one on mobile.
3. Neumorphic surfaces match the sections above and below — not flat, not a different grey.
4. Reveal animation fires once on scroll and is not showy.
5. The `/docs/beyond` link navigates correctly.
6. **Read every word of the copy on screen.** Specifically confirm Vocabulary does not promise to learn jargon, and Cross-lingual does not imply a key or a network.

- [ ] **Step 3: Report to the user with the deploy decision**

The site deploys on push. Do **not** push — report that the section is built, built-clean and locally verified, and let the user decide when it goes live.
