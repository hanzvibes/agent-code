import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:code_harness/models/provider_profile.dart';
import 'package:code_harness/services/llm_service.dart';

void main() {
  final profile = ProviderProfile(
    id: 'test-p',
    name: 'Test Gateway',
    baseUrl: 'https://example.com/v1',
    modelId: 'gpt-4o',
  );

  test('parses streamed text deltas via SSE', () async {
    final sseBody = [
      'data: {"choices":[{"delta":{"content":"Hello"}}]}',
      '',
      'data: {"choices":[{"delta":{"content":" world"}}]}',
      '',
      'data: {"choices":[{"delta":{"content":"!"}}]}',
      '',
      'data: [DONE]',
    ].join('\n');

    final mockClient = MockClient((request) async {
      expect(request.url.path, '/v1/chat/completions');
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      expect(body['stream'], isTrue);
      expect(body['model'], 'gpt-4o');
      return http.Response(
        sseBody,
        200,
        headers: {'content-type': 'text/event-stream'},
      );
    });

    final service = LlmService(clientFactory: () => mockClient);
    final deltas = <String>[];

    final response = await service.streamRequest(
      profile: profile,
      apiKey: 'test-key',
      messages: [
        {'role': 'user', 'content': 'Hi'},
      ],
      onDelta: deltas.add,
    );

    expect(response.text, 'Hello world!');
    expect(deltas, ['Hello', ' world', '!']);
    expect(response.hasToolCalls, isFalse);
  });

  test('parses streamed tool call chunks via SSE', () async {
    final sseBody = [
      'data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_123","type":"function","function":{"name":"read_project_file","arguments":"{\\"path\\": "}}]}}]}',
      '',
      'data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\\"lib/main.dart\\"}"}}]}}]}',
      '',
      'data: [DONE]',
    ].join('\n');

    final mockClient = MockClient((request) async {
      return http.Response(
        sseBody,
        200,
        headers: {'content-type': 'text/event-stream'},
      );
    });

    final service = LlmService(clientFactory: () => mockClient);
    final response = await service.streamRequest(
      profile: profile,
      apiKey: 'test-key',
      messages: [
        {'role': 'user', 'content': 'Read main.dart'},
      ],
    );

    expect(response.hasToolCalls, isTrue);
    expect(response.toolCalls.length, 1);
    expect(response.toolCalls[0].id, 'call_123');
    expect(response.toolCalls[0].name, 'read_project_file');
    expect(response.toolCalls[0].arguments, '{"path": "lib/main.dart"}');
  });

  test('falls back to non-stream JSON response without retry', () async {
    final jsonBody = jsonEncode({
      'choices': [
        {
          'message': {'role': 'assistant', 'content': 'Direct JSON answer'},
        },
      ],
    });

    final mockClient = MockClient((request) async {
      return http.Response(
        jsonBody,
        200,
        headers: {'content-type': 'application/json'},
      );
    });

    final service = LlmService(clientFactory: () => mockClient);
    final deltas = <String>[];
    final response = await service.streamRequest(
      profile: profile,
      apiKey: null,
      messages: [
        {'role': 'user', 'content': 'Hello'},
      ],
      onDelta: deltas.add,
    );

    expect(response.text, 'Direct JSON answer');
    expect(deltas, ['Direct JSON answer']);
  });

  test('passes temperature and max_tokens only when configured', () async {
    Map<String, dynamic>? sentBody;
    final mockClient = MockClient((request) async {
      sentBody = jsonDecode(request.body) as Map<String, dynamic>;
      return http.Response('data: [DONE]', 200);
    });

    final service = LlmService(clientFactory: () => mockClient);

    // Unconfigured
    await service.streamRequest(
      profile: profile,
      apiKey: null,
      messages: [
        {'role': 'user', 'content': 'Test'},
      ],
    );
    expect(sentBody!.containsKey('temperature'), isFalse);
    expect(sentBody!.containsKey('max_tokens'), isFalse);

    // Configured
    await service.streamRequest(
      profile: profile,
      apiKey: null,
      messages: [
        {'role': 'user', 'content': 'Test'},
      ],
      temperature: 0.7,
      maxTokens: 1024,
    );
    expect(sentBody!['temperature'], 0.7);
    expect(sentBody!['max_tokens'], 1024);
  });

  test('handles provider HTTP errors cleanly without silent retry', () async {
    var callCount = 0;
    final mockClient = MockClient((request) async {
      callCount++;
      return http.Response(
        jsonEncode({
          'error': {'message': 'Quota exceeded'},
        }),
        429,
      );
    });

    final service = LlmService(clientFactory: () => mockClient);

    await expectLater(
      () => service.streamRequest(
        profile: profile,
        apiKey: null,
        messages: [
          {'role': 'user', 'content': 'Test'},
        ],
      ),
      throwsA(
        isA<LlmServiceException>().having(
          (e) => e.message,
          'message',
          contains('Quota exceeded'),
        ),
      ),
    );
    expect(callCount, 1); // exactly one request, no retry
  });

  test('supports cancellation via CancelToken', () async {
    final cancelToken = CancelToken();
    cancelToken.cancel();

    final mockClient = MockClient((request) async {
      return http.Response(
        'data: {"choices":[{"delta":{"content":"Hi"}}]}',
        200,
      );
    });

    final service = LlmService(clientFactory: () => mockClient);

    await expectLater(
      () => service.streamRequest(
        profile: profile,
        apiKey: null,
        messages: [
          {'role': 'user', 'content': 'Test'},
        ],
        cancelToken: cancelToken,
      ),
      throwsA(
        isA<LlmServiceException>().having(
          (e) => e.message,
          'message',
          contains('cancelled'),
        ),
      ),
    );
  });
}
