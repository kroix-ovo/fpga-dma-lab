# What I still need for a board port

The simulation starts above the physical PCIe link. I can send TLPs through the engine and check the bytes, but there is no vendor endpoint, transceiver setup, link training, configuration-space hardware, board clocking or pin constraints in this project yet.

For the game application, that means I can test the frame contract now. I can't yet plug a board into the Windows host and send it a live game frame.

## Start at the board's own endpoint example

I'd first check the exact FPGA part, routed PCIe lanes, reference clock and reset against the board's schematic and working endpoint source. Then I'd generate or adapt its vendor endpoint with a 128 KiB BAR0, leaving relaxed ordering and unsupported features disabled at first.

The generic TLP buses in `dma_lab.sv` aren't pin-compatible with every vendor core. I need a wrapper that preserves request/completion headers, byte enables and backpressure, and keeps requester/completer IDs, payload limits, read-request limits, RCB and bus-master enable tied to real configuration space. I would simulate that wrapper separately before trusting it with the frame tests.

The current integration disables transmit sequence-number tracking. A physical wrapper may need it, along with different credit and transmit limits. I'd review the shared TLP arbitration and the upstream contract together rather than assuming the simulation defaults fit the board.

## Give the game pipeline real memory ports

The byte-array RAM in `lab_control.sv` is a functional model. It has segmented DMA access and BAR access from separate processes. I still need a banked synchronous RAM with the engine's ready/done and response timing, plus explicit ownership between DMA, host access and frame processing.

After that I'd add the memory sequencer: read a stable frame, feed the parser, wait for acceptance, send its entity records through the projector and store the outputs with their frame ID. The test harness currently does that coordination. It isn't an autonomous hardware pipeline yet.

The projection divider is combinational. I would pipeline or replace it before trying to meet a practical board clock, then measure latency and resource use rather than infer either from the functional model.

## Reset and clocks need their own work

I'd define each clock domain, synchronize control crossings and hold off traffic during reset, link-down and bus-master disable. A timeout needs a containment and recovery path that accounts for traffic already issued. Clearing a local FIFO doesn't make an old host-memory request disappear, so I can't reuse tags or mappings just because the controller returned to idle.

The driver design has the same lifetime problem. It needs to stop new work, handle queued and active requests separately, and retain mappings until platform/device teardown makes release safe. The [Windows notes](windows-driver.md) describe the intended ownership model.

## What would convince me it works

I would want synthesis, resource and timing reports, CDC/reset checks, correct programming and power behavior, and a known-pattern loopback on the real host. Then I'd run frame validation, partial/unaligned transfers, mapping-denial checks, repeated resets, removal/recovery and application data checks. Throughput and CPU use need measurements on that setup.

The current simulation doesn't establish electrical compatibility, PCIe compliance, timing closure, actual IOMMU behavior or Windows driver correctness. I haven't included guessed pin constraints or a placeholder wrapper that looks like a finished board port.

For the Nexys A7, the practical direction is an explicit UART/Ethernet frame transport. The host would send the application's own data and receive the processed result. That reuses the frame-processing idea, but still needs transport RTL, constraints and its own hardware tests.
