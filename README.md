# LAN Messenger

基于 Flutter 的局域网实时消息应用：**同一套代码运行在 Web、Windows 桌面端、Android 三端**，设备间可实时互发文字消息（广播 + 定向），架构已预留图片/文件消息扩展。

## 功能特性

- **三端互通**：Windows 桌面端既是客户端，又内置轻量 WebSocket 中继服务（shelf）；Web / Android 作为客户端手动输入地址接入
- **消息模式**：广播（发给除自己外的所有在线设备）与定向（点对点）两种会话
- **在线设备列表**：设备上线/下线实时刷新（roster 广播），本机设备有标记
- **可靠传输**：每条消息携带 `msgId`，服务端确认（ack）后标记「已送达」；未确认消息在断线重连后自动补发；接收端按 `msgId` 去重
- **断线自动重连**：指数退避（封顶 30s ± 20% 抖动）+ 心跳保活（15s ping，连续丢失判定掉线）
- **历史持久化**：每会话独立保存最近 200 条消息到本地（各端各自保留，不强一致），重启后自动恢复
- **昵称设置**：持久化昵称，未设置时显示「未命名设备」
- **自适应界面**：窄屏 NavigationBar / 中屏 NavigationRail / 宽屏展开 Rail，Material 3 明暗双主题

## 技术栈

| 依赖 | 用途 |
|---|---|
| flutter_riverpod 3 | 状态管理（`Notifier` 类式 Provider；类型安全、可测试、编译期安全） |
| go_router | 声明式路由（Flutter Web 默认 hash 策略，刷新不丢路由） |
| web_socket_channel | WebSocket 客户端 |
| shelf + shelf_web_socket | 桌面端内置中继服务 |
| window_manager | Windows 窗口初始化（最小尺寸、居中） |
| shared_preferences | 昵称 / 设备 ID / 上次地址 / 消息历史持久化 |
| uuid | 设备唯一 ID 与消息 ID 生成 |

平台差异通过**条件导入**（`export 'x_stub.dart' if (dart.library.io) 'x_io.dart'`）隔离，业务层不直接引用平台 API。

## 通信协议

统一 JSON 信封，消息类型：`hello`（注册身份）、`roster`（在线列表）、`chat`（文本消息）、`ack`（送达确认）、`ping`/`pong`（心跳），未知类型降级为 `unknown` 不崩溃。

```json
{
  "type": "chat",
  "msgId": "uuid",
  "from": { "id": "device-id", "nickname": "甲" },
  "to": "*" 或目标设备 id,
  "timestamp": 1710000000000,
  "payload": { "text": "hello" }
}
```

- 服务端转发时回填 `from`，广播跳过发送方
- 发送方收到 `ack`（携带 `msgId`）后从待发队列移除；重连成功后按序补发未确认消息

## 项目结构

```
lib/
├── main.dart                  # 入口：桌面初始化 + runApp
├── app.dart                   # GoRouter + MaterialApp.router
├── core/
│   ├── constants.dart         # 全局常量（端口、持久化键名等）
│   ├── platform/              # 桌面启动逻辑（条件导入，Windows 专属初始化）
│   ├── protocol/              # MessageEnvelope / DeviceProfile 协议模型
│   └── network/               # LanWsClient（客户端）、HostServer（中继）、退避策略
├── features/
│   ├── connection/            # 连接页：地址输入、状态横幅、设备列表、本机 IP 展示
│   ├── chat/                  # 聊天页：会话切换、气泡、发送状态
│   └── settings/              # 设置页：昵称管理
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

1. 启动 **Windows 桌面端** —— 它是局域网中继，连接页会显示本机局域网 IP 和监听端口（默认 `9090`）
2. 在其他设备（Web / Android）的连接页输入桌面端地址（如 `192.168.0.112:9090`，仅输 IP 时自动补默认端口）并连接
3. 各端在「设置」中配置昵称（建议连接前设置）
4. 连接页设备列表实时显示在线设备；进入「消息」页选择会话（广播或某台设备）互发消息
5. 断开网络后客户端自动重连，离线期间发送的消息在重连后补发

## 测试与质量

```powershell
flutter analyze   # 0 issue
flutter test      # 16 个用例：协议模型 / 退避策略 / 真实服务器网络集成 / 双容器聊天流程集成
```

测试覆盖：协议序列化往返与容错、指数退避计算、roster 实时更新、广播/定向转发、ack 清队列、断线重连与离线消息补发、消息去重、本地持久化。

## 已知限制

- 仅支持文本消息；`payload` 已是 Map 结构，后续可按消息类型扩展图片/文件
- 各端消息历史各自本地保存，不做多端同步
- 中继服务无鉴权与加密，仅限可信局域网使用
- 中继不做离线消息暂存，「离线补发」仅覆盖发送方断线重连场景
- Windows 构建需要系统支持符号链接（开发者模式）；Android 构建需保留 `android/gradle.properties` 中的 `kotlin.incremental=false`（规避 Kotlin daemon 增量缓存损坏）
- 设备发现为手动输入地址（未引入 mDNS）
