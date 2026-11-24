# Security policy

Vroo encrypts voice end to end (ChaCha20-Poly1305, with keys derived from the group's QR code), so flaws in the protocol or its implementation matter.

## Reporting a problem

Report a vulnerability privately through the repository's **Security → Report a vulnerability** form, which is GitHub's private vulnerability reporting. Don't open a public issue.

Please include:

- **What's affected:** the app, the box firmware, the relay server, or protocol v1 itself.
- **How to reproduce it.**
- **What an attacker could do with it.**

Maintainers aim to reply within 7 days.

## In scope

- **Protocol v1:** key derivation, packet sealing, nonces, dedupe, replay protection, and the envelope and groupTag.
- **The box:** setup mode, configuration over Wi-Fi, and the way it filters and forwards packets.
- **The relay server:** forwarding, rate limits, address caps, and denial of service.
- **The app:** storage of the group secret and the box Wi-Fi password, and invite links and QR codes.

## Known design limits (not vulnerabilities)

These are described in [architecture §5.2](docs/architecture.md), under "Limits, by design":

- **Anyone with a group's QR code or invite link can join that group.** Share it only with your riders.
- **Boxes and the relay can see packet metadata.** That means the group tag, sender ID, sequence numbers and timing, but never content.
- **Boxes and the relay trust the plain header.** Someone who copies it can make boxes drop a real packet as a duplicate, or mute a group's voice on the relay. Phones check every seal, so they can't be fooled this way.
- **The relay doesn't yet check return addresses.** Someone who can forge source addresses can make it send a group's sealed traffic to other machines, at most 255 copies of a packet and 16 to one host. A return-address check is planned.
- **A phone whose clock is more than 10 minutes wrong isn't heard.** That's replay protection at work. The app says why on screen and in the helmet.
- **The Bluetooth fallback and box radio can be jammed.** Like any radio, they can be disrupted.
