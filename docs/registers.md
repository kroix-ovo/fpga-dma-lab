# BAR register reference

All values are little-endian 32-bit words. BAR0 is 128 KiB.

| Name | Offset |
|---|---:|
| SIGNATURE | `0x0000` |
| CONTROL | `0x0004` |
| DEVICE_STATUS | `0x0008` |
| COMPLETION_COUNT | `0x000c` |
| QUEUE_COUNTS | `0x0010` |
| TIMEOUT_CYCLES | `0x0014` |
| FPGA_CAPACITY | `0x0018` |
| EPOCH | `0x001c` |
| STAGE_SLOT | `0x0020` |
| STAGE_GENERATION | `0x0024` |
| STAGE_OFFSET_LO | `0x0028` |
| STAGE_OFFSET_HI | `0x002c` |
| STAGE_FPGA_OFFSET | `0x0030` |
| STAGE_LENGTH | `0x0034` |
| STAGE_REQUEST_ID | `0x0038` |
| SUBMIT | `0x003c` |
| ABI_VERSION | `0x0040` |
| SUBMIT_STATUS | `0x0044` |
| CANCEL_ID | `0x0048` |
| CANCEL_STATUS | `0x004c` |
| COMPLETION_ID | `0x0050` |
| COMPLETION_STATUS | `0x0054` |
| COMPLETION_BYTES | `0x0058` |
| COMPLETION_EPOCH | `0x005c` |
| COMPLETION_POP | `0x0060` |
| COMPLETED_TOTAL | `0x0064` |
| FENCE_LO | `0x0070` |
| FENCE_HI | `0x0074` |

Region records start at `0x100`, stride 32, count 16: base low/high (+0/+4), size low/high (+8/+12), generation (+16), permissions (+20). They are write-only; unused fields return AXI SLVERR. FPGA RAM begins at `0x10000`; the last 16 bytes are private.

Status codes: OK=0, BAD_REGION=1, PERMISSION=2, BOUNDS=3, QUEUE_FULL=4, CANCELLED=5, TIMEOUT=6, DMA_ERROR=7, DISABLED=8.
