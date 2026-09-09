from accelerator_runtime import (
    AcceleratorRuntime,
    COMPUTE_CYCLES,
    CONTROL,
    DESTINATION_ADDRESS,
    K_TILES,
    MEMORY_READ_BEATS,
    MEMORY_WRITE_BEATS,
    Quantization,
    REQUANT_MULTIPLIER,
    REQUANT_SHIFT,
    REQUANT_ZERO_POINT,
    RESULTS_TRANSFERRED,
    SOURCE_ADDRESS,
    STATUS,
    TILES_COMPLETED,
    TOTAL_CYCLES,
    choose_requantization,
    FunctionalMemory,
    FunctionalRegisters,
    gemm_reference,
    pack_signed,
    requantize,
    unpack_signed,
)


def main() -> None:
    assert unpack_signed(pack_signed([-8, -1, 0, 7], 4), 4, 4) == [-8, -1, 0, 7]
    quant = choose_requantization(0.25)
    assert quant == Quantization(1, 2)
    assert requantize(-10, quant, 8) == -3

    rows = cols = 4
    k_tile = 5
    total_k = 10
    a = [[((row * 2 + k * 3 + 1) % 5) - 2 for k in range(total_k)]
         for row in range(rows)]
    b = [[((k * 2 - col + 3) % 5) - 2 for col in range(cols)]
         for k in range(total_k)]
    expected = gemm_reference(a, b, quant, 8)

    memory = FunctionalMemory(0x1000, 0x4000)
    registers = FunctionalRegisters(memory, rows, cols, k_tile, 8)
    runtime = AcceleratorRuntime(registers, memory, 0x1000, 0x4000,
                                 rows, cols, k_tile, 8)
    actual, counters = runtime.run_gemm(a, b, quant)
    assert actual == expected
    assert counters["compute_cycles"] == 22
    assert counters["memory_read_beats"] == 10
    assert counters["tiles_completed"] == 2
    assert registers.writes[-8:] == [CONTROL, SOURCE_ADDRESS, DESTINATION_ADDRESS,
                                     K_TILES, REQUANT_MULTIPLIER, REQUANT_SHIFT,
                                     REQUANT_ZERO_POINT, CONTROL]
    large_a = [a[row % rows] for row in range(6)]
    large_b = [row + [row[0], row[1], row[2]] for row in b]
    actual, counters = runtime.run_large_gemm(large_a, large_b, quant)
    assert actual == gemm_reference(large_a, large_b, quant, 8)
    assert counters["tiles_completed"] == 8
    print("PASS: Python runtime packed tensors, sequenced MMIO, and checked counters")


if __name__ == "__main__":
    main()
