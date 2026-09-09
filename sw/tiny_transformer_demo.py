"""Run one deterministic four-token quantized transformer block."""

from math import exp, isqrt

from accelerator_runtime import (
    AcceleratorRuntime,
    FunctionalMemory,
    FunctionalRegisters,
    Quantization,
    gemm_reference,
)


def clamp8(value: int) -> int:
    return min(127, max(-128, value))


def trunc_div(numerator: int, denominator: int) -> int:
    return numerator // denominator if numerator >= 0 else -((-numerator) // denominator)


def transpose(matrix: list[list[int]]) -> list[list[int]]:
    return [list(column) for column in zip(*matrix)]


def add(left: list[list[int]], right: list[list[int]]) -> list[list[int]]:
    return [[clamp8(a + b) for a, b in zip(left_row, right_row)]
            for left_row, right_row in zip(left, right)]


def softmax_q7(scores: list[list[int]]) -> list[list[int]]:
    result = []
    for row in scores:
        maximum = max(row)
        exponentials = [exp((value - maximum) / 16.0) for value in row]
        denominator = sum(exponentials)
        quantized = [round(value * 127 / denominator) for value in exponentials]
        quantized[quantized.index(max(quantized))] += 127 - sum(quantized)
        result.append(quantized)
    return result


def layer_norm_q5(matrix: list[list[int]]) -> list[list[int]]:
    result = []
    for row in matrix:
        mean_q = trunc_div(sum(row) << 8, len(row))
        differences = [(value << 8) - mean_q for value in row]
        stddev_q = isqrt(sum(value * value for value in differences) // len(row) + 1)
        result.append([clamp8(trunc_div(value * 32, stddev_q)) if stddev_q else 0
                       for value in differences])
    return result


def gelu_q44(matrix: list[list[int]]) -> list[list[int]]:
    result = []
    for row in matrix:
        output_row = []
        for value in row:
            gate = min(255, max(0, 128 + 7 * value))
            product = value * gate
            output_row.append(clamp8(
                -((-product + 128) >> 8) if product < 0 else (product + 128) >> 8
            ))
        result.append(output_row)
    return result


def weights(seed: int) -> list[list[int]]:
    return [[((row * 3 + col * seed + seed) % 5) - 2 for col in range(4)]
            for row in range(4)]


def main() -> None:
    memory = FunctionalMemory(0x1000, 0x10000)
    registers = FunctionalRegisters(memory, 4, 4, 4, 8)
    runtime = AcceleratorRuntime(registers, memory, 0x1000, 0x10000,
                                 rows=4, cols=4, k_tile=4, bits=8)
    compute_cycles = 0
    scalar_mac_cycles = 0

    def gemm(a: list[list[int]], b: list[list[int]], shift: int) -> list[list[int]]:
        nonlocal compute_cycles, scalar_mac_cycles
        quant = Quantization(1, shift)
        runtime.reset_buffers()
        actual, counters = runtime.run_gemm(a, b, quant)
        assert actual == gemm_reference(a, b, quant, 8)
        compute_cycles += counters["compute_cycles"]
        scalar_mac_cycles += len(a) * len(b) * len(b[0])
        return actual

    x = [
        [3, -2, 1, 0],
        [-1, 2, 0, 3],
        [2, 1, -3, 1],
        [0, -1, 2, -2],
    ]
    query = gemm(x, weights(1), 2)
    key = gemm(x, weights(2), 2)
    value = gemm(x, weights(3), 1)
    scores = gemm(query, transpose(key), 4)
    probabilities = softmax_q7(scores)
    context = gemm(probabilities, value, 7)
    attention = gemm(context, weights(4), 1)
    normalized = layer_norm_q5(add(x, attention))
    hidden = gelu_q44(gemm(normalized, weights(5), 2))
    feed_forward = gemm(hidden, weights(6), 2)
    output = layer_norm_q5(add(normalized, feed_forward))

    assert all(sum(row) == 127 for row in probabilities)
    print("Tiny transformer output:")
    for row in output:
        print(" ", row)
    assert output == [
        [20, -20, 40, -40],
        [-55, 16, 23, 15],
        [3, 49, -36, -16],
        [-15, 9, 46, -40],
    ]
    print(f"Bit-exact GEMM boundaries: 8/8")
    print(f"Array compute cycles: {compute_cycles}; scalar MAC cycles: {scalar_mac_cycles}; "
          f"compute speedup: {scalar_mac_cycles / compute_cycles:.2f}x")


if __name__ == "__main__":
    main()
