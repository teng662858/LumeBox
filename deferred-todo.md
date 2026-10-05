# Lume Box 待办清单

## 已完成
- [✓] 移除卡片仪表盘首页，实现移动端底部悬浮Dock Tab导航，Windows侧边栏NavigationRail
- [✓] UI文字“自定义视频”改为“视频”，底层id、数据库、缓存不变
- [✓] 四大板块页面右上角统一增加+添加图源按钮；支持本地JS、远程订阅导入，归属当前板块
- [✓] JS导入预处理stripScriptBom，修复UTF‑8 BOM导致LumeSource元信息识别失败
- [✓] 四大板块右上角统一「图源管理」入口（打开本板块图源管理页）；播放器设置迁到设置Tab与播放控制栏齿轮
- [✓] QuickJS‑NG 宿主注入桥接全局 LumeSource（HTTP + 沙盒文件IO），函数式脚本（顶层 getList 等）可直接运行
- [✓] 视频板块首页改为当前图源的内容展示页（浏览/播放两页签），点条目直接起播
- [✓] 导入失败透传引擎真实原因（点名不支持的能力）并对「自建服务端程序」给定向说明；播放失败文案归一为一句人话
- [✓] 网络层：全局并发（6~12）与单域名并发（2~3）双层限制、429/503 指数退避重试、全局 UA/代理、单图源 UA/Cookie/代理覆盖（库 schema v3）
- [✓] 视频播放进度记忆（集数 + 时间点）与首页「继续观看」（续看 / 进度条 / 长按移除）
- [✓] 图源「测试连通性」（单源三态 + 批量，串行不轰炸）与「更新订阅源」（来源地址落库 schema v4、MD5 复校、批量刷新）
- [✓] 图源总管理批量备份 / 恢复（备份不含 Cookie；恢复走导入同款校验、按板块隔离）
- [✓] 缓存体系：按板块的容量上限与过期策略（LRU + 过期修剪，绝不碰用户保存的图片）
- [✓] 视频跨集自动连播（播完进下一集 + 开关；时长未知不跳）
- [✓] iOS 原生画中画控制器（AVPictureInPictureController + 内容源通道）
- [✓] 小说书签（按字符偏移）/ 章节内查找 / 自动翻页；漫画长按保存或复制图片地址
- [✓] 弹幕系统（解析 / 分层轨道渲染 / 设置面板 / 发弹幕；图源可选契约 DanmakuCapable）
- [✓] 追剧日历（播放记录 + 图源章节时间；纯视图不新增存储）
- [✓] 图源可视化编辑器（表单生成函数式脚本 + 高级模式 + 反解）
- [✓] 画中画帧转发管道（Dart 帧源节流 + Swift 帧泵含 CVPixelBufferPool）
- [✓] 视频播放历史页（完整列表 / 续看 / 单条删除 / 一键清空）
- [✓] 缓存策略后台定时执行（启动延迟首跑 + 6 小时复查，只在配了策略时干活）
- [✓] 画中画取帧落地（MPV screenshot-raw → 行距校正 → 帧泵转发；进画中画才拉，退出即停）
- [✓] 播放器高级手势（左半屏上下滑调亮度 / 右半屏调音量 / 水平拖进度 / 长按临时倍速；含提示浮层与拖动进度预览）
- [✓] 小说 TTS 听书（iOS AVSpeechSynthesizer 原生通道 + 切分/会话/跟读翻页/连听下一章/语速音调音量设置；其余平台如实降级为占位）
- [✓] 听书后台播放（音频会话 .playback + .spokenAudio；锁屏 / 控制中心 / 耳机键经 MPRemoteCommandCenter 回到合成器；系统打断即暂停不抢回；可关）
- [✓] 播放器亮度改系统亮度（iOS UIScreen.brightness 原生通道；不支持时回退页面内遮罩，进页面时对齐当前亮度不跳变）
- [✓] 弹幕上报（可选契约 DanmakuPostCapable + 脚本方法 postDanmaku；只读图源返回 false 而非报错，提示「仅本机可见」）
- [✓] 漫画双页进阶（翻页方向左→右/右→左、跨页配对「首页单独/直接配对」、页间距、预加载半径落库、章尾越界进下一章、跨章预取）
- [✓] 预加载优化（小说预取深度 2 + 并发去重 + 缓存容得下预取；漫画临近章尾预取下一章开头；取帧改帧节拍驱动）
- [✓] MPV 帧节拍：用 `time-pos` 流当帧节拍驱动取帧（暂停即停、与画面帧对齐），引擎无此能力时退回定时器

## Phase1 待完成（最小可用版本）
- [ ] MPV播放器完整适配AbstractPlayer抽象层，实现HUD参数展示

## Phase2待完成
- [ ] 漫画：追踪同步（属预留扩展）
- [ ] 小说：书签分组

## Phase3待完成

### 已调研并明确边界（不按原计划扩大实现）
- **MPV 真·推流式帧回调**：media_kit 的 Dart API 没有解码帧回调（`PlayerStream`
  25 条流里没有帧流），`VideoController` 只有一次性 `waitUntilFirstFrameRendered`。
  原生侧确实有 `mpv_render_context_set_update_callback`，但它埋在 media_kit_video
  的 Swift/Java 插件里，且 libmpv 硬性规定**每个 core 只能有一个 render context**
  ——`Video` 部件活着时无法从 Dart 再建一个。结论：不 fork media_kit_video 就拿不到
  真推流。**已落地的最优替代**：用 `time-pos`（每帧最多更新一次）当帧节拍驱动取帧，
  取帧时刻与画面帧对齐、暂停时不再空转；仍受 `screenshot-raw` 的整帧拷贝开销。
  若将来要彻底去掉拷贝：fork media_kit_video 把帧缓冲转发到 Dart，或自研渲染插件。
- **猫源 Node 兼容层**：现有垫片已约 4650 行（crypto/events/path/util/assert/stream/
  http-over-fetch/内存 fs/zlib inflate/tty/async_hooks/perf_hooks 等），并已用真实
  6.4MB Node 打包产物验证过。**不再扩大垫片**是既定结论：真实 cat 源要的是真 socket、
  端口监听与进程/线程（fastify/express 自建服务），垫片只会把「导入就被拦下」变成
  「导入成功、调用时才炸」，对用户更糟。iOS 上跑真实 Node 运行时不可行；
  Android 侧的 Node-Mobile（libnode）是独立立项，不是垫片的延伸。

### 待完成
- [ ] 自建聚合服务类「猫源」的 App 侧用法：薄壳图源脚本经 LumeSource.http 转发（服务跑在电脑/NAS）
- [ ] Android Node‑Mobile 猫源引擎的原生侧集成（Dart 侧契约已就位；需 NDK + libnode）
- [ ] 若确有只需 dns 的猫源脚本：给沙箱加宿主解析（InternetAddress.lookup）的 dns 垫片

## 预留扩展（暂不开发）
- WebDAV同步、Bangumi账号绑定、批量图源校验工具
- 沙盒文件IO持久化（当前为按图源隔离的进程内存储，重启即清空）
