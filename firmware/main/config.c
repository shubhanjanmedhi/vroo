// SPDX-License-Identifier: GPL-3.0-or-later
#include "config.h"

#include <string.h>

#include "nvs.h"
#include "nvs_flash.h"

#define NAMESPACE "vroo"

void config_init(void) {
    esp_err_t err = nvs_flash_init();
    if (err == ESP_ERR_NVS_NO_FREE_PAGES || err == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        ESP_ERROR_CHECK(nvs_flash_erase());
        err = nvs_flash_init();
    }
    ESP_ERROR_CHECK(err);
}

bool config_load(vw_box_config_t *c) {
    memset(c, 0, sizeof *c);
    c->channel = 6;
    c->has_channel = true;
    nvs_handle_t h;
    if (nvs_open(NAMESPACE, NVS_READONLY, &h) != ESP_OK) return false; // nothing saved yet
    size_t len = sizeof c->password;
    c->has_password = nvs_get_str(h, "pw", c->password, &len) == ESP_OK && c->password[0] != '\0';
    len = sizeof c->tag;
    c->has_tag = nvs_get_blob(h, "tag", c->tag, &len) == ESP_OK && len == sizeof c->tag;
    uint8_t ch;
    if (nvs_get_u8(h, "ch", &ch) == ESP_OK && (ch == 1 || ch == 6 || ch == 11)) c->channel = ch;
    nvs_close(h);
    if (!c->has_password) c->password[0] = '\0';
    return c->has_password;
}

void config_save(const vw_box_config_t *c) {
    nvs_handle_t h;
    ESP_ERROR_CHECK(nvs_open(NAMESPACE, NVS_READWRITE, &h));
    if (c->has_password) ESP_ERROR_CHECK(nvs_set_str(h, "pw", c->password));
    if (c->has_tag) ESP_ERROR_CHECK(nvs_set_blob(h, "tag", c->tag, sizeof c->tag));
    ESP_ERROR_CHECK(nvs_set_u8(h, "ch", c->channel));
    ESP_ERROR_CHECK(nvs_commit(h));
    nvs_close(h);
}

void config_erase(void) {
    nvs_handle_t h;
    if (nvs_open(NAMESPACE, NVS_READWRITE, &h) != ESP_OK) return;
    nvs_erase_all(h);
    nvs_commit(h);
    nvs_close(h);
}
