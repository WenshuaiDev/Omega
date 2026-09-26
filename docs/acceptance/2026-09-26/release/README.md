# R：rc7 最终隔离离线验收

统一入口实际返回 **PASS / 0**，见[调度结果](dispatcher-results.tsv)与[目标结果](result.txt)。本次运行从 UTC 2026-09-26 02:53:41 开始，最后一个迁移修复操作于 03:10:36 开始，其成功、Secret 扫描及最终外网拒绝均记录在[精选日志](selected-drill.log)。这是 macOS arm64 / Docker Linux arm64 上的 **Linux amd64 模拟**，不属于原生 Linux amd64 或真实生产交付；原生验收保留 #20。

## 候选、调用方和独立预期值

| 项目 | 实际值 |
| --- | --- |
| 候选 | `0.1.0-issue13-rc7` |
| 候选源码 | `4f6f5b3a2b1f847f4f9fa1ca1f5f94ff56c7930d` |
| 外层归档 SHA-256 | `5723efe8e9ad447c681111ab7793940154e4e24ad1ff9c3777d5b45f0cd06b17` |
| 清单 SHA-256 | `341fc4435b8cb914c317bb446ddd8a972ce267299502a86446f9ba5c38c5de9e` |
| 调度器源码 | `578cae2a4b62662d834225f7ee9ccdf2982b37f3` |
| 实际旧候选 | `0.1.0-issue13-rc4`，独立归档/清单预期值见[实际委托命令](delegated-command.txt) |

[完整清单](manifest.tsv)绑定六个镜像内容 ID、Linux amd64 架构和每份发布文件；[构建记录](build.json)在构建时正确标注验收尚未执行，后续验收绑定这个清单，不改写包内记录。候选之后的 `bbd6a33` 只改质量入口、包装器回归和验收脚本，没有改发布材料或运行时文件。第一次 rc7 演练的精确 0755 断言失败后，原归档保持不变，使用消费者权限验证重新完整执行。

[可信哈希记录](trusted-hashes.txt)另行保存。预期 SHA 作为显式参数在导入/部署前提供，不取归档内的自声明值作为认证依据；这里只记录此次操作员的可信预期值，不声称具有发布者数字签名。

## 实际命令与平台

```bash
./scripts/acceptance.sh release --output NEW_EVIDENCE_DIRECTORY \
  --archive RC7_ARCHIVE --archive-sha256 RC7_ARCHIVE_SHA \
  --version 0.1.0-issue13-rc7 --manifest-sha256 RC7_MANIFEST_SHA \
  --harness-image omega13-offline-harness:amd64 \
  --old-archive RC4_ARCHIVE --old-archive-sha256 RC4_ARCHIVE_SHA \
  --old-version 0.1.0-issue13-rc4 --old-manifest-sha256 RC4_MANIFEST_SHA
```

上面用占位路径避免依赖执行机器目录；[实际委托命令](delegated-command.txt)保留全部哈希及顺序。[调用方平台](dispatcher-platform.txt)、[Docker/验收镜像及工具版本](platform.txt)、[隔离目标架构](target-platform.txt)分别记录。目标是独立、初始空镜像/容器/卷的 Docker daemon，外层 `--network none`、独占数据卷、没有宿主 Docker socket；未修改宿主全局网络。

## 场景与实际证据

| 场景 | 结果和证据 |
| --- | --- |
| 普通操作员导入与冷部署 | UID1000 真实导入六镜像并完成首次 test 部署。[权限记录](operator-import-modes.txt)为 0775 / 1000:1000，实际 PostgreSQL UID70 可读、可执行。 |
| 双层网络隔离 | daemon 的直接 IP curl 退出 7、DNS curl 退出 6、镜像 pull 退出 1 且 network unreachable。应用网络命名空间的直接 TCP 返回 errno101，主机名解析返回 errno-3；同实例内部 API 仍成功。TLS/HTTP 应用错误没有被当成断网证明。 |
| 同镜像提升与重复启动 | test/prod 比较五个长期运行服务的[实际内容 ID](promotion-images.tsv)一致，另一个 tools 镜像始终由同一清单核验后用于一次性检查。独立输入、真实 TLS 路由/深层页/配置/API 版本检查、重复部署和 status 均通过。 |
| 正式 omega 薄包装 | 七种正式命令的独立 JSON 均可解析且 exit_code0；[doctor](omega-doctor.json)、[运行态 health](omega-health-check.json)、[默认人类输出](omega-human.txt)、[无效命令 exit2](omega-invalid.json)。对已停止 API 执行迁移/ensure 后仍停止；同版镜像、输入/角色边界和拒绝场景实际通过。 |
| 完整性与身份拒绝 | 损坏归档、发布文件、清单、缺镜像、同标签错误内容和错误输入所有权均在进入维护前拒绝；未现场拉取或构建。 |
| 已有实例就绪故障 | 撤销运行角色 SELECT 权限造成真实 start 阶段失败，[journal](readiness-failure/journal.tsv)退出1，[实际状态](readiness-failure/containers.json)保存 API `restarting` / health `starting`。维护标记/卷保留，**此场景实际断言外部 HTTP503**；恢复权限后同入口重试成功。 |
| 首次部署迁移失败 | 技术 DB 初始化后由 DDL 事件触发器使实际迁移 SQL 失败；[journal](migration-failure/journal.tsv)退出4、[CLI](migration-failure/migration.json)为 SQLSTATE P0001，[实际镜像](migration-failure/actual-images.txt)只有 DB；[数据库记录](migration-failure-state.txt)表明失败已记录、installation 不存在、已应用版本0。维护标记保留，没有启动不兼容 API；移除故障后原入口重试通过。**此首次部署场景未以外部 HTTP503 作为证据。** |
| 并发与取消 | 实际 SQL 表锁阻塞操作，同实例并发退出6、TERM退出130；[取消 journal](canceled-operation/journal.tsv)与实际任务清理通过。独立 test/prod 随后并行重试成功。 |
| TLS 拒绝与原子更新 | 主机名、私钥不匹配、过期、未来证书四类实际拒绝；失败预检保留旧证书/私钥对，随后明确重建 edge 提供新证书。 |
| 真实旧版本回退 | 使用[旧 rc4 API 内容 ID](rollback-old-image.txt)回退成功，[前](rollback-db-before.txt)/[后](rollback-db-after.txt)数据库结构版本、校验和和安装身份逐字节相同。未知新结构由实际旧二进制拒绝，未切换。 |
| Secret 边界 | 12 个受控凭据/私钥标记，494 项文件、日志、配置/历史及原始/解压镜像层检查零命中；不打印标记值。此结果限定于受控标记，不扩大为所有未知敏感信息的普遍保证。 |
| 自有资源清理 | 成功后移除本次 daemon/数据卷，早先失败的私有演练资源也按标签清理；[独立只读查询](cleanup-verification.json)确认 acceptance 标签的外层容器和卷均为空。其他项目资源未纳入操作。 |

完整运行的安全诊断和成功断言保留在[精选日志](selected-drill.log)，原始来源 SHA-256 在[总索引](../provenance.json)。不提交原始输入、凭据、证书私钥、完整镜像包、数据库或大段服务日志。受控 daemon/磁盘故障回归另属 Q3，不冒充这次真实 Docker 演练。
