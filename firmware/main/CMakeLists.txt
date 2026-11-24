# SPDX-License-Identifier: GPL-3.0-or-later
idf_component_register(
    SRCS "main.c" "config.c" "wifi_ap.c" "bridge.c" "led.c" "button.c"
    INCLUDE_DIRS "."
    PRIV_REQUIRES vroo_wire esp_wifi esp_netif esp_event esp_timer nvs_flash lwip esp_driver_gpio)
