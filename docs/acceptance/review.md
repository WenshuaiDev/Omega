# 独立审查记录

本记录保留审查发现、修复和复核的先后关系。审查不等于运行验收；修复提交与实际验证记录分别绑定。原生 Linux amd64 仍按用户要求留在 [#20](https://github.com/WenshuaiDev/Omega/issues/20)，没有因本机模拟通过而关闭。

代码复审未解决项为 **0**：Spec 轴最初 6 项（1 项 P1、5 项 P2）已修正；Standards 轴最初没有文档规则违反项，1 项 P3 维护性判断已修正。随后发现的卷查询失败被误当作不存在、质量入口残余无界清理也已修正并加入回归。修复提交为 `8dd1d6e`、`9b21b87` 和仅验收相关的 `bbd6a33`。

以下分别保留两位审查者的独立报告；其中“运行中/待执行”描述的是审查当时状态，不能替代实际运行结果。最终 Q3 已由统一入口通过，记录见 [Q3](2026-09-26/quality3/check.txt)；最终离线结果另见主报告 R。证据文档增量仍须独立复核。

## Spec 轴：最终独立报告

### Spec follow-through — 05462c1…bbd6a33

**No unresolved code findings from this review.** All six original findings are fixed in8dd1d6e/9b21b87, with acceptance-only follow-through inbbd6a33:

- Import explicitly preserves authenticated public modes without restoring ownership or privileged bits; destination and Docker capacity checks precede extraction/load.
- The packaged formal omega wrapper requires explicit environment/input/version/trusted manifest, verifies actual image identity, fixes configuration selection, and preserves application stdout, human/JSON choice and exit codes.
- Dev cancellation uses bounded child/daemon operations and releases owned locks independently of Docker cleanup.
- Release acceptance requires a distinct actual old candidate, so rollback cannot silently disappear from passing coverage.
- Browser/dispatcher cancellation bounds child shutdown and writes failure/incomplete-cleanup records; private fixtures are retained when cleanup cannot complete.

The additional follow-through defect—treating failed volume lookup as absence—is fixed for both dev and release. Successful volume inventory is now required before identity/credential preparation or ownership decisions; exact names select the intended volume.

Formal omega uses migration credentials for database maintenance and runtime credentials for HTTP readiness; it mounts no admin credential, starts no database, checks existing API image identity, and leaves an already stopped API stopped. A previously running API is resumed only after successful maintenance. Requiring complete formal TLS/public inputs matches the documented input contract. No unrequested scope expansion found.

Reviewed seven passing controlled shell regressions, both disk-refusal branches, and the additional passing failed-volume-query regression. These fake-Docker tests verify shell failure boundaries; they are not evidence of a real deployment. Fresh full quality and real non-root import/formal CLI acceptance are still running/pending and are not claimed passed here. Native Linux amd64 acceptance remains explicitly deferred to #20. Final evidence/documentation delta remains to be reviewed after aggregation.

Acceptance delta bbd6a33 introduces no additional finding: quality now shares bounded child/daemon handling and preserves partial cancellation records; its focused outage regression checks exit130 and retained scoped names. Replacing the bootstrap mode755 assertion with actual UID70 read/execute checks plus UID1000 ownership correctly tests the consumer boundary and accepts legitimate775 archive modes. No product/bundle files changed; immutable rc7 remains bound to source4f6f5b3. Fresh full runtime acceptance and quality3 remain pending.

## Standards 轴：最终独立报告

### Standards review — final implementation

Reviewed `05462c1...c92e1da` with detailed hunk review of `441a966...c92e1da`; checked commit history, earlier Standards review, AGENTS, all agent conventions, CONTEXT, accepted ADRs 0001–0003, README and extension contracts. Repository and runtime state were read-only. Tool-enforced formatting/lint is outside this review.

#### Documented standards

No actionable hard-standard violation found.

- `scripts/acceptance/{Dockerfile,browser.sh,browser.mjs}`, `scripts/acceptance.sh` and the matching root dependency/lock keep browser tooling separate from deployed applications. The real browser's narrow fixture mounts and explicit source/platform records respect the existing component and evidence boundaries.
- `scripts/build-release.sh`, `import-release.sh`, `release.sh`, `omega-release.sh` and their documentation retain the ADR-0001 offline material contract, ADR-0002 maintenance/data-preservation boundary, and ADR-0003 same-content application-set release. The added standalone wrapper remains application maintenance with explicit verified inputs; no new business model, backup/restore, CI or arbitrary SQL capability is introduced.
- `scripts/quality/model_check.py` excludes the acceptance daemon from production image discovery without suppressing an application component. Extension authority remains in actual workspace, Dockerfile, Compose and configuration sources.
- Updated evidence documentation distinguishes earlier measured commits from the new wrapper corrections and keeps native Linux amd64 acceptance pending.

#### Smell baseline — judgment only

No remaining actionable finding under the supplied smell baseline.

The prior **Duplicated Code** finding (“the same logic shape appears in more than one hunk or file… extract the shared shape”) is resolved by `scripts/process.sh:4–24`, used by dev, release and acceptance wrappers. Thin `run` aliases preserve existing call sites without duplicating the lifecycle implementation; a further framework is unwarranted. Browser observations are bundled around the page/context they describe; repeated app scenarios share the same routines rather than parallel copies.

This result is a Standards assessment, not completion of the separate Spec review or pending final release/quality execution. Subsequent evidence-only documentation changes require a final delta check for overclaimed outcomes.

#### Follow-up delta

Read `c92e1da...4f6f5b3` (fix `9b21b87`): failed volume inventory now refuses preparation; CLI caller-selected human/JSON output is preserved; disk measurement errors are explicit; corresponding regression and offline assertions were added. No new documented-standard or actionable smell finding. Prior verdict holds. Unified quality at `9b21b87` subsequently passed; the earlier integrity-failed run remains excluded.

Read acceptance-only `4f6f5b3...578cae2` (`bbd6a33`): bounded quality cleanup reuses the lifecycle helper and preserves failure reports; bootstrap acceptance now checks actual UID70 readability/executability after UID1000 import. No new Standards finding. Released/runtime files are unchanged; rc7 retains source `4f6f5b3`. Fresh offline execution remains separately pending.

## 修复、验证与失败批次

### Review-fix provenance (2026-09-26)

Implementation commits: `8dd1d6ed3f50afa67618b242b9149adecbec46af`,
`9b21b871c0dd49e2a11d44bede286d1fde11b7f2`, `bbd6a33`.
The last commit changes only `scripts/quality/run.sh`,
`scripts/tests/wrappers_test.py`, and `scripts/accept-release-target.sh`.
No packaged runtime/bundle file changed after 9b21b87. The immutable rc7 candidate
therefore remains valid for a fresh drill driven by the corrected harness.

| Finding | Concrete correction | Evidence scope |
|---|---|---|
| Ordinary-user extraction strips consumer permission | Authenticated tar uses no-same-owner and same-permissions; rejects special mode bits | rc7 first drill really imported all six images as UID1000; then its overly strict755 assertion failed on legitimate775. Corrected drill probes UID70 read/execute and retains UID1000 owner assertion; actual cold deployment awaits fresh drill. |
| Formal standalone omega missing | Packaged omega-release.sh delegates trusted release preflight/locks; role-appropriate CLI; preserves human/JSON stdout and CLI codes; stopped API remains stopped | Updated real offline harness exercises seven commands, parses JSON, checks human text, wrong input, invalid exit2, and stopped-API writes. Final drill result is separate. |
| Unbounded dev preflight/cleanup retains locks | Bounded daemon/Compose/volume operations; tracked-child shutdown; token-owned locks released before daemon removal | Controlled fake-Docker regressions prove preflight20s deadline, cancellation130, locks gone before deliberately hanging removal completes. |
| Disk check too late | Destination and local Docker-root reserves checked before extraction/load; combined reserve for shared filesystem | Both destination-low and Docker-low fake-df cases refuse before destination creation or docker load; not an actual filesystem exhaustion experiment. |
| Rollback silently unexecuted but suite PASS | release/all and direct drill require all old-candidate fields plus distinct version/archive/manifest | Controlled argument tests refuse absent or same candidate before work. Actual old-binary compatible/incompatible rollback remains real drill evidence. |
| Browser/dispatcher cancellation lifecycle | Bounded child stop and owned cleanup, daemon-query failure is not empty state, retained fixture/partial report | Controlled daemon-outage browser cancellation and dispatcher child cancellation return130 and preserve failure reports. Existing real browser13-case proof is separately bound. |
| Duplicate release wait helpers | Shared process.sh used by release/dev/browser/dispatcher | Exit6 propagation and TERM-ignoring timeout exit5 tested; eight wrapper tests passed inside fixed Go1.27.1 image at9b21b87. |
| Failed volume query treated as absent | Successful inventory required before dev identity/credential preparation and formal ownership checks | Controlled listing failures with missing and existing instance.env return5; no identity/credential regeneration and locks removed. |
| Residual quality daemon waits | Shared process helper, bounded daemon calls/cleanup, partial record before cleanup, retain scoped names on failure | New focused quality cancellation/outage test passes on host4.315s and in fixed Go container3.040s; full quality3 includes it. |

All controlled shell regressions use a generated fake Docker executable, never
the host socket or an interruption of the user's Docker daemon. The container
regression runs with read-only source, caller UID and network none.

Full quality2 at `/tmp/omega13-review-final-quality2`: source9b21b87, unified
quality PASS/0, UTC02:46:29–02:49:08, clean source guard passed; eight wrapper
cases, Go/frontend/static checks, real isolated PostgreSQL tests, all three Compose
models, formal image builds and image-user checks passed.

Earlier `/tmp/omega13-review-final-quality` is FAILED: follow-up edits raced its
final source-integrity guard. It is superseded, not a pass. Quality3 at
`/tmp/omega13-review-final-quality3` runs on clean bbd6a33 and its final result
must be read before claiming completion. Native Linux amd64 #20 remains deferred.

Final update: quality3 completed PASS/0 on
`bbd6a3309a32991eb46d55a873635da14a05073c`, UTC02:53:29–02:56:06.
`quality/result.txt` records `stage=complete`, `exit=0`,
`cleanup_complete=true`. All nine wrapper tests passed in45.366s inside the
fixed Go image, and the final original-source/dependency guard passed. The
worktree remained clean. This supersedes pending wording above.
