# Lume Box · Mihon 仓库 `index.pb`（gzip protobuf）支持

来源：真机实测反馈。用户把 `https://github.com/keiyoushi/extensions/raw/repo/index.pb`
填进「漫画 → 扩展仓库 → 添加」，界面报：

```
添加失败：HTTP 404：https://github.com/keiyoushi/extensions/raw/repo/index.pb/index.min.json
```

## 一、问题

原来的地址归一化只认 `.json`：地址不是以 `.json` 结尾就补 `index.min.json`，
于是把 `.pb` 当成了目录，拼出 `…/index.pb/index.min.json` 这种必然 404 的地址。

Mihon / Tachiyomi 系仓库现在正式发布的是 **`index.pb`（gzip 过的 protobuf）**，
而 `index.min.json` 可能只剩「旧客户端请升级」的占位（keiyoushi 就是这样：
JSON 只有 1 条 `Outdated App`，pb 里是 **1409 个扩展**）。

## 二、改动

| 落点 | 内容 |
|---|---|
| `comic_repo_models.dart` / 服务注释 | 口径更新：Mihon 索引 = `index.pb` 或 `index.min.json` |
| `comic_repo_service.dart` | 地址解析与取索引分三路：**点名文件**（`.json` / `.pb`）→ 原样用；**Mihon 根地址** → 先试 `index.pb`，404 再退回 `index.min.json`（老仓库兼容）；**Venera 根地址** → `index.json`。落库的是实际取到的那一个地址（刷新时不再探测） |
| `comic_repo_fetcher.dart` | 端口新增 `fetchBytes`：`.pb` 是二进制（gzip + protobuf），不能先当文本解码 |
| `comic_repo_protobuf.dart`（新增） | 极简 protobuf 读取器：varint / 定长 / 长度前缀字段；越界、分组（wire type 3/4）、varint 超 64 位一律抛可读的 `FormatException` |
| `comic_repo_mihon_pb_parser.dart`（新增） | 按字段号解析 `index.pb`：`Index{1:name, 101:extensions}` → `Extension{1:name, 2:pkg, 3:payload{1:apk 下载地址}, 6:version, 8:sources{2:name,3:lang,4:baseUrl}}`；gzip 自动识别解压；字段号是对着真实索引逐个核对后写死的 |
| 添加仓库弹窗文案 | 说明 Mihon 用 `index.pb` / `index.min.json`，填根地址会自动探测，也可直接粘完整索引地址 |

口径说明：`.pb` 里**没有** `nsfw` 字段，这类仓库的扩展统一按非成人内容处理（文档化）；
载体仍是 `.apk`，本平台只能浏览、不能运行（与 JSON 索引一致）。

## 三、验证

- `test/comic_repo_pb_test.dart`（7 例）：裸 protobuf、gzip、多来源、相对 APK
  地址解析、宽松口径（缺字段只跳该条）、结构不符 / 截断 / 长度越界 / 非法 wire
  type / gzip 损坏的可读错误、varint 大数值（int64 来源 id）；
- `test/comic_repo_service_test.dart` 新增 3 例：点名 `.pb` 地址 → 不再拼接、
  根地址 pb 优先 + JSON 回退（断言请求序列）、`indexUriFor` 三种地址形态；
  原「Mihon 根地址补 index.min.json」用例按新探测行为更新；
- **真实索引核对**（临时执行，不提交）：keiyoushi `index.pb` 108,554 字节
  （gzip）→ 解析出 **1409 个扩展**，首条 `AHottie 1.6.4` 的 APK 地址、
  多来源样例 `Akuma`（27 个来源）都正确读出。
