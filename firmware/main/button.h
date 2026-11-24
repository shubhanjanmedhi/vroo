// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once

// Watches the reset button. Held for 5 s, it erases the config; once released, the box restarts into setup mode.
void button_start(void);
