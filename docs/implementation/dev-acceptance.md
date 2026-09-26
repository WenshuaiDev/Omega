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

实际开发验收结果在完成运行后附录；未附结果不表示通过。
