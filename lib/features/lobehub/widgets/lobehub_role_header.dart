import 'dart:math' as math;

import 'package:conduit_core/features/lobehub/providers/lobehub_agents_provider.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/adaptive_toolbar_components.dart';
import '../../navigation/views/main_navigation_shell.dart';

@immutable
class LobeHubRolePresentation {
  const LobeHubRolePresentation({
    required this.agentId,
    required this.title,
    this.modelId,
    this.provider,
  });

  final String agentId;
  final String title;
  final String? modelId;
  final String? provider;

  static LobeHubRolePresentation? fromConversation(Conversation? conversation) {
    if (conversation == null || conversation.metadata['backend'] != 'lobehub') {
      return null;
    }
    String? text(String key) {
      final value = conversation.metadata[key];
      return value is String && value.trim().isNotEmpty ? value.trim() : null;
    }

    final agentId = text('agentId');
    if (agentId == null) return null;
    return LobeHubRolePresentation(
      agentId: agentId,
      title: text('agentTitle') ?? agentId,
      modelId: text('agentModel'),
      provider: text('provider'),
    );
  }

  String get configurationLabel =>
      '${modelId ?? 'Model unavailable'} / ${provider ?? 'Provider unavailable'}';

  String get accessibleLabel => 'Agent: $title. '
      'Configured model: ${modelId ?? 'unavailable'}. '
      'Provider: ${provider ?? 'unavailable'}. '
      'Read-only: LobeHub REST 2.2.17 does not support per-turn model overrides. '
      'Open Agents to choose another role.';
}

class LobeHubRoleHeader extends ConsumerWidget {
  const LobeHubRoleHeader({
    super.key,
    required this.role,
    required this.maxWidth,
    this.isLoading = false,
    this.onOpenAgents,
  });

  final LobeHubRolePresentation role;
  final double maxWidth;
  final bool isLoading;
  final VoidCallback? onOpenAgents;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final width = maxWidth.clamp(0.0, double.infinity).toDouble();
    if (width == 0) return const SizedBox.shrink();
    final titleStyle = conduitAdaptiveToolbarLeadingTitleTextStyle(context);
    final configurationStyle = AppTypography.captionStyle.copyWith(
      color: context.conduitTheme.textSecondary,
    );
    double textHeight(String label, TextStyle style) => (TextPainter(
      text: TextSpan(text: label, style: style),
      maxLines: 1,
      textScaler: MediaQuery.textScalerOf(context),
      textDirection: Directionality.of(context),
    )..layout()).height;
    final height = math.max(
      conduitScaledControlExtent(context),
      textHeight(role.title, titleStyle) +
          textHeight(role.configurationLabel, configurationStyle) +
          Spacing.xxs + Spacing.sm,
    );
    void openAgents() {
      onOpenAgents?.call();
      ref.read(lobeAgentsProvider.notifier).selectAgent(role.agentId);
      ref.read(mainNavigationIndexProvider.notifier).state = 1;
    }

    return Tooltip(
      message: role.accessibleLabel,
      excludeFromSemantics: true,
      child: Semantics(
        key: const ValueKey('lobehub-role-header'),
        label: role.accessibleLabel,
        button: true,
        enabled: !isLoading,
        onTap: isLoading ? null : openAgents,
        excludeSemantics: true,
        child: buildConduitAdaptiveToolbarPillSurface(
          width: width,
          height: height,
          onPressed: isLoading ? null : openAgents,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: Spacing.sm),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(role.title,
                  key: const ValueKey('lobehub-role-title'),
                  style: titleStyle, maxLines: 1, overflow: TextOverflow.ellipsis),
                const SizedBox(height: Spacing.xxs),
                Text(role.configurationLabel,
                  key: const ValueKey('lobehub-role-configuration'),
                  style: configurationStyle, maxLines: 1,
                  overflow: TextOverflow.ellipsis),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
