// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vroo/net/box_connection.dart';
import 'package:vroo_net/vroo_net.dart';

BoxConnection connect(FakeVrooNet net) =>
    BoxConnection(net: net, ssid: 'Vroo-A1B2C3', password: 'abcd-efgh-jkmn-pqrs')..start();

void main() {
  test('rejoins 10 s after the box network is lost, then every 5 s, until it is back', () => fakeAsync((fa) {
        final net = FakeVrooNet();
        final c = connect(net);
        fa.flushMicrotasks();
        expect(c.state.value, BoxConnectionState.joined);
        net.nextJoinOutcome = JoinOutcome.failed; // the box isn't back yet
        net.emit(BoxNetworkChanged(false));
        fa.elapse(const Duration(seconds: 9));
        expect(net.joins.length, 1); // waits first, in case the phone rejoins by itself
        fa.elapse(const Duration(seconds: 7));
        expect(net.joins.length, 3); // at 10 and 15 s
        net.emit(BoxNetworkChanged(true));
        fa.elapse(const Duration(seconds: 11));
        expect(net.joins.length, 3); // back: no more requests
        expect(c.state.value, BoxConnectionState.joined);
      }));
  test('a join still waiting for the rider is not withdrawn', () => fakeAsync((fa) {
        final net = FakeVrooNet();
        final c = connect(net);
        fa.flushMicrotasks();
        net.joinDelay = const Duration(seconds: 8); // Android's prompt, then the rider reads it and taps Connect
        net.emit(BoxNetworkChanged(false));
        fa.elapse(const Duration(seconds: 40));
        expect(c.state.value, BoxConnectionState.joined);
        expect(net.joins.length, 2); // one request after the loss, left to finish
      }));
  test('after a loss, a request that times out is tried again', () => fakeAsync((fa) {
        final net = FakeVrooNet();
        final c = connect(net);
        fa.flushMicrotasks();
        net.nextJoinOutcome = JoinOutcome.denied; // Android reports "no box within 60 s" this way
        net.emit(BoxNetworkChanged(false));
        fa.elapse(const Duration(seconds: 21));
        expect(c.state.value, BoxConnectionState.joining);
        expect(net.joins.length, 4); // the first join, then at 10, 15 and 20 s
      }));
  test('a joined answer stops the requests', () => fakeAsync((fa) {
        final net = FakeVrooNet();
        final c = connect(net);
        fa.flushMicrotasks();
        net.emit(BoxNetworkChanged(false));
        fa.elapse(const Duration(seconds: 30));
        expect(net.joins.length, 2); // the first join, and the one at 10 s that answered joined
        expect(c.state.value, BoxConnectionState.joined);
      }));
  test('a join made in Settings counts as joined', () => fakeAsync((fa) {
        final net = FakeVrooNet()..nextJoinOutcome = JoinOutcome.needsManualJoin;
        final c = connect(net);
        fa.flushMicrotasks();
        expect(c.state.value, BoxConnectionState.needsManualJoin);
        net.emit(BoxNetworkChanged(true));
        fa.flushMicrotasks();
        expect(c.state.value, BoxConnectionState.joined);
      }));
  test('a Settings join that lands before the join answer stays joined', () => fakeAsync((fa) {
        final net = FakeVrooNet()
          ..nextJoinOutcome = JoinOutcome.needsManualJoin
          ..joinDelay = const Duration(seconds: 1);
        final c = connect(net);
        fa.elapse(const Duration(milliseconds: 500));
        net.emit(BoxNetworkChanged(true)); // iOS: the phone is already on the box's Wi-Fi
        fa.elapse(const Duration(seconds: 1));
        expect(c.state.value, BoxConnectionState.joined);
      }));
  for (final (outcome, state) in [
    (JoinOutcome.needsManualJoin, BoxConnectionState.needsManualJoin),
    (JoinOutcome.denied, BoxConnectionState.denied),
  ]) {
    test('$outcome on the first join is reported, not retried', () => fakeAsync((fa) {
          final net = FakeVrooNet()..nextJoinOutcome = outcome;
          final c = connect(net);
          fa.elapse(const Duration(seconds: 11));
          expect(c.state.value, state);
          expect(net.joins.length, 1);
        }));
  }
}
