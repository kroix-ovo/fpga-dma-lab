"""Transport-independent asynchronous host API for the lab's BAR contract.

The backend supplies read32/write32, read_bytes/write_bytes and allocate_memory.
Only the simulation backend ships. A future KMDF backend owns buffer allocation
and DMA mappings; application callers never supply physical addresses.
"""

from dataclasses import dataclass
from .registers import Status
from . import registers as reg


class DmaError(RuntimeError):
    pass


class QueueFull(DmaError):
    pass


@dataclass(frozen=True)
class Region:
    slot: int
    generation: int
    size: int
    permissions: int
    epoch: int
    owner: object


@dataclass(frozen=True)
class Completion:
    request_id: int
    status: Status
    bytes_completed: int
    epoch: int


class DmaClient:
    READ = 1
    WRITE = 2

    def __init__(self, backend):
        self.backend = backend
        self.regions = {}
        self.memory = {}
        self.pending = set()
        self.results = {}
        self.next_request = 1
        self.generation = 0
        self.epoch = 0
        self.closed = False

    async def initialize(self):
        if await self.backend.read32(reg.SIGNATURE) != 0x444D414C:
            raise DmaError("Unexpected device signature")
        if await self.backend.read32(reg.ABI_VERSION) != 0x00010000:
            raise DmaError("Unsupported device ABI version")
        self.epoch = await self.backend.read32(reg.EPOCH)
        self.fence_memory = self.backend.allocate_memory(4)
        self.backend.permit(self.fence_memory, 4, self.READ)
        address = self.fence_memory.get_absolute_address(0)
        await self.backend.write32(reg.FENCE_LO, address & 0xFFFFFFFF)
        await self.backend.write32(reg.FENCE_HI, address >> 32)
        await self.backend.write32(reg.CONTROL, 1)
        return self

    async def get_capabilities(self):
        return {
            "abi_version": await self.backend.read32(reg.ABI_VERSION),
            "fpga_buffer_bytes": await self.backend.read32(reg.FPGA_CAPACITY),
            "regions": 16,
            "queue_depth_per_direction": 16,
            "address_bits": 64,
            "data_bits": 64,
            "outstanding_read_tlps": 4,
        }

    def _open(self):
        if self.closed:
            raise DmaError("Client is closed")

    async def _idle(self):
        self._open()
        if (
            self.pending
            or await self.backend.read32(reg.DEVICE_STATUS) & 2
            or await self.backend.read32(reg.QUEUE_COUNTS)
        ):
            raise DmaError(
                "Drain outstanding transfers before modifying the registry or FPGA memory"
            )

    def _region(self, region):
        self._open()
        if (
            region.owner is not self
            or self.regions.get(region.slot) is not region
            or region.epoch != self.epoch
        ):
            raise DmaError(
                "Region handle is stale, released, or belongs to another client"
            )

    async def allocate_region(self, size, permissions=3):
        await self._idle()
        if (
            not isinstance(size, int)
            or not 4 <= size <= 4 * 1024 * 1024
            or permissions not in (1, 2, 3)
        ):
            raise ValueError(
                "Size must be 4 bytes..4 MiB; permissions must be READ, WRITE, or both"
            )
        slots = [slot for slot in range(16) if slot not in self.regions]
        if not slots:
            raise DmaError("All region slots are in use")
        slot = slots[0]
        memory = self.backend.allocate_memory(size)
        address = memory.get_absolute_address(0)
        self.generation += 1
        if self.generation > 0xFFFFFFFF:
            raise DmaError(
                "Generation space exhausted; create a fresh client and endpoint"
            )
        base = 0x100 + slot * 32
        for offset, value in [
            (0, address & 0xFFFFFFFF),
            (4, address >> 32),
            (8, size),
            (12, 0),
            (16, self.generation),
            (20, permissions),
        ]:
            await self.backend.write32(base + offset, value)
        region = Region(slot, self.generation, size, permissions, self.epoch, self)
        self.regions[slot] = region
        self.memory[slot] = memory
        self.backend.permit(memory, size, permissions)
        return region

    async def release_region(self, region):
        self._region(region)
        await self._idle()
        await self.backend.write32(0x100 + region.slot * 32 + 20, 0)
        self.backend.revoke(self.memory[region.slot])
        del self.regions[region.slot]
        del self.memory[region.slot]
        # The simulator retains its allocation until teardown. A real backend
        # must unmap/free the allocation only after the device is quiescent.

    def store(self, region, offset, data):
        self._region(region)
        data = bytes(data)
        if offset < 0 or offset + len(data) > region.size:
            raise ValueError("Host buffer write is out of range")
        if self.pending:
            raise DmaError(
                "Host buffer ownership is with the device until transfers are drained"
            )
        self.memory[region.slot][offset : offset + len(data)] = data

    def load(self, region, offset, length):
        self._region(region)
        if offset < 0 or length < 0 or offset + length > region.size:
            raise ValueError("Host buffer read is out of range")
        if self.pending:
            raise DmaError("Wait for DMA completion before reading a host buffer")
        return bytes(self.memory[region.slot][offset : offset + length])

    async def _submit(self, region, offset, fpga_offset, length, direction):
        self._region(region)
        if not all(isinstance(v, int) for v in [offset, fpga_offset, length]):
            raise TypeError("Offsets and length must be integers")
        if (
            not 0 <= offset <= 0xFFFFFFFFFFFFFFFF
            or not 0 <= fpga_offset <= 0xFFFFFFFF
            or not 0 <= length <= 0xFFFFFFFF
        ):
            raise ValueError("Descriptor field is outside its encoded range")
        if self.next_request > 0xFFFFFFFF:
            raise DmaError("Request identifier space exhausted")
        request = self.next_request
        self.next_request += 1
        values = [
            region.slot,
            region.generation,
            offset & 0xFFFFFFFF,
            offset >> 32,
            fpga_offset,
            length,
            request,
            direction,
        ]
        # A client has one command producer. Concurrent producers must use a
        # backend lock around this complete staging-register transaction.
        async with self.backend.command_lock:
            for index, value in enumerate(values):
                await self.backend.write32(reg.STAGE_SLOT + index * 4, value)
            code = await self.backend.read32(reg.SUBMIT_STATUS)
        if code == Status.QUEUE_FULL:
            raise QueueFull("DMA command queue is full; drain completions and retry")
        if code:
            raise DmaError(f"Descriptor submission failed: {code}")
        self.pending.add(request)
        return request

    async def host_to_fpga(self, region, offset, fpga_offset, length):
        return await self._submit(region, offset, fpga_offset, length, 0)

    async def fpga_to_host(self, fpga_offset, region, offset, length):
        return await self._submit(region, offset, fpga_offset, length, 1)

    async def poll(self):
        self._open()
        completions = []
        async with self.backend.command_lock:
            while await self.backend.read32(reg.COMPLETION_COUNT):
                values = [
                    await self.backend.read32(address) for address in (80, 84, 88, 92)
                ]
                await self.backend.write32(reg.COMPLETION_POP, 1)
                completion = Completion(
                    values[0], Status(values[1]), values[2], values[3]
                )
                if completion.epoch != self.epoch:
                    continue
                if completion.request_id not in self.pending:
                    raise DmaError("Unexpected or duplicate completion")
                self.pending.remove(completion.request_id)
                self.results[completion.request_id] = completion
                completions.append(completion)
        return completions

    async def wait(self, request_id, timeout=2_000_000):
        self._open()
        if request_id not in self.pending and request_id not in self.results:
            raise DmaError("Unknown request identifier")
        deadline = self.backend.now_ns() + timeout
        while request_id not in self.results:
            await self.poll()
            if self.backend.now_ns() >= deadline:
                raise TimeoutError(
                    "Host wait expired; request remains pending and owns its buffers"
                )
            await self.backend.sleep_ns(40)
        return self.results[request_id]

    async def cancel(self, request_id):
        self._open()
        async with self.backend.command_lock:
            await self.backend.write32(reg.CANCEL_ID, request_id)
            code = await self.backend.read32(reg.CANCEL_STATUS)
        return {0: "queued_cancelled", 1: "active_cannot_cancel", 2: "not_queued"}[code]

    async def read_fpga(self, offset, length):
        await self._idle()
        if offset < 0 or length < 0 or offset + length > 65520:
            raise ValueError("FPGA memory read is out of range")
        return await self.backend.read_bytes(0x10000 + offset, length)

    async def write_fpga(self, offset, data):
        await self._idle()
        if offset < 0 or offset + len(data) > 65520:
            raise ValueError("FPGA memory write is out of range")
        await self.backend.write_bytes(0x10000 + offset, bytes(data))

    async def get_statistics(self):
        return {
            "completed": await self.backend.read32(reg.COMPLETED_TOTAL),
            "queued": await self.backend.read32(reg.QUEUE_COUNTS),
            "device_status": await self.backend.read32(reg.DEVICE_STATUS),
            "pending_host": len(self.pending),
        }

    async def reset(self):
        await self._idle()
        if await self.backend.read32(reg.DEVICE_STATUS) & 4:
            raise DmaError("A halted endpoint needs full link/device teardown")
        await self.backend.write32(reg.CONTROL, 2)
        for memory in self.memory.values():
            self.backend.revoke(memory)
        self.regions.clear()
        self.memory.clear()
        self.results.clear()
        self.epoch = await self.backend.read32(reg.EPOCH)
        await self.backend.write32(reg.CONTROL, 1)

    async def close(self):
        if self.closed:
            return
        await self._idle()
        if await self.backend.read32(reg.DEVICE_STATUS) & 4:
            # Keep mappings alive until the simulation tears down its link.
            self.closed = True
            return
        for region in list(self.regions.values()):
            await self.release_region(region)
        await self.backend.write32(reg.CONTROL, 0)
        await self.backend.read32(reg.CONTROL)
        self.backend.revoke(self.fence_memory)
        self.closed = True
