// SPDX-License-Identifier: GPL-3.0-or-later
#include "led.h"

#include <stdbool.h>
#include <stdint.h>

#include "driver/gpio.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "sdkconfig.h"

#ifdef CONFIG_VROO_LED_ACTIVE_HIGH
#define LED_ON 1
#else
#define LED_ON 0
#endif

static volatile led_mode_t s_mode;

static void led_task(void *arg) {
    (void)arg;
    for (uint32_t tick = 0;; tick++) { // one tick every 100 ms
        bool on = s_mode == LED_PHONE || (s_mode == LED_SETUP && tick % 10 < 5) || (s_mode == LED_NO_PHONE && tick % 20 == 0);
        gpio_set_level(CONFIG_VROO_LED_GPIO, on ? LED_ON : !LED_ON);
        vTaskDelay(pdMS_TO_TICKS(100));
    }
}

void led_start(led_mode_t mode) {
    s_mode = mode;
    gpio_reset_pin(CONFIG_VROO_LED_GPIO);
    gpio_set_direction(CONFIG_VROO_LED_GPIO, GPIO_MODE_OUTPUT);
    xTaskCreate(led_task, "led", 2048, NULL, 1, NULL);
}

void led_set(led_mode_t mode) { s_mode = mode; }
