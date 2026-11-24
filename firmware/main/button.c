// SPDX-License-Identifier: GPL-3.0-or-later
#include "button.h"

#include "config.h"
#include "driver/gpio.h"
#include "esp_log.h"
#include "esp_system.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "sdkconfig.h"

#define POLL_MS 50
#define HOLD_MS 5000

static void button_task(void *arg) {
    (void)arg;
    int held_ms = 0;
    for (;;) {
        vTaskDelay(pdMS_TO_TICKS(POLL_MS));
        held_ms = gpio_get_level(CONFIG_VROO_BUTTON_GPIO) == 0 ? held_ms + POLL_MS : 0; // pressed pulls it low
        if (held_ms >= HOLD_MS) {
            config_erase();
            ESP_LOGI("vroo_box", "config erased");
            // The BOOT button is the GPIO0 strapping pin: restarting while it's still held would start the
            // chip's firmware download mode instead of setup mode. So wait for the rider to let go.
            while (gpio_get_level(CONFIG_VROO_BUTTON_GPIO) == 0) vTaskDelay(pdMS_TO_TICKS(POLL_MS));
            vTaskDelay(pdMS_TO_TICKS(100)); // let the log line out
            esp_restart();
        }
    }
}

void button_start(void) {
    gpio_reset_pin(CONFIG_VROO_BUTTON_GPIO);
    gpio_set_direction(CONFIG_VROO_BUTTON_GPIO, GPIO_MODE_INPUT);
    gpio_set_pull_mode(CONFIG_VROO_BUTTON_GPIO, GPIO_PULLUP_ONLY);
    xTaskCreate(button_task, "button", 3072, NULL, 1, NULL);
}
