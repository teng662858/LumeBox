import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lume_box/core/translation/ai_assistant.dart';

void main() {
  test('修源请求带原文和要求，禁用重定向，返回完整草稿', () async {
    final client = MockClient((request) async {
      expect(request.followRedirects, false);
      expect(request.headers['Authorization'], 'Bearer fixture');
      final body = jsonDecode(request.body);
      expect(body['model'], 'test-model');
      expect(body['messages'][1]['content'], 'class Spider: pass');
      return http.Response(
        jsonEncode({
          'choices': [
            {
              'finish_reason': 'stop',
              'message': {'content': '```python\nclass Spider: pass\n```'},
            },
          ],
        }),
        200,
      );
    });
    final result = await AiAssistant.request(
      '修复源',
      'class Spider: pass',
      client: client,
      url: 'https://fixture.invalid/v1/chat/completions',
      model: 'test-model',
      key: 'fixture',
    );
    expect(AiAssistant.script(result), 'class Spider: pass');
    client.close();
  });
  for (final value in ['length', 'empty', 'http']) {
    test('拒绝不完整或失败的 AI 响应：$value', () async {
      final client = MockClient(
        (_) async => http.Response(
          jsonEncode({
            'choices': [
              {
                'finish_reason': value,
                'message': {'content': value == 'empty' ? '' : 'partial'},
              },
            ],
          }),
          value == 'http' ? 401 : 200,
        ),
      );
      await expectLater(
        AiAssistant.request(
          'diagnose',
          'stats',
          client: client,
          url: 'https://fixture.invalid/chat',
          model: 'test',
          key: 'key',
        ),
        throwsFormatException,
      );
      client.close();
    });
  }
  test('拒绝非 HTTPS 和超大输入，不发送脚本', () async {
    var calls = 0;
    final client = MockClient((_) async {
      calls++;
      return http.Response('{}', 200);
    });
    for (final url in [
      'http://fixture.invalid/chat',
      'https://fixture.invalid/chat',
    ]) {
      await expectLater(
        AiAssistant.request(
          'repair',
          'x' * (256 * 1024 + 1),
          client: client,
          url: url,
          model: 'test',
          key: 'key',
        ),
        throwsFormatException,
      );
    }
    expect(calls, 0);
    client.close();
  });
}
