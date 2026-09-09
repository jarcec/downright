# R6 Gate — Sandbox × Launch Services × CLI

**Date:** 2026-09-08
**Build:** Downright 0.0.1, ad-hoc signed, `com.apple.security.app-sandbox` +
`files.user-selected.read-write`, installed at `/Applications/Downright.app`
**Shim:** `cli/downright` symlinked to `/opt/homebrew/bin/downright`
**Gate defined in:** `../03-Plan/v0-plan.md` Phase 0; risk R6 in `TRD.md` §13

---

## Verdict: PASS. R6 retired. R10 (atomic rewrites) also retired.

| Test | Result |
|---|---|
| `downright existing.md` from Terminal → sandboxed app reads and renders the file | **Pass** — content rendered; verified by window capture |
| `downright new.md` where the file does not exist (shim `touch`es it, plan D3) | **Pass** — 0-byte file created, opened as an empty document tab |
| External atomic rewrite while open (`printf > tmp && mv tmp existing.md`) | **Pass** — app detected the change and reloaded the new contents unprompted (document unmodified) |
| Repeated external rewrite (second `mv`) | **Pass** — reloaded again; the sandbox grant survived the inode change |
| Shim returns immediately with exit 0 | **Pass** |
| Two paths in one invocation | **Pass** — both opened (as tabs in one window) |

Not exercised by this gate (needs typing; verify in first manual session): saving an
edit from the app back to a CLI-opened path. NSDocument's coordinated write through the
Launch-Services-granted URL is the standard path and is not expected to differ.

## Negative control

Launching the binary directly — `Downright.app/Contents/MacOS/Downright file.md` — with the
path as `argv` (no Launch Services involvement) produced *"The document could not be
opened. You don't have permission."* The grant really does come from Launch Services and
nothing else, which is why the shim must go through `open`.

## Notes

- **Launch Services grants the sandbox extension for shell-opened paths**, exactly as
  for Finder double-click. `downright FILE` is therefore compatible with App Store
  distribution. The distribution decision (PRD OQ-5) stands.
- **Atomic external writers do not revoke access.** `NSDocument`'s file-presenter
  machinery observed the `mv` and `revert(toContentsOf:)` re-read the new file
  successfully. TRD §9's R10 row is downgraded to "verified OK".
- **Signing:** the Apple Development certificate on this machine expired 2024-06, so
  builds are ad-hoc signed (`project.yml`). App Sandbox is enforced identically under an
  ad-hoc signature; nothing in this gate depends on the identity. A current certificate is
  needed only for TestFlight / App Store.
- **Launch Services ambiguity:** with a build product and an installed copy sharing the
  bundle identifier, `open -a Downright` picked the build product. The shim now prefers
  `/Applications/Downright.app` when present.
- **Unified logging:** `os.Logger` lines at `.info`/`.notice` from the sandboxed app were
  not retrievable with `log show` during the gate; verification relied on window captures.
  Worth a look before relying on logs for diagnostics.
