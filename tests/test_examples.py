import sys
from pathlib import Path
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "python"))
from fpga_dma_lab.examples import (
    snapshot,
    parse_snapshot,
    project,
    IDENTITY,
    fir_reference,
    pack_iq,
    unpack_iq,
)


class ExampleContracts(unittest.TestCase):
    def test_snapshot_roundtrip_and_empty(self):
        self.assertEqual(parse_snapshot(snapshot())["sequence"], 2)
        self.assertEqual(parse_snapshot(snapshot(2, []))["entities"], [])

    def test_corruption_and_length(self):
        original = snapshot()
        for offset in (0, 8, 12, 40, 88, 96, len(original) - 8, len(original) - 1):
            data = bytearray(original)
            data[offset] ^= 1
            with self.assertRaises(ValueError):
                parse_snapshot(data)
        for data in (original[:-1], original + b"\0" * 20, b""):
            with self.assertRaises(ValueError):
                parse_snapshot(data)

    def test_signed_projection_and_behind_camera(self):
        self.assertEqual(project(IDENTITY, (-32768, 16384, 0)), (-32768, 16384, True))
        self.assertFalse(project(IDENTITY, (65537, 0, 0))[2])
        matrix = list(IDENTITY)
        matrix[15] = -65536
        self.assertEqual(project(matrix, (0, 0, 0)), (0, 0, False))

    def test_impulse_rounding_and_dc(self):
        self.assertEqual(
            [x for x, _ in fir_reference([(16, 0)] + [(0, 0)] * 6)],
            [1, 2, 3, 4, 3, 2, 1],
        )
        self.assertEqual(fir_reference([(-8, 8)])[0], (-1, 1))
        self.assertEqual(fir_reference([(32767, -32768)] * 16)[-1], (32767, -32768))
        self.assertEqual(
            unpack_iq(pack_iq([(-32768, 32767), (0, -1)])), [(-32768, 32767), (0, -1)]
        )


if __name__ == "__main__":
    unittest.main()
