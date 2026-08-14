import 'package:material_ui/material_ui.dart';

/// What fills the window when there is nothing to plot.
///
/// Better than leaving the plotting area running on invented data: a trace
/// moving across the screen reads as a live signal, and it is disorienting to
/// see one before any server has been connected to.
class WelcomeView extends StatelessWidget {
  /// What the user should do next.
  final String message;

  /// A shortcut to doing it, if there is an obvious one.
  final String? actionLabel;
  final VoidCallback? onAction;

  const WelcomeView({
    super.key,
    required this.message,
    this.actionLabel,
    this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ColoredBox(
      color: theme.colorScheme.surface,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.show_chart,
                size: 56,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(height: 16),
              Text(
                'Waveform Viewer',
                style: theme.textTheme.headlineSmall,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              Text(
                message,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                textAlign: TextAlign.center,
              ),
              if (actionLabel != null && onAction != null) ...[
                const SizedBox(height: 24),
                FilledButton(onPressed: onAction, child: Text(actionLabel!)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
