import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/services/haptic_service.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/platform_ui/platform_ui.dart';
import '../../lobehub/views/lobehub_agents_page.dart';
import '../../settings/views/lobe_settings_page.dart';
import '../widgets/chats_drawer.dart';

export '../../lobehub/views/lobehub_agents_page.dart';

/// Main navigation modules in the 3-module structure.
enum MainNavigationTab { chats, agents, settings }

/// Active main navigation tab index provider (0 = Chats, 1 = Agents, 2 = Settings).
final mainNavigationIndexProvider = StateProvider<int>((ref) => 0);

/// Tab metadata descriptor for the 3-module structure.
class MainNavigationTabItem {
  const MainNavigationTabItem({
    required this.index,
    required this.label,
    required this.materialIcon,
    required this.selectedMaterialIcon,
    required this.sfSymbol,
    required this.selectedSfSymbol,
  });

  final int index;
  final String label;
  final IconData materialIcon;
  final IconData selectedMaterialIcon;
  final String sfSymbol;
  final String selectedSfSymbol;
}

/// Fallback chats tab widget when [AppLocalizations] is not initialized in tests.
class _DefaultChatsView extends StatelessWidget {
  const _DefaultChatsView();

  @override
  Widget build(BuildContext context) {
    if (AppLocalizations.of(context) != null) {
      return const ChatsDrawer();
    }
    final theme = context.conduitTheme;
    return Scaffold(
      backgroundColor: theme.surfaceBackground,
      appBar: AppBar(
        title: const Text('Chats'),
        backgroundColor: theme.surfaceBackground,
        elevation: 0,
      ),
      body: const Center(
        child: Text('Chats'),
      ),
    );
  }
}

/// MainNavigationShell implements Conduit's streamlined 3-module navigation:
/// 1. **Chats (会话)**: Main chat interface, recent conversations, topic list.
/// 2. **Agents (智能体)**: LobeHub agent marketplace / assistant library view.
/// 3. **Settings (设置)**: Server connection info, theme, preferences.
///
/// Features:
/// - Responsive layout preventing RenderFlex overflows on 320dp small screens.
/// - Seamless tab switching with state preservation (IndexedStack / KeyedSubtree).
/// - Theme-aware styling adhering to Conduit design tokens.
/// - Haptic feedback on tab changes.
class MainNavigationShell extends ConsumerStatefulWidget {
  const MainNavigationShell({
    super.key,
    this.child,
    this.initialIndex = 0,
    this.chatsView,
    this.agentsView,
    this.settingsView,
    this.onTabChanged,
  });

  /// Optional child route passed by GoRouter ShellRoute (mounted on Tab 0).
  final Widget? child;

  /// Initial active tab index (default is 0).
  final int initialIndex;

  /// Custom widget for Tab 0 (Chats). Defaults to [child] or [_DefaultChatsView].
  final Widget? chatsView;

  /// Custom widget for Tab 1 (Agents). Defaults to [LobeAgentsPage].
  final Widget? agentsView;

  /// Custom widget for Tab 2 (Settings). Defaults to [LobeSettingsPage].
  final Widget? settingsView;

  /// Optional callback invoked when the active tab index changes.
  final ValueChanged<int>? onTabChanged;

  @override
  ConsumerState<MainNavigationShell> createState() =>
      _MainNavigationShellState();
}

class _MainNavigationShellState extends ConsumerState<MainNavigationShell> {
  @override
  void initState() {
    super.initState();
    if (widget.initialIndex != 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          ref.read(mainNavigationIndexProvider.notifier).state =
              widget.initialIndex;
        }
      });
    }
  }

  @override
  void didUpdateWidget(MainNavigationShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initialIndex != widget.initialIndex) {
      ref.read(mainNavigationIndexProvider.notifier).state =
          widget.initialIndex;
    }
  }

  void _onTabSelected(int index) {
    if (index < 0 || index > 2) return;
    ConduitHaptics.selectionClick();
    ref.read(mainNavigationIndexProvider.notifier).state = index;
    widget.onTabChanged?.call(index);
  }

  List<MainNavigationTabItem> _buildTabItems(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final chatsLabel = l10n?.sidebarChatsTab ?? 'Chats';
    final agentsLabel = 'Agents';
    final settingsLabel = l10n?.settings ?? 'Settings';

    return [
      MainNavigationTabItem(
        index: 0,
        label: chatsLabel,
        materialIcon: Icons.chat_bubble_outline,
        selectedMaterialIcon: Icons.chat_bubble,
        sfSymbol: 'bubble.left',
        selectedSfSymbol: 'bubble.left.fill',
      ),
      MainNavigationTabItem(
        index: 1,
        label: agentsLabel,
        materialIcon: Icons.smart_toy_outlined,
        selectedMaterialIcon: Icons.smart_toy,
        sfSymbol: 'sparkles',
        selectedSfSymbol: 'sparkles',
      ),
      MainNavigationTabItem(
        index: 2,
        label: settingsLabel,
        materialIcon: Icons.settings_outlined,
        selectedMaterialIcon: Icons.settings,
        sfSymbol: 'gearshape',
        selectedSfSymbol: 'gearshape.fill',
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final selectedIndex = ref.watch(mainNavigationIndexProvider).clamp(0, 2);
    final theme = context.conduitTheme;
    final tabItems = _buildTabItems(context);

    final chatsWidget =
        widget.chatsView ?? widget.child ?? const _DefaultChatsView();
    final agentsWidget = widget.agentsView ?? const LobeAgentsPage();
    final settingsWidget = widget.settingsView ?? const LobeSettingsPage();

    return LayoutBuilder(
      builder: (context, constraints) {
        final screenWidth = constraints.maxWidth;
        // On very small screens (<= 340dp), use more compact labels and spacing
        final isSmallScreen = screenWidth <= 340;

        return Scaffold(
          backgroundColor: theme.surfaceBackground,
          body: IndexedStack(
            index: selectedIndex,
            children: [
              KeyedSubtree(
                key: const ValueKey('main-nav-tab-chats'),
                child: chatsWidget,
              ),
              KeyedSubtree(
                key: const ValueKey('main-nav-tab-agents'),
                child: agentsWidget,
              ),
              KeyedSubtree(
                key: const ValueKey('main-nav-tab-settings'),
                child: settingsWidget,
              ),
            ],
          ),
          bottomNavigationBar: _buildBottomBar(
            context,
            theme,
            tabItems,
            selectedIndex,
            isSmallScreen,
          ),
        );
      },
    );
  }

  Widget _buildBottomBar(
    BuildContext context,
    ConduitThemeExtension theme,
    List<MainNavigationTabItem> tabItems,
    int selectedIndex,
    bool isSmallScreen,
  ) {
    final usesCupertino = context.usesCupertinoChrome;

    if (usesCupertino) {
      return CupertinoTabBar(
        currentIndex: selectedIndex,
        onTap: _onTabSelected,
        backgroundColor: theme.surfaceBackground.withValues(alpha: 0.95),
        activeColor: theme.buttonPrimary,
        inactiveColor: theme.textSecondary,
        iconSize: isSmallScreen ? 20.0 : 24.0,
        items: [
          for (final item in tabItems)
            BottomNavigationBarItem(
              icon: Icon(item.materialIcon),
              activeIcon: Icon(item.selectedMaterialIcon),
              label: item.label,
            ),
        ],
      );
    }

    return Container(
      decoration: BoxDecoration(
        color: theme.surfaceBackground,
        border: Border(
          top: BorderSide(
            color: theme.divider.withValues(alpha: 0.4),
            width: 0.5,
          ),
        ),
      ),
      child: NavigationBarTheme(
        data: NavigationBarThemeData(
          height: isSmallScreen ? 56 : 64,
          backgroundColor: theme.surfaceBackground,
          elevation: 0,
          indicatorColor: theme.buttonPrimary.withValues(alpha: 0.12),
          indicatorShape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppBorderRadius.pill),
          ),
          iconTheme: WidgetStateProperty.resolveWith<IconThemeData?>((states) {
            final selected = states.contains(WidgetState.selected);
            return IconThemeData(
              color: selected ? theme.buttonPrimary : theme.textSecondary,
              size: isSmallScreen ? 20 : 24,
            );
          }),
          labelTextStyle:
              WidgetStateProperty.resolveWith<TextStyle?>((states) {
            final selected = states.contains(WidgetState.selected);
            return TextStyle(
              fontSize: isSmallScreen ? 10 : 12,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
              color: selected ? theme.buttonPrimary : theme.textSecondary,
            );
          }),
        ),
        child: NavigationBar(
          selectedIndex: selectedIndex,
          onDestinationSelected: _onTabSelected,
          labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
          destinations: [
            for (final item in tabItems)
              NavigationDestination(
                key: ValueKey('nav-tab-${item.index}'),
                icon: Icon(item.materialIcon),
                selectedIcon: Icon(item.selectedMaterialIcon),
                label: item.label,
                tooltip: item.label,
              ),
          ],
        ),
      ),
    );
  }
}
