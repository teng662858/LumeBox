import 'dart:io';

import 'package:lume_box/core/cat/cat_local_bundle.dart';

void main(List<String> args) {
  final bundle = CatLocalBundle.fromZip(File(args.single).readAsBytesSync());
  stdout.writeln(
    'ZIP validated: index=${bundle.index.length} bytes, config=${bundle.config.length} bytes; both MD5 checks passed.',
  );
}
