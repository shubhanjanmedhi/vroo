// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:clock/clock.dart' as c;

abstract interface class Clock {
  /// Milliseconds on a monotonic clock, for intervals and round trips.
  int nowMs();

  /// Wall-clock time in UTC, for log stamps.
  DateTime wallNow();
}

/// The real clock. It reads package:clock, so code using it runs on fake time inside fakeAsync.
class SystemClock implements Clock {
  final _watch = c.clock.stopwatch()..start();

  @override
  int nowMs() => _watch.elapsedMilliseconds;

  @override
  DateTime wallNow() => c.clock.now().toUtc();
}

/// A clock that moves only when a test sets it.
class FakeClock implements Clock {
  FakeClock({required this.ms, required this.wall});

  int ms;
  DateTime wall;

  @override
  int nowMs() => ms;

  @override
  DateTime wallNow() => wall;
}
