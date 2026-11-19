# Third-party components

`vendor/*.v` and `sim/pcie_if.py` originate from [alexforencich/verilog-pcie](https://github.com/alexforencich/verilog-pcie), commit `25156a9a162c41c60f11f41590c7d006d015ae5a`. The upstream MIT license is retained in `vendor/LICENSE`; individual source headers retain copyright notices. The upstream manifest lists the exact included files.

The PCIe bus adapter has a local compatibility patch for cocotb 2: sampled control values are converted to Python integers before mask operations, and data/parity are converted only for strobed DWORD lanes. Unknowns in active lanes still fail; unused lanes are ignored. The actual PCIe engine files are unmodified.

Installed dependencies `cocotb`, `cocotb-bus`, `cocotbext-axi`, `cocotbext-pcie`, pytest and Scapy retain their respective licenses in their distributions. They are installed dependencies, not bundled source. `requirements.lock` pins the tested dependency versions. Icarus Verilog and Verilator are external tools. Their use does not establish FPGA synthesis or physical-link validation.
