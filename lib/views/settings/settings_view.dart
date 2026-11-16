import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../controllers/app_controller.dart';
import '../../core/ui.dart';
import '../../models/provider_profile.dart';
import 'provider_form_view.dart';

class SettingsView extends StatelessWidget {
  const SettingsView({super.key});

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    final ctrl = Get.find<AppController>();

    return Scaffold(
      backgroundColor: t.bg,
      appBar: appScreenBar(context, title: 'Settings'),
      body: Obx(
        () => ListView(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          children: [
            SectionHeader('Appearance'),
            AppCard(
              child: AppRow(
                title: 'Theme',
                trailing: _ThemePicker(ctrl: ctrl),
              ),
            ),
            const SizedBox(height: 20),
            SectionHeader('Providers'),
            if (ctrl.profiles.isEmpty)
              _NoProvidersCard(t: t, ctrl: ctrl)
            else ...[
              ...ctrl.profiles.map(
                (p) => _ProviderCard(
                  profile: p,
                  isActive: ctrl.prefs.value.activeProfileId == p.id,
                  ctrl: ctrl,
                ),
              ),
              const SizedBox(height: 10),
              PrimaryButton(
                label: 'Add provider',
                onPressed: () => _openProviderForm(context, ctrl),
              ),
            ],
            const SizedBox(height: 20),
            SectionHeader('Privacy & Data Handling'),
            AppCard(
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Direct Gateway Connection', style: t.bodyStrong),
                    const SizedBox(height: 6),
                    Text(
                      '• Requests go directly from your device to your configured OpenAI-compatible gateway — never through Code Harness servers.\n'
                      '• API keys are stored in encrypted device storage (EncryptedSharedPreferences) and never logged.',
                      style: t.caption,
                    ),
                    const SizedBox(height: 12),
                    Text('Local-Only Chat Storage', style: t.bodyStrong),
                    const SizedBox(height: 6),
                    Text(
                      '• Chat sessions are stored on-device in app-private Hive storage, indexed by canonical workspace.\n'
                      '• Only user and assistant text and timestamps are persisted (capped at 100 messages and 200k characters).\n'
                      '• API keys, context snapshots, tool results, and repository source files are never saved in chat sessions.\n'
                      '• Switching workspaces restores the matching session without cross-contamination. Clearing chat deletes the stored session.',
                      style: t.caption,
                    ),
                    const SizedBox(height: 12),
                    Text('Agent Tool Groups (Optional)', style: t.bodyStrong),
                    const SizedBox(height: 6),
                    Text(
                      '• Project inspection is read-only and bounded. Termux command execution is a separate opt-in and is off by default.\n'
                      '• Enabled Termux commands run on-device with Termux permissions and network access; they are not sandboxed and can directly change or delete files.\n'
                      '• Android copy/share/link actions are another optional group and require in-app approval of the exact payload each time.\n'
                      '• Only enabled tool groups are sent to the provider. Tool calls/results are transient and are not stored in saved chat history.',
                      style: t.caption,
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 20),
            SectionHeader('About'),
            AppCard(
              child: Column(
                children: [
                  AppRow(
                    title: 'Version',
                    trailing: Text('1.0.0', style: t.caption),
                  ),
                  Container(
                    height: 0.5,
                    color: t.hairline,
                    margin: const EdgeInsets.only(left: 16),
                  ),
                  AppRow(
                    title: 'Third-party notices',
                    trailing: Icon(Icons.open_in_new, size: 16, color: t.muted),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }

  void _openProviderForm(
    BuildContext context,
    AppController ctrl, [
    ProviderProfile? profile,
  ]) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ProviderFormView(profile: profile, ctrl: ctrl),
      ),
    );
  }
}

class _ThemePicker extends StatelessWidget {
  final AppController ctrl;
  const _ThemePicker({required this.ctrl});

  @override
  Widget build(BuildContext context) {
    final mode = ctrl.themeMode;
    return SegmentedButton<ThemeMode>(
      segments: const [
        ButtonSegment(value: ThemeMode.system, label: Text('Auto')),
        ButtonSegment(value: ThemeMode.light, label: Text('Light')),
        ButtonSegment(value: ThemeMode.dark, label: Text('Dark')),
      ],
      selected: {mode},
      onSelectionChanged: (s) => ctrl.setThemeMode(s.first),
      style: ButtonStyle(
        textStyle: WidgetStateProperty.all(
          const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
        ),
        visualDensity: VisualDensity.compact,
      ),
    );
  }
}

class _NoProvidersCard extends StatelessWidget {
  final AppTokens t;
  final AppController ctrl;
  const _NoProvidersCard({required this.t, required this.ctrl});

  @override
  Widget build(BuildContext context) {
    return AppCard(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('No providers yet', style: t.bodyStrong),
            const SizedBox(height: 6),
            Text(
              'Add an OpenAI-compatible provider to use the AI assistant. Enter a base URL and model ID manually — any OpenAI-compatible API is supported.',
              style: t.caption,
            ),
            const SizedBox(height: 14),
            PrimaryButton(
              label: 'Add first provider',
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => ProviderFormView(ctrl: ctrl)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ProviderCard extends StatelessWidget {
  final ProviderProfile profile;
  final bool isActive;
  final AppController ctrl;

  const _ProviderCard({
    required this.profile,
    required this.isActive,
    required this.ctrl,
  });

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: AppCard(
        onTap: () => ctrl.setActiveProfile(profile.id),
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: isActive ? t.green : t.faint,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(profile.name, style: t.bodyStrong),
                  Text(profile.modelId, style: t.caption),
                ],
              ),
            ),
            Row(
              children: [
                AppBarIcon(
                  icon: Icons.edit_outlined,
                  tooltip: 'Edit',
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) =>
                          ProviderFormView(profile: profile, ctrl: ctrl),
                    ),
                  ),
                ),
                AppBarIcon(
                  icon: Icons.delete_outline,
                  tooltip: 'Delete',
                  onPressed: () async {
                    final ok = await confirmSheet(
                      context,
                      title: 'Delete "${profile.name}"?',
                      message: 'This will remove the profile and its API key.',
                      confirmLabel: 'Delete',
                      destructive: true,
                    );
                    if (ok) ctrl.deleteProfile(profile.id);
                  },
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
