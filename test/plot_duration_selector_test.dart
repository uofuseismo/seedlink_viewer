import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:seedlink_viewer/main.dart' show buildAppTheme;
import 'package:seedlink_viewer/models/plot_timing.dart';
import 'package:seedlink_viewer/views/plot_duration_selector.dart';

/// What the selector reported, in order.
late List<Duration> reported;

Future<void> pumpSelector(
  WidgetTester tester, {
  Duration window = const Duration(minutes: 2),
}) async {
  reported = <Duration>[];
  await tester.pumpWidget(
    MaterialApp(
      theme: buildAppTheme(),
      home: Scaffold(
        body: StatefulBuilder(
          builder: (context, setState) => PlotDurationSelector(
            window: reported.isEmpty ? window : reported.last,
            onWindowChanged: (value) => setState(() => reported.add(value)),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> openMenu(WidgetTester tester) async {
  await tester.tap(find.byType(TextButton));
  await tester.pumpAndSettle();
}

/// The label on the button itself, as opposed to a row in the open menu.
String buttonLabel(WidgetTester tester) {
  return tester
      .widget<Text>(
        find
            .descendant(of: find.byType(TextButton), matching: find.byType(Text))
            .first,
      )
      .data!;
}

Finder menuRow(String label) => find.descendant(
  of: find.byType(MenuItemButton),
  matching: find.text(label),
);

Future<void> type(WidgetTester tester, String text) async {
  await tester.enterText(find.byType(TextField), text);
  await tester.pumpAndSettle();
}

void main() {
  group('the button', () {
    testWidgets('shows what the plots are currently showing', (tester) async {
      await pumpSelector(tester, window: const Duration(minutes: 5));
      expect(buttonLabel(tester), '5 min');
    });

    testWidgets('says fractions in minutes too', (tester) async {
      await pumpSelector(tester, window: const Duration(seconds: 30));
      expect(buttonLabel(tester), '0.5 min');
    });
  });

  group('the menu', () {
    testWidgets('puts the typed field above the quick choices', (tester) async {
      await pumpSelector(tester);
      await openMenu(tester);

      // Typing a duration that is not on the list is the only reason to open
      // this rather than click something already visible, so it comes first.
      expect(find.byType(TextField), findsOneWidget);
      final field = tester.getTopLeft(find.byType(TextField)).dy;
      final firstChoice = tester.getTopLeft(menuRow('1 min')).dy;
      expect(field, lessThan(firstChoice));

      for (final minutes in quickPlotDurationsInMinutes) {
        expect(menuRow('$minutes min'), findsOneWidget);
      }
    });

    testWidgets('ticks the one in force', (tester) async {
      await pumpSelector(tester, window: const Duration(minutes: 10));
      await openMenu(tester);

      final ticked = tester
          .widgetList<MenuItemButton>(find.byType(MenuItemButton))
          .where((button) => (button.leadingIcon as Icon?)?.icon != null)
          .length;
      expect(ticked, 1, reason: 'exactly one row should carry the tick');
    });

    testWidgets('a quick choice reports it and closes', (tester) async {
      await pumpSelector(tester);
      await openMenu(tester);
      await tester.tap(menuRow('10 min'));
      await tester.pumpAndSettle();

      expect(reported, [const Duration(minutes: 10)]);
      expect(find.byType(TextField), findsNothing, reason: 'menu still open');
      expect(buttonLabel(tester), '10 min');
    });
  });

  group('typing a duration of your own', () {
    testWidgets('Enter applies it', (tester) async {
      await pumpSelector(tester);
      await openMenu(tester);
      await type(tester, '7');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      expect(reported, [const Duration(minutes: 7)]);
      expect(buttonLabel(tester), '7 min');
    });

    testWidgets('so does the tick beside the field', (tester) async {
      await pumpSelector(tester);
      await openMenu(tester);
      await type(tester, '3');
      await tester.tap(find.widgetWithIcon(IconButton, Icons.check));
      await tester.pumpAndSettle();

      expect(reported, [const Duration(minutes: 3)]);
    });

    testWidgets('fractions work, because the unit is minutes', (tester) async {
      await pumpSelector(tester);
      await openMenu(tester);
      await type(tester, '0.5');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      expect(reported, [const Duration(seconds: 30)]);
    });

    testWidgets('too long is refused without closing the menu', (tester) async {
      await pumpSelector(tester);
      await openMenu(tester);
      await type(tester, '${maximumPlotDurationInMinutes + 1}');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      expect(reported, isEmpty);
      expect(find.byType(TextField), findsOneWidget, reason: 'menu closed');
      expect(
        find.textContaining('Up to $maximumPlotDurationInMinutes'),
        findsOneWidget,
      );
    });

    testWidgets('zero is refused as well', (tester) async {
      await pumpSelector(tester);
      await openMenu(tester);
      await type(tester, '0');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      expect(reported, isEmpty);
      expect(find.byType(TextField), findsOneWidget);
    });

    testWidgets('walking away leaves the real value behind', (tester) async {
      await pumpSelector(tester, window: const Duration(minutes: 5));
      await openMenu(tester);
      await type(tester, '99');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      // A half typed number left sitting in the field would read as current.
      expect(reported, isEmpty);
      expect(buttonLabel(tester), '5 min');
      await openMenu(tester);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        '5',
      );
    });
  });
}
