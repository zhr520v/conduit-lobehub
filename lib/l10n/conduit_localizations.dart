import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:material_ui/material_ui.dart' as mui;

import 'app_localizations.dart';

/// Localization delegates for Conduit's standalone Material and Cupertino UI.
const List<LocalizationsDelegate<dynamic>> conduitLocalizationsDelegates =
    <LocalizationsDelegate<dynamic>>[
      AppLocalizations.delegate,
      ...GlobalMaterialLocalizations.delegates,
      ...mui.GlobalMaterialLocalizations.delegates,
    ];
