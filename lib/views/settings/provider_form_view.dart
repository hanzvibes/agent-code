import 'package:flutter/material.dart';

import '../../controllers/app_controller.dart';
import '../../core/ui.dart';
import '../../models/provider_profile.dart';
import '../../repositories/profile_repository.dart';
import '../../services/llm_service.dart';

class ProviderFormView extends StatefulWidget {
  final ProviderProfile? profile;
  final AppController ctrl;

  const ProviderFormView({super.key, this.profile, required this.ctrl});

  @override
  State<ProviderFormView> createState() => _ProviderFormViewState();
}

class _ProviderFormViewState extends State<ProviderFormView> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameCtrl;
  late final TextEditingController _urlCtrl;
  late final TextEditingController _modelCtrl;
  late final TextEditingController _keyCtrl;

  bool _isTesting = false;
  String? _testResult;
  bool _testSuccess = false;
  bool _isSaving = false;
  bool _clearSavedKey = false;

  @override
  void initState() {
    super.initState();
    final p = widget.profile;
    _nameCtrl = TextEditingController(text: p?.name ?? '');
    _urlCtrl = TextEditingController(text: p?.baseUrl ?? '');
    _modelCtrl = TextEditingController(text: p?.modelId ?? '');
    _keyCtrl = TextEditingController();
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _urlCtrl.dispose();
    _modelCtrl.dispose();
    _keyCtrl.dispose();
    super.dispose();
  }

  String? _validateUrl(String? val) {
    return ProviderProfile.validateBaseUrl(val);
  }

  Future<void> _testConnection() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _isTesting = true;
      _testResult = null;
    });
    final tempProfile = ProviderProfile(
      id: widget.profile?.id ?? 'test',
      name: _nameCtrl.text.trim(),
      baseUrl: _urlCtrl.text.trim(),
      modelId: _modelCtrl.text.trim(),
    );
    try {
      final typedKey = _keyCtrl.text.trim();
      final key = typedKey.isNotEmpty
          ? typedKey
          : widget.profile?.hasApiKey == true && !_clearSavedKey
          ? await ProfileRepository().getApiKey(widget.profile!.id)
          : null;
      await LlmService().testConnection(profile: tempProfile, apiKey: key);
      setState(() {
        _testResult = 'Connection to ${tempProfile.name} successful.';
        _testSuccess = true;
      });
    } on LlmServiceException catch (e) {
      setState(() {
        _testResult = e.message;
        _testSuccess = false;
      });
    } catch (e) {
      setState(() {
        _testResult =
            'Error: ${e.toString().substring(0, e.toString().length.clamp(0, 100))}';
        _testSuccess = false;
      });
    } finally {
      setState(() => _isTesting = false);
    }
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _isSaving = true);
    try {
      final profileRepo = ProfileRepository();
      final id =
          widget.profile?.id ??
          DateTime.now().millisecondsSinceEpoch.toString();
      final key = _keyCtrl.text.trim();
      final hasKey =
          key.isNotEmpty ||
          ((widget.profile?.hasApiKey ?? false) && !_clearSavedKey);

      final profile = ProviderProfile(
        id: id,
        name: _nameCtrl.text.trim(),
        baseUrl: _urlCtrl.text.trim(),
        modelId: _modelCtrl.text.trim(),
        hasApiKey: hasKey,
      );

      if (key.isNotEmpty) {
        await profileRepo.saveApiKey(id, key);
      } else if (_clearSavedKey) {
        await profileRepo.deleteApiKey(id);
      }

      if (widget.profile == null) {
        await widget.ctrl.addProfile(profile);
      } else {
        await widget.ctrl.updateProfile(profile);
      }

      if (mounted) Navigator.of(context).pop();
    } catch (_) {
      if (mounted) {
        setState(() {
          _testResult = 'Could not save provider settings.';
          _testSuccess = false;
        });
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    final isEditing = widget.profile != null;

    return Scaffold(
      backgroundColor: t.bg,
      appBar: appScreenBar(
        context,
        title: isEditing ? 'Edit provider' : 'Add provider',
        showBack: true,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SectionHeader('Profile'),
              AppCard(
                child: Column(
                  children: [
                    _FieldRow(
                      label: 'Name',
                      child: TextFormField(
                        controller: _nameCtrl,
                        decoration: const InputDecoration(
                          hintText: 'e.g. My OpenAI',
                        ),
                        validator: (v) =>
                            (v?.trim().isEmpty ?? true) ? 'Required' : null,
                      ),
                    ),
                    Container(height: 0.5, color: t.hairline),
                    _FieldRow(
                      label: 'Base URL',
                      child: TextFormField(
                        controller: _urlCtrl,
                        decoration: const InputDecoration(
                          hintText: 'https://api.openai.com/v1',
                        ),
                        keyboardType: TextInputType.url,
                        autocorrect: false,
                        validator: _validateUrl,
                      ),
                    ),
                    Container(height: 0.5, color: t.hairline),
                    _FieldRow(
                      label: 'Model ID',
                      child: TextFormField(
                        controller: _modelCtrl,
                        decoration: const InputDecoration(
                          hintText: 'e.g. gpt-4o',
                        ),
                        autocorrect: false,
                        validator: (v) =>
                            (v?.trim().isEmpty ?? true) ? 'Required' : null,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Text(
                  "Model IDs are entered manually. Check your provider's documentation for the exact model name.",
                  style: t.small,
                ),
              ),
              const SizedBox(height: 20),
              SectionHeader('API Key (optional)'),
              AppCard(
                child: _FieldRow(
                  label: isEditing && (widget.profile?.hasApiKey ?? false)
                      ? 'Replace key'
                      : 'API key',
                  child: TextFormField(
                    controller: _keyCtrl,
                    obscureText: true,
                    enableSuggestions: false,
                    autocorrect: false,
                    decoration: InputDecoration(
                      hintText:
                          isEditing && (widget.profile?.hasApiKey ?? false)
                          ? '(leave blank to keep current)'
                          : 'sk-… (optional)',
                    ),
                  ),
                ),
              ),
              if (isEditing && (widget.profile?.hasApiKey ?? false))
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    onPressed: () =>
                        setState(() => _clearSavedKey = !_clearSavedKey),
                    icon: Icon(
                      _clearSavedKey ? Icons.undo : Icons.key_off_outlined,
                    ),
                    label: Text(
                      _clearSavedKey ? 'Keep saved key' : 'Remove saved key',
                    ),
                  ),
                ),
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Text(
                  'Keys are stored in encrypted device storage and sent only to the provider you configure. They are never logged by Code Harness.',
                  style: t.small,
                ),
              ),
              const SizedBox(height: 6),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Text(
                  'HTTP gateways are unencrypted. Avoid using an API key with an http:// URL. Test connection sends a small provider request and may incur usage.',
                  style: t.small,
                ),
              ),
              if (_testResult != null) ...[
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: _testSuccess
                        ? t.green.withValues(alpha: 0.1)
                        : t.red.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: _testSuccess
                          ? t.green.withValues(alpha: 0.3)
                          : t.red.withValues(alpha: 0.3),
                    ),
                  ),
                  child: Text(
                    _testResult!,
                    style: t.caption.copyWith(
                      color: _testSuccess ? t.green : t.red,
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 24),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size(0, 48),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      onPressed: _isTesting ? null : _testConnection,
                      child: _isTesting
                          ? const SizedBox(
                              height: 16,
                              width: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text('Test connection'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: PrimaryButton(
                      label: _isSaving ? 'Saving…' : 'Save',
                      onPressed: _isSaving ? null : _save,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 32),
            ],
          ),
        ),
      ),
    );
  }
}

class _FieldRow extends StatelessWidget {
  final String label;
  final Widget child;
  const _FieldRow({required this.label, required this.child});

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return Padding(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: t.label),
          const SizedBox(height: 6),
          child,
        ],
      ),
    );
  }
}
