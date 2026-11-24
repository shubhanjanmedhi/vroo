// SPDX-License-Identifier: GPL-3.0-or-later
@DefaultAsset('package:vroo_opus/src/bindings.dart')
library;

import 'dart:ffi';

import 'package:ffi/ffi.dart';

@Native<Pointer<Void> Function(Int32, Int32, Int32, Pointer<Int32>)>(symbol: 'vroo_opus_encoder_new')
external Pointer<Void> opusEncoderNew(int rate, int bitrate, int lossPercent, Pointer<Int32> error);

@Native<Int32 Function(Pointer<Void>, Pointer<Int16>, Int32, Pointer<Uint8>, Int32)>(
    symbol: 'vroo_opus_encode', isLeaf: true)
external int opusEncode(Pointer<Void> enc, Pointer<Int16> pcm, int samples, Pointer<Uint8> out, int maxBytes);

@Native<Void Function(Pointer<Void>)>(symbol: 'vroo_opus_encoder_free')
external void opusEncoderFree(Pointer<Void> enc);

@Native<Pointer<Void> Function(Int32, Pointer<Int32>)>(symbol: 'vroo_opus_decoder_new')
external Pointer<Void> opusDecoderNew(int rate, Pointer<Int32> error);

@Native<Int32 Function(Pointer<Void>, Pointer<Uint8>, Int32, Pointer<Int16>, Int32, Int32)>(
    symbol: 'vroo_opus_decode', isLeaf: true)
external int opusDecode(Pointer<Void> dec, Pointer<Uint8> data, int len, Pointer<Int16> pcm, int samples, int fec);

@Native<Void Function(Pointer<Void>)>(symbol: 'vroo_opus_decoder_free')
external void opusDecoderFree(Pointer<Void> dec);

@Native<Pointer<Utf8> Function(Int32)>(symbol: 'vroo_opus_strerror')
external Pointer<Utf8> opusStrerror(int code);
