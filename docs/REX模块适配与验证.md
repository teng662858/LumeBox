# REX 明文模块：导入与验证

> 2026-11-03 更新：REXENC v2（A256GCM / rex-1）已接入官方内容密钥服务与认证解密；三份用户加密样例均通过原生 QuickJS 加载。懂片帝、山楂4K 实测走通列表、详情、选集及播放地址解析。详见 [源加密与安全备份实现报告](2026-11-03_实现-源加密与安全备份-report.md)。本文其余早期验证记录保留历史语境。

本轮完成普通明文视频模块的列表、搜索、详情、线路选集与播放适配。加密模块及依赖浏览器执行的模块仍有兼容限制，不能把成功导入等同于所有功能可用。

## 直接试用

样板文件是 [lumebox_demo.js](../assets/rex/lumebox_demo.js)。下载后，在视频源的添加入口选择本地 JS 文件导入；也可以使用下列原始文件地址：

```text
https://raw.githubusercontent.com/teng662858/LumeBox/main/assets/rex/lumebox_demo.js
```

选择“REX 明文样板”，打开列表，搜索 `Bunny`，进入详情，切换线路并点选剧集播放。样板不需要账号或密钥。

两条线路、每条三集和角色头像是测试数据，三个选集播放同一段公开样片；备用入口仅增加查询参数，不代表独立备用 CDN。封面与头像使用 Picsum 占位图，不是真实电影海报或演员。视频使用 Mux 公共 HLS 测试流。样板用于确认接口契约，不作为正式影视订阅。

## 对照制作文档的接口检查

| 能力 | 本次状态与限制 |
| --- | --- |
| WidgetMetadata、modules、functionName | 已接入普通视频模块 |
| page/count、搜索 keyword | 原生运行时测试通过，空搜索结果返回空列表 |
| type=url 与顶层 loadDetail(link) | 已修复；原先 URL 条目可能绕过详情处理器 |
| posterPath/detailPoster、coverUrl | 已区分详情海报与背景；请求头随图片传递 |
| backdropPath | 映射到现有全屏模糊背景；TMDB backdrop 优先 |
| peoples | 映射姓名、头像、角色和头像请求头；无 TMDB 演员时展示源演员 |
| genreItems、年份、媒体类型 | 映射到详情；年份/类型可辅助 TMDB 核验 |
| 嵌套 episodeItems | 保留父级线路，进入现有线路与选集 UI |
| stream 资源模块 | 播放时重新解析临时链接；不复用过期播放地址 |
| detailCacheDuration | 详情与目录共用有时限、有容量上限的缓存 |
| Widget.dom、requiresWebView | 尚未完成；不能直接运行所有浏览器模块 |
| 独立弹幕/字幕扩展、字幕压缩包 | 不作为普通视频源完整接入 |
| 自动网盘身份匹配、全部自由参数约定 | 尚未完整实现 |
| FWENC / REXENC | REXENC v2 已支持官方取钥和认证解密；FWENC 仍是不同协议，不支持 |
| playerType | 仍由 LumeBox 可用播放内核控制，不承诺复现其他 APP 的内核分流 |

字段约定参考 [ForwardWidgets 官方示例](https://raw.githubusercontent.com/InchStudio/ForwardWidgets/master/widgets/demo.js)。制作文档说明模块如何编写，并不意味着其他 APP 专用接口自动在 LumeBox 中可用。

## 本次验证记录

- Windows 原生 QuickJS：正式 SourceManager 导入、列表、搜索、详情、两条线路六个选集、播放内容解析通过；测试没有以缺少原生桥为由跳过。
- Android Pixel 8 API 36 模拟器：通过正式导入器和现有页面进入详情，显示线路、选集和演示角色；使用真实 MPV 播放 HLS，连续截图显示动画场景持续推进。
- 模拟器入口：`flutter run -d emulator-5554 -t tool/rex_workflow_preview.dart`。此开发目标包含 Android QuickJS 与 MPV 注入，不改变发布版的平台支持范围。
- 未在本轮实测 iOS AVPlayer，也未逐一验证所有第三方 REX 模块。

## TMDB 同轮修复

先读取源详情，再用干净标题及可用年份、电影/剧集类型匹配；同名歧义或年份不符时保留源信息。缓存升级避免继承旧错误匹配，同一请求合并，HTTP 连接复用，短暂网络/服务端错误自动重试一次。

详情与图片合并请求，支持时减少一次网络往返；旧代理没有附带 images 时保留兼容回退。接口依据 [TMDB append_to_response 文档](https://developer.themoviedb.org/docs/append-to-response)。这些优化不代表任意网络下都能立即匹配成功。

新增 TMDB 片名图片展示，保留图片原有颜色；绿色英文片名字样来自该剧的 logo 素材。没有可用位图 logo 或加载失败时显示原文字标题。前景海报默认提高到 w780、源封面按设备像素解码，上部不做模糊，底部渐隐到背景，实际清晰度仍受原图质量影响。

## 回归命令

```powershell
flutter test test/tmdb_matching_performance_test.dart test/tmdb_test.dart test/tmdb_metadata_regression_test.dart test/tmdb_settings_page_test.dart test/rex_workflow_native_test.dart test/rex_widget_native_test.dart test/rex_widget_samples_native_test.dart test/rex_widget_test.dart test/rex_widget_parameters_test.dart test/video_detail_flow_test.dart test/detail_poster_background_test.dart test/poster_gradient_scaffold_test.dart
```
