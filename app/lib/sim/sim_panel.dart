import 'dart:async';

import 'package:flutter/material.dart';

import '../core/calibration.dart';
import '../core/protocol.dart';
import '../ui/format.dart';
import 'sim_link.dart';
import 'sim_titrator.dart';

/// Dev overlay with fault injection and a live readout of the simulator.
///
/// It sits above the Navigator (via `TitratorApp.builder`), so it cannot use
/// popups, dialogs or sheets: the panel is plain widgets in a [Stack].
class SimPanel extends StatefulWidget {
  const SimPanel({
    super.key,
    required this.sim,
    required this.link,
    required this.child,
  });

  final SimTitrator sim;
  final SimDeviceLink link;
  final Widget child;

  @override
  State<SimPanel> createState() => _SimPanelState();
}

class _SimPanelState extends State<SimPanel> {
  bool _open = false;
  late final Timer _refresh;

  /// Every standard buffer pH, ascending.
  static final _buffers = ({
    for (final set in calibrationBufferSets) ...set,
  }.toList()..sort());

  SimTitrator get _sim => widget.sim;

  @override
  void initState() {
    super.initState();
    _refresh = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (_open) setState(() {});
    });
  }

  @override
  void dispose() {
    _refresh.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final inset = MediaQuery.paddingOf(context);

    return Stack(
      fit: StackFit.expand,
      children: [
        widget.child,
        Positioned(
          left: 8 + inset.left,
          bottom: 8 + inset.bottom,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_open) _card(context),
              const SizedBox(height: 4),
              Material(
                color: scheme.tertiaryContainer,
                shape: const StadiumBorder(),
                child: InkWell(
                  customBorder: const StadiumBorder(),
                  onTap: () => setState(() => _open = !_open),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 6,
                    ),
                    child: Text(
                      'SIM',
                      style: TextStyle(
                        color: scheme.onTertiaryContainer,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _card(BuildContext context) {
    final textStyle = Theme.of(context).textTheme.bodySmall;
    String syringe(Channel c) =>
        '针筒${c.id} ${_sim.syringeMl(c).toStringAsFixed(2)} mL'
        '${_sim.isHomed(c) ? '' : '（未归位）'}';

    return Material(
      elevation: 6,
      borderRadius: BorderRadius.circular(12),
      color: Theme.of(context).colorScheme.surfaceContainerHigh,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 280),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '${_sim.buffered ? '有缓冲' : '无缓冲'}样品 '
                'pH ${_sim.samplePh.toStringAsFixed(2)}  '
                '${_sim.mode.name}\n'
                '${syringe(Channel.ch1)}\n'
                '${syringe(Channel.ch2)}\n'
                '电极 ${_sim.electrodeMv.toStringAsFixed(1)} mV',
                style: textStyle,
              ),
              const SizedBox(height: 8),
              Text('电极位置', style: textStyle),
              Wrap(
                spacing: 8,
                children: [
                  for (final ph in [null, ..._buffers])
                    ChoiceChip(
                      label: Text(ph == null ? '样品' : formatPh(ph)),
                      selected: _sim.bufferPh == ph,
                      onSelected: (_) => setState(() => _sim.bufferPh = ph),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: [
                  ActionChip(
                    label: const Text('掉线'),
                    onPressed: widget.link.dropLink,
                  ),
                  FilterChip(
                    label: const Text('电极异常'),
                    selected: _sim.electrodeFault,
                    onSelected: (on) =>
                        setState(() => _sim.electrodeFault = on),
                  ),
                  ActionChip(
                    label: const Text('新样品（有缓冲）'),
                    onPressed: _sim.newSample,
                  ),
                  ActionChip(
                    label: const Text('新样品（无缓冲）'),
                    onPressed: () => _sim.newSample(buffered: false),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
