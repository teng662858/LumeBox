import '../../core/net/network_cancellation.dart';

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/net/lume_http.dart';
import '../../core/util/lume_log.dart';

/// 当前视频地址的**源测速**：向播放地址发一个 Range 探测，按字节 / 耗时算。
///
/// ## 为什么是「探测」而不是「统计播放器的流量」
///
/// 播放器内核（AVPlayer / MPV / MDK）都在原生侧取流，Dart 侧拿不到它下载了多少
/// 字节、用了多久——**没有可以统计的对象**。想给出真实网速只有两种办法：
/// 1. 按缓冲增长 × 码率估算（零成本，但码率未知时（AVPlayer）算不出来，且它是
///    「播放器消费速度」而不是「网络速度」）；
/// 2. **拿同一份地址、带上同样的请求头，自己发一次小请求实测**（本实现的取舍）。
///
/// 取 2 的理由：口径诚实（量的是 CDN 到本机的真实吞吐）、三套内核都适用、
/// 与播放器同一条请求头（防盗链源不会给出假信号）。代价是要花一点流量，
/// 因此页面只在前台正常播放时、首帧之后每 30 秒采样一次；
/// 首帧之前不测——那时播放器正在抢带宽，探测只会与首帧互相拖慢，读数也混着
/// 播放器自己的下载。
///
/// 探测请求是 `Range: bytes=0-262143`（256KB）：多数 CDN 支持 Range，拿到 206 时
/// 只下这 256KB；不支持 Range 的源会回 200——那就**读到 [probeBytes] 就断开**
/// （读取上限见 `readResponseBody`），绝不把整片视频拉下来。
class PlaybackSpeedMeter {
  PlaybackSpeedMeter({LumeHttp? http})
    : _http = http ?? LumeHttp(source: '测速'),
      _ownsHttp = http == null;

  final LumeHttp _http;
  final bool _ownsHttp;

  /// 探测体积上限（256KB）：用于小样本链路探测，又不至于明显吃流量。
  static const int probeBytes = 256 * 1024;

  /// 单次探测的最长时间。
  static const Duration probeTimeout = Duration(seconds: 8);

  /// 最近一次实测速率（kbps）；null = 还没测过 / 测不出来。
  final ValueNotifier<int?> kbps = ValueNotifier<int?>(null);

  /// 正在测。
  final ValueNotifier<bool> busy = ValueNotifier<bool>(false);

  /// 最近一次探测**没测出读数**（失败 / 被站点拒绝 / 数据太小）。
  ///
  /// 界面据此把占位文案从「测速」换成「测速失败」：真机反馈的「点测速没反应」
  /// 就是这个——失败后既不显示数字、也不显示结论，按钮文案和占位文案一模一样，
  /// 用户只能理解为「点了没用」。如实报失败比沉默好。
  final ValueNotifier<bool> failed = ValueNotifier<bool>(false);

  /// 是否已经对某个地址测过（同一地址不重复自动测）。
  Uri? _measured;
  bool _disposed = false;
  int _revision = 0;
  NetworkCancellation? _probe;
  bool _background = false;

  void cancelBackground() {
    if (_background) _cancelProbe();
  }

  void _cancelProbe() {
    _revision++;
    _probe?.cancel();
    _probe = null;
    _background = false;
    if (!_disposed) busy.value = false;
  }

  static bool canProbeInBackground({
    required bool playing,
    required bool buffering,
    required Duration buffered,
    required bool foreground,
    required bool hasNativeSpeed,
  }) =>
      playing &&
      !buffering &&
      foreground &&
      !hasNativeSpeed &&
      buffered >= const Duration(seconds: 20);

  void reset() {
    _cancelProbe();
    _measured = null;
    kbps.value = null;
    failed.value = false;
  }

  /// 对 [uri] 测速。同一地址已经在测或测过时不重复（[force] 为真时强制重测）。
  Future<void> measure(
    Uri uri, {
    Map<String, String>? headers,
    bool force = false,
    bool background = false,
  }) async {
    if (_disposed || !uri.hasScheme) return;
    if (!force && _measured == uri) return;
    if (!background && _background) cancelBackground();
    if (busy.value) return;
    final probe = _probe = NetworkCancellation();
    _background = background;
    _measured = uri;
    final revision = _revision;
    busy.value = true;
    try {
      final value = await probe.run(() => _measure(uri, headers));
      if (_disposed || revision != _revision) return;
      kbps.value = value;
      // 没读到有效数据也算失败（站点拒绝 Range / 回了个错误页 / 数据太小）。
      failed.value = value == null;
    } on NetworkCancelled {
      // Playback owns the bandwidth; cancellation is not a failed probe.
    } catch (error) {
      // 测速失败不影响播放：清掉读数、如实标记失败并记一条日志。
      LumeLog.info('[player] 测速失败（$uri）：$error');
      if (!_disposed && revision == _revision) {
        kbps.value = null;
        failed.value = true;
      }
    } finally {
      if (!_disposed && identical(_probe, probe)) {
        _probe = null;
        _background = false;
        busy.value = false;
      }
    }
  }

  Future<int?> _measure(
    Uri uri,
    Map<String, String>? headers, {
    int depth = 0,
  }) async {
    final stopwatch = Stopwatch()..start();
    final response = await _http.send(
      url: uri.toString(),
      method: 'GET',
      headers: <String, String>{
        for (final entry in (headers ?? const <String, String>{}).entries)
          if (entry.key.toLowerCase() != 'range') entry.key: entry.value,
        'Range': 'bytes=0-${probeBytes - 1}',
      },
      timeout: probeTimeout,
      // 读取上限：服务端不支持 Range（回 200）时读满这 256KB 就断开，
      // 既不与首帧抢带宽，也不会把整片下载的时间算进速率（那会严重低估）。
      maxBytes: probeBytes,
    );
    stopwatch.stop();

    // 错误页与登录页的下载速度不能代表视频测速成功。
    if (response.statusCode != 200 && response.statusCode != 206) return null;
    final contentType = response.headers.entries
        .where((entry) => entry.key.toLowerCase() == 'content-type')
        .map((entry) => entry.value.toLowerCase())
        .firstOrNull;
    if (contentType?.contains('text/html') ?? false) return null;
    // Measure media bytes rather than the tiny HLS index file. Follow a master
    // index and its media index at most twice, keeping the same request headers.
    if (response.text.trimLeft().startsWith('#EXTM3U')) {
      if (depth >= 2) return null;
      final paths = response.text
          .split('\n')
          .map((line) => line.trim())
          .where((line) => line.isNotEmpty && !line.startsWith('#'));
      final path = paths.firstOrNull;
      if (path == null) return null;
      final segment = uri.resolve(path);
      if (segment.scheme != 'https' && segment.scheme != 'http') return null;
      return _measure(segment, headers, depth: depth + 1);
    }

    final bytes = response.body.length;
    final millis = stopwatch.elapsedMilliseconds;
    if (bytes <= 0 || millis <= 0) return null;
    if (bytes < 8 * 1024) return null; // 太小：多半是错误页 / 重定向壳
    final kbpsValue = (bytes * 8) / millis; // bytes*8 / ms = kbit/s
    return kbpsValue.round();
  }

  /// Source probe throughput. This is not the player's real-time traffic.
  static String? describe(int? kbps) {
    if (kbps == null || kbps <= 0) return null;
    return describeBytes(kbps * 1000 / 8);
  }

  static String describeBytes(double bytesPerSecond) {
    if (!bytesPerSecond.isFinite || bytesPerSecond < 0) return '—';
    if (bytesPerSecond >= 1000 * 1000) {
      return '${(bytesPerSecond / 1000000).toStringAsFixed(1)}MB/s';
    }
    return '${(bytesPerSecond / 1000).round()}KB/s';
  }

  void dispose() {
    _cancelProbe();
    _disposed = true;
    if (_ownsHttp) _http.dispose();
    kbps.dispose();
    busy.dispose();
    failed.dispose();
  }
}
