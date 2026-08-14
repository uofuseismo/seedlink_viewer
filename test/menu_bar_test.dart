import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:waveform_viewer/main.dart';

void main() {
  group('menu bar', () {
    testWidgets('offers File and Selection', (tester) async {
      await tester.pumpWidget(const MyApp());
      await tester.pump();

      expect(find.text('File', findRichText: true), findsOneWidget);
      expect(find.text('Selection', findRichText: true), findsOneWidget);
    });

    testWidgets('Selection opens the stream selector', (tester) async {
      await tester.pumpWidget(const MyApp());
      await tester.pump();

      await tester.tap(find.text('Selection', findRichText: true));
      await tester.pump();

      expect(
        find.text('Stream selector...', findRichText: true),
        findsOneWidget,
      );

      await tester.tap(find.text('Stream selector...', findRichText: true));
      // Let the dialog route animate in, but stop short of the query
      // completing so the progress frame is what we land on.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      // The dialog opens on its progress frame rather than blocking
      expect(find.textContaining('Querying streams from'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      // Then let the sample query finish - both to check it populates and so
      // its timer does not outlive the test.  pumpAndSettle is no use here
      // because the StreamPainters underneath redraw on a periodic timer.
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump();

      expect(find.textContaining('Querying streams from'), findsNothing);
      expect(find.textContaining('Available (114)'), findsOneWidget);
    });

    testWidgets('File offers Exit', (tester) async {
      await tester.pumpWidget(const MyApp());
      await tester.pump();

      await tester.tap(find.text('File', findRichText: true));
      await tester.pump();

      expect(find.text('Exit', findRichText: true), findsOneWidget);
    });
  });
}
