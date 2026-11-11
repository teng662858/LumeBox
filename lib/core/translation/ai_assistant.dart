import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import '../reading/comic_image_tools_settings.dart';
import '../reading/translation_http_client.dart';
import 'ai_text_translation.dart';

abstract final class AiAssistant {
  static Future<String> request(
    String instruction,
    String input, {
    http.Client? client,
    String? url,
    String? model,
    String? key,
  }) async {
    final settings = ComicImageToolsSettings.instance;
    final uri = AiTextTranslation.endpoint(url ?? settings.endpoint);
    final selectedModel = model ?? settings.model;
    if (selectedModel.trim().isEmpty) {
      throw const FormatException('请在 AI 接口设置中填写模型');
    }
    final credential =
        key ??
        await const MethodChannel('lumebox/comicImages')
            .invokeMethod<String>('getKey') ??
        '';
    if (credential.isEmpty) {
      throw const FormatException('请在 AI 接口设置中保存 API Key');
    }
    if (utf8.encode(input).length > 256 * 1024) {
      throw const FormatException('内容超过 256 KB，请精简后重试');
    }
    final transport = client ?? TranslationHttpClient();
    try {
      final request = http.Request('POST', uri)..followRedirects = false;
      request.headers.addAll({
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $credential',
      });
      request.body = jsonEncode({
        'model': selectedModel.trim(),
        'messages': [
          {'role': 'system', 'content': instruction},
          {'role': 'user', 'content': input},
        ],
      });
      final response = await transport
          .send(request)
          .timeout(const Duration(seconds: 60));
      if (response.statusCode != 200) {
        throw FormatException(
          'AI 请求失败（HTTP ${response.statusCode}），请检查接口、模型和额度',
        );
      }
      final bytes = BytesBuilder();
      await for (final chunk in response.stream.timeout(
        const Duration(seconds: 60),
      )) {
        bytes.add(chunk);
        if (bytes.length > 1024 * 1024) {
          throw const FormatException('AI 返回内容过大');
        }
      }
      final body = jsonDecode(utf8.decode(bytes.takeBytes()));
      final choices = body is Map ? body['choices'] : null;
      final choice = choices is List && choices.isNotEmpty
          ? choices.first
          : null;
      if (choice is! Map || choice['finish_reason'] == 'length') {
        throw const FormatException('AI 结果不完整，请重试');
      }
      final message = choice['message'];
      final content = message is Map ? message['content'] : null;
      if (content is! String || content.trim().isEmpty) {
        throw const FormatException('AI 未返回有效结果');
      }
      return content.trim();
    } finally {
      if (client == null) transport.close();
    }
  }

  static String script(String result) {
    final fenced = RegExp(
      r'^```(?:python|py|javascript|js)?\s*\n([\s\S]*?)\n```\s*$',
    );
    return fenced.firstMatch(result.trim())?.group(1) ?? result.trim();
  }
}
