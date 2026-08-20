/// Every duration the plotting depends on, in one place.
///
/// These belong together and belong at the top: the window the user sees and
/// the history kept behind it are not independent, and a window configured
/// longer than the buffer would be truncated by the buffer instead - quietly,
/// and looking exactly like a station that stopped sending. Holding them as
/// one value means a settings dialog changes one thing and everything below
/// stays consistent.
class PlotTiming {
  /// How much time the plots show.
  final Duration window;

  final Duration? _history;

  /// How often a plot redraws.
  ///
  /// The window is always the last [window] up to now, so a plot has to be
  /// repainted as time passes even when no new data has arrived.
  final Duration redrawInterval;

  /// How far ahead of now a packet may be stamped before it is treated as a
  /// clock problem rather than data.
  final Duration clockSlack;

  const PlotTiming({
    this.window = const Duration(minutes: 2),
    Duration? history,
    this.redrawInterval = const Duration(seconds: 3),
    this.clockSlack = const Duration(seconds: 30),
    // The analyzer suggests an initializing formal below.  It cannot be used:
    // the field is private and a named parameter may not begin with an
    // underscore, so `this._history` would not compile.  Keeping the field
    // private is what makes [history] the only way to read the value, which is
    // the point - the stored duration is an override, not the answer.
    // ignore: prefer_initializing_formals
  }) : _history = history;

  /// How much data is kept behind each plot.
  ///
  /// Never less than [window] - the buffer trimming the trace before the
  /// window does would look like data loss rather than a setting. Defaults to
  /// half as much again, so a plot still has something either side when the
  /// window is nudged.
  Duration get history {
    final wanted = _history ?? window * 1.5;
    return wanted < window ? window : wanted;
  }

  /// The same timings with a different window.  The history follows unless it
  /// was set deliberately.
  PlotTiming withWindow(Duration window) {
    return PlotTiming(
      window: window,
      history: _history,
      redrawInterval: redrawInterval,
      clockSlack: clockSlack,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is PlotTiming &&
        other.window == window &&
        other._history == _history &&
        other.redrawInterval == redrawInterval &&
        other.clockSlack == clockSlack;
  }

  @override
  int get hashCode => Object.hash(window, _history, redrawInterval, clockSlack);

  @override
  String toString() =>
      'PlotTiming(window: $window, history: $history, '
      'redraw: $redrawInterval, slack: $clockSlack)';
}

/// The plot durations offered as one click, in minutes.
///
/// Short enough at the bottom to watch an event arrive, long enough at the top
/// to see whether a station has been misbehaving. Anything between or beyond
/// is typed instead - these are the common answers, not the only ones.
///
/// Shared by the dropdown in the window and the dialog under Options, which
/// would otherwise drift into offering different sets of the same thing.
const List<int> quickPlotDurationsInMinutes = <int>[1, 2, 5, 10, 15];

/// The longest window that may be asked for, in minutes.
///
/// The buffer behind each plot is half as long again as the window and holds
/// every sample, so this is really a memory limit: an hour of 200 Hz data is
/// around 6 MB per stream before the history multiplier, and a plot list can
/// hold dozens of streams.
const int maximumPlotDurationInMinutes = 60;

/// A window as minutes, without a trailing .0 on the common whole minute case.
String formatPlotDurationInMinutes(Duration window) {
  final minutes = window.inMicroseconds / Duration.microsecondsPerMinute;
  return minutes == minutes.roundToDouble()
      ? minutes.round().toString()
      : minutes.toStringAsFixed(2).replaceFirst(RegExp(r'0+$'), '');
}

/// Minutes as a window, or null when the text is not one.
///
/// Rejects rather than clamps. A typed 90 that quietly became 60 would look
/// like the field had ignored the keystrokes.
Duration? parsePlotDurationInMinutes(String text) {
  final minutes = double.tryParse(text.trim());
  if (minutes == null ||
      minutes <= 0 ||
      minutes > maximumPlotDurationInMinutes) {
    return null;
  }
  return Duration(
    microseconds: (minutes * Duration.microsecondsPerMinute).round(),
  );
}
