import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'lobehub_connection_page.dart';

/// Entry point for the connection and sign-in flow.
/// Forwards directly to the dedicated LobeHub connection experience.
class ConnectAndSignInPage extends ConsumerWidget {
  const ConnectAndSignInPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return const LobeHubConnectionPage();
  }
}
