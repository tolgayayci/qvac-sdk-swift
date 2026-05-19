# DocC hosting

YK-217 wires the DocC archive to GitHub Pages via
`.github/workflows/docc.yml`. The workflow builds, transforms, and
deploys on every push to `main` and on each release tag.

## Why Xcode's `docbuild` instead of the SwiftPM plugin

The SwiftPM `swift-docc-plugin` runs `swift-symbolgraph-extract`
on every target as a separate process. That extractor drops the
framework search path (`-F`) when invoking Clang on Swift's
generated bridging header for binary targets. Result: any module
that imports a binary `xcframework` (`BareKit` in our case via
`BareKitBridge`) fails with `'BareKit/BareKit.h' file not found`
during DocC build.

`xcodebuild docbuild` doesn't have this gap — Xcode's docc-build
pipeline plumbs the framework search path correctly through symbol
extraction. The trade-off is a macOS runner (which we already have
in CI) instead of a portable Linux build. Documented as the
accepted approach in `docs/qvac-sdk-deliverables-verification.md` §1.7.

## Workflow shape

```yaml
# Trigger: push to main + tag releases.
on: { push: { branches: [main], tags: ['v*'] }, workflow_dispatch: }

permissions:
  contents: read
  pages: write
  id-token: write     # Pages OIDC

jobs:
  build-docc:           # macos-14, Xcode 16
    1. checkout
    2. scripts/download-barekit.sh
    3. scripts/docc-coverage.sh 95     # gate on ≥95% before archive
    4. xcodebuild docbuild -scheme QVACClient
    5. docc process-archive transform-for-static-hosting
    6. upload-pages-artifact

  deploy:               # ubuntu-latest
    1. actions/deploy-pages
```

## URL shape

After deployment, the archive is served at:

```
https://<user>.github.io/qvac-sdk-swift/
  → documentation/qvacclient/        (module overview)
  → documentation/qvacclient/qvacclient/   (QVACClient actor)
  → tutorials/qvacclient/             (Tutorials TOC)
```

The root index.html in `build/docs/` is a meta-redirect to
`documentation/qvacclient/` so visitors landing on the GitHub
Pages root see the module overview rather than a 404.

## Activating GitHub Pages

The workflow is **wired but inactive** until the repo's Pages
settings are turned on. To activate (post-bounty acceptance, per
YK-229 gate):

1. Repo Settings → Pages → Source: "GitHub Actions".
2. Push to `main` (or run the workflow via `workflow_dispatch`).
3. First successful deploy publishes the site; subsequent pushes
   incrementally update.

Until then, `xcodebuild docbuild` can be run locally to preview
the archive in Xcode:

```bash
xcodebuild docbuild \
  -scheme QVACClient \
  -destination 'generic/platform=macOS' \
  -derivedDataPath build/docbuild

open build/docbuild/Build/Products/Debug/QVACClient.doccarchive
```

Xcode opens the archive in its built-in DocC viewer; no static
host needed for the local preview.

## Archive size

The current archive is **~11 MB** — close to the 10 MB VT-6
target but reasonable. The bulk comes from the 116 codegen'd
error code constants in `Generated/ErrorCodes.swift`. If we want
to shrink it, options are:

- Move codegen'd code under a separate target that DocC ignores
  (would require `@_exported import` plumbing — large refactor).
- Excise the `wireName` switch tables from DocC (they're
  reachable from `///` comments today; could mark them
  `@_documentation(visibility: internal)` once we adopt the new
  Swift attribute).

Neither is urgent — 11MB ships fine on GitHub Pages and loads
instantly over modern broadband. Tracked as M3 follow-up.

## Verifying locally

```bash
# 1. Build (verifies the workflow's build-docc step).
./scripts/download-barekit.sh
./scripts/docc-coverage.sh 95
xcodebuild docbuild -scheme QVACClient \
  -destination 'generic/platform=macOS' \
  -derivedDataPath build/docbuild

# 2. Transform for static hosting (the workflow's next step).
xcrun docc process-archive transform-for-static-hosting \
  build/docbuild/Build/Products/Debug/QVACClient.doccarchive \
  --hosting-base-path qvac-sdk-swift \
  --output-path build/docs

# 3. Serve.
python3 -m http.server -d build/docs 8080
# Visit http://localhost:8080/documentation/qvacclient/
```

The transform step rewrites internal links to use `qvac-sdk-swift`
as the base path. To preview without a base path (so the archive
loads from `http://localhost:8080/` directly), omit
`--hosting-base-path`.
