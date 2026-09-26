# 工程基座 V1 验收记录（#18）

对应[规格 #13](https://github.com/WenshuaiDev/Omega/issues/13)。本报告将代码实现、macOS 本机验证、Linux amd64 模拟部署与原生平台验收分开记录。**原生 Linux amd64 尚未执行，按用户明确要求保留 [#20](https://github.com/WenshuaiDev/Omega/issues/20)；不声称整份规格、原生支持或真实生产交付已经验收完成。** OMEGA-28 备份恢复明确排除，没有引入 CI。

证据是实际运行的精简记录，保存在仓库中，PR 审阅者无需访问执行机器的 `/tmp`。原始大日志、临时数据库、凭据、私钥、HTTP 私密响应及其他项目的主机资源清单不进入仓库。各记录保留命令、实际结果、源码/平台和必要资源标识；[采集来源及 SHA-256](2026-09-26/provenance.json) 用于追溯和一致性核对，不表示发布者签名。

## 执行批次与边界

| 批次 | 实际来源和平台 | 结果及仓库内记录 |
| --- | --- | --- |
| Q：统一质量检查 | `cce6725439b9140b0beb319bf07f12f4153f4f5f` 加记录中两份未提交检查脚本改动；macOS arm64 / Docker Linux arm64，正式镜像交叉构建为 Linux amd64 | [质量输出](2026-09-26/quality.txt)、[实际镜像身份](2026-09-26/quality-production-images.txt)和[同序实际用户](2026-09-26/quality-image-users.tsv)、[正常与故意失败入口](2026-09-26/quality-command-results.json)。全检查退出 0；错误 Go、锁不一致退出 1，真实超时退出 5。不能将这批未提交工作区称为最终提交的完整快照。 |
| Q2：浏览器依赖变更后的全量质量检查 | 已提交源码 `d8105e9ca7631f59ad599c746be04663ae941b40`，UTC 02:25:44–02:27:42；macOS arm64 / Docker Linux arm64，正式镜像交叉构建为 Linux amd64 | [完整质量记录](2026-09-26/quality-final.txt)、[镜像身份](2026-09-26/quality-final-production-images.txt)、[实际用户](2026-09-26/quality-final-image-users.tsv)。更新后的根锁不可变安装、全部 Go/Yarn 成员、真实 PostgreSQL 进程测试、三个最终 Compose 模型和五个正式镜像均通过，退出 0。 |
| Q3：最终统一质量入口 | 已提交源码 `bbd6a3309a32991eb46d55a873635da14a05073c`，UTC 02:53:29–02:56:06；macOS arm64 / Docker Linux arm64，正式镜像为 Linux amd64 交叉构建 | `./scripts/acceptance.sh quality --output <新目录>`，[调度结果](2026-09-26/quality3/results.tsv)、[完整检查与九项包装器回归](2026-09-26/quality3/check.txt)、[镜像身份](2026-09-26/quality3/production-images.txt)。退出 0、源文件/依赖一致性通过、`cleanup_complete=true`。 |
| D：完整隔离开发行为 | `9149dce9b8cf7985d60ba6abdb3697a2b4f091a7`，2026-09-26 UTC 02:08:19–02:12:54；macOS arm64 / Docker Linux arm64 | [逐项结果](2026-09-26/dev-results.tsv)、[平台](2026-09-26/dev-platform.txt)、[实际 IP 变化与阻塞会话](2026-09-26/dev-network-and-lock.txt)、[故意失败命令及诊断](2026-09-26/dev-failure-proof.json)。项目镜像/实例/数据冷启动，保留共享第三方镜像缓存；未声称清空整个 Docker 守护进程。 |
| S：源码挂载凭据修正回归 | `a86171c427cab9b3474d0651d8c123b7651c6505`，UTC 02:15:21–02:16:13；同一本机平台 | [结果](2026-09-26/secret-boundary-results.tsv)、[平台](2026-09-26/secret-boundary-platform.txt)、[实际文件可读性及 HTTP 断言](2026-09-26/secret-boundary-assertions.json)、[输入位置拒绝](2026-09-26/input-policy.txt)。实际发现旧源码挂载会暴露 `.omega/dev` 原始凭据后修复，再执行默认目录冷启动；不是只审查挂载 YAML。 |
| A：真实 API/CLI 进程 | 增强测试执行时未提交，之后字节一致提交至 `a86171c`；测试文件 SHA-256 固定，生产 API 源码未变；Go 1.27.1 / PostgreSQL 17.10，本机 Linux arm64 容器 | [实际执行转录、退出码及源码绑定](2026-09-26/api-process.txt)。包括未来 bigserial/sequence、完整 DML 与 DDL 拒绝、部分元数据拒绝；转录明确不是再次运行。此前完整 API 基线同时在 Q 中运行。 |
| B1：交互浏览器 | CUA Codex 内置 Chromium；集成开发实例 `dev-03f989f9a0e6`，更正前端 `ea03111` 后重启 Vite | [人工实际浏览器观察](2026-09-26/browser-manual.md)。两个 app 自动更新且无页面导航、两个深层路由刷新、错误公开配置出现警报且没有 API 请求。早先整页刷新被明确记录并由修正后结果替代。 |
| B2：早期可重复浏览器入口 | `d8105e9ca7631f59ad599c746be04663ae941b40` | [历史 13 项结果](2026-09-26/browser-baseline-results.json)保留来源，正向最终依据为后续 B3；独立故意失败夹具记录单独保留。 |
| B3：最终统一浏览器入口 | 已提交源码 `bbd6a3309a32991eb46d55a873635da14a05073c`，UTC 02:58:16 开始、场景 02:59:06 完成；Playwright 1.63.0 / Chromium 153.0.8010.12，Linux arm64 浏览器容器 | `./scripts/acceptance.sh browser --output <新目录>`，[调度结果](2026-09-26/browser/dispatcher-results.tsv)、[13 项实际结果](2026-09-26/browser/results.json)、[浏览器版本](2026-09-26/browser/browser-version.json)。退出 0，三份夹具精确恢复，`cleanup_complete=true`；[独立清理核对](2026-09-26/browser/cleanup-verification.json)实际查询本次容器/卷/网络均为空。 |
| R：最终统一离线验收 | 候选 `0.1.0-issue13-rc7` / 源码 `4f6f5b3`，调用方 `578cae2`；macOS arm64 上 Linux amd64 隔离模拟 | [最终发布记录与精简证据](2026-09-26/release/README.md)。统一入口 release PASS / 0，含实际 rc4 回退、普通用户导入/冷部署、正式 omega、同镜像提升、双层阻断外网、完整性/就绪/迁移/TLS 故障、并发/取消与修复重试；12 个私密标记 / 494 项检查零命中。 |

D、S、A 是有明确差异边界的分次证据，不能混写为一次运行。早先审查修复期间的一次质量运行因后续编辑触发源码一致性保护而失败；随后冻结源码的 quality2 和最终 Q3 均通过，[失败批次](2026-09-26/superseded-failures.json)未被改写为通过。rc7 首次统一演练在真实普通用户导入成功后，被验收脚本对精确 0755 模式的过严断言截停；修正只验证实际 PostgreSQL UID 的读/执行权限，不改变候选包，完整重跑另行记录。九项包装器回归使用无宿主 Docker socket 的受控故障替身，验证超时、取消、锁、磁盘拒绝和清理边界，不冒充真实 daemon 故障或磁盘耗尽演练。实际共享 Go 模块目前不存在，不为验收凭空增加模块；真实共享前端包已纳入工作区检查和两个 app 更新验证。

## OMEGA-01–38 对照

“通过”仅指对应本机/模拟证据范围。当前 36 项在该范围内通过，OMEGA-28 范围排除，OMEGA-38 原生平台部分未执行；没有把模拟结果计为原生支持或真实生产交付。

| 编号 | 状态 | 已验证行为与证据 / 尚缺内容 |
| --- | --- | --- |
| OMEGA-01 | 通过（本机） | D、S：新项目无输入、容器、卷和项目镜像时真实冷启动；保留第三方基础镜像缓存。 |
| OMEGA-02 | 通过（本机） | D、S、Q：拒绝宿主 Go/Node/Yarn 等运行时的 PATH shim，无被调用记录。 |
| OMEGA-03 | 通过（本机） | D、S：api、web、console、edge、PostgreSQL 健康，入口 HTTP 和数据库支持的 ping 可用。 |
| OMEGA-04 | 通过（本机） | B1、B3：两 app 真实浏览器 HMR，WebSocket 更新、文档哨兵保留且导航数为零；没有以整页刷新冒充状态保留。 |
| OMEGA-05 | 通过（本机） | D：真实 Go 源码改动可见、编译错误停掉旧服务并显示诊断、修复恢复；没有实际共享 Go 模块。 |
| OMEGA-06 | 通过（本机） | D：重复启动保持普通输入、三份凭据哈希、安装身份及时间，释放自己的锁。 |
| OMEGA-07 | 通过（本机） | D：已有数据库卷丢失凭据时退出拒绝，不重生成；恢复原文件后同入口成功。 |
| OMEGA-08 | 通过（本机） | D：真实 immutable 依赖失败和 PostgreSQL SQL 迁移失败分别使启动在正确阶段非零退出。 |
| OMEGA-09 | 通过（本机） | D：修复同一输入/源码后原命令重试成功，未替换数据卷或安装身份。 |
| OMEGA-10 | 通过（本机） | D：两真实实例的项目、端口、卷、凭据不同；A 密码不能登录 B，正确密码可用。 |
| OMEGA-11 | 通过（本机） | D：正常 down 保留卷，重启后凭据与身份一致。 |
| OMEGA-12 | 通过（本机） | D：错误确认、prod 输入、实际 DB 为 prod 均拒绝；正确重置 A 后 B 容器/数据/健康不变。 |
| OMEGA-13 | 通过（本机） | Q3：从 go.work 发现实际模块，格式/vet/模块校验/测试/构建覆盖全部成员。 |
| OMEGA-14 | 通过（本机） | D、Q3：唯一 Yarn 锁和 immutable 安装；故意 manifest 不一致失败且锁哈希不变。 |
| OMEGA-15 | 通过（本机） | D：继承 COMPOSE/受控 OMEGA 污染值不改变明确选择的目标。 |
| OMEGA-16 | 通过（本机及模拟） | A/Q3/D/B3：配置拒绝、无默认回退；D：六份临时凭据不进入 stdout/stderr；S：源码凭据遮蔽及六次 HTTP404。R：12 个受控凭据/私钥标记经494项发布文件、日志、配置/历史和原始/解压镜像层检查零命中。 |
| OMEGA-17 | 通过（模拟） | R：同一候选 web/console 内容 ID 使用独立 test/prod 公开 JSON，环境/版本/路径与真实 TLS 响应核对通过。 |
| OMEGA-18 | 通过（本机及模拟） | B3：两 app 深层路由真实刷新；R：候选静态响应、深层页、缺失资源404、HTML与哈希资源缓存检查通过。 |
| OMEGA-19 | 通过（本机） | D：API 地址 172.21.0.5→172.21.0.6，edge ID 975b41e94ae1 不变，外部 ping 恢复。 |
| OMEGA-20 | 通过（源码及本机） | A/Q：CLI 仅应用命令，帮助/未知命令验证；正式模型策略拒绝 Docker socket/管理权限；[职责契约](../implementation/api.md)。 |
| OMEGA-21 | 通过（本机交叉构建） | Q3：同一实际 API 镜像中的两个二进制版本、提交与 OCI 标签一致；生产架构 Linux amd64。 |
| OMEGA-22 | 通过（本机） | A/Q/D：真实互斥、校验和、未知结构拒绝、失败事务回滚与记录、超时/取消；空库 API 不迁移。 |
| OMEGA-23 | 通过（本机） | A/D：ensure 幂等，实例/环境拒绝，缺失控制表及身份存在却缺失版本记录拒绝，未改写身份。 |
| OMEGA-24 | 通过（本机） | A：未来 bigserial 默认序列、SELECT/INSERT/UPDATE/DELETE 和实际 DDL/角色越权拒绝；S：全部源码消费者不能读取额外角色凭据。 |
| OMEGA-25 | 通过（本机及模拟） | Q3：最终 test/prod 全 profile 模型与实际镜像用户检查，不安全变体被拒绝；R：同一候选部署前真实最终模型核验及实际启动。 |
| OMEGA-26 | 通过（模拟） | R：[候选清单](2026-09-26/release/manifest.tsv)绑定六镜像 ID/架构；导入/运行核验，缺镜像和同标签错误内容均在维护前拒绝。 |
| OMEGA-27 | 通过（模拟） | R：真实旧 rc4 二进制完成兼容回退，数据库结构版本/校验和/安装身份前后相同；未知新结构由实际旧二进制在切换前拒绝。 |
| OMEGA-28 | 范围排除 | 规格明确排除备份恢复；无相关实现或演练要求。 |
| OMEGA-29 | 通过（本机及模拟） | D 为实际手动隔离冷启动；Q3、B3、R 均经统一调度入口执行，R 再验证空目标普通用户冷部署。无 CI；分批记录，不冒称一次 all 运行。 |
| OMEGA-30 | 通过（源码及本机） | [Makefile](../../Makefile) 仅薄入口，应用规则在 API/omega；生命周期命令由固定脚本与 Compose 执行。 |
| OMEGA-31 | 通过（模拟） | R：初始空镜像目标、外层 network none、无宿主 socket；daemon 与应用网络命名空间均有直接IP/DNS传输拒绝证据，内部 API/TLS 成功。原生部分仍见38。 |
| OMEGA-32 | 通过（模拟） | R：独立可信归档/清单预期值，真实损坏归档、文件与清单均拒绝；实际断言拒绝前未进入维护。 |
| OMEGA-33 | 通过（模拟） | R：缺镜像及同标签错误内容明确失败，未隐式拉取/现场构建，已有实例保持运行。 |
| OMEGA-34 | 通过（模拟） | R：首次部署真实迁移SQL失败退出4，维护标记保留；失败记录持久化、installation不存在、已应用版本0，失败快照只有DB，未启动不兼容应用；修复重试通过。此场景不宣称外部503。 |
| OMEGA-35 | 通过（模拟） | R：已有实例撤销运行角色SELECT导致启动/就绪失败退出1，实际状态与失败阶段记录完整；维护/数据保留且外部503，恢复权限后显式重试成功。 |
| OMEGA-36 | 通过（模拟） | R：同一原始归档/清单提升test→prod；五个长期服务实际ID逐一相同，tools一次性镜像由同一清单核验；独立输入，不重建。 |
| OMEGA-37 | 通过（本机及模拟） | D/R：真实SQL阻塞后并发退出6、TERM退出130、锁/任务清理、独立实例并行与重试；Q3：无响应daemon的有界取消/失败报告等九项受控回归；B3/R独立确认自有资源清理。 |
| OMEGA-38 | 未执行（用户保留待办） | 本机 Darwin arm64 / Docker Linux arm64；正式镜像和隔离目标的 Linux amd64 为本地模拟。原生 Linux amd64 验收单独保留 #20。 |

## 浏览器画面与网络证据

[Web 实际 HMR 画面](2026-09-26/browser/web-hmr.png)、[Console 实际 HMR 画面](2026-09-26/browser/console-hmr.png)、[配置拒绝画面](2026-09-26/browser/web-config-wrong-app.png)为最终 B3 自动浏览器当场截图。对应 [Web 网络/WebSocket/导航记录](2026-09-26/browser/web-hmr.json)和[Console 记录](2026-09-26/browser/console-hmr.json)均保留实际更新帧，导航数为 0。[错误 appId 请求记录](2026-09-26/browser/web-config-wrong-app.json)不含 API 请求。没有提交体积较大的完整 trace；保留的截图与 JSON 已足够审查这些断言，完整场景可由入口重新运行。[故意失败记录](2026-09-26/browser/expected-failure.json)来自独立已提交破坏夹具：两个页面先真实健康，随后 HMR 唯一锚点断言失败，浏览器与调度器均退出 1，三份夹具仍精确恢复。

## 审查与修复

[两条独立审查轴的记录](review.md)区分规格缺口、文档规则和维护性判断；最终代码复审两轴均无未解决项；最终发布验收 R 已通过；证据文档增量已在 `2b40a9e` 由两轴独立复核完成，均为零未解决项。

## 后续运行

使用仓库内的手动质量、开发、浏览器和离线验收入口；各入口只能报告自己实际执行的范围。运行失败必须保留原因与实际结果，不能把预期成功写成通过。原生主机到位后，在隔离资源上重新运行适用场景并记录宿主/daemon 架构，不复用本机模拟记录冒充原生结果。
