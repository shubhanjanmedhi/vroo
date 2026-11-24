// SPDX-License-Identifier: GPL-3.0-or-later

/// How a packet reached this phone: through its box, or from the relay over mobile data.
enum RidePath { box, internet }

/// A rider this phone hears from.
class PeerInfo {
  PeerInfo({required this.id, required this.name, required this.lastHeardMs});

  final int id;
  String name;

  /// When this phone last heard from the rider, on its own [Clock.nowMs].
  int lastHeardMs;

  /// The last round trip measured with an echo; null until one comes back.
  int? rttMs;

  /// From the rider's last heartbeat: talking now, and on a phone call.
  bool talking = false, onCall = false;

  /// From the rider's last heartbeat: their box answers, and they send over mobile data.
  bool hasBox = false, hasInternet = false;

  /// The path of the rider's latest packet to arrive first.
  RidePath? lastPath;

  /// When the rider was last heard through the box, and through the relay (any copy, the first or not).
  int? lastBoxMs, lastInternetMs;
}

/// What to call each rider (GR5). Riders who share a name, this rider included, are told apart in rider-ID order:
/// "Ravi", "Ravi 2"… An empty name becomes "Rider". Never includes [myId].
Map<int, String> displayNames(Map<int, PeerInfo> peers, {required int myId, required String myName}) {
  String clean(String name) => name.trim().isEmpty ? 'Rider' : name.trim();
  final everyone = {myId: clean(myName), for (final p in peers.values) p.id: clean(p.name)};
  final byName = <String, List<int>>{};
  everyone.forEach((id, name) => byName.putIfAbsent(name.toLowerCase(), () => []).add(id));
  final out = <int, String>{};
  for (final ids in byName.values) {
    ids.sort();
    for (var k = 0; k < ids.length; k++) {
      out[ids[k]] = k == 0 ? everyone[ids[k]]! : '${everyone[ids[k]]} ${k + 1}';
    }
  }
  return out..remove(myId);
}
