import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../reading/reading_store.dart';
import '../source/source_subscription_sync.dart';
import 'section.dart';
import 'cloud_merge.dart';

class ICloudSync extends ChangeNotifier with WidgetsBindingObserver {
  ICloudSync({this.platformSupported, this.directory});
  final bool? platformSupported;
  final Directory? directory;
  static final instance = ICloudSync();
  static const channel = MethodChannel('lumebox/icloud');
  static const files = {
    'appearance_settings.json',
    'browse_layout.json',
    'shell_settings.json',
    'floating_modules.json',
    'frosted_settings.json',
    'comic_image_tools.json',
  };
  bool automatic = false,
      includeSettings = true,
      includeSubscriptions = true,
      busy = false;
  bool get supported => platformSupported ?? Platform.isIOS;
  String status = '尚未同步';
  DateTime? lastSync;
  String _device = '', _account = '';
  Directory? _root;
  Map<String, Map<String, dynamic>> _records = {};
  Map<String, dynamic> _baseline = {};
  Future<void>? _booting, _syncing;
  Timer? _timer;
  bool _foreground = true;
  Future<void> boot() => _booting ??= _boot().catchError((Object error) {
    automatic = false;
    status = 'iCloud 初始化失败，继续使用本地数据';
    notifyListeners();
  });
  Future<void> _boot() async {
    _root = directory ?? await getApplicationSupportDirectory();
    final file = File('${_root!.path}/icloud-sync-local.json');
    if (file.existsSync()) {
      try {
        final raw = jsonDecode(file.readAsStringSync()) as Map;
        automatic = raw['automatic'] == true;
        includeSettings = raw['settings'] != false;
        includeSubscriptions = raw['subscriptions'] != false;
        _device = '${raw['device'] ?? ''}';
        _account = '${raw['account'] ?? ''}';
        lastSync = DateTime.tryParse('${raw['lastSync']}');
        _baseline = Map<String, dynamic>.from(raw['baseline'] as Map? ?? {});
        _records = CloudMerge.decode(
          CloudMerge.encode(
            (raw['records'] as Map? ?? {}).map(
              (k, v) => MapEntry('$k', Map<String, dynamic>.from(v as Map)),
            ),
          ),
        );
      } catch (_) {
        automatic = false;
        status = '本地同步状态损坏，请重新开启同步';
      }
    }
    if (!RegExp(r'^[a-f0-9]{32}$').hasMatch(_device)) {
      _device = List.generate(
        16,
        (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
      ).join();
    }
    if (supported) {
      WidgetsBinding.instance.addObserver(this);
      _schedule();
      if (automatic) unawaited(sync());
    }
  }

  void _schedule() {
    _timer?.cancel();
    if (supported && automatic && _foreground) {
      _timer = Timer.periodic(
        const Duration(minutes: 5),
        (_) => unawaited(sync()),
      );
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _schedule();
    if (_foreground && automatic) unawaited(sync());
  }

  Future<void> save() async {
    await boot();
    if (_root == null) {
      automatic = false;
      status = '同步配置不可用，继续使用本地数据';
      notifyListeners();
      return;
    }
    try {
      final file = File('${_root!.path}/icloud-sync-local.json');
      final temp = File('${file.path}.tmp');
      temp.writeAsStringSync(
        jsonEncode({
          'automatic': automatic,
          'settings': includeSettings,
          'subscriptions': includeSubscriptions,
          'device': _device,
          'account': _account,
          'lastSync': lastSync?.toIso8601String(),
          'records': _records,
          'baseline': _baseline,
        }),
        flush: true,
      );
      temp.renameSync(file.path);
      _schedule();
      notifyListeners();
    } catch (_) {
      automatic = false;
      _timer?.cancel();
      status = '同步配置保存失败，继续使用本地数据';
      notifyListeners();
    }
  }

  Future<void> setAutomatic(bool enabled) async {
    await boot();
    automatic = enabled;
    await save();
    if (enabled && automatic) await sync(acceptAccount: true);
  }

  Future<void> check() async {
    await boot();
    if (!supported) {
      status = '仅 iOS 支持 iCloud 同步';
      notifyListeners();
      return;
    }
    try {
      await channel
          .invokeMapMethod<String, dynamic>('status')
          .timeout(const Duration(seconds: 30));
      status = 'iCloud 可用';
    } catch (error) {
      status = error is PlatformException
          ? error.message ?? 'iCloud 不可用'
          : 'iCloud 检查超时或不可用';
    }
    notifyListeners();
  }

  bool _allowed(String raw) {
    try {
      final key = jsonDecode(raw);
      if (key is! List || key.length != 3 || key.any((v) => v is! String)) {
        return false;
      }
      if (key[0] == 'global') {
        return includeSettings && key[1] == 'file' && files.contains(key[2]);
      }
      if (!Section.values.any((s) => s.id == key[0])) return false;
      return key[1] == 'library_item' ||
          key[1] == 'reading_progress' ||
          key[1] == 'reading_setting' &&
              (key[2] == 'favorites.folders' ||
                  includeSettings &&
                      ReadingStore.cloudSettingAllowed(key[2])) ||
          includeSubscriptions && key[1] == 'subscription' && _safeUrl(key[2]);
    } catch (_) {
      return false;
    }
  }

  static bool _safeUrl(String text) {
    final uri = Uri.tryParse(text);
    return uri != null &&
        ['http', 'https'].contains(uri.scheme) &&
        uri.host.isNotEmpty &&
        uri.userInfo.isEmpty &&
        !uri.queryParameters.keys.any(
          (key) => RegExp(
            r'token|key|auth|password|secret',
            caseSensitive: false,
          ).hasMatch(key),
        );
  }

  static Object? _safe(Object? value) {
    if (value is Map) {
      return {
        for (final entry in value.entries)
          if (!RegExp(
            r'key|token|password|secret|cookie|authorization|endpoint|proxy|credential',
            caseSensitive: false,
          ).hasMatch('${entry.key}'))
            '${entry.key}': _safe(entry.value),
      };
    }
    if (value is List) return value.map(_safe).toList();
    if (value is String && value.startsWith('http') && !_safeUrl(value)) {
      return null;
    }
    return value;
  }

  Future<Map<String, dynamic>> _snapshot() async {
    final result = <String, dynamic>{};
    for (final section in Section.values) {
      final store = await ReadingStore.open(section);
      for (final entry
          in store.cloudRecords(includeSettings: includeSettings).entries) {
        final row = entry.value;
        if (row is Map) {
          final ids = [row['item_id'], row['chapter_id']].whereType<String>();
          if (ids.any((id) => id.startsWith('http') && !_safeUrl(id))) continue;
          final copy = Map<String, Object?>.from(row);
          if (copy['cover'] is String &&
              (copy['cover'] as String).startsWith('http') &&
              !_safeUrl(copy['cover'] as String)) {
            copy['cover'] = null;
          }
          result[entry.key] = copy;
        }
      }
      if (includeSubscriptions && section != Section.cat) {
        final service = await SourceSubscriptionSync.open(section);
        for (final sub in service.subscriptions) {
          if (_safeUrl(sub.url)) {
            result[jsonEncode([section.id, 'subscription', sub.url])] = {
              'url': sub.url,
              'enabled': sub.enabled,
            };
          }
        }
      }
    }
    if (includeSettings) {
      for (final name in files) {
        final file = File('${_root!.path}/$name');
        if (file.existsSync()) {
          result[jsonEncode(['global', 'file', name])] = _safe(
            jsonDecode(file.readAsStringSync()),
          );
        }
      }
    }
    return result;
  }

  Future<void> sync({bool acceptAccount = false}) =>
      _syncing ??= _run(acceptAccount).whenComplete(() => _syncing = null);
  Future<void> _run(bool acceptAccount) async {
    await boot();
    if (!supported) {
      status = '仅 iOS 支持 iCloud 同步';
      notifyListeners();
      return;
    }
    if (_root == null) {
      status = '同步未就绪，继续使用本地数据';
      notifyListeners();
      return;
    }
    busy = true;
    status = '正在同步…';
    notifyListeners();
    try {
      final remote = await channel
          .invokeMapMethod<String, dynamic>('read')
          .timeout(const Duration(seconds: 45));
      final account = remote?['account'];
      if (account is! String ||
          account.isEmpty ||
          remote?['documents'] is! List) {
        throw const FormatException('iCloud 返回内容无效');
      }
      if (_account.isNotEmpty && _account != account) {
        if (!acceptAccount) automatic = false;
        if (!acceptAccount) {
          await save();
          throw StateError('iCloud 账号已变化，自动同步已暂停；请确认后重新开启');
        }
        _records = {};
        _baseline = {};
      }
      _account = account;
      final documents = <Map<String, Map<String, dynamic>>>[];
      for (final raw in remote!['documents'] as List) {
        if (raw is! String) throw const FormatException('云端快照无效');
        documents.add(
          CloudMerge.decode(raw)..removeWhere((key, _) => !_allowed(key)),
        );
      }
      final local = await _snapshot();
      final own = Map<String, Map<String, dynamic>>.from(_records)
        ..removeWhere((key, _) => !_allowed(key));
      var stamp = DateTime.now().microsecondsSinceEpoch;
      for (final record in [
        ...own.values,
        ...documents.expand((doc) => doc.values),
      ]) {
        stamp = max(stamp, (record['stamp'] as int) + 1);
      }
      final firstContact = _records.isEmpty && _baseline.isEmpty;
      final remoteRecords = CloudMerge.merge(documents);
      for (final key in {...local.keys, ..._baseline.keys.where(_allowed)}) {
        if (firstContact && remoteRecords.containsKey(key)) continue;
        if (jsonEncode(local[key]) != jsonEncode(_baseline[key])) {
          own[key] = {'stamp': stamp++, 'device': _device, 'value': local[key]};
        }
      }
      final merged = CloudMerge.merge([...documents, own]);
      // Validate every incoming reading row before cloud write or local mutation.
      final validation = <String, Map<String, Object?>>{};
      for (final entry in merged.entries) {
        final key = (jsonDecode(entry.key) as List).cast<String>();
        final payload = entry.value['value'];
        if (key[0] == 'global' && payload != null && payload is! Map) {
          throw const FormatException('云端设置格式无效');
        }
        if (key[1] == 'subscription' &&
            payload != null &&
            (payload is! Map ||
                payload['url'] != key[2] ||
                payload['enabled'] is! bool)) {
          throw const FormatException('云端订阅格式无效');
        }
        if ([
          'library_item',
          'reading_progress',
          'reading_setting',
        ].contains(key[1])) {
          validation.putIfAbsent(key[0], () => {})[entry.key] =
              entry.value['value'];
        }
      }
      for (final section in Section.values) {
        final rows = validation[section.id];
        if (rows != null) {
          (await ReadingStore.open(section))
              .applyCloudRecords(rows, validateOnly: true);
        }
      }
      final uploaded = await channel
          .invokeMethod<bool>('write', {
            'device': _device,
            'account': account,
            'text': CloudMerge.encode(merged),
          })
          .timeout(const Duration(seconds: 45));
      if (uploaded != true) throw StateError('iCloud 未接受同步快照');
      // Preserve a local recovery snapshot before applying any cloud records.
      File('${_root!.path}/icloud-before-sync.json')
          .writeAsStringSync(jsonEncode(local), flush: true);
      final bySection = <String, Map<String, Object?>>{};
      for (final entry in merged.entries) {
        final key = (jsonDecode(entry.key) as List).cast<String>();
        final value = entry.value['value'];
        if (key[1] == 'library_item' ||
            key[1] == 'reading_progress' ||
            key[1] == 'reading_setting') {
          bySection.putIfAbsent(key[0], () => {})[entry.key] = value;
        } else if (key[0] == 'global' && value is Map) {
          if (jsonEncode(local[entry.key]) == jsonEncode(value)) continue;
          final file = File('${_root!.path}/${key[2]}');
          final old = file.existsSync()
              ? jsonDecode(file.readAsStringSync())
              : {};
          final temporary = File('${file.path}.icloud');
          temporary.writeAsStringSync(
            jsonEncode(_mergeConfig(old, _safe(value))),
            flush: true,
          );
          temporary.renameSync(file.path);
        } else if (key[1] == 'subscription') {
          final section = Section.values.firstWhere((s) => s.id == key[0]);
          if (section == Section.cat) continue;
          await SourceSubscriptionSync.maintenance(section, () async {
            final service = await SourceSubscriptionSync.open(section);
            if (jsonEncode(local[entry.key]) == jsonEncode(value)) return;
            if (value == null) {
              service.subscriptions.removeWhere((sub) => sub.url == key[2]);
            } else {
              if (value is! Map || value['url'] != key[2]) {
                throw const FormatException('云端订阅无效');
              }
              final old = service.subscriptions
                  .where((sub) => sub.url == key[2])
                  .firstOrNull;
              if (old == null) {
                service.subscriptions.add(
                  SavedSourceSubscription(
                    key[2],
                    enabled: value['enabled'] != false,
                  ),
                );
              } else {
                old.enabled = value['enabled'] != false;
              }
            }
            await service.save();
          });
        }
      }
      for (final section in Section.values) {
        final rows = bySection[section.id];
        if (rows == null) continue;
        final store = await ReadingStore.open(section);
        final current = store.cloudRecords(includeSettings: includeSettings);
        final apply = <String, Object?>{};
        for (final entry in rows.entries) {
          if (jsonEncode(current[entry.key]) != jsonEncode(local[entry.key])) {
            merged[entry.key] = {
              'stamp': stamp++,
              'device': _device,
              'value': current[entry.key],
            };
          } else if (jsonEncode(entry.value) !=
              jsonEncode(current[entry.key])) {
            apply[entry.key] = entry.value;
          }
        }
        if (apply.isNotEmpty) store.applyCloudRecords(apply);
      }
      _records = merged;
      _baseline = {
        for (final entry in merged.entries) entry.key: entry.value['value'],
      };
      lastSync = DateTime.now();
      await save();
      status = '已与本机 iCloud 文件同步，跨设备传输由系统继续完成';
    } catch (error) {
      status = error is PlatformException
          ? error.message ?? 'iCloud 同步失败'
          : '同步未完成：$error';
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  static Object? _mergeConfig(Object? old, Object? incoming) {
    if (old is Map && incoming is Map) {
      return {
        ...old,
        for (final entry in incoming.entries)
          entry.key: _mergeConfig(old[entry.key], entry.value),
      };
    }
    return incoming;
  }
}
