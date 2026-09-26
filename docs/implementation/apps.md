# 前端工作区与参考应用（#15）

两个独立应用位于 `apps/web`、`apps/console`，工作区名称分别为 `@omega/web`、`@omega/console`。实际复用的启动、严格公开配置校验、参考页面与样式位于 `packages/reference-app`，通过 `workspace:*` 引用；两个 app 不引用对方源码。

## 运行与构建契约

- Node **24.21.0 LTS**、Yarn **4.18.1**、TypeScript **6.0.3**、React **19.3.0**、Vite **8.3.1**、ESLint **10.11.0**、typescript-eslint **8.70.1**。Vitest **5.0.1**、jsdom **30.1.1**。锁文件只有根 `yarn.lock`。版本依据 npm 官方元数据，Node LTS 通道依据 [Node 发布记录](https://nodejs.org/en/about/previous-releases)。typescript-eslint peer 范围 `>=4.8.4 <6.1.0` 已核对；安装、检查、构建是兼容性证据。
- 保留 Yarn 1440 分钟新版本隔离策略；未选取当日发布的 Vitest 5.0.2 与 @types/node 24.19.0，使用 5.0.1 与 24.13.6。
- `apps/Dockerfile` 的 `development` 提供 Node/Yarn；任意宿主 UID 可读取 `/opt/corepack` 中预装 Yarn。工作目录 `/workspace`，命令 `yarn workspace @omega/web dev` 或 console，监听 `0.0.0.0:5173`。
- 单一安装任务运行 `yarn install --immutable`。开发服务器不安装依赖。依赖根目录 `node_modules` 和 `.yarn` 必须可写，`.yarn` 保存 cache/global/install-state；不能把 Yarn 缓存放到 node_modules 内（linker 会清理它）。两个 app 以及实际共享包的嵌套 node_modules 也应有受控可写挂载。
- 根 `yarn typecheck`、`yarn lint`、`yarn test`、`yarn build` 自动遍历全部实际工作区成员；`yarn format:check` 只读，`yarn format` 是显式维护操作。
- 固定 base `/web/`、`/console/`；HMR socket 使用页面的主机和端口，路径分别 `/web/hmr`、`/console/hmr`，edge 应保留前缀并转发 Upgrade。
- edge 精确提供 `/<app>/runtime-config.json`，`Cache-Control: no-store`。JSON 必须恰好包含 `schemaVersion:1`、匹配的 `appId`、`environment:dev|test|prod`、非空 `version`、`apiBaseUrl:/api`；拒绝重复/未知/缺失字段、注释、尾逗号、错误类型和任意接口地址。校验完成后才动态加载 React、挂载与调用 API；失败显示明确错误，不打印配置内容或回退地址。请求均有 10 秒超时。
- `production` 目标 `--build-arg APP=web|console` 分别构建独立镜像，端口 8080、非 root nginx、可读只读根文件系统，仅 `/tmp` 需要 tmpfs。`VERSION`、`COMMIT` 写入 OCI 标签。镜像无运行时 JSON、Secret 或 CDN 依赖，环境差异由 edge JSON 提供。
- app 静态 nginx：深层无扩展名路径回退 HTML，缺失 JS/CSS/其他带扩展名资源 404；哈希 assets 一年 immutable，HTML no-cache。只响应自身 base 及内部 `/health/live`。公开配置路径本身 404，必须由 edge 提供。

## 2026-09-26 实际验证

环境：macOS arm64 宿主、Docker Desktop Linux arm64。以下不代表原生 Linux amd64 验收。

1. `docker build --target development -f apps/Dockerfile -t omega-apps-dev:issue15 .` 成功。以 UID 501/GID 20、`--network none`、源码挂载运行 `node --version && yarn --version && yarn install --immutable && yarn typecheck && yarn lint && yarn test && yarn build && yarn format:check` 全部退出 0（依赖缓存已预热）。输出 Node v24.21.0、Yarn 4.18.1，24 个测试通过（每 app 5，配置 14），两个 Vite 正式构建成功。
2. 不匹配锁文件负例：临时向根包加入已缓存的 React 依赖，`yarn install --immutable` 退出 1、明确 YN0028，锁文件未改写；manifest 随后恢复。初次锁文件由显式依赖维护生成，普通检查不更新它。
3. 两次 `docker build --target production --build-arg APP=web|console --build-arg VERSION=issue15 -f apps/Dockerfile ...` 成功。以只读根文件系统、16 MiB `/tmp`、cap-drop ALL、no-new-privileges 运行，两 app 根和 `/status/details` 均 200/no-cache，缺失 JS、缺失 assets、runtime JSON、其他入口均 404，实际哈希 JS `public, max-age=31536000, immutable`。
4. 专属 `omega15-hmr` Docker 网络中启动两个 Vite 与临时 Nginx。宿主仅连 Nginx 18317，通过每个 app 的 Vite token 建立 `/web/hmr`、`/console/hmr` WebSocket；修改对应实际入口源文件后两个连接分别收到 `full-reload`，源码随后恢复。此项证明代理 WebSocket 与文件监听；完整浏览器渲染/React Fast Refresh 和正式工程 edge 的集成验收由总体验收继续执行，不能将此协议检查称为完整 OMEGA-04 浏览器通过。临时容器及网络均已删除。

原生 Linux amd64、正式发布包镜像身份、真实 edge 公开 JSON 和完整浏览器验收需由集成流程另行记录。用户明确原生平台无可用主机，保留待办。

集成浏览器检查发现原 `mount.tsx` 混合组件与非组件导出，React Fast Refresh 将组件修改升级为整页刷新。后续修正把唯一组件导出移入 `App.tsx`，保留独立 `mount.tsx` 启动模块，形成可保留 React 状态的刷新边界。修正后重新执行类型、lint、24 项测试、两个正式构建和格式检查通过；状态保留的浏览器证据仍由集成验收记录。
