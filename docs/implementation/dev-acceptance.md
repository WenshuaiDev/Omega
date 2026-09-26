# 隔离开发行为验收（#22）

手动入口：`./scripts/acceptance-dev.sh --output /absolute/evidence-directory`。

该入口从当前已提交代码创建两个包含空格的独立源码目录，以真实 `make dev`、`scripts/dev.sh` 和 `scripts/omega.sh` 操作专属实例。使用真实 Docker Compose、PostgreSQL、Nginx、Go watcher 和 Yarn immutable 安装，不替换 Docker 命令或伪造成功。每个实例自动生成项目 ID/端口/凭据；输入和临时源码置于私有临时目录，证据目录只保存日志、配置/凭据哈希、SQL 系统元数据结果与资源标识，不复制凭据原文。

宿主机只需开发契约规定的 Bash、Docker/Compose、Git、Make、curl、基本归档/文本/哈希工具。启动前给 Go、Node、Yarn、Corepack、npm、Python、jq 设置显式拒绝 shim；任何宿主调用都会记录并失败。容器中的固定工具不受影响。源码通过 `git archive HEAD` 获取，保持 Git 文件权限；因此修改验收/实现代码后需先提交再运行。

`results.tsv` 逐项记录范围、PASS/FAIL/NOT_EXECUTED、开始/结束时间和证据目录。每次命令保存 `.argv`、`.stdout`、`.stderr`、`.exit`。`platform.txt` 记录源提交和实际平台；`baseline-*` 与 `final-*` 记录资源证据。预期失败必须同时匹配退出码、具体阶段诊断和持久化/恢复结果。

范围包括：项目冷启动及无宿主开发运行时；五服务与入口 HTTP；重复启动保留；凭据丢失拒绝；真实依赖锁不一致失败和恢复；源码重编译、错误关闭旧 API、恢复；环境污染拒绝改变目标；未知配置拒绝；保持 edge 时替换 API 并恢复代理；down 保留；空库事务迁移 SQL 错误、失败记录和修复重试；双实例隔离；实际 PostgreSQL 表锁阻塞维护时的并发和取消；确认/环境/实例边界下的 reset。

成功后通过真实确认 reset 删除两个专属实例的数据/缓存卷，保留外部证据。失败时保留专属资源和私有临时目录供诊断，最终输出精确位置；不会执行全主机清理。重跑创建新的实例，不能把旧运行的部分结果当成新运行结果。

## 验证边界

共享 Docker Desktop 守护进程保留已有基础镜像缓存；“冷启动”证明新项目没有配置、容器或数据，不声称空守护进程首次下载。macOS arm64 与本机 Docker Linux arm64 是开发证据，不能代替原生 Linux amd64 验收。

浏览器 HMR、全部 Go/Yarn 工作区质量检查、完整制品 Secret 审计和离线发布分别由相关验收入口记录，本脚本明确保留 NOT_EXECUTED 行，不用局部通过覆盖完整 OMEGA 编号。真实 PostgreSQL API 进程套件另见 `services/api/tests/integration.sh`。

## API 进程测试连接修正

权限测试现在复制已解析的管理员连接配置，再显式设置 `omega_runtime` 和专属测试密码；不再替换 `postgres:admin-secret` 字面串。2026-09-26 使用管理员密码 `changed-admin-password` 的独立 PostgreSQL 容器及固定 Go 1.27.1 容器执行 `go test -count=1 -v ./services/api/integration`，真实进程和越权测试通过，证明不依赖原密码文本。

实际开发验收结果如下，平台和提交边界分别记录。

## 已执行结果（2026-09-26）

完整开发行为运行：`./scripts/acceptance-dev.sh --output /tmp/omega13-dev-evidence-final`，源提交 `9149dce`，UTC 02:08:19–02:12:54，macOS arm64 / Docker Linux arm64、Docker 29.8.0、Compose 5.5.1。逐项结果和原始命令证据保存在该目录 `results.tsv` 及各编号子目录。前述开发行为全部通过；跨领域项保留 NOT_EXECUTED。

- OMEGA-19 实际 API app-network 地址从 `172.21.0.5` 变成 `172.21.0.6`，容器从 `40ab06c4086c` 变为 `2f653ecd7447`，edge 始终为 `975b41e94ae1`。专属临时容器占据旧地址，外部 ping 恢复后移除；证据 `OMEGA-19-proxy-rediscovery/addresses.txt`。
- OMEGA-37 已按实际维护容器 IP `172.19.0.4` 在 PostgreSQL 中确认该 CLI 正等待真实表锁，再执行并发拒绝 6、TERM 取消 130 和重试；不是仅观察锁文件。维护容器 `604df97a29ed`，证据 `blocked-client.txt` 和操作日志。
- 双实例真实密码交叉认证被拒绝，正确实例凭据成功。reset 同时验证错误确认、prod 输入，以及“输入仍为 dev 但实际数据库身份为 prod”的拒绝；恢复该测试身份后仅重置 A，B 的容器/安装身份/健康不变。
- 六份临时凭据对全部 stdout/stderr 的不回显扫描均无匹配。错误依赖与错误 SQL 都实际导致指定阶段失败，恢复原文件后同一入口成功，数据库数据/身份保留。

### 发现并修复的源码挂载凭据问题

检查 OMEGA-24 时发现，旧 dev 源码挂载包含默认 `.omega/dev`，运行用户能够读取原始 admin/migrator 文件。只读测试 `test -r` 确认问题，全程没有读取或输出凭据值；角色专用 `/run/secrets` 挂载本身不能遮住源码下的原文件。

开发实现已通过 `1ba1d92`（本分支对应 `8cc0d06`）修正：所有源码消费者遮蔽 `/workspace/.omega`，选择器拒绝源码中其他位置的输入，edge 拒绝把 `.omega` 路径转发给 Vite。

受影响回归：`./scripts/acceptance-dev.sh --secret-boundary-only --output /tmp/omega13-dev-secret-boundary`，源提交 `a86171c`，UTC 02:15:21–02:16:13，真实默认 `.omega/dev` 冷启动及以下检查通过：

- API、web、console、migrate、deps 均不能读取来源目录 admin/migrator/staged-admin；API 所需 runtime Secret 仍可读。
- 两个 app 经 edge 访问三个实际私有 `@fs` 路径，六次均为 404；响应正文在私有临时目录校验不含任何凭据，不进入证据日志，随后删除。
- 五服务健康和普通入口仍通过；测试最后只重置自己的实例。

额外入口策略真实进程检查 `tests/acceptance-dev/input-policy.sh` 通过，证据 `/tmp/omega13-dev-input-policy-evidence.txt`：源码中非 `.omega` 输入返回 3；`.omega` 内带空格路径和外部带空格路径通过位置策略，并准确进入“缺失 instance.env”的 2 拒绝，无凭据和锁残留。这部分只证明选择器策略，不额外声称完整启动。

### PostgreSQL 默认权限与部分元数据回归

增强后的 API 真实进程套件再次通过（固定 Go 1.27.1、PostgreSQL 17.10，管理员密码不同于原固定文本）：migrator 创建的未来 `bigserial` 表，runtime 默认插入实际使用新 sequence 并返回 ID 1，SELECT/UPDATE/DELETE 成功；ALTER/DROP 表、sequence、schema 及 CREATE ROLE 均实际被拒绝。缺失控制表、存在安装身份但缺失 schema 记录的两类部分状态均拒绝 migrate/ensure，安装身份未变。这些表只存在于一次性测试数据库中，不引入业务模型。

完整运行证据与凭据边界修复后的定向回归按其各自提交记录，不能混写为同一未经区分的完整快照。原生 Linux amd64 仍未执行；真正生产交付不在此报告范围内。
