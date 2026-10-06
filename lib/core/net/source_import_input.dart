import '../util/md5.dart';
import 'source_subscription.dart';

/// 一份导入输入的形态。本地文件内容与剪贴板文本都可能是这五种之一。
///
/// 判定顺序（**顺序有意义**，不能换）：
/// 1. 空文本 → [unknown]；
/// 2. **备份 JSON → [backup]**：备份里带着图源脚本原文，因此它同时也「像脚本」，
///    必须在脚本判定之前拦下，否则用户粘贴一份备份会被当成脚本导入；
/// 3. 脚本正文 → [script]（有头部元信息注释，或正文含 `LumeSource`）；
/// 4. 一行一个 http(s) 地址 → [manifest]（`.js.md5` 校验清单也走这条）；
/// 5. 裸 MD5 校验值 → [checksum]：本机导入**拿不到**脚本实体地址，只能明确告诉
///    用户换条路（这是「文件选择器允许 .md5、选中却报缺少元信息」的正面修复）；
/// 6. 其余 → [unknown]。
enum SourceImportInputKind {
  script('脚本'),
  manifest('地址清单'),
  checksum('校验值'),
  backup('备份'),
  unknown('认不出');

  const SourceImportInputKind(this.label);

  /// 展示用短名（结果与提示里出现）。
  final String label;
}

/// 导入输入的识别结果：形态 + 解析出来的内容。
class SourceImportInput {
  const SourceImportInput._({
    required this.kind,
    required this.name,
    this.text = '',
    this.urls = const <String>[],
  });

  /// 形态。
  final SourceImportInputKind kind;

  /// 来源展示名（本地文件是文件名，剪贴板/粘贴位为空）。
  final String name;

  /// 脚本文本（仅 [SourceImportInputKind.script] 非空）。
  final String text;

  /// 清单里的 http(s) 地址（仅 [SourceImportInputKind.manifest] 非空）。
  final List<String> urls;

  bool get isScript => kind == SourceImportInputKind.script;

  bool get isManifest => kind == SourceImportInputKind.manifest;

  /// 是否能直接进导入链路（脚本直接导入，清单再解析一层）。
  bool get isImportable => isScript || isManifest;

  /// 不能导入时给用户的**下一步动作**（点明该怎么做，而不是只说「失败了」）。
  String get describeFailure => switch (kind) {
        SourceImportInputKind.checksum =>
          '$_subject只有一串 MD5（.js.md5 校验值）：本机导入拿不到脚本地址。'
              '请改用「订阅链接」填入该 .md5 的网址，或直接选择脚本文件。',
        SourceImportInputKind.backup =>
          '$_subject看起来是源备份：请到「设置 → 源总管理 → 恢复源」里恢复它，'
              '导入弹窗不接受备份文本。',
        SourceImportInputKind.unknown =>
          '$_subject里没有识别出源脚本或订阅地址。',
        _ => '',
      };

  String get _subject => name.isEmpty ? '这段内容' : '「$name」';

  /// 识别一份输入。[name] 只用于提示文案；[urlLimit] 是清单地址的收取上限。
  static SourceImportInput classify(
    String raw, {
    String name = '',
    int urlLimit = 20,
  }) {
    final text = stripBomText(raw).trim();
    if (text.isEmpty) {
      return SourceImportInput._(kind: SourceImportInputKind.unknown, name: name);
    }
    if (_looksLikeBackup(text)) {
      return SourceImportInput._(kind: SourceImportInputKind.backup, name: name);
    }
    if (SourceSubscription.looksLikeScript(text)) {
      return SourceImportInput._(
        kind: SourceImportInputKind.script,
        name: name,
        text: raw,
      );
    }
    final urls = SourceSubscription.urlsIn(text, limit: urlLimit);
    if (urls.isNotEmpty) {
      return SourceImportInput._(
        kind: SourceImportInputKind.manifest,
        name: name,
        urls: urls,
      );
    }
    if (Md5.parseHex(text) != null) {
      return SourceImportInput._(kind: SourceImportInputKind.checksum, name: name);
    }
    return SourceImportInput._(kind: SourceImportInputKind.unknown, name: name);
  }

  /// 是不是 `SourceBackup.encode()` 产出的备份 JSON。
  ///
  /// 判定刻意宽松到只看「以 `{` 开头 + format 标记」：备份格式由 [SourceBackup]
  /// 定义，这里不重复解析它，只负责把用户引到正确的入口。
  static bool _looksLikeBackup(String text) {
    if (!text.startsWith('{')) return false;
    return text.contains('"format"') && text.contains('lume.sources');
  }
}
