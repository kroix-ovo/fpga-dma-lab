# How I want to connect this to a game

The part I'm interested in is the whole frame path. A game has a camera and a set of entities at a particular tick. I want to capture those together, send a stable copy through the FPGA pipeline, and compare the returned screen positions with what the game expected to draw.

That gives me a few useful applications: a developer view while building a small game, a replay inspector when a camera bug is hard to reproduce, or a spectator view using data the game already publishes. The current repository gets as far as a synthetic frame and a static debug image. The live acquisition adapter, replay reader and live viewer below are proposed integration work. The missing acquisition adapter is the next milestone: the current transport cannot attach to a process or discover its game objects.

## Start with the data the game owns

I'd put the publisher at a point where the engine can give me a consistent scene. Copying one entity before a simulation update and the camera after it could produce a valid CRC for a frame that never actually existed.

My intended capture order is:

1. Finish the game tick or take the engine's documented scene snapshot.
2. Copy the selected entities and the camera from that same state.
3. Convert positions and the world-to-clip matrix into the frame format.
4. Assign the next even sequence and encode the CRC.
5. Submit the stable bytes, then leave that buffer alone until completion.

The transport can't work out what a game's coordinates mean. The adapter has to decide which entities to publish, what its IDs mean, and how the camera convention maps into this format. Team, health and gameplay visibility would belong to a documented game profile. The current RTL just carries the flags word; it doesn't interpret those properties.

## A small publisher example

This is a software example of making game frames with the codec already in the repo. It doesn't send them to a physical board or create a replay viewer. Run it with the package installed or with `PYTHONPATH=python` from the repository root.

```python
from fpga_dma_lab.examples import snapshot, parse_snapshot, project, IDENTITY

for tick in range(3):
    # Pretend this position came from our game's completed simulation tick.
    # Q16.16 stores 1.0 as 65536, so this moves the entity by 0.25 per tick.
    entity_x = -32768 + tick * 16384
    entities = [(7, entity_x, 16384, 0, 1)]

    # A small horizontal camera translation. This is an orthographic example,
    # not a conversion of a particular engine's perspective camera.
    camera = list(IDENTITY)
    camera[3] = -tick * 8192
    frame = snapshot(sequence=2 * (tick + 1), entities=entities, matrix=camera)

    decoded = parse_snapshot(frame)
    point = decoded["entities"][0][1:4]
    screen_x, screen_y, inside_clip = project(decoded["matrix"], point)
    print(tick, len(frame), screen_x / 65536, screen_y / 65536, inside_clip)
```

This makes three 120-byte frames. The normalized X positions are `-0.5`, `-0.375` and `-0.25`; Y stays at `0.25`. All three are inside the clip volume. Those are software-reference results, not additional RTL test coverage. The existing RTL scene test still uses its original three entities and identity camera.

The codec currently fills the timestamp with a fixed fixture value. A real publisher needs to make that field an explicit tick or time value, document the units, and test the change. I wouldn't use the fixture timestamp as a measurement of capture latency.

## Get the camera right before adding a viewer

The matrix is row-major. I multiply it by the column vector `[x,y,z,1]`:

```text
clip_x = m00*x + m01*y + m02*z + m03
clip_y = m10*x + m11*y + m12*z + m13
clip_z = m20*x + m21*y + m22*z + m23
clip_w = m30*x + m31*y + m32*z + m33
```

The stored arithmetic uses Q16.16 operands, so the products have more fractional bits until division. The projector divides X and Y by positive W, then returns normalized coordinates in Q16.16. It accepts the clip volume `-W <= X,Y,Z <= W` and rejects nonpositive W.

Some engines store a transposed matrix, use a different handedness or define depth as `0..W`. I'd test a known center point, each screen edge, the near and far depth boundaries, and a point behind the camera before relying on an adapter. An identity matrix matching a reference doesn't establish that an engine's perspective camera is correct.

For a full viewport of width `w` and height `h`, a top-left-origin viewer could map normalized coordinates like this:

```text
pixel_x = (ndc_x / 65536 + 1) * w / 2
pixel_y = (1 - ndc_y / 65536) * h / 2
```

At the right/bottom edge, that formula reaches `w`/`h`; an actual pixel buffer needs an edge/clamping policy. The current SVG maps into an inset 600-by-400 drawing area. Its coordinates aren't a tested engine viewport conversion.

Also, `inside_clip` isn't a line-of-sight result. An entity can be in the camera frustum and behind a wall. If the application needs gameplay visibility, the game has to publish it and the consumer needs a separate rule for it.

## What comes back

The existing harness returns one little-endian `<IiiI>` record per input entity:

| Word | Meaning |
|---|---|
| `u32` | Entity ID |
| `i32` | Normalized X, Q16.16 |
| `i32` | Normalized Y, Q16.16 |
| `u32` | Clip-volume flag, 0 or 1 |

The output currently has no frame header or checksum of its own. The harness knows the input frame and entity count, so it can compare the records directly. For a live viewer I'd add an output frame sequence, schema version, count and integrity check before putting multiple frames in flight. A DMA completion ID and epoch identify a transfer; they aren't a replacement for a game frame ID in a saved replay.

## Keep frame age visible

At the current maximum of 128 entities, a snapshot is 2,660 bytes. Sixty such snapshots per second are 159,600 payload bytes per second, before output data and transport overhead. That's a size calculation, not a measured frame rate or proof that offloading is worthwhile.

I would measure capture time, queue wait, transfer time, processing time and display age separately. A fast projector doesn't help a debug view if it's showing a camera from several ticks ago. The current tests don't measure a live game's frame age.

For the first adapter I'd keep one frame active and skip new captures while busy. That matches the current API's conservative ownership rules. Later, double buffering could let the game prepare another frame while processing continues, but the current client rejects host buffer access while any request is pending. Supporting overlap means changing that ownership model and testing it, not just allocating a second buffer.

## What I'd build next

### 1. Implement live object acquisition

I'd begin on the host with a controlled running application. It should keep real, changing scene objects in its RAM and independently report their expected IDs, positions, camera and capture generation. The inspector would use normal authorized OS/debug access, or a supported application interface. It would decode a documented layout and turn the captured state into the existing snapshot format.

There is no implementation of that inspector here yet. A registered DMA region is memory the transport owns; it doesn't locate a game's objects or grant permission to read them. I also need a separate application layout/decoder, since an address and some bytes don't establish an entity's identity or position.

For the first adapter I'd define attach, capture and detach operations, with an explicit target identity and layout version. Each capture would return either a complete, validated frame or a clear failure. Unsupported versions, unreadable memory and process exit should stop or reject capture, not produce plausible-looking coordinates. The software path should work and be tested before any physical FPGA integration.

### Testing the acquisition layer

These are planned checks, not results from the existing simulation:

| Test | What I'd accept as a pass |
|---|---|
| Live capture | Changing objects read from the running controlled target match its independent ground-truth log by capture generation; synthetic input alone isn't sufficient |
| Identity and layout | The selected process/session and declared layout version are correct; mismatches are rejected before decoding |
| Object lifetime | Creation, removal and an empty scene produce the expected IDs/counts without stale references |
| Coherent frame | Camera and entity values belong to the same capture generation; concurrent updates yield a retry or rejected capture rather than a mixed frame |
| Read failure | Partial/unreadable ranges and permission denial return explicit errors, with no fabricated frame or protection bypass |
| Process lifecycle | Exit, detach and restart invalidate the old session and references; a new session is explicitly established |
| Pipeline integration | The accepted live capture encodes/decodes correctly and its projected IDs/positions match the independent software reference |
| Reproducible evidence | A report identifies the test target build, layout version, sequences, mismatch counts, failed captures and capture-latency distribution |

I'd first check acquisition and decoding against the target's log, then feed the accepted captures into the processor. Comparing the processor with its own input is useful, but it doesn't prove that input came from the correct live objects. I'd require no unexplained mismatches for the declared acceptance cases and publish the cases exercised; that still isn't a guarantee over every application state.

The target and inspector also need a capture-consistency mechanism. A CRC computed after reading a mixed frame only certifies those mixed bytes, so the acquisition test must establish consistency before encoding. A game API, debug build or cooperative test target can provide a generation/snapshot contract; an arbitrary changing process may not provide one.

### 2. Record captured game scenes

After live acquisition passes, I'd keep captures with their expected screen results, including moving entities, a moving camera and object creation/removal. Then I'd add a replay file format and reader so a bad frame can be reproduced without the target running.

The three-frame snippet above explains the codec using software-generated positions. It isn't a live memory reader or evidence that acquisition has been tested.

### 3. A frame processor in hardware

The current harness feeds the parser and projector. I'd replace that bridge with a memory sequencer, keep RAM ownership explicit, and carry a frame ID through processing. The output would only become available after the complete frame had passed validation. I'd also pipeline the divider and add randomized perspective-camera tests.

### 4. A replay inspector

I'd give the host a frame selector, entity labels, camera information and a comparison with the software reference. The first useful result would be replaying the same frame twice and getting identical positions, rather than starting with a live overlay. No such UI ships yet.

### 5. Validate one game adapter

I'd pick one game or engine with an authorized inspection or export path and validate its adapter against that exact build. The adapter would handle its scene API, matrix layout, units, depth range, entity IDs and capture timing. I would keep the DMA contract unchanged unless the application actually needs a new schema.

There isn't a Unity, Unreal, Godot or commercial-game adapter in this repository today. Adding an engine name to the documentation wouldn't establish compatibility.

### 6. The physical path

For the Nexys A7, I'd use an explicit UART or Ethernet application transport. For PCIe, I'd use a suitable endpoint board and implement the Windows mapping/driver design. The [hardware notes](hardware-porting.md) cover that work. Either path needs its own hardware evidence before I'd describe the game pipeline as running on a board.
