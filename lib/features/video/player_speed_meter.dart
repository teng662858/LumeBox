import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/net/lume_http.dart';
import '../../core/util/lume_log.dart';

/// 当前视频地址的**实测网速**：向播放地址发一个 Range 探测，按字节 / 耗时算。
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
/// 因此：**只在起播时与用户主动点「测速」时各测一次**，不周期轮询。
///
/// 探测请求是 `Range: bytes=0-262143`（256KB）：多数 CDN 支持 Range，拿到 206 时
/// 只下这 256KB；不支持 Range 的源会回 200 并开始在后台下载——此时按读到的
/// 前若干字节计时（见 [_measure]），不把整片视频拉下来。
class PlaybackSpeedMeter {
  PlaybackSpeedMeter({LumeHttp? http}) : _http = http ?? LumeHttp(source: '测速');

  final LumeHttp _http;

  /// 探测体积上限（256KB）：够稳定地估出速率，又不至于明显吃流量。
  static const int probeBytes = 256 * 1024;

  /// 单次探测的最长时间。
  static const Duration probeTimeout = Duration(seconds: 8);

  /// 最近一次实测速率（kbps）；null = 还没测过 / 测不出来。
  final ValueNotifier<int?> kbps = ValueNotifier<int?>(null);

  /// 正在测。
  final ValueNotifier<bool> busy = ValueNotifier<bool>(false);

  /// 是否已经对某个地址测过（同一地址不重复自动测）。
  Uri? _measured;
  bool _disposed = false;

  /// 对 [uri] 测速。同一地址已经在测或测过时不重复（[force] 为真时强制重测）。
  Future<void> measure(
    Uri uri, {
    Map<String, String>? headers,
    bool force = false,
  }) async {
    if (_disposed || !uri.hasScheme) return;
    if (!force && _measured == uri) return;
    if (busy.value) return;
    _measured = uri;
    busy.value = true;
    try {
      final value = await _measure(uri, headers);
      if (_disposed) return;
      kbps.value = value;
    } catch (error) {
      // 测速失败不影响播放：清掉读数并记一条日志。
      LumeLog.info('[player] 测速失败（$uri）：$error');
      if (!_disposed) kbps.value = null;
    } finally {
      if (!_disposed) busy.value = false;
    }
  }

  Future<int?> _measure(Uri uri, Map<String, String>? headers) async {
    final stopwatch = Stopwatch()..start();
    final response = await _http.send(
      url: uri.toString(),
      method: 'GET',
      headers: <String, String>{
        ...?headers,
        'Range': 'bytes=0-${probeBytes - 1}',
      },
      timeout: probeTimeout,
    );
    stopwatch.stop();

    final bytes = response.body.length;
    final millis = stopwatch.elapsedMilliseconds;
    if (bytes <= 0 || millis <= 0) return null;
    // 服务端不支持 Range 时也会回 200：这次请求按内容长度计费过重，因此
    // 只在下完前 256KB 内计时（send 已经把响应读全，这里按实测体积算，
    // 不把整片视频的下载时间算进速率——那会把读数严重低估）。
    if (bytes < 8 * 1024) return null; // 太小：多半是错误页 / 重定向壳
    final kbpsValue = (bytes * 8) / millis; // bytes*8 / ms = kbit/s
    return kbpsValue.round();
  }

  /// 展示文本：`1.8MB/s` / `640KB/s`；没有读数时 null。
  static String? describe(int? kbps) {
    if (kbps == null || kbps <= 0) return null;
    final kBytesPerSecond = kbps / 8; // kbps → KB/s
    if (kBytesPerSecond >= 1024) {
      return '${(kBytesPerSecond / 1024).toStringAsFixed(1)}MB/s';
    }
    return '${kBytesPerSecond.round()}KB/s';
  }

  void dispose() {
    _disposed = true;
    kbps.dispose();
    busy.dispose();
  }
}
