import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform;
import 'package:material_ui/material_ui.dart';
import '../models/connection_profile.dart';

/// The application menu bar.
///
/// Connect sits at the top because it is the routine action; creating and
/// maintaining profiles are rarer and live together below the divider, which
/// also keeps a stray click on Delete away from the profile you meant to
/// connect to.
///
/// Two menu bars come out of this, because desktops disagree about where a menu
/// belongs. Windows and Linux put it inside the window, which is what Material's
/// [MenuBar] draws. macOS puts it in the system bar at the top of the screen,
/// which only the OS can draw - so there [PlatformMenuBar] hands the menu to
/// AppKit and this widget renders nothing at all. Drawing the Material bar on
/// macOS would leave two menu bars on screen: the system one the runner already
/// installs from MainMenu.xib, and a second one in the window holding the only
/// items that matter.
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
    // defaultTargetPlatform rather than Platform.isMacOS so a test can pin it:
    // whoever runs the suite decides which menu bar is under test, instead of
    // whichever machine they happen to be sitting at.
    if (defaultTargetPlatform == TargetPlatform.macOS) {
      return PlatformMenuBar(
        menus: [_macApplicationMenu, ..._menus.map(_toPlatformMenu)],
        // The menu lives in the system bar, so there is nothing to lay out.
        // The Align wrapping this collapses around a zero-sized child.
        child: const SizedBox.shrink(),
      );
    }
    return MenuBar(
      children: [
        for (final menu in [_fileMenu, ..._menus])
          _toMaterialEntry(context, menu),
      ],
    );
  }

  // ---------------------------------------------------------------- the menu

  /// The menus that are the same everywhere.
  ///
  /// File and the macOS application menu are deliberately not here: they hold
  /// the same command under different names in different places, and only one
  /// of them exists at a time.
  List<_Submenu> get _menus => [
        _Submenu('Co&nnection', [
          _profileEntry(
            label: '&Connect',
            // A first run has nothing to connect to, so the menu points at
            // Create instead of offering an empty list.
            enabled: _hasProfiles,
            onSelected: onConnect,
            markActive: true,
          ),
          _Item('&Disconnect', onSelected: active == null ? null : onDisconnect),
          const _Separator(),
          _Item('C&reate...', onSelected: onCreate),
          _profileEntry(
            label: '&Edit',
            enabled: _hasProfiles,
            onSelected: onEdit,
          ),
          _profileEntry(
            label: 'De&lete',
            enabled: _hasProfiles,
            onSelected: onDelete,
          ),
        ]),
        _Submenu('&Selection', [
          _Item(
            '&Stream selector...',
            // Nothing to choose from until a server has been asked what it
            // has, so this stays shut until there is a connection.
            onSelected: active == null ? null : onShowStreamSelector,
          ),
        ]),
      ];

  /// Quitting lives in File on Windows and Linux.
  _Submenu get _fileMenu => _Submenu('&File', [
        _Item('E&xit', onSelected: onExit),
      ]);

  /// The macOS application menu.
  ///
  /// Setting a [PlatformMenuBar] replaces the whole main menu, so About, Quit,
  /// Services and the hide commands have to be asked for again or they vanish -
  /// including Cmd-Q, which users will not forgive. These are provided by the
  /// platform rather than by us, so Quit tears the app down the way macOS
  /// expects instead of going through [onExit].
  PlatformMenu get _macApplicationMenu => const PlatformMenu(
        // macOS titles the first menu after the bundle, so this label is only
        // what the tree calls itself.
        label: 'SeedLink Viewer',
        menus: [
          PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.about),
          PlatformMenuItemGroup(
            members: [
              PlatformProvidedMenuItem(
                type: PlatformProvidedMenuItemType.servicesSubmenu,
              ),
            ],
          ),
          PlatformMenuItemGroup(
            members: [
              PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.hide),
              PlatformProvidedMenuItem(
                type: PlatformProvidedMenuItemType.hideOtherApplications,
              ),
              PlatformProvidedMenuItem(
                type: PlatformProvidedMenuItemType.showAllApplications,
              ),
            ],
          ),
          PlatformMenuItemGroup(
            members: [
              PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.quit),
            ],
          ),
        ],
      );

  /// One submenu listing every profile, used for Connect, Edit and Delete.
  ///
  /// Neither menu bar has a disabled submenu, so with nothing to list this
  /// falls back to a greyed out plain item rather than a submenu that opens
  /// onto nothing.
  _Entry _profileEntry({
    required String label,
    required bool enabled,
    required void Function(ConnectionProfile) onSelected,
    bool markActive = false,
  }) {
    if (!enabled) {
      return _Item(label);
    }
    return _Submenu(label, [
      for (final profile in profiles)
        _Item(
          profile.name,
          onSelected: () => onSelected(profile),
          detail: profile.address,
          checked: markActive ? profile.name == active?.name : null,
        ),
    ]);
  }

  // ----------------------------------------------------------- the renderers

  Widget _toMaterialEntry(BuildContext context, _Entry entry) {
    return switch (entry) {
      _Separator() => const Divider(height: 8),
      _Submenu(:final label, :final children) => SubmenuButton(
          menuChildren: [
            for (final child in children) _toMaterialEntry(context, child),
          ],
          child: MenuAcceleratorLabel(label),
        ),
      _Item(:final label, :final onSelected, :final detail, :final checked) =>
        MenuItemButton(
          onPressed: onSelected,
          leadingIcon: checked == null
              ? null
              : Icon(
                  checked
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  size: 16,
                ),
          trailingIcon: detail == null
              ? null
              : Text(detail, style: Theme.of(context).textTheme.bodySmall),
          // A profile name is the user's own text and carries no accelerator
          // marker, so an unescaped '&' in it would silently eat a letter.
          child: checked == null && detail == null
              ? MenuAcceleratorLabel(label)
              : Text(label),
        ),
    };
  }

  PlatformMenu _toPlatformMenu(_Submenu menu) {
    return PlatformMenu(
      label: MenuAcceleratorLabel.stripAcceleratorMarkers(menu.label),
      menus: _toPlatformChildren(menu.children),
    );
  }

  /// Renders a run of entries, turning separators into groups.
  ///
  /// The platform menu has no divider item: it draws a line between
  /// [PlatformMenuItemGroup]s instead. A single group would therefore be
  /// wrapped for nothing, and on some macOS versions picks up a stray line, so
  /// grouping only starts once there is a separator to honour.
  List<PlatformMenuItem> _toPlatformChildren(List<_Entry> entries) {
    final groups = <List<PlatformMenuItem>>[[]];
    for (final entry in entries) {
      if (entry is _Separator) {
        groups.add([]);
        continue;
      }
      groups.last.add(_toPlatformEntry(entry));
    }
    final filled = groups.where((group) => group.isNotEmpty).toList();
    if (filled.length <= 1) {
      return filled.isEmpty ? const [] : filled.single;
    }
    return [for (final group in filled) PlatformMenuItemGroup(members: group)];
  }

  PlatformMenuItem _toPlatformEntry(_Entry entry) {
    return switch (entry) {
      // Handled a level up, where a separator becomes a group boundary.
      _Separator() => throw StateError('separators are grouped, not rendered'),
      _Submenu(:final label, :final children) => PlatformMenu(
          label: MenuAcceleratorLabel.stripAcceleratorMarkers(label),
          menus: _toPlatformChildren(children),
        ),
      _Item() => PlatformMenuItem(
          label: _platformLabel(entry),
          onSelected: entry.onSelected,
        ),
    };
  }

  /// Everything an item has to say, as one string.
  ///
  /// A [PlatformMenuItem] is a label and nothing else - the OS draws it, so
  /// there is nowhere to hang the leading tick or the trailing address that the
  /// Material menu puts in widgets. Both fold into the text instead. macOS has
  /// no Alt accelerators either, so the markers come out.
  String _platformLabel(_Item item) {
    final buffer = StringBuffer();
    if (item.checked ?? false) {
      buffer.write('✓ ');
    }
    buffer.write(MenuAcceleratorLabel.stripAcceleratorMarkers(item.label));
    if (item.detail != null) {
      buffer.write('  —  ${item.detail}');
    }
    return buffer.toString();
  }
}

/// The menu described as data, so it can be written once and drawn twice.
///
/// The two bars take incompatible input - Material's wants widgets, the
/// platform's wants strings it hands to the OS - so neither can be derived from
/// the other. Keeping the description separate leaves the ordering, the
/// enabling rules and the profile lists stated once, with each renderer saying
/// only how it draws.
sealed class _Entry {
  const _Entry();
}

/// Something to click. A null [onSelected] draws it greyed out.
class _Item extends _Entry {
  /// The label, with `&` marking the accelerator letter. The platform menu
  /// strips the markers.
  final String label;
  final VoidCallback? onSelected;

  /// Secondary text, shown after the label - the address behind a profile.
  final String? detail;

  /// Whether this is the chosen one of a set, or null if it is not one of a
  /// set at all. The distinction matters: false still draws an empty radio.
  final bool? checked;

  const _Item(this.label, {this.onSelected, this.detail, this.checked});
}

class _Submenu extends _Entry {
  final String label;
  final List<_Entry> children;

  const _Submenu(this.label, this.children);
}

class _Separator extends _Entry {
  const _Separator();
}
