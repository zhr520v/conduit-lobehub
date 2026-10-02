import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:conduit_core/features/lobehub/models/lobe_agent.dart';
import 'package:conduit_core/features/lobehub/providers/lobehub_agents_provider.dart';

import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/platform_ui/platform_ui.dart';
import '../../navigation/views/main_navigation_shell.dart';

/// Predefined vibrant palette for agent avatar initial badge backgrounds.
const List<Color> _avatarColorPalette = [
  Color(0xFF3B82F6), // Blue
  Color(0xFF8B5CF6), // Purple
  Color(0xFFEC4899), // Pink
  Color(0xFFF97316), // Orange
  Color(0xFF10B981), // Emerald
  Color(0xFF06B6D4), // Cyan
  Color(0xFF6366F1), // Indigo
  Color(0xFFE11D48), // Rose
  Color(0xFF14B8A6), // Teal
  Color(0xFFF59E0B), // Amber
];

/// Computes a deterministic vibrant background color based on the agent's title.
Color _getAvatarBackgroundColor(String title) {
  if (title.isEmpty) return _avatarColorPalette[0];
  final hash = title.runes.fold(0, (acc, rune) => acc + rune);
  return _avatarColorPalette[hash.abs() % _avatarColorPalette.length];
}

/// Dedicated LobeHub Agent Library and Discovery Page.
///
/// Features:
/// - Rich Grid and List views with toggle.
/// - Dynamic avatars supporting emojis, remote network URLs, and colorful
///   uppercase initial badge fallbacks when images 404 or fail.
/// - Title, description, system prompt preview, and model badges.
/// - Real-time search filter bar with debounce and clear.
/// - Tap agent card opens smooth bottom sheet modal with quick actions:
///   - "Start New Chat (开启新对话)": Creates topic and navigates to chat.
///   - "View System Prompt (查看系统设定)": Displays full system instructions in
///     a scrollable modal sheet.
/// - Pull-to-refresh ([RefreshIndicator]) reloading agents via `GET /api/v1/agents`.
/// - Adheres strictly to Conduit design tokens ([context.conduitTheme]).
class LobehubAgentsPage extends ConsumerStatefulWidget {
  const LobehubAgentsPage({
    super.key,
    this.onSelectAgent,
    this.onStartChat,
    this.onViewSystemPrompt,
    this.initialGridView = false,
  });

  /// Optional callback invoked when an agent card is tapped.
  final ValueChanged<LobeAgent>? onSelectAgent;

  /// Optional callback invoked when "Start New Chat" is triggered.
  final ValueChanged<LobeAgent>? onStartChat;

  /// Optional callback invoked when "View System Prompt" is triggered.
  final ValueChanged<LobeAgent>? onViewSystemPrompt;

  /// Whether to initialize in grid view layout (defaults to list view).
  final bool initialGridView;

  @override
  ConsumerState<LobehubAgentsPage> createState() => _LobehubAgentsPageState();
}

/// Backward compatibility alias for [LobehubAgentsPage].
typedef LobeAgentsPage = LobehubAgentsPage;

class _LobehubAgentsPageState extends ConsumerState<LobehubAgentsPage> {
  final TextEditingController _searchController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  late bool _isGridView;

  @override
  void initState() {
    super.initState();
    _isGridView = widget.initialGridView;
    _searchController.addListener(_onSearchChanged);
  }

  @override
  void dispose() {
    _searchController.removeListener(_onSearchChanged);
    _searchController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _onSearchChanged() {
    ref.read(lobeAgentsProvider.notifier).setSearchQuery(_searchController.text);
  }

  Future<void> _refresh() async {
    await ref.read(lobeAgentsProvider.notifier).loadAgents();
  }

  void _toggleViewMode() {
    setState(() {
      _isGridView = !_isGridView;
    });
  }

  void _handleAgentTap(LobeAgent agent) {
    ref.read(lobeAgentsProvider.notifier).selectAgent(agent.id);
    widget.onSelectAgent?.call(agent);
    _showAgentActionsBottomSheet(agent);
  }

  void _showAgentActionsBottomSheet(LobeAgent agent) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => _AgentActionsModalSheet(
        agent: agent,
        onStartChat: (selectedAgent) {
          if (widget.onStartChat != null) {
            widget.onStartChat!(selectedAgent);
          } else {
            try {
              ref.read(mainNavigationIndexProvider.notifier).state = 0;
            } catch (_) {}
          }
        },
        onViewSystemPrompt: (selectedAgent) {
          widget.onViewSystemPrompt?.call(selectedAgent);
          _showSystemPromptBottomSheet(selectedAgent);
        },
      ),
    );
  }

  void _showSystemPromptBottomSheet(LobeAgent agent) {
    final theme = context.conduitTheme;
    final title = agent.title ?? agent.name ?? 'Agent';
    final systemRole = agent.systemRole?.trim();
    final hasPrompt = systemRole != null && systemRole.isNotEmpty;

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => Container(
        key: const ValueKey('system-prompt-bottom-sheet'),
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(sheetContext).height * 0.85,
        ),
        decoration: BoxDecoration(
          color: theme.surfaceBackground,
          borderRadius: const BorderRadius.vertical(
            top: Radius.circular(AppBorderRadius.bottomSheet),
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.2),
              blurRadius: 16,
              offset: const Offset(0, -4),
            ),
          ],
        ),
        padding: EdgeInsets.only(
          bottom: MediaQuery.paddingOf(sheetContext).bottom + Spacing.md,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Sheet drag handle
            Center(
              child: Container(
                margin: const EdgeInsets.only(
                  top: Spacing.sm,
                  bottom: Spacing.xs,
                ),
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: theme.textSecondary.withValues(alpha: 0.3),
                  borderRadius: BorderRadius.circular(AppBorderRadius.pill),
                ),
              ),
            ),
            // Header
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: Spacing.md,
                vertical: Spacing.xs,
              ),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(Spacing.xs),
                    decoration: BoxDecoration(
                      color: theme.buttonPrimary.withValues(alpha: 0.1),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      Icons.psychology_outlined,
                      color: theme.buttonPrimary,
                      size: 20,
                    ),
                  ),
                  const SizedBox(width: Spacing.sm),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'System Prompt (系统设定)',
                          style: TextStyle(
                            color: theme.textPrimary,
                            fontWeight: FontWeight.w700,
                            fontSize: 16,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        Text(
                          title,
                          style: TextStyle(
                            color: theme.textSecondary,
                            fontSize: 12,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  if (hasPrompt)
                    IconButton(
                      icon: const Icon(Icons.copy_rounded, size: 18),
                      tooltip: 'Copy Prompt',
                      onPressed: () {
                        Clipboard.setData(ClipboardData(text: systemRole));
                        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                          const SnackBar(
                            content: Text('System prompt copied to clipboard'),
                            duration: Duration(seconds: 2),
                          ),
                        );
                      },
                    ),
                  IconButton(
                    icon: const Icon(Icons.close_rounded, size: 20),
                    tooltip: 'Close',
                    onPressed: () => Navigator.of(sheetContext).pop(),
                  ),
                ],
              ),
            ),
            Divider(color: theme.divider.withValues(alpha: 0.5), height: 1),
            // Scrollable full system instructions
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(Spacing.md),
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(Spacing.md),
                  decoration: BoxDecoration(
                    color: theme.cardBackground,
                    borderRadius: BorderRadius.circular(AppBorderRadius.md),
                    border: Border.all(
                      color: theme.divider.withValues(alpha: 0.4),
                      width: 1,
                    ),
                  ),
                  child: SelectableText(
                    hasPrompt
                        ? systemRole
                        : 'No system instructions configured for this agent. (此智能体暂无预设系统指令)',
                    style: TextStyle(
                      color: hasPrompt ? theme.textPrimary : theme.textSecondary,
                      fontSize: 13,
                      height: 1.5,
                      fontFamily: 'monospace',
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final agentsState = ref.watch(lobeAgentsProvider);
    final filteredAgents = ref.watch(lobeFilteredAgentsProvider);

    return Scaffold(
      backgroundColor: theme.surfaceBackground,
      appBar: AppBar(
        title: const Text(
          'Agents',
          style: TextStyle(fontWeight: FontWeight.w700),
        ),
        backgroundColor: theme.surfaceBackground,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        actions: [
          // Toggle grid/list view button
          IconButton(
            key: const ValueKey('toggle-view-mode-button'),
            icon: Icon(
              _isGridView ? Icons.view_list_rounded : Icons.grid_view_rounded,
            ),
            tooltip: _isGridView ? 'Switch to list view' : 'Switch to grid view',
            onPressed: _toggleViewMode,
          ),
          // Refresh button
          IconButton(
            key: const ValueKey('refresh-agents-button'),
            icon: const Icon(Icons.refresh_rounded),
            tooltip: 'Refresh',
            onPressed: _refresh,
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            // Search field
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: Spacing.md,
                vertical: Spacing.xs,
              ),
              child: _buildSearchBar(context, theme),
            ),
            // Offline banner if offline
            if (agentsState.isOffline)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: Spacing.md,
                  vertical: Spacing.xs,
                ),
                color: theme.statusWarning.withValues(alpha: 0.15),
                child: Row(
                  children: [
                    Icon(
                      Icons.cloud_off_rounded,
                      size: 16,
                      color: theme.statusWarning,
                    ),
                    const SizedBox(width: Spacing.xs),
                    Expanded(
                      child: Text(
                        'Offline mode: showing cached agents',
                        style: TextStyle(
                          fontSize: 12,
                          color: theme.statusWarning,
                          fontWeight: FontWeight.w600,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
            // Main content
            Expanded(
              child: _buildBody(
                context,
                theme,
                agentsState,
                filteredAgents,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSearchBar(BuildContext context, ConduitThemeExtension theme) {
    return Container(
      height: 40,
      decoration: BoxDecoration(
        color: theme.inputBackground,
        borderRadius: BorderRadius.circular(AppBorderRadius.md),
        border: Border.all(
          color: theme.inputBorder,
          width: 1,
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: Spacing.sm),
      child: Row(
        children: [
          Icon(
            Icons.search_rounded,
            size: 20,
            color: theme.textSecondary,
          ),
          const SizedBox(width: Spacing.xs),
          Expanded(
            child: TextField(
              key: const ValueKey('agents-search-field'),
              controller: _searchController,
              decoration: InputDecoration(
                hintText: 'Search agents...',
                hintStyle: TextStyle(
                  color: theme.textSecondary.withValues(alpha: 0.7),
                  fontSize: 14,
                ),
                border: InputBorder.none,
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(vertical: 8),
              ),
              style: TextStyle(
                color: theme.textPrimary,
                fontSize: 14,
              ),
            ),
          ),
          if (_searchController.text.isNotEmpty)
            GestureDetector(
              key: const ValueKey('clear-search-button'),
              onTap: () {
                _searchController.clear();
                ref.read(lobeAgentsProvider.notifier).clearSearchQuery();
              },
              child: Padding(
                padding: const EdgeInsets.all(4),
                child: Icon(
                  Icons.clear_rounded,
                  size: 16,
                  color: theme.textSecondary,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildBody(
    BuildContext context,
    ConduitThemeExtension theme,
    LobeAgentsState state,
    List<LobeAgent> filteredAgents,
  ) {
    if (state.isLoading && state.agents.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(
              strokeWidth: 2.5,
              valueColor: AlwaysStoppedAnimation<Color>(theme.buttonPrimary),
            ),
            const SizedBox(height: Spacing.md),
            Text(
              'Loading agents...',
              style: TextStyle(color: theme.textSecondary, fontSize: 13),
            ),
          ],
        ),
      );
    }

    if (state.errorMessage != null && state.agents.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(Spacing.xl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.error_outline_rounded,
                size: 48,
                color: theme.statusError,
              ),
              const SizedBox(height: Spacing.md),
              Text(
                'Failed to load agents',
                style: TextStyle(
                  color: theme.textPrimary,
                  fontWeight: FontWeight.w700,
                  fontSize: 16,
                ),
              ),
              const SizedBox(height: Spacing.xs),
              Text(
                state.errorMessage!,
                textAlign: TextAlign.center,
                style: TextStyle(color: theme.textSecondary, fontSize: 12),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: Spacing.lg),
              FilledButton.icon(
                onPressed: _refresh,
                icon: const Icon(Icons.refresh_rounded, size: 18),
                label: const Text('Retry'),
                style: FilledButton.styleFrom(
                  backgroundColor: theme.buttonPrimary,
                  foregroundColor: Colors.white,
                ),
              ),
            ],
          ),
        ),
      );
    }

    if (filteredAgents.isEmpty) {
      final isSearching = state.searchQuery.trim().isNotEmpty;
      return RefreshIndicator(
        onRefresh: _refresh,
        color: theme.buttonPrimary,
        child: LayoutBuilder(
          builder: (context, constraints) => SingleChildScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: constraints.maxHeight),
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(Spacing.xl),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.smart_toy_outlined,
                        size: 56,
                        color: theme.textSecondary.withValues(alpha: 0.5),
                      ),
                      const SizedBox(height: Spacing.md),
                      Text(
                        isSearching
                            ? 'No agents matching "${state.searchQuery}"'
                            : LobeAgentsState.defaultEmptyAgentsMessage,
                        style: TextStyle(
                          color: theme.textSecondary,
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: Spacing.lg),
                      OutlinedButton.icon(
                        onPressed: _refresh,
                        icon: const Icon(Icons.refresh_rounded, size: 16),
                        label: const Text('Refresh'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: theme.buttonPrimary,
                          side: BorderSide(
                            color: theme.buttonPrimary.withValues(alpha: 0.5),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _refresh,
      color: theme.buttonPrimary,
      child: _isGridView
          ? _buildGridView(context, theme, filteredAgents)
          : _buildListView(context, theme, filteredAgents),
    );
  }

  Widget _buildListView(
    BuildContext context,
    ConduitThemeExtension theme,
    List<LobeAgent> agents,
  ) {
    return ListView.separated(
      key: const ValueKey('agents-list-view'),
      controller: _scrollController,
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.symmetric(
        horizontal: Spacing.md,
        vertical: Spacing.sm,
      ),
      itemCount: agents.length,
      separatorBuilder: (_, __) => const SizedBox(height: Spacing.sm),
      itemBuilder: (context, index) {
        final agent = agents[index];
        return _AgentListCard(
          agent: agent,
          onTap: () => _handleAgentTap(agent),
        );
      },
    );
  }

  Widget _buildGridView(
    BuildContext context,
    ConduitThemeExtension theme,
    List<LobeAgent> agents,
  ) {
    return GridView.builder(
      key: const ValueKey('agents-grid-view'),
      controller: _scrollController,
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.symmetric(
        horizontal: Spacing.md,
        vertical: Spacing.sm,
      ),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        crossAxisSpacing: Spacing.sm,
        mainAxisSpacing: Spacing.sm,
        childAspectRatio: 0.82,
      ),
      itemCount: agents.length,
      itemBuilder: (context, index) {
        final agent = agents[index];
        return _AgentGridCard(
          agent: agent,
          onTap: () => _handleAgentTap(agent),
        );
      },
    );
  }
}

/// Helper method to build an avatar widget supporting emoji, network URL,
/// and colorful uppercase initial badge fallback when the image fails.
Widget buildAgentAvatar(
  BuildContext context,
  ConduitThemeExtension theme,
  String? avatar,
  String title, {
  double size = 44.0,
  String? agentId,
}) {
  final trimmed = avatar?.trim() ?? '';
  final isEmoji = trimmed.isNotEmpty &&
      trimmed.runes.length <= 2 &&
      !trimmed.startsWith('http');

  if (isEmoji) {
    return Container(
      key: agentId != null ? ValueKey('agent-avatar-emoji-$agentId') : null,
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: theme.buttonPrimary.withValues(alpha: 0.1),
        shape: BoxShape.circle,
      ),
      alignment: Alignment.center,
      child: Text(
        trimmed,
        style: TextStyle(fontSize: size * 0.52),
      ),
    );
  }

  if (trimmed.startsWith('http://') || trimmed.startsWith('https://')) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(size / 2),
      child: Image.network(
        trimmed,
        width: size,
        height: size,
        fit: BoxFit.cover,
        errorBuilder: (context, error, stackTrace) => buildFallbackAvatar(
          theme,
          title,
          size: size,
          agentId: agentId,
        ),
      ),
    );
  }

  return buildFallbackAvatar(
    theme,
    title,
    size: size,
    agentId: agentId,
  );
}

/// Helper method to build a colorful uppercase initial badge avatar fallback.
Widget buildFallbackAvatar(
  ConduitThemeExtension theme,
  String title, {
  double size = 44.0,
  String? agentId,
}) {
  final cleanTitle = title.trim();
  final initial = cleanTitle.isNotEmpty
      ? cleanTitle.characters.first.toUpperCase()
      : '?';
  final bgColor = _getAvatarBackgroundColor(cleanTitle);

  return Container(
    key: agentId != null
        ? ValueKey('agent-avatar-fallback-$agentId')
        : ValueKey('agent-avatar-fallback-$title'),
    width: size,
    height: size,
    decoration: BoxDecoration(
      color: bgColor,
      shape: BoxShape.circle,
      boxShadow: [
        BoxShadow(
          color: bgColor.withValues(alpha: 0.25),
          blurRadius: 4,
          offset: const Offset(0, 2),
        ),
      ],
    ),
    alignment: Alignment.center,
    child: Text(
      initial,
      style: TextStyle(
        color: Colors.white,
        fontWeight: FontWeight.bold,
        fontSize: size * 0.42,
      ),
    ),
  );
}

/// Helper method to build a clean model badge.
Widget buildModelBadge(
  BuildContext context,
  ConduitThemeExtension theme,
  String model,
) {
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
    decoration: BoxDecoration(
      color: theme.buttonPrimary.withValues(alpha: 0.08),
      borderRadius: BorderRadius.circular(AppBorderRadius.pill),
      border: Border.all(
        color: theme.buttonPrimary.withValues(alpha: 0.2),
        width: 0.8,
      ),
    ),
    constraints: const BoxConstraints(maxWidth: 100),
    child: Text(
      model,
      style: TextStyle(
        color: theme.buttonPrimary,
        fontSize: 10,
        fontWeight: FontWeight.w600,
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    ),
  );
}

/// Agent list item card.
class _AgentListCard extends StatelessWidget {
  const _AgentListCard({
    required this.agent,
    required this.onTap,
  });

  final LobeAgent agent;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final title = agent.title ?? agent.name ?? 'Untitled Agent';
    final description = agent.description ?? '';
    final model = agent.model;
    final avatar = agent.avatar;
    final systemRole = agent.systemRole?.trim();

    return Material(
      color: theme.cardBackground,
      borderRadius: BorderRadius.circular(AppBorderRadius.lg),
      child: InkWell(
        key: ValueKey('agent-card-${agent.id}'),
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppBorderRadius.lg),
        child: Container(
          padding: const EdgeInsets.all(Spacing.md),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppBorderRadius.lg),
            border: Border.all(
              color: theme.divider.withValues(alpha: 0.5),
              width: 1,
            ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Avatar
              buildAgentAvatar(
                context,
                theme,
                avatar,
                title,
                size: 46,
                agentId: agent.id,
              ),
              const SizedBox(width: Spacing.md),
              // Content
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            title,
                            style: TextStyle(
                              color: theme.textPrimary,
                              fontWeight: FontWeight.w700,
                              fontSize: 15,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (model != null && model.isNotEmpty) ...[
                          const SizedBox(width: Spacing.xs),
                          buildModelBadge(context, theme, model),
                        ],
                      ],
                    ),
                    if (description.isNotEmpty) ...[
                      const SizedBox(height: Spacing.xs),
                      Text(
                        description,
                        style: TextStyle(
                          color: theme.textSecondary,
                          fontSize: 12,
                          height: 1.3,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                    if (systemRole != null && systemRole.isNotEmpty) ...[
                      const SizedBox(height: Spacing.xs),
                      Row(
                        children: [
                          Icon(
                            Icons.psychology_outlined,
                            size: 13,
                            color: theme.textSecondary.withValues(alpha: 0.7),
                          ),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Text(
                              systemRole,
                              style: TextStyle(
                                color: theme.textSecondary.withValues(alpha: 0.8),
                                fontSize: 11,
                                fontStyle: FontStyle.italic,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: Spacing.xs),
              Icon(
                Icons.chevron_right_rounded,
                size: 18,
                color: theme.textSecondary.withValues(alpha: 0.4),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Agent grid item card.
class _AgentGridCard extends StatelessWidget {
  const _AgentGridCard({
    required this.agent,
    required this.onTap,
  });

  final LobeAgent agent;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final title = agent.title ?? agent.name ?? 'Untitled Agent';
    final description = agent.description ?? '';
    final model = agent.model;
    final avatar = agent.avatar;
    final systemRole = agent.systemRole?.trim();

    return Material(
      color: theme.cardBackground,
      borderRadius: BorderRadius.circular(AppBorderRadius.lg),
      child: InkWell(
        key: ValueKey('agent-card-${agent.id}'),
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppBorderRadius.lg),
        child: Container(
          padding: const EdgeInsets.all(Spacing.md),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppBorderRadius.lg),
            border: Border.all(
              color: theme.divider.withValues(alpha: 0.5),
              width: 1,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Top row: Avatar & model badge
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  buildAgentAvatar(
                    context,
                    theme,
                    avatar,
                    title,
                    size: 40,
                    agentId: agent.id,
                  ),
                  const Spacer(),
                  if (model != null && model.isNotEmpty)
                    buildModelBadge(context, theme, model),
                ],
              ),
              const SizedBox(height: Spacing.sm),
              // Title
              Text(
                title,
                style: TextStyle(
                  color: theme.textPrimary,
                  fontWeight: FontWeight.w700,
                  fontSize: 14,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              // Description
              if (description.isNotEmpty) ...[
                const SizedBox(height: Spacing.xs),
                Expanded(
                  child: Text(
                    description,
                    style: TextStyle(
                      color: theme.textSecondary,
                      fontSize: 11,
                      height: 1.3,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ] else
                const Spacer(),
              // System prompt preview
              if (systemRole != null && systemRole.isNotEmpty) ...[
                const SizedBox(height: Spacing.xs),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: theme.inputBackground,
                    borderRadius: BorderRadius.circular(AppBorderRadius.sm),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.psychology_outlined,
                        size: 11,
                        color: theme.textSecondary.withValues(alpha: 0.7),
                      ),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          systemRole,
                          style: TextStyle(
                            color: theme.textSecondary.withValues(alpha: 0.8),
                            fontSize: 10,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Agent actions bottom sheet modal presenting quick actions.
class _AgentActionsModalSheet extends StatelessWidget {
  const _AgentActionsModalSheet({
    required this.agent,
    required this.onStartChat,
    required this.onViewSystemPrompt,
  });

  final LobeAgent agent;
  final ValueChanged<LobeAgent> onStartChat;
  final ValueChanged<LobeAgent> onViewSystemPrompt;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final title = agent.title ?? agent.name ?? 'Untitled Agent';
    final description = agent.description ?? '';
    final model = agent.model;
    final avatar = agent.avatar;

    return Container(
      key: const ValueKey('agent-actions-bottom-sheet'),
      decoration: BoxDecoration(
        color: theme.surfaceBackground,
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(AppBorderRadius.bottomSheet),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.15),
            blurRadius: 16,
            offset: const Offset(0, -4),
          ),
        ],
      ),
      padding: EdgeInsets.only(
        bottom: MediaQuery.paddingOf(context).bottom + Spacing.md,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Drag handle
          Center(
            child: Container(
              margin: const EdgeInsets.only(
                top: Spacing.sm,
                bottom: Spacing.sm,
              ),
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: theme.textSecondary.withValues(alpha: 0.3),
                borderRadius: BorderRadius.circular(AppBorderRadius.pill),
              ),
            ),
          ),
          // Agent Header
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: Spacing.lg,
              vertical: Spacing.xs,
            ),
            child: Row(
              children: [
                buildAgentAvatar(
                  context,
                  theme,
                  avatar,
                  title,
                  size: 52,
                  agentId: agent.id,
                ),
                const SizedBox(width: Spacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              title,
                              style: TextStyle(
                                color: theme.textPrimary,
                                fontWeight: FontWeight.w700,
                                fontSize: 17,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (model != null && model.isNotEmpty) ...[
                            const SizedBox(width: Spacing.xs),
                            buildModelBadge(context, theme, model),
                          ],
                        ],
                      ),
                      if (description.isNotEmpty) ...[
                        const SizedBox(height: Spacing.xs),
                        Text(
                          description,
                          style: TextStyle(
                            color: theme.textSecondary,
                            fontSize: 13,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: Spacing.sm),
          Divider(color: theme.divider.withValues(alpha: 0.5), height: 1),
          const SizedBox(height: Spacing.xs),
          // Action 1: Start New Chat
          ListTile(
            key: const ValueKey('action-start-new-chat'),
            leading: Container(
              padding: const EdgeInsets.all(Spacing.xs + 2),
              decoration: BoxDecoration(
                color: theme.buttonPrimary.withValues(alpha: 0.12),
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.chat_bubble_outline_rounded,
                color: theme.buttonPrimary,
                size: 22,
              ),
            ),
            title: Text(
              'Start New Chat (开启新对话)',
              style: TextStyle(
                color: theme.textPrimary,
                fontWeight: FontWeight.w600,
                fontSize: 15,
              ),
            ),
            subtitle: Text(
              'Create new conversation with this agent',
              style: TextStyle(
                color: theme.textSecondary,
                fontSize: 12,
              ),
            ),
            trailing: Icon(
              Icons.chevron_right_rounded,
              color: theme.textSecondary,
              size: 20,
            ),
            onTap: () {
              Navigator.of(context).pop();
              onStartChat(agent);
            },
          ),
          // Action 2: View System Prompt
          ListTile(
            key: const ValueKey('action-view-system-prompt'),
            leading: Container(
              padding: const EdgeInsets.all(Spacing.xs + 2),
              decoration: BoxDecoration(
                color: theme.textSecondary.withValues(alpha: 0.12),
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.psychology_outlined,
                color: theme.textSecondary,
                size: 22,
              ),
            ),
            title: Text(
              'View System Prompt (查看系统设定)',
              style: TextStyle(
                color: theme.textPrimary,
                fontWeight: FontWeight.w600,
                fontSize: 15,
              ),
            ),
            subtitle: Text(
              'Inspect system instructions and role definition',
              style: TextStyle(
                color: theme.textSecondary,
                fontSize: 12,
              ),
            ),
            trailing: Icon(
              Icons.chevron_right_rounded,
              color: theme.textSecondary,
              size: 20,
            ),
            onTap: () {
              Navigator.of(context).pop();
              onViewSystemPrompt(agent);
            },
          ),
        ],
      ),
    );
  }
}
