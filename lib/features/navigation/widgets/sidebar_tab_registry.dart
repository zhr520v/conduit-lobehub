import 'package:material_ui/material_ui.dart';

import '../../../l10n/app_localizations.dart';
import '../controllers/sidebar_tab_behavior.dart';
import '../models/sidebar_navigation_model.dart';
import '../utils/sidebar_create_action.dart';
import 'chats_drawer.dart';

const AssetImage kHermesTabIcon = AssetImage('assets/icons/hermes_agent.png');

/// Optical size for the full-bleed Hermes artwork in compact navigation.
///
/// System tab glyphs include padding inside their nominal 20-point canvas;
/// the Hermes asset does not, so it needs a smaller painted extent to match.
const double kHermesTabIconSize = 17.0;

/// Optical size for Hermes in UIKit's native bottom tab bar.
const double kHermesNativeTabIconSize = 26.0;

typedef SidebarTabLabelBuilder = String Function(AppLocalizations l10n);
typedef SidebarTabBodyBuilder = Widget Function({
  required bool showBottomNavigation,
  required bool active,
});
typedef SidebarTabVisibilityPredicate = bool Function(
  SidebarTabAvailability availability,
);

/// Canonical visibility, presentation, and behavior for a sidebar destination.
@immutable
final class SidebarTabDescriptor {
  const SidebarTabDescriptor({
    required this.id,
    required this.labelBuilder,
    required this.searchHintBuilder,
    required this.bodyBuilder,
    required this.materialIcon,
    required this.selectedMaterialIcon,
    required this.sfSymbol,
    required this.selectedSfSymbol,
    required this.isVisible,
    this.assetName,
    this.nativeAssetName,
    this.assetIconSize,
    this.nativeAssetIconSize,
    this.createAction,
    this.behavior = standardSidebarTabBehavior,
  });

  final SidebarTabId id;
  final SidebarTabLabelBuilder labelBuilder;
  final SidebarTabLabelBuilder searchHintBuilder;
  final SidebarTabBodyBuilder bodyBuilder;
  final IconData materialIcon;
  final IconData selectedMaterialIcon;
  final String sfSymbol;
  final String selectedSfSymbol;
  final SidebarTabVisibilityPredicate isVisible;
  final String? assetName;
  final String? nativeAssetName;
  final double? assetIconSize;
  final double? nativeAssetIconSize;
  final SidebarCreateAction? createAction;
  final SidebarTabBehavior behavior;

  String label(AppLocalizations l10n) => labelBuilder(l10n);
  String searchHint(AppLocalizations l10n) => searchHintBuilder(l10n);

  ValueKey<String> get layerKey =>
      ValueKey<String>('sidebar-tab-layer-${id.name}');
}

String _chatsLabel(AppLocalizations l10n) => l10n.sidebarChatsTab;
String _conversationSearchHint(AppLocalizations l10n) =>
    l10n.searchConversations;

Widget _chatsBody({required bool showBottomNavigation, required bool active}) =>
    const ChatsDrawer();

bool _chatsVisible(SidebarTabAvailability availability) => true;

const sidebarTabRegistry = <SidebarTabDescriptor>[
  SidebarTabDescriptor(
    id: SidebarTabId.chats,
    labelBuilder: _chatsLabel,
    searchHintBuilder: _conversationSearchHint,
    bodyBuilder: _chatsBody,
    materialIcon: Icons.chat_bubble_outline,
    selectedMaterialIcon: Icons.chat_bubble,
    sfSymbol: 'bubble.left',
    selectedSfSymbol: 'bubble.left.fill',
    isVisible: _chatsVisible,
    createAction: chatSidebarCreateAction,
  ),
];

SidebarTabDescriptor sidebarTabDescriptor(SidebarTabId id) =>
    sidebarTabRegistry.firstWhere(
      (descriptor) => descriptor.id == id,
      orElse: () => sidebarTabRegistry.first,
    );

List<SidebarTabId> visibleSidebarTabIds(SidebarTabAvailability availability) =>
    [
      for (final descriptor in sidebarTabRegistry)
        if (descriptor.isVisible(availability)) descriptor.id,
    ];
