# Following a game frame through my RTL

If you're opening this folder first, the game application I have in mind is a debug or replay view. The host supplies the game's own entity positions and camera from one frame. The hardware-side blocks check the snapshot and turn positions into normalized screen coordinates.

I would start with `snapshot_guard.sv` and `project_point.sv`, then read `lab_control.sv` to see how the bytes get to and from FPGA memory. `dma_lab.sv` connects those pieces to the generic PCIe interfaces. The FIR is a separate example; it isn't involved in drawing the scene.

## The module map

| File | What it does for the application |
|---|---|
| [snapshot_guard.sv](snapshot_guard.sv) | Checks the game frame's schema, count, sequence, trailer and CRC before the caller uses it |
| [project_point.sv](project_point.sv) | Converts one world position with the published camera matrix into normalized X/Y and a clip-volume flag |
| [lab_control.sv](lab_control.sv) | Owns descriptors, registered host regions, completion records and the reference FPGA RAM |
| [dma_lab.sv](dma_lab.sv) | Connects the controller, upstream PCIe engine/BAR bridge and application ports used by simulation |
| [fir7.sv](fir7.sv) | Filters complex I/Q samples in the secondary application check |
| [interface.svh](interface.svh) | Generated register and status constants; I change their source in `spec/interface.json` |

## First, make sure the frame belongs together

`snapshot_guard` takes 32-bit little-endian words through `in_data`. A word is accepted on a rising edge when `in_valid` and `in_ready` are both high. The caller pulses `start` to begin a new frame and marks its final word with `in_last`.

The guard reads the magic and version, remembers the even sequence and entity count, checks the repeated sequence at the end, and updates CRC32 as the words arrive. At the final word it pulses `done` and records whether the frame was accepted. Only accepted frames advance its remembered sequence.

I keep CRC and sequence checking separate from gameplay meaning. The guard can tell me that a frame is stale or damaged. It can't tell me that the publisher used the correct camera or froze the scene at the right tick. It also doesn't buffer the entity records for the projector. The caller is responsible for retaining the data and using it only after acceptance.

In the current simulation, the harness does that coordination. There is no autonomous controller here that reads a complete frame from RAM and streams its entities through the projector.

## Then follow one entity

`project_point` takes signed Q16.16 X/Y/Z and a flattened row-major matrix. Each group of 32 matrix bits holds one signed coefficient; element zero is in the lowest 32 bits. The block forms the homogeneous position `[x,y,z,1]`, calculates four clip coordinates, and divides X/Y by positive W.

For example, with the identity matrix, the stored position `(-32768, 16384, 0)` means `(-0.5, 0.25, 0)`. The output is X `-32768`, Y `16384`, with the clip-volume flag high. That's the first on-screen point in the scene fixture.

The `visible` name needs some care. Here it means inside the clip volume, including its Z bounds. It doesn't mean the game has checked walls, line of sight, teams, health or local-player state. Those rules aren't implemented in this block.

The projector is combinational: its outputs follow its inputs without waiting for a clock edge. The divide is also combinational. That's useful for a functional simulation reference, but I still need to pipeline or replace it for a practical high-frequency board design. I haven't synthesized or timed this implementation on a board.

## How the frame reaches memory

`lab_control` sits behind the BAR bridge. The host registers a buffer with a base, length, generation and read/write permissions, then submits a descriptor naming that region and an offset. I check the descriptor before handing it to the upstream DMA engine.

The descriptor queues hold 16 requests in each direction. One descriptor executes at a time, though the read engine can keep four PCIe read TLPs outstanding within that descriptor. Those are different kinds of concurrency: four TLPs don't mean four whole game frames are processing independently.

On a read, host data lands in the reference RAM. On a write, RAM data goes back to the host, followed by a read of a private fence word. Completion records carry the request ID, status, confirmed byte count and epoch. The [main README](../README.md#what-happens-when-the-game-gets-ahead-of-the-device) explains ownership and timeout behavior.

The RAM is a byte-array simulation reference with segmented DMA ports. It still needs a banked implementation and arbitration for a board port. I wouldn't assume that this version will infer the block RAM structure I want.

## Read the harness beside the hardware

In [sim/test_system.py](../sim/test_system.py), `demos()` performs the scene application check:

1. Encode a synthetic camera/entity frame and send it through H2D DMA.
2. Read the received bytes through the BAR and drive `snapshot_guard`.
3. Check that stale, corrupt, torn and truncated frames are rejected.
4. Drive each accepted scene point into `project_point` and compare its answer with the Python reference.
5. Put the projected records into FPGA RAM, return them through D2H DMA and draw a static SVG.

That is the complete application path tested today. A game publisher, memory-to-stream sequencer, replay reader and live viewer are the next pieces, described in [the game integration guide](../docs/game-integration.md).

## A note on the comments

I've kept comments around the decisions that are easy to miss when reading this as software: when a handshake captures data, which process owns memory, why a completion needs a fence, and what reset can safely discard. A `for` loop inside combinational logic doesn't mean one game entity per clock. The clocks and registers around it determine the timing.

The PCIe engine under `vendor/` is upstream code and keeps its original attribution and comments. This folder describes the integration and application around it.
