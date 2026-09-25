# 阶段 1 验收

规格与测试边界：[Issue #11](https://github.com/WenshuaiDev/Omega/issues/11)。
测试根级开发者命令、退出码、文件是否变化和实际制品，不测试内部命令拆分。

2026-09-25 已完成 S1-AC-01～10。完整命令验收源码提交：
`dfe96d927d6542227d770ce75d1b6c872d9a5a5c`。
此后仅补充编辑器设置、开发说明与本验收证据；程序、依赖图及根命令不变。

## 工具核查与兼容性

2026-09-25 通过官方 Node 发行索引和 npm 官方 registry 的 latest 标签核对稳定版本，
直接依赖均固定到精确版本；后续 bootstrap 使用已提交的声明和锁文件，不重新查询 latest。

| 工具或依赖                                   | 最终版本                |
| -------------------------------------------- | ----------------------- |
| Go                                           | 1.27.1（规格明确固定）  |
| Node                                         | 26.10.0                 |
| Corepack                                     | 0.36.0                  |
| Yarn（@yarnpkg/cli-dist）                    | 4.18.1                  |
| React / React DOM                            | 19.3.0                  |
| Vite                                         | 8.3.1                   |
| TypeScript 编译器（@typescript/native 别名） | 7.0.2                   |
| 官方 @typescript/typescript6 兼容包          | 6.0.2                   |
| ESLint 实际加载的 TypeScript JS API          | 6.0.3（锁定的传递依赖） |
| ESLint                                       | 10.11.0                 |
| @eslint/js                                   | 10.0.1                  |
| typescript-eslint                            | 8.70.1                  |
| Prettier                                     | 3.9.9                   |
| @types/react / @types/react-dom              | 19.3.0                  |

版本来源：[Node 官方发行](https://nodejs.org/dist/index.json)、
[TypeScript npm 元数据](https://registry.npmjs.org/typescript)、
[Vite npm 元数据](https://registry.npmjs.org/vite)，其他包使用同一 registry 对应包端点。
兼容方式遵循 [TypeScript 官方并行方案](https://devblogs.microsoft.com/typescript/announcing-typescript-7-0/#running-side-by-side-with-typescript-6.0)。

Vite 8.3.1 发布时间为 `2026-09-24T12:26:19.940Z`。
本次安装时尚未达到 Yarn 实际默认的 1440 分钟门槛，故只加入 `vite@8.3.1` 精确例外；
没有修改默认门槛或扩大到其他 Vite 版本。
第一次全新安装产生 YN0066（TypeScript 6 兼容包可选补丁缺少 `_tsc.js`），
安装退出码为 0；原诊断保留在 Linux 日志中。没有禁用补丁或改动依赖包。
两平台的 `tsc --version` 均为 7.0.2，Lint API 均为 6.0.3，
并分别通过类型检查、ESLint、故意错误探针与 Vite 构建。

## 执行平台和复现方法

| 项目         | macOS                                     | Linux                                     |
| ------------ | ----------------------------------------- | ----------------------------------------- |
| 系统         | macOS 27.0，build 26A428                  | Debian GNU/Linux 12 bookworm 容器         |
| 实际架构     | arm64                                     | aarch64 / Go linux/arm64                  |
| 工具         | 上表固定版本                              | 上表固定版本                              |
| 代码副本     | 从本地已提交源码独立 git clone            | 只读挂载源码后在容器内独立 git clone      |
| 依赖目录     | 新建，无 node_modules                     | 新建，无 node_modules，独立容器缓存       |
| 完整验收命令 | `sh scripts/acceptance.sh`，退出 0        | `sh scripts/acceptance.sh`，退出 0        |
| 原始命令输出 | [macOS 日志](evidence/macos-commands.txt) | [Linux 日志](evidence/linux-commands.txt) |

macOS 通过临时 PATH 选择已下载的 Go 1.27.1，系统默认 Go 1.27.0 没有改动。
Linux 使用以下一次性验收镜像，不是应用容器制品，也不是日常开发前提：

```dockerfile
FROM golang:1.27.1-bookworm@sha256:69a7b9788769bec032d238959b61854e9ae87f57be9029ec04e9885fabf99195 AS go
FROM node:26.10.0-bookworm@sha256:2aaae6d91f99fee84cfc92da9b52c22a185752d247746052bbc3f961e44478c6
COPY --from=go /usr/local/go /usr/local/go
ENV PATH="/usr/local/go/bin:${PATH}"
RUN npm install --global corepack@0.36.0 && git config --global --add safe.directory /source
WORKDIR /source
```

在临时目录保存上述 Dockerfile 后构建，项目根目录执行：

```sh
docker build -t omega-stage1-acceptance /path/to/temporary/context
docker run --rm -v "$PWD:/source:ro" omega-stage1-acceptance sh scripts/acceptance.sh
```

验收脚本仅测试当前已提交源码；会创建独立临时克隆并打印日志目录。
故障注入只修改该克隆；不改动调用者的工作副本。它不是 `make check` 的递归子步骤。
修改实现后先提交，再运行该脚本。浏览器观察需另行执行下述预览步骤。

## 验收矩阵

| 编号     | 两平台实测结果                                                                                                   |
| -------- | ---------------------------------------------------------------------------------------------------------------- |
| S1-AC-01 | 首次 bootstrap 退出 0；分别缺失或伪造 Go、Node、Corepack 版本时退出 2，有具体安装/选择版本提示                   |
| S1-AC-02 | 第二次 bootstrap 退出 0，git diff 为空；故意改变依赖版本后触发 YN0028，退出 2，yarn.lock 字节不变                |
| S1-AC-03 | 格式、两个 Go 模块的 vet/test、TS7、ESLint 全部通过；check 前后受控文件无差异                                    |
| S1-AC-04 | Go 程序与 example-web 构建退出 0；分别注入 Go 未定义符号和前端缺失 import，根 build 均退出 2                     |
| S1-AC-05 | 运行 Go 产物退出 0，输出 `Omega example-service version=devel`；源码实际导入 libs/buildinfo                      |
| S1-AC-06 | 两平台各自构建产物由 Vite preview 提供，在实际浏览器中显示 Omega，见下方截图                                     |
| S1-AC-07 | 将 string 项目名赋值为数字，check 由 TS7 报 TS2322 并退出 2；错误文件字节未变；恢复后通过                        |
| S1-AC-08 | 分别破坏 TSX 与 Go 格式，check 均退出 2 且不修改文件；make fmt 退出 0，恢复到原始受控内容                        |
| S1-AC-09 | node_modules、dist、build、两个 .env.local 都被忽略；.env.example 可添加；结束时 git diff 与未忽略新文件清单为空 |
| S1-AC-10 | 上述命令均在 macOS arm64 与 Linux arm64 独立克隆实际执行；只承诺这两个平台/架构组合                              |

另外验证：显式 any 通过类型检查后由 ESLint 拒绝；Go 格式化动词与参数类型不符被 vet 拒绝；
在 libs 中临时加入失败测试时由 go test 拒绝。三种情况根 check 均退出 2。
全部故障恢复后的 make check、make build 与 git diff 检查均退出 0。

## 浏览器证据

使用 macOS 上 Codex 内置浏览器，视口 1280×720，分别访问：

- macOS 干净副本：`corepack yarn workspace @omega/example-web preview --port 4173 --strictPort`。
- Linux 干净副本：容器内 `corepack yarn workspace @omega/example-web preview --host 0.0.0.0 --port 4174 --strictPort`，仅映射到宿主机 `127.0.0.1:4174`。

两个页面的实际可访问性树均显示 heading「Omega」和「工程起点 · example-web」，截图如下。
Linux 证据表示 Linux 构建并提供的制品在宿主机浏览器实际呈现，不宣称 Linux 桌面浏览器验收。

![macOS 构建产物](evidence/macos-browser.png)

![Linux 构建产物](evidence/linux-build-browser.png)

## 编辑器与审查边界

已按 [TypeScript 官方扩展说明](https://marketplace.visualstudio.com/items?itemName=TypeScriptTeam.native-preview)
提供扩展推荐、启用命令以及指向项目 TS7 别名包的工作区设置。
本次未安装或实际启动该 VS Code 扩展，不把 CLI 通过等同于编辑器运行验收。
Issue #11 要求的编辑器支持说明已提供；其他编辑器未验收。

代码审查基点为用户确认的 `9f16a78`。Standards 与 Spec 两个独立审查轴均未发现需要修改的问题；
结果不替代本文件列出的实际执行证据。
