# What I've checked so far

I keep the raw results under `artifacts/<sim>/`: `results.xml` for the test cases, `report.json` for the transfers and application checks, and `faults.json` for the queue/timeout run. `artifacts/validation.json` collects the successful runs and fingerprints their source files. `artifacts/unit-tests.txt` records the Python checks. The GitHub workflow is configured, but these recorded results came from local runs.

## The recorded runs

| Check | Icarus 13.0 | Verilator 5.048 |
|---|---|---|
| RTL test cases | 2 passed | 2 passed |
| Deterministic transfer seeds | 100 | 100 |
| Main-regression completed descriptors | 216 | 216 |
| Observed DMA TLPs | 851 | 851 |
| Concurrent read requests reached | 4 | 4 |
| Out-of-order read responses | Checked | Checked |
| Scene projection and frame rejection | Passed | Passed |
| Complex I/Q samples | 256, bit-exact | 256, bit-exact |
| Maximum floating-reference FIR difference | 0.5 LSB | 0.5 LSB |

The four Python test methods also passed. I treat these as evidence for the specific fixtures and transfer cases below. They don't establish a live game's frame rate or a board's performance.

## Follow the game application check

The harness makes a synthetic camera/entity snapshot, transfers it by H2D DMA, and reads the received bytes back through the BAR before clocking the RTL parser. It checks that stale, corrupted, torn and truncated frames are rejected.

It then drives three scene points into the projector with an identity camera. The signed Q16.16 positions and clip-volume flags must match the Python reference exactly. One point is off-screen. The harness stores the output records, brings them back through D2H DMA and draws the two on-screen entities into `scene.svg`.

That is the game-specific check implemented today. I haven't tested an engine camera, moving-camera RTL replay, gameplay visibility, a live HUD or a spectator API. The moving-camera snippet in the [game guide](game-integration.md) is a software example, not another recorded RTL run.

## Why I kept the transport tests underneath it

A correct screen-space calculation isn't useful if the frame arrived at the wrong address. The seeded transfer cases vary payload bytes and unaligned host/FPGA offsets. Their length schedule is 0, 1, 3, 4, 7, 127, 128, 129, 511, 512, 513, 2048 and 4096 bytes. They include host addresses above 4 GiB and spans across 4 KiB boundaries.

Every round trip checks the payload and an eight-byte destination guard. The first set also checks the received FPGA bytes through the BAR. I delay read responses independently to exercise four outstanding reads and actual response reordering. The tests check request/payload limits and reject any emitted TLP that crosses a 4 KiB boundary.

The negative cases cover host/FPGA bounds, arithmetic overflow, hardware generation mismatch, disabled bus mastering, direction permissions, released handles, reset epochs and root-domain read denial. A separate case drops a posted write. Its fence can still succeed, so the test checks the unchanged destination and the root denial log rather than pretending that the write returned a PCIe error completion.

For queues, I hold read responses while letting receive dispatch continue. The test fills all 16 slots in both directions, rejects overflow, cancels queued work with a CANCELLED completion, then resumes the healthy requests. A short host wait timeout must leave ownership pending. Finally, I drop an active read to trigger the device watchdog, check the queued-error drain, and confirm that a halted endpoint refuses a normal reset and retains its mappings until teardown.

This is deterministic seeded coverage, not exhaustive verification. The four-read assertion runs when there are at least 13 seeds; the recorded full runs use 100.

## The second application check

The FIR test transfers 256 complex signed-16 samples, drives the RTL with output stalls, and compares every result with the integer reference. It also checks the floating reference within half an LSB, then returns the output through DMA. The Python checks separately cover impulse response, rounding, DC extrema and byte packing, plus snapshot corruption/length, empty scenes and signed/behind-camera projection.

I haven't attached an RF source or measured a continuous sample rate. This remains a second processing example beside the game scene.

## The warnings I still see

Verilator accepts the configured design with nonfatal upstream warnings. The pinned engine has an unused extended-tag FIFO branch whose zero-width indexing produces SELRANGE warnings in the four-tag configuration; the constant tag-count condition disables that branch. CASEINCOMPLETE and combinational nonblocking-assignment warnings remain upstream as well. The runner suppresses width/UNOPTFLAT diagnostics and requests C++17 for the executable.

I wouldn't describe this as warning-free lint or a formal proof. Before a board port I'd still need synthesis, resource-fit and timing results, CDC/reset checks, a vendor endpoint and physical link, Windows driver tests, actual IOMMU checks and hardware throughput measurements. The reference RAM and combinational divider also need board-ready replacements.

## Documentation update, 2026-11-19

I rewrote the README, guides and comments to follow the game application more clearly. This update doesn't add an engine adapter or change the processing logic. The saved simulation reports and their original fingerprints remain evidence of the earlier runs. For the comment edits, I separately checked that removing comments and whitespace leaves the same RTL text, and that the Python, specification and vendor source files are unchanged. I checked the documentation links and examples as part of the writing update; I haven't presented it as a new hardware test run.

## Public report copies

Before publishing, I removed the local hostname and changed absolute source paths in the JUnit reports to `sim/test_system.py`. Test results, seeds, timing and counters are unchanged. This only makes the saved reports portable; it is not a new test run.
