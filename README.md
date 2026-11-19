# FPGA Game Telemetry Lab

I wanted to give this project a clearer application than just moving bytes between a PC and an FPGA. The direction I'm taking is game telemetry: send a frame of entity positions and camera data, check that the frame is complete, project the positions, and bring the results back for a debug view or replay inspector.

The game would publish its own state. That could be a small game I write, a development build with an export hook, or a spectator interface that already exposes the data. I want the FPGA side to work with a frame format I can explain and test, while the game adapter handles where that frame comes from.

Right now the working example is a synthetic scene. It has entity IDs, positions, a camera matrix, a frame sequence and a checksum. It goes through simulated PCIe DMA and the actual parser and projection RTL, then produces a static SVG. I haven't connected a game engine or built a live overlay yet.

The folder and Python package are still called `fpga-dma-lab`. I'm changing how I describe the application, not renaming the imports or commands.

## Next step: live object acquisition and tests

**The main missing piece is getting live objects from a running application. That is the next implementation milestone, and it has not been built or tested yet.** The current example starts with supplied synthetic data. Its DMA buffers don't give the project access to another process's RAM, and the passing transfer tests don't establish that access.

I want to add a host-side acquisition adapter that reads accessible object data from a selected application through an authorized process-memory inspector, debug interface, or supported game API. The adapter needs to understand that application's object layout, entity IDs, camera format and object lifetime. Reading bytes is only the first part; I still need to prove those bytes describe the right objects at the right tick. This software milestone doesn't require an FPGA.

I'd start with a small test application whose live objects and independent ground-truth log I control. Before connecting an actual game, I want these checks to pass:

- Read changing entity positions and the camera from the running target and compare them with its ground truth. A prerecorded fixture alone doesn't pass this check.
- Handle empty scenes, entity creation/removal and target restarts without keeping stale object references or mixing sessions.
- Reject unreadable memory, unsupported layouts, partial reads and inconsistent frames with clear errors. Don't treat an access failure as a reason to bypass protection.
- Encode accepted objects into the existing snapshot format, then compare the processed positions and IDs with the software reference.
- Record the target build/layout version, capture sequence, mismatches and capture latency, so the result can be reproduced.

I would call this milestone complete only after a live capture matches the controlled target and its failure cases behave correctly. An actual game adapter then needs its own access method, layout and camera tests. There is no stealth client, anti-cheat bypass or validated commercial-game integration in this repo. The [acquisition test plan](docs/game-integration.md#testing-the-acquisition-layer) gives the acceptance criteria in more detail.

## What works now

The scene fixture has three entities. Two land inside the camera's clip volume and one lands outside it. The simulation checks their projected positions against a Python reference, returns the records through DMA, and draws the two on-screen points.

Under that example I have a registered-buffer DMA interface, separate read and write queues, polled completions, bounds and permission checks, cancellation for queued work, and a watchdog. The host works with buffer handles rather than choosing physical addresses. Only the simulation backend is implemented.

The saved Icarus and Verilator runs each passed 100 deterministic seeds and both RTL test cases. Each main regression completed 216 descriptors and observed 851 DMA TLPs. The read tests reached four outstanding requests and returned completions out of order. I keep the [validation notes](docs/validation.md) beside the JSON and XML evidence so it's clear what those checks cover.

There is also a complex I/Q FIR example. I'm keeping that as a second use of the transport, but the game scene is the main application I want a reader to follow.

## Where I want to use it

| Application | What I want to inspect | Where it stands |
|---|---|---|
| Live object acquisition | Obtain and decode objects from a selected running application | Next milestone; no process-memory reader or live acquisition tests exist yet |
| Game debug view | Entity positions and the camera transform from one tick | The synthetic scene and static view work in simulation |
| Replay and QA tool | Whether the same recorded frame produces the same screen positions | The deterministic frame check works; a replay reader and timeline still need to be written |
| Spectator view | State deliberately published by a game or server | An integration direction; no adapter or live viewer yet |
| FPGA processing experiment | The cost of sending and processing each frame | The transfer model works; I haven't measured a physical board or shown a speedup |

I've written a [game integration guide](docs/game-integration.md) around that path. If you're starting in the hardware folder, the [RTL reading guide](rtl/README.md) follows one game frame through the modules.

## Try the game scene

From the repository root, install the tools and Python environment:

```sh
brew install python@3.13 verilator icarus-verilog
python3.13 -m venv .venv
source .venv/bin/activate
python -m pip install -r requirements.lock
python tools/generate_interface.py --check
python -m unittest discover -s tests -v
python tools/run.py --sim verilator --seeds 100 --demo telemetry
```

Open `artifacts/verilator/scene.svg` for the debug view. `telemetry.json` contains each entity ID, its normalized screen coordinates and the clip-volume flag. `report.json` records the transfer cases and `results.xml` records the test outcomes. The SVG is generated after simulation; there isn't an interactive game window behind it.

To check both simulators and include the FIR example:

```sh
python tools/run.py --sim icarus --seeds 100 --demo all
python tools/run.py --sim verilator --seeds 100 --demo all
python tools/summarize.py
```

`--demo telemetry`, `iq`, `all` or `none` selects the application checks. `--seeds N` uses seeds `0..N-1`, with 100 as the default. `--waves` keeps waveforms, which can get large. Everything goes into `artifacts/<sim>/`. A failed build or test makes the command exit nonzero.

The recorded development runs used Python 3.13, Icarus 13.0 and Verilator 5.048. The package requires Python 3.12 or newer; the quick start above uses 3.13.

## Follow one frame

```text
Game-owned scene: camera + entity positions from one tick
        |
        | freeze and encode a stable snapshot
        v
DmaClient -> registered host buffer -> H2D DMA
        |
        v
FPGA reference RAM
        |
        | simulation harness moves words into the application ports
        v
snapshot_guard -> accepted frame -> project_point
        |
        v
entity ID + normalized x/y + clip-volume flag
        |
        | harness stores output records, then D2H DMA returns them
        v
Host debug view / future replay inspector
```

`dma_if_pcie` and `pcie_axil_master` come from the pinned, MIT-licensed `alexforencich/verilog-pcie` project. They handle DMA TLPs and BAR transactions. My surrounding interface supplies the buffer registry, descriptors, completions and application examples. The [third-party notes](THIRD_PARTY.md) identify the source and the small cocotb compatibility patch.

There is a gap in that diagram worth keeping visible. The simulation harness reads FPGA RAM through the BAR, clocks words into the parser and points into the projector, then writes the output records back through the BAR. An autonomous RAM-to-application sequencer hasn't been implemented. The DMA transfers are real transaction-level RTL simulation, but the harness still joins the memory and application stages.

## The game frame format

I'm using one fixed format for now, with little-endian fields:

| Field | Stored as |
|---|---|
| Magic | Eight bytes: `DMALAB01` |
| Version and sequence | Two `u32` values; version 1 and an even sequence |
| Timestamp | `u64`; the application defines the units |
| World-to-clip matrix | 16 row-major signed Q16.16 values |
| Entity count | `u32`, up to 128 |
| Each entity | `u32 id`, signed Q16.16 `x, y, z`, `u32 flags` |
| Trailer | Repeated sequence, then CRC32/ISO-HDLC |

A frame takes `100 + 20*entity_count` bytes. The CRC includes every earlier byte, including the repeated sequence. The polynomial is reflected `0xedb88320`, with initial and final XOR `0xffffffff`, matching `zlib.crc32`.

I repeat the sequence and check the CRC to catch stale or damaged snapshots. That doesn't make reading a changing scene atomic. The publisher still has to freeze one consistent frame before handing over the buffer. The RTL accepts strictly increasing even sequences; the stream needs to restart before sequence wrap.

The flags word is carried as application data. It doesn't currently implement health, teams, local-player selection or line-of-sight checks. The projector's `visible` output only means the point is inside the clip volume. It doesn't tell me whether another object blocks the player in the game.

For the camera, `project_point.sv` multiplies `[x,y,z,1]` by the matrix and divides by positive clip W. It checks X, Y and Z against `-W..W`, and returns Q16.16 normalized X/Y. Division truncates toward zero. I still need engine-specific tests for matrix layout, handedness, depth range and viewport mapping. The current fixture uses an identity matrix.

## Sending a frame through the host API

Here is the transport part with game data. This runs inside a cocotb coroutine after `SimBackend(dut)` has been started:

```python
from fpga_dma_lab import DmaClient
from fpga_dma_lab.examples import snapshot

client = await DmaClient(backend).initialize()
frame_buffer = await client.allocate_region(4096, DmaClient.READ)

# These are two scene entities, using Q16.16 positions.
# 65536 means 1.0; -32768 means -0.5.
entities = [(7, -32768, 16384, 0, 1), (8, 32768, -16384, 0, 1)]
frame = snapshot(sequence=2, entities=entities)  # Identity camera by default.
client.store(frame_buffer, 0, frame)
request = await client.host_to_fpga(frame_buffer, 0, 0, len(frame))
assert (await client.wait(request)).status == 0
assert await client.read_fpga(0, len(frame)) == frame

# The test harness drives the parser/projector separately.
# Sending the frame doesn't automatically start those application blocks.
await client.release_region(frame_buffer)
await client.close()
```

`READ` means the device may read host memory, and `WRITE` means it may write host memory. I would register input frames READ and output records WRITE. `sim/test_system.py` has the complete existing scene check, including parser control, projection and the D2H return.

I use one client per endpoint. Its command lock keeps staging-register writes together and serializes completion polling. Registry changes, reset and allocation still need application-level exclusion from producers. A future game publisher should enqueue its stable frames through that owner rather than letting every game subsystem write device registers.

The backend provides register and byte access, memory allocation, mapping permissions, a command lock and timing methods. Only `SimBackend` ships. The [Windows driver design](docs/windows-driver.md) explains how a real backend would own DMA mappings and expose opaque handles to an application.

### What happens when the game gets ahead of the device

Once I submit work, the device owns the buffers until I drain the pending requests. The API rejects host reads/writes, FPGA BAR memory access and registry changes during that time. It's conservative, but it keeps this version's ownership rules easy to follow.

Each direction has 16 queued slots. A full queue raises `QueueFull` without creating a completion. Invalid accepted descriptors finish with an error and don't start DMA. The checks include region generation, permissions, host bounds and overflow, and FPGA bounds. An in-range zero-length request completes without a DMA TLP.

A game-facing policy for old frames still needs to be added. I'd rather skip a frame before submission than build a long backlog of stale camera data. Once a request is active, cancellation cannot pull back PCIe traffic already issued. Queued work can be cancelled; active work reports `active_cannot_cancel`.

A host wait timeout leaves the request pending and keeps ownership with the device. The device watchdog defaults to 100,000 controller clocks, or 400 microseconds at the simulated 250 MHz clock. If it fires, the endpoint disables and halts, resets the internal engine, and drains queued work with errors. It needs full endpoint/link teardown before reuse. The ordinary quiescent reset isn't a way to recycle tags while old traffic might still exist.

For D2H transfers, I wait for the write engine and then read a private host fence word to order the posted writes. The private word lets an output buffer stay write-only. A successful fence still cannot prove that a platform accepted every posted write: a denied write has no PCIe completion. The tests deliberately drop one and check the unchanged destination and the root's denial log. Errors report zero **confirmed** bytes; they don't guarantee the destination was untouched.

`reset()` requires an idle endpoint, changes the epoch and invalidates handles. `close()` requires outstanding work to have been drained. A halted simulation keeps its mappings until link teardown. Completed results stay in `client.results` until reset or client disposal, so a long-running viewer will also need a bounded result-retention policy.

## What I've fixed for this version

| Setting | Current value |
|---|---|
| DMA addresses / TLP data | 64-bit addresses / 64-bit data |
| Outstanding read tags | 4 |
| Max payload / read request | 128 / 512 bytes |
| Queues / completion FIFO | 16 per direction / 16 completions |
| Active descriptors | One at a time, alternating direction preference |
| Region registry | 16 entries with base, length, generation and permissions |
| FPGA memory | 65,536 bytes; 65,520 available to the application |
| BAR0 | 128 KiB; little-endian 32-bit registers |
| Interrupts, scatter/gather, multiple clients | Not implemented |

The controller assumes two 64-bit RAM segments and 16-bit RAM addresses. The upstream engine has more parameters, but changing one isn't enough to change this integration. I'd need to update the controller, memory implementation, capabilities and tests together. [Registers](docs/registers.md) has the exact addresses.

## A second application: I/Q filtering

I kept `fir7.sv` to check that the same transfer path can feed a different application. It filters complex signed-16 I/Q samples using `[1,2,3,4,3,2,1]/16`. It starts with zero history, uses 32-bit sums, rounds halves away from zero and clamps to signed 16 bits. History advances only when input valid and ready meet; output data and valid stay put during a stall.

The example checks 256 complex samples against the integer reference bit for bit and against a floating reference within 0.5 LSB, then returns them through DMA. `iq.csv` holds the results. The saturation signal pulses for a newly computed saturated sample; it isn't a held output sideband. With these positive unity-gain coefficients, valid signed-16 inputs can't reach the clamp.

This isn't wired into the game example, and there is no ADC, SDR interface or measured continuous sample rate. I'm keeping it as a separate processing example rather than calling it a game-input filter.

## What I'd build next

First I'd implement and test the live acquisition adapter described above. That connects the processing framework to a real data source. After a controlled target passes, I'd add a supported game adapter, save captured frames, and build a replay reader before a live viewer. The [integration roadmap](docs/game-integration.md#what-id-build-next) keeps those steps separate from the later board work.

For hardware, I need a banked RAM with explicit arbitration and a RAM-to-stream sequencer. The current byte-array memory is a functional simulation reference and isn't a qualified dual-port BRAM implementation. The projection divider is combinational; it needs a practical pipeline before a high-frequency board build.

My Nexys A7 doesn't have an onboard PCIe endpoint connection. A UART/Ethernet version could reuse the application logic, but the PC would explicitly send the frames and receive results. A physical PCIe version needs another board, a vendor endpoint wrapper and a real driver. I've kept [board options](docs/boards.md), [hardware porting notes](docs/hardware-porting.md) and the [Windows design](docs/windows-driver.md) separate so the simulation results don't imply those pieces exist.

## Where things are

```text
rtl/                       game-frame parser, projector, DMA controller,
                           reference memory, FIR and the RTL reading guide
python/fpga_dma_lab/        host API, scene codec and software references
sim/                       PCIe root model, bus adapters and application tests
vendor/                    pinned upstream PCIe engine and BAR bridge
spec/interface.json        register/status source for generated constants
tools/                     interface generator, simulation runner and reports
tests/                     Python schema and reference-model checks
docs/game-integration.md   publisher example, camera conventions and next steps
artifacts/                 projected scene, raw records and verification evidence
.github/workflows/         CI configuration; the recorded runs were local
```

Original additions use the MIT license. The upstream files keep their own notices. See [LICENSE](LICENSE) and [THIRD_PARTY.md](THIRD_PARTY.md).
