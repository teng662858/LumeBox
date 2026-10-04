import 'package:flutter/material.dart';

import '../../core/session/section.dart';
import '../source/source_section_page.dart';

/// 猫源板块。图源、数据库、缓存目录均与其他板块隔离。
class CatPage extends StatelessWidget {
  const CatPage({super.key});

  @override
  Widget build(BuildContext context) =>
      const SourceSectionPage(section: Section.cat);
}
