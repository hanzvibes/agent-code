import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:code_harness/models/chat_message.dart';
import 'package:code_harness/models/provider_profile.dart';
import 'package:code_harness/services/llm_service.dart';

void main() {
  test(
    'sends an OpenAI-compatible request directly to the selected gateway',
    () async {
      http.Request? captured;
      final client = MockClient((request) async {
        captured = request;
        return http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {'content': 'Gateway response'},
              },
            ],
          }),
          200,
        );
      });
      final profile = ProviderProfile(
        id: 'local',
        name: 'Local Gateway',
        baseUrl: 'https://gateway.example/v1',
        modelId: 'custom-model',
      );

      final result = await LlmService(clientFactory: () => client).chat(
        profile: profile,
        apiKey: 'example-key',
        messages: [
          ChatMessage(
            role: 'user',
            content: 'Hello',
            timestamp: DateTime(2026),
          ),
        ],
      );

      expect(result, 'Gateway response');
      expect(
        captured!.url,
        Uri.parse('https://gateway.example/v1/chat/completions'),
      );
      expect(captured!.headers['authorization'], 'Bearer example-key');
      final body = jsonDecode(captured!.body) as Map<String, dynamic>;
      expect(body['model'], 'custom-model');
      expect(body['stream'], false);
      expect((body['messages'] as List).single['content'], 'Hello');
    },
  );

  test(
    'does not include an Authorization header when the key is blank',
    () async {
      http.Request? captured;
      final profile = ProviderProfile(
        id: 'no-auth',
        name: 'Trusted Gateway',
        baseUrl: 'http://127.0.0.1:1234/v1',
        modelId: 'local-model',
      );
      final client = MockClient((request) async {
        captured = request;
        return http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {'content': 'OK'},
              },
            ],
          }),
          200,
        );
      });

      await LlmService(clientFactory: () => client).chat(
        profile: profile,
        apiKey: null,
        messages: [
          ChatMessage(role: 'user', content: 'Hi', timestamp: DateTime(2026)),
        ],
      );

      expect(captured!.headers.containsKey('authorization'), isFalse);
    },
  );

  test('includes the provider error message on HTTP 400', () async {
    final client = MockClient((request) async {
      return http.Response(
        jsonEncode({
          'error': {'message': 'Invalid tool_call_id'},
        }),
        400,
      );
    });
    final profile = ProviderProfile(
      id: 'local',
      name: 'Local Gateway',
      baseUrl: 'https://gateway.example/v1',
      modelId: 'custom-model',
    );

    await expectLater(
      () => LlmService(clientFactory: () => client).chat(
        profile: profile,
        apiKey: 'example-key',
        messages: [
          ChatMessage(
            role: 'user',
            content: 'Hello',
            timestamp: DateTime(2026),
          ),
        ],
      ),
      throwsA(
        isA<LlmServiceException>().having(
          (e) => e.message,
          'message',
          contains('Invalid tool_call_id'),
        ),
      ),
    );
  });
}
