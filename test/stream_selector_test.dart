import 'package:flutter/gestures.dart' show PointerDeviceKind, kLongPressTimeout;
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:seedlink_viewer/main.dart' show buildAppTheme, tooltipDelay;
import 'package:material_ui/material_ui.dart';
import 'package:seedlink_viewer/models/stream_identifier.dart';
import 'package:seedlink_viewer/services/stream_source.dart';
import 'package:seedlink_viewer/views/stream_selector_dialog.dart';

/// A source with a known answer so the tests do not depend on a server or on
/// the sample asset.
class FakeStreamSource implements StreamSource {
  final List<String> names;
  final Duration delay;
  final Object? failure;

  FakeStreamSource(
    this.names, {
    this.delay = Duration.zero,
    this.failure,
  });

  @override
  String get description => 'test-server:18000';

  @override
  Future<List<StreamIdentifier>> fetchStreams() async {
    if (delay > Duration.zero) {
      await Future<void>.delayed(delay);
    }
    if (failure != null) {
      throw failure!;
    }
    return names.map(StreamIdentifier.fromString).toList();
  }
}

const _sample = <String>[
  'UU.ARUT.EHZ.01',
  'WY.YPK.HHE.01',
  'WY.YPK.HHN.01',
  'WY.YPK.HHZ.01',
  'UU.BGU.HHZ.01',
];

/// Pumps the dialog and settles the initial query.
Future<void> pumpSelector(
  WidgetTester tester, {
  StreamSource? source,
  List<StreamIdentifier> initialSelection = const <StreamIdentifier>[],
}) async {
  await tester.pumpWidget(
    MaterialApp(
      // The real theme, so tooltips here wait as long as they do in the app.
      theme: buildAppTheme(),
      home: Scaffold(
        body: StreamSelectorDialog(
          source: source ?? FakeStreamSource(_sample),
          initialSelection: initialSelection,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// The stream names currently drawn, in order, under a given heading.
List<String> namesUnder(WidgetTester tester, String headingPrefix) {
  final column = find.ancestor(
    of: find.textContaining(headingPrefix),
    matching: find.byType(Column),
  );
  return tester
      .widgetList<ListTile>(
        find.descendant(of: column.first, matching: find.byType(ListTile)),
      )
      .map((tile) => (tile.title! as Text).data!)
      .toList();
}

/// The stream currently highlighted under a heading, if any.
String? highlightedIn(WidgetTester tester, String headingPrefix) {
  final column = find.ancestor(
    of: find.textContaining(headingPrefix),
    matching: find.byType(Column),
  );
  for (final tile in tester.widgetList<ListTile>(
    find.descendant(of: column.first, matching: find.byType(ListTile)),
  )) {
    if (tile.selected) {
      return (tile.title! as Text).data;
    }
  }
  return null;
}

/// The tooltip attached to one of the middle-column buttons.
String tooltipFor(WidgetTester tester, Type buttonType, String label) {
  return tester
      .widget<Tooltip>(
        find
            .ancestor(
              of: find.widgetWithText(buttonType, label),
              matching: find.byType(Tooltip),
            )
            .first,
      )
      .message!;
}

Future<void> tapStream(WidgetTester tester, String name) async {
  await tester.tap(find.text(name));
  await tester.pumpAndSettle();
}

void main() {
  group('StreamSelectorDialog', () {
    testWidgets('shows progress while querying, then the picker', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StreamSelectorDialog(
              source: FakeStreamSource(
                _sample,
                delay: const Duration(milliseconds: 100),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(
        find.text('Querying streams from test-server:18000...'),
        findsOneWidget,
      );
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      await tester.pumpAndSettle();

      expect(find.textContaining('Querying streams'), findsNothing);
      expect(find.text('UU.ARUT.EHZ.01'), findsOneWidget);
      expect(find.textContaining('Available (5)'), findsOneWidget);
    });

    testWidgets('reports a failed query instead of hanging', (tester) async {
      await pumpSelector(
        tester,
        source: FakeStreamSource(
          const [],
          failure: const StreamSourceException('connection refused'),
        ),
      );
      expect(find.textContaining('Could not query'), findsOneWidget);
      expect(find.textContaining('connection refused'), findsOneWidget);
    });

    testWidgets('Add moves the stream across and hides it on the left', (
      tester,
    ) async {
      await pumpSelector(tester);

      await tapStream(tester, 'WY.YPK.HHZ.01');
      await tester.tap(find.widgetWithText(ElevatedButton, 'Add'));
      await tester.pumpAndSettle();

      expect(namesUnder(tester, 'Selected ('), ['WY.YPK.HHZ.01']);
      expect(namesUnder(tester, 'Available ('), isNot(contains('WY.YPK.HHZ.01')));
      expect(find.textContaining('Available (4)'), findsOneWidget);
    });

    testWidgets('Remove puts the stream back on the left', (tester) async {
      await pumpSelector(tester);

      await tapStream(tester, 'UU.BGU.HHZ.01');
      await tester.tap(find.widgetWithText(ElevatedButton, 'Add'));
      await tester.pumpAndSettle();
      expect(namesUnder(tester, 'Available ('), isNot(contains('UU.BGU.HHZ.01')));

      // Tapping the copy in the selected list highlights it there
      await tapStream(tester, 'UU.BGU.HHZ.01');
      await tester.tap(find.widgetWithText(ElevatedButton, 'Remove'));
      await tester.pumpAndSettle();

      expect(namesUnder(tester, 'Selected ('), isEmpty);
      expect(namesUnder(tester, 'Available ('), contains('UU.BGU.HHZ.01'));
    });

    testWidgets('buttons are disabled until something is highlighted', (
      tester,
    ) async {
      await pumpSelector(tester);
      expect(
        tester
            .widget<ElevatedButton>(
              find.widgetWithText(ElevatedButton, 'Add'),
            )
            .onPressed,
        isNull,
      );

      await tapStream(tester, 'UU.ARUT.EHZ.01');
      expect(
        tester
            .widget<ElevatedButton>(
              find.widgetWithText(ElevatedButton, 'Add'),
            )
            .onPressed,
        isNotNull,
      );
    });

    testWidgets('the selected list keeps plot order and starts populated', (
      tester,
    ) async {
      await pumpSelector(
        tester,
        initialSelection: [
          StreamIdentifier.fromString('WY.YPK.HHZ.01'),
          StreamIdentifier.fromString('UU.ARUT.EHZ.01'),
        ],
      );
      // Insertion order, not alphabetical - this is the plot order
      expect(namesUnder(tester, 'Selected ('), [
        'WY.YPK.HHZ.01',
        'UU.ARUT.EHZ.01',
      ]);
      // Already-selected streams are hidden from the available list
      expect(find.textContaining('Available (3)'), findsOneWidget);
    });

    testWidgets('the available list is alphabetised', (tester) async {
      await pumpSelector(tester);
      final names = namesUnder(tester, 'Available (');
      expect(names, orderedEquals(names.toList()..sort()));
    });
  });

  group('regex filter', () {
    testWidgets('narrows the list case-insensitively', (tester) async {
      await pumpSelector(tester);

      await tester.enterText(find.byType(TextField), 'ypk');
      await tester.pumpAndSettle();

      expect(namesUnder(tester, 'Available ('), [
        'WY.YPK.HHE.01',
        'WY.YPK.HHN.01',
        'WY.YPK.HHZ.01',
      ]);
    });

    testWidgets('accepts a real regular expression', (tester) async {
      await pumpSelector(tester);

      await tester.enterText(find.byType(TextField), r'\.HHZ\.');
      await tester.pumpAndSettle();

      expect(namesUnder(tester, 'Available ('), [
        'UU.BGU.HHZ.01',
        'WY.YPK.HHZ.01',
      ]);
    });

    testWidgets('flags a malformed expression without blanking the list', (
      tester,
    ) async {
      await pumpSelector(tester);

      await tester.enterText(find.byType(TextField), 'UU.(BGU');
      await tester.pumpAndSettle();

      expect(find.text('Not a valid regular expression'), findsOneWidget);
      expect(namesUnder(tester, 'Available ('), hasLength(5));
    });

    testWidgets('the suggested example can be typed without being told off', (
      tester,
    ) async {
      await pumpSelector(tester);
      final field = tester.widget<TextField>(find.byType(TextField));
      final example = RegExp(
        r'e\.g\..*or\s+(\S+)',
      ).firstMatch(field.decoration!.hintText!)!.group(1)!;

      // Typed a character at a time, the way a user copying the hint would.
      // A half finished escape reports itself as a mistake, so an example
      // containing one accuses the user of an error on the way to getting it
      // right.
      for (var i = 1; i <= example.length; i++) {
        await tester.enterText(find.byType(TextField), example.substring(0, i));
        await tester.pumpAndSettle();
        expect(
          find.text('Not a valid regular expression'),
          findsNothing,
          reason: 'typing "${example.substring(0, i)}" warned',
        );
      }
      expect(namesUnder(tester, 'Available ('), isNotEmpty);
    });
  });

  group('keyboard accelerators', () {
    testWidgets('bare a adds when the filter does not have focus', (
      tester,
    ) async {
      await pumpSelector(tester);
      await tapStream(tester, 'UU.ARUT.EHZ.01');

      await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
      await tester.pumpAndSettle();

      expect(namesUnder(tester, 'Selected ('), ['UU.ARUT.EHZ.01']);
    });

    testWidgets('bare r removes when the filter does not have focus', (
      tester,
    ) async {
      await pumpSelector(
        tester,
        initialSelection: [StreamIdentifier.fromString('UU.ARUT.EHZ.01')],
      );
      await tapStream(tester, 'UU.ARUT.EHZ.01');

      await tester.sendKeyEvent(LogicalKeyboardKey.keyR);
      await tester.pumpAndSettle();

      expect(namesUnder(tester, 'Selected ('), isEmpty);
    });

    testWidgets('bare a types into the filter instead of adding', (
      tester,
    ) async {
      await pumpSelector(tester);
      await tapStream(tester, 'UU.ARUT.EHZ.01');

      // This is the case that makes names like ARUT typable
      await tester.tap(find.byType(TextField));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'aru');
      await tester.pumpAndSettle();

      expect(namesUnder(tester, 'Selected ('), isEmpty);
      expect(find.text('UU.ARUT.EHZ.01'), findsOneWidget);
    });

    testWidgets('a and r come back after filtering and clicking a row', (
      tester,
    ) async {
      await pumpSelector(tester);

      // Filter, then click a result. The click is what used to leave the
      // keyboard behind in the filter field, where a and r are swallowed so
      // that names like ARUT stay typeable - so Add looked broken.
      await tester.tap(find.byType(TextField));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'arut');
      await tester.pumpAndSettle();
      await tapStream(tester, 'UU.ARUT.EHZ.01');

      await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
      await tester.pumpAndSettle();

      expect(namesUnder(tester, 'Selected ('), ['UU.ARUT.EHZ.01']);
    });

    testWidgets('r comes back after filtering and clicking a selected row', (
      tester,
    ) async {
      await pumpSelector(
        tester,
        initialSelection: [StreamIdentifier.fromString('UU.ARUT.EHZ.01')],
      );

      await tester.tap(find.byType(TextField));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'bgu');
      await tester.pumpAndSettle();
      await tapStream(tester, 'UU.ARUT.EHZ.01');

      await tester.sendKeyEvent(LogicalKeyboardKey.keyR);
      await tester.pumpAndSettle();

      expect(namesUnder(tester, 'Selected ('), isEmpty);
    });

    testWidgets('arrowing out of the filter still works', (tester) async {
      await pumpSelector(tester);

      // The click hands the keyboard back, but arrowing must not - typing a
      // filter and arrowing straight down into the results is the fast path.
      await tester.tap(find.byType(TextField));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'ypk');
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pumpAndSettle();

      expect(namesUnder(tester, 'Selected ('), ['WY.YPK.HHE.01']);
    });

    testWidgets('alt+a adds even while the filter has focus', (tester) async {
      await pumpSelector(tester);
      await tapStream(tester, 'UU.ARUT.EHZ.01');

      await tester.tap(find.byType(TextField));
      await tester.pumpAndSettle();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pumpAndSettle();

      expect(namesUnder(tester, 'Selected ('), ['UU.ARUT.EHZ.01']);
    });

    testWidgets('the mnemonic letter is underlined', (tester) async {
      await pumpSelector(tester);
      final label = tester.widget<Text>(
        find
            .descendant(
              of: find.widgetWithText(ElevatedButton, 'Add'),
              matching: find.byType(Text),
            )
            .first,
      );
      final first = (label.textSpan! as TextSpan).children![1] as TextSpan;
      expect(first.text, 'A');
      expect(first.style?.decoration, TextDecoration.underline);
    });
  });

  group('arrow keys', () {
    testWidgets('walk the highlight instead of leaving a second selection', (
      tester,
    ) async {
      await pumpSelector(tester);
      // Alphabetised: ARUT, BGU, YPK.HHE, YPK.HHN, YPK.HHZ
      await tapStream(tester, 'UU.ARUT.EHZ.01');
      expect(highlightedIn(tester, 'Available ('), 'UU.ARUT.EHZ.01');

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(highlightedIn(tester, 'Available ('), 'UU.BGU.HHZ.01');

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(highlightedIn(tester, 'Available ('), 'WY.YPK.HHE.01');

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pumpAndSettle();
      expect(highlightedIn(tester, 'Available ('), 'UU.BGU.HHZ.01');
    });

    testWidgets('stop at the ends rather than wrapping', (tester) async {
      await pumpSelector(tester);
      await tapStream(tester, 'UU.ARUT.EHZ.01');

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pumpAndSettle();
      expect(highlightedIn(tester, 'Available ('), 'UU.ARUT.EHZ.01');
    });

    testWidgets('down from nothing steps into the available list', (
      tester,
    ) async {
      await pumpSelector(tester);
      expect(highlightedIn(tester, 'Available ('), isNull);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();

      expect(highlightedIn(tester, 'Available ('), 'UU.ARUT.EHZ.01');
    });

    testWidgets('work straight from the filter field', (tester) async {
      await pumpSelector(tester);

      await tester.tap(find.byType(TextField));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'ypk');
      await tester.pumpAndSettle();

      // Arrow down out of the filter and into the filtered results
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(highlightedIn(tester, 'Available ('), 'WY.YPK.HHE.01');

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(highlightedIn(tester, 'Available ('), 'WY.YPK.HHN.01');
    });

    testWidgets('walk the selected list when it owns the highlight', (
      tester,
    ) async {
      await pumpSelector(
        tester,
        initialSelection: [
          StreamIdentifier.fromString('UU.ARUT.EHZ.01'),
          StreamIdentifier.fromString('UU.BGU.HHZ.01'),
        ],
      );
      await tapStream(tester, 'UU.ARUT.EHZ.01');
      expect(highlightedIn(tester, 'Selected ('), 'UU.ARUT.EHZ.01');

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();

      expect(highlightedIn(tester, 'Selected ('), 'UU.BGU.HHZ.01');
      expect(highlightedIn(tester, 'Available ('), isNull);
    });
  });

  group('one highlight at a time', () {
    testWidgets('highlighting on the right releases the left', (tester) async {
      await pumpSelector(tester);

      await tapStream(tester, 'UU.ARUT.EHZ.01');
      await tester.tap(find.widgetWithText(ElevatedButton, 'Add'));
      await tester.pumpAndSettle();
      // Add leaves the left highlighted so a run can be added quickly
      expect(highlightedIn(tester, 'Available ('), isNotNull);

      await tapStream(tester, 'UU.ARUT.EHZ.01');
      expect(highlightedIn(tester, 'Selected ('), 'UU.ARUT.EHZ.01');
      expect(highlightedIn(tester, 'Available ('), isNull);

      // ... and only one of the two buttons can be live at once
      expect(
        tester
            .widget<ElevatedButton>(find.widgetWithText(ElevatedButton, 'Add'))
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<ElevatedButton>(
              find.widgetWithText(ElevatedButton, 'Remove'),
            )
            .onPressed,
        isNotNull,
      );
    });
  });

  group('tooltips', () {
    testWidgets('name the stream that will move', (tester) async {
      await pumpSelector(tester);

      expect(
        tooltipFor(tester, ElevatedButton, 'Add'),
        'Pick a stream on the left to add it to the plot list',
      );

      await tapStream(tester, 'UU.ARUT.EHZ.01');
      expect(
        tooltipFor(tester, ElevatedButton, 'Add'),
        'Add UU.ARUT.EHZ.01 to the plot list',
      );

      await tester.tap(find.widgetWithText(ElevatedButton, 'Add'));
      await tester.pumpAndSettle();
      await tapStream(tester, 'UU.ARUT.EHZ.01');
      expect(
        tooltipFor(tester, ElevatedButton, 'Remove'),
        'Remove UU.ARUT.EHZ.01 from the plot list',
      );
    });
  });

  group('tooltip timing', () {
    testWidgets('waits for the mouse to settle before appearing', (
      tester,
    ) async {
      await pumpSelector(tester);
      await tapStream(tester, 'UU.ARUT.EHZ.01');

      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(
        tester.getCenter(find.widgetWithText(ElevatedButton, 'Add')),
      );

      // Still nothing most of the way through the delay
      await tester.pump(tooltipDelay - const Duration(milliseconds: 50));
      expect(find.text('Add UU.ARUT.EHZ.01 to the plot list'), findsNothing);

      // ... and there once it has elapsed
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pumpAndSettle();
      expect(find.text('Add UU.ARUT.EHZ.01 to the plot list'), findsOneWidget);
    });
  });

  group('remove all', () {
    testWidgets('is disabled while the plot list is empty', (tester) async {
      await pumpSelector(tester);
      expect(
        tester
            .widget<OutlinedButton>(
              find.widgetWithText(OutlinedButton, 'Remove all'),
            )
            .onPressed,
        isNull,
      );
    });

    testWidgets('asks first, and clears everything on confirm', (tester) async {
      await pumpSelector(
        tester,
        initialSelection: [
          StreamIdentifier.fromString('UU.ARUT.EHZ.01'),
          StreamIdentifier.fromString('UU.BGU.HHZ.01'),
        ],
      );

      await tester.tap(find.widgetWithText(OutlinedButton, 'Remove all'));
      await tester.pumpAndSettle();
      expect(find.text('Remove all streams?'), findsOneWidget);
      expect(find.textContaining('clears all 2 streams'), findsOneWidget);

      await tester.tap(find.widgetWithText(FilledButton, 'Remove all'));
      await tester.pumpAndSettle();

      expect(namesUnder(tester, 'Selected ('), isEmpty);
      // Everything comes back on the left
      expect(find.textContaining('Available (5)'), findsOneWidget);
    });

    testWidgets('cancelling leaves the plot list alone', (tester) async {
      await pumpSelector(
        tester,
        initialSelection: [StreamIdentifier.fromString('UU.ARUT.EHZ.01')],
      );

      await tester.tap(find.widgetWithText(OutlinedButton, 'Remove all'));
      await tester.pumpAndSettle();
      // Scoped to the confirmation - the selector has its own Cancel too
      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.widgetWithText(TextButton, 'Cancel'),
        ),
      );
      await tester.pumpAndSettle();

      expect(namesUnder(tester, 'Selected ('), ['UU.ARUT.EHZ.01']);
    });

    testWidgets('has no keyboard accelerator', (tester) async {
      await pumpSelector(
        tester,
        initialSelection: [StreamIdentifier.fromString('UU.ARUT.EHZ.01')],
      );
      // Nothing bound to the obvious candidates should nuke the list
      for (final key in [LogicalKeyboardKey.delete, LogicalKeyboardKey.keyC]) {
        await tester.sendKeyEvent(key);
        await tester.pumpAndSettle();
      }
      expect(find.text('Remove all streams?'), findsNothing);
      expect(namesUnder(tester, 'Selected ('), ['UU.ARUT.EHZ.01']);
    });
  });

  group('plot order', () {
    testWidgets('dragging a stream up reorders the plot order', (tester) async {
      await pumpSelector(
        tester,
        initialSelection: [
          StreamIdentifier.fromString('UU.ARUT.EHZ.01'),
          StreamIdentifier.fromString('UU.BGU.HHZ.01'),
          StreamIdentifier.fromString('WY.YPK.HHZ.01'),
        ],
      );
      expect(namesUnder(tester, 'Selected ('), [
        'UU.ARUT.EHZ.01',
        'UU.BGU.HHZ.01',
        'WY.YPK.HHZ.01',
      ]);

      // Drag the third entry above the first
      final third = find.descendant(
        of: find.byType(ReorderableListView),
        matching: find.text('WY.YPK.HHZ.01'),
      );
      final startedAt = tester.getCenter(third);
      final gesture = await tester.startGesture(startedAt);
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 10));
      await gesture.moveTo(startedAt - const Offset(0, 80));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();

      expect(namesUnder(tester, 'Selected ('), [
        'WY.YPK.HHZ.01',
        'UU.ARUT.EHZ.01',
        'UU.BGU.HHZ.01',
      ]);
    });
  });

  group('dialog result', () {
    testWidgets('OK returns the selection and Cancel returns null', (
      tester,
    ) async {
      for (final confirm in [true, false]) {
        List<StreamIdentifier>? result;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (context) => ElevatedButton(
                  onPressed: () async {
                    result = await showStreamSelector(
                      context,
                      source: FakeStreamSource(_sample),
                    );
                  },
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();

        await tapStream(tester, 'UU.ARUT.EHZ.01');
        await tester.tap(find.widgetWithText(ElevatedButton, 'Add'));
        await tester.pumpAndSettle();

        await tester.tap(find.text(confirm ? 'OK' : 'Cancel'));
        await tester.pumpAndSettle();

        if (confirm) {
          expect(result, hasLength(1));
          expect(result!.single.toString(), 'UU.ARUT.EHZ.01');
        } else {
          expect(result, isNull);
        }
      }
    });
  });
}
