# SPDX-License-Identifier: GPL-3.0-or-later
# Independent protocol v1 vectors, computed with Python's `cryptography` (not with our Dart code).
# Run: python3 -m venv v && v/bin/pip install cryptography && v/bin/python tool/oracle.py
from cryptography.hazmat.primitives.kdf.hkdf import HKDF
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.ciphers.aead import ChaCha20Poly1305
import struct

secret = bytes(range(32))


def hk(info, n):
    return HKDF(algorithm=hashes.SHA256(), length=n, salt=None, info=info.encode()).derive(secret)


def uuid(b):
    b = bytearray(b)
    b[6] = (b[6] & 0x0F) | 0x40
    b[8] = (b[8] & 0x3F) | 0x80
    h = b.hex().upper()
    return f"{h[0:8]}-{h[8:12]}-{h[12:16]}-{h[16:20]}-{h[20:32]}"


key, tag = hk("vroo/v1/key", 32), hk("vroo/v1/tag", 8)
print("key", key.hex(), "tag", tag.hex(), "channel", [1, 6, 11][tag[0] % 3])
print("bleIos", uuid(hk("vroo/v1/ble-ios", 16)), "bleAndroid", uuid(hk("vroo/v1/ble-android", 16)))
header = struct.pack(">BBBIII", 1, 3, 16, 0x01020304, 0x0A0B0C0D, 7)
payload = bytes([1, 0x0C, 77]) + struct.pack(">I", 123456) + bytes([0, 4]) + b"Ravi"
nonce, aad = struct.pack(">III", 0x01020304, 0x0A0B0C0D, 7), header[0:2] + header[3:15]
sealed = header + ChaCha20Poly1305(key).encrypt(nonce, payload, aad)
print("sealed", sealed.hex(), "envelope", (tag + sealed).hex())
