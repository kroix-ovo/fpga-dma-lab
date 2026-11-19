"""Owned telemetry and I/Q fixtures. These never inspect another process."""

import math
import struct
import zlib

COEFFICIENTS = (1, 2, 3, 4, 3, 2, 1)
IDENTITY = tuple(
    65536 if row == column else 0 for row in range(4) for column in range(4)
)


def snapshot(sequence=2, entities=None, matrix=IDENTITY):
    if sequence & 1 or not 0 <= sequence <= 0xFFFFFFFE:
        raise ValueError("Sequence must be an even uint32; restart before wrap")
    if entities is None:
        entities = [
            (1, -32768, 16384, 0, 1),
            (2, 32768, -16384, 0, 1),
            (3, 98304, 0, 0, 1),
        ]
    if len(entities) > 128 or len(matrix) != 16:
        raise ValueError("Invalid entity count or matrix")
    data = struct.pack(
        "<8sIIQ16iI", b"DMALAB01", 1, sequence, 123456789, *matrix, len(entities)
    )
    data += b"".join(struct.pack("<IiiiI", *entity) for entity in entities)
    data += struct.pack("<I", sequence)
    return data + struct.pack("<I", zlib.crc32(data))


def parse_snapshot(data):
    if len(data) < 100 or (len(data) - 100) % 20:
        raise ValueError("Invalid snapshot length")
    magic, version, sequence, timestamp, *rest = struct.unpack("<8sIIQ16iI", data[:92])
    matrix, count = rest[:16], rest[16]
    if (
        magic != b"DMALAB01"
        or version != 1
        or sequence & 1
        or count > 128
        or len(data) != 100 + 20 * count
        or struct.unpack_from("<I", data, len(data) - 8)[0] != sequence
        or struct.unpack_from("<I", data, len(data) - 4)[0] != zlib.crc32(data[:-4])
    ):
        raise ValueError("Invalid snapshot header, sequence, count, or CRC")
    entities = [struct.unpack_from("<IiiiI", data, 92 + i * 20) for i in range(count)]
    return {
        "sequence": sequence,
        "timestamp": timestamp,
        "matrix": matrix,
        "entities": entities,
    }


def trunc_div(numerator, denominator):
    return (abs(numerator) // abs(denominator)) * (
        -1 if (numerator < 0) != (denominator < 0) else 1
    )


def project(matrix, point):
    vector = (*point, 65536)
    clip = [sum(matrix[row * 4 + c] * vector[c] for c in range(4)) for row in range(4)]
    if clip[3] <= 0:
        return 0, 0, False
    x, y = (trunc_div(clip[i] << 16, clip[3]) for i in (0, 1))
    if not all(-2147483648 <= v <= 2147483647 for v in (x, y)):
        return 0, 0, False
    return x, y, all(-clip[3] <= v <= clip[3] for v in clip[:3])


def iq_samples(count=256):
    return [
        (
            round(
                22000 * math.cos(2 * math.pi * i / 23)
                + 7000 * math.cos(2 * math.pi * i / 3)
            ),
            round(
                22000 * math.sin(2 * math.pi * i / 23)
                + 7000 * math.sin(2 * math.pi * i / 3)
            ),
        )
        for i in range(count)
    ]


def fir_reference(samples, floating=False):
    history = [(0, 0)] * 6
    output = []
    for sample in samples:
        values = [sample] + history
        sums = [
            sum(c * value[channel] for c, value in zip(COEFFICIENTS, values))
            for channel in (0, 1)
        ]
        if floating:
            output.append(tuple(v / 16 for v in sums))
        else:
            output.append(
                tuple(
                    max(-32768, min(32767, ((abs(v) + 8) // 16) * (-1 if v < 0 else 1)))
                    for v in sums
                )
            )
        history = values[:6]
    return output


def pack_iq(samples):
    return b"".join(struct.pack("<hh", *sample) for sample in samples)


def unpack_iq(data):
    return list(struct.iter_unpack("<hh", data))


def scene_svg(points):
    circles = "".join(
        f'<circle cx="{400+x*300/65536:.2f}" cy="{240-y*200/65536:.2f}" r="8" fill="#f43f5e"/><text x="{412+x*300/65536:.2f}" y="{244-y*200/65536:.2f}" fill="white">{identifier}</text>'
        for identifier, x, y, visible in points
        if visible
    )
    return f'<svg xmlns="http://www.w3.org/2000/svg" width="800" height="480" viewBox="0 0 800 480"><rect width="800" height="480" fill="#09090b"/><rect x="100" y="40" width="600" height="400" fill="none" stroke="#52525b"/>{circles}<text x="24" y="28" fill="#fafafa" font-family="sans-serif">Owned scene · RTL projection output</text></svg>'
