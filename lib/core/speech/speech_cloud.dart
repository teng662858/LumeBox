import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'speech_turns.dart';

/// 在线 TTS 服务商。对话/停顿规划仍走 OpenAI 兼容的大模型接口。
enum SpeechTtsProvider {
  openai('OpenAI 兼容'),
  mimo('小米 MiMo'),
  azure('Azure Speech'),
  volcengine('火山引擎');

  const SpeechTtsProvider(this.label);

  final String label;

  static SpeechTtsProvider parse(Object? name) =>
      values.where((provider) => provider.name == name).firstOrNull ?? openai;
}

/// Non-secret preferences live in one local file. Secrets use the device-only
/// Keychain and are never included in this JSON or a request to another host.
class SpeechCloudConfig {
  static final instance = SpeechCloudConfig();
  SpeechTtsProvider ttsProvider = SpeechTtsProvider.openai;
  String ttsUrl = '', ttsModel = '', llmUrl = '', llmModel = '';

  /// Azure：区域（如 eastasia）；火山引擎：AppID 与集群。
  String azureRegion = '', volcAppId = '', volcCluster = 'volcano_tts';
  List<String> llmModels = [];
  Future<void>? _loading;
  static const _channel = MethodChannel('lumebox/speech');
  Future<File> get _file async => File(
    '${(await getApplicationSupportDirectory()).path}/speech_cloud.json',
  );
  Future<void> load() => _loading ??= _load();
  Future<void> _load() async {
    final file = await _file;
    if (!await file.exists()) return;
    try {
      final data = jsonDecode(await file.readAsString());
      if (data is! Map) return;
      String field(String key) =>
          data[key] is String ? data[key] as String : '';
      ttsProvider = SpeechTtsProvider.parse(data['ttsProvider']);
      ttsUrl = field('ttsUrl');
      ttsModel = field('ttsModel');
      azureRegion = field('azureRegion');
      volcAppId = field('volcAppId');
      final cluster = field('volcCluster');
      volcCluster = cluster.isEmpty ? 'volcano_tts' : cluster;
      llmUrl = field('llmUrl');
      llmModel = field('llmModel');
      if (data['llmModels'] is List) {
        llmModels = (data['llmModels'] as List)
            .whereType<String>()
            .toSet()
            .toList();
      }
    } on FormatException {
      /* Corrupt configuration has safe empty defaults. */
    }
  }

  Future<void> save() async {
    final file = await _file;
    await file.parent.create(recursive: true);
    final temp = File('${file.path}.tmp');
    await temp.writeAsString(
      jsonEncode({
        'ttsProvider': ttsProvider.name,
        'ttsUrl': ttsUrl,
        'ttsModel': ttsModel,
        'azureRegion': azureRegion,
        'volcAppId': volcAppId,
        'volcCluster': volcCluster,
        'llmUrl': llmUrl,
        'llmModel': llmModel,
        'llmModels': llmModels,
      }),
      flush: true,
    );
    await temp.rename(file.path);
  }

  int revision = 0;
  Future<String> key(String kind, {String? forEndpoint}) async {
    final raw =
        await _channel.invokeMethod<String>('speechGetKey', {'kind': kind}) ??
        '';
    if (raw.isEmpty) return '';
    final record = jsonDecode(raw);
    final expected = (forEndpoint ?? (kind == 'tts' ? ttsUrl : llmUrl)).trim();
    if (record is! Map ||
        record['endpoint'] != expected ||
        record['key'] is! String) {
      throw const FormatException('接口地址已改变，请重新保存对应密钥');
    }
    return record['key'] as String;
  }

  Future<void> setKey(String kind, String key, {String? forEndpoint}) async {
    revision++;
    await _channel.invokeMethod<void>('speechSetKey', {
      'kind': kind,
      'key': key.isEmpty
          ? ''
          : jsonEncode({
              'endpoint': (forEndpoint ?? (kind == 'tts' ? ttsUrl : llmUrl))
                  .trim(),
              'key': key,
            }),
    });
  }

  static Uri endpoint(String raw, String suffix) {
    final uri = Uri.tryParse(raw.trim());
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment) {
      throw const FormatException('请填写有效的 HTTPS 接口地址');
    }
    final path = uri.path.replaceAll(RegExp(r'/+$'), '');
    if (path.endsWith(suffix)) return uri.replace(path: path);
    return uri.replace(
      path: '$path${path.endsWith('/v1') ? '' : '/v1'}$suffix',
    );
  }
}

class SpeechProviderException implements Exception {
  const SpeechProviderException(this.message);
  final String message;
}

class SpeechCloudClient {
  SpeechCloudClient(this.config, {http.Client? client})
    : client = client ?? http.Client();
  final SpeechCloudConfig config;
  final http.Client client;
  void close() => client.close();

  Future<http.StreamedResponse> _post(
    Uri uri,
    String key,
    Map<String, Object?> body,
  ) async {
    final request = http.Request('POST', uri)
      ..followRedirects = false
      ..headers.addAll({
        'Content-Type': 'application/json',
        if (key.isNotEmpty) 'Authorization': 'Bearer $key',
      })
      ..body = jsonEncode(body);
    final response = await client
        .send(request)
        .timeout(const Duration(seconds: 15));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      // Do not copy provider bodies/headers: they may contain credentials.
      await response.stream.listen(null).cancel();
      if (uri.host == 'api.xiaomimimo.com') {
        final message = switch (response.statusCode) {
          401 => 'MiMo 密钥无效，请检查 API Key',
          403 => 'MiMo 拒绝访问，请检查账号权限',
          402 => 'MiMo 账户余额或额度不足，请到平台核对',
          429 => 'MiMo 请求过于频繁或额度受限，请稍后重试并检查额度',
          >= 500 => 'MiMo 服务暂时不可用，请稍后重试',
          _ => 'MiMo 请求失败（${response.statusCode}），请检查配置',
        };
        throw SpeechProviderException(message);
      }
      throw HttpException('语音服务返回 ${response.statusCode}');
    }
    return response;
  }

  Future<List<SpeechTurn>> annotate(String chapter) async {
    await config.load();
    if (config.llmModel.trim().isEmpty) {
      throw const FormatException('请填写大模型名称');
    }
    final address = config.llmUrl;
    final response = await _post(
      SpeechCloudConfig.endpoint(address, '/chat/completions'),
      await config.key('llm', forEndpoint: address),
      {
        'model': config.llmModel,
        'stream': false,
        'messages': [
          {
            'role': 'system',
            'content': 'Return only SSML <speak>. Keep every character of the user chapter in its original order, without rewriting, summarizing or omission. Use <voice name="narrator|male|female"> for narration and dialogue, and <break time="250ms"/> for pauses. No other voice names. No markdown.',
          },
          {'role': 'user', 'content': chapter},
        ],
      },
    );
    final bytes = <int>[];
    await for (final chunk in response.stream.timeout(
      const Duration(seconds: 15),
    )) {
      bytes.addAll(chunk);
      if (bytes.length > chapter.length * 24 + 65536) {
        throw const FormatException('大模型返回内容过大');
      }
    }
    final data = jsonDecode(utf8.decode(bytes));
    final content = data['choices'][0]['message']['content'];
    if (content is! String) throw const FormatException('大模型响应格式无效');
    return SpeechTurns.ssml(content, chapter);
  }

  /// Raw signed 16-bit mono PCM at 24 kHz. Awaiting the consumer provides
  /// backpressure all the way from the native audio queue to HTTP.
  Stream<List<int>> audio(String text, String voice, double speed) async* {
    await config.load();
    switch (config.ttsProvider) {
      case SpeechTtsProvider.openai:
        yield* _openAiAudio(text, voice, speed);
      case SpeechTtsProvider.mimo:
        yield* _mimoAudio(text, voice, speed);
      case SpeechTtsProvider.azure:
        yield* _azureAudio(text, voice, speed);
      case SpeechTtsProvider.volcengine:
        yield* _volcengineAudio(text, voice, speed);
    }
  }

  Stream<List<int>> _mimoAudio(String text, String voice, double speed) async* {
    const base = 'https://api.xiaomimimo.com/v1';
    final key = await config.key('mimo', forEndpoint: base);
    if (key.isEmpty) throw const FormatException('请填写 MiMo API Key');
    const voices = {'冰糖', '茉莉', '苏打', '白桦', 'Mia', 'Chloe', 'Milo', 'Dean'};
    final selected = voices.contains(voice) ? voice : '冰糖';
    final response = await _post(Uri.parse('$base/chat/completions'), key, {
      'model': 'mimo-v2.5-tts',
      'stream': true,
      'messages': [
        {'role': 'user', 'content': '请以自然的旁白风格朗读，语速倍率约 ${speed.clamp(.5, 2)}。'},
        {'role': 'assistant', 'content': text},
      ],
      'audio': {'format': 'pcm16', 'voice': selected},
    });
    var found = false;
    await for (final line
        in response.stream
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .timeout(const Duration(seconds: 30))) {
      if (!line.startsWith('data:')) continue;
      final payload = line.substring(5).trim();
      if (payload.isEmpty || payload == '[DONE]') continue;
      final value = jsonDecode(payload);
      if (value is! Map || value['choices'] is! List) {
        throw const FormatException('MiMo 响应格式无效');
      }
      for (final choice in value['choices'] as List) {
        if (choice is! Map) continue;
        final delta = choice['delta'];
        if (delta is! Map || delta['audio'] is! Map) continue;
        final data = (delta['audio'] as Map)['data'];
        if (data is String && data.isNotEmpty) {
          final bytes = base64Decode(data);
          if (bytes.isNotEmpty) {
            found = true;
            yield bytes;
          }
        }
      }
    }
    if (!found) throw const FormatException('MiMo 未返回音频');
  }

  Stream<List<int>> _openAiAudio(
    String text,
    String voice,
    double speed,
  ) async* {
    if (config.ttsModel.trim().isEmpty) {
      throw const FormatException('请填写 TTS 模型名称');
    }
    final address = config.ttsUrl;
    final response = await _post(
      SpeechCloudConfig.endpoint(address, '/audio/speech'),
      await config.key('tts', forEndpoint: address),
      {
        'model': config.ttsModel,
        'input': text,
        'voice': voice.isEmpty ? 'alloy' : voice,
        'response_format': 'pcm',
        'speed': speed.clamp(.25, 4),
      },
    );
    yield* _pcm(response);
  }

  /// Azure Speech：请求 raw-24khz-16bit-mono-pcm，正好接现有原生 PCM 队列。
  ///
  /// 音色填写完整 Azure 名称（如 `zh-CN-XiaoxiaoNeural`）；沿用 OpenAI 默认的
  /// `alloy / onyx / nova` 时映射到常用的中文音色，避免切服务商后直接报错。
  Stream<List<int>> _azureAudio(
    String text,
    String voice,
    double speed,
  ) async* {
    final region = config.azureRegion.trim().toLowerCase();
    if (!RegExp(r'^[a-z0-9-]+$').hasMatch(region)) {
      throw const FormatException('请填写 Azure 区域，例如 eastasia');
    }
    final key = await config.key('azure', forEndpoint: region);
    if (key.isEmpty) throw const FormatException('请填写 Azure Speech 密钥');
    final request =
        http.Request(
            'POST',
            Uri.https(
              '$region.tts.speech.microsoft.com',
              '/cognitiveservices/v1',
            ),
          )
          ..followRedirects = false
          ..headers.addAll({
            'Ocp-Apim-Subscription-Key': key,
            'Content-Type': 'application/ssml+xml',
            'X-Microsoft-OutputFormat': 'raw-24khz-16bit-mono-pcm',
            'User-Agent': 'LumeBox',
          })
          ..body = azureSsml(text, voice, speed);
    yield* _pcm(await _send(request));
  }

  /// 火山引擎语音合成（HTTP 非流式）：请求 pcm，响应里的 base64 音频解码后
  /// 按 24 KB 一块交给原生队列，和 OpenAI 分支保持同一种背压粒度。
  Stream<List<int>> _volcengineAudio(
    String text,
    String voice,
    double speed,
  ) async* {
    final appId = config.volcAppId.trim();
    if (appId.isEmpty) throw const FormatException('请填写火山引擎 AppID');
    final cluster = config.volcCluster.trim().isEmpty
        ? 'volcano_tts'
        : config.volcCluster.trim();
    final token = await config.key('volc', forEndpoint: appId);
    if (token.isEmpty) throw const FormatException('请填写火山引擎 Access Token');
    final request =
        http.Request(
            'POST',
            Uri.https('openspeech.bytedance.com', '/api/v1/tts'),
          )
          ..followRedirects = false
          ..headers.addAll({
            'Authorization': 'Bearer;$token',
            'Content-Type': 'application/json',
          })
          ..body = jsonEncode({
            'app': {'appid': appId, 'token': token, 'cluster': cluster},
            'user': {'uid': 'lumebox'},
            'audio': {
              'voice_type': volcVoice(voice),
              'encoding': 'pcm',
              'sample_rate': 24000,
              'speed_ratio': speed.clamp(.2, 3.0),
            },
            'request': {
              'reqid': _requestId(),
              'text': text,
              'operation': 'query',
            },
          });
    final response = await _send(request);
    final body = <int>[];
    await for (final chunk in response.stream.timeout(
      const Duration(seconds: 20),
    )) {
      body.addAll(chunk);
      if (body.length > 8 * 1024 * 1024) {
        throw const FormatException('语音服务响应过大');
      }
    }
    final decoded = jsonDecode(utf8.decode(body));
    if (decoded is! Map ||
        decoded['code'] != 3000 ||
        decoded['data'] is! String) {
      final message = decoded is Map
          ? '${decoded['message'] ?? decoded['code'] ?? ''}'
          : '';
      throw FormatException('火山引擎返回错误${message.isEmpty ? '' : '：$message'}');
    }
    final bytes = base64Decode(decoded['data'] as String);
    if (bytes.isEmpty) throw const FormatException('服务未返回音频');
    for (var offset = 0; offset < bytes.length; offset += 24000) {
      yield bytes.sublist(offset, min(offset + 24000, bytes.length));
    }
  }

  Future<http.StreamedResponse> _send(http.Request request) async {
    final response = await client
        .send(request)
        .timeout(const Duration(seconds: 20));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      await response.stream.listen(null).cancel();
      throw HttpException('语音服务返回 ${response.statusCode}');
    }
    return response;
  }

  Stream<List<int>> _pcm(http.StreamedResponse response) async* {
    var size = 0;
    await for (final bytes in response.stream.timeout(
      const Duration(seconds: 20),
    )) {
      size += bytes.length;
      if (size > 48 * 1024 * 1024) throw const FormatException('音频响应过大');
      yield bytes;
    }
    if (size == 0) throw const FormatException('服务未返回音频');
  }

  /// 组装 Azure SSML。速度入参与 OpenAI 分支一致（1.0 = 原速），
  /// 转成 Azure 的百分比；文本按 XML 元素转义，避免正文里的 `<`/`&` 破坏 SSML。
  static String azureSsml(String text, String voice, double speed) {
    final selected = voice.trim();
    final name = switch (selected) {
      '' || 'alloy' => 'zh-CN-XiaoxiaoNeural',
      'onyx' => 'zh-CN-YunxiNeural',
      'nova' => 'zh-CN-XiaoyiNeural',
      _ => selected,
    };
    if (!RegExp(r'^[A-Za-z0-9():._-]+$').hasMatch(name)) {
      throw const FormatException('Azure 音色名称无效');
    }
    final language = name.split('-').take(2).join('-');
    final rate = ((speed.clamp(.5, 2.0) - 1) * 100).round();
    final escaped = const HtmlEscape(HtmlEscapeMode.element).convert(text);
    return '<speak version="1.0" '
        'xmlns="http://www.w3.org/2001/10/synthesis" xml:lang="$language">'
        '<voice name="$name"><prosody rate="${rate >= 0 ? '+' : ''}$rate%">'
        '$escaped</prosody></voice></speak>';
  }

  /// 火山引擎音色：沿用 OpenAI 默认名时映射到常见音色，其余按 `voice_type` 原样发送。
  /// 本地模型的数字音色下标不能被当成 voice_type 发出去。
  static String volcVoice(String voice) {
    final selected = voice.trim();
    if (selected.isEmpty || int.tryParse(selected) != null) {
      return 'BV700_streaming';
    }
    return switch (selected) {
      'alloy' => 'BV700_streaming',
      'onyx' => 'BV705_streaming',
      'nova' => 'BV001_streaming',
      _ => selected,
    };
  }

  static String _requestId() {
    final random = Random();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex = bytes
        .map((value) => value.toRadixString(16).padLeft(2, '0'))
        .join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }
}
