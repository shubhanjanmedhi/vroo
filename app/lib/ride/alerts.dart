// SPDX-License-Identifier: GPL-3.0-or-later
import '../net/peer.dart';

export '../net/peer.dart' show displayNames;

/// Something to play in the helmet.
sealed class Alert {}

final class Say extends Alert {
  Say(this.text);

  final String text;
}

/// The short tone before "[Name] is back".
final class BackTone extends Alert {}

const _lostMs = 4000; // 4 heartbeat intervals (architecture §5.4)
const _aloneRepeatMs = 60000;
const _boxWarnMs = 10000;
const _bigGroup = 10;

/// The spoken messages of spec 7.5, worked out from what the box link sees. Call [update] once a second.
class Alerts {
  final _known = <int>{}, _dropped = <int>{}, _onCall = <int>{};
  int? _lastAloneSaidMs, _boxDownSinceMs;
  bool _boxWarned = false, _clocksSaid = false;

  /// The messages to play now, in order. [peers] are on the same clock as [nowMs]; [names] come from
  /// [displayNames]. [clockGap]: some rider is cut off by the clock check. During the rider's own call ([myCall])
  /// nothing is returned, but the state moves on, so nothing replays afterwards.
  List<Alert> update({
    required Map<int, PeerInfo> peers,
    required Map<int, String> names,
    required bool boxUp,
    required bool myCall,
    bool clockGap = false,
    required int nowMs,
  }) {
    final perRider = <Alert>[], own = <Alert>[];
    String name(int id) => names[id] ?? 'Rider';
    for (final p in peers.values) {
      final reachable = nowMs - p.lastHeardMs <= _lostMs;
      if (_known.add(p.id)) {
        perRider.add(Say('${name(p.id)} joined'));
      } else if (!reachable && _dropped.add(p.id)) {
        perRider.add(Say('${name(p.id)} dropped off'));
      } else if (reachable && _dropped.remove(p.id)) {
        perRider.addAll([BackTone(), Say('${name(p.id)} is back')]);
      }
      if (!reachable) continue;
      if (p.onCall && _onCall.add(p.id)) perRider.add(Say('${name(p.id)} is on a call'));
      if (!p.onCall && _onCall.remove(p.id)) perRider.add(Say('${name(p.id)} is off the call'));
    }

    // Lost the group: only once someone has been heard this ride, so the first rider to start isn't told.
    final alone = _known.isNotEmpty && !peers.values.any((p) => nowMs - p.lastHeardMs <= _lostMs);
    final lastAlone = _lastAloneSaidMs;
    if (!alone) {
      _lastAloneSaidMs = null;
    } else if (lastAlone == null || nowMs - lastAlone >= _aloneRepeatMs) {
      own.add(Say("You've lost the group. Move closer to the others."));
      _lastAloneSaidMs = nowMs;
    }

    // Hearing nobody because of the clocks: otherwise the ride is silent with nothing said, as nobody was ever heard.
    if (clockGap && !_clocksSaid && !peers.values.any((p) => nowMs - p.lastHeardMs <= _lostMs)) {
      own.add(Say('The phone clocks are too far apart to hear each other. '
          'Check the date and time are set to automatic.'));
      _clocksSaid = true;
    }

    if (boxUp) {
      _boxDownSinceMs = null;
      _boxWarned = false;
    } else if (!_boxWarned && nowMs - (_boxDownSinceMs ??= nowMs) >= _boxWarnMs) {
      own.add(Say('Your box is disconnected'));
      _boxWarned = true;
    }

    if (myCall) return const [];
    return [if (1 + peers.length <= _bigGroup) ...perRider, ...own];
  }
}
