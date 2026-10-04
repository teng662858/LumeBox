import '../../../core/net/lume_http.dart';
import '../../../core/source/source.dart';

/// 仓库索引与扩展脚本的抓取端口。
///
/// 与 JS 图源同一条纪律：网络只由宿主 Dart 层发出，脚本侧没有网络权限。
/// 测试注入替身即可在没有网络的机器上跑完整仓库流程。
abstract interface class RepoFetcher {
  /// 抓取文本（索引 JSON 或 JS 脚本）；失败抛 [SourceException]。
  Future<String> fetchText(Uri url);

  void dispose();
}

/// 正式实现：走宿主的 HTTP 层（[LumeHttp]）。
class LumeHttpRepoFetcher implements RepoFetcher {
  LumeHttpRepoFetcher({LumeHttp? http}) : _http = http ?? LumeHttp();

  final LumeHttp _http;

  @override
  Future<String> fetchText(Uri url) async {
    try {
      final response = await _http.send(url: url.toString());
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw SourceException(
          SourceErrorKind.network,
          'HTTP ${response.statusCode}：$url',
        );
      }
      return response.text;
    } on SourceException {
      rethrow;
    } catch (error) {
      throw SourceException(SourceErrorKind.network, '抓取失败：$url（$error）');
    }
  }

  @override
  void dispose() => _http.dispose();
}
