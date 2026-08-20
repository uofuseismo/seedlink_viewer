import 'package:flutter/services.dart' show FilteringTextInputFormatter;
import 'package:material_ui/material_ui.dart';
import '../models/plot_timing.dart';

/// Asks the user how the plots should be drawn.
///
/// Returns the new timings, or null if the user cancelled.
Future<PlotTiming?> showPlotOptions(
  BuildContext context, {
  required PlotTiming timing,
}) {
  return showDialog<PlotTiming>(
    context: context,
    builder: (context) => PlotOptionsDialog(timing: timing),
  );
}

/// Settings for how the plots are drawn.
///
/// Only the window is configurable so far. The dialog is named for the whole
/// group rather than for the one setting because the rest of [PlotTiming] is
/// the obvious next thing to put here, and a "Plot duration" menu item would
/// have to be renamed to make room.
class PlotOptionsDialog extends StatefulWidget {
  final PlotTiming timing;

  const PlotOptionsDialog({super.key, required this.timing});

  @override
  State<PlotOptionsDialog> createState() => _PlotOptionsDialogState();
}

class _PlotOptionsDialogState extends State<PlotOptionsDialog> {
  /// The window as typed, in minutes. The text is the truth here rather than a
  /// parsed Duration: a half finished number is not a duration, and blanking
  /// the field to retype it must not be read as a request for a zero length
  /// plot.
  late final TextEditingController _minutes;
  String? _error;

  @override
  void initState() {
    super.initState();
    _minutes = TextEditingController(
      text: formatPlotDurationInMinutes(widget.timing.window),
    );
  }

  @override
  void dispose() {
    _minutes.dispose();
    super.dispose();
  }

  /// The typed window, or null if what is in the field is not one.
  Duration? get _typedWindow => parsePlotDurationInMinutes(_minutes.text);

  /// The quick choice the field currently agrees with, if any. Typing 5 lights
  /// the 5 min button, so the two halves of the dialog never disagree about
  /// what is set.
  int? get _matchingQuickChoice {
    final window = _typedWindow;
    if (window == null) {
      return null;
    }
    for (final minutes in quickPlotDurationsInMinutes) {
      if (Duration(minutes: minutes) == window) {
        return minutes;
      }
    }
    return null;
  }

  void _choose(int minutes) {
    setState(() {
      _minutes.text = minutes.toString();
      _error = null;
    });
  }

  void _onTyped(String _) {
    setState(() => _error = null);
  }

  void _submit() {
    final window = _typedWindow;
    if (window == null) {
      setState(() {
        _error =
            'Enter a duration between 0 and $maximumPlotDurationInMinutes '
            'minutes';
      });
      return;
    }
    // withWindow rather than a fresh PlotTiming: a history that was set
    // deliberately has to survive a change of window, and the redraw interval
    // and clock slack are none of this dialog's business.
    Navigator.of(context).pop(widget.timing.withWindow(window));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Plot Options'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'How much time each plot shows.',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 16),
            _buildQuickChoices(),
            const SizedBox(height: 16),
            _buildMinutesField(),
          ],
        ),
      ),
      actions: _buildActions(context),
    );
  }

  Widget _buildQuickChoices() {
    final chosen = _matchingQuickChoice;
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final minutes in quickPlotDurationsInMinutes)
          Tooltip(
            message: 'Show the last $minutes '
                '${minutes == 1 ? 'minute' : 'minutes'}',
            child: ChoiceChip(
              label: Text('$minutes min'),
              selected: minutes == chosen,
              // Re-picking the chip that is already lit is a no-op rather than
              // a way to turn it off: there is no such thing as no window.
              onSelected: (_) => _choose(minutes),
            ),
          ),
      ],
    );
  }

  Widget _buildMinutesField() {
    return Tooltip(
      message: 'Any duration up to $maximumPlotDurationInMinutes minutes. '
          'Fractions are allowed, so 0.5 is thirty seconds.',
      child: TextField(
        controller: _minutes,
        onChanged: _onTyped,
        onSubmitted: (_) => _submit(),
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
        decoration: InputDecoration(
          labelText: 'Plot duration (minutes)',
          border: const OutlineInputBorder(),
          isDense: true,
          errorText: _error,
        ),
      ),
    );
  }

  List<Widget> _buildActions(BuildContext context) {
    return [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Cancel'),
      ),
      Tooltip(
        message: 'Apply these settings to the plots.',
        child: FilledButton(onPressed: _submit, child: const Text('Apply')),
      ),
    ];
  }
}
