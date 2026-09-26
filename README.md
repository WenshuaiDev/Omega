# Omega 工程基座

Go Workspace、React/Vite、Yarn Workspaces、PostgreSQL 与 Nginx 的单仓库工程基座。参考应用为 `/web/`、`/console/`，公共 API 为 `/api/v1/ping`。规格以 [Issue #13](https://github.com/WenshuaiDev/Omega/issues/13) 为准；参考应用不提供业务模型或账号系统。

## 开发启动

宿主机准备 Docker（含 Compose 插件）、Bash、curl、Git、Make 和常见 Unix 文件工具；Go、Node、Yarn、数据库由固定容器提供。开发及构建允许联网。macOS arm64 与 Linux amd64 是目标开发平台；当前原生 Linux amd64 验收尚未执行，见 [平台待办 #20](https://github.com/WenshuaiDev/Omega/issues/20)。

```bash
make dev
make status
make logs
make down
```

首次 `make dev` 生成 `.omega/dev` 中的稳定实例身份和凭据，构建开发镜像、安装锁定依赖、初始化数据库角色、显式迁移及初始化必要系统元数据，然后启动五个服务并验证入口。成功后打印实际 URL 并返回终端。开发端口绑定回环地址，按输入目录生成；不要假定固定端口。

不同 checkout 或临时验收可显式使用完整输入目录：

```bash
make dev ARGS="--input '/tmp/omega my-instance'"
make status ARGS="--input '/tmp/omega my-instance'"
make down ARGS="--input '/tmp/omega my-instance'"
```

再次启动会保留配置、密码和数据；变更依赖或迁移后再次运行 `make dev`。前端和 Go 源码通过监听更新，编译错误需要修复后确认新响应。普通 `down` 保留卷。`make dev-reset` 显示并核实选定 dev 实例，要求确认准确实例 ID 后删除该实例数据；test/prod 禁止使用此入口。

输入和数据库卷必须匹配。原卷存在而凭据丢失时恢复原输入，不能重新生成密码。锁冲突时检查报出的锁所属进程；不要删除其他操作的锁。失败命令保留数据及诊断，修复错误后重试同一命令。完整阶段和资源契约见 [开发说明](docs/implementation/dev.md)。

## 手动质量检查

```bash
make check
make test
make check ARGS="--output '/tmp/omega check evidence' --timeout 1800"
./scripts/test.sh --help
```

`make check` 执行所有实际 Go workspace 模块的格式、vet、依赖校验、真实测试和构建；所有 Yarn 成员的 immutable 安装、格式、类型、lint、测试和适用构建；三种环境的完整 Compose 模型及策略检查；所有服务、app、基础设施 Dockerfile 的 Linux amd64 正式镜像构建与架构检查。缺失 workspace 成员、必要检查命令、锁文件不一致和任一失败都会使入口非零退出。共享前端源码包可以没有独立产物构建，必须有类型、lint 和测试。

`make test` 是较短的测试入口：全部 Go/Yarn 成员测试、真实隔离 PostgreSQL 的 CLI/API 进程测试，以及检查器的拒绝策略回归测试。两者都从当前非忽略源码创建临时副本，测试容器和数据库专属，结束只清理自身资源，不使用开发实例的凭据或数据，不修改源码依赖文件，不依赖宿主机 Go/Node/Yarn/Python/jq。Docker 构建缓存可保留；下载依赖需要联网。

默认报告位于 `artifacts/omega-quality-<时间>-<进程>/`，包括工具和主机版本、提交及工作区变化、逐阶段日志、退出状态，完整检查还记录 Compose JSON 和正式镜像内容 ID。`--timeout` 是每阶段上限（默认 1800 秒）。正式构建平台固定 `linux/amd64`；macOS arm64 上的构建或运行是交叉构建/模拟证据，不代表原生 Linux 验收。

这些检查不能替代完整浏览器 HMR、离线目标部署和失败演练。OMEGA-01–38 总体验收由 [#18](https://github.com/WenshuaiDev/Omega/issues/18) 跟踪，原生平台证据由 [#20](https://github.com/WenshuaiDev/Omega/issues/20) 跟踪。不提供 CI、备份恢复或真实生产服务器交付。

## 配置与应用维护

环境只有 `dev/test/prod`。实例输入与发布目录分离，包括 `instance.env`、完整 `api.yaml` / `migration.yaml`、每个 app 的完整公开 JSON、独立 Secret 文件，以及正式环境提供的 TLS 证书/私钥。覆盖文件是完整替代，配置不会作为 shell 执行；test/prod 不接受个人覆盖。运行时公开配置只含公开信息，不承担授权。

应用运维工具 `omega` 与 `omega-api` 同模块、同提交、同正式镜像。支持 `version`、`config validate`、`doctor`、`health check`、`db status`、`db migrate`、`data ensure`，也支持 `--json`。API 不自动迁移；维护命令没有 Docker、构建、整套部署或任意 SQL 能力。CLI 退出码、角色权限、schema/实例拒绝规则见 [API 说明](docs/implementation/api.md)。前端配置/缓存/HMR 契约见 [前端说明](docs/implementation/apps.md)。

## 离线发布

发布必须经过统一质量检查，构建一组 Linux amd64 候选镜像，在 test 验证后按相同镜像内容提升到 prod。发布和导入的入口约定为：

```bash
./scripts/build-release.sh VERSION /absolute/new-output-directory
./scripts/import-release.sh ARCHIVE TRUSTED_ARCHIVE_SHA256 /absolute/new-release-directory
```

解包后的入口位于 `materials/scripts/release.sh`，接受 `deploy|rollback|status|logs|down|tls-reload` 及显式 `--env test|prod --input ABS_DIR --version VERSION --manifest-sha256 TRUSTED_MANIFEST_HASH`。目标机只需预装运行前置，不需要源码或开发工具；正式操作拒绝缺少镜像、错误架构或镜像内容身份不符，不隐式拉取或构建。TLS 材料由部署方提供。校验值需通过可信渠道核对，同包校验不等于发布者签名。

正式升级允许维护窗口。迁移或健康验证失败时保留维护状态、实际已完成步骤与数据；不能把多容器操作当作事务。回退必须先由旧版本核实配置、身份及真实 schema 兼容性，不执行数据库降级。具体发布材料和已执行证据以 `docs/implementation/release.md` 为准；该流程的代码实现和本机演练均不代表生产交付。

新增服务、前端应用或组件前，请按 [扩展接入规则](docs/engineering/extensions.md) 接入所有权威工作区和检查，不建立重复工程清单。
