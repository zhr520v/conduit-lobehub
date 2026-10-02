import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/features/lobehub/providers/lobehub_topics_provider.dart';
import 'package:conduit_core/providers/app_providers.dart';

import '../../../core/router/app_router.dart';
import '../../../core/services/haptic_service.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/theme/theme_providers.dart';
import '../../../shared/widgets/platform_ui/platform_ui.dart';

/// Font scale provider for dynamic typography adjustment.
final lobeFontScaleProvider = StateProvider<double>((ref) => 1.0);

/// Font scale preset definitions.
enum LobeFontScalePreset {
  small(0.85, 'Small (小号)'),
  standard(1.0, 'Standard (标准)'),
  large(1.15, 'Large (大号)');

  const LobeFontScalePreset(this.scale, this.label);
  final double scale;
  final String label;
}

/// Dedicated LobeHub Settings Page (Conduit Edition).
///
/// Implements full settings center:
/// - Server & User Info (Server URL, Online status, user profile & sign-out)
/// - Appearance & Theme (System, Dark, Light reactive toggle)
/// - Typography & Font Size (Presets & continuous slider)
/// - Data & Storage (Safe local SQLite cache clearing with confirmation dialog)
/// - Preferences (Haptic feedback, reasoning capsule collapse)
/// - About Information (App name, version, GPL v3 license, and GitHub repo credits)
class LobehubSettingsPage extends ConsumerStatefulWidget {
  const LobehubSettingsPage({
    super.key,
    this.initialServerUrl,
    this.initialServerName,
    this.initialUserName,
    this.initialUserRole,
    this.initialUserAvatar,
    this.initialThemeMode,
    this.onThemeModeChanged,
    this.initialFontScale,
    this.onFontScaleChanged,
    this.onSignOut,
    this.onClearCache,
    this.version = 'v1.0.0',
    this.licenseText = 'GPL-3.0 License',
    this.repoCredits = 'GitHub: cogwheel0/conduit & LobeHub',
  });

  /// Optional override for current connected server URL.
  final String? initialServerUrl;

  /// Optional override for current server display name.
  final String? initialServerName;

  /// Optional override for logged in user name.
  final String? initialUserName;

  /// Optional override for logged in user role.
  final String? initialUserRole;

  /// Optional override for user avatar image URL.
  final String? initialUserAvatar;

  /// Optional override for initial theme mode.
  final ThemeMode? initialThemeMode;

  /// Optional callback invoked when theme mode changes.
  final ValueChanged<ThemeMode>? onThemeModeChanged;

  /// Optional override for initial font scale.
  final double? initialFontScale;

  /// Optional callback invoked when font scale changes.
  final ValueChanged<double>? onFontScaleChanged;

  /// Optional callback invoked when sign out / disconnect is confirmed.
  final FutureOr<void> Function()? onSignOut;

  /// Optional callback invoked when local cache wipe is confirmed.
  final FutureOr<void> Function()? onClearCache;

  /// App version string.
  final String version;

  /// Open-source license text.
  final String licenseText;

  /// GitHub repository credits text.
  final String repoCredits;

  @override
  ConsumerState<LobehubSettingsPage> createState() => _LobehubSettingsPageState();
}

/// Compatibility alias matching Conduit naming conventions.
typedef LobeSettingsPage = LobehubSettingsPage;

class _LobehubSettingsPageState extends ConsumerState<LobehubSettingsPage> {
  late ThemeMode _currentThemeMode;

  @override
  void initState() {
    super.initState();
    _currentThemeMode = widget.initialThemeMode ?? ThemeMode.system;
  }
  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final l10n = AppLocalizations.of(context);
    final title = l10n?.settings ?? 'Settings';

    return Scaffold(
      backgroundColor: theme.surfaceBackground,
      appBar: AppBar(
        title: Text(
          title,
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
        backgroundColor: theme.surfaceBackground,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.symmetric(
            horizontal: Spacing.md,
            vertical: Spacing.sm,
          ),
          children: [
            _buildServerSection(context, theme),
            const SizedBox(height: Spacing.lg),
            _buildAppearanceSection(context, theme),
            const SizedBox(height: Spacing.lg),
            _buildTypographySection(context, theme),
            const SizedBox(height: Spacing.lg),
            _buildStorageSection(context, theme),
            const SizedBox(height: Spacing.lg),
            _buildPreferencesSection(context, theme),
            const SizedBox(height: Spacing.lg),
            _buildAboutSection(context, theme),
            const SizedBox(height: Spacing.xl),
          ],
        ),
      ),
    );
  }

  Widget _buildSectionHeader(
    BuildContext context,
    ConduitThemeExtension theme,
    String title,
    IconData icon,
  ) {
    return Padding(
      padding: const EdgeInsets.only(bottom: Spacing.xs, left: Spacing.xs),
      child: Row(
        children: [
          Icon(icon, size: 16, color: theme.buttonPrimary),
          const SizedBox(width: Spacing.xs),
          Text(
            title,
            style: TextStyle(
              color: theme.buttonPrimary,
              fontWeight: FontWeight.w700,
              fontSize: 12,
              letterSpacing: 0.5,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCardContainer({
    required ConduitThemeExtension theme,
    required List<Widget> children,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: theme.cardBackground,
        borderRadius: BorderRadius.circular(AppBorderRadius.lg),
        border: Border.all(
          color: theme.divider.withValues(alpha: 0.5),
          width: 1,
        ),
        boxShadow: theme.cardShadows,
      ),
      child: Column(
        children: [
          for (int i = 0; i < children.length; i++) ...[
            if (i > 0)
              Divider(
                height: 1,
                thickness: 0.5,
                color: theme.divider.withValues(alpha: 0.3),
              ),
            children[i],
          ],
        ],
      ),
    );
  }

  // ==========================================
  // Section 1: Server & User Information
  // ==========================================
  Widget _buildServerSection(
    BuildContext context,
    ConduitThemeExtension theme,
  ) {
    final activeServer = ref.watch(activeServerProvider).maybeWhen(
          data: (s) => s,
          orElse: () => null,
        );
    final user = ref.watch(currentUserProvider2);

    final serverUrl = widget.initialServerUrl ??
        activeServer?.url ??
        'https://ai.opw.ink';
    final serverName = widget.initialServerName ??
        activeServer?.name ??
        'LobeHub Server';
    final userName = widget.initialUserName ??
        user?.name ??
        user?.email ??
        'Self-hosted User';
    final userRole = widget.initialUserRole ?? user?.role ?? 'Owner';
    final userAvatar = widget.initialUserAvatar ?? user?.avatar;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildSectionHeader(
          context,
          theme,
          'SERVER CONNECTION',
          Icons.dns_outlined,
        ),
        _buildCardContainer(
          theme: theme,
          children: [
            // Row 1: Server URL and Online indicator
            Padding(
              padding: const EdgeInsets.all(Spacing.md),
              child: Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: theme.buttonPrimary.withValues(alpha: 0.12),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      Icons.cloud_done_rounded,
                      color: theme.buttonPrimary,
                      size: 22,
                    ),
                  ),
                  const SizedBox(width: Spacing.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          serverName,
                          style: TextStyle(
                            color: theme.textPrimary,
                            fontWeight: FontWeight.w700,
                            fontSize: 14,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          serverUrl,
                          key: const Key('lobehub-server-url-text'),
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
                  // Online / Active status badge
                  Container(
                    key: const Key('lobehub-server-status-indicator'),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: theme.statusSuccess.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(AppBorderRadius.pill),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 6,
                          height: 6,
                          decoration: BoxDecoration(
                            color: theme.statusSuccess,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 4),
                        Text(
                          'Online',
                          style: TextStyle(
                            color: theme.statusSuccess,
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            // Row 2: User profile info (username, role, avatar)
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: Spacing.md,
                vertical: Spacing.sm,
              ),
              child: Row(
                children: [
                  _buildUserAvatar(theme, userAvatar, userName),
                  const SizedBox(width: Spacing.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          userName,
                          key: const Key('lobehub-username-text'),
                          style: TextStyle(
                            color: theme.textPrimary,
                            fontWeight: FontWeight.w600,
                            fontSize: 13,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 1),
                        Text(
                          'Role: $userRole',
                          key: const Key('lobehub-user-role-text'),
                          style: TextStyle(
                            color: theme.textSecondary,
                            fontSize: 11,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            // Row 3: Modify Connection / Sign Out button
            InkWell(
              key: const Key('lobehub-sign-out-button'),
              onTap: () => _showSignOutDialog(context, theme),
              borderRadius: const BorderRadius.only(
                bottomLeft: Radius.circular(AppBorderRadius.lg),
                bottomRight: Radius.circular(AppBorderRadius.lg),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: Spacing.md,
                  vertical: Spacing.sm + 2,
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.swap_horiz_rounded,
                      size: 18,
                      color: theme.buttonPrimary,
                    ),
                    const SizedBox(width: Spacing.sm),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Modify Connection / Sign Out (修改连接 / 重新登录)',
                            style: TextStyle(
                              color: theme.buttonPrimary,
                              fontWeight: FontWeight.w600,
                              fontSize: 13,
                            ),
                          ),
                          Text(
                            'Switch server address or sign in with another account',
                            style: TextStyle(
                              color: theme.textSecondary,
                              fontSize: 11,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Icon(
                      Icons.chevron_right_rounded,
                      size: 18,
                      color: theme.textSecondary,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildUserAvatar(
    ConduitThemeExtension theme,
    String? avatarUrl,
    String userName,
  ) {
    if (avatarUrl != null && avatarUrl.trim().isNotEmpty) {
      return ClipOval(
        child: Image.network(
          avatarUrl,
          width: 28,
          height: 28,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => _buildFallbackAvatar(theme, userName),
        ),
      );
    }
    return _buildFallbackAvatar(theme, userName);
  }

  Widget _buildFallbackAvatar(ConduitThemeExtension theme, String userName) {
    final initial = userName.isNotEmpty ? userName[0].toUpperCase() : 'U';
    return Container(
      width: 28,
      height: 28,
      decoration: BoxDecoration(
        color: theme.buttonPrimary.withValues(alpha: 0.15),
        shape: BoxShape.circle,
      ),
      alignment: Alignment.center,
      child: Text(
        initial,
        style: TextStyle(
          color: theme.buttonPrimary,
          fontSize: 12,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  // ==========================================
  // Section 2: Appearance & Theme
  // ==========================================
  Widget _buildAppearanceSection(
    BuildContext context,
    ConduitThemeExtension theme,
  ) {
    ThemeMode themeMode = _currentThemeMode;
    try {
      themeMode = ref.watch(appThemeModeProvider);
    } catch (_) {
      themeMode = _currentThemeMode;
    }

    void setTheme(ThemeMode mode) {
      ConduitHaptics.selectionClick();
      setState(() {
        _currentThemeMode = mode;
      });
      try {
        ref.read(appThemeModeProvider.notifier).setTheme(mode);
      } catch (_) {}
      widget.onThemeModeChanged?.call(mode);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildSectionHeader(
          context,
          theme,
          'APPEARANCE & THEME',
          Icons.palette_outlined,
        ),
        _buildCardContainer(
          theme: theme,
          children: [
            Padding(
              padding: const EdgeInsets.all(Spacing.md),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Theme Mode (外观模式)',
                    style: TextStyle(
                      color: theme.textPrimary,
                      fontWeight: FontWeight.w600,
                      fontSize: 14,
                    ),
                  ),
                  const SizedBox(height: Spacing.sm),
                  Row(
                    children: [
                      Expanded(
                        child: _buildThemeModeButton(
                          key: const Key('lobehub-theme-system-button'),
                          theme: theme,
                          title: 'System (跟随系统)',
                          icon: Icons.brightness_auto_rounded,
                          isSelected: themeMode == ThemeMode.system,
                          onTap: () => setTheme(ThemeMode.system),
                        ),
                      ),
                      const SizedBox(width: Spacing.xs),
                      Expanded(
                        child: _buildThemeModeButton(
                          key: const Key('lobehub-theme-light-button'),
                          theme: theme,
                          title: 'Light (浅色模式)',
                          icon: Icons.light_mode_rounded,
                          isSelected: themeMode == ThemeMode.light,
                          onTap: () => setTheme(ThemeMode.light),
                        ),
                      ),
                      const SizedBox(width: Spacing.xs),
                      Expanded(
                        child: _buildThemeModeButton(
                          key: const Key('lobehub-theme-dark-button'),
                          theme: theme,
                          title: 'Dark (深色模式)',
                          icon: Icons.dark_mode_rounded,
                          isSelected: themeMode == ThemeMode.dark,
                          onTap: () => setTheme(ThemeMode.dark),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildThemeModeButton({
    required Key key,
    required ConduitThemeExtension theme,
    required String title,
    required IconData icon,
    required bool isSelected,
    required VoidCallback onTap,
  }) {
    return InkWell(
      key: key,
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppBorderRadius.md),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: Spacing.sm),
        decoration: BoxDecoration(
          color: isSelected
              ? theme.buttonPrimary.withValues(alpha: 0.12)
              : theme.inputBackground,
          borderRadius: BorderRadius.circular(AppBorderRadius.md),
          border: Border.all(
            color: isSelected
                ? theme.buttonPrimary
                : theme.inputBorder.withValues(alpha: 0.5),
            width: isSelected ? 1.5 : 1,
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 18,
              color: isSelected ? theme.buttonPrimary : theme.textSecondary,
            ),
            const SizedBox(height: 4),
            Text(
              title,
              style: TextStyle(
                fontSize: 10,
                fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
                color: isSelected ? theme.buttonPrimary : theme.textSecondary,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }

  // ==========================================
  // Section 3: Typography & Font Size
  // ==========================================
  Widget _buildTypographySection(
    BuildContext context,
    ConduitThemeExtension theme,
  ) {
    double fontScale = 1.0;
    try {
      fontScale = ref.watch(lobeFontScaleProvider);
    } catch (_) {}

    void setScale(double scale) {
      ConduitHaptics.selectionClick();
      try {
        ref.read(lobeFontScaleProvider.notifier).state = scale;
      } catch (_) {}
      widget.onFontScaleChanged?.call(scale);
    }

    String presetLabel;
    if ((fontScale - 0.85).abs() < 0.05) {
      presetLabel = 'Small (小号)';
    } else if ((fontScale - 1.15).abs() < 0.05) {
      presetLabel = 'Large (大号)';
    } else {
      presetLabel = 'Standard (标准)';
    }

    final percentageText = '${(fontScale * 100).round()}%';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildSectionHeader(
          context,
          theme,
          'TYPOGRAPHY & FONT SIZE',
          Icons.format_size_rounded,
        ),
        _buildCardContainer(
          theme: theme,
          children: [
            Padding(
              padding: const EdgeInsets.all(Spacing.md),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'Font Scale (字体大小与排版)',
                        style: TextStyle(
                          color: theme.textPrimary,
                          fontWeight: FontWeight.w600,
                          fontSize: 14,
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: theme.buttonPrimary.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(AppBorderRadius.pill),
                        ),
                        child: Text(
                          '$percentageText · $presetLabel',
                          key: const Key('lobehub-font-scale-current-label'),
                          style: TextStyle(
                            color: theme.buttonPrimary,
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: Spacing.sm),
                  // Preset buttons
                  Row(
                    children: [
                      Expanded(
                        child: _buildPresetButton(
                          key: const Key('lobehub-font-scale-small-button'),
                          theme: theme,
                          title: 'Small (小号)',
                          scale: 0.85,
                          isSelected: (fontScale - 0.85).abs() < 0.05,
                          onTap: () => setScale(0.85),
                        ),
                      ),
                      const SizedBox(width: Spacing.xs),
                      Expanded(
                        child: _buildPresetButton(
                          key: const Key('lobehub-font-scale-standard-button'),
                          theme: theme,
                          title: 'Standard (标准)',
                          scale: 1.0,
                          isSelected: (fontScale - 1.0).abs() < 0.05,
                          onTap: () => setScale(1.0),
                        ),
                      ),
                      const SizedBox(width: Spacing.xs),
                      Expanded(
                        child: _buildPresetButton(
                          key: const Key('lobehub-font-scale-large-button'),
                          theme: theme,
                          title: 'Large (大号)',
                          scale: 1.15,
                          isSelected: (fontScale - 1.15).abs() < 0.05,
                          onTap: () => setScale(1.15),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: Spacing.md),
                  // Continuous Slider
                  SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      activeTrackColor: theme.buttonPrimary,
                      inactiveTrackColor: theme.divider.withValues(alpha: 0.4),
                      thumbColor: theme.buttonPrimary,
                      overlayColor: theme.buttonPrimary.withValues(alpha: 0.15),
                      trackHeight: 4,
                      thumbShape: const RoundSliderThumbShape(
                        enabledThumbRadius: 7,
                      ),
                    ),
                    child: Slider(
                      key: const Key('lobehub-font-scale-slider'),
                      value: fontScale.clamp(0.85, 1.15),
                      min: 0.85,
                      max: 1.15,
                      divisions: 6,
                      label: percentageText,
                      onChanged: (val) {
                        setScale((val * 100).round() / 100);
                      },
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildPresetButton({
    required Key key,
    required ConduitThemeExtension theme,
    required String title,
    required double scale,
    required bool isSelected,
    required VoidCallback onTap,
  }) {
    return InkWell(
      key: key,
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppBorderRadius.md),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: Spacing.sm),
        decoration: BoxDecoration(
          color: isSelected
              ? theme.buttonPrimary.withValues(alpha: 0.12)
              : theme.inputBackground,
          borderRadius: BorderRadius.circular(AppBorderRadius.md),
          border: Border.all(
            color: isSelected
                ? theme.buttonPrimary
                : theme.inputBorder.withValues(alpha: 0.5),
            width: isSelected ? 1.5 : 1,
          ),
        ),
        child: Center(
          child: Text(
            title,
            style: TextStyle(
              fontSize: 11,
              fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
              color: isSelected ? theme.buttonPrimary : theme.textSecondary,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ),
    );
  }

  // ==========================================
  // Section 4: Data & Storage (Local SQLite Cache)
  // ==========================================
  Widget _buildStorageSection(
    BuildContext context,
    ConduitThemeExtension theme,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildSectionHeader(
          context,
          theme,
          'DATA & STORAGE',
          Icons.storage_rounded,
        ),
        _buildCardContainer(
          theme: theme,
          children: [
            InkWell(
              key: const Key('lobehub-clear-cache-button'),
              onTap: () => _showClearCacheDialog(context, theme),
              borderRadius: BorderRadius.circular(AppBorderRadius.lg),
              child: Padding(
                padding: const EdgeInsets.all(Spacing.md),
                child: Row(
                  children: [
                    Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color: theme.error.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(AppBorderRadius.md),
                      ),
                      child: Icon(
                        Icons.cleaning_services_rounded,
                        color: theme.error,
                        size: 20,
                      ),
                    ),
                    const SizedBox(width: Spacing.md),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Clear Local SQLite Cache (清空本地 SQLite 缓存)',
                            style: TextStyle(
                              color: theme.textPrimary,
                              fontWeight: FontWeight.w600,
                              fontSize: 13,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            'Reset locally cached conversations, messages and temporary files',
                            style: TextStyle(
                              color: theme.textSecondary,
                              fontSize: 11,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Icon(
                      Icons.chevron_right_rounded,
                      size: 20,
                      color: theme.textSecondary,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  // ==========================================
  // Section 5: Preferences (Haptic & Reasoning)
  // ==========================================
  Widget _buildPreferencesSection(
    BuildContext context,
    ConduitThemeExtension theme,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildSectionHeader(
          context,
          theme,
          'PREFERENCES',
          Icons.tune_rounded,
        ),
        _buildCardContainer(
          theme: theme,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: Spacing.md,
                vertical: Spacing.sm,
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.vibration_rounded,
                    size: 20,
                    color: theme.buttonPrimary,
                  ),
                  const SizedBox(width: Spacing.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Haptic Feedback',
                          style: TextStyle(
                            color: theme.textPrimary,
                            fontWeight: FontWeight.w600,
                            fontSize: 14,
                          ),
                        ),
                        Text(
                          'Vibrate on tab switches and interactions',
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
                  Icon(
                    Icons.check_circle_rounded,
                    size: 20,
                    color: theme.statusSuccess,
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: Spacing.md,
                vertical: Spacing.sm,
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.psychology_outlined,
                    size: 20,
                    color: theme.buttonPrimary,
                  ),
                  const SizedBox(width: Spacing.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Reasoning Display',
                          style: TextStyle(
                            color: theme.textPrimary,
                            fontWeight: FontWeight.w600,
                            fontSize: 14,
                          ),
                        ),
                        Text(
                          'Auto-collapse completed thinking capsules',
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
                  Icon(
                    Icons.check_circle_rounded,
                    size: 20,
                    color: theme.statusSuccess,
                  ),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }

  // ==========================================
  // Section 6: About Information
  // ==========================================
  Widget _buildAboutSection(
    BuildContext context,
    ConduitThemeExtension theme,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildSectionHeader(
          context,
          theme,
          'ABOUT',
          Icons.info_outline_rounded,
        ),
        _buildCardContainer(
          theme: theme,
          children: [
            // App Name & Version
            Padding(
              padding: const EdgeInsets.all(Spacing.md),
              child: Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: theme.buttonPrimary.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(AppBorderRadius.md),
                    ),
                    child: Icon(
                      Icons.hub_outlined,
                      color: theme.buttonPrimary,
                      size: 22,
                    ),
                  ),
                  const SizedBox(width: Spacing.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'LobeChat Native (Conduit Edition)',
                          key: const Key('lobehub-about-app-title'),
                          style: TextStyle(
                            color: theme.textPrimary,
                            fontWeight: FontWeight.w700,
                            fontSize: 14,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          widget.version,
                          key: const Key('lobehub-about-version-text'),
                          style: TextStyle(
                            color: theme.textSecondary,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            // GPL v3 Open-source license link
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: Spacing.md,
                vertical: Spacing.sm,
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.verified_user_outlined,
                    size: 18,
                    color: theme.buttonPrimary,
                  ),
                  const SizedBox(width: Spacing.sm),
                  Expanded(
                    child: Text(
                      'License: ${widget.licenseText}',
                      key: const Key('lobehub-about-license-text'),
                      style: TextStyle(
                        color: theme.textSecondary,
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            // GitHub repo credits
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: Spacing.md,
                vertical: Spacing.sm,
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.code_rounded,
                    size: 18,
                    color: theme.buttonPrimary,
                  ),
                  const SizedBox(width: Spacing.sm),
                  Expanded(
                    child: Text(
                      widget.repoCredits,
                      key: const Key('lobehub-about-credits-text'),
                      style: TextStyle(
                        color: theme.textSecondary,
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }

  // ==========================================
  // Confirmation Dialogs & Actions
  // ==========================================
  Future<void> _showSignOutDialog(
    BuildContext context,
    ConduitThemeExtension theme,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          key: const Key('lobehub-sign-out-dialog'),
          backgroundColor: theme.surfaces.popover,
          surfaceTintColor: Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppBorderRadius.dialog),
          ),
          title: Text(
            'Modify Connection / Sign Out (修改连接 / 重新登录)',
            style: TextStyle(
              color: theme.textPrimary,
              fontWeight: FontWeight.w700,
              fontSize: 18,
            ),
          ),
          content: Text(
            'Are you sure you want to disconnect from this server and modify your connection settings or sign out?\n\n确定要断开与当前服务器的连接并重新登录或修改配置吗？',
            style: TextStyle(
              color: theme.textSecondary,
              fontSize: 14,
              height: 1.4,
            ),
          ),
          actions: [
            TextButton(
              key: const Key('lobehub-sign-out-cancel-button'),
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: Text(
                'Cancel (取消)',
                style: TextStyle(
                  color: theme.textSecondary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            TextButton(
              key: const Key('lobehub-sign-out-confirm-button'),
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: Text(
                'Sign Out (重新登录)',
                style: TextStyle(
                  color: theme.error,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        );
      },
    );

    if (confirmed == true && mounted) {
      if (widget.onSignOut != null) {
        await widget.onSignOut!();
      } else {
        try {
          await ref.read(signOutCoordinatorProvider).signOut(keepServerDetails: true);
        } catch (_) {}
        if (mounted) {
          context.go(Routes.serverConnection);
        }
      }
    }
  }

  Future<void> _showClearCacheDialog(
    BuildContext context,
    ConduitThemeExtension theme,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          key: const Key('lobehub-clear-cache-dialog'),
          backgroundColor: theme.surfaces.popover,
          surfaceTintColor: Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppBorderRadius.dialog),
          ),
          title: Text(
            'Clear Local Cache (清空本地缓存)',
            style: TextStyle(
              color: theme.textPrimary,
              fontWeight: FontWeight.w700,
              fontSize: 18,
            ),
          ),
          content: Text(
            'Are you sure you want to clear the local SQLite cache? This will reset local topics and cached message data, but will not delete data on the remote server.\n\n确定要清空本地 SQLite 缓存吗？这将重置本地保存的话题和消息缓存，不会删除远程服务器上的数据。',
            style: TextStyle(
              color: theme.textSecondary,
              fontSize: 14,
              height: 1.4,
            ),
          ),
          actions: [
            TextButton(
              key: const Key('lobehub-clear-cache-cancel-button'),
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: Text(
                'Cancel (取消)',
                style: TextStyle(
                  color: theme.textSecondary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            TextButton(
              key: const Key('lobehub-clear-cache-confirm-button'),
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: Text(
                'Clear Cache (确认清空)',
                style: TextStyle(
                  color: theme.error,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        );
      },
    );

    if (confirmed == true && mounted) {
      try {
        if (widget.onClearCache != null) {
          await widget.onClearCache!();
        } else {
          try {
            ref.invalidate(lobeTopicsProvider);
          } catch (_) {}
        }
      } catch (_) {}

      ConduitHaptics.success();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            key: const Key('lobehub-clear-cache-toast'),
            content: const Text('Local cache cleared'),
            backgroundColor: theme.statusSuccess,
            duration: const Duration(seconds: 2),
          ),
        );
      }
    }
  }
}
