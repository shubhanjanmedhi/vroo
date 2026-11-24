// SPDX-License-Identifier: GPL-3.0-or-later

/// The Opus voice codec for 20 ms mono frames: libopus 1.5.2, compiled from source by this package's build hook.
library;

import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'src/bindings.dart' as c;

export 'src/libopus_license.dart';

/// The largest Opus packet.
const _maxPacketBytes = 1275;

class OpusException implements Exception {
  OpusException(this.code) : message = c.opusStrerror(code).toDartString();

  final int code;
  final String message;

  @override
  String toString() => 'OpusException($code): $message';
}

/// Encodes 20 ms frames of mono 16-bit audio for voice: VOIP, VBR, and in-band FEC for the expected loss.
class OpusEncoder {
  OpusEncoder({int sampleRate = 16000, int bitrate = 16000, int expectedLossPercent = 10})
      : frameSamples = sampleRate ~/ 50 {
    final error = malloc<Int32>();
    try {
      _enc = c.opusEncoderNew(sampleRate, bitrate, expectedLossPercent, error);
      if (_enc == nullptr) throw OpusException(error.value);
    } finally {
      malloc.free(error);
    }
    _pcm = malloc<Int16>(frameSamples);
    _out = malloc<Uint8>(_maxPacketBytes);
  }

  /// Samples in one 20 ms frame.
  final int frameSamples;
  late final Pointer<Void> _enc;
  late final Pointer<Int16> _pcm;
  late final Pointer<Uint8> _out;
  bool _closed = false;

  /// One frame of [frameSamples] samples to one Opus packet.
  Uint8List encode(Int16List frame) {
    if (_closed) throw StateError('OpusEncoder is closed');
    if (frame.length != frameSamples) {
      throw ArgumentError.value(frame.length, 'frame', 'must be $frameSamples samples');
    }
    _pcm.asTypedList(frameSamples).setAll(0, frame);
    final n = c.opusEncode(_enc, _pcm, frameSamples, _out, _maxPacketBytes);
    if (n < 0) throw OpusException(n);
    return Uint8List.fromList(_out.asTypedList(n));
  }

  /// Frees the encoder. Safe to call twice.
  void close() {
    if (_closed) return;
    _closed = true;
    c.opusEncoderFree(_enc);
    malloc
      ..free(_pcm)
      ..free(_out);
  }
}

/// Decodes one sender's Opus packets into 20 ms frames.
class OpusDecoder {
  OpusDecoder({int sampleRate = 16000}) : frameSamples = sampleRate ~/ 50 {
    final error = malloc<Int32>();
    try {
      _dec = c.opusDecoderNew(sampleRate, error);
      if (_dec == nullptr) throw OpusException(error.value);
    } finally {
      malloc.free(error);
    }
    _in = malloc<Uint8>(_maxPacketBytes);
    _pcm = malloc<Int16>(frameSamples);
  }

  /// Samples in one 20 ms frame.
  final int frameSamples;
  late final Pointer<Void> _dec;
  late final Pointer<Uint8> _in;
  late final Pointer<Int16> _pcm;
  bool _closed = false;

  /// One frame from [packet]. A null [packet] conceals one lost frame. With [fec], it rebuilds the frame before
  /// [packet] from the FEC data inside [packet]. OpusException for a packet libopus can't decode.
  Int16List decode(Uint8List? packet, {bool fec = false}) {
    if (_closed) throw StateError('OpusDecoder is closed');
    if (packet != null) {
      if (packet.length > _maxPacketBytes) throw OpusException(-4); // OPUS_INVALID_PACKET
      _in.asTypedList(packet.length).setAll(0, packet);
    }
    final n = c.opusDecode(_dec, packet == null ? nullptr : _in, packet?.length ?? 0, _pcm, frameSamples, fec ? 1 : 0);
    if (n < 0) throw OpusException(n);
    return Int16List.fromList(_pcm.asTypedList(n));
  }

  /// Frees the decoder. Safe to call twice.
  void close() {
    if (_closed) return;
    _closed = true;
    c.opusDecoderFree(_dec);
    malloc
      ..free(_in)
      ..free(_pcm);
  }
}
