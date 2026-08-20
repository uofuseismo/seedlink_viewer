import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:seedlink_viewer/main.dart' show buildAppTheme;
import 'package:seedlink_viewer/models/plot_timing.dart';
import 'package:seedlink_viewer/views/plot_options_dialog.dart';

/// What the dialog handed back, once it has closed.
class Outcome {
  PlotTiming? timing;
  var closed = false;
}

/// Opens the dialog on a real route, so Cancel and Apply pop it the way they
/// do in the app rather than being called directly.
Future<Outcome> pumpOptions(
  WidgetTester tester, {
  PlotTiming timing = const PlotTiming(),
}) async {
  final outcome = Outcome();
  await tester.pumpWidget(
    MaterialApp(
      theme: buildAppTheme(),
      home: Builder(
        builder: (context) => Scaffold(
          body: ElevatedButton(
            onPressed: () async {
              outcome.timing = await showPlotOptions(context, timing: timing);
              outcome.closed = true;
            },
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return outcome;
}

String fieldText(WidgetTester tester) =>
    tester.widget<TextField>(find.byType(TextField)).controller!.text;

bool chipSelected(WidgetTester tester, String label) => tester
    .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, label))
    .selected;

Future<void> type(WidgetTester tester, String text) async {
  await tester.enterText(find.byType(TextField), text);
  await tester.pumpAndSettle();
}

Future<void> apply(WidgetTester tester) async {
  await tester.tap(find.widgetWithText(FilledButton, 'Apply'));
  await tester.pumpAndSettle();
}

void main() {
  group('plot options', () {
    testWidgets('opens showing the window that is already set', (tester) async {
      await pumpOptions(
        tester,
        timing: const PlotTiming(window: Duration(minutes: 5)),
      );

      expect(fieldText(tester), '5');
      // The field and the quick choices are two views of one value, so they
      // must never disagree about what is set.
      expect(chipSelected(tester, '5 min'), isTrue);
      expect(chipSelected(tester, '2 min'), isFalse);
    });

    testWidgets('a quick choice fills the field in', (tester) async {
      await pumpOptions(tester);
      expect(fieldText(tester), '2');

      await tester.tap(find.widgetWithText(ChoiceChip, '10 min'));
      await tester.pumpAndSettle();

      expect(fieldText(tester), '10');
      expect(chipSelected(tester, '10 min'), isTrue);
    });

    testWidgets('typing a quick value lights its button', (tester) async {
      await pumpOptions(tester);
      await type(tester, '10');
      expect(chipSelected(tester, '10 min'), isTrue);
    });

    testWidgets('typing something in between lights none of them', (
      tester,
    ) async {
      await pumpOptions(tester);
      await type(tester, '7');

      for (final minutes in quickPlotDurationsInMinutes) {
        expect(chipSelected(tester, '$minutes min'), isFalse);
      }
    });
  });

  group('what comes back', () {
    testWidgets('a quick choice', (tester) async {
      final outcome = await pumpOptions(tester);

      await tester.tap(find.widgetWithText(ChoiceChip, '10 min'));
      await tester.pumpAndSettle();
      await apply(tester);

      expect(outcome.closed, isTrue);
      expect(outcome.timing!.window, const Duration(minutes: 10));
    });

    testWidgets('an override of the quick choices', (tester) async {
      final outcome = await pumpOptions(tester);
      await type(tester, '7');
      await apply(tester);

      expect(outcome.timing!.window, const Duration(minutes: 7));
    });

    testWidgets('fractions, because the unit is minutes', (tester) async {
      final outcome = await pumpOptions(tester);
      await type(tester, '0.5');
      await apply(tester);

      expect(outcome.timing!.window, const Duration(seconds: 30));
    });

    testWidgets('the buffer follows the window', (tester) async {
      final outcome = await pumpOptions(tester);
      await type(tester, '10');
      await apply(tester);

      // A window longer than the history behind it would be trimmed by the
      // buffer and look like a station that stopped sending.
      expect(
        outcome.timing!.history,
        greaterThanOrEqualTo(outcome.timing!.window),
      );
    });

    testWidgets('a history that was set deliberately survives', (tester) async {
      final outcome = await pumpOptions(
        tester,
        timing: const PlotTiming(
          window: Duration(minutes: 2),
          history: Duration(hours: 1),
        ),
      );
      await type(tester, '5');
      await apply(tester);

      // withWindow rather than a fresh PlotTiming, so a deliberate history and
      // the redraw interval are not quietly reset by a change of window.
      expect(outcome.timing!.history, const Duration(hours: 1));
    });

    testWidgets('nothing at all, when cancelled', (tester) async {
      final outcome = await pumpOptions(tester);
      await type(tester, '42');
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();

      expect(outcome.closed, isTrue);
      expect(outcome.timing, isNull);
    });
  });

  group('what is refused', () {
    Future<void> expectRefused(WidgetTester tester, String typed) async {
      final outcome = await pumpOptions(tester);
      await type(tester, typed);
      await apply(tester);

      // Still open and saying why, rather than closing on a window nobody
      // could plot.
      expect(find.byType(PlotOptionsDialog), findsOneWidget, reason: typed);
      expect(find.textContaining('Enter a duration'), findsOneWidget);
      expect(outcome.closed, isFalse);
    }

    testWidgets('a zero length plot', (tester) async {
      await expectRefused(tester, '0');
    });

    testWidgets('an empty field', (tester) async {
      await expectRefused(tester, '');
    });

    testWidgets('longer than the buffer is willing to hold', (tester) async {
      await expectRefused(tester, '${maximumPlotDurationInMinutes + 1}');
    });

    testWidgets('letters never reach the field at all', (tester) async {
      await pumpOptions(tester);
      await type(tester, '5abc');
      // Filtered on the way in, so there is nothing to complain about later.
      expect(fieldText(tester), '5');
    });
  });
}
