# Contributing to Vroo

Thanks for helping. This project is young, so the most useful contributions right now are:

- **Code:** Flutter, Swift, Kotlin, and ESP32 firmware in C on ESP-IDF.
- **Tests:** on-device testing with real intercoms, and range tests on bikes.
- **Writing:** clear docs and review of the design.

## Before you start

1. Read [docs/spec.md](docs/spec.md) for *what* the app does, and [docs/architecture.md](docs/architecture.md) for *how*.
2. For anything bigger than a small fix, open an issue first and describe the change. Design questions get settled before code is written.
3. Check [docs/todo.md](docs/todo.md) and the plans in `docs/superpowers/plans/` to see what's being worked on.

## Docs first

- **Behaviour changes:** if a change alters what the app does or how it's built, update the spec or architecture in the same pull request.
- **Design decisions:** the docs refer to them by number, such as D26. The decision log itself isn't public, so if your change alters a decision, explain why in the issue or pull request.
- **Protocol changes:** changes to protocol v1 (packets, crypto, envelope, box messages) also need new test vectors. Regenerate them with `packages/vroo_protocol/tool/oracle.py` and `packages/vroo_protocol/tool/gen_c_vectors.dart`.

## Development

[docs/development.md](docs/development.md) covers setting up the toolchain (Flutter, Xcode, Android SDK, ESP-IDF) and running the app, tests and firmware. Every pull request keeps every command under its **Tests** heading passing.

Write the failing test first, then the code. Keep native (Swift and Kotlin) code thin: it moves bytes and audio frames, and all decisions live in Dart.

## Style

- **Dart:** `dart analyze` with no warnings. Lines run up to 120 characters: match the code around your change, and don't run `dart format` over whole files, which would rewrap them.
- **C:** C99. The box firmware never decrypts anything and never holds the group key.
- **Commit messages:** in the form `type(scope): summary`, for example `feat(net): Android box join` or `docs: Plan A bench results`.
- **Pull requests:** small and focused. Say what you tested, and on which phones, intercoms and boards.

## Testing on real hardware

Simulators can't test intercom audio, Wi-Fi to the box or box radios. If you test on devices, add your results to [docs/test-plan.md](docs/test-plan.md) §5: date, phones, intercoms, boards, what passed and what failed. Leave out anything personal: phone serial numbers, hardware addresses, Wi-Fi names and passwords.

Safety: never touch a phone or box while riding. Test settings at stops, on quiet roads, within traffic law.

## Conduct and security

- Everyone taking part follows the [Code of Conduct](CODE_OF_CONDUCT.md).
- Report security problems privately, as described in [SECURITY.md](SECURITY.md), not in public issues.

## Licences, the CLA and dependencies

- **Your licence:** contributions are licensed under the licence of the part they change.
  - GPL-3.0-or-later for the app, plugins, protocol, firmware, simulator and tools.
  - AGPL-3.0-or-later for `server/`.
  - CC BY-SA 4.0 for docs and the box design.
- **The Contributor Licence Agreement:** Vroo's owner also offers paid licences to companies. So before your first pull request is merged, you agree to [CLA.md](CLA.md) by commenting "I have read CLA.md and I agree to it." You keep your copyright.
- **New source files** start with an SPDX line, for example `// SPDX-License-Identifier: GPL-3.0-or-later`. In `server/`, use `AGPL-3.0-or-later`.
- **Dependencies must have permissive licences,** such as MIT, BSD, Apache-2.0, zlib or ISC, so Vroo can be licensed closed as well as open.
  - No GPL, LGPL or AGPL dependencies, and no proprietary SDKs, such as Google ML Kit, Firebase or closed analytics.
  - When you add a dependency, note its licence in the pull request.
- **Patents:** new techniques belong in [docs/defensive-publication.md](docs/defensive-publication.md), so they become public prior art.
