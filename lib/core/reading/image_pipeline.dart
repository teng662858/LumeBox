import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../net/lume_http.dart';
import '../net/lume_net.dart';
import '../net/network_queue.dart';
import '../util/lume_log.dart';
import 'reading_store.dart';

/// 图片管线：网络 → 板块磁盘缓存 → 解码 → 内存缓存。
///
/// 四段都可释放，且释放是**页面的责任**：每个用到图片的页面各持一个实例，
/// 在 `dispose()` 里调用 [dispose]。释放动作包含三件事：
/// 1. 关闭 HTTP 客户端——在飞请求被就地取消（不计入失败日志）；
/// 2. 清空内存缓存——解码后的 [ui.Image] 逐个 dispose，位图内存立刻归还；
/// 3. 拒绝后续调用——等待中的请求收到空结果，不会悬挂。
///
/// 与板块的关系：磁盘缓存目录由页面从 `ReadingLibrary.imageCacheDir` 取得，
/// 落在本板块的 `sections/<id>/reading_cache/images/` 之内，且落盘文件名由
/// [ReadingStore.cacheKey] 从 URL 推出，不含路径分隔符——写不出板块目录。
/// 内存缓存是实例级的，因此板块之间既不共享内存缓存，也不共享解码位图。
///
/// 内存策略见 [ImageMemoryCache]：按字节预算做 LRU；**正在被展示的图**与
/// **预加载窗口内的图**永不回收——前者会被画到，后者是滑动流畅度的保障。
class SectionImagePipeline {
  SectionImagePipeline({
    required this.cacheDir,
    http.Client? client,
    this.memoryBudgetBytes = defaultMemoryBudgetBytes,
    this.maxConcurrent = 6,
    this.timeout = const Duration(seconds: 20),
    this.diskCache = true,
    int maxRetries = 2,
  })  : _client = client ?? http.Client(),
        _maxRetries = maxRetries < 0 ? 0 : maxRetries,
        _memory = ImageMemoryCache(memoryBudgetBytes);

  /// 阅读器默认内存预算。漫画长图按屏宽解码，64MB 约对应十余页。
  static const int defaultMemoryBudgetBytes = 64 * 1024 * 1024;

  /// 封面等小图用的预算（书架、探索、详情页）。
  static const int thumbnailBudgetBytes = 24 * 1024 * 1024;

  /// 板块内的图片缓存目录（调用方从 ReadingLibrary.imageCacheDir 取得）。
  final String cacheDir;
  final http.Client _client;

  /// 是否使用**磁盘**缓存（读与写都算）。
  ///
  /// 默认开：封面与漫画页跨会话复用，重开不必重新下载。
  /// [diskCache] 为 false 时图片一律实取网络（内存缓存与管线复用仍在，当次会话
  /// 内滑动 / 翻页照旧命中）——**漫画板块按用户要求这样关掉了**（「把漫画版块的
  /// 图片缓存删了也不要了」）：它的 `sections/comic/reading_cache/images/` 不再
  /// 新增文件，设置 →「缓存管理」里漫画一栏也就不再涨。代价是重开同一话要重新
  /// 下载页面，这是有意的取舍。
  final bool diskCache;

  /// 解码图内存预算（字节）。
  final int memoryBudgetBytes;

  /// 同时进行的网络请求上限，避免滑动时把连接池占满。
  /// 同时下载的图片数。
  ///
  /// 4 → 6（真机反馈：漫画翻页时图片出得慢）。真正的上限仍在全局网络队列
  /// （单域名并发 2~3，图床保护），这里只是别让自己排得太保守。
  final int maxConcurrent;

  /// 单张图片的额外重试次数（不含首次）。
  ///
  /// 只重试「可能自己好」的失败：连接层异常、5xx、空响应体。
  /// 4xx（404/403）是这张图本身的问题，重试只会让翻页更慢。
  int get maxRetries => _maxRetries;
  final int _maxRetries;

  /// 单张图片的请求超时。
  final Duration timeout;

  final ImageMemoryCache _memory;

  /// URL → 在飞字节请求：同一 URL 并发只发一次。
  final Map<String, Future<Uint8List?>> _inFlightBytes =
      <String, Future<Uint8List?>>{};

  /// 缓存键 → 在飞解码：同一 URL + 解码宽度只解一次。
  final Map<String, Future<ui.Image?>> _inFlightImages =
      <String, Future<ui.Image?>>{};

  int _running = 0;
  final Queue<Completer<void>> _slots = Queue<Completer<void>>();
  bool _disposed = false;

  bool get isDisposed => _disposed;

  /// 内存缓存占用（字节）。
  int get memoryBytes => _memory.bytes;

  /// 内存缓存条目数。
  int get memoryCount => _memory.length;

  /// 内存缓存键：同一 URL 的不同解码宽度是两份不同位图。
  static String key(String url, int? targetWidth) =>
      targetWidth == null ? url : '$url@$targetWidth';

  // ------------------------------------------------------------------ 取图

  /// 取一张已解码的图片。失败（网络、解码、已释放）返回 null。
  ///
  /// **引用契约**：成功返回的图**自带一次引用**，调用方展示完必须 [release]
  /// 归还，归还前它不会被内存缓存的 LRU 回收。多个 tile 并发解码时，谁拿到图
  /// 谁先有引用，因此不会出现「刚拿到手就被别的加载挤掉」——画到已释放位图在
  /// 并发下也不可能发生。
  ///
  /// [targetWidth] 用于按显示宽度解码：漫画长图不按屏宽解码会带来几十 MB 的
  /// 位图，这是条漫场景下最容易踩的内存坑。解码不允许放大：原图比目标宽度还
  /// 小就按原尺寸解，不给长图白涨一圈内存。
  Future<ui.Image?> image(String url, {int? targetWidth}) =>
      _resolveImage(url, targetWidth: targetWidth, holdReference: true);

  /// 取图的统一入口。[holdReference] 决定是否把一次引用记在调用方账上：
  /// 展示用（widget）必须持有，预加载用（只进缓存）不持有。
  Future<ui.Image?> _resolveImage(
    String url, {
    int? targetWidth,
    required bool holdReference,
  }) {
    final trimmed = url.trim();
    if (trimmed.isEmpty || _disposed) return Future<ui.Image?>.value();
    final cacheKey = key(trimmed, targetWidth);
    final cached = _memory.get(cacheKey);
    if (cached != null) {
      if (holdReference) _memory.acquire(cacheKey);
      return Future<ui.Image?>.value(cached);
    }
    final existing = _inFlightImages[cacheKey];
    final request = existing ?? _startDecode(trimmed, targetWidth, cacheKey);
    if (!holdReference) return request;
    // 在飞请求是共享的，引用必须各自记账：谁 await，谁的账上多一次引用。
    return request.then((image) {
      if (image != null) _memory.acquire(cacheKey);
      return image;
    });
  }

  /// 发起一次解码并登记在飞表（同一 URL + 解码宽度只解一次）。
  Future<ui.Image?> _startDecode(
    String url,
    int? targetWidth,
    String cacheKey,
  ) {
    final request = _decode(url, targetWidth, cacheKey);
    _inFlightImages[cacheKey] = request;
    return request.whenComplete(() => _inFlightImages.remove(cacheKey));
  }

  /// 取原始字节（保存图片、解码前的缓存写入都走这里）。
  Future<Uint8List?> bytes(String url) {
    final trimmed = url.trim();
    if (trimmed.isEmpty || _disposed) return Future<Uint8List?>.value();
    final existing = _inFlightBytes[trimmed];
    if (existing != null) return existing;
    final request = _loadBytes(trimmed);
    _inFlightBytes[trimmed] = request;
    return request.whenComplete(() => _inFlightBytes.remove(trimmed));
  }

  /// 取原始字节但**不落缓存**（批量下载用）。
  ///
  /// 批量下载的字节直接写进用户导出目录；如果先经 [bytes] 落一份到图片缓存，
  /// 同一张图就会在缓存与导出目录里各存一份，整部作品下完等于双倍占用。
  /// 除此之外走的仍是同一条下载通路（全局队列 / 并发闸门 / 超时）。
  Future<Uint8List?> fetch(String url) {
    final trimmed = url.trim();
    if (trimmed.isEmpty || _disposed) return Future<Uint8List?>.value();
    return _download(trimmed);
  }

  /// 预加载一批图片（阅读器前后 N 张）。结果只进缓存，不返回给调用方。
  /// 预加载失败只记日志：它属于「提前准备」，不该打断阅读。
  void preload(Iterable<String> urls, {int? targetWidth}) {
    for (final url in urls) {
      unawaited(_preloadOne(url, targetWidth));
    }
  }

  /// 声明预加载窗口：窗口内的图钉住不回收；窗口外的图在无引用时立刻回收，
  /// 或随预算被 LRU 淘汰。滑动时每次窗口变化调用它即可。
  void retain(Iterable<String> urls, {int? targetWidth}) =>
      _memory.retain(urls.map((url) => key(url.trim(), targetWidth)).toSet());

  /// 登记一次展示引用（widget 挂载时调用）。
  void acquire(String url, {int? targetWidth}) =>
      _memory.acquire(key(url.trim(), targetWidth));

  /// 释放一次展示引用（widget 卸载时调用）。
  void release(String url, {int? targetWidth}) =>
      _memory.release(key(url.trim(), targetWidth));

  // ------------------------------------------------------------------ 释放

  /// 关闭客户端、取消在飞请求、清空内存缓存并拒绝后续调用。可重复调用。
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    // 取消在飞请求：关闭客户端是 package:http 提供的取消入口。
    try {
      _client.close();
    } catch (error, stackTrace) {
      LumeLog.error(error, stackTrace);
    }
    _drainSlots();
    _inFlightBytes.clear();
    _inFlightImages.clear();
    _memory.clear();
  }

  // ------------------------------------------------------------------ 内部

  Future<void> _preloadOne(String url, int? targetWidth) async {
    // 预加载不持有引用：图只进缓存，随时可以被预算回收。
    final loaded = await _resolveImage(
      url,
      targetWidth: targetWidth,
      holdReference: false,
    );
    if (loaded == null && !_disposed) {
      LumeLog.warn('预加载未命中: $url');
    }
  }

  Future<ui.Image?> _decode(
    String url,
    int? targetWidth,
    String cacheKey,
  ) async {
    final data = await bytes(url);
    if (data == null || _disposed) return null;
    try {
      final codec = await ui.instantiateImageCodec(
        data,
        targetWidth: targetWidth,
        // 原图比目标宽度小就按原尺寸解：长条图不会被放大后白占内存。
        allowUpscaling: false,
      );
      final frame = await codec.getNextFrame();
      final image = frame.image;
      codec.dispose();
      if (_disposed) {
        image.dispose();
        return null;
      }
      // 入库时的淘汰会跳过刚插入的这一张：它马上就要交给调用方，不能被自己挤掉。
      _memory.put(cacheKey, image);
      return image;
    } catch (error) {
      LumeLog.warn('图片解码失败: $url ($error)');
      return null;
    }
  }

  /// 字节来源顺序：磁盘缓存 → 网络。网络结果落盘，跨会话复用。
  ///
  /// [diskCache] 为 false 的板块（当前是漫画）直接走网络：不读盘也不落盘，
  /// 目录里不会因为看漫画而多出文件。
  ///
  /// 缓存判定用**同步** `stat`（`existsSync` / `lengthSync`）：这两个只是元数据
  /// 系统调用（微秒级），而一屏封面也就几十次。**不用异步版**是踩过坑的：
  /// `flutter_test` 的测试体跑在假时钟里，真实文件 IO 的完成回调等不到，
  /// 读缓存这条路径会把整个用例挂死（comic_reader 全套由绿变红）。
  Future<Uint8List?> _loadBytes(String url) async {
    if (!diskCache) return _download(url);
    final file = File(_diskPath(url));
    try {
      if (file.existsSync() && file.lengthSync() > 0) {
        return await file.readAsBytes();
      }
    } catch (error) {
      LumeLog.warn('图片缓存读取失败: $url ($error)');
    }
    final downloaded = await _download(url);
    if (downloaded == null) return null;
    try {
      file.parent.createSync(recursive: true);
      await file.writeAsBytes(downloaded, flush: false);
    } catch (error) {
      // 落盘失败不影响本次显示。
      LumeLog.warn('图片缓存写入失败: $url ($error)');
    }
    return downloaded;
  }

  Future<Uint8List?> _download(String url) async {
    final allowed = await _acquireSlot();
    if (allowed != true || _disposed) return null;
    try {
      for (var attempt = 0; attempt <= _maxRetries; attempt++) {
        if (_disposed) return null;
        final outcome = await _fetchOnce(url);
        if (outcome.bytes != null) return outcome.bytes;
        if (!outcome.retryable || attempt == _maxRetries) break;
        // 退避：200ms、400ms。图片是**可见内容**，等太久不如让用户先看到缺口
        // 再自己重试——因此重试次数刻意少（默认 2）。
        await Future<void>.delayed(Duration(milliseconds: 200 * (attempt + 1)));
      }
      return null;
    } finally {
      _releaseSlot();
    }
  }

  /// 取一次图片字节，并回报「重试有没有意义」。
  Future<({Uint8List? bytes, bool retryable})> _fetchOnce(String url) async {
    try {
      // 图片同样走全局网络队列：单域名并发（2~3）保护图床，429/503 自动退避。
      // 队列管「什么时候发」，这里只管「拿到字节后怎么用」。
      final response = await LumeNet.queue.send(
        NetworkRequest(
          url: url,
          headers: <String, String>{
            'User-Agent': LumeNet.settings.userAgent.trim().isEmpty
                ? LumeHttp.defaultUserAgent
                : LumeNet.settings.userAgent.trim(),
          },
          source: '图片缓存',
          proxy: LumeNet.settings.proxy,
        ),
      );
      if (_disposed) return (bytes: null, retryable: false);
      final code = response.statusCode;
      if (code >= 200 && code < 300) {
        final bytes = response.body;
        if (bytes.isEmpty) {
          LumeLog.warn('图片响应为空: $url');
          return (bytes: null, retryable: true);
        }
        return (bytes: Uint8List.fromList(bytes), retryable: false);
      }
      // 4xx 是「这张图本身有问题」（链接失效 / 防盗链），重试不会变好。
      final retryable = code < 400 || code >= 500;
      LumeLog.warn('图片请求失败($code${retryable ? '，将重试' : '，不重试'}): $url');
      return (bytes: null, retryable: retryable);
    } on Object catch (error) {
      // 管线已释放导致的请求中断不算错误，也不值得重试。
      if (_disposed) return (bytes: null, retryable: false);
      LumeLog.warn('图片请求异常(将重试): $url ($error)');
      return (bytes: null, retryable: true);
    }
  }

  /// 并发闸门：最多 [maxConcurrent] 个网络请求同时在跑。
  Future<bool?> _acquireSlot() async {
    if (_disposed) return null;
    if (_running < maxConcurrent) {
      _running++;
      return true;
    }
    final waiter = Completer<void>();
    _slots.add(waiter);
    await waiter.future;
    if (_disposed) return null;
    _running++;
    return true;
  }

  void _releaseSlot() {
    if (_slots.isNotEmpty) {
      // 把名额直接转交给下一个等待者。
      _slots.removeFirst().complete();
    } else {
      _running = _running > 0 ? _running - 1 : 0;
    }
  }

  /// 唤醒全部等待者，避免页面退出后仍有请求悬挂。
  void _drainSlots() {
    while (_slots.isNotEmpty) {
      _slots.removeFirst().complete();
    }
    _running = 0;
  }

  /// 落盘路径：板块目录 + 由 URL 推出的十六进制文件名。
  String _diskPath(String url) =>
      p.join(cacheDir, '${ReadingStore.cacheKey(url)}.img');

  /// 某张图的磁盘缓存文件路径（与 [_diskPath] 同一套规则，供测试与排障定位）。
  @visibleForTesting
  String cachePathFor(String url) => _diskPath(url.trim());
}

/// 解码图的内存缓存：按字节预算做 LRU，带引用计数与钉住集合。
///
/// 三种状态共同决定一张图能否被回收：
/// - **引用中**（调用方正在展示，[acquire] 未 [release]）永不回收，
///   否则会画到已释放的位图；
/// - **钉住**（落在预加载窗口内）不回收，滑动时才能立刻命中；
/// - 其余按最近使用顺序（[get] 命中即置为最近）淘汰，直到回到预算之内。
///
/// 还有一条硬约束：**刚插入的那一张不会被它自己触发的那次淘汰回收**——
/// 它正要交给调用方，如果被挤掉，调用方拿到的是已释放的位图（并发加载时
/// 曾会真的发生）。保护范围只限这一次淘汰，之后它要么被引用（安全），
/// 要么成为普通的可淘汰项。
///
/// 淘汰时对 [ui.Image] 调用 `dispose()`，位图内存同步归还。
class ImageMemoryCache {
  ImageMemoryCache(this.budgetBytes);

  /// 字节预算。<= 0 表示不限制（测试用）。
  final int budgetBytes;

  final LinkedHashMap<String, _CacheEntry> _entries =
      LinkedHashMap<String, _CacheEntry>();

  int _bytes = 0;
  bool _closed = false;

  int get bytes => _bytes;

  int get length => _entries.length;

  ui.Image? get(String key) {
    final entry = _entries[key];
    if (entry == null) return null;
    // 命中即提到队尾（最近使用），LRU 由插入顺序表达。
    _entries
      ..remove(key)
      ..[key] = entry;
    return entry.image;
  }

  void put(String key, ui.Image image) {
    if (_closed) {
      image.dispose();
      return;
    }
    _remove(key);
    final entry = _CacheEntry(image);
    _entries[key] = entry;
    _bytes += entry.bytes;
    // 跳过刚插入的这一张：它马上要交给调用方。
    _trim(protect: key);
  }

  void acquire(String key) => _entries[key]?.refs++;

  void release(String key) {
    final entry = _entries[key];
    if (entry == null) return;
    if (entry.refs > 0) entry.refs--;
    _trim();
  }

  void releaseAll() {
    for (final entry in _entries.values) {
      entry.refs = 0;
    }
    _trim();
  }

  void retain(Set<String> keys) {
    for (final entry in _entries.entries) {
      entry.value.pinned = keys.contains(entry.key);
    }
    _trim();
  }

  /// 清空全部缓存，逐个释放位图。
  void clear() {
    _closed = true;
    for (final entry in _entries.values) {
      entry.dispose();
    }
    _entries.clear();
    _bytes = 0;
  }

  /// 按预算淘汰：[protect] 指定的键在这次淘汰中跳过（用于「刚插入、正要交给
  /// 调用方」的那一张）。
  void _trim({String? protect}) {
    if (budgetBytes <= 0 || _bytes <= budgetBytes) return;
    for (final key in _entries.keys.toList(growable: false)) {
      if (_bytes <= budgetBytes) break;
      if (key == protect) continue;
      final entry = _entries[key]!;
      if (entry.refs > 0 || entry.pinned) continue;
      _entries.remove(key);
      _bytes -= entry.bytes;
      entry.dispose();
    }
  }

  void _remove(String key) {
    final entry = _entries.remove(key);
    if (entry == null) return;
    _bytes -= entry.bytes;
    entry.dispose();
  }
}

class _CacheEntry {
  _CacheEntry(this.image) : bytes = image.width * image.height * 4;

  final ui.Image image;

  /// 位图字节估算：宽 × 高 × 4（RGBA）。
  final int bytes;

  int refs = 0;
  bool pinned = false;

  void dispose() {
    try {
      image.dispose();
    } on Object catch (error, stackTrace) {
      LumeLog.error(error, stackTrace);
    }
  }
}
