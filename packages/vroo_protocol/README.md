# vroo_protocol

Protocol v1 in pure Dart, shared by the app, the relay server and the simulator: key derivation, invites, packets, encryption, the envelope, dedupe and box messages. The design is in [architecture §5](../../docs/architecture.md).

- **Tests:** `dart test`.
- **Test vectors:** `tool/oracle.py` computes them independently with Python's `cryptography`, and `tool/gen_c_vectors.dart` writes them out for the firmware's host tests.
- **Bench probe:** `tool/box_probe.dart` checks a real box from a Mac ([development.md](../../docs/development.md)).
