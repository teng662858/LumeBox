import 'package:lume_box/core/player/player_factory.dart';
import 'package:lume_box/core/player/player_settings.dart';

import 'dart:ffi';

import 'package:lume_box/core/js/qjs_bindings.dart';
// Development-only harness. Uses production importer, JS runtime, pages and player.
// Android runtime override stays in this target and never changes release gates.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lume_box/core/js/lume_js_engine.dart';
import 'package:lume_box/core/js/source_engine.dart';
import 'package:lume_box/core/net/lume_net.dart';
import 'package:lume_box/core/reading/reading.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/source/source.dart';
import 'package:lume_box/core/theme/lume_theme.dart';
import 'package:lume_box/core/tmdb/tmdb.dart';
import 'package:lume_box/features/video/video_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await LumeNet.boot();
  Qjs.overrideLibrary(DynamicLibrary.open('libquickjs_c_bridge_plugin.so'));
  Qjs.reclaimRuntime = false;
  // ignore: invalid_use_of_visible_for_testing_member
  LumeJsEngine.debugSupportedOverride = true;
  SourceEngineRegistry.register(
    CatEngineKind.quickjs,
    ({required sourceId, required http, required section}) async =>
        QuickJsSourceEngine(
          await LumeJsEngine.create(
            sourceId: sourceId,
            http: http,
            section: section,
          ),
        ),
  );
  final library = await ReadingLibrary.open(Section.video);
  library.setSetting('video.detail.originalStyle', 'true');
  // Test module-provided artwork/cast without TMDB enrichment hiding the mapping.
  TmdbSettings.instance.enabled = false;
  runApp(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: LumeTheme.build(brightness: Brightness.light),
      home: RexWorkflowPreview(library: library),
    ),
  );
}

class RexWorkflowPreview extends StatefulWidget {
  const RexWorkflowPreview({super.key, required this.library});
  final ReadingLibrary library;
  @override
  State<RexWorkflowPreview> createState() => _PreviewState();
}

class _PreviewState extends State<RexWorkflowPreview> {
  String status = '明文样板：Blender 开放电影；角色和三集目录为演示数据';
  bool busy = false;
  Future<void> import() async {
    setState(() {
      busy = true;
      status = '正在通过正式源管理接口导入…';
    });
    try {
      final manager = LumeSources.manager(Section.video);
      final result = await manager.importScript(
        await rootBundle.loadString('assets/rex/lumebox_demo.js'),
      );
      if (!result.isSuccess) throw StateError(result.message ?? '导入失败');
      await manager.select(result.descriptor!.id);
      final source = (await manager.open(result.descriptor!.id))!;
      final first = (await source.list()).items;
      final search = (await source.list(keyword: 'Bunny')).items;
      final detail = (await source.detail(search.single.id))!;
      final chapters = await source.chapters(search.single.id);
      if (!mounted) return;
      setState(
        () => status =
            '导入成功 · 列表 ${first.length} 项 · Bunny 搜索 ${search.length} 项 · 线路 ${chapters.map((e) => e.line).toSet().length} 条 · 演员 ${detail.cast.length} 位（演示）',
      );
      await Navigator.push(
        context,
        MaterialPageRoute<void>(
          builder: (_) => Scaffold(
            body: SafeArea(
              child: VideoPage(
                library: widget.library,
                sourceManager: manager,
                catalog: const _PreviewMpvCatalog(),
              ),
            ),
          ),
        ),
      );
    } catch (e) {
      if (mounted) setState(() => status = '失败：$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('REX 全流程实测')),
    body: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(status),
          const SizedBox(height: 24),
          FilledButton(
            onPressed: busy ? null : import,
            child: const Text('导入明文样板并打开正式视频页面'),
          ),
        ],
      ),
    ),
  );
}

// Real libmpv injection for Android preview only, not a fake playback backend.
class _PreviewMpvCatalog implements PlayerKernelCatalog {
  const _PreviewMpvCatalog();
  @override
  bool isAvailable(PlayerKernel kernel) => kernel == PlayerKernel.mpv;
  @override
  String? unavailableReason(PlayerKernel kernel) =>
      isAvailable(kernel) ? null : '预览使用真实 MPV';
}
