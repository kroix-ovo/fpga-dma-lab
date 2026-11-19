# The PCIe boards I looked at

I kept three price bands here because the board cost matters for this project. These are candidates for a future game-telemetry board port, not boards I've run this design on.

The prices and availability below are the recorded **2026-11-18** research snapshot. I haven't refreshed them as part of this writing update. They exclude shipping, tax, adapters, power and programming accessories, so I'd check the complete setup cost before buying.

| Budget | Candidate and observed price | Interface and FPGA | Availability / caveat |
|---|---|---|---|
| Under $150 | [RHS LiteFury, $109](https://rhsresearch.com/products/litefury) | M.2 2280 Key M; PCIe Gen2 x4; XC7A100T-L2FGG484E; 512 MB DDR3 | Manufacturer listed **sold out**. This is not a currently purchasable recommendation at that price. |
| $150–300 | [RHS PicoEVB, $249](https://www.crowdsupply.com/rhs-research/picoevb) | M.2 2230 Key A/E; PCIe Gen2 x1; XC7A50T; onboard JTAG | Official campaign page listed **no longer available**. Use only if a verifiable used unit is found; no current used price verified. |
| $300–500 | [ALINX AX7103, $374 excluding VAT](https://www.fpgapro.com/product-detail/fpga-development-boards/artix-7/ax7103-fpga-dev-board-kit-with-amd-artix-7-xc7a100t) | Desktop PCIe Gen2 x4; XC7A100T-2FGG484I; 1 GB DDR3 | Retailer showed in stock; confirm kit contents and checkout total. Manufacturer source separately verifies board specifications. |

[AX7103 manufacturer page](https://alinx.com/detail/492), [manufacturer manual](https://alinx.com/public/upload/file/AX7103_User_Manual.pdf), [LiteFury/NiteFury sources](https://github.com/RHSResearchLLC/NiteFury-and-LiteFury), [PicoEVB sources](https://github.com/RHSResearchLLC/PicoEVB).

The awkward part is availability: both cheaper candidates were unavailable in those sources. I don't have a verified currently available option in those two bands. If I considered a used board, I'd want the exact FPGA part, schematic, programming interface, source license, constraints and a working endpoint example before calling it a usable alternative.

I'd also check the connector carefully. M.2 Key M and Key A/E aren't interchangeable, and a USB storage enclosure doesn't turn into a PCIe development connection. A passive adapter has to match the keying and lane wiring. A MacBook external enclosure would add another compatibility and cost question I haven't tested; the planned PCIe host is Windows.

## Nexys A7

I already have the Nexys A7, so I'd like to reuse it for the application logic. It doesn't have an onboard PCIe edge connector or routed PCIe endpoint interface. Ethernet moves packets; it doesn't give the board direct access to the host's memory.

The useful Nexys direction is a game-owned publisher explicitly sending frames over UART or Ethernet, with the parser/projector returning results over that same application transport. That still needs transport RTL, constraints, sequencing and hardware tests. This release doesn't supply them. The [Digilent board reference](https://digilent.com/reference/programmable-logic/nexys-a7/reference-manual) is the hardware starting point.
