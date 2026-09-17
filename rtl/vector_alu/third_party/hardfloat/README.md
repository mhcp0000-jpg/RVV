# Berkeley HardFloat Release 1 (selected Verilog files)

The files in this directory are unmodified copies from John R. Hauser's
[official HardFloat Release 1 archive](https://www.jhauser.us/arithmetic/HardFloat-1.zip)
(SHA-256 `6b3757c9fbfa2230c6a2b84605e39372cb589dd7500e979c4f0b8ecc8a03b14b`).
The RISC-V specialization is used. `COPYING.txt` contains the redistribution
conditions, and each source file retains its original notice.

`vcore_alu_fp32_fma.sv` converts IEEE binary32 inputs to HardFloat's recoded
format, performs one fused multiply-add with a single final rounding, and
converts back to IEEE binary32. `vcore_alu_fp32_slice.sv` supplies two lanes
to the existing 64-bit-per-cycle ALU pipeline. These RTL files are the local
integration layer and are outside the upstream archive.

The core is combinational in this integration. A 1 GHz clock is a target,
not an achieved timing result; physical synthesis and STA are required.
