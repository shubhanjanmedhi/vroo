// SPDX-License-Identifier: GPL-3.0-or-later
#include "bridge.h"

#include <errno.h>
#include <stdlib.h>
#include <string.h>

#include "config.h"
#include "esp_log.h"
#include "esp_system.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "led.h"
#include "lwip/sockets.h"

#define DATA_PORT 47000
#define CONTROL_PORT 47001
#define MAX_PHONES 4
#define PHONE_TIMEOUT_US (30 * 1000000LL)
#define STATUS_EVERY_US 1000000LL
#define FW_VERSION 1

static const char *TAG = "vroo_box";

typedef struct {
    uint32_t ip;   // network byte order
    uint16_t port; // network byte order
    int64_t heard_us;
    bool used;
} phone_t;

static struct {
    uint32_t box_id;
    bool setup_mode;
    vw_box_config_t cfg;
    phone_t phones[MAX_PHONES];
    vw_dedupe_t dedupe;
    vw_box_status_t counts; // only the packet counters are kept here; the rest is filled in when sent
    int data_sock, control_sock;
} s;

static bool phone_live(const phone_t *p, int64_t now) { return p->used && now - p->heard_us <= PHONE_TIMEOUT_US; }

static bool phone_is(const phone_t *p, const struct sockaddr_in *a) {
    return p->used && p->ip == a->sin_addr.s_addr && p->port == a->sin_port;
}

// Refreshes the sender's entry. A new sender takes a free or expired entry, else the least recently heard.
static void phone_heard(const struct sockaddr_in *from, int64_t now) {
    phone_t *slot = NULL;
    for (int i = 0; i < MAX_PHONES && !slot; i++) {
        if (phone_is(&s.phones[i], from)) slot = &s.phones[i];
    }
    for (int i = 0; i < MAX_PHONES && !slot; i++) {
        if (!phone_live(&s.phones[i], now)) slot = &s.phones[i];
    }
    if (!slot) {
        slot = &s.phones[0];
        for (int i = 1; i < MAX_PHONES; i++) {
            if (s.phones[i].heard_us < slot->heard_us) slot = &s.phones[i];
        }
    }
    slot->ip = from->sin_addr.s_addr;
    slot->port = from->sin_port;
    slot->heard_us = now;
    slot->used = true;
}

static uint8_t phones_live(int64_t now) {
    uint8_t n = 0;
    for (int i = 0; i < MAX_PHONES; i++) n += phone_live(&s.phones[i], now);
    return n;
}

static void send_to_phone(int sock, const phone_t *p, const uint8_t *buf, size_t len) {
    struct sockaddr_in to = {.sin_family = AF_INET, .sin_port = p->port, .sin_addr.s_addr = p->ip};
    sendto(sock, buf, len, 0, (struct sockaddr *)&to, sizeof to);
}

static size_t status_bytes(uint8_t *out, int64_t now) {
    vw_box_status_t st = s.counts;
    st.box_id = s.box_id;
    st.fw_version = FW_VERSION;
    st.uptime_s = (uint32_t)(now / 1000000);
    st.setup_mode = s.setup_mode;
    st.phones = phones_live(now);
    return vw_encode_box_status(&st, out, VW_BOX_STATUS_SIZE);
}

static void on_data(int64_t now) {
    static uint8_t buf[1500];
    struct sockaddr_in from;
    socklen_t from_len = sizeof from;
    int n = recvfrom(s.data_sock, buf, sizeof buf, 0, (struct sockaddr *)&from, &from_len);
    if (n < 0 || from.sin_family != AF_INET) return;
    phone_heard(&from, now);
    s.counts.rx_from_phones++;
    const uint8_t *tag, *packet;
    size_t packet_len;
    vw_header_t h;
    // Not this group's, or not protocol v1: either way it isn't ours to pass on.
    if (s.setup_mode || !s.cfg.has_tag || !vw_unwrap(buf, (size_t)n, &tag, &packet, &packet_len) ||
        memcmp(tag, s.cfg.tag, VW_GROUP_TAG_SIZE) != 0 || !vw_parse_header(packet, packet_len, &h)) {
        s.counts.drop_tag++;
        return;
    }
    if (!vw_dedupe_first(&s.dedupe, h.src, h.session, h.seq, (uint32_t)(now / 1000))) {
        s.counts.drop_dup++;
        return;
    }
    for (int i = 0; i < MAX_PHONES; i++) {
        if (!phone_live(&s.phones[i], now) || phone_is(&s.phones[i], &from)) continue;
        send_to_phone(s.data_sock, &s.phones[i], buf, (size_t)n);
        s.counts.tx_to_phones++;
    }
}

static void on_control(int64_t now) {
    uint8_t buf[128];
    struct sockaddr_in from;
    socklen_t from_len = sizeof from;
    int n = recvfrom(s.control_sock, buf, sizeof buf, 0, (struct sockaddr *)&from, &from_len);
    if (n < 0 || from.sin_family != AF_INET) return;
    phone_heard(&from, now);
    vw_box_config_t c;
    if (!vw_decode_box_config(buf, (size_t)n, &c) || (s.setup_mode && !c.has_password)) return;
    bool restart = s.setup_mode || (c.has_channel && c.channel != s.cfg.channel) ||
                   (c.has_password && strcmp(c.password, s.cfg.password) != 0);
    if (c.has_tag) {
        memcpy(s.cfg.tag, c.tag, sizeof c.tag);
        s.cfg.has_tag = true;
    }
    if (c.has_channel) s.cfg.channel = c.channel;
    if (c.has_password) {
        memcpy(s.cfg.password, c.password, sizeof c.password);
        s.cfg.has_password = true;
    }
    config_save(&s.cfg);
    uint8_t status[VW_BOX_STATUS_SIZE];
    sendto(s.control_sock, status, status_bytes(status, now), 0, (struct sockaddr *)&from, sizeof from);
    if (!restart) {
        ESP_LOGI(TAG, "config saved");
        return;
    }
    ESP_LOGI(TAG, "config saved, restarting");
    vTaskDelay(pdMS_TO_TICKS(300)); // let the status reply leave first
    esp_restart();
}

static int udp_socket(uint16_t port) {
    int sock = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    struct sockaddr_in addr = {.sin_family = AF_INET, .sin_port = htons(port), .sin_addr.s_addr = htonl(INADDR_ANY)};
    if (sock < 0 || bind(sock, (struct sockaddr *)&addr, sizeof addr) != 0) {
        ESP_LOGE(TAG, "udp port %u: errno %d", port, errno);
        abort();
    }
    return sock;
}

static void bridge_task(void *arg) {
    (void)arg;
    s.data_sock = udp_socket(DATA_PORT);
    s.control_sock = udp_socket(CONTROL_PORT);
    int64_t next_status = esp_timer_get_time() + STATUS_EVERY_US;
    for (;;) {
        int64_t now = esp_timer_get_time();
        if (now >= next_status) {
            uint8_t status[VW_BOX_STATUS_SIZE];
            size_t len = status_bytes(status, now);
            for (int i = 0; i < MAX_PHONES; i++) {
                if (phone_live(&s.phones[i], now)) send_to_phone(s.control_sock, &s.phones[i], status, len);
            }
            led_set(s.setup_mode ? LED_SETUP : phones_live(now) ? LED_PHONE : LED_NO_PHONE);
            next_status = now + STATUS_EVERY_US;
        }
        int64_t wait_us = next_status - now;
        struct timeval tv = {.tv_sec = (time_t)(wait_us / 1000000), .tv_usec = (suseconds_t)(wait_us % 1000000)};
        fd_set ready;
        FD_ZERO(&ready);
        FD_SET(s.data_sock, &ready);
        FD_SET(s.control_sock, &ready);
        int max_fd = s.data_sock > s.control_sock ? s.data_sock : s.control_sock;
        if (select(max_fd + 1, &ready, NULL, NULL, &tv) <= 0) continue;
        now = esp_timer_get_time();
        if (FD_ISSET(s.data_sock, &ready)) on_data(now);
        if (FD_ISSET(s.control_sock, &ready)) on_control(now);
    }
}

void bridge_start(uint32_t box_id, const vw_box_config_t *cfg, bool setup_mode) {
    s.box_id = box_id;
    s.cfg = *cfg;
    s.setup_mode = setup_mode;
    vw_dedupe_init(&s.dedupe);
    xTaskCreate(bridge_task, "bridge", 4096, NULL, 5, NULL);
}
