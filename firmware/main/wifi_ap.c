// SPDX-License-Identifier: GPL-3.0-or-later
#include "wifi_ap.h"

#include <inttypes.h>
#include <stdio.h>
#include <string.h>

#include "dhcpserver/dhcpserver.h"
#include "esp_event.h"
#include "esp_log.h"
#include "esp_mac.h"
#include "esp_netif.h"
#include "esp_random.h"
#include "esp_wifi.h"

static const char *TAG = "vroo_box";

uint32_t wifi_ap_box_id(void) {
    uint8_t mac[6];
    ESP_ERROR_CHECK(esp_read_mac(mac, ESP_MAC_WIFI_SOFTAP));
    return (uint32_t)mac[2] << 24 | (uint32_t)mac[3] << 16 | (uint32_t)mac[4] << 8 | mac[5];
}

void wifi_ap_start(uint32_t box_id, const vw_box_config_t *cfg) {
    ESP_ERROR_CHECK(esp_netif_init());
    ESP_ERROR_CHECK(esp_event_loop_create_default());
    esp_netif_t *ap = esp_netif_create_default_wifi_ap();
    // Hand out addresses from a random point on each boot. iPhones silently reuse the address they had before
    // (without asking again), and a freshly restarted box would otherwise give that address to the next phone.
    uint32_t first = 2 + esp_random() % 240;
    dhcps_lease_t lease = {.enable = true};
    IP4_ADDR(&lease.start_ip, 192, 168, 4, first);
    IP4_ADDR(&lease.end_ip, 192, 168, 4, first + 9);
    ESP_ERROR_CHECK(esp_netif_dhcps_option(ap, ESP_NETIF_OP_SET, ESP_NETIF_REQUESTED_IP_ADDRESS, &lease, sizeof lease));
    ESP_LOGI(TAG, "phone addresses 192.168.4.%" PRIu32 " to .%" PRIu32, first, first + 9);
    wifi_init_config_t init = WIFI_INIT_CONFIG_DEFAULT();
    ESP_ERROR_CHECK(esp_wifi_init(&init));

    wifi_config_t wc = {.ap = {.max_connection = 4, .channel = 6, .authmode = WIFI_AUTH_OPEN}};
    int n = snprintf((char *)wc.ap.ssid, sizeof wc.ap.ssid, "%s%06" PRIX32, cfg ? "Vroo-" : "Vroo-setup-",
                     box_id & 0xFFFFFF);
    wc.ap.ssid_len = (uint8_t)n;
    if (cfg) {
        wc.ap.channel = cfg->channel;
        wc.ap.authmode = WIFI_AUTH_WPA2_PSK;
        strlcpy((char *)wc.ap.password, cfg->password, sizeof wc.ap.password);
    }
    ESP_ERROR_CHECK(esp_wifi_set_mode(WIFI_MODE_AP));
    ESP_ERROR_CHECK(esp_wifi_set_config(WIFI_IF_AP, &wc));
    ESP_ERROR_CHECK(esp_wifi_start());
    if (cfg) {
        ESP_LOGI(TAG, "normal mode ssid=%s ch=%d", (char *)wc.ap.ssid, wc.ap.channel);
    } else {
        ESP_LOGI(TAG, "setup mode ssid=%s", (char *)wc.ap.ssid);
    }
}
