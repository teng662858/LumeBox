part of 'comic_reader_page.dart';

const _readerAccent = Color(0xFFFF315F);

IconData _readerIcon(IconData icon) => switch (icon) {
  Icons.ios_share => CupertinoIcons.share_up,
  Icons.flag_outlined => CupertinoIcons.flag,
  Icons.flag => CupertinoIcons.flag_fill,
  Icons.bookmark_border => CupertinoIcons.bookmark,
  Icons.bookmark => CupertinoIcons.bookmark_fill,
  Icons.edit_note => CupertinoIcons.square_pencil,
  Icons.tune => CupertinoIcons.slider_horizontal_3,
  Icons.lock_open => CupertinoIcons.lock_open,
  Icons.lock => CupertinoIcons.lock,
  Icons.touch_app_outlined => CupertinoIcons.device_phone_portrait,
  Icons.translate => CupertinoIcons.text_bubble,
  Icons.volume_up_outlined => CupertinoIcons.speaker_2,
  Icons.bedtime_outlined => CupertinoIcons.moon_zzz,
  Icons.dashboard_customize_outlined => CupertinoIcons.slider_horizontal_3,
  Icons.feedback_outlined => CupertinoIcons.exclamationmark_bubble,
  Icons.more_horiz => CupertinoIcons.ellipsis_circle,
  Icons.crop => CupertinoIcons.crop,
  _ => icon,
};

class _ReaderSliderThumb extends SliderComponentShape {
  const _ReaderSliderThumb();
  @override
  Size getPreferredSize(bool isEnabled, bool isDiscrete) => const Size(30, 20);
  @override
  void paint(
    PaintingContext context,
    Offset center, {
    required Animation<double> activationAnimation,
    required Animation<double> enableAnimation,
    required bool isDiscrete,
    required TextPainter labelPainter,
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required TextDirection textDirection,
    required double value,
    required double textScaleFactor,
    required Size sizeWithOverflow,
  }) {
    final rect = RRect.fromRectAndRadius(
      Rect.fromCenter(center: center, width: 30, height: 20),
      const Radius.circular(12),
    );
    context.canvas.drawShadow(Path()..addRRect(rect), Colors.black26, 4, true);
    context.canvas.drawRRect(rect, Paint()..color = Colors.white);
  }
}

/// Presentation and interaction controls, separate from the image pipeline.
extension _ComicReaderChrome on _ComicReaderPageState {
  void _showStartupZoneHint() {
    if (_zoneHintShown || _images.isEmpty) return;
    _zoneHintShown = true;
    if (!_preferences.showZonesOnStart || _preferences.tapZones == 'disabled') {
      return;
    }
    _refresh(() => _startupZoneHint = true);
    _zoneHintTimer = Timer(const Duration(seconds: 4), () {
      if (mounted) _refresh(() => _startupZoneHint = false);
    });
  }

  void _onComicSpeechPosition(int offset) {
    final page = _speechText, url = _speechUrl;
    if (!mounted || page == null || url == null) return;
    _speechCursor.value = ComicSpeechCursor(url, page, offset);
  }

  Future<void> _stopComicSpeech({bool closePanel = false}) async {
    _speechContinuous = false;
    _speechGeneration++;
    _speechWorking = false;
    _speechText = null;
    _speechUrl = null;
    _speechCursor.value = null;
    if (closePanel) {
      _refresh(() {
        _speechPanelOpened = false;
        _speechMini = false;
      });
    }
    await _speech?.stop();
  }

  Future<void> _changeComicSpeechSettings(SpeechSettings settings) async {
    _refresh(() => _speechSettings = settings);
    widget.library.setSetting(SpeechSettings.settingKey, settings.encode());
    _applyComicSpeechSettings();
    final session = _speech;
    if (session != null &&
        (session.isActive || session.isPaused) &&
        session.segmentCount > 0) {
      final rejection = await session.seekToSegment(session.segmentIndex);
      if (mounted && rejection != null) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(rejection)));
      }
    }
  }

  Future<void> _showSpeechSpeed() => _readerSheet(
    '朗读倍速',
    (update) => ListView(
      children: [
        for (final speed in [.5, .75, 1.0, 1.25, 1.5, 1.75, 2.0])
          _entry(
            Icons.speed,
            '${speed.toString().replaceFirst(RegExp(r'\.0$'), '')}×',
            () {
              Navigator.pop(context);
              unawaited(
                _changeComicSpeechSettings(
                  _speechSettings.copyWith(rate: speed / 2),
                ),
              );
            },
            selected: (_speechSettings.rate * 2 - speed).abs() < .01,
            arrow: false,
          ),
        const Padding(
          padding: EdgeInsets.all(20),
          child: Text(
            '播放中切换会从当前片段开头应用；暂停时保持暂停。',
            style: TextStyle(fontSize: 12, color: Colors.grey),
          ),
        ),
      ],
    ),
    height: .68,
  );

  Future<List<(String, String)>> _loadComicVoices() async {
    try {
      final raw = await const MethodChannel('lumebox/speech')
          .invokeListMethod<dynamic>('speechVoices')
          .timeout(const Duration(seconds: 5));
      final voices = <String, String>{};
      for (final voice in raw ?? []) {
        if (voice is Map &&
            voice['id'] is String &&
            (voice['id'] as String).isNotEmpty) {
          voices[voice['id'] as String] = SpeechVoiceLabels.label(voice);
        }
      }
      return voices.entries.map((entry) => (entry.key, entry.value)).toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> _showComicVoices() async {
    if (_speechSettings.mode != SpeechMode.system) {
      await _showComicSpeechPanel();
      return;
    }
    _comicVoices = _loadComicVoices();
    final box = _comicVoiceAnchor.currentContext?.findRenderObject();
    final anchor = box is RenderBox && box.hasSize
        ? box.localToGlobal(Offset.zero) & box.size
        : null;
    await _showReaderMenu('voices', anchor: anchor);
  }

  Widget _voiceMenu(void Function(VoidCallback) close) =>
      FutureBuilder<List<(String, String)>>(
        future: _comicVoices,
        builder: (context, snapshot) => Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _entry(
              Icons.record_voice_over_outlined,
              '自动',
              () => close(
                () => unawaited(
                  _changeComicSpeechSettings(
                    _speechSettings.copyWith(narratorVoice: ''),
                  ),
                ),
              ),
              selected: _speechSettings.narratorVoice.isEmpty,
              arrow: false,
            ),
            if (!snapshot.hasData)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator()),
              ),
            for (final voice in snapshot.data ?? <(String, String)>[])
              _entry(
                Icons.person_outline,
                voice.$2,
                () => close(
                  () => unawaited(
                    _changeComicSpeechSettings(
                      _speechSettings.copyWith(narratorVoice: voice.$1),
                    ),
                  ),
                ),
                selected: _speechSettings.narratorVoice == voice.$1,
                arrow: false,
              ),
            if (snapshot.hasData && snapshot.data!.isEmpty)
              const Padding(
                padding: EdgeInsets.all(20),
                child: Text(
                  '系统音色列表暂不可用，可继续使用自动音色。',
                  style: TextStyle(fontSize: 13, color: Colors.grey),
                ),
              ),
            if (snapshot.hasData &&
                snapshot.data!.isNotEmpty &&
                _speechSettings.narratorVoice.isNotEmpty &&
                !snapshot.data!.any(
                  (voice) => voice.$1 == _speechSettings.narratorVoice,
                ))
              const Padding(
                padding: EdgeInsets.all(20),
                child: Text(
                  '已保存的音色在此设备不可用，请选择自动或其他音色。',
                  style: TextStyle(fontSize: 13, color: Colors.grey),
                ),
              ),
            const Divider(indent: 18, endIndent: 18),
            _entry(
              Icons.settings_outlined,
              '完整朗读设置',
              () => close(_showComicSpeechPanel),
            ),
          ],
        ),
      );

  Widget _buildSpeechRestore() => Positioned(
    left: 16,
    bottom: (_toolbar ? 78 : 16) + MediaQuery.paddingOf(context).bottom,
    child: _roundButton(
      Icons.record_voice_over_outlined,
      '显示朗读栏',
      () => _refresh(() => _speechMini = true),
    ),
  );

  /// Display slices never change the source page number stored in progress/bookmarks.
  List<(int, int)> get _displayPages => [
    for (var index = 0; index < _images.length; index++)
      if (_preferences.splitWide &&
          _settings.mode == ComicReadingMode.single &&
          (_ratios[index] ?? 2) < 1) ...[
        (index, _settings.isRightToLeft ? 1 : -1),
        (index, _settings.isRightToLeft ? -1 : 1),
      ] else
        (index, 0),
  ];
  int _displayIndexOf(int page) {
    final entries = _displayPages;
    final exact = entries.indexWhere(
      (entry) => entry.$1 == page && entry.$2 == _wideHalf,
    );
    return exact >= 0
        ? exact
        : math.max(0, entries.indexWhere((entry) => entry.$1 == page));
  }

  Widget _glass(
    Widget child, {
    double radius = 28,
    double opacity = .58,
    Color tint = Colors.white,
  }) => _ReaderGlass(child, radius: radius, opacity: opacity, tint: tint);

  Widget _readerGroup(Widget child) => ClipRRect(
    borderRadius: BorderRadius.circular(24),
    child: Material(color: Colors.white, child: child),
  );

  Widget _roundButton(
    IconData icon,
    String label,
    VoidCallback? action, {
    bool selected = false,
  }) => _glass(
    IconButton(
      tooltip: label,
      onPressed: action,
      icon: LumeIcon(
        _readerIcon(icon),
        slot: 'comic_reader_chrome.1',
        variant: true,
        color: selected ? _readerAccent : null,
        fallback: icon == Icons.vertical_align_bottom
            ? ComicReaderVerticalFlowGlyph(
                color: selected ? _readerAccent : null,
              )
            : null,
      ),
      constraints: const BoxConstraints.tightFor(width: 44, height: 44),
    ),
  );

  Widget _readerTopBar() {
    final safe = MediaQuery.viewPaddingOf(context);
    // The custom status capsules occupy the system status band. Applying a
    // SafeArea above them would reserve that band twice on notched iPhones.
    return Positioned(
      top: 0,
      left: 12 + safe.left,
      right: 12 + safe.right,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            height: math.max(44, safe.top),
            child: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 20),
              child: Center(child: ComicReaderStatus()),
            ),
          ),
          const SizedBox(height: 6),
          Row(
            key: const Key('comic.top.controls'),
            children: [
              _roundButton(
                Icons.close,
                '退出阅读',
                () => Navigator.of(context).maybePop(),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) => Center(
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        minWidth: math.min(136, constraints.maxWidth),
                        maxWidth: math.min(180, constraints.maxWidth),
                        minHeight: 44,
                      ),
                      child: IntrinsicWidth(
                        child: _glass(
                          InkWell(
                            key: const Key('comic.top.title'),
                            onTap: _showChapterSheet,
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 14,
                                vertical: 6,
                              ),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Text(
                                    _chapters.isEmpty
                                        ? '漫画阅读'
                                        : _chapters[_chapterIndex].title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontSize: 14,
                                      height: 1.15,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    widget.target.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontSize: 11,
                                      height: 1.15,
                                      color: Color(0xFF85858D),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              _roundButton(
                _flowIcon,
                '阅读方向',
                () => _showReaderMenu('direction'),
              ),
              const SizedBox(width: 8),
              _roundButton(
                Icons.more_horiz,
                '更多',
                () => _showReaderMenu('main'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  IconData get _flowIcon => switch (_preferences.flow) {
    'rtl' => Icons.keyboard_double_arrow_left,
    'ltr' => Icons.keyboard_double_arrow_right,
    'horizontal' => Icons.swap_horiz,
    'spread' => Icons.auto_stories_outlined,
    _ => Icons.vertical_align_bottom,
  };
  String get _flowLabel =>
      const {
        'webtoon': '条漫',
        'vertical': '垂直滚动',
        'horizontal': '水平滚动',
        'rtl': '从右到左（日漫）',
        'ltr': '从左到右',
        'spread': '双页跨页',
      }[_preferences.flow] ??
      '条漫';

  Widget _readerBottomBar() => Positioned(
    left: 12,
    right: 12,
    bottom: 0,
    child: SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Row(
          children: [
            for (var i = 0; i < _preferences.toolbar.length; i++) ...[
              if (i > 0) const SizedBox(width: 8),
              if (_preferences.toolbar[i] == 'slider')
                Expanded(child: _pageSlider())
              else if (_preferences.toolbar[i] == 'auto')
                _roundButton(
                  _autoScrolling ? Icons.pause : Icons.play_arrow,
                  '自动滚动',
                  _images.isEmpty ? null : _toggleAutoScroll,
                  selected: _autoScrolling,
                )
              else if (_preferences.toolbar[i] == 'thumbnails')
                _roundButton(
                  Icons.view_week_outlined,
                  '页面缩略图',
                  _images.isEmpty ? null : _showThumbnails,
                )
              else if (_preferences.toolbar[i] == 'chapters')
                _roundButton(
                  Icons.format_list_bulleted,
                  '目录',
                  _showChapterSheet,
                ),
            ],
          ],
        ),
      ),
    ),
  );

  Widget _pageSlider() => _glass(
    SizedBox(
      height: 48,
      child: Row(
        children: [
          IconButton(
            tooltip: '上一章',
            visualDensity: VisualDensity.compact,
            icon: const LumeIcon(
              Icons.keyboard_double_arrow_left,
              slot: 'comic_reader_chrome.2',
              size: 21,
            ),
            onPressed: _chapterIndex > 0
                ? () => _openChapter(_chapterIndex - 1)
                : null,
          ),
          Text(
            _images.isEmpty ? '—' : '${_page + 1}',
            style: const TextStyle(fontSize: 12),
          ),
          Expanded(
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                activeTrackColor: _readerAccent,
                inactiveTrackColor: Colors.black12,
                thumbColor: Colors.white,
                trackHeight: 3,
                thumbShape: const _ReaderSliderThumb(),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
              ),
              child: Slider(
                key: const Key('comic.pageSlider'),
                value: _images.isEmpty ? 0 : _page.toDouble(),
                max: math.max(1, _images.length - 1).toDouble(),
                semanticFormatterCallback: (v) => '第 ${v.round() + 1} 页',
                onChanged: _images.length > 1
                    ? (v) => _goToPage(v.round())
                    : null,
              ),
            ),
          ),
          Text(
            '${_images.length}',
            style: const TextStyle(fontSize: 12, color: Color(0xFF73737B)),
          ),
          IconButton(
            tooltip: '下一章',
            visualDensity: VisualDensity.compact,
            icon: const LumeIcon(
              Icons.keyboard_double_arrow_right,
              slot: 'comic_reader_chrome.3',
              size: 21,
            ),
            onPressed: _chapterIndex + 1 < _chapters.length
                ? () => _openChapter(_chapterIndex + 1)
                : null,
          ),
        ],
      ),
    ),
  );

  Future<void> _readerSheet(
    String title,
    Widget Function(StateSetter) body, {
    double height = .88,
    bool grouped = false,
    Widget Function(StateSetter)? leading,
  }) async {
    if (_autoScrolling) _stopAutoScroll();
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black26,
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, update) => SizedBox(
          height: MediaQuery.sizeOf(context).height * height,
          child: _glass(
            Column(
              children: [
                const SizedBox(height: 7),
                Container(
                  width: 48,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.black26,
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 8, 12, 14),
                  child: Row(
                    children: [
                      SizedBox(width: 64, child: leading?.call(update)),
                      Expanded(
                        child: Text(
                          title,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      TextButton(
                        onPressed: () => Navigator.pop(sheetContext),
                        child: const Text(
                          '完成',
                          style: TextStyle(color: _readerAccent),
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(child: SafeArea(top: false, child: body(update))),
              ],
            ),
            radius: 32,
            opacity: grouped ? .98 : .58,
            tint: grouped ? const Color(0xFFF2F2F7) : Colors.white,
          ),
        ),
      ),
    );
  }

  Widget _entry(
    IconData icon,
    String title,
    VoidCallback? action, {
    String? detail,
    bool selected = false,
    Color? color,
    bool arrow = true,
  }) => ListTile(
    minLeadingWidth: 24,
    contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 1),
    leading: LumeIcon(
      _readerIcon(icon),
      slot: 'comic_reader_chrome.4',
      variant: true,
      color: color ?? (selected ? _readerAccent : const Color(0xFF17181D)),
      fallback: icon == Icons.vertical_align_bottom
          ? ComicReaderVerticalFlowGlyph(
              color:
                  color ?? (selected ? _readerAccent : const Color(0xFF17181D)),
            )
          : null,
    ),
    title: Text(
      title,
      style: TextStyle(
        fontSize: 16,
        color: const Color(0xFF17181D),
        fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
      ),
    ),
    subtitle: detail == null
        ? null
        : Text(
            detail,
            style: const TextStyle(fontSize: 12, color: Color(0xFF5F6069)),
          ),
    trailing: selected
        ? const LumeIcon(
            Icons.check,
            slot: 'comic_reader_chrome.5',
            color: _readerAccent,
            size: 20,
          )
        : arrow
        ? const LumeIcon(
            Icons.chevron_right,
            slot: 'comic_reader_chrome.6',
            size: 19,
          )
        : null,
    onTap: action,
  );

  Future<void> _showReaderMenu(String initial, {Rect? anchor}) async {
    if (_autoScrolling) _stopAutoScroll();
    final safeTop = MediaQuery.paddingOf(context).top;
    await showGeneralDialog<void>(
      context: context,
      barrierDismissible: false,
      barrierLabel: '关闭阅读菜单',
      barrierColor: Colors.black.withValues(alpha: .08),
      transitionDuration: const Duration(milliseconds: 180),
      pageBuilder: (dialogContext, animation, secondary) => Stack(
        fit: StackFit.expand,
        children: [
          Semantics(
            label: '关闭阅读菜单',
            button: true,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => Navigator.pop(dialogContext),
              child: const SizedBox.expand(),
            ),
          ),
          SafeArea(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final anchorBottom = anchor == null
                    ? null
                    : (anchor.top - safeTop - 8)
                          .clamp(
                            80.0,
                            math.max(80.0, constraints.maxHeight - 12),
                          )
                          .toDouble();
                final height = anchorBottom == null
                    ? math.min(
                        580.0,
                        constraints.maxHeight -
                            (constraints.maxHeight > 500 ? 64 : 8) -
                            12,
                      )
                    : math.min(580.0, anchorBottom - 8);
                final top = anchorBottom == null
                    ? (constraints.maxHeight > 500 ? 64.0 : 8.0)
                    : anchorBottom - height;
                return Align(
                  alignment: Alignment.topRight,
                  child: Padding(
                    padding: EdgeInsets.only(right: 12, top: top, bottom: 12),
                    child: SizedBox(
                      width: math.min(
                        constraints.maxWidth - 24,
                        (constraints.maxWidth * .60).clamp(230.0, 300.0),
                      ),
                      height: height,
                      child: _ReaderMenuStack(
                        initial: initial,
                        alignment: anchor == null
                            ? Alignment.topRight
                            : Alignment.bottomRight,
                        title: _menuTitle,
                        surface: (child) => GestureDetector(
                          excludeFromSemantics: true,
                          onTap: () {},
                          child: _glass(child, radius: 30, opacity: .86),
                        ),
                        close: () => Navigator.pop(dialogContext),
                        entries: (route, open, refresh) => _menuEntries(
                          route,
                          open,
                          (action) {
                            _refresh(action);
                            _saveExperience();
                            refresh();
                          },
                          (action) {
                            Navigator.pop(dialogContext);
                            action();
                          },
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
      transitionBuilder: (context, animation, secondary, child) =>
          FadeTransition(
            opacity: animation,
            child: ScaleTransition(
              scale: Tween<double>(begin: .97, end: 1).animate(
                CurvedAnimation(parent: animation, curve: Curves.easeOutCubic),
              ),
              alignment: Alignment.topRight,
              child: child,
            ),
          ),
    );
  }

  String _menuTitle(String route) =>
      const {
        'main': '阅读工具',
        'voices': '声音',
        'direction': '阅读方向',
        'reading': '阅读模式',
        'background': '背景',
        'zoom': '缩放',
        'zones': '点击区域',
        'bookmarks': '书签',
        'flags': '标记',
        'translation': '翻译',
        'orientation': '屏幕方向',
        'presets': '阅读预设',
      }[route] ??
      '阅读工具';

  List<Widget> _menuEntries(
    String route,
    void Function(String) open,
    void Function(VoidCallback) change,
    void Function(VoidCallback) close,
  ) {
    switch (route) {
      case 'voices':
        return [_voiceMenu(close)];
      case 'direction':
        return [
          for (final item in <(String, String, IconData)>[
            ('rtl', '从右到左（日漫）', Icons.keyboard_double_arrow_left),
            ('ltr', '从左到右', Icons.keyboard_double_arrow_right),
            ('vertical', '垂直滚动', Icons.vertical_align_bottom),
            ('webtoon', '条漫', Icons.south),
            ('horizontal', '水平滚动', Icons.swap_horiz),
            ('spread', '双页跨页', Icons.auto_stories_outlined),
          ])
            _entry(
              item.$3,
              item.$2,
              () => close(() => _setFlow(item.$1)),
              selected: _preferences.flow == item.$1,
              arrow: false,
            ),
        ];
      case 'reading':
        return [
          _entry(
            _flowIcon,
            '阅读方向',
            () => open('direction'),
            detail: _flowLabel,
          ),
          _entry(
            Icons.screen_rotation_outlined,
            '屏幕方向',
            () => open('orientation'),
            detail: _orientationLabel,
          ),
          const Divider(indent: 18, endIndent: 18),
          _entry(
            Icons.palette_outlined,
            '背景',
            () => open('background'),
            detail: _settings.background.label,
          ),
          _entry(
            Icons.space_bar,
            '调整边距',
            () => close(_showLayoutAdjustments),
            detail: '侧边距与页间距',
          ),
          _entry(
            Icons.crop,
            '裁剪边距',
            () => close(_showCropAdjustments),
            detail: _preferences.cropRatio == 0
                ? '关闭'
                : '${(_preferences.cropRatio * 100).round()}%',
          ),
          _entry(
            Icons.vertical_split_outlined,
            '拆分宽图',
            () => change(() {
              _preferences.splitWide = !_preferences.splitWide;
              _rebuildControllers();
            }),
            selected: _preferences.splitWide,
            detail: '单页模式按阅读方向拆为两屏',
            arrow: false,
          ),
          _entry(Icons.bookmarks_outlined, '阅读预设', () => open('presets')),
          _entry(
            Icons.auto_stories_outlined,
            '跨页配对',
            () => change(() {
              _updateSettings(
                _settings.copyWith(
                  spreadMode: _settings.spreadMode == ComicSpreadMode.coverFirst
                      ? ComicSpreadMode.pairFromStart
                      : ComicSpreadMode.coverFirst,
                ),
              );
              _rebuildControllers();
            }),
            detail: _settings.spreadMode.label,
          ),
          _entry(
            Icons.settings_outlined,
            '完整阅读设置',
            () => close(_openReaderSettings),
          ),
        ];
      case 'background':
        return [
          for (final bg in ComicReaderBackground.values)
            _entry(
              Icons.circle,
              bg == ComicReaderBackground.black ? 'OLED 纯黑' : bg.label,
              () => change(
                () => _updateSettings(_settings.copyWith(background: bg)),
              ),
              color: bg == ComicReaderBackground.white ? Colors.grey : bg.color,
              selected: _settings.background == bg,
              arrow: false,
            ),
        ];
      case 'orientation':
        return [
          for (final value in ['device', 'portrait', 'landscape'])
            _entry(
              Icons.screen_rotation_outlined,
              const {
                'device': '跟随设备',
                'portrait': '竖屏',
                'landscape': '横屏',
              }[value]!,
              () {
                change(() => _preferences.orientation = value);
                unawaited(_applyOrientation());
              },
              selected: _preferences.orientation == value,
              arrow: false,
            ),
        ];
      case 'zoom':
        return [
          _entry(
            _preferences.zoomLocked ? Icons.lock : Icons.lock_open,
            '锁定缩放',
            () => change(
              () => _preferences.zoomLocked = !_preferences.zoomLocked,
            ),
            selected: _preferences.zoomLocked,
            arrow: false,
          ),
          _entry(
            Icons.zoom_in,
            '双击与双指缩放',
            () => change(
              () => _updateSettings(
                _settings.copyWith(doubleTapZoom: !_settings.doubleTapZoom),
              ),
            ),
            selected: _settings.doubleTapZoom,
            arrow: false,
          ),
        ];
      case 'zones':
        return [
          for (final item in <(String, String)>[
            ('disabled', '已禁用'),
            ('vertical', '上 / 下'),
            ('horizontal', '左 / 右'),
            ('lshape', 'L 形'),
            ('edge', '边缘'),
            ('kindle', 'Kindle 风格'),
            ('custom', '自定义'),
          ])
            _entry(
              Icons.touch_app_outlined,
              item.$2,
              () {
                change(() => _preferences.tapZones = item.$1);
                if (item.$1 == 'custom') close(_showCustomTapZones);
              },
              selected: _preferences.tapZones == item.$1,
              arrow: false,
            ),
          const Divider(indent: 18, endIndent: 18),
          _entry(
            Icons.swap_horiz,
            '反转点击区域',
            () => change(
              () => _preferences.reverseZones = !_preferences.reverseZones,
            ),
            selected: _preferences.reverseZones,
            arrow: false,
          ),
          _entry(
            Icons.visibility_outlined,
            '显示点击区域',
            () =>
                change(() => _preferences.showZones = !_preferences.showZones),
            selected: _preferences.showZones,
            arrow: false,
          ),
          _entry(
            Icons.play_circle_outline,
            '开始阅读时显示',
            () => change(
              () => _preferences.showZonesOnStart =
                  !_preferences.showZonesOnStart,
            ),
            detail: '开启阅读时提示 4 秒，点按即可收起',
            selected: _preferences.showZonesOnStart,
            arrow: false,
          ),
        ];
      case 'presets':
        return [
          _entry(
            Icons.south,
            '条漫连续阅读',
            () => close(() {
              _setFlow('webtoon');
              _updateSettings(_settings.copyWith(marginRatio: 0, pageGap: 0));
            }),
            arrow: false,
          ),
          _entry(
            Icons.keyboard_double_arrow_left,
            '日漫单页',
            () => close(() {
              _setFlow('rtl');
              _updateSettings(
                _settings.copyWith(
                  background: ComicReaderBackground.black,
                  doubleTapZoom: true,
                ),
              );
            }),
            arrow: false,
          ),
          _entry(
            Icons.auto_stories_outlined,
            '平板双页',
            () => close(() {
              _setFlow('spread');
              _updateSettings(
                _settings.copyWith(
                  spreadMode: ComicSpreadMode.coverFirst,
                  pageGap: 8,
                ),
              );
            }),
            arrow: false,
          ),
        ];
      case 'bookmarks':
        return [
          _entry(
            _bookmarkedHere ? Icons.bookmark : Icons.bookmark_border,
            _bookmarkedHere ? '移除此页书签' : '为此页添加书签',
            () => close(_toggleBookmark),
            arrow: false,
          ),
          _entry(
            Icons.note_add_outlined,
            '添加备注…',
            () => close(() => _editNote(pageNote: true)),
            arrow: false,
          ),
          const Divider(indent: 18, endIndent: 18),
          _entry(
            Icons.format_list_bulleted,
            '所有书签',
            () => close(_showBookmarkSheet),
            detail: '${_bookmarks.length} 个位置',
          ),
        ];
      case 'flags':
        return [
          for (final item in <(String, Color)>[
            ('红色', Colors.red),
            ('橙色', Colors.orange),
            ('黄色', Colors.amber),
            ('绿色', Colors.green),
            ('蓝色', Colors.blue),
            ('紫色', Colors.purple),
          ])
            _entry(
              Icons.flag,
              item.$1,
              () => change(() => _setChapterFlag(item.$1)),
              color: item.$2,
              selected: _chapterFlag == item.$1,
              arrow: false,
            ),
          _entry(
            Icons.flag_outlined,
            '清除标记',
            () => change(() => _setChapterFlag('')),
            arrow: false,
          ),
        ];
      case 'translation':
        return [
          _entry(
            Icons.close,
            '关闭',
            () => change(() {
              _translationGeneration++;
              _setTranslationScope('off');
              _translationBusy = false;
              _translations.clear();
            }),
            selected: _translationScope == 'off',
            arrow: false,
          ),
          _entry(
            Icons.description_outlined,
            '当前页',
            () => close(() {
              _setTranslationScope('page');
              _translatePages(false);
            }),
            selected: _translationScope == 'page',
            arrow: false,
          ),
          _entry(
            Icons.menu_book_outlined,
            '本章',
            () => close(() {
              _setTranslationScope('chapter');
              _translatePages(true);
            }),
            selected: _translationScope == 'chapter',
            arrow: false,
          ),
          _entry(
            Icons.library_books_outlined,
            '本系列',
            () => close(() {
              _setTranslationScope('series');
              _translatePages(true);
            }),
            detail: '记住本系列，下次阅读继续自动翻译',
            selected: _translationScope == 'series',
            arrow: false,
          ),
          const Divider(indent: 18, endIndent: 18),
          _entry(
            Icons.language,
            '翻译语言与引擎',
            () => close(
              () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) =>
                      const ComicImageToolsSettingsPage(translation: true),
                ),
              ),
            ),
          ),
        ];
      default:
        return [
          _entry(
            Icons.ios_share,
            '分享页面',
            _images.isEmpty || _loading || _sharing
                ? null
                : () => close(_shareCurrentPage),
            detail: _sharing ? '正在生成当前画面…' : '包含画面调整、裁剪及译文',
            arrow: false,
          ),
          _entry(
            Icons.flag_outlined,
            '标记',
            () => open('flags'),
            detail: _chapterFlag.isEmpty ? null : _chapterFlag,
          ),
          _entry(Icons.bookmark_border, '书签', () => open('bookmarks')),
          _entry(
            Icons.edit_note,
            '为本章添加笔记',
            () => close(_editNote),
            arrow: false,
          ),
          const Divider(indent: 18, endIndent: 18),
          _entry(_flowIcon, '阅读模式', () => open('reading'), detail: _flowLabel),
          _entry(Icons.tune, '画面调整', () => close(_showPictureAdjustments)),
          _entry(
            _preferences.zoomLocked ? Icons.lock : Icons.lock_open,
            '缩放',
            () => open('zoom'),
            detail: _preferences.zoomLocked ? '已锁定' : '未锁定',
          ),
          _entry(
            Icons.touch_app_outlined,
            '点击区域',
            () => open('zones'),
            detail: _preferences.tapZones == 'disabled' ? '已禁用' : '已启用',
          ),
          _entry(
            Icons.translate,
            '翻译',
            () => open('translation'),
            detail: _translationScope == 'off'
                ? '关闭'
                : '${const {'page': '当前页', 'chapter': '本章', 'series': '本系列'}[_translationScope]}'
                      ' · ${_translationBusy
                          ? '正在翻译…'
                          : _translations.isEmpty
                          ? '无识别结果'
                          : '已翻译 ${_translations.length} 页'}',
          ),
          _entry(
            Icons.volume_up_outlined,
            '朗读',
            () => close(() {
              _refresh(() {
                _speechPanelOpened = true;
                _speechMini = true;
              });
              _showComicSpeechPanel();
            }),
            arrow: false,
          ),
          _entry(
            Icons.bedtime_outlined,
            '睡眠定时器',
            () => close(_showSleepTimer),
            detail: _sleepDeadline == null
                ? null
                : '将在 ${_sleepDeadline!.hour.toString().padLeft(2, '0')}:${_sleepDeadline!.minute.toString().padLeft(2, '0')} 停止',
          ),
          _entry(
            Icons.dashboard_customize_outlined,
            '自定义工具栏…',
            () => close(_showToolbarEditor),
          ),
          _entry(Icons.speed, '自动滚动速度', () => close(_showAutoSettings)),
          const Divider(indent: 18, endIndent: 18),
          _entry(
            Icons.settings_outlined,
            '完整阅读设置',
            () => close(_openReaderSettings),
          ),
          _entry(
            Icons.feedback_outlined,
            '报告问题',
            () => close(
              () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const LogReportPage(exporter: LogExporter()),
                ),
              ),
            ),
          ),
        ];
    }
  }

  void _setFlow(String flow) {
    _stopAutoScroll();
    _preferences.flow = flow;
    final mode = flow == 'webtoon'
        ? ComicReadingMode.waterfall
        : flow == 'spread'
        ? ComicReadingMode.doublePage
        : ComicReadingMode.single;
    _updateSettings(
      _settings.copyWith(
        mode: mode,
        direction: flow == 'rtl'
            ? ComicReadingDirection.rightToLeft
            : ComicReadingDirection.leftToRight,
      ),
    );
    _rebuildControllers();
    _primeWindow();
    _saveExperience();
  }

  String get _orientationLabel => const {
    'device': '跟随设备',
    'portrait': '竖屏',
    'landscape': '横屏',
  }[_preferences.orientation]!;
  Future<void> _applyOrientation() =>
      SystemChrome.setPreferredOrientations(switch (_preferences.orientation) {
        'portrait' => [
          DeviceOrientation.portraitUp,
          DeviceOrientation.portraitDown,
        ],
        'landscape' => [
          DeviceOrientation.landscapeLeft,
          DeviceOrientation.landscapeRight,
        ],
        _ => DeviceOrientation.values,
      });

  Widget _buildContinuous() => NotificationListener<ScrollNotification>(
    onNotification: _onPagedScroll,
    child: PageView.builder(
      controller: _pageController,
      pageSnapping: false,
      scrollDirection: _preferences.flow == 'vertical'
          ? Axis.vertical
          : Axis.horizontal,
      onPageChanged: _onPageChanged,
      itemCount: _displayPages.length,
      itemBuilder: (context, index) => Padding(
        padding: EdgeInsets.symmetric(
          horizontal: _settings.marginOf(_viewport.width),
        ),
        child: _tileFor(_displayPages[index].$1, half: _displayPages[index].$2),
      ),
    ),
  );

  void _stepPage(int delta) {
    if (_images.isEmpty || _loading) return;
    if (_settings.mode == ComicReadingMode.waterfall) {
      final controller = _scrollController;
      if (controller == null || !controller.hasClients) return;
      controller.animateTo(
        (controller.offset + delta * _viewport.height * .8).clamp(
          0.0,
          controller.position.maxScrollExtent,
        ),
        duration: const Duration(milliseconds: 240),
        curve: Curves.easeOut,
      );
    } else {
      _turnPage(delta);
    }
  }

  int _tapDelta(Offset point, Size size) {
    final x = point.dx / size.width, y = point.dy / size.height;
    var delta = 0;
    switch (_preferences.tapZones) {
      case 'vertical':
        delta = y < .3
            ? -1
            : y > .7
            ? 1
            : 0;
      case 'horizontal':
        delta = x < .3
            ? -1
            : x > .7
            ? 1
            : 0;
      case 'lshape':
        delta = x < .22
            ? -1
            : (x > .78 || y > .75)
            ? 1
            : 0;
      case 'edge':
        delta = x < .16
            ? -1
            : x > .84
            ? 1
            : 0;
      case 'custom':
        delta =
            _preferences.customZones[(y * 3).floor().clamp(0, 2) * 3 +
                (x * 3).floor().clamp(0, 2)];
      case 'kindle':
        delta = x < .22
            ? -1
            : (y > .2 && x > .4)
            ? 1
            : 0;
    }
    if (_preferences.reverseZones) delta = -delta;
    if (_preferences.tapZones != 'vertical' && _settings.isRightToLeft) {
      delta = -delta;
    }
    return delta;
  }

  Widget _tapZonePreview() => LayoutBuilder(
    builder: (context, c) => Stack(
      children: [
        for (var y = 0; y < 10; y++)
          for (var x = 0; x < 10; x++)
            Positioned(
              left: c.maxWidth * x / 10,
              top: c.maxHeight * y / 10,
              width: c.maxWidth / 10,
              height: c.maxHeight / 10,
              child: ColoredBox(
                color: (switch (_tapDelta(
                  Offset(
                    c.maxWidth * (x + .5) / 10,
                    c.maxHeight * (y + .5) / 10,
                  ),
                  c.biggest,
                )) {
                  -1 => Colors.blue,
                  1 => Colors.green,
                  _ => Colors.grey,
                }).withValues(alpha: .23),
              ),
            ),
        const Center(
          child: Text(
            '蓝色：上一页 · 绿色：下一页\n灰色：工具栏',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Colors.white,
              fontSize: 14,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ],
    ),
  );

  Widget _adjustSlider(
    String label,
    IconData icon,
    double value,
    double min,
    double max,
    void Function(double) onChanged, {
    String? display,
    bool normalized = false,
  }) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 8, 20, 6),
    child: Column(
      children: [
        Row(
          children: [
            LumeIcon(
              icon,
              slot: 'comic_reader_chrome.7',
              variant: true,
              size: 22,
            ),
            const SizedBox(width: 10),
            Text(label),
            const Spacer(),
            Text(
              display ??
                  '${((normalized ? (value - min) / (max - min) : value) * 100).round()}%',
              style: const TextStyle(color: Colors.grey, fontSize: 13),
            ),
          ],
        ),
        Slider(
          activeColor: _readerAccent,
          value: value.clamp(min, max),
          min: min,
          max: max,
          onChanged: onChanged,
        ),
      ],
    ),
  );

  Future<void> _showPictureAdjustments() => _readerSheet(
    '画面调整',
    (update) => ListView(
      children: [
        _adjustSlider(
          '亮度',
          Icons.wb_sunny_outlined,
          _preferences.brightness,
          .15,
          1,
          (v) {
            _refresh(() => _preferences.brightness = v);
            update(() {});
            _saveExperience();
          },
          display: '${(_preferences.brightness * 100).round()}%',
        ),
        _adjustSlider(
          '色温',
          Icons.thermostat_outlined,
          _preferences.warmth,
          0,
          1,
          (v) {
            _refresh(() => _preferences.warmth = v);
            update(() {});
            _saveExperience();
          },
        ),
        const Divider(indent: 20, endIndent: 20),
        _adjustSlider('锐度', Icons.flare, _preferences.sharpness, 0, 2, (v) {
          _refresh(() => _preferences.sharpness = v);
          _saveExperience();
          update(() {});
        }, normalized: true),
        _adjustSlider('对比度', Icons.contrast, _preferences.contrast, .5, 1.5, (
          v,
        ) {
          _refresh(() => _preferences.contrast = v);
          update(() {});
          _saveExperience();
        }, normalized: true),
        _adjustSlider('伽马', Icons.tonality, _preferences.gamma, .5, 2, (v) {
          _refresh(() => _preferences.gamma = v);
          _saveExperience();
          update(() {});
        }, normalized: true),
        SwitchListTile(
          activeThumbColor: _readerAccent,
          title: const Text('降噪'),
          secondary: const LumeIcon(
            Icons.auto_fix_high_outlined,
            slot: 'comic_reader_chrome.8',
          ),
          value: _preferences.denoise,
          onChanged: (v) {
            _refresh(() => _preferences.denoise = v);
            _saveExperience();
            update(() {});
          },
        ),
        SwitchListTile(
          activeThumbColor: _readerAccent,
          title: const Text('灰度'),
          secondary: const LumeIcon(
            Icons.filter_b_and_w,
            slot: 'comic_reader_chrome.9',
          ),
          value: _preferences.grayscale,
          onChanged: (v) {
            _refresh(() => _preferences.grayscale = v);
            update(() {});
            _saveExperience();
          },
        ),
        SwitchListTile(
          activeThumbColor: _readerAccent,
          title: const Text('反转颜色'),
          secondary: const LumeIcon(
            Icons.invert_colors,
            slot: 'comic_reader_chrome.10',
          ),
          value: _preferences.inverted,
          onChanged: (v) {
            _refresh(() => _preferences.inverted = v);
            update(() {});
            _saveExperience();
          },
        ),
        Padding(
          padding: const EdgeInsets.all(20),
          child: FilledButton.tonal(
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFE4E4E4),
              foregroundColor: _readerAccent,
              shape: const StadiumBorder(),
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
            onPressed: () {
              _refresh(() {
                _preferences.brightness = 1;
                _preferences.warmth = 0;
                _preferences.contrast = 1;
                _preferences.gamma = 1;
                _preferences.sharpness = 0;
                _preferences.denoise = false;
                _preferences.grayscale = false;
                _preferences.inverted = false;
              });
              _saveExperience();
              update(() {});
            },
            child: const Text('重置为默认', style: TextStyle(color: _readerAccent)),
          ),
        ),
      ],
    ),
    leading: (_) => IconButton(
      tooltip: '图片处理模型',
      icon: const LumeIcon(
        Icons.auto_fix_high_outlined,
        slot: 'comic_reader_chrome.11',
      ),
      onPressed: () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => const ComicImageToolsSettingsPage(),
        ),
      ),
    ),
    grouped: true,
  );

  Future<void> _showLayoutAdjustments() => _readerSheet(
    '调整边距',
    (update) => ListView(
      children: [
        _adjustSlider(
          '侧边距',
          Icons.space_bar,
          _settings.marginRatio,
          0,
          ComicReaderSettings.maxMarginRatio,
          (v) {
            _updateSettings(_settings.copyWith(marginRatio: v));
            update(() {});
          },
        ),
        _adjustSlider(
          '页间距',
          Icons.height,
          _settings.pageGap,
          0,
          ComicReaderSettings.maxPageGap,
          (v) {
            _updateSettings(_settings.copyWith(pageGap: v));
            update(() {});
          },
          display: '${_settings.pageGap.round()}',
        ),
      ],
    ),
    height: .46,
  );

  Future<void> _showCropAdjustments() => _readerSheet(
    '裁剪边距',
    (update) => ListView(
      children: [
        _adjustSlider('裁剪比例', Icons.crop, _preferences.cropRatio, 0, .15, (
          value,
        ) {
          _refresh(() => _preferences.cropRatio = value);
          _saveExperience();
          update(() {});
        }),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 20),
          child: Text(
            '从图片四边等比例裁去留白，不修改原图；分享页面会应用当前裁剪。',
            style: TextStyle(color: Colors.grey, fontSize: 13),
          ),
        ),
        TextButton(
          onPressed: () {
            _refresh(() => _preferences.cropRatio = 0);
            _saveExperience();
            update(() {});
          },
          child: const Text('关闭裁剪'),
        ),
      ],
    ),
    height: .42,
  );

  Future<void> _showCustomTapZones() => _readerSheet(
    '自定义点击区域',
    (update) => ListView(
      padding: const EdgeInsets.all(20),
      children: [
        const Text(
          '点按格子切换：上一页 → 工具栏 → 下一页。',
          style: TextStyle(color: Colors.grey, fontSize: 13),
        ),
        const SizedBox(height: 16),
        AspectRatio(
          aspectRatio: .8,
          child: GridView.count(
            physics: const NeverScrollableScrollPhysics(),
            crossAxisCount: 3,
            childAspectRatio: .8,
            children: [
              for (var index = 0; index < 9; index++)
                Padding(
                  padding: const EdgeInsets.all(3),
                  child: Material(
                    color: (switch (_preferences.customZones[index]) {
                      -1 => Colors.blue,
                      1 => Colors.green,
                      _ => Colors.grey,
                    }).withValues(alpha: .15),
                    borderRadius: BorderRadius.circular(12),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(12),
                      onTap: () {
                        _refresh(
                          () => _preferences.customZones[index] =
                              _preferences.customZones[index] == 1
                              ? -1
                              : _preferences.customZones[index] + 1,
                        );
                        _saveExperience();
                        update(() {});
                      },
                      child: Center(
                        child: Text(switch (_preferences.customZones[index]) {
                          -1 => '上一页',
                          1 => '下一页',
                          _ => '工具栏',
                        }, style: const TextStyle(fontSize: 13)),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    ),
    height: .72,
  );

  Future<void> _showAutoSettings() => _readerSheet(
    '自动滚动',
    (update) => ListView(
      children: [
        _adjustSlider('滚动速度', Icons.speed, _preferences.autoSpeed, 10, 120, (
          v,
        ) {
          _refresh(() => _preferences.autoSpeed = v);
          _saveExperience();
          update(() {});
        }, display: '${_preferences.autoSpeed.round()} 像素 / 秒'),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 22),
          child: Text(
            '条漫、垂直及水平滚动模式连续移动；翻页模式定时翻页。到章末自动进入下一章。',
            style: TextStyle(color: Colors.grey, fontSize: 13),
          ),
        ),
      ],
    ),
    height: .4,
  );

  Future<void> _showSleepTimer() => _readerSheet(
    '睡眠定时器',
    (update) => ListView(
      children: [
        for (final minutes in [5, 10, 15, 20, 30, 45, 60, 90])
          _entry(Icons.bedtime_outlined, '$minutes 分钟', () {
            _sleepTimer?.cancel();
            _refresh(
              () => _sleepDeadline = DateTime.now().add(
                Duration(minutes: minutes),
              ),
            );
            _sleepTimer = Timer(Duration(minutes: minutes), () {
              if (!mounted) return;
              _stopAutoScroll();
              unawaited(_stopComicSpeech());
              _speechStatus.value = '睡眠定时已停止朗读';
              _refresh(() => _sleepDeadline = null);
            });
            Navigator.pop(context);
          }, arrow: false),
        _entry(
          Icons.timer_off_outlined,
          '取消定时器',
          () {
            _sleepTimer?.cancel();
            _refresh(() => _sleepDeadline = null);
            Navigator.pop(context);
          },
          color: _readerAccent,
          arrow: false,
        ),
      ],
    ),
    height: .65,
  );

  Future<void> _showToolbarEditor() async {
    var editing = false;
    await _readerSheet(
      '自定义工具栏',
      (update) {
        const labels = {
          'auto': '自动滚动',
          'slider': '页面滑块',
          'thumbnails': '页面缩略图',
          'chapters': '章节',
        };
        const icons = {
          'auto': Icons.play_arrow,
          'slider': Icons.tune,
          'thumbnails': Icons.view_week_outlined,
          'chapters': Icons.format_list_bulleted,
        };
        void save() {
          _saveExperience();
          _refresh(() {});
          update(() {});
        }

        void hide(String id) {
          if (id == 'slider') return;
          _preferences.toolbar.remove(id);
          save();
        }

        return ListView(
          padding: const EdgeInsets.symmetric(horizontal: 18),
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text('可见', style: const TextStyle(color: Colors.grey)),
            ),
            _readerGroup(
              ReorderableListView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                buildDefaultDragHandles: false,
                itemCount: _preferences.toolbar.length,
                onReorderItem: (oldIndex, newIndex) {
                  if (!editing) return;
                  final id = _preferences.toolbar.removeAt(oldIndex);
                  _preferences.toolbar.insert(newIndex, id);
                  save();
                },
                itemBuilder: (context, index) {
                  final id = _preferences.toolbar[index];
                  return Dismissible(
                    key: ValueKey('comic.toolbar.$id'),
                    direction: id == 'slider'
                        ? DismissDirection.none
                        : DismissDirection.endToStart,
                    background: Container(
                      alignment: Alignment.centerRight,
                      padding: const EdgeInsets.only(right: 20),
                      decoration: BoxDecoration(
                        color: _readerAccent,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: const LumeIcon(
                        Icons.visibility_off_outlined,
                        slot: 'comic_reader_chrome.12',
                        color: Colors.white,
                      ),
                    ),
                    onDismissed: (_) => hide(id),
                    child: ReorderableDelayedDragStartListener(
                      index: index,
                      enabled: editing,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          ListTile(
                            leading: LumeIcon(
                              icons[id],
                              slot: 'comic_reader_chrome.13',
                              variant: true,
                            ),
                            title: Text(labels[id]!),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (id == 'slider')
                                  const Text(
                                    '必填',
                                    style: TextStyle(
                                      color: Colors.grey,
                                      fontSize: 12,
                                    ),
                                  )
                                else if (editing)
                                  IconButton(
                                    tooltip: '隐藏',
                                    icon: const LumeIcon(
                                      Icons.remove_circle_outline,
                                      slot: 'comic_reader_chrome.14',
                                      color: _readerAccent,
                                    ),
                                    onPressed: () => hide(id),
                                  ),
                                if (editing)
                                  ReorderableDragStartListener(
                                    index: index,
                                    child: const Padding(
                                      padding: EdgeInsets.only(left: 12),
                                      child: LumeIcon(
                                        Icons.drag_handle,
                                        slot: 'comic_reader_chrome.15',
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                          if (index < _preferences.toolbar.length - 1)
                            const Divider(height: 1, indent: 56, endIndent: 18),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 10, 16, 18),
              child: Text(
                '点按“编辑”可拖动排序；向左滑动隐藏按钮。页面滑块始终保留。',
                style: TextStyle(fontSize: 12, color: Colors.grey),
              ),
            ),
            const Padding(
              padding: EdgeInsets.all(12),
              child: Text('已隐藏', style: TextStyle(color: Colors.grey)),
            ),
            _readerGroup(
              Column(
                children: [
                  for (final id in labels.keys.where(
                    (id) => !_preferences.toolbar.contains(id),
                  ))
                    ListTile(
                      key: ValueKey('comic.toolbar.restore.$id'),
                      leading: LumeIcon(
                        icons[id],
                        slot: 'comic_reader_chrome.16',
                        variant: true,
                      ),
                      title: Text(labels[id]!),
                      trailing: const LumeIcon(
                        Icons.add_circle,
                        slot: 'comic_reader_chrome.17',
                      ),
                      onTap: () {
                        _preferences.toolbar.add(id);
                        save();
                      },
                    ),
                ],
              ),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 10, 16, 12),
              child: Text(
                '点按按钮即可放回栏中。',
                style: TextStyle(fontSize: 12, color: Colors.grey),
              ),
            ),
            const SizedBox(height: 20),
            TextButton.icon(
              style: TextButton.styleFrom(
                backgroundColor: Colors.white,
                alignment: Alignment.centerLeft,
                padding: const EdgeInsets.all(18),
              ),
              icon: const LumeIcon(
                Icons.restart_alt,
                slot: 'comic_reader_chrome.18',
                color: _readerAccent,
              ),
              onPressed: () {
                _preferences.toolbar = ['auto', 'slider', 'thumbnails'];
                save();
              },
              label: const Text(
                '重置为默认',
                style: TextStyle(color: _readerAccent),
              ),
            ),
          ],
        );
      },
      grouped: true,
      leading: (update) => TextButton(
        key: const Key('comic.toolbar.edit'),
        onPressed: () => update(() => editing = !editing),
        child: Text(
          editing ? '结束' : '编辑',
          style: const TextStyle(fontSize: 12, color: _readerAccent),
        ),
      ),
    );
  }

  Future<void> _showThumbnails() async {
    if (_autoScrolling) _stopAutoScroll();
    final selected = await showModalBottomSheet<int>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => SizedBox(
        height: MediaQuery.sizeOf(context).height * .6,
        child: _glass(
          Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 10, 10, 4),
                child: Row(
                  children: [
                    const Expanded(
                      child: Text(
                        '页面缩略图',
                        style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: '关闭',
                      onPressed: () => Navigator.pop(sheetContext),
                      icon: const LumeIcon(
                        Icons.close,
                        slot: 'comic_reader_chrome.19',
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: GridView.builder(
                  padding: const EdgeInsets.all(16),
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 110,
                    childAspectRatio: .62,
                    crossAxisSpacing: 10,
                    mainAxisSpacing: 12,
                  ),
                  itemCount: _images.length,
                  itemBuilder: (context, index) => InkWell(
                    onTap: () => Navigator.pop(sheetContext, index),
                    child: Column(
                      children: [
                        Expanded(
                          child: Container(
                            clipBehavior: Clip.antiAlias,
                            decoration: BoxDecoration(
                              color: Colors.black12,
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                color: index == _page
                                    ? _readerAccent
                                    : Colors.transparent,
                                width: 2,
                              ),
                            ),
                            child: _ComicImageTile(
                              pipeline: _pipeline,
                              url: _images[index],
                              index: index,
                              decodeWidth: 160,
                              loadBytes: widget.pageBytes,
                              doubleTapZoom: false,
                              onLongPress: () {},
                            ),
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '${index + 1}',
                          style: TextStyle(
                            fontSize: 12,
                            color: index == _page
                                ? _readerAccent
                                : Colors.black54,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
          radius: 30,
        ),
      ),
    );
    if (selected != null && mounted) _goToPage(selected);
  }

  String get _annotationKey =>
      'comic.annotations.${widget.target.sourceId}.${widget.target.itemId}';
  Map<String, dynamic> _annotations() {
    try {
      final value = jsonDecode(widget.library.setting(_annotationKey) ?? '{}');
      return value is Map ? Map<String, dynamic>.from(value) : {};
    } catch (_) {
      return {};
    }
  }

  String get _chapterFlag =>
      '${_annotations()['flag:${_chapters.isEmpty ? '' : _chapters[_chapterIndex].id}'] ?? ''}';
  void _setChapterFlag(String flag) {
    if (_chapters.isEmpty) return;
    final data = _annotations();
    data['flag:${_chapters[_chapterIndex].id}'] = flag;
    widget.library.setSetting(_annotationKey, jsonEncode(data));
  }

  Future<String?> _editNote({
    bool pageNote = false,
    ComicBookmark? bookmark,
  }) async {
    if (_chapters.isEmpty) return null;
    final chapterId = bookmark?.chapterId ?? _chapters[_chapterIndex].id;
    final page = bookmark?.page ?? _page;
    final notePosition =
        bookmark ??
        ComicBookmark(
          chapterIndex: _chapterIndex,
          chapterId: chapterId,
          chapterTitle: _chapters[_chapterIndex].title,
          page: page,
          createdAt: DateTime.now(),
        );
    final key = pageNote ? 'page-note:$chapterId:$page' : 'note:$chapterId';
    final data = _annotations();
    final controller = TextEditingController(text: '${data[key] ?? ''}');
    final note = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(pageNote ? '页面备注' : '章节笔记'),
        content: TextField(
          controller: controller,
          autofocus: true,
          minLines: 3,
          maxLines: 8,
          maxLength: 4000,
          decoration: InputDecoration(
            hintText: pageNote ? '记录这一页的想法…' : '记录这一章的想法…',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, controller.text),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 250));
    controller.dispose();
    if (note == null || !mounted) return null;
    if (pageNote &&
        bookmark == null &&
        !_bookmarks.any(
          (item) => item.chapterId == chapterId && item.page == page,
        )) {
      _writeBookmarks(ComicBookmarks.add(_bookmarks, notePosition));
    }
    final latest = _annotations();
    latest[key] = note;
    widget.library.setSetting(_annotationKey, jsonEncode(latest));
    return note;
  }

  Future<void> _shareCurrentPage() async {
    if (_images.isEmpty || _loading || _sharing) return;
    // Capture the chosen page and settings before asynchronous decoding. A page
    // turn or slider edit must not silently export another page or mixed values.
    final index = _page;
    final url = _images[index];
    final override = _pageOverrides[url];
    final half = _settings.mode == ComicReadingMode.single ? _wideHalf : 0;
    final crop = _preferences.cropRatio;
    final matrix = List<double>.of(_preferences.colorMatrix);
    final brightness = _preferences.brightness;
    final gamma = _preferences.gamma, sharpness = _preferences.sharpness;
    final denoise = _preferences.denoise;
    final translations = List<ComicTextRegion>.of(_translations[url] ?? []);
    final scaler = MediaQuery.textScalerOf(context);
    final fontFamily = Theme.of(context).textTheme.bodyMedium?.fontFamily;
    final width = _settings.mode == ComicReadingMode.doublePage
        ? math.max(1.0, (_innerWidth - _settings.pageGap) / 2)
        : _innerWidth;
    final maxHeight = _settings.mode == ComicReadingMode.waterfall
        ? double.infinity
        : _viewport.height;
    final decodeWidth = _decodeWidth;
    final name = p.setExtension(_fileNameFor(url, index), '.png');
    _refresh(() => _sharing = true);
    ui.Image? source, filtered;
    try {
      final bytes = override ?? await widget.pageBytes?.call(url);
      if (!mounted) return;
      if (bytes != null) {
        final codec = await ui.instantiateImageCodec(
          bytes,
          targetWidth: decodeWidth,
        );
        try {
          source = (await codec.getNextFrame()).image;
        } finally {
          codec.dispose();
        }
      } else {
        final image = await _pipeline.image(url, targetWidth: decodeWidth);
        if (image == null) throw StateError('图片尚未加载');
        try {
          source = image.clone();
        } finally {
          _pipeline.release(url, targetWidth: decodeWidth);
        }
      }
      if (!mounted) return;
      filtered = await filterComicPage(
        source,
        gamma: gamma,
        sharpness: sharpness,
        denoise: denoise,
      );
      if (!mounted) return;
      final rect = comicPageSource(
        Size(filtered.width.toDouble(), filtered.height.toDouble()),
        cropRatio: crop,
        half: half,
      );
      final output = await composeComicPage(
        image: filtered,
        source: rect,
        colorMatrix: matrix,
        brightness: brightness,
        displayWidth: math.min(width, maxHeight * rect.width / rect.height),
        translations: translations,
        textScaler: scaler,
        fontFamily: fontFamily,
      );
      if (!mounted) return;
      await (widget.imageExporter ?? exportProcessedImage)(output, name);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('分享失败：$error')));
      }
    } finally {
      filtered?.dispose();
      source?.dispose();
      _refresh(() => _sharing = false);
    }
  }

  void _setTranslationScope(String scope) {
    _translationGeneration++;
    _translationBusy = false;
    _translationScope = scope;
    final data = _annotations();
    data['translation.scope'] = scope == 'series' ? 'series' : 'off';
    widget.library.setSetting(_annotationKey, jsonEncode(data));
  }

  Future<void> _translatePages(bool chapter) async {
    if (_images.isEmpty || _translationBusy) return;
    final generation = ++_translationGeneration;
    final urls = List<String>.of(_images);
    final current = _page;
    _refresh(() => _translationBusy = true);
    try {
      for (final index
          in chapter ? List<int>.generate(urls.length, (i) => i) : [current]) {
        if (!mounted || generation != _translationGeneration) break;
        final url = urls[index];
        final bytes =
            _pageOverrides[url] ??
            await (widget.pageBytes?.call(url) ?? _pipeline.bytes(url));
        if (!mounted || generation != _translationGeneration) break;
        if (bytes == null) throw StateError('第 ${index + 1} 页未能加载');
        final regions = await _imageTools.translate(bytes);
        if (!mounted || generation != _translationGeneration) break;
        _refresh(() => _translations[url] = regions);
      }
    } catch (error) {
      if (mounted && generation == _translationGeneration) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('翻译失败：$error')));
      }
    } finally {
      if (mounted && generation == _translationGeneration) {
        _refresh(() => _translationBusy = false);
      }
    }
  }

  Widget _buildSpeechMini() => Positioned(
    left: 16,
    right: 16,
    bottom: 88 + MediaQuery.paddingOf(context).bottom,
    child: ValueListenableBuilder<SpeechState>(
      valueListenable: _speechState,
      builder: (context, state, _) => _glass(
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ValueListenableBuilder<ComicSpeechCursor?>(
                valueListenable: _speechCursor,
                builder: (context, cursor, _) {
                  if (cursor == null || cursor.text.isEmpty) {
                    return ValueListenableBuilder<String>(
                      valueListenable: _speechStatus,
                      builder: (context, status, _) => Text(
                        status.isEmpty ? '漫画朗读' : status,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12),
                      ),
                    );
                  }
                  return Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(text: cursor.text.substring(0, cursor.start)),
                        TextSpan(
                          text: cursor.text.substring(cursor.start, cursor.end),
                          style: const TextStyle(
                            color: _readerAccent,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        TextSpan(text: cursor.text.substring(cursor.end)),
                      ],
                    ),
                    key: const Key('comic.speech.highlight'),
                    maxLines: 2,
                    textAlign: TextAlign.center,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 13),
                  );
                },
              ),
              FittedBox(
                fit: BoxFit.scaleDown,
                child: SizedBox(
                  width: 400,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      IconButton(
                        tooltip: '停止朗读',
                        onPressed: () {
                          unawaited(_stopComicSpeech(closePanel: true));
                        },
                        icon: const LumeIcon(
                          Icons.close,
                          slot: 'comic_reader_chrome.20',
                          size: 20,
                        ),
                      ),
                      IconButton(
                        tooltip: '朗读上一页',
                        onPressed: _page > 0
                            ? () {
                                _goToPage(_page - 1);
                                _startComicSpeech(continuous: false);
                              }
                            : null,
                        icon: const LumeIcon(
                          Icons.fast_rewind,
                          slot: 'comic_reader_chrome.21',
                          size: 22,
                        ),
                      ),
                      IconButton(
                        tooltip: state == SpeechState.speaking
                            ? '暂停朗读'
                            : '继续朗读',
                        onPressed: () async {
                          if (state == SpeechState.speaking) {
                            await _speech?.pause();
                          } else if (state == SpeechState.paused) {
                            await _speech?.resume();
                          } else {
                            await _startComicSpeech(continuous: true);
                          }
                        },
                        icon: LumeIcon(
                          state == SpeechState.speaking
                              ? Icons.pause
                              : Icons.play_arrow,
                          slot: 'comic_reader_chrome.22',
                          variant: true,
                        ),
                      ),
                      IconButton(
                        tooltip: '朗读下一页',
                        onPressed: _page + 1 < _images.length
                            ? () {
                                _goToPage(_page + 1);
                                _startComicSpeech(continuous: false);
                              }
                            : null,
                        icon: const LumeIcon(
                          Icons.fast_forward,
                          slot: 'comic_reader_chrome.23',
                          size: 22,
                        ),
                      ),
                      TextButton(
                        key: const Key('comic.speech.speed'),
                        onPressed: _showSpeechSpeed,
                        child: Text(
                          '${(_speechSettings.rate * 2).toStringAsFixed(1)}×',
                          style: const TextStyle(
                            color: Colors.black,
                            fontSize: 12,
                          ),
                        ),
                      ),
                      IconButton(
                        key: _comicVoiceAnchor,
                        tooltip: '声音与朗读设置',
                        onPressed: _showComicVoices,
                        icon: const LumeIcon(
                          Icons.record_voice_over_outlined,
                          slot: 'comic_reader_chrome.24',
                          size: 21,
                        ),
                      ),
                      IconButton(
                        tooltip: '隐藏朗读栏',
                        onPressed: () => _refresh(() => _speechMini = false),
                        icon: const LumeIcon(
                          Icons.visibility_off_outlined,
                          slot: 'comic_reader_chrome.25',
                          size: 21,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        radius: 24,
      ),
    ),
  );

  void _stopAutoScroll() {
    _autoTimer?.cancel();
    _autoTimer = null;
    _refresh(() => _autoScrolling = false);
  }

  void _toggleAutoScroll() {
    if (_autoScrolling) {
      _stopAutoScroll();
      return;
    }
    if (_images.isEmpty || _loading) return;
    _refresh(() => _autoScrolling = true);
    var last = DateTime.now();
    double pageElapsed = 0;
    _autoTimer = Timer.periodic(const Duration(milliseconds: 32), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      final now = DateTime.now();
      final seconds = now.difference(last).inMicroseconds / 1000000;
      last = now;
      final lifecycle = WidgetsBinding.instance.lifecycleState;
      if (lifecycle != null && lifecycle != AppLifecycleState.resumed) return;
      if (_loading) return;
      final ScrollController? controller =
          _settings.mode == ComicReadingMode.waterfall
          ? _scrollController
          : _settings.mode == ComicReadingMode.single &&
                ['vertical', 'horizontal'].contains(_preferences.flow)
          ? _pageController
          : null;
      if (controller != null && controller.hasClients) {
        final next = controller.offset + _preferences.autoSpeed * seconds;
        if (next >= controller.position.maxScrollExtent) {
          if (_chapterIndex + 1 < _chapters.length) {
            _openChapter(_chapterIndex + 1);
          } else {
            _stopAutoScroll();
          }
        } else {
          controller.jumpTo(next);
        }
      } else {
        pageElapsed += seconds;
        if (pageElapsed < 240 / _preferences.autoSpeed) return;
        pageElapsed = 0;
        final count = _settings.mode == ComicReadingMode.doublePage
            ? _settings.spreadCount(_images.length)
            : _displayPages.length;
        final current = (_pageController?.page ?? 0).round();
        if (current + 1 < count) {
          _turnPage(1);
        } else if (_chapterIndex + 1 < _chapters.length) {
          _openChapter(_chapterIndex + 1);
        } else {
          _stopAutoScroll();
        }
      }
    });
  }
}
