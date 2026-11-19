# How I'd connect the game publisher on Windows

I haven't written the Windows driver yet. This is the backend design I would implement after the simulation contract is settled. There is no `.sys`, INF, signed package, WDK build or executable Windows device client in this release.

I want the game adapter to submit a buffer handle, offset and length. The driver should own the mapping behind that handle, so the application doesn't need to know a bus address or keep track of pinned pages itself.

## I'd start with driver-owned buffers

For v1 I'd use an exclusive KMDF function driver and restrict the device to the intended local application or service. In hardware preparation I'd validate the BAR resources, signature and ABI, create a 64-bit bus-master DMA enabler, and keep traffic disabled until the registry and private fence buffer are ready.

My first buffer path would use `WdfCommonBufferCreate`. The framework provides a device logical address and a CPU virtual address. I'd return an opaque ID to the game adapter and use buffered IOCTLs to copy frames into those allocations and read completed outputs back. It's an extra copy, but it avoids making the first driver depend on a game's user-pointer lifetime or assuming its pages form one contiguous DMA interval. I'd cap allocated bytes, region count and outstanding work.

Microsoft describes [common buffers](https://learn.microsoft.com/en-us/windows-hardware/drivers/wdf/using-common-buffers) and [DMA transactions/transfers](https://learn.microsoft.com/en-us/windows-hardware/drivers/wdf/dma-transactions-and-dma-transfers). A WDF transaction can become several transfers. A later zero-copy path would have to use the framework's scatter/gather mappings and split them into descriptors this controller supports. The current registry describes one contiguous logical interval, not an arbitrary MDL.

## The application interface I'd expose

These are proposed IOCTLs, not implemented entry points:

| Operation | What the caller supplies or receives | Rule I'd enforce |
|---|---|---|
| GET_CAPS | ABI, sizes and queue limits | Validate structure size and version |
| ALLOC_BUFFER | Size/direction → opaque buffer ID | Allocate a mapped common buffer within the owner's quota |
| WRITE_BUFFER | ID, offset and bytes | Host-owned input only; check arithmetic and bounds |
| READ_BUFFER | ID, offset and length → bytes | Completed, host-owned output only |
| SUBMIT | ID, offsets, length, direction and request ID | Resolve the mapping, check permissions, serialize BAR staging |
| GET_COMPLETIONS | Bounded result array | Match request IDs and epochs |
| CANCEL | Request ID | Cancel queued work; retain active mappings |
| RELEASE_BUFFER | Buffer ID | Require no pending work, disable registry, then unmap |
| RESET_QUIESCENT | Expected epoch | Require an idle endpoint and invalidate handles |

I'd use fixed-width fields, explicit lengths, reserved-zero fields and overflow-safe 64-bit checks. IDs would belong to the opening file context, so another process couldn't resolve them. I wouldn't expose a general BAR-write operation or raw DMA address to the game adapter; those belong to the backend's device setup.

For game frames, I also want an application sequence in the payload. The completion request ID tells me which transfer finished, but the viewer still needs to know which captured frame the returned records describe.

## Keep ownership through timeout and close

I'd start with a serialized polling worker at PASSIVE_LEVEL and the same register ordering as the simulator. MSI/MSI-X would need matching RTL and resource handling; interrupts aren't implemented in v1.

A timed-out application wait doesn't release a buffer that hardware still owns. Neither does an IOCTL cancellation request. On close, power-down or removal, the driver needs to stop new submissions, cancel queued work, drain or contain active traffic, disable bus mastering and tear down DMA mappings under the OS/framework lifecycle before freeing memory.

A watchdog timeout or surprise removal needs platform-aware recovery. I still need to choose and verify the WDF callbacks, reset mechanism and DMA-remapping behavior. Simply clearing the software request list would leave the hard part unresolved.

The FPGA registry is a correctness check, not isolation against untrusted firmware. I'd keep the host's DMA-remapping protections enabled. The root model in this repository is a behavioral permission domain; it doesn't establish Windows IOMMU compatibility.

## What I'd test before using it with a game

I'd build with the chosen WDK and appropriate development signing, then use Driver Verifier and the applicable HLK checks. The lifecycle cases matter as much as a successful transfer: allocation failure, malformed IOCTLs, 32/64-bit callers, process exit, cancellation races, sleep/resume, surprise removal, link reset and late writes.

I'd also test addresses above 4 GiB, mapping denials and known-pattern loopback, then measure frame age, throughput and CPU cost with real buffers. Those are acceptance criteria for the future driver. The existing simulation results don't claim they've happened.
