# vroo_audio

Flutter plugin that carries Vroo's voice through the intercom's call link: 20 ms frames of 16 kHz mono audio in and out, call and route events, speech as audio, and keeping the app alive for the ride. The Kotlin and Swift sides stay thin, and mixing and every decision live in Dart. The design is in [architecture §4.5](../../docs/architecture.md), and the test commands are in [development.md](../../docs/development.md).

`example/` is an audio check screen for trying it on a phone.
