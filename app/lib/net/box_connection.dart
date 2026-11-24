// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:vroo_net/vroo_net.dart';

enum BoxConnectionState { idle, joining, joined, needsManualJoin, denied }

/// After the box's network is lost, the first request waits this long, so the phone can rejoin by itself first.
const _firstRejoinAfter = Duration(seconds: 10);

/// Then the phone is asked again this often, unless a request is still waiting for its answer. Until requests name
/// the box's BSSID, each Android request shows the Connect prompt (bench, 2026-10-27).
const _rejoinEvery = Duration(seconds: 5);

/// Keeps the phone on its box's Wi-Fi: joins, then follows the box's network as it comes and goes, asking again while
/// it's gone.
/// - A new request never replaces one still waiting: Android would withdraw the first, prompt and all.
/// - "Join it in Settings" is the rider's to act on, and so is "denied" on the first join. Once the box has been
///   joined, a denied or failed request is tried again: on Android, "denied" also means nothing was found in 60 s,
///   for example while the bike is off.
/// - Being on the box's network counts as joined, however the phone got there.
class BoxConnection {
  BoxConnection({required this.net, required this.ssid, required this.password});

  final VrooNet net;
  final String ssid;
  final String password;

  final _state = ValueNotifier(BoxConnectionState.idle);
  StreamSubscription<NetEvent>? _events;
  Timer? _retry;
  bool _asking = false, _onBoxNetwork = false, _everJoined = false;

  ValueListenable<BoxConnectionState> get state => _state;

  Future<void> start() async {
    _events = net.events.listen(_onEvent);
    await _join();
  }

  Future<void> stop() async {
    _stopRetrying();
    unawaited(_events?.cancel());
    _events = null;
    _state.value = BoxConnectionState.idle;
    await net.leaveBox();
  }

  void _onEvent(NetEvent e) {
    if (e is! BoxNetworkChanged) return;
    _onBoxNetwork = e.available;
    if (e.available) {
      _joined(); // the phone rejoined by itself, or the rider joined in Settings
    } else if (_state.value == BoxConnectionState.joined) {
      _state.value = BoxConnectionState.joining;
      _retryLater(_firstRejoinAfter);
    }
  }

  Future<void> _join() async {
    if (_asking) return;
    _asking = true;
    if (_state.value == BoxConnectionState.idle) _state.value = BoxConnectionState.joining;
    final JoinOutcome outcome;
    try {
      outcome = await net.joinBox(ssid: ssid, password: password);
    } finally {
      _asking = false;
    }
    if (_events == null) return; // stopped meanwhile
    if (_onBoxNetwork || outcome == JoinOutcome.joined) {
      _joined();
      return;
    }
    switch (outcome) {
      case JoinOutcome.needsManualJoin:
        _stopRetrying();
        _state.value = BoxConnectionState.needsManualJoin;
      case JoinOutcome.denied when !_everJoined:
        _stopRetrying();
        _state.value = BoxConnectionState.denied;
      case _:
        _state.value = BoxConnectionState.joining;
        _retryLater(_rejoinEvery);
    }
  }

  void _joined() {
    _stopRetrying();
    _everJoined = true;
    _state.value = BoxConnectionState.joined;
  }

  void _retryLater(Duration first) => _retry ??= Timer(first, () {
        _retry = Timer.periodic(_rejoinEvery, (_) => _join());
        _join();
      });

  void _stopRetrying() {
    _retry?.cancel();
    _retry = null;
  }
}
