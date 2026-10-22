# LAN Messenger

基于 Flutter 的局域网实时消息应用：**同一套代码运行在 Web、Windows 桌面端、Android 三端**，设备间可实时互发文字消息（广播 + 定向），架构已预留图片/文件消息扩展。

## 功能特性

### 三端互通

- **Windows 桌面端既是客户端，又内置轻量 WebSocket 中继服务**（shelf）；Web / Android 作为客户端接入
- **服务端自动发现**：客户端登录后按本机 /24 网段探测（1~254 并发探测 + WS 握手确认），也可手动输入地址（仅输 IP 自动补默认端口）
- **在线设备列表**：设备上线/下线实时刷新（roster 广播），按账号去重，本机有标记

### 账号体系

- **注册 / 登录**：REST 接口（`/api/register`、`/api/login`、`/api/me`），用户名 3-24 字符、密码 ≥8 位
- **密码安全**：PBKDF2-HMAC-SHA256 加盐哈希存储，服务端不落明文；REST 响应不回传敏感字段
- **Token 鉴权**：登录颁发 token，WebSocket `hello` 握手携带 token 校验；同设备重登踢掉旧连接，同账号多设备可同时在线
- **登录限速**：按「IP|用户名」维度统计，60 秒窗口内失败 ≥5 次返回 429，成功后清零
- **资料管理**：改昵称（实时广播 roster）、改密码（吊销其他设备会话，当前设备保留登录）

### 消息与会话

- **消息模式**：广播（发给其他所有在线用户）与定向（点对点）两种会话，服务端按 userId 路由转发
- **会话列表页**：广播会话固定首位 + 用户会话按最近消息排序，含在线状态、最近消息预览、时间与未读角标（99+ 封顶）
- **未读体系**：非当前会话消息未读计数，切换会话自动清零；不在消息页时 SnackBar 提示「收到 N 条离线消息」
- **离线消息补投**：接收方不在线时服务端按账号暂存，上线后自动补投（带 `replay` 标记）；发送方断线重连后未确认消息自动补发
- **可靠传输**：每条消息携带 `msgId`，服务端确认（ack）后标记「已送达」，接收端按 `msgId` 去重；发送状态三态（发送中 / 已送达 / 失败），失败可点击重试（按原 `msgId` 重新入队幂等覆盖）
- **断线自动重连**：指数退避（封顶 30s ± 20% 抖动）+ 心跳保活（15s ping）；鉴权完成前的消息先缓冲，注册后按序转发不丢失
- **历史持久化**：每会话独立保存最近 200 条消息到本地（各端各自保留，不强一致），重启后自动恢复

### 界面

- **登录即连接**：登录成功直达消息页，自动探测并连接中继服务；连接页降级为状态页（显示进度 / 失败原因 / 重试入口）
- **自适应布局**：窄屏 NavigationBar / 中屏 NavigationRail / 宽屏展开 Rail，Material 3 明暗双主题

## 技术栈

| 依赖 | 用途 |
|---|---|
| flutter_riverpod 3 | 状态管理（`Notifier` 类式 Provider；类型安全、可测试、编译期安全） |
| go_router | 声明式路由（Flutter Web 默认 hash 策略，刷新不丢路由） |
| web_socket_channel | WebSocket 客户端 |
| shelf + shelf_web_socket | 桌面端内置中继服务（WS + REST） |
| http | REST 客户端（注册 / 登录 / 资料） |
| crypto | PBKDF2-HMAC-SHA256 密码哈希 |
| window_manager | Windows 窗口初始化（最小尺寸、居中） |
| shared_preferences | token / 昵称 / 设备 ID / 上次地址 / 消息历史 / 未读计数持久化 |
| uuid | 设备唯一 ID 与消息 ID 生成 |

平台差异通过**条件导入**（`export 'x_stub.dart' if (dart.library.io) 'x_io.dart'`）隔离，业务层不直接引用平台 API。

## 通信协议

统一 JSON 信封，消息类型：`hello`（注册身份，携带 token）、`roster`（在线用户列表）、`chat`（文本消息）、`ack`（送达确认）、`error`（服务端错误）、`ping`/`pong`（心跳），未知类型降级为 `unknown` 不崩溃。

```json
{
  "type": "chat",
  "msgId": "uuid",
  "from": { "id": "device-id", "userId": "u-xxx", "nickname": "甲" },
  "to": "*" 或目标 userId,
  "timestamp": 1710000000000,
  "payload": { "text": "hello" }
}
```

- 服务端转发时回填 `from`，广播跳过发送方；WS 会话须经 token 鉴权后才参与路由
- 发送方收到 `ack`（携带 `msgId`）后从待发队列移除；重连成功后按序补发未确认消息
- 离线补投消息 `payload` 附带 `replay: true`，客户端据此显示离线分隔线与未读提示

## 项目结构

```
lib/
├── main.dart                  # 入口：桌面初始化 + runApp
├── app.dart                   # GoRouter + MaterialApp.router（登录态重定向）
├── core/
│   ├── constants.dart         # 全局常量（端口、持久化键名等）
│   ├── auth/                  # AccountStore 抽象 + JSON 文件实现、PBKDF2 密码哈希
│   ├── network/               # LanWsClient（客户端）、HostServer（中继）、
│   │                          #   服务端探测/解析（server_probe / server_resolver）、退避策略
│   ├── platform/              # 桌面启动逻辑（条件导入，Windows 专属初始化）
│   └── protocol/              # MessageEnvelope / UserProfile 协议模型
├── features/
│   ├── auth/                  # 登录 / 注册页、AuthApi（REST）、AuthController（token 会话）
│   ├── connection/            # 连接状态页：自动连接进度、状态横幅、设备列表、本机 IP 展示
│   ├── chat/                  # 会话列表页 + 聊天页：气泡、发送状态、未读角标
│   └── settings/              # 设置页：改昵称、改密码
└── shared/
    ├── app_paths.dart         # 路由路径
    └── widgets/               # 自适应导航脚手架
```

## 快速开始

环境要求：Flutter 3.44+ / Dart 3.12+

```powershell
flutter pub get
```

### 运行

```powershell
# Windows 桌面端（中继 + 客户端一体，连接页展示本机 IP 与端口）
flutter run -d windows

# Web 客户端（浏览器）
flutter run -d chrome

# Android 客户端（真机/模拟器）
flutter run -d <android-device-id>
```

### 三端联调步骤

1. 启动 **Windows 桌面端** —— 它是局域网中继，注册页显示本机局域网 IP 和监听端口（默认 `9090`）
2. 其他设备（Web / Android）在登录页**注册账号并登录**；登录成功后自动探测同网段中继并连接（也可手动输入地址，如 `192.168.0.112:9090`）
3. 连接页设备列表实时显示在线用户；进入「消息」页从会话列表选择会话（广播或某位用户）互发消息
4. 断开网络后客户端自动重连；对端离线期间发送的消息在其重新上线后自动补投，发送方断线重连后未确认消息自动补发

## 测试与质量

```powershell
flutter analyze   # 0 issue
flutter test      # 98 个用例
```

测试覆盖：协议序列化往返与容错、PBKDF2 哈希与校验、AccountStore 注册/登录/改密/限速语义、指数退避计算、服务端地址解析与网段探测、roster 实时更新、广播/定向按用户路由、token 鉴权与多设备会话、登录限速 429、离线消息暂存补投（replay 标记）、未读计数与离线提示、ack 清队列、断线重连与消息补发、发送失败重试、消息去重、本地持久化、真实服务器网络集成、双容器聊天流程集成。

## 已知限制

- 仅支持文本消息；`payload` 已是 Map 结构，后续可按消息类型扩展图片/文件
- 各端消息历史各自本地保存，不做多端同步
- 中继无 TLS 加密，token 明文传输，仅限可信局域网使用；token 存于 shared_preferences（flutter_secure_storage 暂缓）
- 中继不做服务端消息历史，「离线补投」仅覆盖接收方离线期间的暂存，补投完成后即清除
- Windows 构建需要系统支持符号链接（开发者模式）；Android 构建需保留 `android/gradle.properties` 中的 `kotlin.incremental=false`（规避 Kotlin daemon 增量缓存损坏）
- 服务端发现依赖同网段 /24 探测，跨网段需手动输入地址
- 系统通知（flutter_local_notifications）暂缓
