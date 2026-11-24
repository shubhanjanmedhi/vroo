# Hardware: the box

Status: draft · 2026-10-24 · One box per bike. It's a Wi-Fi hotspot for the rider's phone and a long-range radio to the other boxes. Design in [architecture.md](architecture.md) §4.7.

## 1. What a box is

A small ESP32 board with an external antenna, in a waterproof case, powered from the bike's USB socket. It has no buttons except one recessed button for reset to setup. A status light shows its state. It can't hear the group: it only passes encrypted packets along.

## 2. Parts per box (v1, hand-built)

Prices are rough, as of 2026. The exact board gets chosen in M1 after bench and range tests.

| Part | What to look for | About |
|---|---|---|
| ESP32 board | An ESP32 chip with Espressif's 802.11 long-range mode and an external antenna connector (u.FL/IPEX), plus USB-C. Candidates: a board using an ESP32-S3 or classic ESP32 "U/UE" module, or a tiny board that comes with an antenna. Confirm long-range support for the exact chip | $5–15 |
| 2.4 GHz antenna | The board's approved external antenna, or a 2–3 dBi dipole. Keep within the module's certified antenna types | $2–5 |
| Case | Small IP65 or better ABS box, with a cable gland or a sealed USB-C pass-through | $3–5 |
| Cable | USB-C from the bike's USB socket, ideally right-angle, with strain relief | $3 |
| Mount | Velcro or zip ties, or a 3D-printed bracket | $1–3 |
| Optional | A small USB power bank, for bikes without a USB socket | $10 |

Expect about $15–30 per box. For the group: 3 boxes for M1, and 6 for M2 (5 plus a spare). The M2 big-bench test of large-group behaviour also needs about 10 boards. They don't need cases, and can be reused.

## 3. Assembly

1. Fit the antenna to the board's connector. Never power the board without its antenna.
2. Mount the board in the case with foam, so it can't rattle, and keep the light visible.
3. Run the USB cable through the gland, then seal it.
4. Route the antenna so it stands vertical and sits outside any metal.

## 4. Mounting on the bike

- **Antenna:** high and clear of the rider's body, for example on the tail, a rear rack, or the top of the windscreen. A rider's body blocks a lot of 2.4 GHz signal, and the other bikes are ahead and behind. FT1 compares placements.
- **Heat and water:** keep the case off hot engine parts and out of direct spray.
- **Power:** use a switched USB socket, so the box turns on and off with the ignition.

## 5. Loading the software (once)

1. Plug the box into a computer with a USB-C cable.
2. Open the flashing web page in Chrome or Edge. It's ESP Web Tools, hosted with the firmware.
3. Click Install. When it's done, the box opens its setup Wi-Fi.
4. In the app, tap **Add my box** (spec 6.2).

Updates from the app come in v2. Until then, re-flash the same way.

## 6. Power and heat

- **Draw:** about 0.5–1 W while running, which any bike USB socket supplies.
- **Heat:** keep the case out of direct summer sun if possible. FT7 records box temperature.

## 7. Design files and radio rules

- **Design files:** the parts list, assembly notes and any case files are part of Vroo, under CC BY-SA 4.0 like the docs (D34).
- **Personal use:** boxes use certified ESP32 modules in the 2.4 GHz band.
- **Antennas and power:** keep to the module's approved antenna types and the firmware's default power limits. Builders are responsible for following their country's radio rules.
- **Boxes for sale:** need product certification in each market (FCC, CE, India WPC and so on). That falls to whoever makes them.
