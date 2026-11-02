# lume_box

A new Flutter project.

## 使用说明

- [播放增强、四内核限制与视频/漫画本地下载](docs/2026-11-02_播放增强与本地下载.md)
- [片头片尾识别、手动打点、模型替换与日志](docs/2026-10-19_片头片尾识别接入.md)
- [漫画阅读器的截图对照与操作验收](docs/2026-10-18_漫画阅读器截图对照验收.md)
- [主题色、字体与自适应颜色设置](docs/2026-10-18_个性化设置.md)


底部导航为漫画／视频／设置，猫源从视频选择器进入，网页主页支持长按排序。视频源支持通用 Python Spider、Python／JS 多文件 ZIP 源包、ESM／CommonJS 依赖加载、JS Spider 及远程 T4／RPC，见 [三 TAB 与多文件源包](docs/2026-10-20_三TAB与多文件源包.md)。Python 代码在 App 进程内执行，请仅导入可信来源；Android Java／DEX 需外部后端，原生扩展需随 iOS 构建签名。

Rex 明文经典 Widget 已接入参数、同步存储／共享缓存、搜索到播放和集合解析；大师兄、采集聚合、荐片已通过原文件离线链路及重开测试。REXENC／FWENC 加密模块尚未接通密钥加载，详见 [Rex Widget 接入范围](docs/2026-10-20_Rex-Widget接入.md)。

## 打包产物（未签名 IPA）

**构建产物统一放 `ipa/`**（目录已忽略，不进版本库）。文件名带**构建号**：

```
ipa/LumeBox-unsigned-1.0.<run_number>.ipa
```

拉最新一次 CI 构建（`gh` 已登录即可）：

```bash
bash tool/fetch_ipa.sh        # 等价于「把最新成功的 IPA 拉到 ipa/」
bash tool/fetch_ipa.sh <run>  # 指定某次 run
```

装到手机后**核对装的是哪一版**：设置 →「关于」会显示
`LumeBox · 版本 1.0.<run_number>（构建 <run_number>）`——与文件名对上才是这一版。
（以前所有包都是 `1.0.0(1)`、文件名也一直相同，装上旧包看不出来，真机踩过一次
「代码改了但界面没变」。）

## Getting Started

This project is a starting point for a Flutter application.

A few resources to get you started if this is your first Flutter project:

- [Learn Flutter](https://docs.flutter.dev/get-started/learn-flutter)
- [Write your first Flutter app](https://docs.flutter.dev/get-started/codelab)
- [Flutter learning resources](https://docs.flutter.dev/reference/learning-resources)

For help getting started with Flutter development, view the
[online documentation](https://docs.flutter.dev/), which offers tutorials,
samples, guidance on mobile development, and a full API reference.


### 公共弹幕服务

播放器同时保留源弹幕，并支持[弹弹play开放弹幕网络](https://www.dandanplay.com/)及兼容 API。
在播放器“更多 → 弹幕服务地址”中选择 Cynn、Wenjian、官方服务或自定义 HTTPS 部署前缀；支持 [danmu_api](https://github.com/huangxd-/danmu_api) 的搜索与弹幕接口。默认使用用户指定的 Cynn 地址；服务无结果或不稳定时可换服务。匹配不唯一时使用“匹配公共弹幕”选择对应作品和集数。

官方服务须按[官方接入说明](https://doc.dandanplay.com/open/)申请应用凭证。iOS 配置保存在设备钥匙串，签名仅发到官方主机；第三方兼容服务不接收官方凭证。没有对应弹幕的作品不生成模拟弹幕。

最低支持 iOS 18.0。播放器提供 AVPlayer、MPV、MDK 和 AetherEngine，HDR／杜比能力与实际输出限制见 [播放器展示说明](docs/player-presentation.md)。
