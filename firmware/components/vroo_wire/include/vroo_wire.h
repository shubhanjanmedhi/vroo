// SPDX-License-Identifier: GPL-3.0-or-later
//
// vroo_wire: the parts of protocol v1 a box needs (docs/architecture.md §5.2): envelope and header parsing,
// dedupe, and box messages. Plain C99 with no ESP-IDF includes, so the host tests build it too.
#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define VW_PROTOCOL_VERSION 1
#define VW_HEADER_SIZE 15
#define VW_AEAD_TAG_SIZE 16
#define VW_GROUP_TAG_SIZE 8
#define VW_DEDUPE_WINDOW_MS 10000
#define VW_DEDUPE_SLOTS 2048
#define VW_BOX_MSG_VERSION 1
#define VW_BOX_CONFIG 0x10
#define VW_BOX_STATUS 0x11
#define VW_BOX_STATUS_SIZE 30

typedef struct { uint8_t version, type, ttl; uint32_t src, session, seq; } vw_header_t;

// Splits an envelope into groupTag and packet. False if it's too short to hold a sealed packet (39 bytes).
bool vw_unwrap(const uint8_t *dgram, size_t len, const uint8_t **group_tag, const uint8_t **packet, size_t *packet_len);

// False if the packet is shorter than a header or isn't protocol v1.
bool vw_parse_header(const uint8_t *packet, size_t len, vw_header_t *out);

typedef struct { uint32_t src, session, seq, t_ms; bool used; } vw_dedupe_slot_t;
typedef struct { vw_dedupe_slot_t slots[VW_DEDUPE_SLOTS]; } vw_dedupe_t;

void vw_dedupe_init(vw_dedupe_t *d);

// True for the first copy of packet (src, session, seq) within the window. now_ms may wrap around.
bool vw_dedupe_first(vw_dedupe_t *d, uint32_t src, uint32_t session, uint32_t seq, uint32_t now_ms);

typedef struct { bool has_tag, has_channel, has_password; uint8_t tag[8]; uint8_t channel; char password[64]; } vw_box_config_t;

// False, leaving *out untouched, unless b is a well-formed BOX_CONFIG holding values the box accepts:
// channel 1, 6 or 11, and a password of 8-63 printable ASCII characters.
bool vw_decode_box_config(const uint8_t *b, size_t len, vw_box_config_t *out);

typedef struct { uint32_t box_id; uint16_t fw_version; uint32_t uptime_s; bool setup_mode; uint8_t phones;
                 uint32_t rx_from_phones, tx_to_phones, drop_dup, drop_tag; } vw_box_status_t;

// Writes BOX_STATUS and returns its size (30), or returns 0 if cap is smaller than that.
size_t vw_encode_box_status(const vw_box_status_t *s, uint8_t *out, size_t cap);
