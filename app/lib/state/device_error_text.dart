import '../core/protocol.dart';
import '../l10n/app_localizations.dart';

/// User-facing text of a device error, for snack bars and notifications.
String deviceErrorText(AppLocalizations l10n, DeviceError error) =>
    switch ((error.code, error.channel, error.direction)) {
      ('busy', _, _) => l10n.errorBusy,
      ('limit', final channel?, Direction.aspirate) => l10n.errorSyringeFull(
        channel.id,
      ),
      ('limit', final channel?, Direction.dispense) => l10n.errorSyringeEmpty(
        channel.id,
      ),
      ('limit', _, _) => l10n.errorLimit,
      ('unhomed', final channel?, _) => l10n.errorUnhomed(channel.id),
      ('sensor', _, _) => l10n.errorSensor,
      ('no_converge', _, _) => l10n.errorNoConverge,
      ('bad_cmd', _, _) => l10n.errorBadCmd,
      _ => l10n.errorGeneric(error.code, error.message ?? '').trim(),
    };
