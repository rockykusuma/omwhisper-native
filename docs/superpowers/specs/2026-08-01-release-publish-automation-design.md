# Release publishing automation — design

**Date:** 2026-08-01 · **Status:** approved

## 1. The problem

Cutting a release is five steps. The script does one of them and prints a reminder for the rest:

```
Next: upload OmWhisper_2.0.4_arm64.dmg to the GitHub release, and publish
.build-release/appcast/appcast.xml at https://omwhisper.in/appcast.xml
```

A printed reminder is not a check. It cannot fail, cannot be observed, and cannot report that
it was ignored — the same shape as the three things wrongly recorded as verified on 2026-07-31
(see `CLAUDE.md` § Verification).

It was ignored. The website's `DOWNLOAD_URL` was a version-pinned constant that nothing bumped,
so **omwhisper.in served 2.0.0 for four consecutive releases** — the build with the silent
auto-update, the dead Check for Updates button and the Documentation link pointing at the frozen
Tauri docs. Every visitor got the worst shipped version. Fixed 2026-08-01 by deriving the URL
from `appcast.xml` at site build time, which removes step 5 but leaves 2–4 manual.

The worse failure is still live: **forgetting to publish `appcast.xml` at all.** Sparkle would
offer nothing, so no existing install would ever be told an update exists — silently, with the
GitHub release looking perfectly healthy.

## 2. Decisions

| Question | Decision | Why |
|---|---|---|
| Scope | One command, end to end, then verify | Chosen by R over a review gate and over full CI |
| Structure | New `scripts/publish-release.sh`, invoked by `build-release.sh --publish` | Notarization takes ~10 min; a publish failure must be re-runnable without rebuilding |
| Default behaviour | Unchanged — a bare `build-release.sh` publishes nothing | Building and releasing are different acts; publishing is outward-facing |
| Release notes | `docs/releases/vX.Y.Z.md` if present, else `gh --generate-notes` | Real notes when a release deserves them; no friction for a patch |
| Web repo location | `$OMWHISPER_WEB_REPO`, default `../omWhisperWebApp` | `.env` already carries machine-specific config and is gitignored |
| Idempotency | `gh release view \|\| create`; `gh release upload --clobber` | Re-running after a timeout must converge, not duplicate |

## 3. Preflight — before the build, not after

Every one of these is cheap and currently discovered late, after ten minutes of notarization:

- `gh auth status` succeeds
- `$OMWHISPER_WEB_REPO` exists, is on `main`, has a clean working tree
- **the native repo has a clean working tree**
- build number exceeds the live appcast *(already implemented, keep as-is)*
- Sparkle's `generate_appcast` binary is resolvable *(already implemented, move earlier)*

The native-repo check is correctness, not hygiene. `gh release create` tags whatever commit is
checked out; publishing from a dirty tree produces a tag that does not correspond to the binary
users download, and nothing downstream would ever reveal it.

Refusing on a dirty *web* repo matters for a different reason: the publish step commits and
pushes that repo, and it must never sweep up unrelated work in progress.

## 4. Publish

1. `gh release create vX.Y.Z` (or reuse existing) with notes per §2
2. `gh release upload --clobber` the `.dmg`
3. Copy `$BUILD_DIR/appcast/appcast.xml` → `$WEB/public/appcast.xml`
4. Commit and push the web repo

Step 4 triggers Vercel. Because `DOWNLOAD_URL` now derives from the appcast at site build time,
the download button follows automatically — there is no separate step to forget, which is the
point.

## 5. Verification — the actual deliverable

Replaces the printed reminder. Each check can come back negative and exits non-zero:

| Check | Fails when |
|---|---|
| Poll `omwhisper.in/appcast.xml` until `sparkle:version` == the new build (bounded timeout) | The appcast never published, or Vercel did not deploy |
| Fetch the live JS bundle; assert it references the new `.dmg` filename | The site build did not pick up the new appcast |
| `curl -I` the enclosure URL **read from the live appcast** → expect 200 | `--download-url-prefix` is wrong, or the asset upload failed |

The third deliberately reads the URL out of the deployed feed rather than from a local shell
variable. A local variable can only confirm what this script already believes; the deployed feed
is what Sparkle will actually fetch, and it is the only version of that URL that can disagree.

Any timeout is a failure, not a warning. A release that cannot be observed as live is not a
release — and this check alone, with steps 2–4 still done by hand, would have caught the 2.0.0
drift on the day it happened.

## 6. Out of scope

- Moving the build into GitHub Actions (considered, rejected as a separate project — needs the
  Developer ID cert, its password, and the Apple app-specific password in repo secrets)
- Windows / the frozen Tauri release
- Rollback or un-publishing
- Bumping `CURRENT_PROJECT_VERSION` automatically — the existing guard already refuses to build
  a release nobody would be offered, which is the failure that matters
