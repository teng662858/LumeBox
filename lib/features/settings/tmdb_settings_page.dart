import '../video/detail_poster_background.dart';

import 'package:flutter_svg/flutter_svg.dart';

import '../../shared/widgets/native_glass_controls.dart';
import '../../shared/widgets/native_glass_surfaces.dart';

import 'package:lume_box/shared/widgets/lume_icon.dart';

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../core/tmdb/tmdb.dart';
import '../../core/tmdb/tmdb_connection_failure.dart';
import '../../core/net/lume_net.dart';
import '../../shared/widgets/glass_card.dart';
import 'settings_ui.dart';

class TmdbSettingsPage extends StatefulWidget {
  const TmdbSettingsPage({
    super.key,
    this.appearanceKey,
    this.loadPreview,
    this.focusAppearance,
    this.previewColor,
    this.clientFactory,
  });
  final String? appearanceKey, focusAppearance;
  final Color? previewColor;
  final Future<Uint8List?> Function()? loadPreview;
  final TmdbClient Function(TmdbSettings)? clientFactory;
  @override
  State<TmdbSettingsPage> createState() => _TmdbSettingsPageState();
}

class _TmdbSettingsPageState extends State<TmdbSettingsPage> {
  final settings = TmdbSettings.instance;
  late final keyText = TextEditingController(text: settings.apiKey);
  late final api = TextEditingController(text: settings.apiProxy);
  late final image = TextEditingController(text: settings.imageProxy);
  late bool workOnly =
      widget.appearanceKey != null &&
      settings.detailOverrides.value.containsKey(widget.appearanceKey);
  late final Future<Uint8List?> preview =
      widget.loadPreview?.call() ?? Future.value();
  final focusKey = GlobalKey();
  TmdbDetailAppearance get appearance =>
      settings.appearanceFor(workOnly ? widget.appearanceKey : null);
  void updateAppearance(TmdbDetailAppearance value) =>
      settings.setAppearance(workOnly ? widget.appearanceKey : null, value);
  @override
  void initState() {
    super.initState();
    if (widget.focusAppearance != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final target = focusKey.currentContext;
        if (target != null) Scrollable.ensureVisible(target, alignment: .4);
      });
    }
  }

  bool testing = false;
  void save() {
    settings.apiKey = keyText.text;
    settings.apiProxy = api.text;
    settings.imageProxy = image.text;
    settings.save();
  }

  @override
  void dispose() {
    keyText.dispose();
    api.dispose();
    image.dispose();
    super.dispose();
  }

  Future<void> test(bool isApi) async {
    if (testing) return;
    save();
    setState(() => testing = true);
    final client = widget.clientFactory?.call(settings) ?? TmdbClient(settings);
    var message = '测试成功';
    try {
      if (isApi) {
        await client.testApi();
      } else {
        final bytes = await client.testImage();
        final codec = await ui.instantiateImageCodec(Uint8List.fromList(bytes));
        final frame = await codec.getNextFrame();
        frame.image.dispose();
        codec.dispose();
      }
    } catch (error) {
      message = TmdbConnectionFailure.describe(
        error,
        api: isApi,
        customEndpoint: (isApi ? settings.apiProxy : settings.imageProxy)
            .trim()
            .isNotEmpty,
        globalProxy: LumeNet.settings.proxy.trim().isNotEmpty,
      );
    } finally {
      client.dispose();
      if (mounted) setState(() => testing = false);
    }
    if (mounted) {
      await showGlassDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(
            isApi
                ? (settings.apiProxy.trim().isEmpty ? '测试 API 连接' : '测试 API 代理')
                : (settings.imageProxy.trim().isEmpty ? '测试图片连接' : '测试 图片代理'),
          ),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('确定'),
            ),
          ],
        ),
      );
    }
  }

  Future<void> disconnect() async {
    final yes = await showGlassDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('断开连接'),
        content: const Text('清除本机保存的 API Key 和两个代理地址，并关闭 TMDB？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('断开'),
          ),
        ],
      ),
    );
    if (yes != true) return;
    await settings.disconnect();
    keyText.clear();
    api.clear();
    image.clear();
  }

  Widget appearanceSlider(String label, String field, double min, double max) {
    final value = appearance.toJson()[field]!;
    return ConstrainedBox(
      key: widget.focusAppearance == field ? focusKey : null,
      constraints: const BoxConstraints(minHeight: 48),
      child: Row(
        children: [
          SizedBox(
            width: 86,
            child: Text(label, style: const TextStyle(fontSize: 12)),
          ),
          Expanded(
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 2,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
              ),
              child: Slider(
                key: ValueKey('tmdb-appearance-$field'),
                value: value,
                min: min,
                max: max,
                label: '${(value * 100).round()}%',
                onChanged: (next) =>
                    updateAppearance(appearance.withValue(field, next)),
                onChangeEnd: (_) => settings.save(appearanceOnly: true),
              ),
            ),
          ),
          SizedBox(
            width: 40,
            child: Text(
              '${(value * 100).round()}%',
              textAlign: TextAlign.right,
              style: const TextStyle(fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }

  Widget appearanceSection() => ExpansionTile(
    key: const Key('tmdb-appearance-section'),
    initiallyExpanded: widget.focusAppearance != null,
    tilePadding: const EdgeInsets.symmetric(horizontal: 16),
    childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
    title: const Text('详情页外观调节', style: TextStyle(fontSize: 14)),
    subtitle: const Text('背景 · 海报 · 渐变 · 标识', style: TextStyle(fontSize: 12)),
    children: [
      if (widget.appearanceKey != null)
        SwitchListTile.adaptive(
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: const Text('仅此作品使用', style: TextStyle(fontSize: 12)),
          value: workOnly,
          onChanged: (value) {
            if (value) {
              settings.setAppearance(widget.appearanceKey, appearance);
            } else {
              settings.clearAppearance(widget.appearanceKey!);
            }
            setState(() => workOnly = value);
            settings.save(appearanceOnly: true);
          },
        ),
      if (widget.loadPreview != null)
        FutureBuilder<Uint8List?>(
          future: preview,
          builder: (context, snapshot) {
            final bytes = snapshot.data;
            if (bytes == null) return const SizedBox.shrink();
            final color = adjustDetailBackground(
              widget.previewColor ?? const Color(0xff2c343d),
              brightness: appearance.backgroundBrightness,
              saturation: appearance.backgroundSaturation,
            );
            return ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: SizedBox(
                height: 128,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    ColoredBox(color: color),
                    DetailPosterFade(
                      brightness: appearance.posterBrightness,
                      strength: appearance.fadeStrength,
                      child: Image.memory(
                        bytes,
                        cacheWidth: 384,
                        fit: BoxFit.cover,
                        errorBuilder: (_, _, _) => const SizedBox.shrink(),
                      ),
                    ),
                    Positioned(
                      bottom: 8,
                      left: 12,
                      child: Row(
                        children: [
                          const Text(
                            '海报预览',
                            style: TextStyle(color: Colors.white, fontSize: 12),
                          ),
                          const SizedBox(width: 8),
                          SvgPicture.asset(
                            'assets/branding/tmdb.svg',
                            width: 18 * appearance.logoScale,
                            height: 13 * appearance.logoScale,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      Wrap(
        spacing: 8,
        children: [
          for (final preset in {
            '柔和': const TmdbDetailAppearance(
              backgroundSaturation: .7,
              posterBrightness: .95,
              fadeStrength: 1.3,
            ),
            '明亮': const TmdbDetailAppearance(
              backgroundBrightness: 1.5,
              posterBrightness: 1.1,
              fadeStrength: .8,
            ),
            '原图': const TmdbDetailAppearance(fadeStrength: 0),
          }.entries)
            ActionChip(
              label: Text(preset.key),
              onPressed: () {
                updateAppearance(preset.value);
                settings.save(appearanceOnly: true);
              },
            ),
        ],
      ),
      appearanceSlider('背景亮度', 'backgroundBrightness', .3, 2.5),
      appearanceSlider('背景色彩', 'backgroundSaturation', 0, 3),
      appearanceSlider('沉浸海报亮度', 'posterBrightness', .2, 1.8),
      appearanceSlider('沉浸渐变强度', 'fadeStrength', 0, 3),
      appearanceSlider('TMDB标识大小', 'logoScale', .5, 2.5),
      Row(
        children: [
          const Expanded(
            child: Text('实时生效 · 松手自动保存', style: TextStyle(fontSize: 12)),
          ),
          TextButton(
            key: const Key('tmdb-appearance-reset'),
            onPressed: () {
              updateAppearance(const TmdbDetailAppearance());
              settings.save(appearanceOnly: true);
            },
            child: const Text('恢复默认', style: TextStyle(fontSize: 12)),
          ),
        ],
      ),
    ],
  );

  @override
  Widget build(BuildContext context) => GlassScaffold(
    effectModule: GlassModule.settings,
    title: 'TMDB配置',
    child: ListenableBuilder(
      listenable: Listenable.merge([
        settings,
        settings.detailAppearance,
        settings.detailOverrides,
      ]),
      builder: (context, _) => SettingsSurfaceList(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        children: [
          NativeSwitchListTile.adaptive(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: const Text('启用 TMDB', style: TextStyle(fontSize: 14)),
            value: settings.enabled,
            onChanged: (value) {
              settings.enabled = value;
              save();
            },
          ),
          NativeSwitchListTile.adaptive(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: const Text('详情页海报背景', style: TextStyle(fontSize: 14)),
            subtitle: const Text(
              '随海报取色；关闭后使用纯色背景',
              style: TextStyle(fontSize: 12),
            ),
            value: settings.detailBackdropEnabled,
            onChanged: (value) {
              settings.detailBackdropEnabled = value;
              save();
            },
          ),
          appearanceSection(),
          const SizedBox(height: 8),
          const Text('海报展示样式'),
          const SizedBox(height: 10),
          SegmentedButton<TmdbPosterStyle>(
            showSelectedIcon: false,
            style: const ButtonStyle(visualDensity: VisualDensity.compact),
            segments: const [
              ButtonSegment(value: TmdbPosterStyle.fixed, label: Text('固定')),
              ButtonSegment(value: TmdbPosterStyle.random, label: Text('随机')),
              ButtonSegment(value: TmdbPosterStyle.carousel, label: Text('轮播')),
            ],
            selected: {settings.posterStyle},
            onSelectionChanged: (values) {
              settings.posterStyle = values.first;
              save();
            },
          ),
          const SizedBox(height: 12),
          Text('图片', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          LayoutBuilder(
            builder: (context, constraints) {
              final columns = constraints.maxWidth >= 340 ? 2 : 1;
              final width =
                  (constraints.maxWidth - (columns - 1) * 10) / columns;
              return Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  for (final kind in TmdbImageKind.values)
                    SizedBox(
                      width: width,
                      child: DropdownButtonFormField<String>(
                        key: ValueKey('tmdb-image-${kind.name}'),
                        initialValue: settings.imageSize(kind),
                        isExpanded: true,
                        decoration: InputDecoration(
                          labelText: kind.label,
                          isDense: true,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 8,
                          ),
                        ),
                        items: [
                          for (final size in kind.sizes)
                            DropdownMenuItem(
                              value: size,
                              child: Text(
                                size,
                                style: const TextStyle(fontSize: 12),
                              ),
                            ),
                        ],
                        onChanged: (value) {
                          if (value == null) return;
                          settings.setImageSize(kind, value);
                          save();
                        },
                      ),
                    ),
                ],
              );
            },
          ),
          const SizedBox(height: 6),
          const Text('仅影响下载清晰度，不改变页面尺寸。', style: TextStyle(fontSize: 12)),
          const SizedBox(height: 12),
          TextField(
            controller: keyText,
            maxLines: 1,
            autocorrect: false,
            onChanged: (_) => save(),
            decoration: InputDecoration(
              isDense: true,
              labelText: 'API Key',
              hintText: '留空使用内置密钥',
              helperText: '已内置默认密钥；可填写自己的 v3 Key 或 v4 Token',
              suffixIcon: IconButton(
                tooltip: '清除 API Key',
                icon: const LumeIcon(
                  Icons.cancel,
                  slot: 'tmdb_settings_page.1',
                ),
                onPressed: () {
                  keyText.clear();
                  save();
                },
              ),
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: api,
            maxLines: 1,
            onChanged: (_) => save(),
            decoration: const InputDecoration(
              isDense: true,
              labelText: 'API代理地址',
              hintText: 'HTTP(S) API 根地址，留空使用官方地址',
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: image,
            maxLines: 1,
            onChanged: (_) => save(),
            decoration: const InputDecoration(
              isDense: true,
              labelText: '图片代理地址',
              hintText: '例如 https://image.tmdb.org/t/p/，留空使用官方图片地址',
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: testing || !settings.configured
                      ? null
                      : () => test(true),
                  child: Text(
                    settings.apiProxy.trim().isEmpty
                        ? '测试 API 连接'
                        : '测试 API 代理',
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton(
                  onPressed: testing || !settings.enabled
                      ? null
                      : () => test(false),
                  child: Text(
                    settings.imageProxy.trim().isEmpty ? '测试图片连接' : '测试 图片代理',
                  ),
                ),
              ),
            ],
          ),
          if (testing) const LinearProgressIndicator(),
          const SizedBox(height: 12),
          const SettingsFooterNote(
            '配置仅保存在本机。请求时使用所配置的 TMDB／代理服务；不会上传至项目服务器。关闭 TMDB 后不发起请求。',
            padding: EdgeInsets.zero,
          ),
          const SizedBox(height: 12),
          TextButton(
            onPressed: testing ? null : disconnect,
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('断开连接'),
          ),
        ],
      ),
    ),
  );
}
