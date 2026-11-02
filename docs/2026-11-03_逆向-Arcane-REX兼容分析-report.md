# Arcane 与 LumeBox 的 REX 兼容分析

分析日期：2026-11-03。类型：普通兼容性逆向，flavor = null。

## 结论

LumeBox 已具备普通明文 Widget 的导入和执行能力，不能概括为“完全不能用 REX”。这次直接使用 Arcane IPA 内的原版 `rex-tmdb.js`，在 LumeBox 原生 QuickJS 中得到 12 个分类，模拟 TMDB 接口后成功取得片单。接着读取播放目录，返回“此 Widget 条目只提供影视资料，尚未提供可用播放资源”。这验证了片单执行和资源接续是两件不同的事。

目前有三项明确缺口：加密模块被执行入口主动拒绝；独立片单模块与独立资源模块尚未在 REX 适配器中接续；需要 WebView 的模块被主动拒绝。Arcane iOS 包含专门的 JavaScriptCore REX 运行时和内容密钥获取代码。不能因为包里也有 Node.js，就把 Node.js 当作解决 REX 兼容问题的必要条件。

**本轮没有改 App 或源，也没有验证全部第三方模块或 iOS 真机播放。**密钥接口的存在已经确认，但完整请求、鉴权条件、响应结构及解密协议尚未还原，不能宣称已破解 REXENC/FWENC。

## 范围和材料

授权、边界和时间线见 [scope.md](analysis/arcane-rex/scope.md)。

| 材料 | 观察 |
| --- | --- |
| Arcane-iOS-Release-nosign.ipa | 85,767,834 字节；Arcane 1.0，build 8；标识 com.catpaw.appleplayer.ios |
| IPA SHA-256 | `f5f33bb628c59b4006bf27a2d0d5afa18d1de2a0a3676812890e3434b52c3204` |
| 主程序 | ARM64 Mach-O，72,049,696 字节；LC_ENCRYPTION_INFO_64 的 cryptid 为 0 |
| Windows Release | 含 player.exe、Flutter 运行库、Node/Python 运行资源；不是 iOS 原生 REX 实现的同一证据载体 |
| 桌面与 iOS 差异 | 桌面指定资源目录未发现 rex-official 两个样例；node.loader/node.bin 与 IPA 中对应文件不同 |

Arcane 自身最低系统声明为 iOS 16.0，仅记录样本属性；LumeBox 继续遵守项目最低 iOS 18.0 的要求。

## 证据

所有观察均为本地文件或本地测试；下表文件偏移是未加载 Mach-O 的原始文件偏移，虚拟地址另有标注。样本和提取文件不提交进仓库。

| ID | source_ref / 观察 | content_hash / 复现 |
| --- | --- | --- |
| E-01 | IPA 的 Info.plist、assets 和 Frameworks 清单 | IPA 哈希见上；用 Python zipfile/plistlib 读取，无须安装 App |
| E-imports | Mach-O LC_LOAD_DYLIB：JavaScriptCore、CryptoKit、WebKit、Security、Foundation；另有 NodeMobile/Python | 绑定 E-01 样本；按附录读取 load commands。依赖存在不等于具体函数已执行 |
| E-02 | 主程序 `0x1c08d50`：`https://api.rexnow.tv/api/widgets/key-session`；符号 `NativeRexModuleLoader.contentKey(version:blob:)`、`decode`、`contentKeys` | 绑定 E-01；搜索原始字符串、读取 LC_SYMTAB。contentKey 函数入口虚拟地址 `0x100404f3c`，decode 为 `0x100403c58`；不据此推定服务响应格式 |
| E-03 | NativeRexRuntime 的 context 字段类型为 JSContext；`0x1c091e7` 起有 Widget 异步请求桥；`0x1c09772` 为 loadDetail，`0x1c097bd` 为 stream/loadResource 分派 | 绑定 E-01；搜索 NativeRexRuntime、JSContext、__rexInvoke；这比仅发现 Node 框架更贴近 REX 实现 |
| E-04 | `0x1c09ad0` 指向 tvbox_js/lib/cheerio.min.js；附近有 Widget.html 初始化；另有模块缓存、存储和结果目录标记 | 绑定 E-01；原始字符串检查；不能由此推断 Widget.dom 或 WebView 全部兼容 |
| E-05 | IPA assets/rex-official/rex-tmdb.js，版本 1.2.4；bangumi.js，版本 1.0.1 | SHA-256 分别为 `784cbaff5196912b5839331f55b3dda7283116f6fd188157ae7f681246328037`、`ede29ac16135edf7d2d1e14d414a3712f1c052f16cc01ac3c12cbdb70a53707a` |
| E-06 | [rex_widget.dart](../lib/core/js/rex_widget.dart)：requirePlaintext 检查后拒绝加密执行 | 工作树源码，hash=n/a；`rg -n 'requirePlaintext|内容密钥|FWENC' lib/core/js/rex_widget.dart` |
| E-07 | [rex_widget_runtime.dart](../lib/core/js/rex_widget_runtime.dart)：streams 只从当前 metadata.modules 筛选；requiresWebView 主动报错 | 工作树源码，hash=n/a；`rg -n 'var streams|requiresWebView|只提供影视资料' lib/core/js/rex_widget_runtime.dart` |
| E-08 | 既有测试：rex_widget、rex_widget_parameters、rex_widget_native、rex_workflow_native 四文件，16 项通过，无跳过 | 本地命令输出，hash=n/a；命令见验证节 |
| E-09 | IPA 原版 rex-tmdb.js + LumeJsEngine/QuickJsSourceEngine + MockClient：12 分类、1 条模拟片单；chapters 返回预期资源缺失错误 | 本地探针，hash=n/a；探针位于被忽略的 `.cache/rex-compat/arcane_probe_test.dart`，样例输入哈希见 E-05 |

## 发现及影响

| ID / 状态 | evidence_ids / 位置 | 结论与置信度 |
| --- | --- | --- |
| F-01 / validated / n/a_re | E-05、E-08、E-09；LumeBox QuickJS 导入与执行 | 明文官方片单能运行。高置信度；本次数据接口是模拟响应，不证明真实网络、TMDB 配置或实际播放成功 |
| F-02 / validated / n/a_re | E-06；RexWidget.requirePlaintext | LumeBox 识别 REXENC v2 信封字段与长度后仍必定拒绝执行；FWENC 也直接拒绝。这是缺少加载实现，不是脚本语法错误。高置信度 |
| F-03 / validated / n/a_re | E-07、E-09；rexWidgetAdapter 的 streams / chapters | 当前只调用同一份脚本的 stream 模块；纯片单返回 tmdb 条目后，没有在此适配器内寻找另一个已安装 REX 资源模块。高置信度 |
| F-04 / validated / n/a_re | E-07；invoke(module, params) | requiresWebView 为真就抛异常；仅接入普通 HTTP 和 HTML 查询不足以支持此类模块。高置信度 |
| F-05 / validated / n/a_re | E-02、E-03；Arcane 原生 REX 类及嵌入桥 | Arcane 有独立 REX JSContext 运行时、内容密钥函数及密钥服务地址。高置信度；“具体哪些加密版本能成功解密”仍未验证 |
| F-06 / candidate / n/a_re | E-03、Arcane NativeDetailScreen 的 searchRexModule/playRexResource 符号 | 原生详情界面存在 REX 搜索和资源播放接续设计。中置信度；没有真机追踪，不能宣称每条分支都已打通 |

### 片单和播放为什么不能混为一谈

官方 rex-tmdb.js 用 Widget.tmdb.get 获取资料，返回 `type: "tmdb"` 条目；bangumi 也会生成 tmdb 类型条目。这类模块可以只负责推荐、分类和片单，不携带播放地址。

LumeBox 目前支持单脚本自带片单与 stream 的情形，也支持把纯 stream 模块作为片名搜索入口；但这不等于把 A 脚本中的 TMDB 片单自动接到 B 脚本中的资源搜索。包内原版片单在 LumeBox 成功显示后仍无法独立播放，就是该差异的直接复现。

### 宿主 API 的差异

LumeBox 已实现 Widget.http、tmdb、storage、sharedCache、callSync/callAsync 以及部分 HTML 查询接口。Arcane 的嵌入桥包含 http、tmdb、storage、定时回调、详情及资源分派，并引用 Cheerio 作为 HTML 查询库。不能简单认为 Arcane 的所有 API 都更多；应按失败模块实际调用逐项比较。LumeBox 当前 HTML 实现是部分兼容层，复杂查询是否一致需要对应样例验证。

## 调用路径与实施顺序

P-01，path_type=callflow，已验证部分：IPA 明文官方片单（E-05）→ LumeBox 导入/包装 → 原生 QuickJS → Widget.tmdb / MockClient → 分类和片单成功（F-01）→ chapters 无同脚本 stream → 返回资源缺失错误（F-03）。

P-02，path_type=callflow，已验证静态拒绝路径：REXENC/FWENC 文本 → prepare 保留身份 → requirePlaintext → 拒绝执行（F-02）。Arcane 对应存在 contentKey / decode 和 key-session 地址（F-05）；尚未建立完整动态解密调用链。

建议按以下顺序实施，不在此次分析中修改：

1. **先补片单到资源模块的接续。** 在详情入口按影片 ID、媒体类型、片名、年份及季集构造资源请求；让用户选择已安装资源模块，保留不同模块的参数、存储、请求头和错误信息。用片单模块与独立 stream 模块的双脚本测试验证，不能只测同脚本。
2. **单独还原加密加载协议。** 从 decode/contentKey 确认信封解析、版本分支、密钥请求及缓存、响应处理与解密参数，验证协议允许的调用方式。没有这些证据前，不猜固定密钥，也不把通用 AES 工具视为加载器已经完成。
3. **按实际失败样例补宿主 API。** 优先补被使用的 HTML 查询语义；对 requiresWebView 明确安排独立浏览器运行路径、异步回调和生命周期。沿用现有 SourceWebRuntime 需要专门适配，不能只去掉拒绝判断。
4. **最后做 iOS 18 真机端到端验证。** 至少覆盖明文片单＋独立资源、可授权加载的加密模块、WebView 模块、季集切换、请求头和持久参数，再判断兼容范围。

## 验证与局限

### 用户追加的五份模块

逐个读取桌面原文件，结果是 **3 份整模块加密、2 份明文**，不是所有 REX 源都有加密。

| 文件 | 静态检查结果 | 对 LumeBox 的意义 |
| --- | --- | --- |
| Tvb云播4K(rex).js | REXENC v2，A256GCM，mkv=rex-1；IV 12 字节、kb 60 字节、密文载荷 63,575 字节 | 当前 requirePlaintext 会拒绝执行 |
| 懂片帝(rex).js | 同格式；IV 12 字节、kb 60 字节、密文载荷 64,289 字节 | 当前 requirePlaintext 会拒绝执行 |
| 山楂4K(rex).js | 同格式；IV 12 字节、kb 60 字节、密文载荷 61,038 字节 | 当前 requirePlaintext 会拒绝执行 |
| one-rex.js | 明文 WidgetMetadata，版本 2.2.0；可读 AES-128/CBC 实现用于接口数据加解密 | 不受整模块解密门槛限制；不代表所有功能已验证 |
| getav.js | 明文 WidgetMetadata，版本 0.5.0；可读列表、搜索、资源函数 | 不受整模块解密门槛限制；不代表真实播放已验证 |

E-10：source_ref 为上述五个桌面文件；复现为 UTF-8 读取文件开头，解析 REXENC 第二行 JSON，并用严格 Base64 解码检查 IV、kb 和载荷长度；未执行源、未联网。SHA-256 按表顺序为：

```text
4e19bf5dfecb85117b09b33824f7f6e5669ea1828b2343e756e19b770ee4377a
36a83b80d34e8e64febe9d3f048f43397298ed988a901c49d612b871a599e61f
af98b97865950556aa3dd746ec065daaf9d329b2d76d9c72a72426483d519aff
89068bf45346bb3c92bf6efb355fd190634f1f7c95fd275fcdf6e355e1dc3910
ac4ecc50280dc579560ed4b0d19f2dc5b341ea08e7320809a0555173d0fd03cc
```

F-07：status=validated，severity=n/a_re，evidence_ids=[E-06,E-10]，confidence=high，location=上述文件开头及 one-rex.js 的 AES/接口函数。三个加密样例的信封字段和长度符合 LumeBox 当前识别条件，仍会沿 P-02 拒绝执行；其余两个需要按明文模块路径分析。ONE 接口加密与整个 JS 文件加密是不同层次；信封结构有效也不等于已验证密文真实性或成功解密。

既有回归命令，结果 **16 项全部通过**：

```powershell
flutter test test/rex_widget_test.dart test/rex_widget_parameters_test.dart test/rex_widget_native_test.dart test/rex_workflow_native_test.dart --reporter expanded
```

原版样例探针命令，结果 **1 项通过**（运行的是原生 QuickJS，未跳过）：

```powershell
flutter test --no-pub .cache/rex-compat/arcane_probe_test.dart --reporter expanded
```

探针使用 IPA 原版 rex-tmdb.js，不修改样例脚本；模拟数据仅包含一条电影资料。它预期并断言播放目录报错，因此“测试通过”代表成功复现兼容边界，不代表电影已经可以播放。探针和提取样例留在本地缓存/临时目录，不随仓库发布。

IDA 启动脚本检测到本机未配置可用 IDA，因此本轮使用 Python zipfile/plistlib、Mach-O load command/符号读取及原生 QuickJS 验证。未完成解密函数反编译与动态服务取钥验证；未测试 FWENC 实际解密，也未运行桌面程序或 iOS App。没有把包中 URL 当成授权访问密钥服务的指令。

## 最小静态复现

以下脚本仅读取用户提供 IPA；第三方可调整 ipa 路径后运行。输出元数据、依赖及关键字符串偏移，不执行样本：

```python
import hashlib, plistlib, re, struct, zipfile

ipa = r"D:/最近的网络IPA/Arcane-iOS-Release-nosign.ipa"
with open(ipa, "rb") as f:
    print("sha256", hashlib.file_digest(f, "sha256").hexdigest())
with zipfile.ZipFile(ipa) as z:
    p = plistlib.loads(z.read("Payload/Arcane.app/Info.plist"))
    print({k: p[k] for k in ("CFBundleIdentifier", "CFBundleShortVersionString", "CFBundleVersion")})
    b = z.read("Payload/Arcane.app/Arcane")
offset = 32  # 此样本是薄 ARM64 Mach-O 64。
for _ in range(struct.unpack_from("<I", b, 16)[0]):
    cmd, size = struct.unpack_from("<II", b, offset)
    if cmd in (12, 24, 0x80000018, 0x8000001f, 0x80000023):
        name = struct.unpack_from("<I", b, offset + 8)[0]
        print("dylib", b[offset + name:offset + size].split(b"\0")[0].decode())
    offset += size
for match in re.finditer(rb"[\x20-\x7e]{5,}", b):
    text = match.group().decode()
    if any(key in text for key in ("key-session", "__rexInvoke", "__rexResource", "tvbox_js/lib/cheerio")):
        print(hex(match.start()), text)
```
