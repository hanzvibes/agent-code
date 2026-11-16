import 'package:hive_flutter/hive_flutter.dart';

part 'provider_profile.g.dart';

@HiveType(typeId: 0)
class ProviderProfile extends HiveObject {
  @HiveField(0)
  String id;

  @HiveField(1)
  String name;

  @HiveField(2)
  String baseUrl;

  @HiveField(3)
  String modelId;

  @HiveField(4)
  bool hasApiKey;

  ProviderProfile({
    required this.id,
    required this.name,
    required this.baseUrl,
    required this.modelId,
    this.hasApiKey = false,
  });

  static String? validateBaseUrl(String? value) {
    final uri = value == null ? null : Uri.tryParse(value.trim());
    if (uri == null || !const {'http', 'https'}.contains(uri.scheme)) {
      return 'Enter a valid http(s) URL.';
    }
    if (uri.host.isEmpty || uri.userInfo.isNotEmpty) {
      return 'The URL must include a host and must not contain credentials.';
    }
    if (uri.hasQuery || uri.hasFragment) {
      return 'The base URL cannot contain a query or fragment.';
    }
    return null;
  }

  Uri get chatCompletionsUri {
    final validation = validateBaseUrl(baseUrl);
    if (validation != null) throw FormatException(validation);

    final base = Uri.parse(baseUrl.trim());
    var path = base.path.replaceAll(RegExp(r'/+$'), '');
    if (path.isEmpty) path = '/v1';
    if (!path.endsWith('/chat/completions')) path = '$path/chat/completions';
    return base.replace(path: path, query: null, fragment: null);
  }

  String get chatCompletionsUrl => chatCompletionsUri.toString();

  ProviderProfile copyWith({
    String? name,
    String? baseUrl,
    String? modelId,
    bool? hasApiKey,
  }) {
    return ProviderProfile(
      id: id,
      name: name ?? this.name,
      baseUrl: baseUrl ?? this.baseUrl,
      modelId: modelId ?? this.modelId,
      hasApiKey: hasApiKey ?? this.hasApiKey,
    );
  }
}
