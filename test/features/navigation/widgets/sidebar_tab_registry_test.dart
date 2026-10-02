import 'package:checks/checks.dart';
import 'package:conduit/features/navigation/models/sidebar_navigation_model.dart';
import 'package:conduit/features/navigation/widgets/sidebar_tab_registry.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('sidebar_tab_registry pruning', () {
    test('sidebarTabRegistry contains only SidebarTabId.chats', () {
      check(sidebarTabRegistry.length).equals(1);
      check(sidebarTabRegistry.first.id).equals(SidebarTabId.chats);
    });

    test(
      'visibleSidebarTabIds contains only chats regardless of availability flags',
      () {
        const availabilityBothEnabled = SidebarTabAvailability(
          hermesOnly: false,
          hasOpenWebUi: true,
          hermesEnabled: true,
          notesEnabled: true,
          terminalEnabled: true,
          channelsEnabled: true,
        );
        check(visibleSidebarTabIds(availabilityBothEnabled)).deepEquals([
          SidebarTabId.chats,
        ]);

        const availabilityAllDisabled = SidebarTabAvailability(
          hermesOnly: true,
          hasOpenWebUi: false,
          hermesEnabled: false,
          notesEnabled: false,
          terminalEnabled: false,
          channelsEnabled: false,
        );
        check(visibleSidebarTabIds(availabilityAllDisabled)).deepEquals([
          SidebarTabId.chats,
        ]);
      },
    );

    test('sidebarTabDescriptor safely falls back to chats for legacy tabs', () {
      check(sidebarTabDescriptor(SidebarTabId.chats).id).equals(
        SidebarTabId.chats,
      );
      check(sidebarTabDescriptor(SidebarTabId.hermes).id).equals(
        SidebarTabId.chats,
      );
      check(sidebarTabDescriptor(SidebarTabId.notes).id).equals(
        SidebarTabId.chats,
      );
      check(sidebarTabDescriptor(SidebarTabId.terminal).id).equals(
        SidebarTabId.chats,
      );
      check(sidebarTabDescriptor(SidebarTabId.channels).id).equals(
        SidebarTabId.chats,
      );
    });

    test('retains legacy icon constants for backward compatibility', () {
      check(kHermesTabIconSize).equals(17.0);
      check(kHermesNativeTabIconSize).equals(26.0);
      check(kHermesTabIcon.assetName).equals('assets/icons/hermes_agent.png');
    });
  });
}
