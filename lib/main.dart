import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:path_provider/path_provider.dart';

import 'core/theme.dart';
import 'controllers/app_controller.dart';
import 'controllers/assistant_controller.dart';
import 'controllers/project_controller.dart';
import 'models/app_prefs.dart';
import 'models/provider_profile.dart';
import 'repositories/chat_repository.dart';
import 'repositories/prefs_repository.dart';
import 'repositories/profile_repository.dart';
import 'services/llm_service.dart';
import 'services/workspace_service.dart';
import 'views/shell.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);

  // Init Hive
  final appDocDir = await getApplicationDocumentsDirectory();
  await Hive.initFlutter(appDocDir.path);
  Hive.registerAdapter(ProviderProfileAdapter());
  Hive.registerAdapter(AppPrefsAdapter());
  await ProfileRepository.openBox();
  await PrefsRepository.openBox();
  await ChatRepository.openBox();

  // Create sample workspace if first run
  final prefsRepo = PrefsRepository();
  if (prefsRepo.prefs.lastWorkspacePath == null) {
    final samplePath = '${appDocDir.path}/code_harness_sample';
    await WorkspaceService.createSampleWorkspace(samplePath);
    final p = prefsRepo.prefs;
    p.lastWorkspacePath = samplePath;
    await prefsRepo.save(p);
  }

  final profileRepo = ProfileRepository();
  final chatRepo = ChatRepository();
  final appController = Get.put(
    AppController(prefsRepo: prefsRepo, profileRepo: profileRepo),
  );
  final projectController = Get.put(ProjectController(appController));
  Get.put(
    AssistantController(
      appController: appController,
      projectController: projectController,
      profileRepo: profileRepo,
      chatRepo: chatRepo,
      llmService: LlmService(),
    ),
  );

  runApp(const CodeHarnessApp());
}

class CodeHarnessApp extends StatelessWidget {
  const CodeHarnessApp({super.key});

  @override
  Widget build(BuildContext context) {
    return GetBuilder<AppController>(
      builder: (ctrl) => GetMaterialApp(
        title: 'Code Harness',
        debugShowCheckedModeBanner: false,
        themeMode: ctrl.themeMode,
        theme: buildTheme(isDark: false),
        darkTheme: buildTheme(isDark: true),
        home: const AppShell(),
      ),
    );
  }
}
