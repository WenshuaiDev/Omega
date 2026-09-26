# Real browser integrated development evidence — 2026-09-26

Host macOS arm64; Docker Linux arm64; CUA Codex in-app Chromium browser (Chrome connector unavailable but IAB succeeded). Dev agent worktree <dev-worktree>, instance dev-03f989f9a0e6, entry localhost:20837 via actual edge. Source integrated frontend2f66629/API6b80fe5/dev40333bc plus documented local dev corrections.

- Navigate /web/: actual rendered heading Web参考应用, projectOmega/appweb/environmentdev/versiondev and API statusok. Screenshot observed. No default fallback.
- Click visible 深层路由示例 to /web/status/details then explicit browser reload: still rendered app+APIok at same deep route.
- Click visible Console link: /console/ renders Console参考应用, appconsole and APIok. Screenshot observed. Browser error/warn log empty.
- Keep separate web and console browser tabs open. Replace shared mount.tsx descriptive paragraph with unique OMEGA-04 marker in running source. No manual reload. Both DOM snapshots automatically showed marker and APIok.
- Browser Vite debug logs revealed Fast Refresh invalidation because mount.tsx exported a noncomponent `mount`; update fell back to full page reload. This is automatic WebSocket update evidence, but not state-preserving React refresh. Frontend agent assigned correction and will rerun final test. Original source restored from exact backup, git diff empty.

Not final all-scenarios acceptance. Dev agent may restart this isolated instance to fix staged-secret inode preservation on repeat run.

## Corrected React Fast Refresh verification

After merging frontendea03111 (App.tsx component-only export) and restarting both existing Vite containers to clear the prior invalidated module graph:
- Browser both apps loaded normally, APIok.
- Enabled tab-scoped CDP Page events; recorded pre-edit cursors235(web),331(console).
- Changed App.tsx paragraph to `OMEGA-04 React Fast Refresh 实测标记` without browser reload.
- Both actual visible DOMs automatically showed the exact marker.
- CDP reads after those cursors for Page.frameNavigated returned events[] (no truncation, no more events) with new cursors241/337. Thus updates did not navigate/reload either page.
- Source restored from byte-for-byte backup; git diff App.tsx empty.

Previous stale module graph observation is superseded by clean dev server run with corrected source. This is real browser/Vite/edge integration evidence for both apps.

## Runtime public configuration refusal and restoration

Changed only isolated instance web.json appId to console, then reloaded actual /web/ browser. DOM became explicit alert `应用无法启动：公开配置加载或校验失败。请检查部署配置后刷新页面。`. CDP Network.requestWillBeSent events after baseline showed document/dev modules and /web/runtime-config.json only, no /api/v1/ping request; no default fallback. Restored web.json byte-for-byte afterwards. Console deep-link and explicit browser reload separately rendered /console/status/details with APIok. Browser error/warn log empty in healthy state.
