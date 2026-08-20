import 'package:flutter/services.dart' show FilteringTextInputFormatter;
import 'package:material_ui/material_ui.dart';
import '../models/plot_timing.dart';

/// How much time the plots show, sitting in the window rather than in a menu.
///
/// The same setting also lives under Options -> Plot, and both are worth
/// having for the same reason a PDF reader puts zoom in the View menu and on
/// the toolbar: the menu is where a setting is found, this is where it is
/// used. The dialog is also where the rest of [PlotTiming] will go, none of
/// which belongs in a dropdown.
///
/// The typed field is the first thing in the menu, above the quick choices,
/// because a duration that is not on the list is the only reason to open this
/// rather than to have clicked something already visible.
class PlotDurationSelector extends StatefulWidget {
  /// How much time the plots currently show.
  final Duration window;

  /// Called with a new window. Only ever called with a valid one - what is
  /// typed is checked here so no caller has to.
  final ValueChanged<Duration> onWindowChanged;

  const PlotDurationSelector({
    super.key,
    required this.window,
    required this.onWindowChanged,
  });

  @override
  State<PlotDurationSelector> createState() => _PlotDurationSelectorState();
}

class _PlotDurationSelectorState extends State<PlotDurationSelector> {
  final _controller = MenuController();
  late final TextEditingController _minutes = TextEditingController(
    text: formatPlotDurationInMinutes(widget.window),
  );
  final _minutesFocus = FocusNode(debugLabel: 'plot duration');

  /// Set while what has been typed is not a duration, so the field can say so
  /// without the menu closing on a value nobody could plot.
  var _rejected = false;

  /// The window actually in force.  Held rather than read off the widget
  /// because closing the menu has to restore the field, and when a quick
  /// choice closes it the parent has not rebuilt with the new window yet.
  late Duration _committed = widget.window;

  @override
  void didUpdateWidget(PlotDurationSelector oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The window can change from under this - the Options dialog sets it too -
    // and the field has to follow or the two would disagree.
    if (oldWidget.window != widget.window) {
      _committed = widget.window;
      if (!_minutesFocus.hasFocus) {
        _minutes.text = formatPlotDurationInMinutes(_committed);
      }
    }
  }

  @override
  void dispose() {
    _minutes.dispose();
    _minutesFocus.dispose();
    super.dispose();
  }

  void _choose(Duration window) {
    setState(() {
      _rejected = false;
      _committed = window;
    });
    _minutes.text = formatPlotDurationInMinutes(window);
    _controller.close();
    widget.onWindowChanged(window);
  }

  void _submitTyped() {
    final window = parsePlotDurationInMinutes(_minutes.text);
    if (window == null) {
      setState(() => _rejected = true);
      return;
    }
    _choose(window);
  }

  @override
  Widget build(BuildContext context) {
    return MenuAnchor(
      controller: _controller,
      // Whatever was typed and not applied goes back to what is actually set
      // when the menu is dismissed.  A number left sitting in the field reads
      // as the duration in force, whether it was rejected, half finished, or
      // simply abandoned.
      onClose: () {
        setState(() {
          _rejected = false;
          _minutes.text = formatPlotDurationInMinutes(_committed);
        });
      },
      menuChildren: [
        _buildTypedEntry(),
        const Divider(height: 8),
        for (final minutes in quickPlotDurationsInMinutes)
          MenuItemButton(
            onPressed: () => _choose(Duration(minutes: minutes)),
            // A tick beside the one in force, so the button's label and the
            // list cannot appear to disagree.
            leadingIcon: Icon(
              Duration(minutes: minutes) == widget.window ? Icons.check : null,
              size: 16,
            ),
            child: Text('$minutes min'),
          ),
      ],
      builder: (context, controller, child) {
        return Tooltip(
          message: 'How much time each plot shows.',
          child: TextButton.icon(
            onPressed: () =>
                controller.isOpen ? controller.close() : controller.open(),
            icon: const Icon(Icons.arrow_drop_down),
            iconAlignment: IconAlignment.end,
            label: Text('${formatPlotDurationInMinutes(widget.window)} min'),
          ),
        );
      },
    );
  }

  /// The typed line at the top of the menu.
  Widget _buildTypedEntry() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: SizedBox(
        width: 180,
        child: TextField(
          controller: _minutes,
          focusNode: _minutesFocus,
          autofocus: true,
          onSubmitted: (_) => _submitTyped(),
          onChanged: (_) {
            if (_rejected) {
              setState(() => _rejected = false);
            }
          },
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          inputFormatters: [
            FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
          ],
          decoration: InputDecoration(
            labelText: 'Minutes',
            border: const OutlineInputBorder(),
            isDense: true,
            errorText: _rejected
                ? 'Up to $maximumPlotDurationInMinutes'
                : null,
            suffixIcon: IconButton(
              icon: const Icon(Icons.check, size: 18),
              tooltip: 'Use this duration',
              onPressed: _submitTyped,
            ),
          ),
        ),
      ),
    );
  }
}
