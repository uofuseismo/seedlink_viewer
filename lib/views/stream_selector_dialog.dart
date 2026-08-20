import 'dart:math' show min;
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:material_ui/material_ui.dart';
import '../models/stream_identifier.dart';
import '../services/stream_source.dart';

/// Requests that the highlighted available stream be selected.
class AddStreamIntent extends Intent {
  const AddStreamIntent();
}

/// Requests that the highlighted selected stream be dropped.
class RemoveStreamIntent extends Intent {
  const RemoveStreamIntent();
}

/// Walks the highlight up or down whichever list currently owns it.
class MoveHighlightIntent extends Intent {
  /// -1 for the row above, 1 for the row below.
  final int delta;
  const MoveHighlightIntent(this.delta);
}

/// Asks the user which streams to plot.
///
/// Returns the chosen streams in plot order, or null if the user cancelled.
Future<List<StreamIdentifier>?> showStreamSelector(
  BuildContext context, {
  required StreamSource source,
  List<StreamIdentifier> initialSelection = const <StreamIdentifier>[],
}) {
  return showDialog<List<StreamIdentifier>>(
    context: context,
    builder: (context) =>
        StreamSelectorDialog(source: source, initialSelection: initialSelection),
  );
}

/// A two-list picker: everything the server offers on the left, the streams to
/// plot on the right, in the order they will be drawn.
class StreamSelectorDialog extends StatefulWidget {
  final StreamSource source;
  final List<StreamIdentifier> initialSelection;

  const StreamSelectorDialog({
    super.key,
    required this.source,
    this.initialSelection = const <StreamIdentifier>[],
  });

  @override
  State<StreamSelectorDialog> createState() => _StreamSelectorDialogState();
}

class _StreamSelectorDialogState extends State<StreamSelectorDialog> {
  late final Future<List<StreamIdentifier>> _query;

  /// Everything the server offered.
  final _offered = <StreamIdentifier>[];

  /// The streams to plot, in the order they will be drawn.
  final _selected = <StreamIdentifier>[];

  /// At most one of these is ever set.  Highlighting a row on one side clears
  /// the other so it is always obvious which stream Add/Remove will act on.
  StreamIdentifier? _offeredHighlight;
  StreamIdentifier? _selectedHighlight;

  /// Rows are a fixed height so the arrow keys can scroll the highlight into
  /// view without measuring anything.
  static const double _rowHeight = 44;

  /// Tooltips default to appearing the instant the mouse lands, which nags on
  /// buttons whose job is already obvious.  Make the mouse settle first.
  final _offeredScroll = ScrollController();
  final _selectedScroll = ScrollController();

  final _filterController = TextEditingController();
  final _filterFocus = FocusNode(debugLabel: 'stream filter');

  /// Owns the Add/Remove and arrow key shortcuts.  Held rather than left
  /// implicit so that clicking a row can take the focus back off the filter
  /// field, which swallows a bare a or r to stay typeable.
  final _pickerFocus = FocusNode(debugLabel: 'stream picker');
  RegExp? _filter;
  String? _filterError;

  @override
  void initState() {
    super.initState();
    _selected.addAll(widget.initialSelection);
    _query = _load();
  }

  /// Caches what the server offered so the two lists can be derived from it.
  /// The FutureBuilder watching this rebuilds once it completes, so there is
  /// no need to setState here - and no second listener to leave an error
  /// unhandled if the query fails.
  Future<List<StreamIdentifier>> _load() async {
    final streams = await widget.source.fetchStreams();
    _offered
      ..clear()
      ..addAll(streams);
    return streams;
  }

  @override
  void dispose() {
    _filterController.dispose();
    _filterFocus.dispose();
    _pickerFocus.dispose();
    _offeredScroll.dispose();
    _selectedScroll.dispose();
    super.dispose();
  }

  /// The streams on offer that have not been taken yet and survive the filter.
  /// Taking a stream hides it here rather than deleting it, so removing it puts
  /// it straight back.
  List<StreamIdentifier> get _visible {
    final taken = _selected.toSet();
    return _offered
        .where((stream) => !taken.contains(stream))
        .where((stream) => _filter?.hasMatch(stream.toString()) ?? true)
        .toList()
      ..sort((a, b) => a.toString().compareTo(b.toString()));
  }

  void _onFilterChanged(String text) {
    setState(() {
      if (text.isEmpty) {
        _filter = null;
        _filterError = null;
        return;
      }
      try {
        _filter = RegExp(text, caseSensitive: false);
        _filterError = null;
      } on FormatException {
        // Leave the previous list showing rather than blanking it while the
        // user is midway through typing something like "UU.(BGU".
        _filter = null;
        _filterError = 'Not a valid regular expression';
      }
    });
  }

  /// Clicking a row picks it and hands the keyboard back to the lists.
  ///
  /// Typing in the filter leaves the focus there, and the filter deliberately
  /// swallows a bare a or r so that names like ARUT stay typeable.  Without
  /// this, clicking back onto a list left the highlight in one place and the
  /// keyboard in another: Add and Remove appeared to have stopped working.
  void _pick(void Function(StreamIdentifier) highlight, StreamIdentifier s) {
    _pickerFocus.requestFocus();
    highlight(s);
  }

  /// Highlights a row on the left, releasing whatever the right had.
  void _highlightOffered(StreamIdentifier? stream) {
    setState(() {
      _offeredHighlight = stream;
      _selectedHighlight = null;
    });
  }

  /// Highlights a row on the right, releasing whatever the left had.
  void _highlightSelected(StreamIdentifier? stream) {
    setState(() {
      _selectedHighlight = stream;
      _offeredHighlight = null;
    });
  }

  /// Walks the highlight through whichever list owns it.  With nothing
  /// highlighted yet this steps into the available list, so a user can type a
  /// filter and arrow straight down into the results.
  void _moveHighlight(int delta) {
    if (_selectedHighlight != null) {
      final index = _selected.indexOf(_selectedHighlight!);
      final next = (index + delta).clamp(0, _selected.length - 1);
      _highlightSelected(_selected[next]);
      _scrollIntoView(_selectedScroll, next);
      return;
    }
    final visible = _visible;
    if (visible.isEmpty) {
      return;
    }
    final index = _offeredHighlight == null
        ? (delta > 0 ? -1 : visible.length)
        : visible.indexOf(_offeredHighlight!);
    final next = (index + delta).clamp(0, visible.length - 1);
    _highlightOffered(visible[next]);
    _scrollIntoView(_offeredScroll, next);
  }

  /// Nudges a list just far enough to bring a row into view.
  void _scrollIntoView(ScrollController controller, int index) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!controller.hasClients) {
        return;
      }
      final position = controller.position;
      final top = index * _rowHeight;
      final bottom = top + _rowHeight;
      if (top < position.pixels) {
        controller.jumpTo(top.clamp(0.0, position.maxScrollExtent));
      } else if (bottom > position.pixels + position.viewportDimension) {
        controller.jumpTo(
          (bottom - position.viewportDimension).clamp(
            0.0,
            position.maxScrollExtent,
          ),
        );
      }
    });
  }

  void _add() {
    final chosen = _offeredHighlight;
    if (chosen == null || _selected.contains(chosen)) {
      return;
    }
    final wasAt = _visible.indexOf(chosen);
    setState(() {
      _selected.add(chosen);
      // Keep the highlight where the eye already is - on whatever slid up into
      // the vacated row - so a run of streams can be added without re-aiming.
      final remaining = _visible;
      _offeredHighlight = remaining.isEmpty
          ? null
          : remaining[min(wasAt, remaining.length - 1)];
    });
  }

  void _remove() {
    final chosen = _selectedHighlight;
    if (chosen == null) {
      return;
    }
    final wasAt = _selected.indexOf(chosen);
    setState(() {
      _selected.remove(chosen);
      _selectedHighlight = _selected.isEmpty
          ? null
          : _selected[min(wasAt, _selected.length - 1)];
    });
  }

  /// Clears the whole plot list.  Deliberately awkward: no accelerator, and a
  /// confirmation, because it throws away work that took a while to assemble.
  Future<void> _removeAll() async {
    final count = _selected.length;
    if (count == 0) {
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove all streams?'),
        content: Text(
          'This clears all $count streams from the plot list. '
          'The available list is unaffected.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Remove all'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      setState(() {
        _selected.clear();
        _selectedHighlight = null;
      });
    }
  }

  /// Moves a stream to a new position in the plot order.  onReorderItem has
  /// already accounted for the dragged row being lifted out of the list.
  void _reorder(int oldIndex, int newIndex) {
    setState(() {
      _selected.insert(newIndex, _selected.removeAt(oldIndex));
    });
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 820, maxHeight: 560),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Stream Selector',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 12),
              Expanded(
                child: FutureBuilder<List<StreamIdentifier>>(
                  future: _query,
                  builder: (context, snapshot) {
                    if (snapshot.connectionState != ConnectionState.done) {
                      return _buildQuerying();
                    }
                    if (snapshot.hasError) {
                      return _buildFailed(snapshot.error!);
                    }
                    return _buildPicker(context);
                  },
                ),
              ),
              const SizedBox(height: 12),
              _buildActions(context),
            ],
          ),
        ),
      ),
    );
  }

  /// Shown while the server is being asked what it has.
  Widget _buildQuerying() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(),
          const SizedBox(height: 20),
          Text('Querying streams from ${widget.source.description}...'),
        ],
      ),
    );
  }

  Widget _buildFailed(Object error) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.error_outline, size: 40),
          const SizedBox(height: 20),
          Text('Could not query ${widget.source.description}'),
          const SizedBox(height: 8),
          Text('$error', style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
  }

  Widget _buildPicker(BuildContext context) {
    // Alt+A and Alt+R always work.  Bare a and r work too, but the filter field
    // below swallows them so that typing a stream name stays possible.  The
    // arrow keys drive the highlight rather than focus traversal, which is what
    // put a second, competing selection on screen.
    return Shortcuts(
      shortcuts: <ShortcutActivator, Intent>{
        const SingleActivator(LogicalKeyboardKey.keyA): const AddStreamIntent(),
        const SingleActivator(LogicalKeyboardKey.keyA, alt: true):
            const AddStreamIntent(),
        const SingleActivator(LogicalKeyboardKey.keyR):
            const RemoveStreamIntent(),
        const SingleActivator(LogicalKeyboardKey.keyR, alt: true):
            const RemoveStreamIntent(),
        const SingleActivator(LogicalKeyboardKey.arrowUp):
            const MoveHighlightIntent(-1),
        const SingleActivator(LogicalKeyboardKey.arrowDown):
            const MoveHighlightIntent(1),
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          AddStreamIntent: CallbackAction<AddStreamIntent>(
            onInvoke: (_) {
              _add();
              return null;
            },
          ),
          RemoveStreamIntent: CallbackAction<RemoveStreamIntent>(
            onInvoke: (_) {
              _remove();
              return null;
            },
          ),
          MoveHighlightIntent: CallbackAction<MoveHighlightIntent>(
            onInvoke: (intent) {
              _moveHighlight(intent.delta);
              return null;
            },
          ),
        },
        child: Focus(
          focusNode: _pickerFocus,
          autofocus: true,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: _buildOffered(context)),
              _buildButtons(context),
              Expanded(child: _buildSelected(context)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildOffered(BuildContext context) {
    final visible = _visible;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildHeading('Available (${visible.length})'),
        Expanded(
          child: _buildListBox(
            child: ListView.builder(
              controller: _offeredScroll,
              itemExtent: _rowHeight,
              itemCount: visible.length,
              itemBuilder: (context, index) {
                final stream = visible[index];
                return _buildRow(
                  stream: stream,
                  isHighlighted: stream == _offeredHighlight,
                  onTap: () => _pick(_highlightOffered, stream),
                );
              },
            ),
          ),
        ),
        const SizedBox(height: 8),
        // A bare a or r here has to reach the text field rather than firing the
        // Add/Remove shortcuts above, otherwise names like ARUT are untypable.
        Shortcuts(
          shortcuts: <ShortcutActivator, Intent>{
            const SingleActivator(LogicalKeyboardKey.keyA):
                const DoNothingAndStopPropagationIntent(),
            const SingleActivator(LogicalKeyboardKey.keyR):
                const DoNothingAndStopPropagationIntent(),
          },
          child: TextField(
            controller: _filterController,
            focusNode: _filterFocus,
            onChanged: _onFilterChanged,
            decoration: InputDecoration(
              isDense: true,
              border: const OutlineInputBorder(),
              labelText: 'Filter (regular expression)',
              hintText: 'e.g. ypk  or  UU.*HHZ',
              errorText: _filterError,
              suffixIcon: _filterController.text.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.clear),
                      tooltip: 'Clear filter',
                      onPressed: () {
                        _filterController.clear();
                        _onFilterChanged('');
                      },
                    ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildSelected(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildHeading('Selected (${_selected.length}) - plot order'),
        Expanded(
          child: _buildListBox(
            child: ReorderableListView.builder(
              scrollController: _selectedScroll,
              itemExtent: _rowHeight,
              itemCount: _selected.length,
              onReorderItem: _reorder,
              itemBuilder: (context, index) {
                final stream = _selected[index];
                return _buildRow(
                  key: ValueKey<String>(stream.toString()),
                  stream: stream,
                  isHighlighted: stream == _selectedHighlight,
                  onTap: () => _pick(_highlightSelected, stream),
                  leading: Text(
                    '${index + 1}.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                );
              },
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'Drag to set the order streams are plotted in.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }

  Widget _buildButtons(BuildContext context) {
    final toAdd = _offeredHighlight;
    final toRemove = _selectedHighlight;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Tooltip(
            message: toAdd == null
                ? 'Pick a stream on the left to add it to the plot list'
                : 'Add $toAdd to the plot list',
            child: ElevatedButton(
              onPressed: toAdd == null ? null : _add,
              child: const _MnemonicLabel(label: 'Add', mnemonicIndex: 0),
            ),
          ),
          const SizedBox(height: 12),
          Tooltip(
            message: toRemove == null
                ? 'Pick a stream on the right to remove it from the plot list'
                : 'Remove $toRemove from the plot list',
            child: ElevatedButton(
              onPressed: toRemove == null ? null : _remove,
              child: const _MnemonicLabel(label: 'Remove', mnemonicIndex: 0),
            ),
          ),
          const SizedBox(height: 32),
          Tooltip(
            message: _selected.isEmpty
                ? 'The plot list is already empty'
                : 'Clear all ${_selected.length} streams from the plot list',
            child: OutlinedButton(
              onPressed: _selected.isEmpty ? null : _removeAll,
              style: OutlinedButton.styleFrom(
                foregroundColor: Theme.of(context).colorScheme.error,
              ),
              child: const Text('Remove all'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActions(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        const SizedBox(width: 8),
        FilledButton(
          onPressed: () =>
              Navigator.of(context).pop(List<StreamIdentifier>.of(_selected)),
          child: const Text('OK'),
        ),
      ],
    );
  }

  Widget _buildHeading(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text(text, style: Theme.of(context).textTheme.labelLarge),
    );
  }

  Widget _buildListBox({required Widget child}) {
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).dividerColor),
      ),
      child: child,
    );
  }

  Widget _buildRow({
    required StreamIdentifier stream,
    required bool isHighlighted,
    required VoidCallback onTap,
    Key? key,
    Widget? leading,
  }) {
    // Deliberately no long press handler here: ReorderableListView uses long
    // press to start a drag on touch platforms and would fight with it.
    return ListTile(
      key: key,
      dense: true,
      selected: isHighlighted,
      selectedTileColor: Theme.of(context).colorScheme.primaryContainer,
      // Keep the hover tint, which usefully tracks the mouse, but drop the
      // focus tint - it read as a second selection competing with the real one.
      focusColor: Colors.transparent,
      leading: leading,
      title: Text(stream.toString()),
      onTap: onTap,
    );
  }
}

/// A button label with one letter underlined to advertise its shortcut.
class _MnemonicLabel extends StatelessWidget {
  final String label;
  final int mnemonicIndex;

  const _MnemonicLabel({required this.label, required this.mnemonicIndex});

  @override
  Widget build(BuildContext context) {
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(text: label.substring(0, mnemonicIndex)),
          TextSpan(
            text: label.substring(mnemonicIndex, mnemonicIndex + 1),
            style: const TextStyle(decoration: TextDecoration.underline),
          ),
          TextSpan(text: label.substring(mnemonicIndex + 1)),
        ],
      ),
    );
  }
}
