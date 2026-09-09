"""Measure verified accelerator GEMM latency against a scalar CPU reference."""

from __future__ import annotations

import argparse
import json
from time import perf_counter

from accelerator_runtime import (
    AcceleratorRuntime,
    FunctionalMemory,
    FunctionalRegisters,
    MappedRegion,
    Quantization,
    gemm_reference,
)


def positive_int(value: str) -> int:
    parsed = int(value, 0)
    if parsed <= 0:
        raise argparse.ArgumentTypeError("value must be positive")
    return parsed


def matrix_a(rows: int, inner: int, bits: int) -> list[list[int]]:
    span = 1 << min(bits - 1, 3)
    return [[(row * 3 + index * 5 + 1) % (2 * span) - span
             for index in range(inner)] for row in range(rows)]


def matrix_b(inner: int, columns: int, bits: int) -> list[list[int]]:
    span = 1 << min(bits - 1, 3)
    return [[(index * 7 - column * 3 + 2) % (2 * span) - span
             for column in range(columns)] for index in range(inner)]


def measure(args: argparse.Namespace) -> dict[str, object]:
    if args.m % args.rows or args.n % args.cols or args.k % args.k_tile:
        raise ValueError("M, N, and K must be multiples of the hardware tile dimensions")

    a = matrix_a(args.m, args.k, args.bits)
    b = matrix_b(args.k, args.n, args.bits)
    quant = Quantization(1, args.shift)
    closables: list[MappedRegion] = []
    if args.functional:
        memory = FunctionalMemory(args.dma_base, args.dma_size)
        registers = FunctionalRegisters(memory, args.rows, args.cols,
                                        args.k_tile, args.bits)
        backend = "functional-emulation"
    else:
        if not args.register_device or not args.dma_device:
            raise ValueError("real hardware needs --register-device and --dma-device")
        registers = MappedRegion(args.register_device, args.register_size)
        memory = MappedRegion(args.dma_device, args.dma_size, args.dma_base,
                              args.dma_offset)
        closables.extend((registers, memory))
        backend = "fpga"

    try:
        runtime = AcceleratorRuntime(registers, memory, args.dma_base, args.dma_size,
                                     args.rows, args.cols, args.k_tile, args.bits)
        expected = gemm_reference(a, b, quant, args.bits)
        runtime.reset_buffers()
        actual, counters = runtime.run_large_gemm(a, b, quant)
        if actual != expected:
            raise RuntimeError("accelerator output differs from the CPU reference")

        start = perf_counter()
        for _ in range(args.iterations):
            runtime.reset_buffers()
            actual, counters = runtime.run_large_gemm(a, b, quant)
        accelerator_seconds = (perf_counter() - start) / args.iterations

        start = perf_counter()
        for _ in range(args.iterations):
            expected = gemm_reference(a, b, quant, args.bits)
        cpu_seconds = (perf_counter() - start) / args.iterations
        assert actual == expected

        return {
            "backend": backend,
            "shape": [args.m, args.k, args.n],
            "precision_bits": args.bits,
            "iterations": args.iterations,
            "verified": True,
            "accelerator_seconds": accelerator_seconds,
            "scalar_python_seconds": cpu_seconds,
            "wall_clock_speedup": cpu_seconds / accelerator_seconds,
            "last_command_counters": counters,
        }
    finally:
        for region in reversed(closables):
            region.close()


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    result.add_argument("--functional", action="store_true",
                        help="smoke-test with emulation; not a hardware measurement")
    result.add_argument("--register-device", help="AXI-Lite UIO device, e.g. /dev/uio0")
    result.add_argument("--register-size", type=positive_int, default=0x1000)
    result.add_argument("--dma-device", help="DMA mapping device, e.g. /dev/mem")
    result.add_argument("--dma-base", type=lambda value: int(value, 0), default=0x10000000)
    result.add_argument("--dma-size", type=positive_int, default=0x1000000)
    result.add_argument("--dma-offset", type=lambda value: int(value, 0), default=0)
    result.add_argument("--rows", type=positive_int, default=16)
    result.add_argument("--cols", type=positive_int, default=16)
    result.add_argument("--k-tile", type=positive_int, default=16)
    result.add_argument("--bits", type=int, choices=(4, 8), default=8)
    result.add_argument("--m", type=positive_int, default=64)
    result.add_argument("--n", type=positive_int, default=64)
    result.add_argument("--k", type=positive_int, default=64)
    result.add_argument("--shift", type=int, choices=range(64), default=6)
    result.add_argument("--iterations", type=positive_int, default=10)
    return result


def main() -> None:
    args = parser().parse_args()
    report = measure(args)
    print(json.dumps(report, indent=2, sort_keys=True))
    if args.functional:
        print("Functional emulation passed; wall_clock_speedup is not an FPGA result.")


if __name__ == "__main__":
    main()
