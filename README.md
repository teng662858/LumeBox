# lume_box

A new Flutter project.

## 图源（脚本不随本仓库分发）

内置图源统一放在 **[teng662858/LumeBox-Sources](https://github.com/teng662858/LumeBox-Sources)**，
按板块提供订阅清单，App 里「导入图源 → 订阅地址」粘贴即可：

| 板块 | 订阅地址 |
|------|----------|
| 小说 | `https://raw.githubusercontent.com/teng662858/LumeBox-Sources/main/novel/sources.txt` |
| 漫画 | `https://raw.githubusercontent.com/teng662858/LumeBox-Sources/main/comic/sources.txt` |
| 视频 | `https://raw.githubusercontent.com/teng662858/LumeBox-Sources/main/video/sources.txt` |

本地要跑「真实引擎 + 真实脚本」的原生用例，先拉一份脚本缓存：

```bash
dart run tool/fetch_sources.dart   # → .sources-cache/<section>/（已 gitignore）
```

没拉缓存时那些用例**整组跳过**（不是失败）：它们验的是「脚本对得上站点真实结构」，
不是 App 自身的行为。

## Getting Started

This project is a starting point for a Flutter application.

A few resources to get you started if this is your first Flutter project:

- [Learn Flutter](https://docs.flutter.dev/get-started/learn-flutter)
- [Write your first Flutter app](https://docs.flutter.dev/get-started/codelab)
- [Flutter learning resources](https://docs.flutter.dev/reference/learning-resources)

For help getting started with Flutter development, view the
[online documentation](https://docs.flutter.dev/), which offers tutorials,
samples, guidance on mobile development, and a full API reference.
