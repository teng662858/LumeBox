import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'module_script.dart';
import 'source_script.dart';
import 'rex_widget_runtime.dart';

/// Rex/Forward classic Widget scripts are a separate host protocol from ESM.
class RexWidget {
  static final _encrypted = RegExp(
    r'^(?:\s*//[^\n]*\n)*\s*(REXENC|FWENC)\r?\n',
  );

  static bool isEncrypted(String script) =>
      _encrypted.hasMatch(stripScriptBom(script));

  static bool matches(String script) =>
      isEncrypted(script) ||
      RegExp(
        r'^\s*//\s*LumeRuntime:\s*rex\b',
        multiLine: true,
      ).hasMatch(script) ||
      script.contains('WidgetMetadata') &&
          ModuleScript.objectStringFields(script, 'WidgetMetadata') != null;

  static String identity(String nativeId) =>
      'rex_${sha256.convert(utf8.encode(nativeId)).toString().substring(0, 24)}';

  static String prepare(
    String script, {
    String name = '',
    String originUrl = '',
  }) {
    final clean = stripScriptBom(script);
    if (SourceMetadata.parseHeader(clean) != null) return clean;
    final fields = isEncrypted(clean)
        ? <String, String>{}
        : ModuleScript.objectStringFields(clean, 'WidgetMetadata') ?? {};
    final nativeId = fields['id'] ?? '';
    final label =
        fields['title'] ??
        (name.isNotEmpty
            ? name.replaceFirst(RegExp(r'\.(js|rex|fwd)$'), '')
            : 'Rex 模块');
    final key = nativeId.isNotEmpty
        ? nativeId
        : originUrl.isNotEmpty
        ? originUrl
        : name.isNotEmpty
        ? name
        : clean;
    return '// LumeRuntime: rex\n// LumeSource: ${jsonEncode({'id': identity(key), 'name': label, 'version': fields['version'] ?? '1', 'category': 'video'})}\n$clean';
  }

  static void requirePlaintext(String script) {
    final clean = stripScriptBom(script);
    final match = _encrypted.firstMatch(clean);
    if (match == null) return;
    final marker = match.group(1)!;
    final lines = clean.substring(match.end).trim().split(RegExp(r'\r?\n'));
    if (marker == 'FWENC') {
      throw const FormatException('FWENC 加密模块需要其宿主提供解密加载协议；请使用明文 Widget 源码');
    }
    try {
      if (lines.length != 2) throw const FormatException();
      final header = jsonDecode(lines[0]);
      if (header is! Map) throw const FormatException();
      if (header['v'] != 2 ||
          header['alg'] != 'A256GCM' ||
          header['mkv'] != 'rex-1') {
        throw const FormatException('不支持的 REXENC 加密版本或算法');
      }
      if (base64Decode('${header['iv']}').length != 12 ||
          base64Decode('${header['kb']}').length != 60 ||
          base64Decode(lines[1]).length <= 16) {
        throw const FormatException();
      }
    } on FormatException catch (error) {
      if (error.message == '不支持的 REXENC 加密版本或算法') rethrow;
      throw const FormatException('REXENC 加密信封损坏或字段长度无效');
    }
    throw const FormatException(
      'REXENC 模块须先由宿主异步加载内容密钥，不能直接作为明文执行',
    );
  }

  static String wrap(String script, Map<String, Object?> state) {
    requirePlaintext(script);
    final meta = SourceMetadata.parseHeader(script);
    if (meta == null) throw const FormatException('Rex 模块缺少导入身份');
    final seed = jsonEncode({
      'id': meta.id,
      'name': meta.name,
      'version': meta.version,
    });
    return '''
(function () {
  var __lumeRexIdentity = $seed;
  var __lumeRexEnvironment = (function(initialState) {
    $rexWidgetEnvironment
    return {Widget:Widget, run:widgetRun, state:function(){return widgetState;}, setMetadata:function(m){widgetMetadata=m;}, functionName:widgetFunctionName};
  })(${jsonEncode(state)});
  var Widget = __lumeRexEnvironment.Widget;
  $script
  if (typeof WidgetMetadata !== 'object' || !WidgetMetadata) throw new Error('Rex 模块没有有效的 WidgetMetadata');
  __lumeRexEnvironment.setMetadata(WidgetMetadata);
  function __lumeRexFunction(name) {
    if (!__lumeRexEnvironment.functionName(name)) throw new Error('Widget 函数名无效');
    var fn = eval(name);
    if (typeof fn !== 'function') throw new Error('Widget 没有实现函数：' + name);
    return fn;
  }
  LumeSource = ($rexWidgetAdapter)(WidgetMetadata, __lumeRexFunction, __lumeRexIdentity, __lumeRexEnvironment.run, __lumeRexEnvironment.state);
})();
''';
  }
}
