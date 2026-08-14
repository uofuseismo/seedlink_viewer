import 'package:material_ui/material_ui.dart';
import '../models/connection_profile.dart';

/// The application menu bar.
///
/// Connect sits at the top because it is the routine action; creating and
/// maintaining profiles are rarer and live together below the divider, which
/// also keeps a stray click on Delete away from the profile you meant to
/// connect to.
class AppMenuBar extends StatelessWidget {
  final List<ConnectionProfile> profiles;

  /// The profile currently connected, if any.
  final ConnectionProfile? active;

  final void Function(ConnectionProfile) onConnect;
  final VoidCallback onDisconnect;
  final VoidCallback onCreate;
  final void Function(ConnectionProfile) onEdit;
  final void Function(ConnectionProfile) onDelete;
  final VoidCallback onShowStreamSelector;
  final VoidCallback onExit;

  const AppMenuBar({
    super.key,
    required this.profiles,
    required this.active,
    required this.onConnect,
    required this.onDisconnect,
    required this.onCreate,
    required this.onEdit,
    required this.onDelete,
    required this.onShowStreamSelector,
    required this.onExit,
  });

  bool get _hasProfiles => profiles.isNotEmpty;

  @override
  Widget build(BuildContext context) {
    return MenuBar(
      children: [
        SubmenuButton(
          menuChildren: [
            MenuItemButton(
              onPressed: onExit,
              child: const MenuAcceleratorLabel('E&xit'),
            ),
          ],
          child: const MenuAcceleratorLabel('&File'),
        ),
        SubmenuButton(
          menuChildren: [
            _buildProfileSubmenu(
              context,
              label: '&Connect',
              // A first run has nothing to connect to, so the menu points at
              // Create instead of offering an empty list.
              enabled: _hasProfiles,
              onSelected: onConnect,
              markActive: true,
            ),
            MenuItemButton(
              onPressed: active == null ? null : onDisconnect,
              child: const MenuAcceleratorLabel('&Disconnect'),
            ),
            const Divider(height: 8),
            MenuItemButton(
              onPressed: onCreate,
              child: const MenuAcceleratorLabel('C&reate...'),
            ),
            _buildProfileSubmenu(
              context,
              label: '&Edit',
              enabled: _hasProfiles,
              onSelected: onEdit,
            ),
            _buildProfileSubmenu(
              context,
              label: 'De&lete',
              enabled: _hasProfiles,
              onSelected: onDelete,
            ),
          ],
          child: const MenuAcceleratorLabel('Co&nnection'),
        ),
        SubmenuButton(
          menuChildren: [
            MenuItemButton(
              // Nothing to choose from until a server has been asked what it
              // has, so this stays shut until there is a connection.
              onPressed: active == null ? null : onShowStreamSelector,
              child: const MenuAcceleratorLabel('&Stream selector...'),
            ),
          ],
          child: const MenuAcceleratorLabel('&Selection'),
        ),
      ],
    );
  }

  /// One submenu listing every profile, used for Connect, Edit and Delete.
  ///
  /// SubmenuButton has no disabled state, so with nothing to list this falls
  /// back to a greyed out plain item rather than a submenu that opens onto
  /// nothing.
  Widget _buildProfileSubmenu(
    BuildContext context, {
    required String label,
    required bool enabled,
    required void Function(ConnectionProfile) onSelected,
    bool markActive = false,
  }) {
    if (!enabled) {
      return MenuItemButton(
        onPressed: null,
        child: MenuAcceleratorLabel(label),
      );
    }
    return SubmenuButton(
      menuChildren: [
        for (final profile in profiles)
          MenuItemButton(
            onPressed: () => onSelected(profile),
            leadingIcon: markActive
                ? Icon(
                    profile.name == active?.name
                        ? Icons.radio_button_checked
                        : Icons.radio_button_unchecked,
                    size: 16,
                  )
                : null,
            trailingIcon: Text(
              profile.address,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            child: Text(profile.name),
          ),
      ],
      child: MenuAcceleratorLabel(label),
    );
  }
}
