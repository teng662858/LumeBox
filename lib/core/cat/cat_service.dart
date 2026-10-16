import 'dart:async';

import '../session/privacy_settings.dart';

import '../source/source_subscription_sync.dart';
import '../session/section.dart';

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../util/lume_log.dart';

String catText(Object? value) => value == null ? '' : '$value';
Map<String, dynamic> catMap(Object? value) =>
    value is Map ? value.map((key, value) => MapEntry('$key', value)) : {};
List<Map<String, dynamic>> catMaps(Object? value) =>
    value is List ? value.whereType<Map>().map(catMap).toList() : [];

class CatSubscription {
  CatSubscription({
    required this.id,
    required this.name,
    required this.url,
    this.hash = '',
    this.configHash = '',
    this.enabled = true,
    this.automatic = true,
    this.checked = 0,
    this.error = '',
    this.sites = const [],
  });
  final String id;
  String name, url, hash, configHash, error;
  bool enabled, automatic;
  int checked;
  List<CatSite> sites;
  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'url': url,
    'hash': hash,
    'configHash': configHash,
    'enabled': enabled,
    'automatic': automatic,
    'checked': checked,
    'error': error,
    'sites': sites.map((site) => site.toJson()).toList(),
  };
  factory CatSubscription.fromJson(Map<String, dynamic> value) {
    final id = catText(value['id']);
    return CatSubscription(
      id: id,
      name: catText(value['name']),
      url: catText(value['url']),
      hash: catText(value['hash']),
      configHash: catText(value['configHash']),
      enabled: value['enabled'] != false,
      automatic: value['automatic'] != false,
      checked: (value['checked'] as num?)?.toInt() ?? 0,
      error: catText(value['error']),
      sites: catMaps(value['sites'])
          .map((raw) => CatSite.fromJson(id, raw))
          .toList(),
    );
  }
}

class CatSite {
  const CatSite({
    required this.subscriptionId,
    required this.key,
    required this.name,
    required this.api,
    this.kind = 'video',
    this.ext = '',
    this.searchable = true,
    this.iconUrl = '',
    this.siteUrl = '',
  });
  final String subscriptionId, key, name, api, kind;
  final Object? ext;
  final bool searchable;
  final String iconUrl, siteUrl;
  String get id => '$subscriptionId|$kind|$key';
  Map<String, dynamic> toJson() => {
    'key': key,
    'name': name,
    'api': api,
    'kind': kind,
    'ext': ext,
    'searchable': searchable,
    if (iconUrl.isNotEmpty) 'icon': iconUrl,
    if (siteUrl.isNotEmpty) 'siteUrl': siteUrl,
  };
  factory CatSite.fromJson(
    String subscriptionId,
    Map<String, dynamic> raw, {
    String? kind,
  }) {
    final key = catText(raw['key']).replaceFirst(RegExp(r'^nodejs_'), '');
    var api = catText(raw['api']);
    if (api.startsWith('node:')) api = api.substring(5);
    if (api.startsWith('http')) {
      final uri = Uri.parse(api);
      api = '${uri.path}${uri.hasQuery ? '?${uri.query}' : ''}';
    }
    if (api.isEmpty) {
      api = '/spider/${Uri.encodeComponent(key)}/${raw['type'] ?? 3}';
    }
    if (!api.startsWith('/')) api = '/$api';
    return CatSite(
      subscriptionId: subscriptionId,
      key: key,
      name: catText(raw['name']).isEmpty ? key : catText(raw['name']),
      api: api,
      kind: kind ?? catText(raw['kind']),
      ext: raw['ext'] ?? '',
      searchable: raw['searchable'] != false && raw['searchable'] != 0,
      iconUrl: _publicUrl(raw['icon'] ?? raw['logo']),
      siteUrl: _publicUrl(raw['siteUrl'] ?? raw['home'] ?? raw['url']),
    );
  }
  static String _publicUrl(Object? value) {
    final uri = Uri.tryParse(catText(value));
    return uri != null &&
            {'https', 'http'}.contains(uri.scheme) &&
            uri.host.isNotEmpty &&
            uri.userInfo.isEmpty
        ? uri.toString()
        : '';
  }

  static List<CatSite> parseConfig(
    String subscriptionId,
    Map<String, dynamic> payload,
  ) {
    final root = payload['data'] is Map ? catMap(payload['data']) : payload;
    final result = <CatSite>[];
    for (final kind in ['video', 'comic', 'novel', 'live']) {
      final section = catMap(root[kind]);
      final sites = section['sites'];
      final rawSites = sites is Map ? sites['list'] : sites;
      for (final raw in catMaps(rawSites)) {
        if (raw['enable'] == false || raw['enabled'] == false) continue;
        final site = CatSite.fromJson(subscriptionId, raw, kind: kind);
        if (site.key.isNotEmpty && !result.any((old) => old.id == site.id)) {
          result.add(site);
        }
      }
    }
    return result;
  }
}

/// One embedded Node runtime, independent subscription identities and data roots.
/// The bridge token stays in memory; URLs with credentials and account profiles
/// are stored in iOS Keychain rather than subscription JSON or logs.
class CatService extends ChangeNotifier {
  CatService._();
  @visibleForTesting
  CatService.testing();
  static final instance = CatService._();
  static const channel = MethodChannel('lumebox/cat_node');
  final subscriptions = <CatSubscription>[];
  final favorites = <String>{};
  final history = <Map<String, dynamic>>[];
  final _bases = <String, Uri>{};
  final _versions = <String, String>{};
  final _initialized = <String>{};
  final _waiters = <String, Completer<Uri>>{};
  final _profiles = <String, Map<String, dynamic>>{};
  final _upstreams = <String, String>{};
  final _bookmarks = <String, Map<String, dynamic>>{};
  final messages = StreamController<Map<String, dynamic>>.broadcast();
  Map<String, dynamic> playInfo = {};
  bool collectionAllowed(Map<String, dynamic> entry) {
    final id = catText(entry['site']);
    final site = subscriptions
        .expand((s) => s.sites)
        .where((s) => s.id == id)
        .firstOrNull;
    return PrivacySettings.instance.allowsSource(
      id,
      site?.name ?? catText(entry['title']),
    );
  }

  List<Map<String, dynamic>> get favoriteItems =>
      _bookmarks.values.where(collectionAllowed).toList();
  Future<void> _saving = Future.value();
  Directory? _root;
  HttpServer? _bridge;
  int? _bridgePort;
  Uri? _control;
  Future<void>? _booting;
  Future<void> _operation = Future.value();
  bool _nodeStarted = false;
  bool needsSiteSelection = false;
  String recoveryMessage = '上次猫源启动未完成，已暂停自动恢复。请手动选择站点或打开配置中心。';
  final _pendingSources = <String, int>{};

  Future<T> guardStartup<T>(
    String recordId,
    Future<T> Function() action,
  ) async {
    _pendingSources[recordId] = (_pendingSources[recordId] ?? 0) + 1;
    await save();
    try {
      return await action();
    } finally {
      final count = (_pendingSources[recordId] ?? 1) - 1;
      if (count <= 0) {
        _pendingSources.remove(recordId);
      } else {
        _pendingSources[recordId] = count;
      }
      await save();
    }
  }

  String? selectedSiteId;
  int siteColumns = 1;
  Future<void> setSiteColumns(int value) async {
    siteColumns = value.clamp(1, 2);
    await save();
  }

  String status = '';
  bool busy = false;
  final String _token = List.generate(
    32,
    (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();

  Future<void> boot() => _booting ??= _boot();
  Future<void> _boot() async {
    final base = await getApplicationSupportDirectory();
    _root = Directory('${base.path}/sections/cat/node');
    await _root!.create(recursive: true);
    SourceSubscriptionSync.attachNoticeFile(
      Section.cat,
      File('${_root!.path}/subscription-changes.txt'),
    );
    final file = File('${_root!.path}/subscriptions.json');
    if (await file.exists()) {
      try {
        final raw = catMap(jsonDecode(await file.readAsString()));
        subscriptions.addAll(
          catMaps(raw['subscriptions']).map(CatSubscription.fromJson),
        );
        favorites.addAll((raw['favorites'] as List? ?? []).map(catText));
        history.addAll(catMaps(raw['history']));
        for (final entry in catMaps(raw['bookmarks'])) {
          _bookmarks['${entry['site']}|${entry['id']}'] = entry;
        }
        selectedSiteId = raw['selectedSiteId'] as String?;
        siteColumns = ((raw['siteColumns'] as num?)?.toInt() ?? 1).clamp(1, 2);
        final unfinished = (raw['pendingSources'] as List? ?? [])
            .map(catText)
            .toSet();
        final migrateStartup =
            raw['startupRecoveryVersion'] != 1 && subscriptions.isNotEmpty;
        recoveryMessage = unfinished.isNotEmpty
            ? '上次猫源启动未完成，已暂停自动恢复。请手动选择站点或打开配置中心。'
            : catText(raw['recoveryMessage']).isNotEmpty
            ? catText(raw['recoveryMessage'])
            : '猫源宿主已更新，为避免恢复旧启动状态，请手动选择站点；原订阅与配置均已保留。';
        needsSiteSelection =
            raw['needsSiteSelection'] == true ||
            unfinished.isNotEmpty ||
            migrateStartup;
        if (needsSiteSelection) {
          selectedSiteId = null;
          for (final record in subscriptions.where(
            (r) => unfinished.contains(r.id),
          )) {
            record.error = '上次站点启动未完成，已暂停自动恢复；请手动选择站点或打开配置中心';
          }
          await save();
        }
      } catch (error) {
        LumeLog.warn('[cat] 订阅记录读取失败: $error');
      }
    }
    notifyListeners();
  }

  Future<void> save() => _saving = _saving.then(
    (_) => _save(),
    onError: (Object error, StackTrace stack) => _save(),
  );
  Future<void> _save() async {
    if (_root == null) return;
    final file = File('${_root!.path}/subscriptions.json.tmp');
    await file.writeAsString(
      jsonEncode({
        'subscriptions': subscriptions.map((s) => s.toJson()).toList(),
        'favorites': favorites.toList(),
        'history': history.take(100).toList(),
        'bookmarks': _bookmarks.values.toList(),
        'selectedSiteId': selectedSiteId,
        'siteColumns': siteColumns,
        'startupRecoveryVersion': 1,
        'needsSiteSelection': needsSiteSelection,
        'recoveryMessage': recoveryMessage,
        'pendingSources': _pendingSources.keys.toList(),
      }),
      flush: true,
    );
    await file.rename('${_root!.path}/subscriptions.json');
    notifyListeners();
  }

  Future<T> _serial<T>(Future<T> Function() action) {
    final result = _operation.then((_) => action());
    _operation = result.then<void>(
      (_) {},
      onError: (Object error, StackTrace stack) {},
    );
    return result;
  }

  Future<String?> secret(String key) =>
      channel.invokeMethod<String>('readSecret', {'key': key});
  Future<void> _saveSecret(String key, String? value) =>
      channel.invokeMethod<void>('writeSecret', {'key': key, 'value': value});

  Future<CatSubscription> add(String name, String address) => _serial(() async {
    await boot();
    final parsed = Uri.tryParse(address.trim());
    if (parsed == null ||
        !['http', 'https'].contains(parsed.scheme) ||
        !parsed.path.endsWith('.js.md5')) {
      throw const FormatException('请填写 index.js.md5 订阅地址');
    }
    final clean = parsed.replace(userInfo: '');
    final existing = subscriptions
        .where((s) => s.url == clean.toString())
        .firstOrNull;
    if (existing != null) {
      if (parsed.userInfo.isNotEmpty) {
        await _saveSecret('auth:${existing.id}', parsed.userInfo);
      }
      await _update(existing);
      await save();
      return existing;
    }
    final id = List.generate(
      16,
      (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    final record = CatSubscription(
      id: id,
      name: name.trim().isEmpty ? parsed.host : name.trim(),
      url: clean.toString(),
    );
    if (parsed.userInfo.isNotEmpty) {
      await _saveSecret('auth:$id', parsed.userInfo);
    }
    subscriptions.add(record);
    await save();
    try {
      await _update(record);
    } catch (error) {
      record.error = '$error';
      await save();
      rethrow;
    }
    await save();
    return record;
  });

  Future<void> update(CatSubscription record) => _serial(() async {
    try {
      await _update(record);
    } catch (error) {
      record.error = '$error';
      await save();
      rethrow;
    }
    await save();
  });
  Future<void> _update(CatSubscription record) async {
    record.checked = DateTime.now().millisecondsSinceEpoch;
    status = '检查 ${record.name} 更新';
    busy = true;
    notifyListeners();
    try {
      final auth = await secret('auth:${record.id}');
      final hashUri = Uri.parse(record.url);
      final indexUri = hashUri.replace(
        path: hashUri.path.replaceFirst(RegExp(r'\.md5$'), ''),
      );
      final configUri = indexUri.replace(
        path: indexUri.path.replaceFirst(RegExp(r'\.js$'), '.config.js'),
      );
      final hash = utf8
          .decode(await _download(hashUri, auth, 4096))
          .trim()
          .toLowerCase();
      if (!RegExp(r'^[0-9a-f]{32}$').hasMatch(hash)) {
        throw const FormatException('订阅校验文件不是有效 MD5');
      }
      var resolvedConfig = configUri;
      var bytes = await _download(indexUri, auth, 20 * 1024 * 1024);
      if (md5.convert(bytes).toString() != hash) {
        bytes = await _download(
          indexUri.replace(
            queryParameters: {
              ...indexUri.queryParameters,
              '_lume_refresh': '${DateTime.now().millisecondsSinceEpoch}',
            },
          ),
          auth,
          20 * 1024 * 1024,
        );
      }
      if (md5.convert(bytes).toString() != hash) {
        final fallback = verifiedBundleFallback(hashUri, hash);
        if (fallback != null) {
          final historical = await _download(fallback, null, 20 * 1024 * 1024);
          if (md5.convert(historical).toString() == hash) {
            bytes = historical;
            resolvedConfig = fallback.replace(
              path: fallback.path.replaceFirst(RegExp(r'\.js$'), '.config.js'),
            );
          }
        }
      }
      if (md5.convert(bytes).toString() != hash) {
        throw const FormatException('作者发布的程序包与 MD5 不一致，保留旧版本；请稍后更新或联系作者');
      }
      final config = await _download(resolvedConfig, auth, 2 * 1024 * 1024);
      final configHash = md5.convert(config).toString();
      try {
        final configMD5 = utf8
            .decode(
              await _download(
                resolvedConfig.replace(path: '${resolvedConfig.path}.md5'),
                auth,
                4096,
              ),
            )
            .trim()
            .toLowerCase();
        if (RegExp(r'^[0-9a-f]{32}$').hasMatch(configMD5) &&
            configMD5 != configHash) {
          throw const FormatException('配置 MD5 不一致，保留旧版本');
        }
      } on HttpException catch (error) {
        if (!error.message.contains('404')) rethrow;
      }
      final destination = Directory(
        '${_root!.path}/bundles/${record.id}/$hash-$configHash',
      );
      final indexFile = File('${destination.path}/index.js');
      final configFile = File('${destination.path}/index.config.js');
      final valid =
          await indexFile.exists() &&
          await configFile.exists() &&
          md5.convert(await indexFile.readAsBytes()).toString() == hash &&
          md5.convert(await configFile.readAsBytes()).toString() == configHash;
      if (!valid) {
        final staging = Directory(
          '${destination.path}.tmp-${DateTime.now().microsecondsSinceEpoch}',
        );
        await staging.create(recursive: true);
        try {
          await File('${staging.path}/index.js')
              .writeAsBytes(bytes, flush: true);
          await File('${staging.path}/index.config.js')
              .writeAsBytes(config, flush: true);
          if (await destination.exists()) {
            await destination.delete(recursive: true);
          }
          await staging.rename(destination.path);
        } finally {
          if (await staging.exists()) await staging.delete(recursive: true);
        }
      }
      if (record.hash != hash || record.configHash != configHash) {
        SourceSubscriptionSync.recordChange(
          Section.cat,
          record.id,
          record.name,
          record.hash.isEmpty ? '已新增' : '已更新',
        );
        for (final site in record.sites) {
          SourceSubscriptionSync.recordChange(
            Section.cat,
            site.id,
            site.name,
            '已更新',
          );
        }
      }
      record.hash = hash;
      record.configHash = configHash;
      record.checked = DateTime.now().millisecondsSinceEpoch;
      record.error = '';
    } finally {
      busy = false;
      status = '';
      notifyListeners();
    }
  }

  Future<Uint8List> _download(Uri uri, String? auth, int limit) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 20);
    try {
      var target = uri;
      for (var redirect = 0; redirect < 6; redirect++) {
        final request = await client
            .getUrl(target)
            .timeout(const Duration(seconds: 20));
        request.followRedirects = false;
        request.headers.set('User-Agent', 'LumeBox/1 CatPaw');
        request.headers.set('Cache-Control', 'no-cache');
        if (auth != null &&
            target.host == uri.host &&
            target.port == uri.port &&
            target.scheme == uri.scheme) {
          request.headers.set(
            'Authorization',
            'Basic ${base64Encode(utf8.encode(Uri.decodeComponent(auth)))}',
          );
        }
        final response = await request.close().timeout(
          const Duration(seconds: 30),
        );
        if ([301, 302, 303, 307, 308].contains(response.statusCode)) {
          final location = response.headers.value('location');
          await response.drain<void>();
          if (location == null) throw const HttpException('订阅重定向缺少地址');
          target = target.resolve(location);
          continue;
        }
        if (response.statusCode != 200) {
          throw HttpException(
            response.statusCode == 401
                ? '订阅需要有效账号密码，请在编辑地址 / 授权中填写作者提供的凭据（HTTP 401）'
                : '订阅 HTTP ${response.statusCode}',
          );
        }
        final bytes = BytesBuilder(copy: false);
        await for (final chunk in response.timeout(
          const Duration(seconds: 30),
        )) {
          bytes.add(chunk);
          if (bytes.length > limit) throw const HttpException('订阅文件超过大小限制');
        }
        return bytes.takeBytes();
      }
      throw const HttpException('订阅重定向过多');
    } finally {
      client.close(force: true);
    }
  }

  Future<void> checkUpdates() => _serial(() async {
    await boot();
    if (subscriptions.isEmpty) return;
    for (final subscription
        in subscriptions.where((s) => s.enabled && s.automatic).toList()) {
      if (DateTime.now().millisecondsSinceEpoch - subscription.checked <
          (subscription.error.isEmpty
                  ? const Duration(hours: 6)
                  : const Duration(minutes: 30))
              .inMilliseconds) {
        continue;
      }
      try {
        await _update(subscription);
      } catch (error) {
        subscription.error = '$error';
        LumeLog.warn('[cat] ${subscription.name} 更新失败，保留旧包');
      }
    }
    await save();
  });

  /// A supplier's published checksum can temporarily point to an older official snapshot.
  /// Only the exact checksum we independently verified is eligible; no integrity check is skipped.
  static Uri? verifiedBundleFallback(Uri manifest, String hash) {
    if (manifest.host == 'raw.githubusercontent.com' &&
        manifest.path ==
            '/xiaobaitulele/xptv/refs/heads/main/jstv/index.js.md5' &&
        hash == 'eae292d3319ef56fa34a57c6bc459b61') {
      return Uri.parse(
        'https://raw.githubusercontent.com/xiaobaitulele/xptv/9d15140196c4653fc3dbdc39a648eea9b627bcb8/jstv/index.js',
      );
    }
    return null;
  }

  Future<bool> hasBundle(CatSubscription record) async {
    await boot();
    if (record.hash.isEmpty || record.configHash.isEmpty) return false;
    final bundle =
        '${_root!.path}/bundles/${record.id}/${record.hash}-${record.configHash}';
    return await File('$bundle/index.js').exists() &&
        await File('$bundle/index.config.js').exists();
  }

  Future<Uri> activate(CatSubscription record) => _serial(
    () => guardStartup(record.id, () async {
      await boot();
      if (!record.enabled) throw StateError('订阅已停用');
      if (!await hasBundle(record)) await _update(record);
      final version = '${record.hash}-${record.configHash}';
      if (_versions[record.id] == version && _bases[record.id] != null) {
        return _bases[record.id]!;
      }
      busy = true;
      status = '启动 ${record.name}';
      notifyListeners();
      try {
        await _ensureBridge();
        final dataRoot = Directory('${_root!.path}/profiles/${record.id}');
        await dataRoot.create(recursive: true);
        final bundle = '${_root!.path}/bundles/${record.id}/$version';
        final spec = {
          'id': record.id,
          'index': '$bundle/index.js',
          'config': '$bundle/index.config.js',
          'dataRoot': dataRoot.path,
        };
        if (!await File('$bundle/index.js').exists()) {
          throw StateError('订阅包尚未下载，请刷新订阅');
        }
        final waiter = Completer<Uri>();
        final ready = waiter.future.timeout(const Duration(seconds: 90));
        ready.then<void>((_) {}, onError: (Object error, StackTrace stack) {});
        _waiters[record.id] = waiter;
        if (!_nodeStarted) {
          final bootstrap = File('${_root!.path}/bootstrap.js');
          await bootstrap.writeAsString(
            await rootBundle.loadString('assets/cat/bootstrap.js'),
            flush: true,
          );
          final specFile = File('${_root!.path}/runtime-spec.json');
          await specFile.writeAsString(
            jsonEncode({
              'bridgePort': _bridge!.port,
              'token': _token,
              'sources': [spec],
            }),
          );
          final cache = Directory('${_root!.path}/compile-cache');
          await cache.create(recursive: true);
          final launched = await channel.invokeMethod<bool>('start', {
            'bootstrap': bootstrap.path,
            'spec': specFile.path,
            'cache': cache.path,
          });
          if (launched != true) throw StateError('Node 已在运行，请完整关闭 App 后重新打开');
          _nodeStarted = true;
        } else {
          if (_bases.containsKey(record.id)) {
            await request(
              _control!,
              '/ctl/stop',
              body: {'id': record.id},
              authenticated: true,
            );
          }
          _bases.remove(record.id);
          _versions.remove(record.id);
          await request(
            _control!,
            '/ctl/source',
            body: spec,
            authenticated: true,
          );
        }
        final base = await ready;
        _bases[record.id] = base;
        _versions[record.id] = version;
        final config = await request(base, '/config');
        record.sites = CatSite.parseConfig(record.id, config);
        record.error = '';
        _initialized.removeWhere((id) => id.startsWith('${record.id}|'));
        await save();
        return base;
      } catch (error) {
        record.error = '$error';
        await save();
        rethrow;
      } finally {
        _waiters.remove(record.id);
        busy = false;
        status = '';
        notifyListeners();
      }
    }),
  );
  Future<void> _ensureBridge() async {
    if (_bridge != null) return;
    _bridge = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      _bridgePort ?? 0,
    );
    _bridgePort = _bridge!.port;
    _bridge!.listen((request) => unawaited(_handleBridge(request)));
  }

  Future<void> _handleBridge(HttpRequest request) async {
    try {
      if (request.uri.path != '/msg' ||
          request.headers.value('x-catvod-token') != _token) {
        request.response.statusCode = 403;
        await request.response.close();
        return;
      }
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in request.timeout(const Duration(seconds: 5))) {
        bytes.add(chunk);
        if (bytes.length > 1024 * 1024) throw const FormatException('桥消息过大');
      }
      final message = catMap(jsonDecode(utf8.decode(bytes.takeBytes())));
      final action = catText(message['action']);
      final opt = catMap(message['opt']);
      final id = catText(opt['id']).isNotEmpty
          ? catText(opt['id'])
          : (request.headers.value('x-lume-cat-source') ?? '');
      Object reply = {};
      if (action == 'getPlayInfo') reply = playInfo;
      if (['toast', 'openInternalWebview', 'dialog'].contains(action)) {
        messages.add({'action': action, 'sourceId': id, ...opt});
      }
      if (action == 'controlReady') {
        _control = Uri.tryParse(catText(opt['address']));
      }
      if (action == 'sourceStarted' || action == 'serverStarted') {
        final base = Uri.tryParse(catText(opt['address']));
        final waiter = _waiters[id];
        if (base != null &&
            base.host == '127.0.0.1' &&
            subscriptions.any((s) => s.id == id)) {
          _bases[id] = base;
        }
        if (base != null &&
            base.host == '127.0.0.1' &&
            waiter != null &&
            !waiter.isCompleted) {
          waiter.complete(base);
        }
      }
      if (action == 'sourceError' || action == 'nodeError') {
        final record = subscriptions.where((r) => r.id == id).firstOrNull;
        if (record != null) {
          record.error = catText(opt['message']);
          await save();
        }
        final waiter = _waiters[id] ?? _waiters.values.firstOrNull;
        if (waiter != null && !waiter.isCompleted) {
          waiter.completeError(StateError(catText(opt['message'])));
        }
      }
      if (action == 'saveProfile' || action == 'queryProfile') {
        var profiles = _profiles[id] ??= catMap(
          jsonDecode(await secret('profile:$id') ?? '{}'),
        );
        if (action == 'saveProfile') {
          profiles = _profiles[id] = opt;
          await _saveSecret('profile:$id', jsonEncode(profiles));
        }
        reply = profiles;
      }
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode(reply));
      await request.response.close();
    } catch (error) {
      request.response.statusCode = 500;
      await request.response.close();
      LumeLog.warn('[cat] 宿主桥消息处理失败');
    }
  }

  Future<Map<String, dynamic>> request(
    Uri base,
    String path, {
    Map<String, dynamic>? body,
    bool authenticated = false,
  }) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    try {
      final uri = base.resolve(path);
      final request = await client
          .openUrl(body == null ? 'GET' : 'POST', uri)
          .timeout(const Duration(seconds: 15));
      request.headers.contentType = ContentType.json;
      request.headers.set('User-Agent', 'okhttp/3.15.0');
      if (authenticated) request.headers.set('X-CatVod-Token', _token);
      if (body != null) request.write(jsonEncode(body));
      final response = await request.close().timeout(
        const Duration(seconds: 90),
      );
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in response.timeout(const Duration(seconds: 30))) {
        bytes.add(chunk);
        if (bytes.length > 8 * 1024 * 1024) {
          throw const FormatException('站点响应过大');
        }
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw HttpException('猫源接口 HTTP ${response.statusCode}');
      }
      Object? decoded = jsonDecode(utf8.decode(bytes.takeBytes()));
      if (decoded is String) decoded = jsonDecode(decoded);
      if (decoded is! Map) throw const FormatException('猫源接口返回了非对象数据');
      final payload = catMap(decoded);
      final failure = payload['error'];
      if (payload['success'] == false ||
          (failure is String && failure.isNotEmpty)) {
        throw StateError(
          '猫源接口失败：${payload['message'] ?? payload['msg'] ?? failure ?? '未知原因'}',
        );
      }
      return payload;
    } finally {
      client.close(force: true);
    }
  }

  Future<Map<String, dynamic>> call(
    CatSite site,
    String operation, [
    Map<String, dynamic> body = const {},
  ]) async {
    if (!PrivacySettings.instance.allowsSource(site.id, site.name)) {
      throw StateError('成人内容已隐藏，请在隐私设置中开启');
    }
    final record = subscriptions.firstWhere((s) => s.id == site.subscriptionId);
    return guardStartup(record.id, () async {
      final base = _versions[record.id] == '${record.hash}-${record.configHash}'
          ? (_bases[record.id] ?? await activate(record))
          : await activate(record);
      final api = Uri.parse(site.api);
      String endpoint(String operation) => api
          .replace(
            path: '${api.path.replaceFirst(RegExp(r'/+$'), '')}/$operation',
          )
          .toString();
      if (!_initialized.contains(site.id) && operation != 'init') {
        try {
          final init = await request(
            base,
            endpoint('init'),
            body: {'ext': site.ext},
          );
          final upstream = catText(init['siteUrl'] ?? init['url']);
          if (upstream.startsWith('http')) _upstreams[site.id] = upstream;
          _initialized.add(site.id);
        } on HttpException catch (error) {
          if (error.message.contains('404')) {
            _initialized.add(site.id);
          } else {
            rethrow;
          }
        }
      }
      return request(base, endpoint(operation), body: body);
    });
  }

  Uri? baseFor(CatSite site) => _bases[site.subscriptionId];
  Future<void> refreshSites(CatSubscription record) async {
    try {
      final base = await activate(record);
      record.sites = CatSite.parseConfig(
        record.id,
        await request(base, '/config'),
      );
      if (record.sites.isEmpty) throw StateError('配置接口没有返回可用站点，请打开站点配置检查');
      if (SourceSubscriptionSync.notice(Section.cat, record.id) != null) {
        for (final site in record.sites) {
          SourceSubscriptionSync.recordChange(
            Section.cat,
            site.id,
            site.name,
            '已更新',
          );
        }
      }
      record.error = '';
      _initialized.removeWhere((id) => id.startsWith('${record.id}|'));
      await save();
    } catch (error) {
      record.error = '$error';
      await save();
      rethrow;
    }
  }

  Future<Uri> configurationUrl(CatSubscription record) async {
    final base = await activate(record);
    final client = HttpClient();
    try {
      for (final path in ['/website', '/website/index.html', '/']) {
        final uri = base.resolve(path);
        final response = await (await client.getUrl(uri))
            .close()
            .timeout(const Duration(seconds: 8));
        final success =
            response.statusCode == 200 &&
            (response.headers.contentType?.mimeType.contains('html') ?? false);
        await response.drain<void>();
        if (success) return uri;
      }
      throw StateError('这个订阅没有提供网页配置中心，请选择它的配置站点');
    } finally {
      client.close(force: true);
    }
  }

  Map<String, String>? imageHeadersFor(CatSite site) =>
      _upstreams[site.id] == null ? null : {'Referer': _upstreams[site.id]!};
  Future<void> remove(CatSubscription record) => _serial(() async {
    if (_control != null && _bases.containsKey(record.id)) {
      await request(
        _control!,
        '/ctl/stop',
        body: {'id': record.id},
        authenticated: true,
      );
    }
    subscriptions.remove(record);
    _bases.remove(record.id);
    _versions.remove(record.id);
    await _saveSecret('auth:${record.id}', null);
    await _saveSecret('profile:${record.id}', null);
    await save();
  });
  Future<void> select(CatSite site) async {
    if (!PrivacySettings.instance.allowsSource(site.id, site.name)) return;
    needsSiteSelection = false;
    selectedSiteId = site.id;
    await save();
  }

  Future<void> toggleFavorite(CatSite site, Map<String, dynamic> item) async {
    final id = '${site.id}|${item['id']}';
    if (favorites.remove(id)) {
      _bookmarks.remove(id);
    } else {
      favorites.add(id);
      _bookmarks[id] = {...item, 'site': site.id};
    }
    await save();
  }

  Future<void> removeCollection(
    Set<String> ids, {
    required bool favorites,
  }) async {
    if (favorites) {
      this.favorites.removeAll(ids);
      _bookmarks.removeWhere((key, _) => ids.contains(key));
    } else {
      history.removeWhere(
        (entry) => ids.contains('${entry['site']}|${entry['id']}'),
      );
    }
    await save();
  }

  Future<void> remember(CatSite site, Map<String, dynamic> item) async {
    final id = catText(item['id']);
    history.removeWhere((old) => old['site'] == site.id && old['id'] == id);
    history.insert(0, {
      ...item,
      'site': site.id,
      'time': DateTime.now().millisecondsSinceEpoch,
    });
    await save();
  }

  Future<void> resume() async {
    await _serial(() async {
      if (!_nodeStarted) return;
      final previous = _bridge;
      _bridge = null;
      await previous?.close(force: true);
      await _ensureBridge();
    });
    await checkUpdates();
  }

  @visibleForTesting
  Future<void> closeForTesting() async {
    await _bridge?.close(force: true);
    _bridge = null;
    await _saving;
    await messages.close();
    super.dispose();
  }
}
