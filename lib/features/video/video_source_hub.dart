import 'package:flutter/material.dart';

import '../../core/cat/cat_service.dart';
import '../../core/reading/reading_library.dart';
import '../../core/session/section.dart';
import '../../core/source/source.dart';
import '../../core/util/lume_log.dart';
import '../../core/web/web_home_sources.dart';
import '../cat/cat_page.dart';
import '../source/video_source_picker.dart';
import '../source/video_source_scope.dart';
import '../web/web_home_page.dart';
import 'video_page.dart';

/// A single video surface, with no migration of source IDs or reading records.
class VideoSourceHub extends StatefulWidget {
  const VideoSourceHub({super.key});

  @override
  State<VideoSourceHub> createState() => _VideoSourceHubState();
}

class _VideoSourceHubState extends State<VideoSourceHub> {
  bool _cat = false;
  bool _catCreated = false;
  CatSite? _site;
  WebHomeSource? _webHome;
  int _revision = 0;
  int _selection = 0;
  bool _pickerOpen = false;

  @override
  void initState() {
    super.initState();
    _restore();
  }

  Future<void> _restore() async {
    try {
      final generation = _selection;
      final library = await ReadingLibrary.open(Section.video);
      if (!mounted || generation != _selection) return;
      final kind = library.setting('video.source.kind');
      if (kind == 'cat') {
        setState(() {
          _cat = true;
          _catCreated = true;
        });
      } else if (kind == 'web') {
        final id = library.setting('video.web.selected');
        final store = await WebHomeStore.open();
        final home = store.byId(id);
        if (!mounted || generation != _selection) return;
        if (home != null) setState(() => _webHome = home);
      }
    } catch (error, stackTrace) {
      // The content page owns its storage error UI; a missing preference must
      // not turn a recoverable storage problem into an unhandled exception.
      LumeLog.error(error, stackTrace);
    }
  }

  Future<void> _pick(BuildContext context) async {
    if (_pickerOpen) return;
    _pickerOpen = true;
    try {
      await _pickSource(context);
    } catch (error, stackTrace) {
      LumeLog.error(error, stackTrace);
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('切换源失败，请重试')));
      }
    } finally {
      _pickerOpen = false;
    }
  }

  Future<void> _pickSource(BuildContext context) async {
    final manager = LumeSources.manager(Section.video);
    final selected = await showVideoSourcePicker(
      context: context,
      manager: manager,
      currentCatId: _cat ? CatService.instance.selectedSiteId : null,
      currentWebId: _webHome?.id,
      showingCat: _cat,
    );
    if (!mounted) return;
    // Imports can change the available sources even when the drawer is closed.
    setState(() {
      _revision++;
      if (_site != null &&
          CatService.instance.subscriptions.any(
            (record) => record.removedSiteIds.contains(_site!.id),
          )) {
        _site = null;
      }
      if (_webHome != null &&
          WebHomeStore.instance?.byId(_webHome!.id) == null) {
        _webHome = null;
      }
    });
    if (selected == null) return;
    _selection++;
    if (selected.site case final site?) {
      await CatService.instance.select(site);
      if (!mounted) return;
      setState(() {
        _site = site;
        _cat = true;
        _catCreated = true;
        _webHome = null;
      });
    } else if (selected.webHome case final home?) {
      final library = await ReadingLibrary.open(Section.video);
      library.setSetting('video.source.kind', 'web');
      library.setSetting('video.web.selected', home.id);
      if (!context.mounted) return;
      setState(() {
        _cat = false;
        _webHome = home;
      });
      await Navigator.push<void>(
        context,
        MaterialPageRoute(builder: (_) => WebHomePage(source: home)),
      );
      return;
    } else if (selected.sourceId case final id?) {
      if (await manager.select(id) == null || !mounted) return;
      setState(() {
        _cat = false;
        _webHome = null;
        _revision++;
      });
    }
    final library = await ReadingLibrary.open(Section.video);
    library.setSetting('video.source.kind', _cat ? 'cat' : 'ordinary');
  }

  @override
  Widget build(BuildContext context) => VideoSourceScope(
    openPicker: _pick,
    child: SourcePickerEdgeSwipe(
      onOpen: () => _pick(context),
      child: IndexedStack(
        index: _cat ? 1 : 0,
        children: [
          TickerMode(
            enabled: !_cat,
            child: VideoPage(sourceRevision: _revision),
          ),
          if (_catCreated)
            TickerMode(
              enabled: _cat,
              child: CatPage(requestedSite: _site),
            )
          else
            const SizedBox.shrink(),
        ],
      ),
    ),
  );
}
