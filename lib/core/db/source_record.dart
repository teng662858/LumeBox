import 'dart:convert';

import 'package:sqlite3/sqlite3.dart';

import '../net/network_settings.dart';
import '../source/source_site_config.dart';

/// 图源的持久化模型。每个板块的库中各自保存，图源不跨板块共享。
class SourceRecord {
  const SourceRecord({
    required this.id,
    required this.name,
    required this.version,
    required this.section,
    required this.script,
    required this.enabled,
    this.network = NetworkProfile.none,
    this.siteConfig = SourceSiteConfig.none,
    this.originUrl = '',
    this.group = '',
    this.failureCount = 0,
    this.brokenAt = 0,
  });

  final String id;
  final String name;
  final String version;

  /// 归属板块标记：导入时落库，读取路径据此拒绝跨板块记录。
  final String section;

  final String script;
  final bool enabled;

  /// 单图源网络覆盖（UA / Cookie / 代理）；空项继承全局设置。
  final NetworkProfile network;

  /// 单图源「换网址 / 账号登入」：站点镜像、选中下标、自定义域名与登录账号。
  /// 与 [network] 一样按源存，落在本板块库里（跨板块不共享）。
  final SourceSiteConfig siteConfig;

  /// 订阅来源地址；本地导入的图源为空（没有可更新的来源）。
  final String originUrl;

  /// 用户自定的分组名；空串表示未分组。
  ///
  /// 与「板块」是两个层次：板块是**物理隔离**（各自一个库、一套运行时，脚本
  /// 不许跨板块），分组只是同一板块内的**展示归类**（用户按习惯把源分成
  /// 「主力 / 备用」这类）。分组永远不改变归属板块。
  final String group;

  /// 连续失败次数；达到阈值后由管理页标为失效。
  final int failureCount;

  /// 「标记为失效」的时间戳（毫秒）；0 表示未失效。
  final int brokenAt;

  /// 是否已被标记为失效。
  ///
  /// 失效的源**不再参与自动重试**（批量测试 / 批量刷新会跳过它），避免对着一个
  /// 已经死掉的源反复打目标站。用户可以在管理页手动「恢复」——恢复即清零计数，
  /// 让它重新进入自动流程。
  bool get isBroken => brokenAt > 0;

  /// 是否来自订阅（可「更新订阅源」）。
  bool get isSubscribed => originUrl.trim().isNotEmpty;

  factory SourceRecord.fromRow(Row row) => SourceRecord(
        id: row['id'] as String,
        name: row['name'] as String,
        version: row['version'] as String,
        section: row['section'] as String,
        script: row['script'] as String,
        enabled: (row['enabled'] as int) != 0,
        network: NetworkProfile(
          userAgent: '${row['user_agent'] ?? ''}',
          cookie: '${row['cookie'] ?? ''}',
          proxy: '${row['proxy'] ?? ''}',
          bridge: '${row['bridge'] ?? ''}',
          // 缺列（老库还没来得及迁移）时按「关闭」读：宁可连不上，也不悄悄放宽校验。
          allowBadCertificate: '${row['allow_bad_cert'] ?? ''}' == '1',
        ),
        // 换网址 / 账号登入：整份配置以 JSON 存在一列里（老库 / 老行缺列时
        // 读出来是空串 → 落到默认值，既有数据库照常可用）。
        siteConfig: SourceSiteConfig.fromJson(_siteJson(row['site_config'])),
        originUrl: '${row['origin_url'] ?? ''}',
        group: '${row['source_group'] ?? ''}',
        failureCount: (row['failure_count'] as int?) ?? 0,
        brokenAt: (row['broken_at'] as int?) ?? 0,
      );

  /// 落库的配置列 → JSON 值；空串 / 坏 JSON 一律按「没有配置」处理
  /// （坏数据只该让这一项回到默认，不该让整个源读不出来）。
  static Object? _siteJson(Object? raw) {
    final text = '${raw ?? ''}'.trim();
    if (text.isEmpty) return null;
    try {
      return jsonDecode(text);
    } catch (_) {
      return null;
    }
  }
}
