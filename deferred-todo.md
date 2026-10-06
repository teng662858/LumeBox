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
- [✓] 沙箱预算补判：跑得完但跑太久的脚本（CPU 空转超 3–5s）按超时处理并销毁上下文（原实现会当成正常结果收下，墙钟预算形同虚设）
- [✓] 桥接调用的引擎级错误分类：脚本方法体内堆爆（out of memory）不再被当成可捕获的普通脚本错误，改为销毁上下文
- [✓] 图源板块自报校验（`category`）：声明与导入目标不符时在解析阶段拒绝并输出明确日志；未声明的脚本不受影响
- [✓] MPV 播放器完整适配 AbstractPlayer 抽象层（HUD：编码 / 分辨率 / 帧率 / 码率由 MPV 内核自身输出；设置页可切 MPV / AVPlayer，MDK 仅枚举占位）
- [✓] 漫画阅读器 UI：阅读背景（纯黑 / 深灰 / 护眼绿 / 纯白）/ 点击翻页模式（分区点击，方向随阅读方向）/ 本地基础书签（顶栏加删 + 列表跳转删除；不做账号同步）
- [✓] 全量文案统一：「图源」展示文案收口为「源」（弹窗标题 / 空态 / 页面标题 / 错误与日志文案；只改 UI 字符串，逻辑零改动）
- [✓] 图源导入体验优化：三条输入通道（本地多文件 / 订阅链接 / 剪贴板）在板块页与源总管理页共用一份弹窗
- [✓] 本地文件内容识别：脚本 / 地址清单（含 .js.md5）/ 裸 MD5 校验值 / 备份 / 认不出——本地 `.js.md5` 与清单文件从「选中就报错」变成可用，且给出下一步动作
- [✓] 导入覆盖确认（同 id 先问一句，取消即整批零写入）与导入结果弹窗（逐条结论 / 失败原因 / 复制明细）
- [✓] 订阅拉取进度提示与清单截断说明（超 20 条地址时说明只处理前 N 条）；管理页空态直达导入
- [✓] JS 沙箱安全：导出中断通路（vendored 插件补丁）+ 修复「装备被提前解除」→ 纯 CPU 死循环可被回收
- [✓] JS 沙箱安全：栈上限下调至 512KB（原 1MB 实测会让进程当场死亡）+ 排空判废后不再交出成功结果
- [✓] JS 沙箱安全：宿主层沙箱身份校验（沙箱 id 带板块前缀，跨板块/跨来源调用在入口被拒）
- [✓] JS 沙箱安全：单次操作预算口径写实（求值 / 微任务轮 / 宿主往返 / 定时器注册四处记账）
- [✓] JS 沙箱安全：恶意脚本矩阵用例（10 例，覆盖正则回溯 / 递归 / 大分配 / 微任务 / 调用风暴 / 定时器 / 超大返回 / 伪造身份 / 跨源隔离）

## 已知底座缺陷（需原生侧修复，本轮不扩大实现范围）
- [✓] **纯 CPU 死循环无法中断回收**（已修复，安全测试第 1 条现已成立）
  - **原现象**：图源脚本方法体内 `while(true){}` 这类纯 CPU 空转会把调用线程一直占住，
    3–5 秒墙钟预算、内存上限、宿主/微任务预算**全部失效**，JSContext 无法被销毁。
  - **实际根因有两个，都在本轮修掉**：
    1. **符号没导出**（原判断）：插件用 `C_VISIBILITY_PRESET hidden` 编译 quickjs，
       且 `JS_EXTERN` 在 Windows 上需要 `BUILDING_QJS_SHARED` 才展开（插件从未定义），
       因此 `JS_SetInterruptHandler` 不在动态符号表里。已通过 vendored 插件副本
       （`third_party/quickjs_engine`）补一个 `jsSetInterruptHandler` 导出包装解决；
    2. **装备被提前解除**（原先没发现）：`SandboxContext._evaluate` 是「先 disarm 再
       drain」，而 `async` 方法体 `await` 之后的部分正是在**排空阶段**执行的
       （`_drainJobs` → `executePendingJob`）——死循环就卡在那里，中断已解除、
       回调直接放行。现已改为装备保持到排空结束。
  - **验证**：`test/js_sandbox/deadloop_timeout_test.dart` 用例 1a 由「期望失败」
    转为通过（死循环在 1 秒内被回收、判定为失控、上下文重建可用）；
    另新增 `test/js_sandbox/malicious_script_test.dart`（10 例）覆盖正则回溯 /
    无限递归 / 大分配 / 微任务自循环 / 宿主调用风暴 / 定时器风暴 / 超大返回值 /
    伪造沙箱身份 / 跨源隔离。
  - **顺带修掉的两个真问题**：
    - **栈上限过高会让进程当场死亡**：`defaultStackLimitBytes` 原为 1MB，实测
      无限递归会撞穿宿主线程栈、进程无异常直接消失（768/900/960KB 均正常抛出
      RangeError，1024KB 崩）。已下调为 512KB（2 倍余量）；
    - **无限微任务链被当成成功**：排空阶段判废后，求值结果仍被原样交出
      （实测 `isOk=true` 而上下文已销毁重建）。现已在排空后复核污染标记。

## 已完成（本轮新增）
- [✓] 漫画详情页批量下载（范围：全部 / 未读 / 仅当前章；分目录落盘、可重跑、
      可取消、结果是列表内的一张卡；不改阅读数据）
- [✓] 全局浅色主题与玻璃质感：三级底 / 三档文字 / 极淡阴影 / 顶部栏与底部 Dock
      磨砂穿栏；小说阅读页保持独立主题；漫画阅读器底色不动、工具栏改浅
- [✓] App 图标提亮（程序化生成亮色源图 + 重出 iOS 全套无 Alpha 图标）

## 已完成（本轮新增）
- [✓] 播放器：切到 MPV 不再空转 —— 播放页四态 + 控制栏常在（播放器设置不再消失）
      + 失败态「重试 / 切回 AVPlayer」+ 熔断中的 MPV 可在设置里重试
- [✓] JS 沙箱安全复测：三条性质（死循环超时销毁 / 上下文隔离 / 板块隔离）放回
      生产路径核验通过；补两处新攻击面（定时器内死循环、同 id 跨板块、JS 伪造身份）
- [✓] 示例源脚本：小说 / 漫画 / 视频三份可真跑的模板 + 本地站点端到端验证
      （导入 → 真实引擎 → HTTP → 解析 → 业务页渲染）

## 已完成（本轮新增）
- [✓] 三份独立 demo 示例源核验（小说文本 / 漫画图片 / 视频地址，各自板块绑定 +
      跨板块导入全部被拒）
- [✓] Venera 漫画源桥接：ComicSource / Network / Convert / UI / HtmlDocument 全局 +
      explore / categoryComics / search / loadInfo / loadEp 契约映射（脚本免改）
- [✓] 全量冒烟入口：`flutter test test/js_sandbox/smoke_test.dart`
      （三份 demo 各自板块跑通 + 死循环回收 + 上下文隔离，跑完打印汇总表）

## Phase2待完成
- [ ] 小说：书签分组 UI（同步功能延后）
- [ ] 漫画详情页：角色卡片横滑（需图源提供角色数据，等有真实图源再做）
- [ ] 探索页多维筛选（题材 / 区域 / 属性，需图源契约扩展，同上）
- [ ] 长按分享 / 保存到系统相册（需新原生依赖 + iOS 权限文案 + 真机验证）

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
- [ ] **AVPlayer 内核的 AVPlayer API 适配**（本轮确认**延期，不开发**）
  - **现状**：AVPlayer 内核由 `video_player` 插件驱动（纹理渲染），插件不暴露
    `AVPlayer` / `AVPlayerLayer`（源码全文检索 `pictureinpicture` 0 命中）。
  - **为什么要适配**：系统画中画（PiP）与字幕样式（字号）都要求直接持有 AVPlayer 的
    原生对象，插件通路下这两件事都无处落地——与「iOS 原生 PiP 接入」「字幕样式生效」
    两条待办同源，是同一个根因的三种表现。
  - **落地方向**：自研 Swift 内核（`AVPlayerLayer` + `AVPictureInPictureController`），
    播放与画中画一体；详见 `.zcode/plans/phase3-player-pip-approved-and-deferred.md`
    的延后待办 1、2。
  - **前置条件**：Mac + Xcode 构建与真机验证（当前开发机为 Windows，无法验证 iOS 侧）。

### 下轮候选（本轮已调研，未做）
- [ ] **插件的 `stringifyFn` 泄漏 → JSRuntime 无法回收**：插件的
      `JS_NewContextDartBridge` 里 `JS_FreeValue(ctx, globalObject)` 与
      `JS_FreeValue(ctx, stringifyFn)` 被注释掉了（且 `stringifyFn` 是个**全局变量**，
      多上下文会互相覆盖，直接打开注释是错的）。后果是 `JS_FreeRuntime` 的
      `assert(list_empty(&rt->gc_obj_list))` 在断言构建里必然失败（实测 Debug
      exit=3 / Release exit=0），因此 Dart 侧只能 `Qjs.reclaimRuntime = false`，
      每次销毁只释放 context、**runtime 被漏掉不回收**（`Qjs.abandonedRuntimes` 累加）。
      **实测泄漏速率（Phase3 复测基线，供修复后对照）**：**1.00 个 JSRuntime / 每次
      上下文销毁**、进程 RSS 约 **0.2MB / 轮**（50 轮正常循环 +9MB、20 轮失控重建 +10MB）。
      `JSContext` 侧回收干净（差值 0），泄漏只在这一处。
      修好 = 长跑 App 不再漏 runtime、Debug 构建不再 abort；代价 = 要动插件上下文创建
      的既有行为，且 `test/sandbox_native_test.dart` 里「放弃回收」的断言要改成
      「真的回收」。本轮刻意未与中断补丁混在一起改（同一文件两处改动，出问题难定位）。
      观测装置：`test/js_sandbox/ffi_memory_observation_test.dart`。
- [ ] 导入后自动跑一次连通性检测：与既有「批量测试连通性」重叠；批量导入时每条
      3–5s，会让导入明显变慢。等有真实使用反馈再定（落点：`source_import_flow.dart`
      的导入循环后追加一次 `testConnectivity`，结果并进结果弹窗）。
- [ ] 恢复备份的逐条预览（dry-run）：恢复现在只报总数（`恢复完成：新增 X · 覆盖 Y…`），
      写入前看不到「哪几条会被覆盖、哪几条会新增」。涉及备份格式与跨板块写入，单独一轮做。
- [ ] Mihon / Venera 扩展仓库的批量安装（另一条导入链路 `comic_repo_service.dart`，
      本轮只动「添加源」这条，未一并改）。

### 猫源「自建服务端程序」类脚本：定位与出路（本轮已定性，不做运行支持）
- 定性（2026-10 实测）：`catpaw` / `kstore` 这类订阅里的 6MB 包**不是图源脚本**，
  是别的客户端的扩展程序包（零图源入口、自带网站与弹幕前端、本地 HTTP/2 服务端、
  自有宿主桥 messageToDart）。iOS 无端口无进程，**补垫片也跑不起来**——
  本轮已把这一点写进导入提示（见 CHANGELOG）。
- 出路（按优先级）：
  1. 用直接抓接口的源脚本（getList / getDetail / getContent + fetch）；
  2. 若这类包对外提供 HTTP API：在电脑 / NAS 上跑它，App 侧写一个**薄壳源脚本**
     经 `LumeSource.http` 转发（deferred-todo 里「自建聚合服务类猫源」那条）；
  3. 仅当确有「只依赖 dns 解析」的猫源脚本时，再考虑加 dns 垫片
     （InternetAddress.lookup）——本轮未加，因为已定性的两份都不是这种情况。

### Venera 兼容层的未接入项（有真实需求再补）
- [ ] `Convert.sha1/sha256/sha512/hmac`（需要把摘要实现从猫源垫片里抽成共享件，
      或由宿主再实现一份；当前只接了 md5，其余调用即报「尚未接入」）
- [ ] `Convert.decryptAes*/decryptRsa`（网盘类源常用；需要 AES/RSA 实现）
- [ ] 账号登录 / 收藏夹 / 评论 / 排序点赞（需要 UI 与账号体系，Phase1~3 均未规划）
- [ ] 图片级自定义请求头（`onImageLoad` 返回的 headers 现在被丢弃；
      要透传得让图片管线支持逐图请求头）
- [ ] HTML 伪类与兄弟选择器（当前明确报错；要支持得写更完整的 CSS 选择器引擎）

## 预留扩展（暂不开发）
- 漫画：追踪同步（Phase2 本期不实现）
- WebDAV同步、Bangumi账号绑定、批量图源校验工具
- 沙盒文件IO持久化（当前为按图源隔离的进程内存储，重启即清空）
