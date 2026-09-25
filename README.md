# Omega

阶段 1 工程起点：[Issue #11](https://github.com/WenshuaiDev/Omega/issues/11)。
Go 示例通过共享 buildinfo 打印版本后退出，React 示例显示项目名。

## 前置工具（prerequisites）

支持 macOS、Linux；Windows 请在 WSL2 的 Linux 文件系统内工作。
自行安装 Git、Make、POSIX shell，以及以下精确版本，并将它们加入 PATH：

| 工具     | 版本    | 安装依据                                                                 |
| -------- | ------- | ------------------------------------------------------------------------ |
| Go       | 1.27.1  | [官方安装](https://go.dev/doc/install)，仓库 `.go-version`               |
| Node     | 26.10.0 | [官方发行](https://nodejs.org/dist/v26.10.0/)，仓库 `.node-version`      |
| Corepack | 0.36.0  | [官方项目](https://github.com/nodejs/corepack)，仓库 `.corepack-version` |

先选择 Node 26.10.0，再由开发者执行 `npm install --global corepack@0.36.0`。
也可自行将其安装到用户管理的前缀并加入 PATH。无需运行 `corepack enable`，
项目始终使用 `corepack yarn`，按 `package.json` 准备 Yarn 4.18.1。

`make bootstrap` 校验上述版本，准备项目固定的 Yarn，并安装依赖。
不会安装或切换全局 Go、Node、Corepack，不自动追随新版；Go 的隐式工具链下载被禁用。
版本不符时先按提示选择对应版本，再重试。可用
`go version`、`node --version`、`corepack --version`、`corepack yarn --version` 诊断。
若缺少 Make 或 Git，先使用操作系统包管理器安装；macOS 可先安装 Command Line Tools。

## 从克隆到运行产物

```sh
git clone git@github.com:WenshuaiDev/Omega.git
cd Omega
make bootstrap
make bootstrap # 可重复执行，不改写 yarn.lock
make check
make build
./build/example-service
corepack yarn workspace @omega/example-web preview
```

Go 输出 `Omega example-service version=devel` 后成功退出。
打开预览命令打印的本地地址（通常为 <http://127.0.0.1:4173>），页面显示 Omega。
前端制品位于 `web/apps/example-web/dist/`。按 Ctrl+C 结束预览。
修改页面时可运行 `corepack yarn workspace @omega/example-web dev`。

| 根命令           | 行为                                                            |
| ---------------- | --------------------------------------------------------------- |
| `make bootstrap` | 校验工具；下载 Go 依赖；`yarn install --immutable`              |
| `make fmt`       | 用同版 gofmt 和固定 Prettier 修正本阶段源码、配置与文档         |
| `make check`     | 只读格式检查、逐模块 vet/test、TS7 类型检查、ESLint；不自动修复 |
| `make build`     | 构建 Makefile 清单内全部 Go 程序及所有前端工作区构建目标        |

任一底层步骤失败，根命令非零退出。`check` 可以更新工具缓存，但不修改源码。
本阶段没有独立 Go 单元用例，`go test` 仍覆盖两个实际模块；外部行为验收见
[验收流程](docs/stage1/acceptance.md)。构建通过不能替代类型检查通过。
首次安装要求公共网络可用，不支持离线安装。

Go 依赖准备使用逐模块 `go list -deps -test ./...`，尊重 Workspace 中的本地 libs，
避免将尚未发布的 libs 占位版本当作远程下载目标。当前没有外部 Go 依赖，因此没有人为生成空 go.sum。

## 代理、镜像和安装排错

按网络情况设置 `HTTP_PROXY` / `HTTPS_PROXY` / `NO_PROXY`；Yarn 使用
`YARN_HTTP_PROXY` / `YARN_HTTPS_PROXY`，Corepack 可设置 `COREPACK_NPM_REGISTRY`。
Go 使用 `GOPROXY`（必要时设置 `GOPRIVATE`）；Yarn registry 可通过
`YARN_NPM_REGISTRY_SERVER` 覆盖。优先使用可信且保持包内容一致的镜像，不关闭 TLS 校验。
含账号的代理地址或 token 只放在用户环境，不能提交。
网络或不可变锁文件错误会保留原始诊断；核对网络与依赖声明后重新执行，
不要在 bootstrap 中删除锁文件或切换到可变安装。
首次安装可能出现 Yarn 对官方 TypeScript 6 兼容包的可选补丁警告 YN0066；
目前该补丁找不到 `_tsc.js`，安装仍成功。保留原始诊断，不关闭补丁机制；
必须继续分别通过 TS7 类型检查、ESLint 和构建来确认兼容性。

## 工程职责与依赖方向

| 位置                       | 职责                                                 |
| -------------------------- | ---------------------------------------------------- |
| `go.work`                  | 连接同一提交协同开发的 Go 模块；根目录不是 Go Module |
| `services/example-service` | 独立服务模块，当前只有退出型示例程序                 |
| `libs/buildinfo`           | libs 单一共享模块中的业务无关版本能力                |
| `web/apps/example-web`     | React 应用；根 package.json 管理私有 Yarn Workspace  |
| `web/packages`（将来按需） | 共享前端包，只能被应用依赖，不能反向依赖应用         |
| `contracts`（将来按需）    | 跨进程接口定义                                       |
| `clients`（将来按需）      | 契约对应的调用能力                                   |
| `environments`（将来按需） | 非敏感环境差异定义                                   |
| `deploy`（将来按需）       | 将应用部署到已有环境                                 |
| `infra`（将来按需）        | 创建运行平台与基础设施                               |

服务可以依赖 libs；libs 不依赖服务；服务不得直接导入其他服务实现。
不逐共享包拆 Go Module，不承诺 libs 独立发布或 `GOWORK=off` 的独立安装。
新增实际 Go 模块时同时登记 go.work 和 Makefile 的 GO_MODULES；
新增 main 包时登记 GO_PROGRAMS，并保持程序名称唯一。
新增前端工作区需提供 typecheck、lint、build 脚本；共享包不得依赖应用。
未使用目录仅记录职责，不创建空包。没有 HTTP 服务、业务功能、配置加载器、部署或 CI 工作流。

## 环境与 Secret

环境名称固定为 local、dev、test、staging、prod；CI 是检查执行场所，不是业务环境。
本地私密配置归属对应服务或应用，使用被 Git 忽略的 `.env.local`；
需要样例时提交无真实凭据的 `.env.example`。环境定义只保存非敏感差异。
浏览器能读取的所有配置都视为公开信息，即使来自被忽略的本地文件也不能包含 Secret。
两个示例无需配置，本阶段不实现配置加载或 Secret Provider。

## 前端工具和 VS Code

Yarn 使用 node-modules，依赖目录、缓存、安装状态和产物均忽略；声明及锁文件提交。
项目通过 `@typescript/native` 别名运行 TypeScript 7 的 `tsc`；
`typescript` 别名指向官方 `@typescript/typescript6`，只为 ESLint 提供兼容 API。
执行 `corepack yarn workspace @omega/example-web typecheck` 会先打印真实编译器版本 7.0.2。
对应[官方并行方案](https://devblogs.microsoft.com/typescript/announcing-typescript-7-0/#running-side-by-side-with-typescript-6.0)。

VS Code 安装工作区推荐的 [TypeScript 7 官方扩展](https://marketplace.visualstudio.com/items?itemName=TypeScriptTeam.native-preview)，
在命令面板启用 TypeScript 7 Language Server。扩展应使用项目中安装的 TS7；
不要把 `typescript/lib` 兼容 API 指定为编辑器 SDK，也不生成 PnP Yarn SDK。
CLI 验收与编辑器实际运行分别记录，其他编辑器不在本阶段验收范围。

最终版本与平台证据见[阶段 1 验收](docs/stage1/acceptance.md)。
