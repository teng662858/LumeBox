import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'source.dart';

class SourceDuplicateGroup {
  const SourceDuplicateGroup(this.reason, this.sources);
  final String reason;
  final List<SourceDescriptor> sources;
}

List<SourceDuplicateGroup> findSourceDuplicates(
  List<SourceDescriptor> sources,
  Map<String, String> scripts,
) {
  final hashes = <String, List<SourceDescriptor>>{};
  final hosts = <String, List<SourceDescriptor>>{};
  for (final source in sources) {
    final script = scripts[source.id];
    if (script != null && script.isNotEmpty) {
      hashes
          .putIfAbsent(sha256.convert(utf8.encode(script)).toString(), () => [])
          .add(source);
    }
    final host =
        Uri.tryParse(source.siteUrl)?.host
            .toLowerCase()
            .replaceFirst(RegExp(r'^www\.'), '') ??
        '';
    if (host.isNotEmpty) hosts.putIfAbsent(host, () => []).add(source);
  }
  return [
    for (final group in hashes.values.where((g) => g.length > 1))
      SourceDuplicateGroup('脚本内容完全相同', group),
    for (final entry in hosts.entries.where((e) => e.value.length > 1))
      SourceDuplicateGroup('同站点 ${entry.key}（可能是不同版本，不一定重复）', entry.value),
  ];
}
