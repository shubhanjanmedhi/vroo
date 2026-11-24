# Vroo relay server

Free software under the [GNU AGPL, version 3 or later](../LICENSES/AGPL-3.0-or-later.txt): if you run a changed
version for others, you must offer them its source. Paid licences on other terms are available (see the
[main README](../README.md#licence)).

Riders without a box, or out of box range, talk over mobile data. Their phones send each voice packet to a relay
server, and the relay passes it on to the other phones in the same group. The relay can't listen: every packet is
sealed with the group's key, which the relay never has. It reads only the plain routing header, and keeps nothing but
which addresses are riding in which group (architecture §4.9).

Anyone can run one: the founder for a group, a club, or a company that licenses Vroo. There's no public relay (D26).

## What you need

- A small Linux computer with a public IPv4 address, such as a virtual machine from any hosting company. 1 CPU and
  512 MB of memory is plenty for a group or a club. This costs about $5 a month.
- UDP port **47100** open to the internet in the host's firewall.

## Install it as a program (simplest)

1. On a Mac with the repository, build the Linux program:

   ```
   cd server
   dart compile exe --target-os linux --target-arch x64 bin/vroo_relay.dart -o build/vroo_relay-linux-x64
   ```

   For an ARM server, use `--target-arch arm64`.

2. Copy it to the server, for example with `scp build/vroo_relay-linux-x64 user@SERVER:/tmp/vroo_relay`.

3. On the server, install it and make it start by itself:

   ```
   sudo install -m 755 /tmp/vroo_relay /usr/local/bin/vroo_relay
   sudo useradd --system --no-create-home vroo
   sudo tee /etc/systemd/system/vroo-relay.service >/dev/null <<'UNIT'
   [Unit]
   Description=Vroo relay server
   After=network-online.target
   Wants=network-online.target

   [Service]
   User=vroo
   ExecStart=/usr/local/bin/vroo_relay --port 47100
   Restart=always
   RestartSec=2
   NoNewPrivileges=true
   ProtectSystem=strict
   ProtectHome=true

   [Install]
   WantedBy=multi-user.target
   UNIT
   sudo systemctl daemon-reload
   sudo systemctl enable --now vroo-relay
   ```

## Or run the container

From the repository root:

```
docker build -f server/Dockerfile -t vroo-relay .
docker run -d --restart unless-stopped -p 47100:47100/udp --name vroo-relay vroo-relay
```

## Check it's working

Every 10 seconds the relay prints one line of counters:

```
2026-11-18T10:00:00.000Z groups=1 addresses=5 rx=12450 tx=49800 drop_size=0 drop_rate=0 drop_cap=0 drop_send=0 drop_full=0
```

- **groups, addresses:** groups riding now, and the phones heard in the last 30 seconds.
- **rx, tx:** packets in and out since it started.
- **drop_size:** packets that weren't Vroo packets.
- **drop_rate:** packets over the limits: 200 a second from one phone, or 2,000 a second for one group.
- **drop_cap:** voice from a fifth rider talking at the same moment (only 4 voices are carried at once).
- **drop_send:** packets the server's own network refused to send, for example to a phone that just left a Wi-Fi.
  A few are normal. A steady climb means a network problem on the server.
- **drop_full:** packets from a new phone that didn't fit: a group holds up to 256 phones, at most 16 of them from one
  internet address, and the server up to 50,000 in all. A climb with no big group riding means someone is sending
  junk.

See the lines with `journalctl -u vroo-relay -f` (program) or `docker logs -f vroo-relay` (container).

## Point the app at it

In the app, set **Relay server** to the server's address, such as `203.0.113.5` (port 47100 is assumed) or
`relay.example.org:47100`. Every rider in the group uses the same relay.

## What it keeps

Nothing is written to disk. In memory it holds, for each group's routing tag, the addresses that sent in the last 30
seconds. Voice, names and locations are sealed inside the packets, and the relay can't read them.
