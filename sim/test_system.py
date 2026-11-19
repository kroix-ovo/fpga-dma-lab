import json
import os
import random
import struct
from pathlib import Path
import cocotb
from cocotb.triggers import RisingEdge, Timer
from backend import SimBackend
from fpga_dma_lab import DmaClient, DmaError, QueueFull
from fpga_dma_lab.client import Status
from fpga_dma_lab.examples import (
    snapshot,
    parse_snapshot,
    project,
    scene_svg,
    iq_samples,
    fir_reference,
    pack_iq,
    unpack_iq,
)


async def tick(dut):
    await RisingEdge(dut.clk)
    await Timer(1, unit="ns")


async def check_snapshot(dut, payload):
    dut.snapshot_start.value = 1
    await tick(dut)
    dut.snapshot_start.value = 0
    words = list(struct.unpack("<" + "I" * (len(payload) // 4), payload))
    for i, word in enumerate(words):
        assert int(dut.snapshot_in_ready.value)
        dut.snapshot_in_data.value = word
        dut.snapshot_in_valid.value = 1
        dut.snapshot_in_last.value = i == len(words) - 1
        await tick(dut)
    dut.snapshot_in_valid.value = 0
    dut.snapshot_in_last.value = 0
    assert int(dut.snapshot_done.value)
    return bool(int(dut.snapshot_accepted.value))


async def demos(dut, client, region, directory):
    results = {}
    mode = os.environ["LAB_DEMO"]
    if mode in ("all", "telemetry"):
        data = snapshot()
        client.store(region, 0, data)
        assert (
            await client.wait(await client.host_to_fpga(region, 0, 0, len(data)))
        ).status == Status.OK
        received = await client.read_fpga(0, len(data))
        assert await check_snapshot(dut, received)
        assert not await check_snapshot(dut, received), "stale sequence accepted"
        corrupt = bytearray(snapshot(4))
        corrupt[95] ^= 1
        assert not await check_snapshot(dut, corrupt), "corrupt CRC accepted"
        torn = bytearray(snapshot(4))
        torn[-8] ^= 2
        assert not await check_snapshot(dut, torn), "torn sequence accepted"
        assert not await check_snapshot(dut, snapshot(6)[:-4]), "truncation accepted"
        assert await check_snapshot(dut, snapshot(8))
        scene = parse_snapshot(received)
        dut.point_matrix.value = sum(
            (v & 0xFFFFFFFF) << (32 * i) for i, v in enumerate(scene["matrix"])
        )
        points = []
        for identifier, x, y, z, flags in scene["entities"]:
            for name, value in [("point_x", x), ("point_y", y), ("point_z", z)]:
                getattr(dut, name).value = value & 0xFFFFFFFF
            await Timer(1, unit="ns")
            actual = (
                dut.point_ndc_x.value.to_signed(),
                dut.point_ndc_y.value.to_signed(),
                bool(int(dut.point_visible.value)),
            )
            assert actual == project(scene["matrix"], (x, y, z))
            points.append((identifier, *actual))
        output = b"".join(
            struct.pack("<IiiI", identifier, x, y, visible)
            for identifier, x, y, visible in points
        )
        await client.write_fpga(4096, output)
        assert (
            await client.wait(
                await client.fpga_to_host(4096, region, 8192, len(output))
            )
        ).status == Status.OK
        assert client.load(region, 8192, len(output)) == output
        (directory / "scene.svg").write_text(scene_svg(points))
        (directory / "telemetry.json").write_text(
            json.dumps({"sequence": scene["sequence"], "projected": points}, indent=2)
        )
        results["telemetry"] = {
            "crc_stale_torn_truncation": "passed",
            "projected_entities": len(points),
        }
    if mode in ("all", "iq"):
        samples = iq_samples()
        data = pack_iq(samples)
        client.store(region, 0, data)
        assert (
            await client.wait(await client.host_to_fpga(region, 0, 0, len(data)))
        ).status == Status.OK
        received = unpack_iq(await client.read_fpga(0, len(data)))
        output = []
        dut.fir_out_ready.value = 0
        for i, sample in enumerate(received):
            dut.fir_in_data.value = int.from_bytes(pack_iq([sample]), "little")
            dut.fir_in_valid.value = 1
            dut.fir_out_ready.value = 1
            await Timer(1, unit="ns")
            assert int(dut.fir_in_ready.value)
            await tick(dut)
            assert int(dut.fir_out_valid.value)
            value = int(dut.fir_out_data.value)
            dut.fir_in_valid.value = 0
            dut.fir_out_ready.value = 0
            if i % 11 == 0:
                for _ in range(3):
                    await tick(dut)
                    assert (
                        int(dut.fir_out_valid.value)
                        and int(dut.fir_out_data.value) == value
                    )
            output.extend(unpack_iq(value.to_bytes(4, "little")))
        dut.fir_in_valid.value = 0
        dut.fir_out_ready.value = 1
        await tick(dut)
        assert output == fir_reference(received)
        floating = fir_reference(received, floating=True)
        error = max(
            abs(a - b) for pair, ref in zip(output, floating) for a, b in zip(pair, ref)
        )
        assert error <= 0.5
        packed = pack_iq(output)
        await client.write_fpga(4096, packed)
        assert (
            await client.wait(
                await client.fpga_to_host(4096, region, 8192, len(packed))
            )
        ).status == Status.OK
        assert client.load(region, 8192, len(packed)) == packed
        (directory / "iq.csv").write_text(
            "sample,input_i,input_q,output_i,output_q\n"
            + "".join(
                f"{i},{a},{b},{c},{d}\n"
                for i, ((a, b), (c, d)) in enumerate(zip(samples, output))
            )
        )
        results["iq"] = {
            "samples": len(output),
            "bit_exact": True,
            "max_float_error_lsb": error,
            "stall_checks": True,
        }
    return results


@cocotb.test()
async def system_regression(dut):
    backend = await SimBackend(dut).start()
    client = await DmaClient(backend).initialize()
    region = await client.allocate_region(16384)
    directory = Path(os.environ["LAB_ARTIFACTS"])
    seeds = list(range(int(os.environ["LAB_SEEDS"])))
    cases = []
    backend.rc.delay_reads = True
    for seed in seeds:
        rng = random.Random(seed)
        length = [0, 1, 3, 4, 7, 127, 128, 129, 511, 512, 513, 2048, 4096][seed % 13]
        source = 4093 if seed % 2 else rng.randrange(0, 2048)
        target = rng.randrange(8192, 10000)
        fpga = rng.randrange(0, 4096)
        payload = rng.randbytes(length)
        client.store(region, source, payload)
        client.store(region, target, b"\xa5" * (length + 8))
        a = await client.wait(await client.host_to_fpga(region, source, fpga, length))
        assert a.status == Status.OK and a.bytes_completed == length, (seed, a)
        if seed < 13 and length:
            assert await client.read_fpga(fpga, length) == payload
        b = await client.wait(await client.fpga_to_host(fpga, region, target, length))
        assert b.status == Status.OK and b.bytes_completed == length, (seed, b)
        assert client.load(region, target, length + 8) == payload + b"\xa5" * 8, seed
        cases.append(
            {
                "seed": seed,
                "length": length,
                "source": source,
                "destination": target,
                "fpga": fpga,
            }
        )
    backend.rc.delay_reads = False
    reordered = backend.rc.read_issue_order != backend.rc.read_response_order
    if len(seeds) >= 13:
        assert backend.rc.max_read_inflight == 4
        assert reordered
    for offset, fpga, length in [
        (16384, 0, 1),
        (0, 65520, 1),
        (0, 65521, 0),
        (0xFFFFFFFFFFFFFFFF, 0, 2),
        (0, 0, 0xFFFFFFFF),
    ]:
        count = len(backend.rc.requests)
        result = await client.wait(
            await client.host_to_fpga(region, offset, fpga, length)
        )
        assert result.status == Status.BOUNDS and len(backend.rc.requests) == count
    # Deliberately bypass the client's stale-handle prevention to check RTL.
    await backend.write32(0x100 + region.slot * 32 + 16, region.generation + 1)
    assert (
        await client.wait(await client.host_to_fpga(region, 0, 0, 4))
    ).status == Status.BAD_REGION
    await backend.write32(0x100 + region.slot * 32 + 16, region.generation)
    await backend.function.clear_master()
    await backend.sleep_ns(20)
    count = len(backend.rc.requests)
    assert (
        await client.wait(await client.host_to_fpga(region, 0, 0, 4))
    ).status == Status.DISABLED
    assert len(backend.rc.requests) == count
    await backend.function.set_master()
    await backend.sleep_ns(20)
    read_only = await client.allocate_region(64, DmaClient.READ)
    result = await client.wait(await client.fpga_to_host(0, read_only, 0, 4))
    assert result.status == Status.PERMISSION
    write_only = await client.allocate_region(64, DmaClient.WRITE)
    result = await client.wait(await client.host_to_fpga(write_only, 0, 0, 4))
    assert result.status == Status.PERMISSION
    await client.write_fpga(0, b"abcd")
    assert (
        await client.wait(await client.fpga_to_host(0, write_only, 0, 4))
    ).status == Status.OK
    assert client.load(write_only, 0, 4) == b"abcd"
    client.store(write_only, 0, b"guard")
    backend.revoke(client.memory[write_only.slot])
    # Posted write denial has no completion. The independent fence succeeds;
    # root-domain evidence and the scoreboard must expose the dropped write.
    assert (
        await client.wait(await client.fpga_to_host(0, write_only, 0, 4))
    ).status == Status.OK
    assert client.load(write_only, 0, 5) == b"guard"
    assert any(kind == "write" for kind, address in backend.rc.denied)
    backend.permit(client.memory[write_only.slot], 64, DmaClient.WRITE)
    backend.revoke(client.memory[read_only.slot])
    result = await client.wait(await client.host_to_fpga(read_only, 0, 0, 4))
    assert result.status == Status.DMA_ERROR
    backend.permit(client.memory[read_only.slot], 64, DmaClient.READ)
    await client.release_region(read_only)
    try:
        await client.host_to_fpga(read_only, 0, 0, 4)
    except DmaError:
        pass
    else:
        assert False, "released handle accepted"
    demo_results = await demos(dut, client, region, directory)
    stats = await client.get_statistics()
    requests = backend.rc.requests
    assert all(
        (address & 4095) + length <= 4096 for _, address, length, _ in requests
    ), "TLP crossed 4KiB boundary"
    assert all(
        length <= (512 if direction == "read" else 128)
        for direction, _, length, _ in requests
    )
    assert all(address >= 0x100000000 for _, address, _, _ in requests)
    await client.reset()
    try:
        client.load(region, 0, 1)
    except DmaError:
        pass
    else:
        assert False, "reset did not invalidate handles"
    assert not client.regions
    await client.close()
    assert not backend.rc.allowed
    (directory / "report.json").write_text(
        json.dumps(
            {
                "status": "passed",
                "seeds": seeds,
                "cases": cases,
                "statistics": stats,
                "tlp_count": len(requests),
                "host_address_bits_tested": 64,
                "max_concurrent_read_tlps": backend.rc.max_read_inflight,
                "out_of_order_responses": reordered,
                "guards": [
                    "bounds",
                    "overflow",
                    "permissions",
                    "released_handle",
                    "reset_epoch",
                    "root_read_denial",
                    "RTL_generation",
                    "bus_master_disable",
                    "4KiB_TLP_split",
                    "payload_limits",
                ],
                "posted_write_denial": "logged/dropped by root; not observable through fence status",
                "demos": demo_results,
            },
            indent=2,
        )
    )


@cocotb.test()
async def timeout_queue_and_cancel(dut):
    backend = await SimBackend(dut).start()
    client = await DmaClient(backend).initialize()
    region = await client.allocate_region(4096)
    await backend.write32(20, 20000)
    backend.rc.hold_reads = True
    active = await client.host_to_fpga(region, 0, 0, 1024)
    await backend.sleep_ns(100)
    assert await client.cancel(active) == "active_cannot_cancel"
    queued = [await client.host_to_fpga(region, 0, 0, 4) for _ in range(16)]
    try:
        await client.host_to_fpga(region, 0, 0, 4)
    except QueueFull:
        pass
    else:
        assert False, "queue overflow accepted"
    write_queued = [await client.fpga_to_host(0, region, 2048, 4) for _ in range(16)]
    try:
        await client.fpga_to_host(0, region, 2048, 4)
    except QueueFull:
        pass
    else:
        assert False, "write queue overflow accepted"
    assert await backend.read32(16) == 0x00100010
    assert await client.cancel(queued[0]) == "queued_cancelled"
    try:
        await client.wait(active, timeout=100)
    except TimeoutError:
        assert active in client.pending
    else:
        assert False, "host timeout failed"
    try:
        client.load(region, 0, 1)
    except DmaError:
        pass
    else:
        assert False, "pending buffer ownership was released"
    backend.rc.hold_reads = False
    backend.rc.read_gate.set()
    assert (await client.wait(active)).status == Status.OK
    assert (await client.wait(queued[0])).status == Status.CANCELLED
    for request in queued[1:]:
        assert (await client.wait(request)).status == Status.OK
    for request in write_queued:
        assert (await client.wait(request)).status == Status.OK
    backend.rc.drop_reads = True
    active = await client.host_to_fpga(region, 0, 0, 1024)
    queued = [await client.host_to_fpga(region, 0, 0, 4) for _ in range(3)]
    assert (await client.wait(active)).status == Status.TIMEOUT
    for request in queued:
        assert (await client.wait(request)).status in (
            Status.DISABLED,
            Status.CANCELLED,
        )
    assert (await backend.read32(8)) & 4
    try:
        await client.reset()
    except DmaError:
        pass
    else:
        assert False, "halted endpoint reset was accepted"
    Path(os.environ["LAB_ARTIFACTS"], "faults.json").write_text(
        json.dumps(
            {
                "status": "passed",
                "queue_capacity": 16,
                "active_timeout": "halted",
                "host_timeout": "retains ownership",
                "queued_cancel": "CANCELLED completion without DMA; healthy queue resumed",
                "mapping_lifetime": "retained until root/link teardown",
            },
            indent=2,
        )
    )
    await client.close()
