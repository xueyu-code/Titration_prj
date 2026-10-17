import 'package:flutter/material.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';

import '../data/device_link.dart';
import '../l10n/app_localizations.dart';
import '../state/device_controller.dart';
import '../state/scan_controller.dart';
import 'history_page.dart';
import 'home_page.dart';
import 'widgets/language_button.dart';
import 'widgets/snack.dart';

class ScanPage extends ConsumerStatefulWidget {
  const ScanPage({super.key});

  @override
  ConsumerState<ScanPage> createState() => _ScanPageState();
}

class _ScanPageState extends ConsumerState<ScanPage> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ref.read(scanProvider.notifier).start();
    });
  }

  Future<void> _connect(DiscoveredDevice device) async {
    ref.read(scanProvider.notifier).stop();
    final l10n = AppLocalizations.of(context);
    final navigator = Navigator.of(context);
    final name = device.name.isEmpty ? l10n.unknownDevice : device.name;

    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => PopScope(
        canPop: false,
        child: AlertDialog(
          content: Row(
            children: [
              const CircularProgressIndicator(),
              const SizedBox(width: 24),
              Text(l10n.connecting),
            ],
          ),
        ),
      ),
    );

    try {
      await ref.read(deviceProvider.notifier).connect(device.id, name);
    } on LinkException catch (e) {
      navigator.pop(); // progress dialog
      if (mounted) showLinkError(context, e);
      return;
    }
    navigator.pop(); // progress dialog
    await navigator.push(
      MaterialPageRoute<void>(builder: (_) => const HomePage()),
    );
    if (mounted) ref.read(scanProvider.notifier).start();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scan = ref.watch(scanProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.appTitle),
        actions: [
          IconButton(
            icon: const Icon(Icons.history),
            tooltip: l10n.history,
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const HistoryPage()),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: l10n.rescan,
            onPressed: () => ref.read(scanProvider.notifier).start(),
          ),
          const LanguageButton(),
        ],
      ),
      body: Column(
        children: [
          SizedBox(
            height: 4,
            child: scan.scanning ? const LinearProgressIndicator() : null,
          ),
          Expanded(
            child: switch (scan.bleStatus) {
              BleStatus.ready => _DeviceList(scan: scan, onTap: _connect),
              BleStatus.unknown => const Center(
                child: CircularProgressIndicator(),
              ),
              BleStatus.poweredOff => _StatusMessage(
                icon: Icons.bluetooth_disabled,
                message: l10n.bluetoothOff,
              ),
              BleStatus.unauthorized => _StatusMessage(
                icon: Icons.lock_outline,
                message: l10n.bluetoothUnauthorized,
                actionLabel: l10n.openSettings,
                onAction: openAppSettings,
              ),
              BleStatus.locationServicesDisabled => _StatusMessage(
                icon: Icons.location_off,
                message: l10n.locationOff,
              ),
              BleStatus.unsupported => _StatusMessage(
                icon: Icons.bluetooth_disabled,
                message: l10n.bluetoothUnsupported,
              ),
            },
          ),
        ],
      ),
    );
  }
}

class _DeviceList extends StatelessWidget {
  const _DeviceList({required this.scan, required this.onTap});

  final ScanState scan;
  final void Function(DiscoveredDevice) onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final primary = Theme.of(context).colorScheme.primary;

    if (scan.devices.isEmpty) {
      return scan.scanning
          ? const SizedBox.shrink()
          : Center(child: Text(l10n.noDevices));
    }
    return ListView.builder(
      itemCount: scan.devices.length,
      itemBuilder: (context, i) {
        final device = scan.devices[i];
        final titrator = ScanController.isTitrator(device);
        return ListTile(
          leading: Icon(
            titrator ? Icons.science : Icons.bluetooth,
            color: titrator ? primary : null,
          ),
          title: Text(device.name.isEmpty ? l10n.unknownDevice : device.name),
          subtitle: Text(device.id),
          trailing: Text(l10n.rssiDbm(device.rssi)),
          onTap: () => onTap(device),
        );
      },
    );
  }
}

/// Centered explanation for a Bluetooth state that blocks scanning.
class _StatusMessage extends StatelessWidget {
  const _StatusMessage({
    required this.icon,
    required this.message,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: theme.colorScheme.outline),
            const SizedBox(height: 16),
            Text(
              message,
              textAlign: TextAlign.center,
              style: theme.textTheme.titleMedium,
            ),
            if (onAction != null) ...[
              const SizedBox(height: 16),
              FilledButton(onPressed: onAction, child: Text(actionLabel!)),
            ],
          ],
        ),
      ),
    );
  }
}
