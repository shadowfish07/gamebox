# Gamebox F4 Personal Match History Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在 Gamebox Android App 中交付仅当前用户可见的五子棋战绩统计与时间倒序分页列表。

**Architecture:** Go 服务端在同一 SQLite 只读事务中从 `matches`/`match_players`/`users`/`match_events` 生成当前用户视角的统计和记录，HTTP 层负责严格查询参数与 opaque 游标编解码。Flutter 以独立 feature 承载模型、API、controller 和 Material 3 二级页，首页只注入 API 并负责导航。

**Tech Stack:** Go 1.25.0、SQLite/modernc.org/sqlite、Flutter 3.47.1、Dart 3.13.1、Material 3、Flutter Widget/Integration Test、Bash、ADB/UI Automator、现有双 AVD E2E。

**Spec:** `docs/superpowers/specs/2026-08-25-gamebox-f4-match-history-design.md`

## Global Constraints

- 实施前必须完整阅读 spec 与 `.agents/skills/gamebox-material-3-ux/SKILL.md`，并加载 Flutter App、Core Contract 和 acceptance references。
- F4 v1 只包含个人统计和只读列表；不得增加回放、筛选、详情、点击行为、分享、公开战绩或排行榜。
- 只返回 token 对应用户的记录；HTTP 请求不接受用户 ID。
- 活跃和取消对局不出现在列表中；取消和作废不进入有效对局统计。
- 认输映射为普通胜/负；总手数只计数 `gomoku.move.accepted`。
- 默认页大小 20，合法范围 1–50；排序固定为 `finished_at DESC, match_id DESC`。
- 公开 UI 不得硬编码颜色、字号、圆角或动效；不新增 Navigation Bar，败局不使用 `error` 色。
- 可见返回与 Android 系统返回必须等价；所有交互目标至少 48×48dp。
- 每个行为改动必须先添加失败测试并亲眼确认 RED，再写最小实现取得 GREEN。
- 固定 E2E 不得截图或保留图片；视觉证据在独立真实 Android 运行时活动中取得。
- 最终必须运行 `bash tool/verify.sh` 和 `bash tool/e2e_android.sh`，并附上实际构建 App 的首页入口、亮色战绩页与暗色战绩页截图。
- 每个提交只暂存当前任务列出的文件；保留无关改动，只创建本地提交，不 push。

---

## File Map

```text
server/internal/store/
├── migrate.go                              # 注册 002 迁移
├── migrate_test.go                         # 索引与迁移幂等契约
└── migrations/002_match_history_indexes.sql # 用户战绩成员索引
server/internal/matches/
├── history.go                              # 战绩类型、校验和只读查询
└── history_test.go                         # 结果、统计、手数、分页、损坏数据
server/internal/httpapi/
├── history_handlers.go                     # 查询参数、游标 codec 与 JSON handler
├── history_handlers_test.go                # codec 和 HTTP 契约
└── router.go                               # 鉴权路由与 method fallback
app/lib/features/history/
├── match_history_models.dart               # 严格 JSON 模型
├── match_history_api.dart                  # 鉴权 GET 和查询参数编码
├── match_history_controller.dart           # 首页/翻页状态机
└── match_history_page.dart                 # Material 3 只读二级页
app/test/features/history/
├── match_history_models_test.dart
├── match_history_api_test.dart
├── match_history_controller_test.dart
└── match_history_page_test.dart
app/lib/app.dart                                           # 生产 API 组装与测试注入
app/lib/features/home/home_page.dart                       # 我的战绩入口和路由
app/test/features/home/home_page_test.dart                 # 入口强调、语义与导航
app/test/app_home_test.dart                                # 认证后组装回归
app/test/app_test.dart                                     # GameboxApp 构造参数回归
app/integration_test/semantics_test.dart                   # 稳定语义标识流
tool/e2e_android.sh                                        # 真实双设备战绩读链路
```

## Stable Interfaces

Go 服务层稳定入口：

```go
func (service *Service) ListHistory(
    ctx context.Context,
    gameID string,
    userID string,
    request HistoryPageRequest,
) (HistoryPage, error)
```

Flutter 稳定入口：

```dart
abstract interface class MatchHistoryApi {
  Future<MatchHistoryPageData> fetchPage({String? cursor, int limit = 20});
}

final class MatchHistoryController extends ChangeNotifier {
  MatchHistoryController({required MatchHistoryApi api});
  Future<void> load();
  Future<void> retry();
  Future<void> loadMore();
}
```

## Coverage Map

| 规格要求 | 实施任务 |
| --- | --- |
| 索引与迁移幂等 | Task 1 |
| 结果映射、统计、手数、一致快照、keyset 分页 | Task 2 |
| 鉴权边界、严格参数、opaque 游标、HTTP JSON | Task 3 |
| Flutter 严格模型与鉴权 API | Task 4 |
| 首次加载、重试、自动翻页、迟到请求 | Task 5 |
| 首页入口、Material 3 页面、明暗色、返回、空/错误状态 | Task 6 |
| 稳定 semantics 与真实双 AVD 读链路 | Task 7 |
| 完整门禁、独立 Android 视觉证据和最终审计 | Task 8 |

### Task 1: 添加战绩查询索引迁移

**Files:**
- Create: `server/internal/store/migrations/002_match_history_indexes.sql`
- Modify: `server/internal/store/migrate.go`
- Modify: `server/internal/store/migrate_test.go`

**Interfaces:**
- Consumes: 现有 embedded migration registry 和 schema 断言。
- Produces: `idx_match_players_user_id_match_id(user_id, match_id)`，Task 2 查询以当前用户成员关系为入口。

- [ ] **Step 1: 先把第二个迁移和索引写入失败测试**

```go
wantIndexes := map[string][]string{
    "idx_match_players_user_id_match_id": {"user_id", "match_id"},
}

if err := db.QueryRow(
    `SELECT COUNT(*) FROM schema_migrations WHERE version=2`,
).Scan(&count); err != nil || count != 1 {
    t.Fatalf("migration version 2 count=%d err=%v, want 1", count, err)
}
```

增加从只有 version 1 的旧库打开后出现 version 2 且重复打开不改变 checksum/applied_at 的断言。

- [ ] **Step 2: 运行精确迁移测试并确认 RED**

```bash
(cd server && go test ./internal/store -run 'TestOpenAndMigrate|TestConcurrentOpenAppliesMigrationOnce' -count=1)
```

Expected: FAIL，原因是 002 SQL 文件缺失或新索引不存在。

- [ ] **Step 3: 添加最小迁移**

```sql
CREATE INDEX idx_match_players_user_id_match_id
  ON match_players(user_id, match_id);
```

`migrate.go` 的 registry 只追加 version 2，不修改 001 内容或 checksum。

```go
var migrations = []migration{
    {version: 1, path: "migrations/001_initial.sql"},
    {version: 2, path: "migrations/002_match_history_indexes.sql"},
}
```

- [ ] **Step 4: 重跑存储测试**

```bash
(cd server && go test ./internal/store -count=1)
```

Expected: PASS，新建库、从 version 1 升级的旧库和重复打开均只有一个 version 2 记录与一个新索引。

- [ ] **Step 5: 提交迁移**

```bash
git add server/internal/store/migrations/002_match_history_indexes.sql server/internal/store/migrate.go server/internal/store/migrate_test.go
git commit -m "feat: index personal match history"
```

### Task 2: 实现权威战绩查询

**Files:**
- Create: `server/internal/matches/history.go`
- Create: `server/internal/matches/history_test.go`

**Interfaces:**
- Consumes: `idx_match_players_user_id_match_id`、现有 `Service.db`、`canonicalUUID`、`matchDatabaseError`、五子棋 game registry。
- Produces: `HistoryPageRequest`、`HistoryCursor`、`HistoryStatistics`、`HistoryEntry`、`HistoryPage`、`(*Service).ListHistory` 和不暴露数据值的 `HistoryFailureMetadata`。

- [ ] **Step 1: 定义服务契约并写入失败测试**

```go
type HistoryPageRequest struct {
    Limit  int
    Cursor *HistoryCursor
}

type HistoryCursor struct {
    FinishedAt time.Time
    MatchID    string
}

type HistoryStatistics struct {
    ValidMatches int64
    Wins         int64
    Losses       int64
    Draws        int64
    WinRate      float64
}

type HistoryEntry struct {
    ID               string
    Outcome          string
    OpponentNickname string
    Color            Color
    FinishedAt       time.Time
    MoveCount        int64
}

type HistoryPage struct {
    Statistics HistoryStatistics
    Matches    []HistoryEntry
    NextCursor *HistoryCursor
}

func HistoryFailureMetadata(err error) (phase string, category string, ok bool)
```

table-driven 测试插入五子连线、认输、和棋、作废、零手取消和活跃对局，分别从双方用户视角断言 `win/loss/draw/abandoned`。

- [ ] **Step 2: 运行新服务测试并确认 RED**

```bash
(cd server && go test ./internal/matches -run 'TestListHistory' -count=1)
```

Expected: FAIL with `undefined: HistoryPageRequest` 或 `service.ListHistory undefined`。

- [ ] **Step 3: 实现输入校验和只读事务外壳**

```go
func (service *Service) ListHistory(ctx context.Context, gameID, userID string, request HistoryPageRequest) (_ HistoryPage, err error) {
    if !service.configured() {
        return HistoryPage{}, ErrInvalidConfiguration
    }
    if ctx == nil || gameID != gomoku.GameID || !canonicalUUID(userID) ||
        request.Limit < 1 || request.Limit > 50 || !validHistoryCursor(request.Cursor) {
        return HistoryPage{}, ErrInvalidRequest
    }
    transaction, beginErr := service.db.BeginTx(ctx, &sql.TxOptions{ReadOnly: true})
    if beginErr != nil {
        return HistoryPage{}, newHistoryFailure(
            "begin", historyDatabaseCategory(ctx, beginErr), matchDatabaseError(ctx, beginErr),
        )
    }
    defer rollbackReadTransaction(ctx, transaction, &err)
    statistics, statisticsErr := readHistoryStatistics(ctx, transaction, gameID, userID)
    if statisticsErr != nil {
        return HistoryPage{}, statisticsErr
    }
    entries, next, entriesErr := readHistoryEntries(ctx, transaction, gameID, userID, request)
    if entriesErr != nil {
        return HistoryPage{}, entriesErr
    }
    if commitErr := transaction.Commit(); commitErr != nil {
        return HistoryPage{}, newHistoryFailure(
            "commit", historyDatabaseCategory(ctx, commitErr), matchDatabaseError(ctx, commitErr),
        )
    }
    return HistoryPage{Statistics: statistics, Matches: entries, NextCursor: next}, nil
}
```

`history.go` 同时定义 `readHistoryStatistics(ctx context.Context, transaction *sql.Tx, gameID, userID string) (HistoryStatistics, error)`、`readHistoryEntries(ctx context.Context, transaction *sql.Tx, gameID, userID string, request HistoryPageRequest) ([]HistoryEntry, *HistoryCursor, error)`、`newHistoryFailure(phase, category string, err error) error`、`historyDatabaseCategory(ctx context.Context, err error) string` 和 `rollbackReadTransaction(ctx context.Context, transaction *sql.Tx, err *error)`。`validHistoryCursor` 要求 UTC 毫秒可往返转换、规范非零 UUID 和非零时间。

内部错误使用一个可 `Unwrap()` 的非导出 wrapper 携带固定元数据：phase 只能是 `begin`/`statistics`/`entries`/`commit`/`rollback`，category 只能是 `database`/`data_integrity`/`cancelled`。`HistoryFailureMetadata` 只返回这两个枚举字符串，不返回 SQL、用户 ID、昵称、游标或底层错误文本。

```go
func rollbackReadTransaction(ctx context.Context, transaction *sql.Tx, target *error) {
    rollbackErr := transaction.Rollback()
    if rollbackErr != nil && !errors.Is(rollbackErr, sql.ErrTxDone) && *target == nil {
        *target = newHistoryFailure(
            "rollback", historyDatabaseCategory(ctx, rollbackErr), matchDatabaseError(ctx, rollbackErr),
        )
    }
}
```

- [ ] **Step 4: 实现统计与列表查询**

统计 SQL 必须同时返回 invalid row count，只接受以下组合：

```sql
status='finished' AND result IN ('five','resignation')
  AND winner_user_id IN (SELECT user_id FROM match_players WHERE match_id=matches.id)
status='finished' AND result='draw' AND winner_user_id IS NULL
status='abandoned' AND result IS NULL AND winner_user_id IS NULL
```

聚合前先在同一事务内确认当前用户存在且 `enabled=1`，否则返回 `ErrInvalidRequest`。计算固定为 `valid = wins + losses + draws`；`valid == 0` 时 `WinRate=0`，否则 `WinRate=float64(wins)/float64(valid)`。

列表查询以 `match_players AS current_player` 的 `user_id=?` 为入口，`LEFT JOIN` 唯一对手和 `users`，返回 `LIMIT request.Limit+1`，并使用：

```sql
ORDER BY matches.finished_at DESC, matches.id DESC
```

有游标时增加：

```sql
AND (matches.finished_at < ? OR (matches.finished_at = ? AND matches.id < ?))
```

每行验证 match ID、当前颜色、两名不同成员、对手存在且昵称合法、终局字段一致；`moveCount` 使用：

```sql
SELECT COUNT(*) FROM match_events
WHERE match_id=matches.id AND event_type='gomoku.move.accepted'
```

第 `Limit+1` 行只用来判定更多数据，`NextCursor` 来自实际返回的最后一行。

- [ ] **Step 5: 补齐分页、损坏数据、取消与计划测试**

`TestListHistoryUsesStableFinishedAtAndIDCursor` 创建三条相同 `finished_at` 和一条更旧记录，以 limit 2 连续请求两页，断言四个 ID 各出现一次且顺序严格下降。`TestListHistoryCountsOnlyAcceptedMoves` 在两次 accepted move 后追加认输事件，断言 `MoveCount == 2`。`TestListHistoryRejectsInvalidRequestAndCorruptTerminalRows` 表驱动断言 limit 0/51、非规范游标、未知 result、对局外 winner、缺少对手和非法颜色都返回精确错误。

`TestListHistoryQueryPlan` 用 `EXPLAIN QUERY PLAN` 断言成员入口使用 `idx_match_players_user_id_match_id`。只有实际计划证明需要时才新增 `matches` 复合索引和对应 003 迁移。

- [ ] **Step 6: 运行包测试并提交**

```bash
(cd server && go test ./internal/matches ./internal/store -count=1)
git add server/internal/matches/history.go server/internal/matches/history_test.go
git commit -m "feat: query personal match history"
```

### Task 3: 暴露严格的战绩 HTTP API

**Files:**
- Create: `server/internal/httpapi/history_handlers.go`
- Create: `server/internal/httpapi/history_handlers_test.go`
- Modify: `server/internal/httpapi/router.go`

**Interfaces:**
- Consumes: `matches.ListHistory`、`matches.HistoryPageRequest`、`matches.HistoryCursor`。
- Produces: `GET /v1/games/gomoku/history`、`decodeHistoryCursor`、`encodeHistoryCursor`、`requestIDFromContext(context.Context) string`，JSON 字段与 spec 完全一致。

- [ ] **Step 1: 先写游标 codec 和 HTTP 失败测试**

```go
type historyCursorPayload struct {
    Version    int    `json:"v"`
    FinishedAt int64  `json:"finishedAt"`
    MatchID    string `json:"matchId"`
}
```

测试覆盖：无 padding base64url 往返、错误 alphabet/padding、非 JSON、尾随 JSON、缺失/额外/重复字段、非版本 1、非法毫秒与非规范 UUID。HTTP 测试覆盖默认 20、合法 1/50、越界 limit、未知/重复参数、无效 token 精确映射 `401 unauthorized`、参数/游标错误精确映射 `400 invalid_request`、内部数据错误精确映射 `500 internal_error`、身份隔离、成功响应和 method fallback。内部失败测试还断言日志含 request ID、`feature=match_history`、固定 phase/category，且不含 Authorization、用户 ID、昵称或完整 cursor。

- [ ] **Step 2: 运行 HTTP 测试并确认 RED**

```bash
(cd server && go test ./internal/httpapi -run 'TestHistoryCursor|TestGomokuHistory' -count=1)
```

Expected: FAIL，原因是 codec、handler 或路由尚不存在。

- [ ] **Step 3: 实现严格查询参数与游标 codec**

```go
func parseHistoryQuery(rawQuery string) (matches.HistoryPageRequest, error) {
    values, err := url.ParseQuery(rawQuery)
    if err != nil {
        return matches.HistoryPageRequest{}, matches.ErrInvalidRequest
    }
    for key, entries := range values {
        if (key != "cursor" && key != "limit") || len(entries) != 1 {
            return matches.HistoryPageRequest{}, matches.ErrInvalidRequest
        }
    }
    request := matches.HistoryPageRequest{Limit: 20}
    if entries := values["limit"]; len(entries) == 1 {
        limit, parseErr := strconv.Atoi(entries[0])
        if parseErr != nil || limit < 1 || limit > 50 {
            return matches.HistoryPageRequest{}, matches.ErrInvalidRequest
        }
        request.Limit = limit
    }
    if entries := values["cursor"]; len(entries) == 1 {
        cursor, decodeErr := decodeHistoryCursor(entries[0])
        if decodeErr != nil {
            return matches.HistoryPageRequest{}, matches.ErrInvalidRequest
        }
        request.Cursor = &cursor
    }
    return request, nil
}
```

解码先用 `json.Decoder.Token()` 遍历单一对象，以 `map[string]bool` 拒绝重复键，且只接受 `v`/`finishedAt`/`matchId` 各一次；再检查 EOF 和 payload 重新编码的 canonical base64url 结果等于原值。`decodeHistoryCursor(value string) (matches.HistoryCursor, error)` 是 `parseHistoryQuery` 使用的唯一解码入口，`encodeHistoryCursor(cursor matches.HistoryCursor) (string, error)` 是 handler 使用的唯一编码入口。

- [ ] **Step 4: 实现 handler 和路由**

```go
mux.Handle("GET /v1/games/gomoku/history", router.authenticated(http.HandlerFunc(router.gomokuHistory)))
registerMethodFallback(mux, "/v1/games/gomoku/history", http.MethodGet)
```

handler 只使用 `authenticatedUser(request).ID`，调用 `ListHistory`，将 `FinishedAt.UTC().UnixMilli()` 写入 `finishedAt`，并将最后游标编码为 `nextCursor`。返回列表为空时必须是 `[]` 而不是 `null`。

```go
type historyStatisticsResponse struct {
    ValidMatches int64   `json:"validMatches"`
    Wins         int64   `json:"wins"`
    Losses       int64   `json:"losses"`
    Draws        int64   `json:"draws"`
    WinRate      float64 `json:"winRate"`
}

type historyMatchResponse struct {
    ID               string `json:"id"`
    Outcome          string `json:"outcome"`
    OpponentNickname string `json:"opponentNickname"`
    Color            string `json:"color"`
    FinishedAt       int64  `json:"finishedAt"`
    MoveCount        int64  `json:"moveCount"`
}

type historyResponse struct {
    Statistics historyStatisticsResponse `json:"statistics"`
    Matches    []historyMatchResponse     `json:"matches"`
    NextCursor *string                    `json:"nextCursor"`
}
```

`router` 保存 `config.Logger`，request middleware 把新生成的 request ID 放入请求 context。当 `ListHistory` 返回带 metadata 的内部错误时，handler 只写入：

```go
router.logger.Printf(
    "request_id=%s feature=match_history phase=%s category=%s",
    requestIDFromContext(request.Context()), phase, category,
)
```

HTTP 响应仍是通用 `internal_error`，不把诊断 metadata 暴露给客户端。

- [ ] **Step 5: 重跑服务端契约并提交**

```bash
(cd server && go test ./internal/httpapi ./internal/matches ./internal/store -count=1)
git add server/internal/httpapi/history_handlers.go server/internal/httpapi/history_handlers_test.go server/internal/httpapi/router.go
git commit -m "feat: expose match history API"
```

### Task 4: 实现 Flutter 战绩模型与 API

**Files:**
- Create: `app/lib/features/history/match_history_models.dart`
- Create: `app/lib/features/history/match_history_api.dart`
- Create: `app/test/features/history/match_history_models_test.dart`
- Create: `app/test/features/history/match_history_api_test.dart`

**Interfaces:**
- Consumes: `ApiClient`、`SessionController`、`hasExactJsonKeys`、`isCanonicalGameboxUuid`。
- Produces: `MatchOutcome`、`MatchHistoryStatistics`、`MatchHistoryEntry`、`MatchHistoryPageData`、`MatchHistoryApi`、`HttpMatchHistoryApi`。

- [ ] **Step 1: 先写严格 JSON 模型失败测试**

```dart
enum MatchOutcome { win, loss, draw, abandoned }

final class MatchHistoryPageData {
  const MatchHistoryPageData({
    required this.statistics,
    required this.matches,
    required this.nextCursor,
  });
  factory MatchHistoryPageData.fromEnvelope(Map<String, Object?> envelope);
}
```

合法 fixture 包含四种 outcome、黑/白、UTC 毫秒、非负手数和 nullable cursor。非法表覆盖每层额外/缺失键、非法 UUID/昵称/颜色/outcome、负数计数、非有限或越界胜率、溢出时间和重复 match ID。

- [ ] **Step 2: 运行模型测试并确认 RED**

```bash
(cd app && flutter test test/features/history/match_history_models_test.dart)
```

Expected: FAIL with missing import/file or undefined model types.

- [ ] **Step 3: 实现严格不可变模型**

```dart
final class MatchHistoryEntry {
  const MatchHistoryEntry({
    required this.id,
    required this.outcome,
    required this.opponentNickname,
    required this.color,
    required this.finishedAt,
    required this.moveCount,
  });
  final String id;
  final MatchOutcome outcome;
  final String opponentNickname;
  final GomokuColor color;
  final DateTime finishedAt;
  final int moveCount;
}
```

`matches` 使用 `List.unmodifiable`；时间使用 `DateTime.fromMillisecondsSinceEpoch(value, isUtc: true)`；根对象、统计和行对象均使用 `hasExactJsonKeys`。

- [ ] **Step 4: 先写 API 请求与错误归一失败测试**

```dart
abstract interface class MatchHistoryApi {
  Future<MatchHistoryPageData> fetchPage({String? cursor, int limit = 20});
}
```

断言首页 URL 是 `/v1/games/gomoku/history?limit=20`，翻页 cursor 经 query encoding 后与原值完全往返，Authorization 和 `onUnauthorized: session.refresh` 沿用现有逻辑，非法响应转换为 `ApiError(code: 'invalid_response')`。

- [ ] **Step 5: 实现 API 并运行两个测试文件**

```dart
final query = Uri(
  path: '/v1/games/gomoku/history',
  queryParameters: {
    'limit': '$limit',
    if (cursor != null) 'cursor': cursor,
  },
).toString();
final envelope = await _client.getJson(
  query,
  accessToken: () => _session.accessToken,
  onUnauthorized: _session.refresh,
);
```

```bash
(cd app && flutter test test/features/history/match_history_models_test.dart test/features/history/match_history_api_test.dart)
git add app/lib/features/history/match_history_models.dart app/lib/features/history/match_history_api.dart app/test/features/history/match_history_models_test.dart app/test/features/history/match_history_api_test.dart
git commit -m "feat: add match history data client"
```

### Task 5: 实现可恢复的战绩 Controller

**Files:**
- Create: `app/lib/features/history/match_history_controller.dart`
- Create: `app/test/features/history/match_history_controller_test.dart`

**Interfaces:**
- Consumes: `MatchHistoryApi.fetchPage`、`MatchHistoryPageData`、`ApiError`。
- Produces: 页面可监听的首次加载、有数据、首次错误、加载更多与底部错误状态。

- [ ] **Step 1: 写入 controller 状态机失败测试**

逐项断言：

```dart
expect(controller.isInitialLoading, isTrue);
await controller.load();
expect(controller.statistics, page.statistics);
expect(controller.matches, page.matches);
expect(controller.hasMore, isTrue);
```

其余测试覆盖首次失败与 `retry()`、空页、`loadMore()` 追加去重、统计替换、同一游标并发抑制、底部失败保留数据、底部重试、`nextCursor=null` 停止请求和 `dispose()` 后迟到 Future 不通知。

- [ ] **Step 2: 运行 controller 测试并确认 RED**

```bash
(cd app && flutter test test/features/history/match_history_controller_test.dart)
```

Expected: FAIL with missing controller file/type.

- [ ] **Step 3: 实现最小状态机**

```dart
Future<void> loadMore() async {
  final cursor = _nextCursor;
  if (_disposed || _isInitialLoading || _isLoadingMore || cursor == null) return;
  _isLoadingMore = true;
  _loadMoreError = null;
  notifyListeners();
  try {
    final page = await _api.fetchPage(cursor: cursor);
    if (_disposed) return;
    final seen = _matches.map((entry) => entry.id).toSet();
    _matches = List.unmodifiable([
      ..._matches,
      ...page.matches.where((entry) => seen.add(entry.id)),
    ]);
    _statistics = page.statistics;
    _nextCursor = page.nextCursor;
  } on ApiError catch (error) {
    if (!_disposed) _loadMoreError = error;
  } finally {
    if (!_disposed) {
      _isLoadingMore = false;
      notifyListeners();
    }
  }
}
```

`load()` 在既无数据也无进行中请求时请求首页；`retry()` 清除首次错误后重用该路径。对非 `ApiError` 不吞掉编程错误。

- [ ] **Step 4: 运行测试并提交**

```bash
(cd app && flutter test test/features/history/match_history_controller_test.dart)
git add app/lib/features/history/match_history_controller.dart app/test/features/history/match_history_controller_test.dart
git commit -m "feat: manage paginated match history"
```

### Task 6: 构建 Material 3 战绩页并接入首页

**Files:**
- Create: `app/lib/features/history/match_history_page.dart`
- Create: `app/test/features/history/match_history_page_test.dart`
- Modify: `app/lib/features/home/home_page.dart`
- Modify: `app/lib/app.dart`
- Modify: `app/test/features/home/home_page_test.dart`
- Modify: `app/test/app_home_test.dart`
- Modify: `app/test/app_test.dart`

**Interfaces:**
- Consumes: `MatchHistoryController`、`MatchHistoryApi`、`GameboxPageBody`、`GameboxAsyncPanel`、现有 Material 3 tokens。
- Produces: `MatchHistoryPage`、`open-match-history` 首页入口和可由 `GameboxApp` 注入的 history API。

- [ ] **Step 1: 先写战绩页所有状态的 Widget 失败测试**

稳定标识固定为：

```text
match-history-page
match-history-back
match-history-loading
match-history-error
retry-match-history
match-history-statistics
match-history-empty
match-history-list
match-history-entry-<match-id>
match-history-load-more
retry-match-history-more
```

断言初始加载、空、首次错误/重试、四种结果、黑白方、本地时间、手数、底部加载/错误、自动触发翻页、记录无 tap action、亮/暗主题和 320dp 宽度长昵称无 overflow。

- [ ] **Step 2: 写入首页入口与返回失败测试**

```dart
expect(find.bySemanticsIdentifier('open-match-history'), findsOneWidget);
expect(find.descendant(
  of: find.byKey(const Key('open-match-history')),
  matching: find.byType(OutlinedButton),
), findsOneWidget);
await tester.tap(find.byKey(const Key('open-match-history')));
await tester.pumpAndSettle();
expect(find.byKey(const Key('match-history-page')), findsOneWidget);
```

先点击 `match-history-back`，再用新的 fixture 执行 `tester.pageBack()`，两者都必须返回原 `home-shell` 且 HomeController 不重建。

- [ ] **Step 3: 运行新 Widget 测试并确认 RED**

```bash
(cd app && flutter test test/features/history/match_history_page_test.dart test/features/home/home_page_test.dart)
```

Expected: FAIL with missing page and missing `open-match-history`.

- [ ] **Step 4: 实现战绩页状态树**

```dart
return Semantics(
  key: const Key('match-history-page'),
  identifier: 'match-history-page',
  container: true,
  child: Scaffold(
    appBar: AppBar(
      leading: Semantics(
        key: const Key('match-history-back'),
        identifier: 'match-history-back',
        child: BackButton(onPressed: () => Navigator.of(context).pop()),
      ),
      title: const Text('我的战绩'),
    ),
    body: NotificationListener<ScrollNotification>(
      onNotification: _onScroll,
      child: GameboxPageBody(children: _children(context)),
    ),
  ),
);
```

page state 在 `initState` 中注册 controller listener 并调用 `unawaited(controller.load())`，在 `dispose` 中移除 listener 后销毁该页面独享 controller。`_onScroll` 在 `metrics.extentAfter <= GameboxTokens.spacing.large` 时使用 `unawaited(controller.loadMore())`，始终返回 `false`。初始加载和错误使用 `GameboxAsyncPanel`；统计使用带 `match-history-statistics` Key/identifier 的 `Semantics + Card + Wrap`；记录使用带 `match-history-entry-<match-id>` Key/identifier 的非交互 `Semantics + Card/ListTile`，结果 Chip 颜色只从 `Theme.of(context).colorScheme` 语义角色取值。首版不包含 `RefreshIndicator` 或其他下拉刷新入口。

时间文案使用：

```dart
final local = entry.finishedAt.toLocal();
final material = MaterialLocalizations.of(context);
final finished = '${material.formatShortDate(local)} '
    '${material.formatTimeOfDay(TimeOfDay.fromDateTime(local), alwaysUse24HourFormat: true)}';
```

- [ ] **Step 5: 实现首页入口和生产注入**

`HomePage` 新增必需参数 `MatchHistoryApi historyApi`，点击时创建页面独享 controller：

```dart
Future<void> _openHistory() => Navigator.of(context).push<void>(
  MaterialPageRoute<void>(
    builder: (_) => MatchHistoryPage(
      controller: MatchHistoryController(api: widget.historyApi),
    ),
  ),
);
```

用户信息卡中的入口使用 `OutlinedButton.icon`，`Key` 和 `Semantics.identifier` 均为 `open-match-history`。`GameboxApp` 新增可选 `MatchHistoryApi? matchHistoryApi` 仅供测试注入，生产路径先使用 `final apiClient = _ownedApiClient ??= ApiClient(httpClient: http.Client())`，再创建 `HttpMatchHistoryApi(apiClient, sessionController)`，不向非 nullable 构造器传递空值。

- [ ] **Step 6: 运行 Flutter feature 回归并提交**

```bash
(cd app && flutter test test/features/history test/features/home/home_page_test.dart test/app_home_test.dart test/app_test.dart)
git add app/lib/features/history/match_history_page.dart app/test/features/history/match_history_page_test.dart app/lib/features/home/home_page.dart app/lib/app.dart app/test/features/home/home_page_test.dart app/test/app_home_test.dart app/test/app_test.dart
git commit -m "feat: add personal match history page"
```

### Task 7: 补充稳定语义契约和双 AVD 读链路

**Files:**
- Modify: `app/integration_test/semantics_test.dart`
- Modify: `tool/e2e_android.sh`

**Interfaces:**
- Consumes: `open-match-history`、`match-history-page`、`match-history-statistics`、`match-history-entry-<id>`、`match-history-back`。
- Produces: fixture 语义测试与真实服务/双 Android 设备逻辑证据；不产生截图。

- [ ] **Step 1: 先写 integration semantics 失败测试**

`_Fixture` 注入 `_FakeMatchHistoryApi`，新测试执行：

```dart
await tester.tap(find.bySemanticsIdentifier('open-match-history'));
await _flush(tester);
expect(find.bySemanticsIdentifier('match-history-statistics'), findsOneWidget);
expect(find.bySemanticsIdentifier('match-history-entry-$_matchId'), findsOneWidget);
await tester.tap(find.bySemanticsIdentifier('match-history-back'));
await _flush(tester);
expect(find.bySemanticsIdentifier('game-gomoku'), findsOneWidget);
```

- [ ] **Step 2: 运行 integration test 并确认 RED**

```bash
(cd app && flutter test integration_test/semantics_test.dart)
```

Expected: FAIL until fixture 注入与战绩 semantics 完整。

- [ ] **Step 3: 完成 semantics fixture 并修改固定 E2E**

在现有认输对局结束且两台 App 返回空闲首页后，A 设备执行：

```bash
tap_identifier "$SERIAL_A" open-match-history
wait_for_identifier "$SERIAL_A" match-history-statistics >/dev/null \
  || fail "A history statistics did not load"
wait_for_identifier "$SERIAL_A" "match-history-entry-$THIRD_MATCH_ID" >/dev/null \
  || fail "A history did not include the authoritative resignation match"
tap_identifier "$SERIAL_A" match-history-back
wait_for_identifier "$SERIAL_A" choose-opponent >/dev/null \
  || fail "visible history Back did not return A to the idle lobby"

tap_identifier "$SERIAL_A" open-match-history
wait_for_identifier "$SERIAL_A" match-history-page >/dev/null \
  || fail "A history page did not reopen"
adb_for "$SERIAL_A" shell input keyevent KEYCODE_BACK >/dev/null \
  || fail "could not send Android Back from history"
wait_for_identifier "$SERIAL_A" choose-opponent >/dev/null \
  || fail "Android Back did not return A to the idle lobby"
```

脚本不引入 `screencap`、PNG、像素比对或截图目录。

- [ ] **Step 4: 运行稳定契约与 shell 门禁并提交**

```bash
(cd app && flutter test integration_test/semantics_test.dart)
bash -n tool/e2e_android.sh
! rg -n 'screencap|screenshots/|\.png|SSIM' tool/e2e_android.sh
git add app/integration_test/semantics_test.dart tool/e2e_android.sh
git commit -m "test: cover match history Android flow"
```

### Task 8: 完整验证与真实 Android 视觉验收

**Files:**
- Evidence only, ignored: `artifacts/f4-android/*.png`
- Modify only if an observed defect requires it: the exact source/test files from Tasks 1–7

**Interfaces:**
- Consumes: 所有实现提交和仓库 Android lease/E2E 契约。
- Produces: 全门禁证据、双 AVD 逻辑证据、已亲眼检查的真实 App 截图与最终 UX verdict。

- [ ] **Step 1: 确认工具链和工作区基线**

```bash
if [[ -n "${GAMEBOX_FLUTTER_SDK_ROOT:-}" ]]; then
  export PATH="$GAMEBOX_FLUTTER_SDK_ROOT/bin:$PATH"
fi
flutter --version
dart --version
go version
command -v sqlite3
git status --short
adb -s "$VISUAL_SERIAL" shell wm size
adb -s "$VISUAL_SERIAL" shell wm density
```

Expected: Flutter 3.47.1、Dart 3.13.1、Go 1.25.0；工作区无非本任务意外改动。`VISUAL_SERIAL` 必须选择现有双 AVD 中逻辑宽度不大于 360dp 的竖屏手机；如果当前设备不符合，选择另一台已由仓库准备的 AVD，不临时覆盖共享设备的分辨率或密度。

- [ ] **Step 2: 运行快速门禁和完整门禁**

```bash
bash tool/verify_fast.sh
bash tool/verify.sh
```

Expected: 两个命令 exit 0，Go、Flutter、设计系统、Godot、脚本和部署检查全部通过。

- [ ] **Step 3: 运行双 AVD 真实逻辑验收**

```bash
bash tool/e2e_android.sh
```

Expected: exit 0，认输对局出现在当前用户战绩中，可见返回与 Android 系统返回都回到空闲首页，且 E2E artifact 中没有图片。

- [ ] **Step 4: 准备独立视觉验收状态**

使用与 E2E 相同源码构建产物和一个独立的忽略 SQLite 数据库：

```bash
umask 077
mkdir -p artifacts/f4-android
VISUAL_TEMP="$(mktemp -d)"
VISUAL_DB="$PWD/artifacts/f4-android/visual.sqlite"
VISUAL_PORT=18081
VISUAL_JWT="$(openssl rand -hex 32)"
VISUAL_PEPPER="$(openssl rand -hex 32)"
VISUAL_ORIGINAL_UI_MODE="$(adb -s "$VISUAL_SERIAL" shell cmd uimode night)"
(cd server && go build -o "$VISUAL_TEMP/gameboxd" ./cmd/gameboxd)
(cd server && go build -o "$VISUAL_TEMP/gameboxctl" ./cmd/gameboxctl)
GAMEBOX_ADDR="0.0.0.0:$VISUAL_PORT" \
GAMEBOX_DB_PATH="$VISUAL_DB" \
GAMEBOX_JWT_SECRET="$VISUAL_JWT" \
GAMEBOX_TOKEN_PEPPER="$VISUAL_PEPPER" \
  "$VISUAL_TEMP/gameboxd" >"$VISUAL_TEMP/server.log" 2>&1 &
VISUAL_SERVER_PID=$!
until curl --fail --silent "http://127.0.0.1:$VISUAL_PORT/healthz" >/dev/null; do sleep 0.2; done
VISUAL_INVITES="$(GAMEBOX_TOKEN_PEPPER="$VISUAL_PEPPER" \
  "$VISUAL_TEMP/gameboxctl" invite create --count 2 --db "$VISUAL_DB" --json)"
VISUAL_INVITE_A="$(jq -er '.invites[0]' <<<"$VISUAL_INVITES")"
VISUAL_INVITE_B="$(jq -er '.invites[1]' <<<"$VISUAL_INVITES")"
(cd app && flutter build apk --debug \
  --dart-define="GAMEBOX_API_BASE_URL=http://10.0.2.2:$VISUAL_PORT")
adb -s "$VISUAL_SERIAL" install -r app/build/app/outputs/flutter-apk/app-debug.apk
adb -s "$VISUAL_SERIAL" shell pm clear me.zqydev.gamebox
adb -s "$VISUAL_SERIAL" shell monkey -p me.zqydev.gamebox 1
```

在真实 App 注册页通过 `invite-code`/`nickname`/`register` 标识输入 `VISUAL_INVITE_A`、`测试棋手A` 并提交；此时不截图。待 `open-match-history` 出现后，在不输出响应内容的情况下注册第二个用户：

```bash
jq -n --arg invite "$VISUAL_INVITE_B" --arg nickname '测试棋手B' \
  '{inviteCode:$invite,nickname:$nickname}' >"$VISUAL_TEMP/register-b.json"
curl --fail --silent --show-error \
  -H 'Content-Type: application/json' \
  --data-binary "@$VISUAL_TEMP/register-b.json" \
  "http://127.0.0.1:$VISUAL_PORT/v1/auth/register" \
  >"$VISUAL_TEMP/session-b.json"
VISUAL_USER_A="$(sqlite3 "$VISUAL_DB" \
  "SELECT id FROM users WHERE normalized_nickname='测试棋手a'")"
VISUAL_USER_B="$(jq -er '.session.user.id' "$VISUAL_TEMP/session-b.json")"
[[ "$VISUAL_USER_A" =~ ^[0-9a-f-]{36}$ && "$VISUAL_USER_B" =~ ^[0-9a-f-]{36}$ ]]
kill -TERM "$VISUAL_SERVER_PID"
wait "$VISUAL_SERVER_PID"
```

服务停止后只在该忽略视觉库中写入四条确定性终局记录；它们分别让 A 显示胜、负、和与作废，手数为 3/4/5/0：

```bash
VISUAL_FINISHED_AT="$(($(date +%s) * 1000))"
sqlite3 "$VISUAL_DB" <<SQL
INSERT INTO matches(id,game_id,status,revision,result,winner_user_id,created_at,updated_at,finished_at) VALUES
('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1','gomoku','finished',3,'five','$VISUAL_USER_A',$((VISUAL_FINISHED_AT-40000)),$((VISUAL_FINISHED_AT-40000)),$((VISUAL_FINISHED_AT-40000))),
('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa2','gomoku','finished',4,'five','$VISUAL_USER_B',$((VISUAL_FINISHED_AT-30000)),$((VISUAL_FINISHED_AT-30000)),$((VISUAL_FINISHED_AT-30000))),
('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa3','gomoku','finished',5,'draw',NULL,$((VISUAL_FINISHED_AT-20000)),$((VISUAL_FINISHED_AT-20000)),$((VISUAL_FINISHED_AT-20000))),
('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa4','gomoku','abandoned',1,NULL,NULL,$((VISUAL_FINISHED_AT-10000)),$((VISUAL_FINISHED_AT-10000)),$((VISUAL_FINISHED_AT-10000)));
INSERT INTO match_players(match_id,user_id,seat,color) VALUES
('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1','$VISUAL_USER_A',0,'black'),('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1','$VISUAL_USER_B',1,'white'),
('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa2','$VISUAL_USER_A',0,'white'),('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa2','$VISUAL_USER_B',1,'black'),
('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa3','$VISUAL_USER_A',0,'black'),('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa3','$VISUAL_USER_B',1,'white'),
('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa4','$VISUAL_USER_A',0,'white'),('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa4','$VISUAL_USER_B',1,'black');
WITH RECURSIVE moves(match_id,max_revision,revision) AS (
  VALUES ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1',3,1),
         ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa2',4,1),
         ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa3',5,1)
  UNION ALL SELECT match_id,max_revision,revision+1 FROM moves WHERE revision<max_revision
)
INSERT INTO match_events(match_id,revision,event_type,action_id,actor_user_id,payload_json,created_at)
SELECT match_id,revision,'gomoku.move.accepted',NULL,
       CASE WHEN revision%2=1 THEN '$VISUAL_USER_A' ELSE '$VISUAL_USER_B' END,
       '{}',$VISUAL_FINISHED_AT FROM moves;
INSERT INTO match_events(match_id,revision,event_type,action_id,actor_user_id,payload_json,created_at)
VALUES ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa4',1,'platform.match.abandoned',NULL,NULL,'{}',$VISUAL_FINISHED_AT);
PRAGMA quick_check;
PRAGMA foreign_key_check;
SQL
```

检查输出必须只有 `ok` 且无 foreign-key 行，然后使用原密钥重启真实服务：

```bash
GAMEBOX_ADDR="0.0.0.0:$VISUAL_PORT" \
GAMEBOX_DB_PATH="$VISUAL_DB" \
GAMEBOX_JWT_SECRET="$VISUAL_JWT" \
GAMEBOX_TOKEN_PEPPER="$VISUAL_PEPPER" \
  "$VISUAL_TEMP/gameboxd" >"$VISUAL_TEMP/server.log" 2>&1 &
VISUAL_SERVER_PID=$!
until curl --fail --silent "http://127.0.0.1:$VISUAL_PORT/healthz" >/dev/null; do sleep 0.2; done
```

在截图前用 UI Automator 或 Android 控制工具确认首页存在 `open-match-history`，但此时不点击；这是首页截图的起始状态。点击后必须等到 `match-history-statistics` 再截取战绩页。

```bash
adb -s "$VISUAL_SERIAL" shell uiautomator dump --compressed /sdcard/f4-home.xml
adb -s "$VISUAL_SERIAL" pull /sdcard/f4-home.xml artifacts/f4-android/home.xml
rg -F 'resource-id="open-match-history"' artifacts/f4-android/home.xml
```

若准备状态时发现 API 或数据语义错误，先为该错误增加 RED 测试，然后修复并重跑 Steps 2–3；不用截图数据绕过产品逻辑。

- [ ] **Step 5: 在实际构建 App 中截取三个最小证据状态**

```bash
adb -s "$VISUAL_SERIAL" shell screencap -p /sdcard/f4-home-light.png
adb -s "$VISUAL_SERIAL" pull /sdcard/f4-home-light.png artifacts/f4-android/home-light.png
```

使用 Android 控制工具点击 `open-match-history`，等待 `match-history-statistics` 出现，再执行：

```bash
adb -s "$VISUAL_SERIAL" shell screencap -p /sdcard/f4-history-light.png
adb -s "$VISUAL_SERIAL" pull /sdcard/f4-history-light.png artifacts/f4-android/history-light.png
adb -s "$VISUAL_SERIAL" shell cmd uimode night yes
adb -s "$VISUAL_SERIAL" shell am force-stop me.zqydev.gamebox
adb -s "$VISUAL_SERIAL" shell monkey -p me.zqydev.gamebox 1
```

暗色重启后使用同一 Android 控制工具重新点击 `open-match-history`，等待 `match-history-statistics` 出现，再执行：

```bash
adb -s "$VISUAL_SERIAL" shell screencap -p /sdcard/f4-history-dark.png
adb -s "$VISUAL_SERIAL" pull /sdcard/f4-history-dark.png artifacts/f4-android/history-dark.png
```

截图不包含 token、邀请码、内部 URL 或真实用户资料。

- [ ] **Step 6: 亲眼检查截图并输出固定 UX 审计结构**

对三张 PNG 使用图像查看工具，检查安全区、文字裁切、48dp 目标、结果非纯颜色表达、败局未使用 error 色、亮/暗对比与首页主次操作。最终报告按以下顺序：

该报告明确区分：Task 7 双 AVD 完成真实对局到战绩的逻辑读链路；Task 8 的四条确定性终局数据只用于让实际构建 App 稳定呈现四种视觉状态，不冒充外部生产数据证据。

```text
1. Scope and selected profile
2. MUST findings
3. SHOULD findings and recorded deviations
4. MAY decisions
5. Tests and target-runtime commands
6. Screenshot matrix
7. Verdict: complete | incomplete | blocked
```

- [ ] **Step 7: 确认提交和工作区，不提交截图**

```bash
kill -TERM "$VISUAL_SERVER_PID"
wait "$VISUAL_SERVER_PID"
adb -s "$VISUAL_SERIAL" shell pm clear me.zqydev.gamebox
adb -s "$VISUAL_SERIAL" shell rm -f \
  /sdcard/f4-home.xml \
  /sdcard/f4-home-light.png \
  /sdcard/f4-history-light.png \
  /sdcard/f4-history-dark.png
case "$VISUAL_ORIGINAL_UI_MODE" in
  *yes*) adb -s "$VISUAL_SERIAL" shell cmd uimode night yes ;;
  *no*) adb -s "$VISUAL_SERIAL" shell cmd uimode night no ;;
  *) adb -s "$VISUAL_SERIAL" shell cmd uimode night auto ;;
esac
case "$VISUAL_TEMP" in
  "${TMPDIR%/}/"*|/tmp/*|/private/tmp/*|/var/folders/*) ;;
  *) printf 'refusing to remove unexpected visual temp path\n' >&2; exit 1 ;;
esac
rm -rf -- "$VISUAL_TEMP"
git status --short
git log --oneline --decorate -10
git diff --check
```

Expected: 业务实现和测试均已在 Tasks 1–7 的窄提交中；`artifacts/` 保持忽略；工作区干净。

## Final Handoff Checklist

- [ ] API 契约与 spec JSON 字段完全一致。
- [ ] 身份隔离、游标校验和损坏数据失败关闭有自动化证据。
- [ ] 认输、和棋、作废、取消和总手数语义都有服务层证据。
- [ ] Flutter 加载、空、错误、有数据、加载更多和底部错误状态均有 Widget/controller 证据。
- [ ] 首页入口是带文字的次级操作，记录行不可点击，页面无回放和筛选。
- [ ] 固定 E2E 通过且未保留截图。
- [ ] 完整仓库门禁与双 AVD E2E 均 exit 0。
- [ ] 三张真实 Android 截图已实际检查并在最终响应中附上。
- [ ] 最终 verdict 只使用 `complete`、`incomplete` 或 `blocked`。
