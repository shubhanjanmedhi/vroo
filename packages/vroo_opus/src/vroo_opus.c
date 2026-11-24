// SPDX-License-Identifier: GPL-3.0-or-later
//
// A thin layer over libopus for Dart FFI, which can't call the variadic opus_*_ctl functions. Mono only.
#include <stddef.h>
#include <stdint.h>

#include "opus.h"

#define VROO_EXPORT __attribute__((visibility("default"))) __attribute__((used))

// A voice encoder: VOIP, VBR, in-band FEC tuned for [loss_percent] expected loss. NULL on failure, with *error set.
VROO_EXPORT void *vroo_opus_encoder_new(int32_t rate, int32_t bitrate, int32_t loss_percent, int32_t *error) {
    int err;
    OpusEncoder *enc = opus_encoder_create(rate, 1, OPUS_APPLICATION_VOIP, &err);
    if (err == OPUS_OK) err = opus_encoder_ctl(enc, OPUS_SET_BITRATE(bitrate));
    if (err == OPUS_OK) err = opus_encoder_ctl(enc, OPUS_SET_VBR(1));
    if (err == OPUS_OK) err = opus_encoder_ctl(enc, OPUS_SET_INBAND_FEC(1));
    if (err == OPUS_OK) err = opus_encoder_ctl(enc, OPUS_SET_PACKET_LOSS_PERC(loss_percent));
    if (err == OPUS_OK) err = opus_encoder_ctl(enc, OPUS_SET_SIGNAL(OPUS_SIGNAL_VOICE));
    *error = err;
    if (err != OPUS_OK && enc) {
        opus_encoder_destroy(enc);
        enc = NULL;
    }
    return enc;
}

// Bytes written to [out], or a negative libopus error.
VROO_EXPORT int32_t vroo_opus_encode(void *enc, const int16_t *pcm, int32_t samples, uint8_t *out, int32_t max_bytes) {
    return opus_encode((OpusEncoder *)enc, pcm, samples, out, max_bytes);
}

VROO_EXPORT void vroo_opus_encoder_free(void *enc) { opus_encoder_destroy((OpusEncoder *)enc); }

VROO_EXPORT void *vroo_opus_decoder_new(int32_t rate, int32_t *error) {
    int err;
    OpusDecoder *dec = opus_decoder_create(rate, 1, &err);
    *error = err;
    return err == OPUS_OK ? dec : NULL;
}

// Samples decoded, or a negative libopus error. NULL [data] conceals a lost frame; [fec] rebuilds the frame before
// [data] from its in-band FEC.
VROO_EXPORT int32_t vroo_opus_decode(void *dec, const uint8_t *data, int32_t len, int16_t *pcm, int32_t samples,
                                     int32_t fec) {
    return opus_decode((OpusDecoder *)dec, data, len, pcm, samples, fec);
}

VROO_EXPORT void vroo_opus_decoder_free(void *dec) { opus_decoder_destroy((OpusDecoder *)dec); }

VROO_EXPORT const char *vroo_opus_strerror(int32_t code) { return opus_strerror(code); }
