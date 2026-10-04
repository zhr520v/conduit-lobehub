# Conduit Design System Contract & Component Tokens

This document codifies the existing production design tokens and component primitives of Conduit for the LobeHub client. Per project mandate, this establishes the visual and structural design contract across 8 standard sections without introducing a new theme.

---

## 1. Design System Architecture & Foundations

Conduit's design system is an adaptive, token-driven architecture layered over `ConduitThemeExtension`, `TweakcnThemeDefinition`, and platform-adaptive UI primitives (`material_ui` and `cupertino_ui`).

- **Single Source of Truth**: UI surfaces consume design tokens strictly through `context.conduitTheme` (`ConduitThemeExtension`) and `context.colorTokens`.
- **Adaptive Execution**: Material 3 chrome on Android and Cupertino navigation chrome on iOS (`context.usesCupertinoChrome`).
- **No New Themes**: All styling reuses existing Conduit palettes (`TweakcnThemes.conduit`, `TweakcnThemes.t3Chat`) across light and dark modes without creating ad-hoc color schemes or overriding token layers.
- **Visual Invariant**: Pure semantic tokens drive surface fills, borders, typography, and elevations. Direct hardcoded hex colors or arbitrary magic layout constants are strictly forbidden.

---

## 2. Token Specifications

### Color Tokens & Semantic Palette

The color system is derived from `AppColorTokens` and exposed through `ConduitThemeExtension`:

| Token | Semantic Role | Light Mode Value | Dark Mode Value |
|---|---|---|---|
| `surfaceBackground` | Root page background | `surfaces.background` | `surfaces.background` |
| `cardBackground` | Elevated surfaces, cards, modals | `surfaces.card` | `surfaces.card` |
| `cardBorder` | Card & container boundaries | `surfaces.border` | `surfaces.border` |
| `buttonPrimary` | Primary actions & accent highlights | `variant.primary` | `variant.primary` |
| `buttonPrimaryText` | High-contrast label on primary action | White / Light Ink | Dark Ink |
| `inputBackground` | Search & text field containers | `surfaces.input` blended | `surfaces.input` blended |
| `inputBorder` | Resting text input border | `surfaces.border` | `surfaces.border` |
| `dividerColor` | Visual section separators | `tokens.neutralTone20` | `tokens.neutralTone40` |
| `textPrimary` | High-emphasis headers and titles | `tokens.neutralOnSurface` | `tokens.neutralOnSurface` |
| `textSecondary` | Subtitles, descriptions, captions | `tokens.neutralTone80` | `tokens.neutralTone80` |
| `warning` | Warnings & server capability limitations | `statusPalette.warning.base` | `statusPalette.warning.base` |
| `error` | Critical failures & snackbars | `statusPalette.destructive.base` | `statusPalette.destructive.base` |
| `success` | Confirmations & online indicators | `statusPalette.success.base` | `statusPalette.success.base` |

### Typography Hierarchy

Conduit typography maps onto an adaptive scale defined in `AppTypography`:

| Scale Item | Size (pt) | Weight | Line Height | Usage |
|---|---|---|---|---|
| `displayLargeStyle` | 34 / 57 | w700 / w400 | 1.21 | Prominent page banners |
| `headlineMediumStyle` | 20 / 28 | w600 / w400 | 1.25 | Section headers & modal titles |
| `headlineSmallStyle` | 17 / 24 | w600 / w400 | 1.29 | Sheet title & dialog headers |
| `titleLargeStyle` | 17 / 22 | w600 / w400 | 1.29 | Agent card titles |
| `bodyLargeStyle` | 16 / 17 | w400 | 1.31 | Chat messages & modal body |
| `bodyMediumStyle` | 14 / 16 | w400 | 1.43 | Card descriptions & search fields |
| `bodySmallStyle` | 13 | w400 | 1.38 | Agent prompt preview, secondary notes |
| `labelSmallStyle` / `caption` | 11 / 12 | w500 | 1.33 | Badges, tags, timestamps |
| `codeStyle` | 13 | w400 (Mono) | 1.38 | System prompts, model IDs, logs |

### Spacing Scale (8pt Grid)

| Spacing Token | Value | Component Application |
|---|---|---|
| `Spacing.xxs` | 2.0 dp | Badge internal vertical inset |
| `Spacing.xs` | 4.0 dp | Compact padding, icon-to-text spacing, micro gaps |
| `Spacing.sm` | 8.0 dp | Grid spacing, list separator gaps, avatar margins |
| `Spacing.md` | 16.0 dp | Screen horizontal padding, card content padding |
| `Spacing.lg` | 24.0 dp | Section headers, sheet top/bottom margins |
| `Spacing.xl` | 32.0 dp | Empty state spacing, modal margins |
| `Spacing.xxl` | 48.0 dp | Hero illustration spacing |

### Border Radii & Shapes

| Shape Token | Radius | Surface Applied |
|---|---|---|
| `AppBorderRadius.xs` | 4.0 dp | Micro tags & prompt preview chips |
| `AppBorderRadius.sm` | 8.0 dp | Snackbars, small button pills |
| `AppBorderRadius.md` | 12.0 dp | Input search bars, action cards |
| `AppBorderRadius.lg` | 16.0 dp | Agent list & grid cards |
| `AppBorderRadius.xl` | 24.0 dp | Modals, prominent bottom containers |
| `AppBorderRadius.bottomSheet` | 24.0 dp | Drag-sheet top rounded corners |
| `AppBorderRadius.pill` / `round` | 999.0 dp | Model badges, sheet grab handle, circular avatars |

### Elevation & Shadows

- `ConduitShadows.low(context)`: Offset (0, 2), Blur 8, Opacity 0.08 — cards at rest.
- `ConduitShadows.card(context)`: Offset (0, 3), Blur 12, Opacity 0.06 — agent tiles.
- `ConduitShadows.modal(context)`: Offset (0, 12), Blur 32, Opacity 0.20 — modal bottom sheets.

---

## 3. Component Primitives & Anatomy

### 3.1 Agent Card Primitive (List & Grid Variants)
- **Container**: Fills `theme.cardBackground`, bordered by `theme.dividerColor.withValues(alpha: 0.5)` with `AppBorderRadius.lg` (16dp).
- **Avatar**: 46dp (List) / 40dp (Grid) circular container supporting emoji glyph, remote HTTPS image with error-fallback badge, or deterministic colorful uppercase letter badge computed from agent title hash.
- **Model Badge**: `buildModelBadge` with `theme.buttonPrimary.withValues(alpha: 0.08)` background, 0.8dp outline, uppercase/monospace text.
- **Content Area**: Title (`textPrimary`, 15dp w700), 2-line truncated description (`textSecondary`, 12dp), and optional system prompt preview chip (`inputBackground`, italic).

### 3.2 Action Sheet Primitive (`_AgentActionsModalSheet`)
- **Presentation**: Drag-handle modal sheet with `AppBorderRadius.bottomSheet` (24dp) top radius.
- **Agent Header**: Enlarged 52dp avatar, full title, model badge, and bio.
- **Action Items**:
  1. `action-start-new-chat`: Starts server conversation topic bound to `chosenAgent`, selects true model separately.
  2. `action-view-system-prompt`: Inspects full system instructions in scrollable code view.
- **Capability Notice Banner**: Informative warning banner when active server lacks vision/file analysis support, alerting users cleanly without misleading model capabilities.

### 3.3 Status & Notice Banners
- **Offline / Constraint Banner**: Full-width container colored `theme.warning.withValues(alpha: 0.15)` with `theme.warning` icon (16dp) and semibold body text (12dp).
- **Snackbar Primitive**: Standard `ScaffoldMessenger` snackbar with clear human-readable error messages on action failures; preserves user location on failure.

---

## 4. Motion & Transitions

- **Duration Standard**:
  - Micro-interactions (toggles, taps): 150ms (`Curves.easeInOut`).
  - Sheet transitions & tab switches: 250ms (`Curves.easeInOutCubic`).
- **Reduced Motion Support**: `context.reduceMotion` detects accessibility features via `MediaQuery.maybeDisableAnimationsOf(context)` and `platformDispatcher.accessibilityFeatures`, falling back to `Duration.zero` to respect vestibular needs.
- **GPU Composited**: Animations operate exclusively on `opacity` and `transform`.

---

## 5. Layout & Spatial System

### 3-Module Navigation Shell
- **Structure**: Streamlined bottom navigation hierarchy consisting of 3 distinct tabs:
  1. `Chats (Index 0)`: Active conversation, message transcript, drawer/history.
  2. `Agents (Index 1)`: LobeHub assistant library, discovery, search, and action triggers.
  3. `Settings (Index 2)`: Server connection, sync state, and appearance preferences.
- **State Preservation**: Managed via `IndexedStack` / `KeyedSubtree` keeping page scroll offsets and state intact.
- **Responsive Constraints**:
  - Small screen guard (`screenWidth <= 340dp`): Compact bottom navigation icons (20dp) and text (10dp) preventing `RenderFlex` overflow.
  - Standard mobile (`360dp - 430dp`): Default 24dp icons, comfortable 16dp horizontal gutters.
  - Large / Tablet (`> 600dp`): Centered layout with constrained card aspect ratios.

---

## 6. State Architecture & Interactions

### Agent-to-Chat Flow Contract
1. **Trigger**: User selects agent card -> taps "Start New Chat (开启新对话)".
2. **Server Topic Creation**: Calls `LobeHubApiClient.createTopic(title: agentTitle, agentId: agent.id)`. The topic is directly bound to the chosen `agentId`.
3. **Model Selection**: The true underlying model is looked up in the model roster by **BOTH** `modelId` and `provider`. The agent is **NEVER** injected as a fake model or fallback. Missing configured models/providers are visible failures. Global selection changes only after verified online creation and activation succeed.
4. **Metadata Preservation**: Reloaded and persisted `Conversation` identity uses `backend: lobehub`, `agentId`, `agentTitle`, `agentModel`, and `provider`. Identity comes from the server topic and exact Agent details, not an optimistic summary or the globally selected model.
5. **Activation Seam**: Invokes `conversationSelectionProvider.notifier.select(summary)`.
6. **Authentication Preservation**: The existing account/server owner, auth-session epoch, and client transport identity are verified across every async boundary. Missing clients, detail errors, unverified/local topic IDs, and mismatched Agent IDs cannot succeed.
7. **Failure Isolation**: On error, an error SnackBar is displayed; navigation tab does **NOT** switch to 0. On success, navigation smoothly switches to Tab 0 (`Chats`).
8. **Bound Role Header**: Within the existing adaptive toolbar, the Agent title is primary and its configured model/provider is separate secondary read-only information. Full role/model/provider text and the v2.2.17 model-override limitation remain accessible via semantics/tooltip. Tapping the role opens the existing Agents tab (index 1), never the model roster. Non-LobeHub and Hermes titles remain unchanged.
9. **Queued Identity**: Headless dispatch uses the target conversation's verified Agent/model/provider configuration. Another chat's global model selection cannot supply or override that provider.

---

## 7. Accessibility & Cognitive Constraints

- **Contrast Floor**: All text-to-surface contrast ratios must achieve WCAG 2.1 AA (minimum 4.5:1 for body, 3:1 for large display titles) verified through `_contrastRatio`.
- **Touch Target Floor**: All interactive icon buttons and list tiles maintain a minimum 44x44dp hit test area.
- **CJK Precision**: Natural word breaking for Chinese, Japanese, and Korean copy (`TextOverflow.ellipsis`, safe wrap, no orphaned single-glyph lines).
- **Semantics & Keys**: Keyed widgets (`nav-tab-0`, `nav-tab-1`, `agent-card-$id`, `action-start-new-chat`) ensure robust screen reader accessibility and deterministic testing.

---

## 8. Accepted Debt & Non-Goals

- **Server 2.2.17 REST Limitation**: LobeHub server version 2.2.17 `/api/v1/chat` is string-only and `/api/v1/responses` strips images. File upload functions for storage, but multimodal image inference is unsupported by server REST. The capability provider disables vision/file inference and explains the server limitation directly without falsely reporting that the underlying model lacks vision.
- **Durable Agent SSE Correlation**: Complex SSE agent turn streaming correlation is handled by backend worker layers; the UI contract is strictly responsible for `topic.agentId` binding, provider/model separation, and conversation activation.
- **No Scope Expansion**: No redesign of existing Conduit theme engines, no custom dependency injection, and no replacement of existing navigation routing.
