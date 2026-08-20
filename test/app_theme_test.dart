import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:seedlink_viewer/main.dart' show buildAppTheme, tooltipDelay;

/// The WCAG contrast ratio between two opaque colours.
double contrastRatio(Color a, Color b) {
  final first = a.computeLuminance();
  final second = b.computeLuminance();
  final lighter = first > second ? first : second;
  final darker = first > second ? second : first;
  return (lighter + 0.05) / (darker + 0.05);
}

void main() {
  group('text field contrast', () {
    // A test subject typed over a port that was already filled in, and typed
    // out a host that was only ever a suggestion.  Both are the same mistake:
    // Material's default placeholder colour sits so close to entered text that
    // there is nothing to tell them apart.
    final theme = buildAppTheme();
    final colours = theme.colorScheme;
    final hint = theme.inputDecorationTheme.hintStyle!.color!;

    test('a placeholder is clearly not something already entered', () {
      final entered = colours.onSurface;
      expect(
        contrastRatio(entered, hint),
        greaterThan(3.0),
        reason: 'entered text and placeholder text look too alike',
      );
    });

    test('a placeholder is still readable', () {
      // Lighter separates it from real input, but past a point it stops being
      // a usable suggestion.  3:1 is the floor Material holds non-body text
      // to.
      expect(
        contrastRatio(hint, colours.surface),
        greaterThan(3.0),
        reason: 'placeholder has faded into the field',
      );
    });

    test('entered text stays at full strength', () {
      // The other half of the fix is unavailable - this is already about as
      // dark as it goes, so the separation has to come from the placeholder.
      expect(contrastRatio(colours.onSurface, colours.surface), greaterThan(7));
    });
  });

  test('tooltips wait for the mouse to settle', () {
    expect(buildAppTheme().tooltipTheme.waitDuration, tooltipDelay);
  });
}
