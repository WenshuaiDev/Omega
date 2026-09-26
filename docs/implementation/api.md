# API 与 omega（#14）

`services/api` 是单独 Go Module，根 `go.work` 只引用真实模块。固定 Go 容器 `1.27.1-bookworm`；pgx `v5.11.0`、YAML `v3.0.4` 已通过容器构建和实际 PostgreSQL 验证。API 与 CLI 共用源码、版本变量和同一 production 镜像。生产镜像使用 scratch、CA bundle、UID/GID `10001:10001`，无 shell 或 Docker 操作能力。镜像标签记录版本和提交，`omega version` 与 `omega-api --version` 可核对二进制。

## 调用与配置

`omega [--config PATH] [--json] version|config validate|doctor|health check|db status|db migrate|data ensure`。所有操作只读一份显式完整 YAML。`omega-api --config PATH`；开发监听器 `go run ./services/api/cmd/devwatch --config PATH`，工作目录为仓库根。监听实际仓库 Go 源文件与 workspace/module 锁文件；重新编译前关闭旧服务，编译失败保持 API 停止并输出错误。

配置字段见 integration-contract.md；仅 dev/test/prod。拒绝未知、重复、错误类型、别名、多个 YAML 文档、非法端口/时长和缺失字段。Secret 是单行非空文件，最大 4096 字节；要求普通文件且没有 group-write/group-execute/other 权限，允许 0600/0640/0400/0440，实际进程仍必须具备读取权限。配置错误不回显原文，数据库失败只输出 SQLSTATE，不输出连接串、密码和服务端详细诊断。CLI 数据库连接拒绝继承的 `PG*` 变量，避免 pgx/libpq 环境参数参与目标选择。

help/version/config validate 不连接数据库。doctor 校验数据库依赖、结构与身份；health check 还经无环境代理的本地 HTTP 访问 `/health/ready`，HTTP 未启动或不健康返回 5。`db status` 明确返回 empty/unmigrated/unbound/ready，拒绝不兼容版本、校验和损坏和身份不匹配；empty 状态仅用于显式首次部署判断，不代表可运行。

退出码：0 成功，2 输入，3 策略，4 执行失败，5 超时/不健康，6 维护锁冲突，130 取消。普通和 JSON 输出均有操作 ID、版本、实例、命令、起止时间及结果；结果 stdout，诊断 stderr。

## 数据库与权限契约

基础设施首次创建数据库 `omega` 和非超级用户 `omega_migrator`、`omega_runtime`。撤销 PUBLIC 数据库权限，二者只需 CONNECT；仅 migrator 需数据库 CREATE；public schema 撤销 PUBLIC CREATE。不得使用 postgres 初始化角色运行应用维护。

`db migrate` 只接受实际 current_user=omega_migrator 且非超级用户；获取会话 advisory lock `718293410`，建立归 migrator 所有的 `omega` schema、schema_migrations 和 migration_attempts。runtime 仅有 schema USAGE 和控制表 SELECT。默认未来表权限是 SELECT/INSERT/UPDATE/DELETE、未来 sequence 为 USAGE/SELECT。版本 1 安装身份表特别撤销写权限，只给 runtime SELECT。API 实际检查 current_user=omega_runtime，禁止超级用户、创建角色/数据库/schema 和写 installation 权限。

迁移版本和 SQL SHA-256 固定于代码，支持 schema 范围 1..1。每条迁移在事务内执行，成功版本记录与成功 journal 同事务提交；失败回滚并使用独立有界上下文写不含 Secret 的错误记录。进程被强杀时 running 记录保留为诊断，未提交迁移回滚，下次显式 migrate 可重试。没有 down、跳版本、任意 SQL 或修改已发布迁移的入口。

首次顺序是技术初始化 → db migrate → data ensure → API。ensure 仅在兼容、未绑定的 schema 中插入单例安装 ID/环境；重复调用读已有记录，不改写。已有身份不匹配时所有维护写入均拒绝。安装表存在但没有 schema 记录等部分状态拒绝自动修复。API 从不迁移，也不初始化身份。

API 在配置、数据库、结构、身份、实际运行权限检查后监听。`/health/live` 仅反映进程 HTTP 存活；`/health/ready` 和 `/api/v1/ping` 实际读取数据库必要元数据。依赖暂时失效时 HTTP 存活、就绪 503，恢复后重新 ready。收到 TERM/INT 后停止 ready、停止接流量并按配置有界等待 HTTP 在途请求，超时强制关闭。

## 可重复验证与证据

执行 `services/api/tests/integration.sh`：自动创建唯一 Docker 网络和 tmpfs PostgreSQL，固定 Go 容器以只读源码运行真实进程测试，结束仅清理自己的容器/网络。无需宿主机 Go。测试凭据是该专属临时数据库的固定测试值，无真实实例输入。

2026-09-26 本机 macOS arm64 / Docker Linux arm64 已通过：

- `go test ./services/api/...`：无数据库 help/version/config 检查。
- `services/api/tests/integration.sh`：Go 1.27.1 与 PostgreSQL 17.10 的真实 CLI/API 进程、严格配置、Secret 权限、空库 API 拒绝、显式迁移、ensure 幂等、身份拒绝、互斥冲突、校验和/未知结构拒绝、DDL 注入故障后的事务回滚和持久化失败记录、修复重试、runtime 越权实际拒绝、未来默认表权限、HTTP 存活/就绪分离与恢复、无 HTTP 时 health check 失败、SIGTERM 正常关闭、真实 SQL 等待超时与 SIGINT 取消退出码。
- `go vet ./services/api/...`，正式 Docker 多阶段构建成功。构建中的固定 Go 工具链成功生成同版 omega 和 omega-api。

原生 Linux amd64、完整 make dev/HMR/离线发布/跨镜像兼容回退属于集成验收，不能由上述 API 测试替代。实际共享 Go 模块尚无复用需求，不创建空模块；监听器覆盖后续真实成员路径。
