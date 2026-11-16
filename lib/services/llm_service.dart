import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/chat_message.dart';
import '../models/provider_profile.dart';
import 'workspace_tool_service.dart';

class LlmServiceException implements Exception {
  final String message;
  const LlmServiceException(this.message);
  @override
  String toString() => message;
}

class LlmStreamResponse {
  final String text;
  final List<ToolCallInfo> toolCalls;

  const LlmStreamResponse({this.text = '', this.toolCalls = const []});

  bool get hasToolCalls => toolCalls.isNotEmpty;
}

class _ToolCallAccumulator {
  final int index;

  /// The provider may stream a tool call without an `id` (some
  /// OpenAI-compatible gateways do). A follow-up request carrying an
  /// empty `tool_call_id` is rejected with HTTP 400, so the id
  /// starts as a deterministic fallback and is only replaced when a
  /// real id arrives.
  String id;
  String name = '';
  final StringBuffer arguments = StringBuffer();

  _ToolCallAccumulator(this.index) : id = 'call_$index';

  void merge(Map<String, dynamic> chunk) {
    if (chunk['id'] is String && (chunk['id'] as String).isNotEmpty) {
      id = chunk['id'] as String;
    }
    final func = chunk['function'];
    if (func is Map<String, dynamic>) {
      if (func['name'] is String && (func['name'] as String).isNotEmpty) {
        name = func['name'] as String;
      }
      if (func['arguments'] is String) {
        arguments.write(func['arguments'] as String);
      }
    }
  }

  ToolCallInfo toToolCallInfo() => ToolCallInfo(
    id: id,
    name: name,
    arguments: _sanitizedToolArguments(arguments.toString()),
  );
}

/// Tool-call arguments must be a JSON string: an empty or truncated
/// argument list is repaired to `{}` so the follow-up request stays
/// valid — the failed call itself is already reported to the model
/// as a tool error.
String _sanitizedToolArguments(String raw) {
  if (raw.trim().isEmpty) return '{}';
  try {
    jsonDecode(raw);
    return raw;
  } catch (_) {
    return '{}';
  }
}

/// Provider error detail for a failed HTTP response: the provider's
/// own `error.message` when present, otherwise a short slice of the
/// raw body, otherwise just the status. The old code showed a bare
/// "HTTP 400" with no clue what the provider rejected.
String _providerErrorDetail(int statusCode, String body) {
  try {
    final parsed = jsonDecode(body);
    if (parsed is Map && parsed['error'] != null) {
      final errObj = parsed['error'];
      if (errObj is Map && errObj['message'] != null) {
        return 'HTTP $statusCode: ${errObj['message']}';
      } else if (errObj is String) {
        return 'HTTP $statusCode: $errObj';
      }
    }
  } catch (_) {}
  final flat = body.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (flat.isEmpty) return 'HTTP $statusCode';
  const maxDetailChars = 300;
  final shown = flat.length > maxDetailChars
      ? '${flat.substring(0, maxDetailChars)}…'
      : flat;
  return 'HTTP $statusCode: $shown';
}

class LlmService {
  static const _timeout = Duration(seconds: 90);
  final http.Client Function() _clientFactory;

  LlmService({http.Client Function()? clientFactory})
    : _clientFactory = clientFactory ?? http.Client.new;

  Future<String> chat({
    required ProviderProfile profile,
    required String? apiKey,
    required List<ChatMessage> messages,
    CancelToken? cancelToken,
    double? temperature,
    int? maxTokens,
  }) async {
    final uri = profile.chatCompletionsUri;
    final headers = <String, String>{
      'Content-Type': 'application/json',
      if (apiKey?.isNotEmpty ?? false) 'Authorization': 'Bearer $apiKey',
    };
    final requestBody = <String, dynamic>{
      'model': profile.modelId,
      'messages': messages.map((message) => message.toApiMap()).toList(),
      'stream': false,
    };
    if (temperature != null) {
      requestBody['temperature'] = temperature;
    }
    if (maxTokens != null) {
      requestBody['max_tokens'] = maxTokens;
    }
    final body = jsonEncode(requestBody);

    final client = _clientFactory();
    cancelToken?.setClient(client);
    try {
      final response = await client
          .post(uri, headers: headers, body: body)
          .timeout(_timeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw LlmServiceException(
          'Request to ${profile.name} failed '
          '(${_providerErrorDetail(response.statusCode, response.body)}).',
        );
      }
      final data = jsonDecode(response.body);
      if (data is! Map<String, dynamic> || data['choices'] is! List) {
        throw const LlmServiceException(
          'The provider returned an unexpected response.',
        );
      }
      final choices = data['choices'] as List<dynamic>;
      if (choices.isEmpty || choices.first is! Map<String, dynamic>) {
        throw const LlmServiceException('The provider returned no answer.');
      }
      final message = choices.first['message'];
      final content = message is Map<String, dynamic>
          ? message['content']
          : null;
      if (content is String) return content;
      if (content is List) {
        return content
            .whereType<Map>()
            .where((part) => part['type'] == 'text' && part['text'] is String)
            .map((part) => part['text'] as String)
            .join();
      }
      throw const LlmServiceException(
        'The provider response did not contain text.',
      );
    } on TimeoutException {
      throw LlmServiceException('Request to ${profile.name} timed out.');
    } on LlmServiceException {
      rethrow;
    } catch (error) {
      if (cancelToken?.isCancelled ?? false) {
        throw const LlmServiceException('Request cancelled.');
      }
      final message = error.toString();
      throw LlmServiceException(
        'Network error from ${profile.name}: '
        '${message.length > 120 ? message.substring(0, 120) : message}',
      );
    } finally {
      cancelToken?.clearClient(client);
      client.close();
    }
  }

  Future<LlmStreamResponse> streamRequest({
    required ProviderProfile profile,
    required String? apiKey,
    required List<Map<String, dynamic>> messages,
    List<Map<String, dynamic>>? tools,
    CancelToken? cancelToken,
    double? temperature,
    int? maxTokens,
    void Function(String delta)? onDelta,

    /// Fired the moment a streamed tool-call chunk first names a tool
    /// (Batch 6 — desain D10): the UI can show the tool name live
    /// instead of waiting for the whole response. Arguments arrive in
    /// later chunks, so only the call index, id, and name are given.
    /// Not fired for the non-stream JSON fallback (those calls arrive
    /// complete at the end and are returned in the response).
    void Function(int index, String id, String name)? onToolCallName,
  }) async {
    final uri = profile.chatCompletionsUri;
    final headers = <String, String>{
      'Content-Type': 'application/json',
      'Accept': 'text/event-stream, application/json',
      if (apiKey?.isNotEmpty ?? false) 'Authorization': 'Bearer $apiKey',
    };
    final requestBody = <String, dynamic>{
      'model': profile.modelId,
      'messages': messages,
      'stream': true,
    };
    if (temperature != null) {
      requestBody['temperature'] = temperature;
    }
    if (maxTokens != null) {
      requestBody['max_tokens'] = maxTokens;
    }
    if (tools != null && tools.isNotEmpty) {
      requestBody['tools'] = tools;
    }

    final client = _clientFactory();
    cancelToken?.setClient(client);

    try {
      final request = http.Request('POST', uri)
        ..headers.addAll(headers)
        ..body = jsonEncode(requestBody);

      final streamedResponse = await client.send(request).timeout(_timeout);

      if (streamedResponse.statusCode < 200 ||
          streamedResponse.statusCode >= 300) {
        final errBody = await streamedResponse.stream.bytesToString();
        throw LlmServiceException(
          'Request to ${profile.name} failed '
          '(${_providerErrorDetail(streamedResponse.statusCode, errBody)}).',
        );
      }

      final textBuffer = StringBuffer();
      final toolAccumulators = <int, _ToolCallAccumulator>{};
      final reportedToolCallNames = <int>{};
      bool isNonStreamJson = false;
      final rawJsonBuffer = StringBuffer();

      final lineStream = streamedResponse.stream
          .transform(utf8.decoder)
          .transform(const LineSplitter());

      await for (final line in lineStream) {
        if (cancelToken?.isCancelled ?? false) {
          throw const LlmServiceException('Request cancelled.');
        }

        final trimmed = line.trim();
        if (trimmed.isEmpty) continue;

        if (!isNonStreamJson &&
            textBuffer.isEmpty &&
            toolAccumulators.isEmpty &&
            trimmed.startsWith('{')) {
          isNonStreamJson = true;
        }

        if (isNonStreamJson) {
          rawJsonBuffer.writeln(trimmed);
          continue;
        }

        if (trimmed == 'data: [DONE]') {
          break;
        }

        if (trimmed.startsWith('data:')) {
          final dataStr = trimmed.substring(5).trim();
          if (dataStr.isEmpty) continue;

          try {
            final chunk = jsonDecode(dataStr);
            if (chunk is Map<String, dynamic> && chunk['choices'] is List) {
              final choices = chunk['choices'] as List;
              if (choices.isNotEmpty && choices.first is Map) {
                final firstChoice = choices.first as Map<String, dynamic>;
                final delta = firstChoice['delta'];
                if (delta is Map<String, dynamic>) {
                  final content = delta['content'];
                  if (content is String && content.isNotEmpty) {
                    textBuffer.write(content);
                    onDelta?.call(content);
                  }
                  final toolCalls = delta['tool_calls'];
                  if (toolCalls is List) {
                    for (final tc in toolCalls) {
                      if (tc is Map<String, dynamic>) {
                        final idx = tc['index'] is int ? tc['index'] as int : 0;
                        final acc = toolAccumulators.putIfAbsent(
                          idx,
                          () => _ToolCallAccumulator(idx),
                        );
                        acc.merge(tc);
                        // Live tool name (Batch 6 — desain D10): report
                        // the name as soon as the first chunk carries it.
                        if (onToolCallName != null &&
                            acc.name.isNotEmpty &&
                            reportedToolCallNames.add(idx)) {
                          onToolCallName(idx, acc.id, acc.name);
                        }
                      }
                    }
                  }
                }
              }
            }
          } catch (_) {
            // Skip unparseable chunks
          }
        }
      }

      if (isNonStreamJson) {
        final jsonStr = rawJsonBuffer.toString();
        final data = jsonDecode(jsonStr);
        if (data is Map<String, dynamic> && data['choices'] is List) {
          final choices = data['choices'] as List;
          if (choices.isNotEmpty && choices.first is Map) {
            final choice = choices.first as Map<String, dynamic>;
            final message = choice['message'];
            if (message is Map<String, dynamic>) {
              if (message['tool_calls'] is List) {
                final tcs = message['tool_calls'] as List;
                final list = <ToolCallInfo>[];
                for (var i = 0; i < tcs.length; i++) {
                  final tc = tcs[i];
                  if (tc is Map<String, dynamic>) {
                    final fn = tc['function'] as Map<String, dynamic>? ?? {};
                    final rawId = (tc['id'] ?? '').toString();
                    list.add(
                      ToolCallInfo(
                        id: rawId.isEmpty ? 'call_$i' : rawId,
                        name: (fn['name'] ?? '').toString(),
                        arguments: _sanitizedToolArguments(
                          (fn['arguments'] ?? '').toString(),
                        ),
                      ),
                    );
                  }
                }
                return LlmStreamResponse(toolCalls: list);
              }
              final content = message['content'];
              if (content is String) {
                onDelta?.call(content);
                return LlmStreamResponse(text: content);
              }
            }
          }
        }
        throw const LlmServiceException(
          'The provider returned an unexpected non-stream response.',
        );
      }

      if (toolAccumulators.isNotEmpty) {
        final sortedIndices = toolAccumulators.keys.toList()..sort();
        final list = sortedIndices
            .map((i) => toolAccumulators[i]!.toToolCallInfo())
            .toList();
        return LlmStreamResponse(text: textBuffer.toString(), toolCalls: list);
      }

      return LlmStreamResponse(text: textBuffer.toString());
    } on TimeoutException {
      throw LlmServiceException('Request to ${profile.name} timed out.');
    } on LlmServiceException {
      rethrow;
    } catch (error) {
      if (cancelToken?.isCancelled ?? false) {
        throw const LlmServiceException('Request cancelled.');
      }
      final message = error.toString();
      throw LlmServiceException(
        'Network error from ${profile.name}: '
        '${message.length > 120 ? message.substring(0, 120) : message}',
      );
    } finally {
      cancelToken?.clearClient(client);
      client.close();
    }
  }

  Future<bool> testConnection({
    required ProviderProfile profile,
    required String? apiKey,
  }) async {
    await chat(
      profile: profile,
      apiKey: apiKey,
      messages: [
        ChatMessage(
          role: 'user',
          content: 'Reply with OK.',
          timestamp: DateTime.now(),
        ),
      ],
      maxTokens: 4,
    );
    return true;
  }
}

class CancelToken {
  http.Client? _client;
  bool _cancelled = false;

  void setClient(http.Client client) {
    _client = client;
    if (_cancelled) client.close();
  }

  void clearClient(http.Client client) {
    if (identical(_client, client)) _client = null;
  }

  void cancel() {
    _cancelled = true;
    _client?.close();
    _client = null;
  }

  bool get isCancelled => _cancelled;
}
