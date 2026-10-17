import 'package:flutter/material.dart';

import '../../data/device_link.dart';
import '../../l10n/app_localizations.dart';

void showSnack(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
}

void showLinkError(BuildContext context, LinkException error) {
  final l10n = AppLocalizations.of(context);
  showSnack(context, switch (error.reason) {
    LinkFailure.timeout => l10n.linkTimeout,
    LinkFailure.notTitrator => l10n.linkNotTitrator,
    LinkFailure.failed => l10n.linkFailed,
  });
}
