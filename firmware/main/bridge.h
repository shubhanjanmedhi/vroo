// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once

#include <stdbool.h>
#include <stdint.h>

#include "vroo_wire.h"

// Starts the UDP bridge task on 192.168.4.1:
// - data port 47000: an envelope with the saved group tag that passes dedupe goes to every other phone heard in
//   the last 30 s;
// - control port 47001: takes BOX_CONFIG, and sends BOX_STATUS to every phone each second.
// Any datagram on either port refreshes the 4-entry phone table.
void bridge_start(uint32_t box_id, const vw_box_config_t *cfg, bool setup_mode);
