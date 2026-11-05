import '../../shared/widgets/native_glass_surfaces.dart';

import 'package:lume_box/shared/widgets/lume_icon.dart';

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/media/playback_focus.dart';
import '../../core/speech/speech_advanced.dart';
import '../../core/speech/speech_segments.dart';
import '../../core/speech/speech_cloud.dart';
import '../../core/speech/speech_local.dart';
import '../../core/speech/speech_settings.dart';
import '../../core/speech/speech_voice_labels.dart';

class SpeechModesPanel extends StatefulWidget {
  const SpeechModesPanel({
    super.key,
    required this.settings,
    required this.onChanged,
    this.selectorOnly = false,
    this.optionsOnly = false,
    this.singleSpeaker = false,
    this.localModel,
  });
  final bool selectorOnly, optionsOnly;

  /// 单说话人模式（漫画 OCR 朗读）：隐藏「自动切换对话音色」，
  /// 并强制只用旁白音色。
  final bool singleSpeaker;
  final SpeechSettings settings;
  final ValueChanged<SpeechSettings> onChanged;
  final SpeechLocalModel? localModel;
  @override
  State<SpeechModesPanel> createState() => _SpeechModesPanelState();
}

class _SpeechModesPanelState extends State<SpeechModesPanel> {
  late final model = widget.localModel ?? SpeechLocalModel.instance;
  var _selectionGeneration = 0;
  final _systemVoiceLabels = <String, String>{};
  Timer? _voiceTimeout;
  Completer<List<dynamic>?>? _voiceRequest;
  @override
  void initState() {
    super.initState();
    // Tests/unsupported devices may have no platform path provider.
    if (!widget.optionsOnly) {
      unawaited(model.check().catchError((_) => false));
      unawaited(KokoroModel.instance.check().catchError((_) => false));
    }
    if (widget.settings.mode == SpeechMode.system) {
      unawaited(_loadVoiceLabels());
    }
  }

  @override
  void didUpdateWidget(SpeechModesPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.settings.mode == SpeechMode.system &&
        oldWidget.settings.mode != SpeechMode.system) {
      unawaited(_loadVoiceLabels());
    }
  }

  Future<void> _loadVoiceLabels() async {
    if (widget.selectorOnly) return;
    _cancelVoiceLookup();
    final request = _voiceRequest = Completer<List<dynamic>?>();
    void complete(List<dynamic>? value) {
      if (!request.isCompleted) request.complete(value);
    }

    _voiceTimeout = Timer(const Duration(seconds: 5), () => complete(null));
    unawaited(
      const MethodChannel('lumebox/speech')
          .invokeListMethod<dynamic>('speechVoices')
          .then(complete, onError: (Object _) => complete(null)),
    );
    final data = await request.future;
    if (!mounted || !identical(request, _voiceRequest)) return;
    _cancelVoiceLookup();
    setState(() {
      for (final voice in data ?? []) {
        if (voice is Map && voice['id'] is String) {
          _systemVoiceLabels[voice['id'] as String] = SpeechVoiceLabels.label(
            voice,
          );
        }
      }
    });
  }

  void _cancelVoiceLookup() {
    _voiceTimeout?.cancel();
    final request = _voiceRequest;
    _voiceRequest = null;
    if (request != null && !request.isCompleted) request.complete(null);
  }

  @override
  void dispose() {
    _cancelVoiceLookup();
    super.dispose();
  }

  void _selectMode(SpeechMode value) {
    if (value == SpeechMode.kokoro && !KokoroModel.instance.ready) {
      setState(() => _selectionGeneration++);
      unawaited(_installKokoro());
      return;
    }
    if (value == SpeechMode.local && !model.ready) {
      // The form field otherwise displays its just-picked value while the
      // installation dialog is cancelled, despite retaining the system engine.
      setState(() => _selectionGeneration++);
      unawaited(_installOffline(selectWhenReady: true));
      return;
    }
    widget.onChanged(
      widget.settings.copyWith(
        mode: value,
        autoDialogue: widget.singleSpeaker ? false : null,
      ),
    );
  }

  Future<void> _installKokoro() async {
    final accepted = await showGlassDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('下载 Kokoro 离线音色'),
        content: const Text(
          '首次使用需下载约 147 MB 模型，安装期间建议预留至少 600 MiB 空间；安装后约占 205 MiB。完成后可离线使用。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('下载'),
          ),
        ],
      ),
    );
    if (accepted != true || !mounted) return;
    final kokoro = KokoroModel.instance;
    final installed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const _KokoroInstallDialog(),
    );
    if (!mounted) return;
    if (installed == true) {
      _selectMode(SpeechMode.kokoro);
    } else if (kokoro.error != null && kokoro.error != '已取消') {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(
          content: Text(kokoro.error!),
          action: SnackBarAction(label: '重试', onPressed: _installKokoro),
        ),
      );
    }
  }

  Future<void> _removeKokoro() async {
    final accepted = await showGlassDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除 Kokoro 音色包？'),
        content: const Text('请先停止朗读。删除后再次使用需要重新下载；VITS 音色不受影响。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (accepted != true || !mounted) return;
    try {
      await KokoroModel.instance.remove();
      if (!mounted) return;
      if (widget.settings.mode == SpeechMode.kokoro) {
        widget.onChanged(widget.settings.copyWith(mode: SpeechMode.system));
      }
      setState(() {});
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)
            ?.showSnackBar(const SnackBar(content: Text('删除失败，请停止朗读后重试')));
      }
    }
  }

  Future<void> _installOffline({bool selectWhenReady = false}) async {
    if (model.preparing) return;
    final fromFile = await showGlassDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('启用本地离线朗读'),
        content: const SingleChildScrollView(
          child: Text(
            '这是普通话离线音色包，压缩资源约 147 MB，支持 174 种音色。'
            '首次使用需联网下载，安装期间建议预留至少 600 MiB 空间；安装后可离线使用。\n\n'
            '也可从“文件”选择完整的 vits-zh-aishell3.tar.bz2 包。'
            '安装完成后即可选择本地模式；系统朗读无需安装这个包。',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('从文件安装'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('下载并安装'),
          ),
        ],
      ),
    );
    if (fromFile == null || !mounted) return;
    final installed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _LocalInstallDialog(model: model, fromFile: fromFile),
    );
    if (!mounted) return;
    if (installed == true) {
      if (selectWhenReady) _selectMode(SpeechMode.local);
      ScaffoldMessenger.maybeOf(context)
          ?.showSnackBar(const SnackBar(content: Text('离线音色包已就绪，可使用本地朗读')));
    } else if (model.error != null && model.error != '已取消') {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(
          content: Text(model.error!),
          action: SnackBarAction(
            label: '重试',
            onPressed: () => _installOffline(selectWhenReady: selectWhenReady),
          ),
        ),
      );
    }
  }

  Future<void> _removeOffline() async {
    final accepted = await showGlassDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除本地离线音色包？'),
        content: const Text('请先停止朗读。删除后再次使用需要重新下载；Kokoro 音色不受影响。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (accepted != true || !mounted) return;
    try {
      await model.remove();
      if (!mounted) return;
      if (widget.settings.mode == SpeechMode.local) {
        widget.onChanged(widget.settings.copyWith(mode: SpeechMode.system));
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)
            ?.showSnackBar(const SnackBar(content: Text('删除失败，请停止朗读后重试')));
      }
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: model,
    builder: (context, _) => Column(
      children: [
        if (!widget.optionsOnly)
          DropdownButtonFormField<SpeechMode>(
            key: ValueKey('${widget.settings.mode.name}:$_selectionGeneration'),
            initialValue: widget.settings.mode,
            isExpanded: true,
            decoration: const InputDecoration(labelText: '听书模式'),
            items: [
              for (final mode in SpeechMode.values)
                DropdownMenuItem(
                  value: mode,
                  enabled: !model.preparing || mode != SpeechMode.local,
                  child: Text(
                    '${mode.label}${mode == SpeechMode.local && !model.ready ? '（先启用音色包）' : ''}',
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
            onChanged: (value) {
              if (value != null) _selectMode(value);
            },
          ),
        if (!widget.selectorOnly) ...[
          if (!widget.singleSpeaker)
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: const Text('自动识别对话并切换音色'),
              subtitle: const Text('关闭后全程使用旁白音色'),
              value: widget.settings.autoDialogue,
              onChanged: (value) => widget.onChanged(
                widget.settings.copyWith(autoDialogue: value),
              ),
            ),
          if (!widget.singleSpeaker)
            const ExpansionTile(
              title: Text('多人音色怎么设置？'),
              childrenPadding: EdgeInsets.fromLTRB(16, 0, 16, 12),
              children: [
                Text(
                  '1. 选择听书模式；离线模式首次使用需先下载音色包。\n'
                  '2. 打开“自动识别对话并切换音色”。\n'
                  '3. 分别点“旁白音色”“男声音色”“女声音色”，为三个角色选择不同声音。\n'
                  '4. 返回阅读页开始朗读，语速、音调与音量也可分别调整。\n\n'
                  '普通识别主要处理“角色名：台词”格式，其他对话可能仍由旁白朗读；AI 增强需配置在线接口，判断也可能出错。当前最多区分旁白、男声、女声三类，不能为四个具体人物分别指定音色。',
                ),
              ],
            ),
          if (!model.ready)
            TextButton.icon(
              onPressed: model.preparing ? null : _installOffline,
              icon: model.preparing
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const LumeIcon(
                      Icons.download_for_offline_outlined,
                      slot: 'speech_modes_panel.1',
                    ),
              label: Text(
                model.preparing ? '正在安装音色包…' : '下载 sherpa-onnx 离线音色包（约 147 MB）',
              ),
            ),
          if (!model.ready)
            const Padding(
              padding: EdgeInsets.only(bottom: 8),
              child: Text(
                '用于普通话离线朗读，首次使用需安装；系统朗读可直接使用。',
                style: TextStyle(fontSize: 12),
              ),
            ),
          if (model.present || model.ready)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: Text(model.ready ? '离线音色包已就绪' : '离线音色包损坏，请删除后重新下载'),
              subtitle: const Text('sherpa-onnx · 普通话 VITS'),
              trailing: TextButton(
                onPressed: model.preparing ? null : _removeOffline,
                child: const Text('删除'),
              ),
            ),
          if (model.error != null)
            Text(
              model.error!,
              style: TextStyle(
                fontWeight: FontWeight.w600,
                color: Theme.of(context).colorScheme.error,
              ),
            ),
          ListenableBuilder(
            listenable: KokoroModel.instance,
            builder: (context, _) => KokoroModel.instance.present
                ? ListTile(
                    dense: true,
                    title: Text(
                      KokoroModel.instance.ready
                          ? 'Kokoro 离线音色已安装'
                          : 'Kokoro 音色包损坏，请删除后重新下载',
                    ),
                    trailing: TextButton(
                      onPressed: _removeKokoro,
                      child: const Text('删除'),
                    ),
                  )
                : const SizedBox.shrink(),
          ),
          for (final role in ['旁白', '男声', '女声'])
            if (role == '旁白' ||
                (!widget.singleSpeaker && widget.settings.autoDialogue))
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text('$role音色'),
                subtitle: Text(_voiceLabel(role)),
                trailing: const LumeIcon(
                  Icons.edit_outlined,
                  slot: 'speech_modes_panel.2',
                  size: 18,
                ),
                onTap: () => _editVoice(role),
              ),
          if (widget.settings.mode == SpeechMode.cloud ||
              widget.settings.mode == SpeechMode.cloudAi)
            TextButton.icon(
              icon: const LumeIcon(
                Icons.settings_ethernet,
                slot: 'speech_modes_panel.3',
              ),
              label: const Text('配置在线接口与密钥'),
              onPressed: () => showGlassDialog<void>(
                context: context,
                builder: (_) => const _CloudSettingsDialog(),
              ),
            ),
        ],
      ],
    ),
  );
  String _voice(String role) => role == '旁白'
      ? widget.settings.narratorVoice
      : role == '男声'
      ? widget.settings.maleVoice
      : widget.settings.femaleVoice;
  String _voiceLabel(String role) {
    final value = _voice(role);
    if (value.isEmpty) return '系统默认';
    if (widget.settings.mode == SpeechMode.system) {
      return _systemVoiceLabels[value] ?? '已选系统音色';
    }
    return widget.settings.mode == SpeechMode.local ? '音色 $value' : value;
  }

  Future<void> _editVoice(String role) async {
    final value = await showGlassDialog<String>(
      context: context,
      builder: (_) => _SpeechVoiceDialog(
        role: role,
        settings: widget.settings,
        value: _voice(role),
      ),
    );
    if (value == null || !mounted) return;
    if (widget.settings.mode == SpeechMode.local &&
        (int.tryParse(value) == null ||
            int.parse(value) < 0 ||
            int.parse(value) > 173)) {
      return;
    }
    widget.onChanged(
      widget.settings.copyWith(
        narratorVoice: role == '旁白' ? value : null,
        maleVoice: role == '男声' ? value : null,
        femaleVoice: role == '女声' ? value : null,
      ),
    );
  }
}

class _LocalInstallDialog extends StatefulWidget {
  const _LocalInstallDialog({required this.model, required this.fromFile});
  final SpeechLocalModel model;
  final bool fromFile;
  @override
  State<_LocalInstallDialog> createState() => _LocalInstallDialogState();
}

class _LocalInstallDialogState extends State<_LocalInstallDialog> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_run());
    });
  }

  Future<void> _run() async {
    final ok = await widget.model.prepare(fromFile: widget.fromFile);
    if (mounted) Navigator.pop(context, ok);
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: false,
    child: ListenableBuilder(
      listenable: widget.model,
      builder: (context, _) => AlertDialog(
        title: const Text('安装 sherpa-onnx 离线音色'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.model.phase),
            const SizedBox(height: 12),
            LinearProgressIndicator(value: widget.model.progress),
            if (widget.model.progress != null)
              Text('${(widget.model.progress! * 100).floor()}%'),
            const SizedBox(height: 8),
            const Text('解压期间取消可能需要等待当前步骤结束。'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: widget.model.phase == '正在取消'
                ? null
                : widget.model.cancel,
            child: const Text('取消'),
          ),
        ],
      ),
    ),
  );
}

class _KokoroInstallDialog extends StatefulWidget {
  const _KokoroInstallDialog();
  @override
  State<_KokoroInstallDialog> createState() => _KokoroInstallDialogState();
}

class _KokoroInstallDialogState extends State<_KokoroInstallDialog> {
  final model = KokoroModel.instance;
  @override
  void initState() {
    super.initState();
    unawaited(_run());
  }

  Future<void> _run() async {
    final ok = await model.install();
    if (mounted) Navigator.pop(context, ok);
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: false,
    child: ListenableBuilder(
      listenable: model,
      builder: (context, _) => AlertDialog(
        title: const Text('安装 Kokoro 音色'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(model.phase),
            const SizedBox(height: 12),
            LinearProgressIndicator(value: model.progress),
            if (model.progress != null)
              Text('${(model.progress! * 100).floor()}%'),
            const SizedBox(height: 8),
            const Text('解压期间取消可能需要等待当前步骤结束。'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: model.phase == '正在取消' ? null : model.cancel,
            child: const Text('取消'),
          ),
        ],
      ),
    ),
  );
}

class _CloudSettingsDialog extends StatefulWidget {
  const _CloudSettingsDialog();
  @override
  State<_CloudSettingsDialog> createState() => _CloudSettingsDialogState();
}

class _CloudSettingsDialogState extends State<_CloudSettingsDialog> {
  final config = SpeechCloudConfig.instance;
  final mimoKey = TextEditingController();
  final ttsUrl = TextEditingController();
  final ttsModel = TextEditingController();
  final ttsKey = TextEditingController();
  final llmUrl = TextEditingController();
  final llmModel = TextEditingController();
  final llmKey = TextEditingController();
  final azureRegion = TextEditingController();
  final azureKey = TextEditingController();
  final volcAppId = TextEditingController();
  final volcToken = TextEditingController();
  final volcCluster = TextEditingController();
  SpeechTtsProvider provider = SpeechTtsProvider.openai;
  bool loaded = false, busy = false;
  String? error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<String> _key(String kind, [String endpoint = '']) async {
    if (endpoint.isEmpty && (kind == 'azure' || kind == 'volc')) return '';
    try {
      return await config.key(
        kind,
        forEndpoint: endpoint.isEmpty ? null : endpoint,
      );
    } catch (_) {
      // 地址或服务商改过：旧密钥不再匹配，留空让用户重填。
      return '';
    }
  }

  Future<void> _load() async {
    try {
      await config.load();
      final values = await Future.wait([
        _key('tts', config.ttsUrl),
        _key('llm', config.llmUrl),
        _key('azure', config.azureRegion.trim()),
        _key('volc', config.volcAppId.trim()),
        _key('mimo', 'https://api.xiaomimimo.com/v1'),
      ]);
      if (!mounted) return;
      provider = config.ttsProvider;
      ttsUrl.text = config.ttsUrl;
      ttsModel.text = config.ttsModel;
      ttsKey.text = values[0];
      llmUrl.text = config.llmUrl;
      llmModel.text = config.llmModel;
      llmKey.text = values[1];
      azureRegion.text = config.azureRegion;
      azureKey.text = values[2];
      volcAppId.text = config.volcAppId;
      volcToken.text = values[3];
      volcCluster.text = config.volcCluster;
      mimoKey.text = values[4];
      setState(() => loaded = true);
    } catch (_) {
      if (mounted) setState(() => error = '无法读取本机接口配置');
    }
  }

  @override
  void dispose() {
    for (final field in [
      mimoKey,
      ttsUrl,
      ttsModel,
      ttsKey,
      llmUrl,
      llmModel,
      llmKey,
      azureRegion,
      azureKey,
      volcAppId,
      volcToken,
      volcCluster,
    ]) {
      field.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => busy = true);
    try {
      final selected = provider;
      if (selected == SpeechTtsProvider.openai) {
        final url = ttsUrl.text.trim();
        if (url.isNotEmpty) {
          SpeechCloudConfig.endpoint(url, '/audio/speech');
        }
        if (ttsModel.text.trim().isEmpty) {
          throw const FormatException('请填写 TTS 模型名称');
        }
        config.ttsUrl = url;
        config.ttsModel = ttsModel.text.trim();
        if (ttsKey.text.trim().isNotEmpty) {
          await config.setKey('tts', ttsKey.text.trim(), forEndpoint: url);
        }
      } else if (selected == SpeechTtsProvider.mimo) {
        const endpoint = 'https://api.xiaomimimo.com/v1';
        final typed = mimoKey.text.trim();
        if (typed.isNotEmpty) {
          await config.setKey('mimo', typed, forEndpoint: endpoint);
        } else if ((await _key('mimo', endpoint)).isEmpty) {
          throw const FormatException('请填写 MiMo API Key');
        }
      } else if (selected == SpeechTtsProvider.azure) {
        final region = azureRegion.text.trim().toLowerCase();
        if (!RegExp(r'^[a-z0-9-]+$').hasMatch(region)) {
          throw const FormatException('请填写 Azure 区域，例如 eastasia');
        }
        config.azureRegion = region;
        final typed = azureKey.text.trim();
        if (typed.isNotEmpty) {
          await config.setKey('azure', typed, forEndpoint: region);
        } else if ((await _key('azure', region)).isEmpty) {
          throw const FormatException('请填写 Azure Speech 密钥');
        }
      } else {
        final appId = volcAppId.text.trim();
        if (appId.isEmpty) {
          throw const FormatException('请填写火山引擎 AppID');
        }
        config.volcAppId = appId;
        config.volcCluster = volcCluster.text.trim().isEmpty
            ? 'volcano_tts'
            : volcCluster.text.trim();
        final typed = volcToken.text.trim();
        if (typed.isNotEmpty) {
          await config.setKey('volc', typed, forEndpoint: appId);
        } else if ((await _key('volc', appId)).isEmpty) {
          throw const FormatException('请填写火山引擎 Access Token');
        }
      }
      final llmEndpoint = llmUrl.text.trim();
      if (llmEndpoint.isNotEmpty) {
        SpeechCloudConfig.endpoint(llmEndpoint, '/chat/completions');
      }
      config.llmUrl = llmEndpoint;
      config.llmModel = llmModel.text.trim();
      await config.setKey('llm', llmKey.text.trim(), forEndpoint: llmEndpoint);
      if (config.llmModel.isNotEmpty &&
          !config.llmModels.contains(config.llmModel)) {
        config.llmModels.add(config.llmModel);
      }
      config.ttsProvider = selected;
      await config.save();
      if (mounted) Navigator.pop(context);
    } catch (error) {
      if (mounted) {
        setState(
          () => this.error = error is FormatException
              ? error.message
              : '保存失败，请检查接口地址和本机密钥访问权限',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Widget _field(
    TextEditingController controller,
    String label, {
    bool secret = false,
    String? hint,
    String? helper,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: TextField(
      controller: controller,
      enabled: loaded && !busy,
      obscureText: secret,
      autocorrect: false,
      enableSuggestions: false,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        helperText: helper,
        helperMaxLines: 3,
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('在线 TTS 接口'),
    content: SizedBox(
      width: 420,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!loaded && error == null) const LinearProgressIndicator(),
            DropdownButtonFormField<SpeechTtsProvider>(
              key: ValueKey(provider),
              initialValue: provider,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'TTS 服务商'),
              items: [
                for (final value in SpeechTtsProvider.values)
                  DropdownMenuItem(value: value, child: Text(value.label)),
              ],
              onChanged: loaded && !busy
                  ? (value) {
                      if (value != null) setState(() => provider = value);
                    }
                  : null,
            ),
            const SizedBox(height: 12),
            if (provider == SpeechTtsProvider.openai) ...[
              _field(ttsUrl, 'TTS 地址', hint: 'https://…/v1'),
              _field(ttsModel, 'TTS 模型'),
              _field(ttsKey, 'TTS API-Key', secret: true),
            ] else if (provider == SpeechTtsProvider.mimo) ...[
              _field(mimoKey, 'MiMo API Key', secret: true),
              const Text(
                '音色填写：冰糖、茉莉、苏打、白桦、Mia、Chloe、Milo 或 Dean。正文会发送到小米进行语音合成。',
              ),
            ] else if (provider == SpeechTtsProvider.azure) ...[
              _field(
                azureRegion,
                'Azure 区域',
                hint: 'eastasia / japaneast / westus',
                helper: '区域在 Azure 语音资源的「密钥和终结点」页面查看。',
              ),
              _field(azureKey, 'Azure Speech 密钥', secret: true),
              const Padding(
                padding: EdgeInsets.only(bottom: 12),
                child: Text(
                  '音色填完整 Azure 名称（如 zh-CN-XiaoxiaoNeural）；'
                  '留空或沿用 alloy / onyx / nova 会自动映射到中文音色。',
                ),
              ),
            ] else ...[
              _field(volcAppId, 'AppID'),
              _field(volcToken, 'Access Token', secret: true),
              _field(volcCluster, 'Cluster', hint: 'volcano_tts'),
              const Padding(
                padding: EdgeInsets.only(bottom: 12),
                child: Text(
                  '音色填火山的 voice_type（如 BV700_streaming）；'
                  '需使用已开通语音合成、且支持 PCM 的音色。',
                ),
              ),
            ],
            const Divider(height: 24),
            const Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'AI 增强（可选，OpenAI 兼容大模型）',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
            const SizedBox(height: 8),
            _field(llmUrl, '大模型地址', hint: 'https://…/v1'),
            _field(llmModel, '大模型名称'),
            _field(llmKey, '大模型 API-Key', secret: true),
            if (config.llmModels.isNotEmpty)
              DropdownButtonFormField<String>(
                decoration: const InputDecoration(labelText: '已保存的大模型'),
                isExpanded: true,
                items: [
                  for (final name in config.llmModels)
                    DropdownMenuItem(value: name, child: Text(name)),
                ],
                onChanged: (value) {
                  if (value != null) llmModel.text = value;
                },
              ),
            const SizedBox(height: 8),
            const Text(
              '密钥仅保存在本机钥匙串；调用时仅发往对应的服务商。'
              '简易模式不请求大模型；切换服务商或地址后需重新保存对应密钥。',
            ),
            if (error != null)
              Text(
                error!,
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  color: Theme.of(context).colorScheme.error,
                ),
              ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: busy ? null : () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: loaded && !busy ? _save : null,
        child: const Text('保存'),
      ),
    ],
  );
}

class _SpeechVoiceDialog extends StatefulWidget {
  const _SpeechVoiceDialog({
    required this.role,
    required this.settings,
    required this.value,
  });
  final String role, value;
  final SpeechSettings settings;
  SpeechMode get mode => settings.mode;
  @override
  State<_SpeechVoiceDialog> createState() => _SpeechVoiceDialogState();
}

class _SpeechVoiceDialogState extends State<_SpeechVoiceDialog> {
  late final controller = TextEditingController(text: widget.value);
  List<(String, String)> voices = [];
  static const _methods = MethodChannel('lumebox/speech');
  final _preview = AdvancedSpeechSource(_methods);
  bool _busy = false;

  Future<void> _stopPreview() async {
    _preview.cancel();
    try {
      await _methods.invokeMethod<void>('stop');
    } on MissingPluginException {
      // No speech engine is installed on this platform.
    } on PlatformException {
      // The engine may already have been torn down.
    }
  }

  Future<void> _tryVoice() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await PlaybackFocus.acquire('speech_preview');
      if (!mounted) return;
      await _stopPreview();
      if (!mounted) return;
      const text = '你好，这是一段语音试听，欢迎使用朗读功能。';
      final settings = widget.settings.copyWith(
        narratorVoice: controller.text.trim(),
        autoDialogue: false,
        backgroundPlayback: false,
      );
      if (settings.mode == SpeechMode.system) {
        await _methods.invokeMethod<void>('speak', {
          'text': text,
          'rate': settings.rate,
          'pitch': settings.pitch,
          'volume': settings.volume,
          'voice': settings.narratorVoice,
          'background': false,
        });
      } else {
        await _preview.speak(
          const SpeechSegment(text: text, start: 0),
          settings,
          focusOwner: 'speech_preview',
          onError: (message) {
            if (mounted) {
              ScaffoldMessenger.of(context)
                  .showSnackBar(SnackBar(content: Text('试听失败：$message')));
            }
          },
        );
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('试听失败：$error')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void initState() {
    super.initState();
    PlaybackFocus.register('speech_preview', _stopPreview);
    if (widget.mode == SpeechMode.system) unawaited(_load());
    if ((widget.mode == SpeechMode.cloud ||
            widget.mode == SpeechMode.cloudAi) &&
        SpeechCloudConfig.instance.ttsProvider == SpeechTtsProvider.mimo) {
      voices = [
        for (final voice in [
          '冰糖',
          '茉莉',
          '苏打',
          '白桦',
          'Mia',
          'Chloe',
          'Milo',
          'Dean',
        ])
          (voice, voice),
      ];
      if (!voices.any((v) => v.$1 == controller.text)) controller.text = '冰糖';
    }
    if (widget.mode == SpeechMode.local || widget.mode == SpeechMode.kokoro) {
      voices = [
        for (var i = 0; i < (widget.mode == SpeechMode.kokoro ? 103 : 174); i++)
          (
            '$i',
            widget.mode == SpeechMode.kokoro
                ? (i < 3
                      ? '英文音色 $i'
                      : i < 58
                      ? '中文女声 $i'
                      : '中文男声 $i')
                : '音色 $i',
          ),
      ];
      if (controller.text.isEmpty) controller.text = '0';
    }
  }

  Future<void> _load() async {
    try {
      final data = await const MethodChannel('lumebox/speech')
          .invokeListMethod<dynamic>('speechVoices');
      if (!mounted) return;
      setState(
        () => voices = [
          ('', '系统默认'),
          for (final voice in data ?? [])
            if (voice is Map && voice['id'] is String)
              (voice['id'] as String, SpeechVoiceLabels.label(voice)),
        ],
      );
    } catch (_) {
      /* Keep the original system default available. */
    }
  }

  @override
  void dispose() {
    PlaybackFocus.unregister('speech_preview', _stopPreview);
    if (PlaybackFocus.owner == 'speech_preview') {
      unawaited(_stopPreview());
    } else {
      _preview.cancel();
    }
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text('${widget.role}音色'),
    content: SizedBox(
      width: 360,
      child: voices.isEmpty
          ? TextField(
              controller: controller,
              decoration: const InputDecoration(
                labelText: '音色标识',
                helperText: '填写服务商的 voice 名称，系统模式可留空',
              ),
            )
          : DropdownButtonFormField<String>(
              initialValue: controller.text,
              isExpanded: true,
              items: [
                for (final voice in voices)
                  DropdownMenuItem(
                    value: voice.$1,
                    child: Text(voice.$2, overflow: TextOverflow.ellipsis),
                  ),
                if (!voices.any((v) => v.$1 == controller.text))
                  DropdownMenuItem(
                    value: controller.text,
                    child: Text(controller.text),
                  ),
              ],
              onChanged: (value) {
                if (value != null) controller.text = value;
              },
            ),
    ),
    actions: [
      TextButton.icon(
        onPressed: _busy ? null : _tryVoice,
        icon: const Icon(Icons.volume_up_outlined),
        label: const Text('试听'),
      ),
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(context, controller.text.trim()),
        child: const Text('保存'),
      ),
    ],
  );
}
