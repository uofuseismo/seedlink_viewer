import 'package:material_ui/material_ui.dart';

/// Asks for the passphrase on a private key that turned out to need one.
///
/// Only ever reached because a key was read and found to be encrypted, so this
/// says which key it is asking about - a user with several will otherwise be
/// guessing which passphrase is wanted.
///
/// Returns null when the user gives up. Nothing is remembered here: the caller
/// holds the answer for as long as the connection lasts and no longer.
Future<String?> showPassphrasePrompt(
  BuildContext context, {
  required String keyPath,
  required bool retry,
}) {
  return showDialog<String>(
    context: context,
    barrierDismissible: false,
    builder: (context) => PassphraseDialog(keyPath: keyPath, retry: retry),
  );
}

class PassphraseDialog extends StatefulWidget {
  final String keyPath;

  /// True when the last attempt was wrong, so the dialog says so instead of
  /// appearing to have ignored it.
  final bool retry;

  const PassphraseDialog({
    super.key,
    required this.keyPath,
    this.retry = false,
  });

  @override
  State<PassphraseDialog> createState() => _PassphraseDialogState();
}

class _PassphraseDialogState extends State<PassphraseDialog> {
  final _passphrase = TextEditingController();
  var _hidden = true;

  @override
  void dispose() {
    _passphrase.dispose();
    super.dispose();
  }

  void _submit() => Navigator.of(context).pop(_passphrase.text);

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Unlock private key'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.retry
                  ? 'That passphrase did not unlock the key. Try again.'
                  : 'This key is protected by a passphrase.',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 4),
            Text(
              widget.keyPath,
              style: Theme.of(context).textTheme.bodySmall,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _passphrase,
              autofocus: true,
              obscureText: _hidden,
              onSubmitted: (_) => _submit(),
              decoration: InputDecoration(
                labelText: 'Passphrase',
                border: const OutlineInputBorder(),
                isDense: true,
                errorText: widget.retry ? 'Not this one' : null,
                suffixIcon: IconButton(
                  icon: Icon(_hidden ? Icons.visibility : Icons.visibility_off),
                  tooltip: _hidden ? 'Show' : 'Hide',
                  onPressed: () => setState(() => _hidden = !_hidden),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Used for this session only and never saved.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        Tooltip(
          message: 'Unlock the key and carry on connecting.',
          child: FilledButton(
            onPressed: _submit,
            child: const Text('Unlock'),
          ),
        ),
      ],
    );
  }
}
