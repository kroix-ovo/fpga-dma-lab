"""Actual RTL/cocotb PCIe backend, with permission-checked root memory."""

import logging
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer, Lock, Event
from cocotb.utils import get_sim_time
from cocotbext.pcie.core import RootComplex
from cocotbext.pcie.core.tlp import Tlp, TlpType
from cocotbext.pcie.core.utils import PcieId
from pcie_if import PcieIfDevice, PcieIfRxBus, PcieIfTxBus


class ProtectedRoot(RootComplex):
    """A buffer-domain permission model, not an implementation of an IOMMU."""

    def __init__(self):
        self.allowed = []
        self.requests = []
        self.read_issue_order = []
        self.read_response_order = []
        self.read_inflight = 0
        self.max_read_inflight = 0
        self.denied = []
        self.hold_reads = False
        self.read_gate = Event()
        self.drop_reads = False
        self.delay_reads = False
        super().__init__()

    def permits(self, address, length, permission):
        # PCIe byte enables can describe a subrange of a DWORD-aligned request.
        return any(
            base <= address and address + length <= base + size and flags & permission
            for base, size, flags in self.allowed
        )

    async def handle_mem_read_tlp(self, tlp):
        self.requests.append(("read", tlp.address, tlp.length * 4, tlp.tag))
        self.read_issue_order.append((tlp.address, tlp.tag))
        # Keep receive dispatch free for BAR completions while delaying DMA.
        cocotb.start_soon(self._respond_read(tlp))

    async def _respond_read(self, tlp):
        self.read_inflight += 1
        self.max_read_inflight = max(self.max_read_inflight, self.read_inflight)
        try:
            await self._respond_read_inner(tlp)
        finally:
            self.read_inflight -= 1

    async def _respond_read_inner(self, tlp):
        if self.hold_reads:
            await self.read_gate.wait()
        if self.drop_reads:
            return
        if self.delay_reads:
            # Different tags receive different delays, allowing completions
            # for distinct PCIe requests to be delivered out of issue order.
            await Timer(40 * (4 - (tlp.tag % 4)), unit="ns")
        if not self.permits(tlp.address, tlp.length * 4, 1):
            self.denied.append(("read", tlp.address))
            await self.send(Tlp.create_ur_completion_for_tlp(tlp, PcieId(0, 0, 0)))
            return
        self.read_response_order.append((tlp.address, tlp.tag))
        await super().handle_mem_read_tlp(tlp)

    async def handle_mem_write_tlp(self, tlp):
        self.requests.append(("write", tlp.address, tlp.length * 4, tlp.tag))
        if not self.permits(tlp.address, tlp.length * 4, 2):
            self.denied.append(("write", tlp.address))
            return
        await super().handle_mem_write_tlp(tlp)


class SimBackend:
    def __init__(self, dut):
        self.dut = dut
        self.command_lock = Lock()
        self.rc = ProtectedRoot()
        self.device = PcieIfDevice(
            clk=dut.clk,
            rst=dut.rst,
            rx_req_tlp_bus=PcieIfRxBus.from_prefix(dut, "rx_req_tlp"),
            tx_cpl_tlp_bus=PcieIfTxBus.from_prefix(dut, "tx_cpl_tlp"),
            tx_rd_req_tlp_bus=PcieIfTxBus.from_prefix(dut, "tx_rd_req_tlp"),
            tx_wr_req_tlp_bus=PcieIfTxBus.from_prefix(dut, "tx_wr_req_tlp"),
            rx_cpl_tlp_bus=PcieIfRxBus.from_prefix(dut, "rx_cpl_tlp"),
            rd_req_tx_seq_num=dut.s_axis_rd_req_tx_seq_num,
            rd_req_tx_seq_num_valid=dut.s_axis_rd_req_tx_seq_num_valid,
            wr_req_tx_seq_num=dut.s_axis_wr_req_tx_seq_num,
            wr_req_tx_seq_num_valid=dut.s_axis_wr_req_tx_seq_num_valid,
            cfg_max_payload=dut.max_payload_size,
            cfg_max_read_req=dut.max_read_request_size,
            cfg_ext_tag_enable=dut.ext_tag_enable,
            cfg_rcb=dut.rcb_128b,
        )
        self.device.functions[0].configure_bar(0, 128 * 1024)
        self.rc.make_port().connect(self.device)
        # Exercise actual 64-bit DMA addresses, independent of BAR placement.
        self.pool = self.rc.mem_address_space.create_pool(0x100000000, 0x10000000)
        self.allocations = []
        self.bar = None

    async def start(self):
        logging.getLogger("cocotb").setLevel(logging.WARNING)
        for name in [
            "fir_in_data",
            "fir_in_valid",
            "fir_out_ready",
            "snapshot_start",
            "snapshot_in_valid",
            "snapshot_in_last",
            "snapshot_in_data",
            "point_x",
            "point_y",
            "point_z",
            "point_matrix",
        ]:
            getattr(self.dut, name).value = 0
        cocotb.start_soon(Clock(self.dut.clk, 4, unit="ns").start())
        for signal in ["requester_id", "completer_id", "bus_master_enable"]:
            getattr(self.dut, signal).value = 0
        self.dut.rst.value = 1
        for _ in range(5):
            await RisingEdge(self.dut.clk)
        self.dut.rst.value = 0
        for _ in range(5):
            await RisingEdge(self.dut.clk)
        await self.rc.enumerate()
        self.function = self.rc.find_device(self.device.functions[0].pcie_id)
        await self.function.enable_device()
        await self.function.set_master()
        self.bar = self.function.bar_window[0]
        self.dut.requester_id.value = int(self.device.functions[0].pcie_id)
        self.dut.completer_id.value = int(self.device.functions[0].pcie_id)
        cocotb.start_soon(self._configuration())
        await Timer(20, unit="ns")
        return self

    async def _configuration(self):
        while True:
            self.dut.bus_master_enable.value = int(
                self.device.functions[0].bus_master_enable
            )
            await RisingEdge(self.dut.clk)

    def allocate_memory(self, size):
        # Reserve aligned padding for DWORD reads at a byte-granular boundary.
        memory = self.pool.alloc_region((size + 3) & ~3)
        self.allocations.append(memory)
        return memory

    def permit(self, memory, size, permissions):
        self.rc.allowed.append(
            (memory.get_absolute_address(0), (size + 3) & ~3, permissions)
        )

    def revoke(self, memory):
        base = memory.get_absolute_address(0)
        self.rc.allowed = [entry for entry in self.rc.allowed if entry[0] != base]

    async def read32(self, address):
        return int.from_bytes(
            await self.bar.read(address, 4, timeout=100000, timeout_unit="ns"), "little"
        )

    async def write32(self, address, value):
        await self.bar.write(address, int(value).to_bytes(4, "little"))

    async def read_bytes(self, address, length):
        return bytes(
            await self.bar.read(address, length, timeout=100000, timeout_unit="ns")
        )

    async def write_bytes(self, address, data):
        await self.bar.write(address, data)
        # Drain posted MMIO writes before returning ownership.
        await self.read32(0)

    @staticmethod
    def now_ns():
        return int(get_sim_time(unit="ns"))

    @staticmethod
    async def sleep_ns(duration):
        await Timer(duration, unit="ns")
