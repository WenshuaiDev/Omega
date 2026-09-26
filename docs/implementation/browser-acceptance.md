# Unified acceptance entry and browser suite (#23)

`./scripts/acceptance.sh quality|dev|browser|release|all --output NEW_DIRECTORY`
is a fixed dispatcher over `check.sh`, `acceptance-dev.sh`, the browser suite,
and `accept-release.sh`. It requires committed clean source, propagates real suite
failures, records unrun suites as NOT_EXECUTED, and leaves complete OMEGA01–38
aggregation to #18. `local_run_exit=0` never implies `spec_complete=true` or native
Linux amd64 completion. Native evidence remains the explicit #20 todo.

Release/all require `--archive`, `--archive-sha256`, `--version`,
`--manifest-sha256` and `--harness-image`. Optional rollback candidate arguments
are `--old-archive`, `--old-archive-sha256`, `--old-version`,
`--old-manifest-sha256`, supplied together. The existing offline harness must be
built online first; the dispatcher never rebuilds or substitutes the candidate.
Use `./scripts/acceptance.sh --help` for exact syntax. `quality` already includes
all workspace tests, so the dispatcher does not redundantly invoke test.sh.

Browser-only example:

```bash
./scripts/acceptance.sh browser --output /tmp/omega-browser-evidence
```

The browser suite archives the committed tree into an owned source directory,
starts a real private dev instance and builds an acceptance-only browser image.
It tests actual React rendering/API status, both apps' HMR WebSockets and DOM
updates without document navigation/reload, deep links and explicit reloads,
wrong-app/malformed runtime JSON with explicit failure and no attempted API
fallback, and successful restoration. It restores source/config bytes in both
browser finally and shell cleanup, preserves traces/screenshots/requests/results,
and removes only its generated instance resources. Every wait is bounded.

The browser container shares the owned edge network namespace and visits
`http://127.0.0.1:8080`, so page and WebSocket requests go through actual Nginx.
A separate host curl verifies the published allocated loopback ingress. This
avoids Docker Desktop-only hostnames and supports the same network path on Linux.
The browser receives no Docker socket, private backend credentials or arbitrary
source-tree mount: only the fixture App.tsx and two public JSON files are writable.
It uses a fresh browser context per config-failure/recovery scenario and never
intercepts/mock-answers network requests. Document sentinels and real navigation
events distinguish React Fast Refresh from a full-page reload.

The sole new root devDependency is `playwright-core`1.63.0, pinned in the existing
Yarn lock. Official npm metadata records release2026-09-04, Node>=20 and no
runtime dependencies. The browser image is pinned to
`mcr.microsoft.com/playwright:v1.63.0-noble@sha256:eff16c30e6f3f4af0a03fa4b706120d5e9b0891c344a27d64559aff5900a4a27`,
whose inspected manifest contains Linux amd64 and arm64. Its matching browser
binaries/system libraries are installed at image build/pull time; the library is
copied from an immutable install using the fixed Node24.21.0/Yarn4.18.1 build stage.
Runtime uses `--pull never`; no npx or browser downloads occur during scenarios.
This image and the DinD harness are test tooling, excluded from production image
discovery/package contents. No new application workspace, CI, production import
or host runtime requirement is introduced.

The browser process runs as the host UID with dropped capabilities, private1GiB
shared memory and no-new-privileges. Playwright's default trusted-test Chromium
mode is contained inside this disposable test container; no changes are made to
application Compose security or host IPC/network configuration.

Primary packaging references: [Playwright Docker documentation](https://playwright.dev/docs/docker),
[official npm package metadata](https://registry.npmjs.org/playwright-core/1.63.0).
Actual local results are appended after execution; the pinned candidates above
alone are not compatibility or acceptance proof.
