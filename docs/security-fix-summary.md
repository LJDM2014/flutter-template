# 局域网即时通讯 安全修复变更摘要

> 依据：《架构风险与优化建议报告》（[architecture-risk-report.html](architecture-risk-report/architecture-risk-report.html)）P0/P1 路线图
> 修复周期：2026-10-22
> 范围：R1（明文传输）、R2（PBKDF2 阻塞）—— P0；R3（重连停摆）、R4（token 明文落盘）—— P1
> 验证结果：`flutter analyze` 0 告警，全量 105 项测试通过（含 TLS 端到端 5 项、重连恢复链路改写）

---

## 1. R1 明文传输（P0）→ WSS/HTTPS 全链路 TLS

**风险**：WS 消息与 REST 凭据在局域网内明文传输，可被同网段嗅探/篡改。

**修复内容**：

| 模块 | 变更 |
| --- | --- |
| 证书生成 | 新增 `core/network/relay_cert.dart`（pointycastle）：RSA-2048 自签证书（CN=LAN Messenger Relay，有效期 10 年，basicConstraints CA:true），TBS/SPKI/PKCS#8 全部 DER 手工拼装；`relay-cert.pem`/`relay-key.pem` 以「临时文件 + rename」原子落盘于应用数据目录，幂等复用 |
| 服务端 | `HostServer.start` 新增可选 `SecurityContext`（shelf_io 以 TLS 监听）；证书生成/加载失败降级为明文（可用性优先）；`RelayStatus.secure` 标记并在连接页展示 |
| 服务探测 | `probeServer` 改为**先 TLS 后明文**（`ProbeResult{reachable, secure}`），防止把 TLS 服务误判为明文可达；IO 端 `SecureSocket.connect`（onBadCertificate 接受自签），Web 端 fetch `/api/me` 近似探测 |
| 客户端 | `ResolvedServer.secure` + `pref.server_secure` 持久化；WS 按 secure 选 wss/ws，REST 选 https/http（https 使用接受自签证书的 `IOClient`）；平台差异经 `tls_support.dart` 条件门面封装（IO 端 wss 带 `customClient`，Web 端证书信任由浏览器策略管理并给出首次信任提示） |

**新增测试**：`test/relay_tls_test.dart` 5 项（证书幂等可加载、TLS 探测命中、https REST 闭环、wss 双端握手、明文不误判）。

## 2. R2 PBKDF2 阻塞（P0）→ Isolate 化

**风险**：10 万次迭代 PBKDF2 同步执行在事件循环上，服务端并发登录时阻塞心跳与消息转发。

**修复内容**：
- `PasswordHasher.hash/verify` 改为 `Isolate.run` 后台异步执行（返回 `Future`），不再阻塞事件循环；
- `AccountStore.register/verifyLogin/changePassword` 调用点与相关测试同步适配 `await`；
- `deriveHex`（RFC 向量校验用）保持同步不变。

## 3. R3 重连停摆（P1）→ 永不放弃的慢速轮询

**风险**：重连退避耗尽后进入 `disconnected` 终态并放弃，客户端失去自动恢复能力，需用户手动干预。

**修复内容**：
- [ws_client.dart](../lib/core/network/ws_client.dart)：退避耗尽（`BackoffStrategy.delayFor` 返回 null）不再进入终态，转 **60s 慢速轮询**（`slowPollInterval`），保持 `reconnecting` 阶段按周期重试，中继恢复后下一周期自动自愈；
- `LanConnState` 新增 `slowPolling` 标记，连接页/消息页空态区分文案：「连接断开，Xs 后重连…」（快速退避）vs「连接中断，每 60s 自动重连，恢复后无需手动操作」（慢速轮询）；
- 聊天层语义：慢速轮询期间消息保持「发送中」等待补发（不标记失败）；仅客户端实例替换/主动断开（`disconnected`）时标记 failed，用户可点击重试；
- `chat_flow_test` 阶段⑦改写为完整链路：退避耗尽 → 消息保持发送中 → 实例替换标记失败 → retryMessage 重新入队 → 恢复连接补发转已送达。

## 4. R4 token 明文落盘（P1）→ 摘要存储 + 安全存储

**风险**：服务端 `sessions.json` 保存明文 token（文件泄露即身份泄露）；客户端 token 明文存于 shared_preferences。

**修复内容**：

**服务端**（[account_store_io.dart](../lib/core/auth/account_store_io.dart)）：
- `sessions.json` 只存 `SHA-256(token)` 摘要（map 键与 `AuthSession.token` 均为摘要），校验时对来方明文 token 做同样摘要后比对；
- `verifyLogin` 返回值是唯一携带明文 token 的会话对象（下发给客户端仅此一次）；
- 离线补投、多设备踢出、改密吊销均按摘要键控，行为不变。

**客户端**（新增 `core/auth/token_store.dart` 门面体系）：
- `TokenStore` 接口 + `InMemoryTokenStore`（测试注入）；
- IO 实现（Windows DPAPI / Android Keystore，flutter_secure_storage ^11）：token 不再明文写入 shared_preferences；首次读取自动迁移旧版明文副本并删除源文件；
- Web 实现（localStorage）：键名沿用 `pref.auth.token`，存量会话免迁移（浏览器端隔离边界由同源策略提供）；
- `auth_providers` 经可覆写的 `tokenStoreProvider` 读写：恢复读取（平台通道异常按无会话处理）、登录写入、登出删除；账号资料（user_id/username/nickname，非敏感）仍存 shared_preferences。

## 5. 变更文件清单

**新增**
- `lib/core/network/relay_cert.dart`、`lib/core/network/tls_support.dart`（+ io/web 实现）
- `lib/core/auth/token_store.dart`、`token_store_base.dart`、`token_store_secure.dart`、`token_store_prefs.dart`
- `test/relay_tls_test.dart`

**修改**
- 服务端：`host_server_io.dart`、`account_store_io.dart`、`password_hasher.dart`、`account_store.dart`、桌面启动装配
- 客户端：`ws_client.dart`、`backoff.dart`（语义注释）、`server_probe.dart`、`server_resolver.dart`、`auth_providers.dart`、`connection_providers.dart`、`chat_providers.dart`、`connect_page.dart`、`chat_page.dart`、`constants.dart`
- 测试：`account_store_test.dart`、`auth_session_test.dart`、`app_test.dart`、`chat_flow_test.dart`、`password_hasher_test.dart` 等
- 依赖：`pointycastle`（R1）、`flutter_secure_storage`（R4）、`crypto`（R4 摘要）

## 6. 升级影响与注意事项

1. **服务端存量会话**：升级后旧版明文 `sessions.json` 条目（摘要与明文同为 64 位 hex，无法区分）校验失败，所有存量用户需重新登录一次；建议发布说明中注明。
2. **客户端存量 token**：IO 端自动迁移至安全存储（无感）；Web 端键名沿用（无感）。
3. **Web 端首次使用 wss**：自签证书无法在代码内绕过信任，需先用浏览器访问一次中继地址并信任证书（连接页已有提示）。
4. **证书降级**：证书生成/加载失败时服务端降级为明文监听（可用性优先），连接页会展示 TLS 状态，属预期行为。

## 7. 后续建议（报告 P2 及以下）

- 账号存储迁移 SQLite（AccountStore 抽象已就绪，替换实现即可）；
- 服务端会话 TTL 到期主动清理策略（当前为按需惰性清理）；
- 中继证书到期前提醒/轮换机制（当前 10 年有效期，幂等复用）。
