# Gamebox Android 手机局域网房主设计

- 日期：2026-08-22
- Issue：[支持局域网联机？#8](https://github.com/shadowfish07/gamebox/issues/8)
- 状态：对话设计已确认，等待书面规格审核
- 本期目标：两台面对面的 Android 手机在完全断网时，通过同一 Wi-Fi 或房主热点完成五子棋开房、扫码加入、断线恢复、房主服务崩溃恢复、结算和本地战绩保存

## 1. 背景与目标

Gamebox 当前使用 Flutter 大厅、独立 `:game` Godot 进程和公网 Go 权威服务端完成双人五子棋。邀请码、账号和长期凭证只属于公共服务端；客户端构建时固定公共 API origin，手机本身不承载对局服务。

Issue #8 面向面对面场景：没有电脑、没有公网、没有可用公共服务端时，一台 Android 手机应能创建局域网房间并同时作为玩家，另一台 Android 手机扫码加入。局域网模式必须继续采用权威状态、revision、动作幂等和快照恢复，不能退化为双方各自计算结果的无主同步。

本期目标如下：

1. App 拥有一个与登录无关的本地昵称，没有邀请码也能进入局域网模式。
2. 房主手机运行可恢复的局域网权威服务，房主和客人都作为普通客户端参与。
3. 双方通过二维码交换地址和临时凭证，不需要局域网自动发现或再次填写昵称。
4. 普通网络中断、Godot 进程退出和房主服务意外停止后，未完成对局可以继续。
5. 公网和局域网对局生成同一结构的本地战绩，并在 UI 中统一展示。
6. 局域网身份、房间凭证和战绩绝不进入公共服务端的账号、排名或权威对局数据。

## 2. 范围

### 2.1 本期包含

- Android 24 及以上版本；首期不新增 iOS 或桌面客户端。
- 两名玩家、一个房间、一场五子棋；同一台房主设备同一时间最多保留一个未完成 LAN 房间。
- 两台手机位于同一 Wi-Fi，或客人连接房主通过 Android 系统开启的热点。
- 房主创建房间、显示二维码、等待客人、进入对局、关闭或恢复房间。
- 客人扫码加入；相机不可用时允许手动输入二维码原文。
- 房主 Android 前台服务、Go LAN Engine、HTTP/WebSocket 边界和持久化事件日志。
- 公网与 LAN 共用的本地昵称、本地战绩结构和战绩列表。
- 公共服务端昵称更新接口及非阻塞后台同步。
- 两模拟器自动化验收和两台真实 Android 手机的热点闭环验收。

### 2.2 明确不做

- App 自动创建、配置或关闭 Android 热点；用户在系统界面完成网络连接。
- mDNS、SSDP、蓝牙、Wi-Fi Direct 或附近设备自动发现。
- 房主迁移、第三名玩家、观战、聊天、好友、随机匹配或房间列表。
- 把 LAN 战绩上传公共服务端、计入公网排名或用于公共账号统计。
- 公共账号、邀请码、access token 或 refresh token 在 LAN 模式中降级复用。
- 为局域网连接部署公共 CA 证书或自建 PKI；本期只支持显式启用的受信任私网明文通信。
- 回填升级前已经完成的公网历史对局；本地统一战绩从本功能上线后开始记录。
- 房主 App 被卸载、数据被清除或用户明确放弃后的恢复。

## 3. 已确认的产品决策

### 3.1 一个本地昵称

- `AppProfile.nickname` 是设备上的唯一昵称来源，首次使用 App 时必须填写，填写不依赖邀请码或网络。
- 创建 LAN 房间和扫码加入都自动使用该昵称，不再次询问。
- 公网注册默认提交同一个昵称。
- 已注册用户修改本地昵称后，App 默认向公共服务端同步一份。
- 网络错误时本地昵称立即生效并进入待同步状态；已认证用户保存昵称时立即尝试一次，之后在 App 启动、回到前台和用户手动重试时再次尝试，同一前台会话内最多每五分钟一次。
- 公共服务端返回昵称冲突或格式错误时停止自动重试，保留本地昵称并提示用户修改。
- 昵称同步失败不清除登录信息，不退出当前对局，也不阻止公网或 LAN 游戏。同步成功前，其他公网玩家仍看到服务端上一次接受的昵称。

### 3.2 LAN 是临时身份，不是游客公网账号

- LAN 玩家 ID、房间令牌和恢复令牌只绑定一场本地房间。
- 没有邀请码的用户可以直接使用 LAN；已经注册的用户也可以随时临时切换到 LAN。
- 切换模式不会读取、覆盖或删除公共 refresh token。
- 局域网服务不提供公共注册、邀请码消费、账号迁移或公共对手列表。

### 3.3 战绩统一展示、内部保留来源

- 公网和 LAN 终局都写入同一个本地 `GameResult` 模型。
- 战绩列表按结束时间统一排序，不显示“公网”或“局域网”标签。
- 数据层保留不可见的 `source` 字段，用于排错、迁移和阻止 LAN 战绩误上传。
- 双方各自在自己的设备上保存权威终局结果；查看 LAN 战绩不依赖房主继续在线。

## 4. 总体架构

```text
房主 Flutter / MainActivity
  ├─ AppProfile + LAN 房间 UI
  └─ LanHostService（Android 前台服务，主进程）
       └─ Go LAN Engine（gomobile AAR）
            ├─ 单房间内存权威状态
            ├─ 五子棋规则、revision 和动作幂等
            ├─ 持久化事件日志与恢复
            └─ HTTP + WebSocket 监听

房主 Godot :game ── ws://127.0.0.1:<port> ──┐
                                             ├─ Go LAN Engine
客人 Godot :game ── ws://<host-lan-ip>:<port> ┘

双方终局事件 ── GameResultBridge ── 本机原子结果文件 ── Flutter 战绩列表
```

### 4.1 Go LAN Engine

新增一个不导入 `modernc.org/sqlite`、公网 auth、users 或持久化 match service 的纯 Go 移动端入口。它复用现有：

- `protocol` 的版本化消息外壳和 fixture；
- `games` 注册表和 `games/gomoku` 权威规则；
- action ID、expected revision、快照、心跳和恢复令牌的既有语义。

LAN Engine 只实现单房间所需的窄状态机和 HTTP/WebSocket 路由。Android 通过 [`gomobile bind`](https://pkg.go.dev/golang.org/x/mobile/cmd/gomobile) 将入口打成 AAR，并仅暴露启动、停止、查询状态、创建房间、恢复房间和更新网络地址所需的方法。

不能直接把完整 `gameboxd` 绑定进 APK。当前 match service 深度依赖 `modernc.org/sqlite`，而该驱动的[官方支持平台列表](https://pkg.go.dev/modernc.org/sqlite)不包含 Android。移动端采用单房间事件日志，避免复制公共 SQLite 服务的账号和多用户持久化复杂度。

### 4.2 Android `LanHostService`

- 用户在可见的 Flutter 页面点击“创建房间”或“继续局域网对局”时启动服务。
- 服务运行在 App 主进程；Go 网络循环使用自己的 goroutine，不阻塞 Android 主线程。
- 服务立即提升为前台服务并显示不可隐藏的“正在主持局域网对局”通知。
- Flutter Activity 进入后台、Godot 在独立 `:game` 进程运行时，服务继续主持房间。
- 服务使用 `START_STICKY` 请求系统在普通进程回收后重建，但恢复正确性不依赖系统一定自动重建；下次打开 App 时也必须可以恢复。
- 用户完成、主动放弃或明确关闭房间后停止前台服务并移除通知。

Android 8 及以上限制后台服务，Android 14 及以上要求匹配的前台服务声明和权限；实现必须遵循[Android 前台服务要求](https://developer.android.com/develop/background-work/services/fgs)。

### 4.3 Flutter

Flutter 新增四个边界：

1. `AppProfileStore`：本地昵称、昵称同步状态和安全迁移。
2. `LanRoomController`：创建、扫码、加入、等待、恢复和放弃房间。
3. `LanHostPlatform`：通过 MethodChannel 控制 Kotlin 前台服务并读取服务状态。
4. `GameHistoryStore`：导入、去重、排序和展示本机 `GameResult`。

公共 `ApiClient` 和 `SessionController` 继续只连接公共 origin。LAN 请求使用独立客户端和独立临时凭证，二者不能共享 token provider、401 刷新回调或安全存储键。

### 4.4 Godot 和 Android 结果桥

- LAN 与公网继续启动同一个 Gomoku 场景和 `MatchClient`，只改变注入的 WebSocket origin 和一次性票据。
- 公共和 LAN 协议都新增同一版本化终局结果 payload，包含生成本地战绩所需的双方昵称、颜色、结果、结束时间、最终 revision 和完整规范事件。客户端中途重连后也必须从权威端取得完整结果，不能靠本地缓存补齐历史。
- 一个窄的 Android `GameResultBridge` 接收严格 JSON，验证固定 schema 后在 App 私有目录写入每场一个原子结果文件。
- 同一 `matchId` 重复提交必须幂等；跨进程写入不使用不可靠的多进程 `SharedPreferences`。
- Flutter/Kotlin 在启动每场 Godot 对局前持久化一个不含凭证明文的 `PendingGameResult`，至少记录 match ID 和来源。结果文件原子落盘后才清除 pending 标记。
- Flutter 回到前台后导入结果文件并刷新统一战绩列表；存在 pending 而结果文件缺失时，从对应权威端重新获取终局结果。

### 4.5 公共服务端昵称更新

公共服务端新增认证接口 `PATCH /v1/me`。请求固定为 `{"nickname":"新昵称"}`，成功返回 `200 {"user":{"id":"...","nickname":"..."}}`；多余字段、错误类型或无效格式返回 `invalid_request`，唯一键冲突返回 `nickname_taken`，未认证返回 `unauthorized`。它调用现有 `users.NormalizeNickname`，继续执行 2–16 个 Unicode code point、可见字符、首尾空白裁剪、连接符上下文和不区分大小写唯一键规则。更新只改变显示身份，不撤销会话、不改变对局玩家 ID，也不回写历史事件中的昵称快照。

公共服务端另新增认证接口 `GET /v1/matches/{matchId}/result`。它只允许对局参与者读取已经终结的单场权威结果和完整规范事件，不提供历史枚举；活跃对局返回 `match_not_finished`，非参与者和不存在的 ID 都返回 `match_not_found`。该接口只用于已知 pending match 的崩溃补写，因此不会回填升级前的历史列表。

## 5. 首次使用与模式入口

### 5.1 本地昵称初始化

1. App 启动后先加载 `AppProfile`。
2. 没有本地昵称时显示一次本地昵称页面；成功保存后才能进入游戏大厅。
3. 新用户即使没有邀请码，也可以从大厅进入 LAN 模式。
4. 公网注册页面复用本地昵称，邀请码仍是公共服务端注册的必填项。
5. 已安装旧版本且已有公共会话的用户，在首次成功恢复会话时把服务端昵称迁移为本地昵称。
6. 旧用户首次升级时如果离线且尚无本地昵称，允许先填写本地昵称，并在恢复公共会话后按正常规则同步。

### 5.2 大厅入口

- 五子棋卡片提供“公网对战”和“局域网对战”。
- 公网入口沿用当前状态和对手选择；未注册用户进入时显示邀请码注册入口。
- LAN 入口只显示“创建房间”和“扫码加入”。
- 存在未完成的本机 LAN 房间时，首页优先显示“继续局域网对局”和“放弃”，创建新房间前必须先处理旧房间。
- 战绩入口展示同一个列表，不暴露来源筛选。

## 6. 创建、加入和恢复二维码

### 6.1 创建房间

1. Flutter 验证本地昵称存在，并从可见 Activity 请求所需局域网权限。
2. `LanHostService` 生成随机房间 ID、随机玩家 ID、随机高端口、房间密钥和 token pepper。
3. 服务先持久化 `room.created` journal record 及密钥摘要，再开始监听 `0.0.0.0:<port>`。
4. 服务选择当前 Wi-Fi/热点接口的私网 IPv4 地址，并生成初始加入二维码。
5. 房主获得只绑定本局的 launch ticket，Godot 使用 loopback 地址连接自己的服务。

### 6.2 初始加入二维码

二维码使用版本化深链结构，语义字段至少包含：

- `protocolVersion`；
- `roomId`；
- 房主私网地址和端口；
- 一次性高熵房间密钥；
- 十分钟过期时间。

二维码不包含房主或客人的昵称、公共账号 ID、公共凭证、LAN resume token 或历史数据。

客人扫码后必须完成以下校验：

- URI scheme、字段集合和协议版本完全匹配；
- 地址属于允许的私网 IPv4 范围，端口合法；
- 二维码未过期；
- 本地昵称存在且满足统一昵称规则。

提交加入前，客人先在安全存储生成并保存随机 `joinAttemptId` 和高熵 candidate resume token。加入请求携带本地昵称、attempt ID、candidate token 和二维码房间密钥。服务验证后原子持久化客人临时玩家 ID、昵称、座位、attempt ID 和 token 摘要，再返回 launch ticket；加入被明确拒绝时删除这组候选凭证。

如果服务在持久化后、响应前崩溃，客人使用同一 attempt ID 和 candidate token 重试；服务先用已持久化的 token 摘要识别同一客人，再签发新的 launch ticket，不要求已经失效的二维码房间密钥，也不创建第二个身份。房间锁定后，其他 attempt ID 一律拒绝，初始房间密钥立即失效。

客人把自己的 room ID、最后 endpoint 和 resume token 写入与公共 refresh token 不同的 Android 安全存储键。房间完成、客人明确放弃或房主发出已提交的取消/终局事件后删除该凭证。

### 6.3 恢复二维码

- 房间锁定后不再展示含初始房间密钥的二维码。
- 房主网络地址或监听端口变化时展示恢复二维码，只包含协议版本、room ID 和新 endpoint。
- 客人 App 只有在本地存在该 room ID 对应的 resume token 时才接受恢复二维码。
- 丢失 resume token 的设备不能冒充原客人；房主需要主动放弃并创建新房间。

## 7. LAN 对局协议

### 7.1 身份与票据

- 房主和客人都通过一次性 launch ticket 建立首个 WebSocket 连接。
- 消费 launch ticket 后返回本局 resume token；令牌只绑定 room ID、玩家 ID 和 game ID。
- 房主没有修改棋盘、指定颜色、强制获胜或绕过 revision 的管理接口。
- 服务端随机分配黑白，黑方先行，规则与公共 Gomoku 完全一致。

### 7.2 一次落子

1. 客户端提交坐标、action ID 和 expected revision。
2. LAN Engine 验证房间、玩家、轮次、revision、动作去重和目标空位。
3. Gomoku 规则模块计算新状态和终局结果。
4. 服务创建下一条规范事件并持久化。
5. 持久化成功后才更新内存 revision 并向双方广播。
6. 持久化失败时不广播、不增加 revision，客户端保留旧权威状态并重试。

### 7.3 普通断线

- Godot 沿用现有心跳、退避和 resume token 重连。
- 房主 Godot 崩溃或退出不停止 `LanHostService`；重新进入后连接 loopback 并恢复。
- 客人切换网络或短暂离线时尝试最后 endpoint；endpoint 变化时请求重新扫描恢复二维码。
- 只要房主服务仍可恢复，双方离线不自动判负；正常点击认输才生成认输终局。
- 返回 Flutter、按 Home 键、Godot Activity 退出或普通网络中断都不等于认输。
- 客人尚未加入，或双方加入但 revision 仍为 0 时，任一方可以取消且不生成胜负战绩。
- revision 大于 0 后，任一方主动选择“放弃对局”都提交认输终局，对方获胜；关闭页面本身不能绕过该确认。

## 8. 房主持久化与崩溃恢复

### 8.1 持久化布局

每台房主设备仅有一个 `active_room`，App 私有目录保存：

- 版本化 room manifest：room ID、game ID、创建时间、最近 endpoint 和日志格式版本；manifest 是定位信息，不是权威对局状态；
- Android Keystore 保护的房间密钥材料；
- 按单调 `journalSequence` 排序的规范 journal record；`room.created`、`player.joined`、launch/resume credential 摘要、游戏事件、取消、终局和双方结果落盘确认都进入同一序列；
- 游戏事件另外携带 `gameRevision`；房间恢复以完整 journal 重放结果为真相，不信任 manifest 中的缓存状态；
- 每条 record 的前序哈希和当前哈希，用于检测缺口、乱序和内容损坏；
- 未完成房间的本机 host resume credential。

record 文件采用“写临时文件 → `fsync` → 原子 rename → 同步目录”的提交顺序。临时文件不是已接受 record，启动时可以删除；已经 rename 的 record 不得静默跳过、改写或截断。manifest 更新可以落后于 journal，恢复时从最后一个连续、验证通过的 journal record 重建状态并重新写出 manifest 投影。

### 8.2 提交崩溃边界

- 事件落盘前崩溃：动作未接受；客户端使用同一 action ID 重试。
- 事件已落盘、广播前崩溃：恢复时重放该事件；同一 action ID 返回既有结果，不重复落子。
- 广播后客户端未收到确认：重连快照包含已提交 revision，客户端按 action ID 收敛。
- 终局事件遵守相同顺序；只有终局事件持久化后才能写本地战绩。

### 8.3 启动恢复

1. 普通系统回收后，`LanHostService` 被重建时尝试恢复。
2. 用户强制停止 App、手机重启或系统没有重建服务时，下次打开 Gamebox 显示“继续局域网对局”。
3. 恢复器验证 manifest schema、journalSequence 连续性、哈希链、action ID 唯一性、gameRevision 连续性和 Gomoku 规则重放结果。
4. 验证通过后重建内存状态，优先重新绑定原端口；失败时选择新端口并要求客人扫描恢复二维码。
5. 验证失败时拒绝启动伪造或不完整棋局，保留原始文件并让用户明确放弃。

活跃房间不自动过期，一直保存到完成或用户主动放弃。终局后，服务继续保存终局 journal 和最小恢复凭证，直到双方都确认对应 `GameResult` 已在各自设备原子落盘；两份确认都提交后才清除房间凭证和可恢复状态。若一方长期无法确认，房主可以在明确提示对方可能缺失本地战绩后结束房间。已写入的本地 `GameResult` 始终保留。

## 9. 本地战绩

`GameResult` 至少包含：

- schema version、match ID、game ID；
- 本机玩家昵称、对手昵称、本机颜色；
- `win`、`loss` 或 `draw` 结果及终局原因；
- 开始、结束时间和最终 revision；
- 完整的规范对局事件，用于未来回放；
- 内部 `source=public|lan` 字段。

约束如下：

- 文件名和主键使用 match ID，同一结果重复提交不产生重复记录。
- 写入使用临时文件和原子 rename，损坏结果不进入 UI。
- 公网和 LAN 都从版本化权威终局结果 payload 生成相同结构；客户端预测结果不能写战绩。
- LAN 客户端必须在结果文件 `fsync` 和 rename 完成后才发送 `result.persisted` 确认；服务崩溃后可继续提供相同终局 payload。
- 公网客户端存在 pending 但本地结果缺失时，通过 `GET /v1/matches/{matchId}/result` 补写该场结果；它不能枚举或回填其他旧对局。
- UI 混合展示两种来源，不显示来源标签。
- LAN 结果永不上传公共服务端；本地来源字段不能由展示层覆盖。
- 清除公共登录态不删除本地战绩；卸载 App 或清除应用数据会删除。

## 10. 私网和权限边界

### 10.1 明文 LAN

本期为了面对面热点场景允许 `http://` 和 `ws://`，并承认同一不受信任局域网中的被动监听风险。控制措施是：

- LAN 必须由用户显式创建或扫码进入；公共模式始终使用 HTTPS/WSS。
- 客户端只接受私网 IPv4 endpoint，不接受二维码把 LAN 客户端指向公网明文地址。
- 初始房间密钥高熵、十分钟过期且成功加入后失效。
- 房间锁定后只能使用既有 resume token 恢复。
- 公共 access/refresh token 永远不发送给 LAN origin。
- 日志、截图和 E2E artifact 不保留二维码原文、房间密钥、launch ticket 或 resume token。

### 10.2 Android 权限

- 保留 `INTERNET` 权限，并增加前台服务、通知、相机和适用 Android 版本的局域网权限声明。
- Android 16 使用兼容测试开关验证受限 LAN 行为；Android 17 及更高 target 遵循新的 `ACCESS_LOCAL_NETWORK` 运行时权限。
- 用户拒绝相机权限时允许手动输入；拒绝局域网权限时 LAN 不可用，但公共游戏继续可用。
- 所有权限都在用户点击相应功能后按需申请，不在首次启动时一次性索取。

Android 的当前 LAN 权限演进以[官方 Local network permission 文档](https://developer.android.com/privacy-and-security/local-network-permission)为准，实施和发布时必须按实际 target SDK 复核。

## 11. UI 与错误处理

### 11.1 主要页面

- 本地昵称初始化/编辑页；显示公共昵称同步状态，但同步失败不是游戏门禁。
- 五子棋卡片上的公网与局域网入口。
- LAN 选择页：创建房间、扫码加入。
- 房主等待页：二维码、连接状态、关闭房间。
- 客人连接页：扫描、手动输入、等待和重试。
- 活跃 LAN 恢复卡：继续、显示恢复二维码或明确放弃。
- 公网和 LAN 共用的本地战绩列表。

### 11.2 失败行为

| 情况 | 行为 |
| --- | --- |
| 没有 Wi-Fi/热点地址 | 保留未完成房间，提示连接网络后重试，不降级到移动公网明文 |
| 相机权限拒绝 | 提供手动输入二维码原文 |
| LAN 权限拒绝 | 解释用途并引导系统设置，公网模式不受影响 |
| 二维码过期或版本不兼容 | 明确拒绝，不创建半完成玩家 |
| 房间已满或已锁定 | 拒绝新身份；原客人只能凭 resume token 恢复 |
| 客人掉线 | 自动重连；endpoint 变化后提示重新扫描恢复二维码 |
| 房主 Godot 退出 | 前台服务继续运行，房主可重新进入 |
| 房主服务意外停止 | 双方等待；服务自动或下次打开 App 时从日志恢复 |
| revision 0 时取消 | 提交取消 record，不生成胜负战绩，然后清除可恢复房间 |
| revision 大于 0 后主动放弃 | 二次确认并提交认输终局；对方获胜，双方照常保存战绩 |
| 日志损坏后明确放弃 | 无法生成可信结果；二次确认后只删除本机可恢复状态，并告知用户没有战绩 |
| 恢复日志损坏 | 失败关闭，不静默修复；保留证据并要求用户明确放弃 |
| 昵称临时同步失败 | 后台重试，游戏不受影响 |
| 公网昵称冲突 | 停止自动重试，保留本地昵称并提示修改；公网仍使用旧昵称 |

## 12. 测试与验收

### 12.1 Go 和协议

- LAN 单房间状态机、双方座位、随机颜色、房间锁定和票据消费。
- 五子棋四方向、长连、和棋、认输、revision、action ID 幂等和非法动作。
- 每一个 revision 的“落盘前崩溃”“落盘后广播前崩溃”和“广播后确认前崩溃”。
- manifest 落后、journalSequence 或 gameRevision 缺口、乱序、重复 action ID、哈希损坏、规则重放不一致时的确定行为；只有 manifest 落后可以由完整 journal 自动重建，其余情况失败关闭。
- 初始二维码过期、恢复二维码、第三人加入和错误 room ID。
- `player.joined` 落盘后响应丢失时，同一 join attempt 幂等恢复且其他 attempt 被拒绝。
- LAN 与公共协议 fixture 继续保持相同解释。

### 12.2 Flutter 和 Android

- 本地昵称首次初始化、旧用户迁移、修改、待同步、瞬时重试和昵称冲突。
- 公共 token 与 LAN token 的存储键、provider 和生命周期隔离。
- 创建、扫码、手动输入、等待、继续、放弃和统一战绩列表的 widget 测试。
- `LanHostService` 前台通知、START_STICKY 重建、MethodChannel、端口变化和服务停止测试。
- `GameResultBridge` 严格 schema、原子写入、重复 match ID 和损坏文件测试。
- `PendingGameResult` 在 Godot 启动前落盘，LAN result ack 顺序和公网单场结果补写测试。
- `gomobile bind` 产出 AAR，并验证 APK 中所支持 ABI 的 Go JNI 与 Godot native 库同时存在且可加载。
- 所有用户可见 UI 变更都必须在真实构建的目标 App 中截图，并确保截图不包含二维码密钥或其他凭证。

### 12.3 Godot

- 公网和 LAN launch config 使用同一协议实现。
- 首次快照、重复事件、revision 缺口、普通重连、终局和结果桥。
- 房主 Godot 进程退出后重新启动，前台 LAN 服务不被连带停止。

### 12.4 双模拟器 LAN E2E

新增仓库脚本，在不伪造 Go LAN Engine 的前提下完成：

1. 构建并安装同一个 Debug APK 到两台隔离模拟器。
2. 在模拟器 A 内启动真实 `LanHostService` 和 AAR 服务。
3. 使用 `adb forward` 把模拟器 A 的监听端口暴露给宿主，再由模拟器 B 通过 `10.0.2.2` 进入；这验证移动端服务和协议，但不冒充真实 Wi-Fi 证据。
4. 通过 debug-only 安全注入二维码 payload，自动完成加入；生产入口仍验证真实扫码。
5. 完成落子、客人断线重连、房主 Godot 重启和终局。
6. 强制停止房主 App，在客人保持等待时重新启动 A，恢复相同 room ID、revision 和棋盘后继续。
7. 验证双方本地结果内容和事件哈希相同，战绩列表不显示来源标签。
8. artifact 保存结构化摘要、脱敏日志和关键截图，不保存二维码或令牌。

### 12.5 两台真实 Android 手机热点 E2E

最终完成门槛必须使用同一个候选 APK：

1. 房主通过 Android 系统开启热点，客人加入热点；两台设备关闭移动数据或处于无公网环境。
2. 房主创建房间，客人使用相机扫描真实二维码并加入。
3. 双方进入 Godot，验证颜色、棋盘和 revision 一致。
4. 中途断开并恢复客人网络，验证 resume token 重连。
5. 强制停止房主 App，重新打开后选择继续房间；如果 endpoint 改变，使用恢复二维码重新连接。
6. 完成一局并验证双方得到一致结果、完整事件和统一战绩展示。
7. 切回公共模式，验证公共登录态仍在；昵称同步失败和更新检查失败都不影响 LAN 战绩。

### 12.6 回归门槛

- `bash tool/verify.sh` 继续作为统一构建/测试门槛，并纳入移动 AAR、权限、APK native 资产和结果桥检查。
- `bash tool/e2e_android.sh` 继续验证现有公共服务端双端可玩闭环。
- 新增 LAN 双模拟器 gate；真实双机热点闭环是发布前的目标运行时验收，不能由端口转发模拟器测试代替。
- Release 候选 APK 必须验证 LAN 明文私网策略、前台服务和 Godot/Go 两套 native runtime，而不只验证 Debug 构建。

## 13. 风险与控制

| 风险 | 控制方式 |
| --- | --- |
| Go AAR 与 Godot JNI/ABI 打包冲突 | 先做垂直构建样板；统一 ABI 集合，并在 APK 资产门槛中同时验证两套 native 库 |
| 完整服务端 SQLite 无法用于 Android | LAN Engine 不导入 `modernc.org/sqlite`，使用单房间规范事件日志 |
| Android 后台限制杀死房主 | 可见页面启动前台服务、持续通知、START_STICKY 和下次打开 App 的显式恢复 |
| 服务在提交中途崩溃 | 以单调 journal 为权威，先 fsync/rename 再更新内存和广播；action ID 重试收敛 |
| 加入已提交但响应丢失 | 客人预存 attempt ID 和 candidate token；同一 attempt 幂等取回新 launch ticket |
| 终局已提交但战绩未落盘 | 保存终局 journal，LAN 等双方 ack；公网按 pending match ID 从窄结果接口补写 |
| 热点重建导致 IP 或端口变化 | 保留 room ID 和 resume token，使用不含加入密钥的恢复二维码更新 endpoint |
| 同网段第三方窃听 | 明确受信任网络边界、短期一次性密钥、房间锁定、私网 endpoint 校验，且公共凭证永不进入 LAN |
| 本地战绩被修改 | 只作为本机展示，不上传或影响公共权威统计；损坏文件不展示 |
| LAN 改造破坏公共模式 | 依赖和凭证完全隔离，协议 fixture 共用，并保留统一 gate 与公共双端 E2E |
| UI 改动缺少真实证据 | 遵循仓库 `AGENTS.md`，在真实构建 App 上截图并随验收 artifact 保存脱敏证据 |

## 14. 完成标准

本期只有同时满足以下条件才算完成：

1. 无邀请码用户能设置一个本地昵称并进入 LAN；已注册用户可无损切换公网和 LAN。
2. 两台断网 Android 手机通过房主热点和真实扫码完成同一局五子棋。
3. LAN 使用现有权威规则、revision、动作幂等、快照和重连语义。
4. 房主服务被强制停止后，下次打开 App 能恢复同一 room ID、棋盘、revision、玩家和恢复凭证，并继续完成对局。
5. 公网和 LAN 终局都写入统一本地战绩，UI 不区分来源；LAN 数据不上传公共服务端。
6. 本地昵称修改不会阻止游戏，并按确定的瞬时/冲突规则同步公共服务端。
7. Go、Flutter、Kotlin、Godot、双模拟器 LAN E2E、现有公共 E2E 和候选 APK 检查全部通过。
8. 两台真实手机的热点、扫码、断线、强停恢复、终局和战绩均有脱敏日志与真实 UI 截图证据。

## 15. 继续方式

书面规格审核通过后，下一步使用 Superpowers `writing-plans` 生成实施计划。计划的第一个里程碑必须是可丢弃的垂直技术样板：

1. 纯 Go LAN Engine 经 `gomobile bind` 生成目标 ABI 的 AAR；
2. AAR 与现有 Godot native runtime 同时打入 APK 并在 Android 真机加载；
3. `LanHostService` 在手机上监听 loopback 和 WLAN endpoint；
4. 另一个客户端完成一次最小 WebSocket 握手；
5. 服务停止并从一条已落盘事件恢复。

样板只用于验证最高风险边界，不提前扩展 UI。样板通过后，再按昵称与入口、房间协议、持久化恢复、结果桥、自动化 E2E 和真实双机验收的顺序实施。
