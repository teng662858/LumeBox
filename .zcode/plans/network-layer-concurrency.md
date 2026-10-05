# Lume Box · 网络层：全局并发控制与防封禁（文档第六条）

来源：对照《聚合项目最终完整开发文档》第六部分「全局网络层防封禁 & 并发控制规范」
（文档里唯一被标「重点」的未实现项），也是「批量测试图源」「批量刷新订阅」的地基。

## 一、文档要求 → 落点

| 文档要求 | 实现 |
|---|---|
| 全局总并发 6~12（可配置） | `NetworkQueue` 全局额度 + `NetworkSettings.globalConcurrency`（默认 8，写入时收敛到 6~12） |
| 单域名独立并发 2~3（核心防封） | `NetworkQueue` 按 host 的独立额度 + `perHostConcurrency`（默认 2，收敛到 2~3） |
| 智能指数退避重试 429 / 503 / 网络波动 | 429 与 503 触发退避重试（`base * 2^n` + 0~25% 抖动）；网络异常同样重试；服务器给 `Retry-After` 就听它的（秒或 HTTP 日期，上限 30s） |
| 每个图源可独立配置代理、独立 UA | 库 schema v3 给 `source` 表加 `user_agent` / `cookie` / `proxy` 三列；图源管理页「更多 → 网络配置」编辑 |
| 单图源配置优先于全局设置 | `NetworkProfile.mergedWith(settings)`：覆盖项优先，缺项继承全局 |
| 请求来源在日志里区分 | `NetworkRequest.source` 标记（图源 id / 「订阅拉取」/「图片缓存」…），重试日志带来源 |
| 所有请求强制走统一队列 | `LumeHttp` 默认取 `LumeNet.queue`（应用级共享）；图片下载经同一队列；注入客户端时保留既有语义（测试替身） |
| 每个图源 Cookie 隔离 | Cookie 只来自图源自身配置，不参与「继承全局」——全局没有 Cookie 概念，图源之间不会串 |

## 二、为什么队列必须是应用级单例

文档要求「全局总并发 6~12」。若每个板块（或每个图源）各建一个队列，四板块同时跑就是
四倍并发，防封直接失效。因此队列由 `LumeNet` 唯一持有，所有 `LumeHttp` 都从它取额度；
设置变更时 `LumeNet.apply` 重建队列（在飞请求自然结束，新请求按新额度排队）。

额度获取用**条件变量**模式（拿不到就登记等待者、释放时唤醒全部重新检查），而不是
「先占全局再等域名」——后者会让一个大站把全局额度囤住，饿死其他域名。

## 三、改动清单

| 文件 | 作用 |
|---|---|
| `lib/core/net/network_settings.dart`（新） | `NetworkSettings`（全局，含 `clamped()` 收敛）、`NetworkProfile`（图源覆盖）、`NetworkSettingsStore`（JSON 落盘，原子写） |
| `lib/core/net/network_queue.dart`（新） | `NetworkQueue`（双层额度 + 退避重试）、`NetworkRequest` / `NetworkResponse` |
| `lib/core/net/lume_net.dart`（新） | 应用级单例：一份设置 + 一个队列；`boot()` 启动加载、`save()` 落盘并即时生效；`sendDirect` 按代理建客户端 |
| `lib/core/net/lume_http.dart` | 接入队列；UA / Cookie / 代理按「图源覆盖 → 全局 → 内置」决定；`source` 标记 |
| `lib/core/db/section_database.dart` | schema v3：`source` 表加 `user_agent` / `cookie` / `proxy`（迁移对「列已存在」容错） |
| `lib/core/db/source_record.dart` | `SourceRecord.network` |
| `lib/core/js/source_registry.dart` | `httpFor(sourceId)` 按图源造带覆盖的客户端并缓存；`setSourceNetwork`；`release` 一并释放客户端 |
| `lib/core/source/{data_source,source_manager,lume_sources}.dart` | `SourceDescriptor.network` / `hasNetworkOverride`；端口新增 `setNetwork` |
| `lib/core/reading/image_pipeline.dart` | 图片下载走全局队列（单域名并发保护图床） |
| `lib/features/settings/network_settings_page.dart`（新） | 全局网络设置页（并发 / 重试 / 超时 / UA / 代理） |
| `lib/features/settings/settings_page.dart` | 设置页新增「网络设置」入口 |
| `lib/features/source/source_section_page.dart` | 图源「更多 → 网络配置」编辑器；行内「网络已自定义」标记 |
| `lib/main.dart` | 启动时 `LumeNet.boot()` |

## 四、边界与未做

- **SOCKS 代理不支持**：如实降级为直连并记日志（不假装生效）。http / https 代理走
  `HttpClient.findProxy`，TLS 隧道与证书校验交给 dart:io。
- **重试只覆盖幂等方法**：POST 不重试（避免重复提交）；其余 4xx 不重试（地址错了、
  要鉴权，重试只是徒劳地多打目标站）。
- **未做**：按图源的可配置并发（文档只要求全局与单域名两级）、请求抓包预览面板
  （文档「调试日志规范」的增强项）、订阅来源 URL 落库（属「更新订阅源」任务）。
- 全局设置文件放在应用支持目录根部（不属任何板块）：它本来就对四板块同时生效，
  放板块内会与隔离口径矛盾。

## 五、测试

| 文件 | 覆盖 |
|---|---|
| `test/network_queue_test.dart`（新，21 例） | **单域名并发绝不超过上限**、不同域名可并行、全局上限跨域名生效、额度随请求结束归还；429/503 重试并在成功后返回、重试用尽如实返回、404 不重试、POST 不重试、网络异常重试与最终抛出；`Retry-After` 秒数与 HTTP 日期、超上限收敛；`hostOf` 解析；并发区间强制收敛；图源覆盖优先级与 Cookie 隔离；LumeHttp 接线（注入客户端语义、UA/代理解析顺序、共享队列排队） |
| `test/network_settings_test.dart`（新，9 例） | 全局设置：缺失回退、保存读回、越界收敛、文件损坏回退、JSON 往返；图源覆盖：写入读回、重命名/重新导入不清覆盖、清空即继承、旧库自动补列 |

验证：`flutter analyze` 零告警；全量 **509 例**通过。

## 六、下一步（本次未做）

1. **图源「测试连通性」**（单源 + 批量）：现在有了队列与退避，批量测试不会变成攻击；
2. **「更新订阅源」**：需要给 `source` 表加「订阅来源 URL」列，再用队列重新拉取；
3. 图源总管理的批量备份 / 恢复。
