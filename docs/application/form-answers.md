# Tether bounty application — form answers

Drafted on **2026-05-14** for paste-into-form at submission time
(YK-229). All content below is ready-to-paste unless tagged
`<USER-PROVIDED: …>`.

Bounty: <https://tether.dev/grants/bounties/2885283454/>
Bounty deadline: **2026-06-24** (≈ 5.7 weeks from today)

The form's exact field set isn't visible without signing in, so each
section below pairs a likely field name with our prepared answer and a
character-count hint. On submission day we paste each, then proofread
for any field the form actually has that's not represented here.

---

## Section 1 — Identity

| Field | Answer |
| --- | --- |
| Email | `tolgayayci@protonmail.com` |
| Full Name | `<USER-PROVIDED: leave blank per direction, or fill when ready>` |
| Team / Company | `<USER-PROVIDED: leave blank per direction>` |
| GitHub username | `<USER-PROVIDED: github.com/<handle>>` |
| Website / proposal URL | `<NOTION-URL: filled when YK-227 ships>` |
| Country / timezone | `<USER-PROVIDED: country, UTC offset>` |

---

## Section 2 — Content

### Field: **Why this bounty?** (≈100 words, hard cap likely 500-1000 chars)

> QVAC's "stable intelligence" mission — local-first, user-owned AI on
> open infrastructure — aligns with what makes Tether's broader stack
> compelling. Swift is the largest native developer ecosystem after
> Android, and right now there's no first-class path for an iOS or
> macOS app to use the QVAC SDK without going through React Native or
> a JS bridge. Closing that gap unlocks a real new surface for QVAC.
> The dual-transport design (UDS for desktop, BareKit IPC for iOS) is
> de-risked by `bare-rpc-swift` already existing; the proposal walks
> through the milestone-by-milestone plan with explicit acceptance
> criteria. I want to ship this end-to-end, not prototype it.

**Word count:** 99. **Char count:** 745.

### Field: **Relevant Experience** (≈150 words, hard cap likely 1000-2000 chars)

> Full-stack web3 developer with extensive TypeScript and Swift
> shipping experience across native iOS, JS-runtime backends, and the
> Bare/Pear ecosystem. Comfortable across the layers this bounty
> requires: TypeScript Compiler API (the code-gen pipeline reads
> `@qvac/sdk` `.d.ts` and emits idiomatic Swift), Swift concurrency
> (actors + `AsyncThrowingStream`), and low-level transport work
> (`Network.framework` `NWConnection .unix`, length-prefixed binary
> framing).
>
> Spent the lead-up to applying reading the QVAC SDK source end-to-end
> (handler registry, schemas, error tables, `__init_config` handshake),
> documenting it in a reproducible spec, building a working M1
> end-to-end against a real Bare worker fixture (ping round-trip over
> UDS, 250 sequential + 50 concurrent), and writing the planning that
> turned into the milestone breakdown linked in the proposal.
> `<USER-PROVIDED: optionally add 1-3 prior project URLs to anchor the
> claim — e.g. a Swift package you maintain, a TypeScript codegen tool,
> or a JS-runtime contribution>`

**Word count:** 154 (incl. placeholder). **Char count without
placeholder:** 935.

### Field: **Past grant / bounty work** (optional)

> `<USER-PROVIDED: prior grants/bounties if any; "first application
> through Tether grants" is fine to say if true>`

### Field: **References** (optional)

> `<USER-PROVIDED: 0-3 references. OK to leave blank — the proposal
> + GitHub history is the primary signal>`

---

## Section 3 — Plan

### Field: **Estimated timeline**

> 6 weeks across 3 milestones (M1 → M3), targeting completion **before
> the 2026-06-24 deadline**. M1 (code-gen + IPC transport) is already
> built locally and ready to push the moment the application is
> accepted — `docs/qvac-sdk-deliverables-verification.md` is the
> gate evidence. M2 (core API surface) and M3 (RAG + plugins + DocC +
> example app + release) are sequenced day-by-day in the proposal.

### Field: **Milestones** (if the form asks for a structured breakdown)

| Milestone | Target | Deliverables |
| --- | --- | --- |
| M1 — Code-gen tooling & IPC transport | **already shipped locally; ready to push on acceptance** | TypeScript-Compiler-API codegen → 30 Swift files; `UDSTransport` via `NWConnection .unix`; `RPCBridge` adapting `bare-rpc-swift`; PING round-trip against real Bare worker (250 sequential + 50 concurrent); CI on macOS-14 ARM64 with LCOV coverage |
| M2 — Core API surface | ~3 weeks after M1 acceptance | `QVACClient` actor wired through to `RPCBridge`; `__init_config` handshake; `completion` (streaming + blocking); `transcribe` / `translate` / `textToSpeech` / `ocr` / `diffusion` / `upscale`; cancellation via worker `cancel`; iOS BareKit transport; iOS Simulator CI matrix |
| M3 — RAG, plugins, docs, distribution | by deadline | 9 RAG ops; `invokePlugin` + stream; DocC catalog (95%+ symbol coverage) + 2 tutorials; SwiftUI streaming-chat example app (macOS + iOS); Swift Package Index listing; v0.1.0 release |

### Field: **Will you accept the bounty agreement?**

> Yes.

---

## Section 4 — Pointers

| Field | Answer |
| --- | --- |
| Proposal URL | `<NOTION-URL: filled when YK-227 ships>` |
| Source code | (held private until acceptance per project rule; immediately public after) |
| Open questions you've prepared | yes — `docs/application/open-questions.md` (in the proposal) lists 12 prioritized questions across 4 tiers |

---

## Self-audit (VTs from the issue body)

| VT | Status |
| --- | --- |
| 1 — All required fields answered | ✅ Every field this draft anticipates has a prepared answer or a typed placeholder slot |
| 2 — Character counts | ✅ "Why this bounty?" 99 words / 745 chars; "Relevant Experience" 154 words / 935 chars. Both fit any reasonable form-field cap (most are 500-2000 chars). |
| 3 — Links resolve | Will be re-checked at paste time; `tether.dev/grants` is the live bounty page; Notion URL filled when YK-227 ships |
| 4 — Tone consistency | ✅ Confident, concrete ("M1 is already built locally and ready to push the moment the application is accepted"); no hedge words like "we'll try" or "hopefully" |
| 5 — No leaks | ✅ All identity fields are typed placeholders; the only personal data baked in is the email already on file (`tolgayayci@protonmail.com`); no SDK pre-release info, no QVAC private details |
| 6 — Backup | ✅ This doc is the backup — paste fails or session times out, re-paste from here |

## What's still needed from you before YK-229 paste-and-submit

1. **Fill identity placeholders**: full name (or leave blank), GitHub username, country/timezone.
2. **Add 1-3 prior-project URLs to "Relevant Experience"** so the experience claim has concrete anchors. Or tell me which projects to reference and I'll edit in place.
3. **Confirm the Notion URL** once YK-227 ships (next issue).
4. **Decide whether to leave team/company blank** as the original direction said, or fill it.
5. **References + past grants** — leave blank or fill, both are fine.

I'll wait for go-ahead at YK-229 (the actual submit step) before claiming any of this is final.
