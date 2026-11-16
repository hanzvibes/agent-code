import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../controllers/app_controller.dart';
import '../core/ui.dart';
import 'assistant/assistant_view.dart';
import 'project/project_view.dart';
import 'settings/settings_view.dart';

class AppShell extends StatelessWidget {
  const AppShell({super.key});

  static const _tabs = [
    _TabItem(
      label: 'Project',
      icon: Icons.folder_outlined,
      activeIcon: Icons.folder,
    ),
    _TabItem(
      label: 'Assistant',
      icon: Icons.chat_bubble_outline,
      activeIcon: Icons.chat_bubble,
    ),
    _TabItem(
      label: 'Settings',
      icon: Icons.settings_outlined,
      activeIcon: Icons.settings,
    ),
  ];

  static const _pages = [ProjectView(), AssistantView(), SettingsView()];

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    final appCtrl = Get.find<AppController>();

    return Obx(() {
      final currentIndex = appCtrl.selectedTab.value;
      return Scaffold(
        body: IndexedStack(index: currentIndex, children: _pages),
        bottomNavigationBar: Container(
          decoration: BoxDecoration(
            border: Border(top: BorderSide(color: t.hairline, width: 0.5)),
          ),
          child: NavigationBar(
            selectedIndex: currentIndex,
            onDestinationSelected: (i) => appCtrl.selectTab(i),
            backgroundColor: t.bg,
            surfaceTintColor: Colors.transparent,
            elevation: 0,
            height: 64,
            labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
            destinations: _tabs
                .map(
                  (tab) => NavigationDestination(
                    icon: Icon(tab.icon),
                    selectedIcon: Icon(tab.activeIcon, color: t.accent),
                    label: tab.label,
                  ),
                )
                .toList(),
          ),
        ),
      );
    });
  }
}

class _TabItem {
  final String label;
  final IconData icon;
  final IconData activeIcon;
  const _TabItem({
    required this.label,
    required this.icon,
    required this.activeIcon,
  });
}
