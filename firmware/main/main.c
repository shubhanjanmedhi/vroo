// SPDX-License-Identifier: GPL-3.0-or-later
//
// Vroo box firmware (docs/hardware.md): a hotspot for its own phones that bridges their same-group packets.
// It runs in setup mode until a phone saves a password, then in normal mode. Holding the button 5 s resets it.
#include "bridge.h"
#include "button.h"
#include "config.h"
#include "led.h"
#include "wifi_ap.h"

void app_main(void) {
    config_init();
    vw_box_config_t cfg;
    bool setup_mode = !config_load(&cfg);
    uint32_t box_id = wifi_ap_box_id();
    led_start(setup_mode ? LED_SETUP : LED_NO_PHONE);
    button_start();
    wifi_ap_start(box_id, setup_mode ? NULL : &cfg);
    bridge_start(box_id, &cfg, setup_mode);
}
