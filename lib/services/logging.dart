import 'dart:developer' as developer;

import 'package:flutter/foundation.dart' show kReleaseMode;
import 'package:logging/logging.dart';

export 'package:logging/logging.dart' show Logger, Level;

/// Wires `package:logging` up to somewhere the records can actually be seen.
///
/// Records go to `dart:developer`'s [developer.log] rather than to `print`, so
/// they arrive in DevTools and the IDE's debug console with their level, logger
/// name and stack trace intact instead of as a bare line of text. `print` also
/// truncates on some platforms, which is exactly the wrong behaviour for the
/// stack trace attached to a decode failure.
///
/// Call once, before `runApp`. Calling it twice would attach a second listener
/// and double every record, so repeat calls are ignored - tests that build the
/// app more than once would otherwise get noisier with each one.
///
/// A release build keeps warnings and above. Everything below is per-packet or
/// per-frame chatter that costs time to format and helps nobody once the app is
/// shipped.
void setUpLogging({Level? level}) {
  if (_configured) {
    return;
  }
  _configured = true;
  Logger.root.level = level ?? (kReleaseMode ? Level.WARNING : Level.INFO);
  Logger.root.onRecord.listen((record) {
    developer.log(
      record.message,
      time: record.time,
      sequenceNumber: record.sequenceNumber,
      level: record.level.value,
      name: record.loggerName,
      error: record.error,
      stackTrace: record.stackTrace,
    );
  });
}

bool _configured = false;
