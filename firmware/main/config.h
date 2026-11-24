// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once

#include <stdbool.h>

#include "vroo_wire.h"

// Opens NVS, erasing it first if it holds an incompatible layout.
void config_init(void);

// Loads the saved config from NVS namespace "vroo" (keys pw, tag, ch). The channel is always set (default 6).
// True if a password is saved, which means normal mode.
bool config_load(vw_box_config_t *c);

void config_save(const vw_box_config_t *c);
void config_erase(void);
