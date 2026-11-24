// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once

typedef enum {
    LED_SETUP,    // blinks once a second
    LED_NO_PHONE, // a 100 ms flash every 2 s
    LED_PHONE,    // solid on
} led_mode_t;

void led_start(led_mode_t mode);
void led_set(led_mode_t mode);
