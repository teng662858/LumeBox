import 'dart:typed_data';

import '../../../core/net/lume_http.dart';
import '../../../core/source/source.dart';

/// 仓库索引与扩展脚本的抓取端口。
///
/// 与 JS 图源同一条纪律：网络只由宿主 Dart 层发出，脚本侧没有网络权限。
/// 测试注入替身即可在没有网络的机器上跑完整仓库流程。
abstract interface class RepoFetcher {
  /// 抓取文本（JSON 索引 `index.min.json` / `index.json`、JS 脚本）；
  /// 失败抛 [SourceException]。
  Future<String> fetchText(Uri url);

  /// 抓取原始字节（Mihon 的 `index.pb` 是 gzip 过的 protobuf，必须按字节收，
  /// 不能先当文本解码）；失败抛 [SourceException]。
  Future<Uint8List> fetchBytes(Uri url);

  void dispose();
}

/// 正式实现：走宿主的 HTTP 层（[LumeHttp]）。
class LumeHttpRepoFetcher implements RepoFetcher {
  LumeHttpRepoFetcher({LumeHttp? http}) : _http = http ?? LumeHttp();

  final LumeHttp _http;

  @override
  Future<String> fetchText(Uri url) async => (await _fetch(url)).text;

  @override
  Future<Uint8List> fetchBytes(Uri url) async => (await _fetch(url)).body;

  Future<LumeHttpResponse> _fetch(Uri url) async {
    try {
      final response = await _http.send(url: url.toString());
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw SourceException(
          SourceErrorKind.network,
          'HTTP ${response.statusCode}：$url',
        );
      }
      return response;
    } on SourceException {
      rethrow;
    } catch (error) {
      throw SourceException(SourceErrorKind.network, '抓取失败：$url（$error）');
    }
  }

  @override
  void dispose() => _http.dispose();
}
