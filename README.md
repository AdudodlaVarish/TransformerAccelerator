# FPGA Transformer Accelerator

Synthesizable SystemVerilog and a dependency-free Python runtime for an INT8/INT4
transformer accelerator. The project covers the full path from host commands and
AXI DMA through double-buffered tiles, a systolic MAC array, accumulation,
requantization, and DDR writes. Standalone streaming blocks implement scaled
dot-product attention, fixed-point softmax, layer normalization, ReLU, and GELU.

## Architecture

```text
Host runtime
    |
    | AXI-Lite commands and counters
    v
accelerator_control
    |
    v
transformer_axi_dma <====== AXI4 bursts ======> DDR
    |                                             ^
    | packed AXI-Stream K slices                  |
    v                                             |
two BRAM/URAM input banks                         |
    |  load bank N+1 while bank N computes        |
    v                                             |
ROWS x COLS systolic MAC array                    |
    |                                             |
INT32 cross-K-tile accumulator                    |
    |                                             |
multiplier/shift/zero-point requantization        |
    |                                             |
packed INT8/INT4 result burst ====================+

attention_score -> attention_softmax
layer_norm       -> transformer_activation (bypass/ReLU/GELU)
```

`transformer_accelerator_top` is the SoC-facing GEMM top. Its AXI-Lite slave
programs `transformer_axi_dma`, whose AXI4 master moves packed matrix slices.
The stream core fills one input bank while the other feeds the array. Row and
column delays stagger operands so `A[row,k]` and `B[k,col]` meet at the correct
processing element. A K tile takes `K + ROWS + COLS - 2` compute cycles.

`BUFFER_RAM_STYLE="block"` requests BRAM. Set it to `"ultra"` for URAM on
supported Xilinx devices. The arrays are banked by operand row/column to provide
the parallel bandwidth required by the MAC array.

## Numeric formats and layout

- GEMM operands and outputs: signed INT8 or packed signed INT4.
- Accumulators: signed INT32 by default.
- Requantization: `round(accumulator * multiplier / 2^shift) + zero_point`,
  followed by signed saturation.
- Softmax scores: signed Q12.4 by default; probabilities are unsigned Q0.8.
- Activation input/output: signed Q4.4 INT8.
- Layer norm statistics: eight fractional bits; per-element gamma is Q8.8.

One DMA input beat contains, least-significant field first:

```text
A[0,k], A[1,k], ... A[ROWS-1,k], B[k,0], B[k,1], ... B[k,COLS-1]
```

The host sends all K slices for tile 0, then tile 1, and so on. Results are
row-major. INT4 values occupy low nibble then high nibble. The DMA limits bursts
to `MAX_READ_BURST`, never crosses a 4 KiB boundary, propagates AXI response or
stream protocol failures, and holds data stable under backpressure.

## AXI-Lite register map

| Offset | Name | Description |
|---:|---|---|
| `0x00` | CONTROL | bit 0 start, bit 1 clear sticky status |
| `0x04` | STATUS | bit 0 busy, bit 1 done, bit 2 error |
| `0x08` | SOURCE | packed input physical address |
| `0x0c` | DESTINATION | packed output physical address |
| `0x10` | K_TILES | number of K tiles to accumulate |
| `0x14` | MULTIPLIER | unsigned requantization multiplier |
| `0x18` | SHIFT | requantization right shift |
| `0x1c` | ZERO_POINT | signed output zero point |
| `0x20..0x4c` | COUNTERS | 64-bit total/compute/stall/read/write counters |
| `0x50` | TILES | completed K tiles |
| `0x54` | RESULTS | completed output matrices |

Writes accept independent AXI-Lite address and data channels. Done and error are
sticky until cleared or a new command starts.

## Verification

Requirements: Verilator, GNU Make, and Python 3. Run the complete regression:

```bash
make test
```

The self-checking tests cover:

- signed systolic data movement and two consecutive matrix products;
- ping-pong loading during compute and active-bank protection;
- full-precision accumulation across K tiles, rounding, clamp, and saturation;
- INT8 and packed INT4 DMA, 4 KiB burst splitting, byte strobes, AXI stalls,
  descriptor latching, response/framing errors, and performance counters;
- AXI-Stream backpressure and simultaneous consume/refill cases;
- scaled dot-product attention plus softmax versus floating point;
- layer normalization, zero variance, per-element affine values, ReLU, and GELU;
- an exact, cycle-accurate RTL transformer block chaining seven GEMMs, attention,
  softmax, residuals, two layer normalizations, and GELU;
- AXI-Lite command sequencing and 64-bit counter access;
- complete AXI-Lite → DMA → DDR-model → GEMM → DDR top-level integration;
- Python packing, quantization, M/N/K tiling, buffer allocation, and MMIO order;
- a deterministic four-token transformer block with eight bit-exact GEMMs.

Run the model demo directly with:

```bash
python3 -B sw/tiny_transformer_demo.py
```

## Measured cycle results

`make benchmark` builds and runs a cycle-accurate 16×16×16 INT8 DMA test. With
the included AXI memory model and output backpressure, Verilator reports:

| Configuration | Scalar baseline | Accelerator command | Speedup |
|---|---:|---:|---:|
| 16×16×16 INT8 GEMM | 4,096 cycles at one MAC/cycle | 350 cycles | **11.70×** |
| Tiny transformer, eight 4×4 GEMMs | 512 MAC cycles | 80 array-compute cycles | **6.40×** |

The 350-cycle number includes DMA read setup, compute, serialized result packing,
write stalls, and the AXI write response. It is a measured RTL cycle comparison,
not a claim about CPU wall-clock time. FPGA LUT/DSP/BRAM use, Fmax, power, and
wall-clock CPU speedup must be measured after selecting a board and running its
vendor synthesis/implementation tools; none are invented here.

After attaching the mapped accelerator and DMA memory, collect a verified
wall-clock comparison against the scalar Python CPU reference with:

```bash
python3 -B sw/benchmark.py --register-device /dev/uio0 --dma-device /dev/mem \
  --dma-base 0x10000000 --dma-offset 0x10000000
```

Use `--functional` only to validate the benchmark workflow. Its output is
explicitly labeled emulation and is not a hardware-performance result.

## Host runtime

`sw/accelerator_runtime.py` provides:

- `/dev/uio` or reserved-memory mapping through `MappedRegion`;
- aligned DMA arena allocation with destination 4 KiB protection;
- INT4/INT8 packing and signed unpacking;
- symmetric quantization and multiplier/shift selection;
- single-tile and padded large-M/N GEMM scheduling;
- polling, hardware-error propagation, and counter collection;
- a functional device backend for tests when no board is attached.

The runtime is synchronous: buffers are reusable as soon as `run_gemm` returns.
Add cache maintenance appropriate to the target platform when the DMA memory is
not hardware-coherent.

## Source map

- `rtl/systolic_array.sv`: parameterized PE mesh.
- `rtl/tiled_gemm.sv`: BRAM/URAM banks, skew scheduler, accumulator, requantizer.
- `rtl/transformer_gemm_accelerator.sv`: AXI-Stream bank scheduler and counters.
- `rtl/transformer_axi_dma.sv`: AXI4 burst reader/writer and result packer.
- `rtl/accelerator_control.sv`: AXI-Lite register and status block.
- `rtl/transformer_accelerator_top.sv`: synthesizable GEMM subsystem top.
- `rtl/attention_score.sv`, `rtl/attention_softmax.sv`: attention reduction path.
- `rtl/layer_norm.sv`, `rtl/transformer_activation.sv`: transformer nonlinear path.
- `sim/tb_tiny_transformer.sv`: exact end-to-end RTL transformer regression.
- `sim/tb_transformer_accelerator_top.sv`: complete SoC-facing transaction test.
- `sw/accelerator_runtime.py`: runtime, packing, quantization, and functional backend.
- `sw/tiny_transformer_demo.py`: deterministic end-to-end quantized model.
- `sw/benchmark.py`: bit-exact FPGA-versus-scalar-CPU wall-clock benchmark.
