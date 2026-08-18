import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/services.dart' show LogicalKeyboardKey;
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
    // A modal dialog covers the in-window menu bar, so a click cannot reach it
    // while one is up. A shortcut and the macOS system menu both still can,
    // and either would stack a second dialog on the first, so the menu closes
    // for as long as the home route is not the one on top. isCurrentOf rather
    // than reading the route directly: it depends on the aspect, so this
    // rebuilds when a dialog opens and again when it closes.
    final interactive = ModalRoute.isCurrentOf(context) ?? true;
    final menus = _menus(interactive: interactive);

    // defaultTargetPlatform rather than Platform.isMacOS so a test can pin it:
    // whoever runs the suite decides which menu bar is under test, instead of
    // whichever machine they happen to be sitting at.
    if (defaultTargetPlatform == TargetPlatform.macOS) {
      // Nothing registers the shortcuts here. A PlatformMenuItem carries its
      // own, and macOS matches the keystroke against the system menu itself -
      // registering them again in dart would fire every command twice.
      return PlatformMenuBar(
        menus: [_macApplicationMenu, ...menus.map(_toPlatformMenu)],
        // The menu lives in the system bar, so there is nothing to lay out.
        // The Align wrapping this collapses around a zero-sized child.
        child: const SizedBox.shrink(),
      );
    }
    // Material shows the shortcut beside the item but does not act on it, so
    // the same descriptions are handed to the registry to be made real.
    return _MenuShortcuts(
      shortcuts: _shortcutsOf([_fileMenu(interactive: interactive), ...menus]),
      child: MenuBar(
        children: [
          for (final menu in [_fileMenu(interactive: interactive), ...menus])
            _toMaterialEntry(context, menu),
        ],
      ),
    );
  }

  /// Ctrl on Windows and Linux, Cmd on macOS.
  static SingleActivator _accelerator(LogicalKeyboardKey key) {
    return defaultTargetPlatform == TargetPlatform.macOS
        ? SingleActivator(key, meta: true)
        : SingleActivator(key, control: true);
  }

  /// Every shortcut in the menu that leads somewhere, paired with what it does.
  ///
  /// Items that are greyed out are left out rather than registered as no-ops,
  /// so Ctrl-D does nothing at all when there is nothing to disconnect from
  /// instead of quietly swallowing the keystroke.
  Map<ShortcutActivator, VoidCallback> _shortcutsOf(List<_Entry> entries) {
    final shortcuts = <ShortcutActivator, VoidCallback>{};
    void visit(_Entry entry) {
      switch (entry) {
        case _Separator():
          break;
        case _Submenu(:final children):
          children.forEach(visit);
        case _Item(:final shortcut, :final onSelected):
          if (shortcut is ShortcutActivator && onSelected != null) {
            shortcuts[shortcut as ShortcutActivator] = onSelected;
          }
      }
    }

    entries.forEach(visit);
    return shortcuts;
  }

  // ---------------------------------------------------------------- the menu

  /// The menus that are the same everywhere.
  ///
  /// File and the macOS application menu are deliberately not here: they hold
  /// the same command under different names in different places, and only one
  /// of them exists at a time.
  /// Only the leaves carry shortcuts. Connect, Edit and Delete each open onto
  /// a list of profiles, so there is no one thing a keystroke could mean.
  List<_Submenu> _menus({required bool interactive}) => [
    _Submenu('Co&nnection', [
      _profileEntry(
        label: '&Connect',
        // A first run has nothing to connect to, so the menu points at
        // Create instead of offering an empty list.
        enabled: interactive && _hasProfiles,
        onSelected: onConnect,
        markActive: true,
      ),
      _Item(
        '&Disconnect',
        onSelected: (interactive && active != null) ? onDisconnect : null,
        shortcut: _accelerator(LogicalKeyboardKey.keyD),
      ),
      const _Separator(),
      _Item(
        'C&reate...',
        onSelected: interactive ? onCreate : null,
        shortcut: _accelerator(LogicalKeyboardKey.keyN),
      ),
      _profileEntry(
        label: '&Edit',
        enabled: interactive && _hasProfiles,
        onSelected: onEdit,
      ),
      _profileEntry(
        label: 'De&lete',
        enabled: interactive && _hasProfiles,
        onSelected: onDelete,
      ),
    ]),
    _Submenu('&Selection', [
      _Item(
        '&Stream selector...',
        // Nothing to choose from until a server has been asked what it
        // has, so this stays shut until there is a connection.
        onSelected: (interactive && active != null)
            ? onShowStreamSelector
            : null,
        shortcut: _accelerator(LogicalKeyboardKey.keyL),
      ),
    ]),
  ];

  /// Quitting lives in File on Windows and Linux.
  ///
  /// There is no macOS counterpart to build here: Quit is provided by the
  /// platform in the application menu and already answers to Cmd-Q.
  _Submenu _fileMenu({required bool interactive}) => _Submenu('&File', [
    _Item(
      'E&xit',
      onSelected: interactive ? onExit : null,
      shortcut: _accelerator(LogicalKeyboardKey.keyQ),
    ),
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
      _Item(
        :final label,
        :final onSelected,
        :final detail,
        :final checked,
        :final shortcut,
      ) =>
        MenuItemButton(
          onPressed: onSelected,
          // Displayed only - _MenuShortcuts is what makes it fire.
          shortcut: shortcut,
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
        // macOS renders this next to the item and matches the keystroke
        // against it, so nothing on the dart side has to.
        shortcut: entry.shortcut,
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

  /// The keystroke that does the same thing, if there is one. Both menus can
  /// show it; only the platform one acts on it by itself.
  final MenuSerializableShortcut? shortcut;

  const _Item(
    this.label, {
    this.onSelected,
    this.detail,
    this.checked,
    this.shortcut,
  });
}

class _Submenu extends _Entry {
  final String label;
  final List<_Entry> children;

  const _Submenu(this.label, this.children);
}

class _Separator extends _Entry {
  const _Separator();
}

/// Makes the menu's shortcuts actually fire on Windows and Linux.
///
/// Material draws the shortcut beside an item and stops there - a [MenuBar]
/// never listens for the keystroke, and a menu that has to be open for its own
/// accelerator to work is no use. The registry is app wide, so registering here
/// covers the whole window rather than only this subtree.
///
/// The map is rebuilt from the menu on every change and swapped in wholesale,
/// which is what keeps a shortcut from outliving the state that made it valid:
/// disconnecting drops Ctrl-D on the same frame that greys the item out.
class _MenuShortcuts extends StatefulWidget {
  final Map<ShortcutActivator, VoidCallback> shortcuts;
  final Widget child;

  const _MenuShortcuts({required this.shortcuts, required this.child});

  @override
  State<_MenuShortcuts> createState() => _MenuShortcutsState();
}

class _MenuShortcutsState extends State<_MenuShortcuts> {
  ShortcutRegistryEntry? _registration;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _register();
  }

  @override
  void didUpdateWidget(_MenuShortcuts oldWidget) {
    super.didUpdateWidget(oldWidget);
    _register();
  }

  void _register() {
    final intents = {
      for (final entry in widget.shortcuts.entries)
        entry.key: VoidCallbackIntent(entry.value),
    };
    // The registry refuses an empty map, so having nothing to offer is said by
    // holding no registration at all rather than by holding an empty one.
    if (intents.isEmpty) {
      _registration?.dispose();
      _registration = null;
      return;
    }
    if (_registration == null) {
      _registration = ShortcutRegistry.of(context).addAll(intents);
    } else {
      _registration!.replaceAll(intents);
    }
  }

  @override
  void dispose() {
    _registration?.dispose();
    _registration = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
