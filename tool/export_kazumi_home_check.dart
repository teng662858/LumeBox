import 'dart:convert';
import 'dart:io';

import 'package:lume_box/core/source/kazumi_rule.dart';

void main(List<String> args) {
  if (args.length != 2) {
    stderr.writeln(
      'Usage: dart run tool/export_kazumi_home_check.dart rule.json output.cjs',
    );
    exitCode = 2;
    return;
  }
  final rule = File(args[0]).readAsStringSync();
  final script = KazumiRule.convert(rule);
  final a = script.indexOf('function kazumiExtract(');
  final b = script.indexOf('function kazumiPath(', a);
  File(args[1]).writeAsStringSync(
    'const kazumiRule = ${jsonEncode(jsonDecode(rule))};\n${script.substring(a, b)}\nmodule.exports = kazumiExtract;',
  );
}
