// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once

#include <stdint.h>

#include "vroo_wire.h"

// The box ID: the lower 32 bits of the softAP MAC. Its lower 24 bits name the hotspot.
uint32_t wifi_ap_box_id(void);

// Starts the hotspot at 192.168.4.1: the open Vroo-setup-XXXXXX on channel 6 when cfg is NULL, otherwise
// the WPA2 Vroo-XXXXXX with cfg's password and channel. At most 4 phones either way.
void wifi_ap_start(uint32_t box_id, const vw_box_config_t *cfg);
