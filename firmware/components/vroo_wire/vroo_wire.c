// SPDX-License-Identifier: GPL-3.0-or-later
#include "vroo_wire.h"

#include <string.h>

#define DEDUPE_PROBES 16

static uint32_t get_be32(const uint8_t *p) {
    return (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | p[3];
}

static void put_be32(uint8_t *p, uint32_t v) {
    p[0] = (uint8_t)(v >> 24);
    p[1] = (uint8_t)(v >> 16);
    p[2] = (uint8_t)(v >> 8);
    p[3] = (uint8_t)v;
}

bool vw_unwrap(const uint8_t *dgram, size_t len, const uint8_t **group_tag, const uint8_t **packet, size_t *packet_len) {
    if (len < VW_GROUP_TAG_SIZE + VW_HEADER_SIZE + VW_AEAD_TAG_SIZE) return false;
    *group_tag = dgram;
    *packet = dgram + VW_GROUP_TAG_SIZE;
    *packet_len = len - VW_GROUP_TAG_SIZE;
    return true;
}

bool vw_parse_header(const uint8_t *packet, size_t len, vw_header_t *out) {
    if (len < VW_HEADER_SIZE || packet[0] != VW_PROTOCOL_VERSION) return false;
    out->version = packet[0];
    out->type = packet[1];
    out->ttl = packet[2];
    out->src = get_be32(packet + 3);
    out->session = get_be32(packet + 7);
    out->seq = get_be32(packet + 11);
    return true;
}

void vw_dedupe_init(vw_dedupe_t *d) { memset(d, 0, sizeof *d); }

bool vw_dedupe_first(vw_dedupe_t *d, uint32_t src, uint32_t session, uint32_t seq, uint32_t now_ms) {
    uint32_t start = ((src * 2654435761u) ^ (session * 2246822519u) ^ (seq * 3266489917u)) % VW_DEDUPE_SLOTS;
    vw_dedupe_slot_t *free_slot = NULL, *oldest = NULL;
    for (uint32_t i = 0; i < DEDUPE_PROBES; i++) {
        vw_dedupe_slot_t *s = &d->slots[(start + i) % VW_DEDUPE_SLOTS];
        uint32_t age = now_ms - s->t_ms; // unsigned, so a wrapped clock still gives the right age
        bool live = s->used && age <= VW_DEDUPE_WINDOW_MS;
        if (live && s->src == src && s->session == session && s->seq == seq) return false;
        if (!live && !free_slot) free_slot = s;
        if (!oldest || age > (uint32_t)(now_ms - oldest->t_ms)) oldest = s;
    }
    vw_dedupe_slot_t *slot = free_slot ? free_slot : oldest;
    slot->src = src;
    slot->session = session;
    slot->seq = seq;
    slot->t_ms = now_ms;
    slot->used = true;
    return true;
}

bool vw_decode_box_config(const uint8_t *b, size_t len, vw_box_config_t *out) {
    if (len < 3 || b[0] != VW_BOX_MSG_VERSION || b[1] != VW_BOX_CONFIG) return false;
    vw_box_config_t c;
    memset(&c, 0, sizeof c);
    uint8_t mask = b[2];
    size_t at = 3;
    if (mask & 1) {
        if (len < at + VW_GROUP_TAG_SIZE) return false;
        memcpy(c.tag, b + at, VW_GROUP_TAG_SIZE);
        c.has_tag = true;
        at += VW_GROUP_TAG_SIZE;
    }
    if (mask & 2) {
        if (len <= at || (b[at] != 1 && b[at] != 6 && b[at] != 11)) return false;
        c.channel = b[at++];
        c.has_channel = true;
    }
    if (mask & 4) {
        if (len <= at) return false;
        size_t n = b[at++];
        if (n < 8 || n > 63 || len < at + n) return false;
        for (size_t i = 0; i < n; i++) {
            if (b[at + i] < 0x20 || b[at + i] > 0x7E) return false;
        }
        memcpy(c.password, b + at, n); // c was zeroed, so the password stays NUL-terminated
        c.has_password = true;
    }
    *out = c;
    return true;
}

size_t vw_encode_box_status(const vw_box_status_t *s, uint8_t *out, size_t cap) {
    if (cap < VW_BOX_STATUS_SIZE) return 0;
    out[0] = VW_BOX_MSG_VERSION;
    out[1] = VW_BOX_STATUS;
    put_be32(out + 2, s->box_id);
    out[6] = (uint8_t)(s->fw_version >> 8);
    out[7] = (uint8_t)s->fw_version;
    put_be32(out + 8, s->uptime_s);
    out[12] = s->setup_mode ? 1 : 0;
    out[13] = s->phones;
    put_be32(out + 14, s->rx_from_phones);
    put_be32(out + 18, s->tx_to_phones);
    put_be32(out + 22, s->drop_dup);
    put_be32(out + 26, s->drop_tag);
    return VW_BOX_STATUS_SIZE;
}
