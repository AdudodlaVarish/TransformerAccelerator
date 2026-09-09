"""Dependency-free host runtime and quantization helpers for the RTL register map."""

from __future__ import annotations

from dataclasses import dataclass
import mmap
import os
import struct


CONTROL = 0x00
STATUS = 0x04
SOURCE_ADDRESS = 0x08
DESTINATION_ADDRESS = 0x0C
K_TILES = 0x10
REQUANT_MULTIPLIER = 0x14
REQUANT_SHIFT = 0x18
REQUANT_ZERO_POINT = 0x1C
TOTAL_CYCLES = 0x20
COMPUTE_CYCLES = 0x28
INPUT_STALL_CYCLES = 0x30
OUTPUT_STALL_CYCLES = 0x38
MEMORY_READ_BEATS = 0x40
MEMORY_WRITE_BEATS = 0x48
TILES_COMPLETED = 0x50
RESULTS_TRANSFERRED = 0x54


@dataclass(frozen=True)
class Quantization:
    multiplier: int
    shift: int
    zero_point: int = 0


class MappedRegion:
    """Memory-map a UIO/device region; usable for registers or reserved DMA memory."""

    def __init__(self, device: str, size: int, physical_base: int = 0, offset: int = 0):
        self.physical_base = physical_base
        self.size = size
        self._fd = os.open(device, os.O_RDWR | os.O_SYNC)
        self._map = mmap.mmap(self._fd, size, offset=offset)

    def close(self) -> None:
        self._map.close()
        os.close(self._fd)

    def __enter__(self) -> MappedRegion:
        return self

    def __exit__(self, *_: object) -> None:
        self.close()

    def _offset(self, address: int, size: int) -> int:
        offset = address - self.physical_base
        if offset < 0 or offset + size > self.size:
            raise ValueError("mapped access is outside the region")
        return offset

    def read32(self, address: int) -> int:
        return struct.unpack_from("<I", self._map, self._offset(address, 4))[0]

    def write32(self, address: int, value: int) -> None:
        struct.pack_into("<I", self._map, self._offset(address, 4), value & 0xFFFFFFFF)

    def read(self, address: int, size: int) -> bytes:
        offset = self._offset(address, size)
        return self._map[offset : offset + size]

    def write(self, address: int, data: bytes) -> None:
        offset = self._offset(address, len(data))
        self._map[offset : offset + len(data)] = data


def pack_signed(values: list[int], bits: int) -> bytes:
    if bits not in (4, 8):
        raise ValueError("only INT4 and INT8 packing is supported")
    low, high = -(1 << (bits - 1)), (1 << (bits - 1)) - 1
    packed = bytearray()
    accumulator = 0
    used_bits = 0
    for value in values:
        if not low <= value <= high:
            raise ValueError(f"{value} is outside signed INT{bits}")
        accumulator |= (value & ((1 << bits) - 1)) << used_bits
        used_bits += bits
        if used_bits == 8:
            packed.append(accumulator)
            accumulator = 0
            used_bits = 0
    if used_bits:
        packed.append(accumulator)
    return bytes(packed)


def unpack_signed(data: bytes, count: int, bits: int) -> list[int]:
    if bits not in (4, 8):
        raise ValueError("only INT4 and INT8 packing is supported")
    values = []
    mask = (1 << bits) - 1
    for index in range(count):
        raw = (data[(index * bits) // 8] >> ((index * bits) % 8)) & mask
        values.append(raw - (1 << bits) if raw & (1 << (bits - 1)) else raw)
    return values


def pack_gemm_inputs(
    a: list[list[int]], b: list[list[int]], k_tile: int, bits: int
) -> bytes:
    if not a or not b or not a[0] or len(a[0]) != len(b):
        raise ValueError("GEMM dimensions must be ROWSxK and KxCOLS")
    total_k, cols = len(b), len(b[0])
    if any(len(row) != total_k for row in a) or any(len(row) != cols for row in b):
        raise ValueError("matrix rows must have consistent dimensions")
    if total_k % k_tile:
        raise ValueError("K must be an integer number of hardware K tiles")
    values = []
    for k_index in range(total_k):
        values.extend(row[k_index] for row in a)
        values.extend(b[k_index])
    return pack_signed(values, bits)


def requantize(value: int, quant: Quantization, bits: int) -> int:
    product = value * quant.multiplier
    if quant.shift:
        magnitude = abs(product)
        scaled = (magnitude + (1 << (quant.shift - 1))) >> quant.shift
        if product < 0:
            scaled = -scaled
    else:
        scaled = product
    low, high = -(1 << (bits - 1)), (1 << (bits - 1)) - 1
    return min(high, max(low, scaled + quant.zero_point))


def gemm_reference(
    a: list[list[int]], b: list[list[int]], quant: Quantization, bits: int
) -> list[list[int]]:
    return [
        [
            requantize(sum(a[row][k] * b[k][col] for k in range(len(b))), quant, bits)
            for col in range(len(b[0]))
        ]
        for row in range(len(a))
    ]


def quantize_symmetric(values: list[float], bits: int) -> tuple[list[int], float]:
    if bits not in (4, 8) or not values:
        raise ValueError("quantization needs non-empty values and 4 or 8 bits")
    limit = (1 << (bits - 1)) - 1
    maximum = max(abs(value) for value in values)
    scale = maximum / limit if maximum else 1.0
    return ([max(-limit, min(limit, round(value / scale))) for value in values], scale)


def choose_requantization(real_multiplier: float, multiplier_bits: int = 16) -> Quantization:
    if real_multiplier < 0:
        raise ValueError("requantization multiplier must be non-negative")
    if real_multiplier == 0:
        return Quantization(0, 0)
    maximum = (1 << multiplier_bits) - 1
    best = None
    for shift in range(64):
        multiplier = round(real_multiplier * (1 << shift))
        if 0 < multiplier <= maximum:
            error = abs(multiplier / (1 << shift) - real_multiplier)
            if best is None or error < best[0]:
                best = (error, multiplier, shift)
    if best is None:
        raise ValueError("multiplier is outside the hardware representation")
    return Quantization(best[1], best[2])


class AcceleratorRuntime:
    """Sequence synchronous GEMM commands through accelerator_control."""

    def __init__(
        self,
        registers: object,
        memory: object,
        buffer_base: int,
        buffer_size: int,
        rows: int = 4,
        cols: int = 4,
        k_tile: int = 4,
        bits: int = 8,
        poll_limit: int = 1_000_000,
    ):
        if bits not in (4, 8):
            raise ValueError("runtime supports INT4 or INT8 bitstreams")
        beat_bytes = (rows + cols) * bits // 8
        if rows <= 0 or cols <= 0 or k_tile <= 0 or beat_bytes & (beat_bytes - 1):
            raise ValueError("array dimensions must produce a power-of-two AXI beat")
        if buffer_base < 0 or buffer_base + buffer_size > (1 << 32):
            raise ValueError("DMA arena must fit the 32-bit address registers")
        self.registers = registers
        self.memory = memory
        self.buffer_base = buffer_base
        self.buffer_size = buffer_size
        self.rows = rows
        self.cols = cols
        self.k_tile = k_tile
        self.bits = bits
        self.poll_limit = poll_limit
        self._next_buffer = buffer_base

    def reset_buffers(self) -> None:
        self._next_buffer = self.buffer_base

    def _allocate(self, size: int, alignment: int, no_cross_4k: bool = False) -> int:
        address = (self._next_buffer + alignment - 1) & -alignment
        if no_cross_4k and (address & 0xFFF) + size > 4096:
            address = (address + 4095) & -4096
        if address + size > self.buffer_base + self.buffer_size:
            raise MemoryError("accelerator DMA arena is full")
        self._next_buffer = address + size
        return address

    def _read64(self, address: int) -> int:
        return self.registers.read32(address) | (self.registers.read32(address + 4) << 32)

    def counters(self) -> dict[str, int]:
        return {
            "total_cycles": self._read64(TOTAL_CYCLES),
            "compute_cycles": self._read64(COMPUTE_CYCLES),
            "input_stall_cycles": self._read64(INPUT_STALL_CYCLES),
            "output_stall_cycles": self._read64(OUTPUT_STALL_CYCLES),
            "memory_read_beats": self._read64(MEMORY_READ_BEATS),
            "memory_write_beats": self._read64(MEMORY_WRITE_BEATS),
            "tiles_completed": self.registers.read32(TILES_COMPLETED),
            "results_transferred": self.registers.read32(RESULTS_TRANSFERRED),
        }

    def run_gemm(
        self, a: list[list[int]], b: list[list[int]], quant: Quantization
    ) -> tuple[list[list[int]], dict[str, int]]:
        if (not a or not b or not b[0] or len(a) != self.rows
                or len(b[0]) != self.cols):
            raise ValueError("matrix shape does not match the accelerator array")
        if len(b) % self.k_tile or len(b) // self.k_tile > 0xFFFF:
            raise ValueError("K must fit an integer number of 16-bit tile commands")
        if not 0 <= quant.multiplier < (1 << 16) or not 0 <= quant.shift < 64:
            raise ValueError("requantization fields exceed the hardware registers")
        low, high = -(1 << (self.bits - 1)), (1 << (self.bits - 1)) - 1
        if not low <= quant.zero_point <= high:
            raise ValueError("zero point exceeds the output data width")

        payload = pack_gemm_inputs(a, b, self.k_tile, self.bits)
        beat_bytes = (self.rows + self.cols) * self.bits // 8
        output_size = (self.rows * self.cols * self.bits + 7) // 8
        source = self._allocate(len(payload), beat_bytes)
        destination = self._allocate(output_size, beat_bytes, no_cross_4k=True)
        self.memory.write(source, payload)
        self.memory.write(destination, bytes(output_size))

        self.registers.write32(CONTROL, 2)
        self.registers.write32(SOURCE_ADDRESS, source)
        self.registers.write32(DESTINATION_ADDRESS, destination)
        self.registers.write32(K_TILES, len(b) // self.k_tile)
        self.registers.write32(REQUANT_MULTIPLIER, quant.multiplier)
        self.registers.write32(REQUANT_SHIFT, quant.shift)
        self.registers.write32(REQUANT_ZERO_POINT, quant.zero_point)
        self.registers.write32(CONTROL, 1)

        for _ in range(self.poll_limit):
            status = self.registers.read32(STATUS)
            if status & 0b100:
                raise RuntimeError("accelerator reported a DMA or protocol error")
            if status & 0b010:
                break
        else:
            raise TimeoutError("accelerator command did not complete")

        flat = unpack_signed(self.memory.read(destination, output_size),
                             self.rows * self.cols, self.bits)
        result = [flat[row*self.cols:(row+1)*self.cols] for row in range(self.rows)]
        return result, self.counters()

    def run_large_gemm(
        self, a: list[list[int]], b: list[list[int]], quant: Quantization
    ) -> tuple[list[list[int]], dict[str, int]]:
        if not a or not b or not a[0] or not b[0] or len(a[0]) != len(b):
            raise ValueError("GEMM dimensions must be MxK and KxN")
        total_k, columns = len(b), len(b[0])
        if any(len(row) != total_k for row in a) or any(len(row) != columns for row in b):
            raise ValueError("matrix rows must have consistent dimensions")
        if total_k % self.k_tile:
            raise ValueError("K must be padded to a hardware tile multiple")

        output = [[0] * columns for _ in a]
        totals: dict[str, int] = {}
        for row_start in range(0, len(a), self.rows):
            tile_a = [
                list(a[row_start + row]) if row_start + row < len(a) else [0] * total_k
                for row in range(self.rows)
            ]
            for col_start in range(0, columns, self.cols):
                tile_b = [
                    [b[k][col_start + col] if col_start + col < columns else 0
                     for col in range(self.cols)]
                    for k in range(total_k)
                ]
                self.reset_buffers()
                tile, counters = self.run_gemm(tile_a, tile_b, quant)
                for row in range(min(self.rows, len(a) - row_start)):
                    for col in range(min(self.cols, columns - col_start)):
                        output[row_start + row][col_start + col] = tile[row][col]
                for name, value in counters.items():
                    totals[name] = totals.get(name, 0) + value
        return output, totals


class FunctionalMemory:
    """Byte-addressable backend for host tests and demos without FPGA hardware."""

    def __init__(self, base: int, size: int):
        self.base = base
        self.data = bytearray(size)

    def write(self, address: int, data: bytes) -> None:
        offset = address - self.base
        if offset < 0 or offset + len(data) > len(self.data):
            raise ValueError("functional memory write is outside the region")
        self.data[offset:offset + len(data)] = data

    def read(self, address: int, size: int) -> bytes:
        offset = address - self.base
        if offset < 0 or offset + size > len(self.data):
            raise ValueError("functional memory read is outside the region")
        return bytes(self.data[offset:offset + size])


class FunctionalRegisters:
    """Execute commands functionally while preserving the hardware register contract."""

    def __init__(self, memory: FunctionalMemory, rows: int, cols: int,
                 k_tile: int, bits: int):
        self.memory = memory
        self.rows = rows
        self.cols = cols
        self.k_tile = k_tile
        self.bits = bits
        self.values: dict[int, int] = {}
        self.writes: list[int] = []

    def write32(self, address: int, value: int) -> None:
        self.values[address] = value & 0xFFFFFFFF
        self.writes.append(address)
        if address == CONTROL and value & 2:
            self.values[STATUS] = 0
        if address == CONTROL and value & 1:
            self._run()

    def read32(self, address: int) -> int:
        return self.values.get(address, 0)

    def _run(self) -> None:
        k_tiles = self.values[K_TILES]
        total_k = k_tiles * self.k_tile
        beat_values = self.rows + self.cols
        beat_bytes = beat_values * self.bits // 8
        packed = self.memory.read(self.values[SOURCE_ADDRESS], total_k * beat_bytes)
        values = unpack_signed(packed, total_k * beat_values, self.bits)
        a = [[0] * total_k for _ in range(self.rows)]
        b = [[0] * self.cols for _ in range(total_k)]
        for k_index in range(total_k):
            base = k_index * beat_values
            for row in range(self.rows):
                a[row][k_index] = values[base + row]
            for col in range(self.cols):
                b[k_index][col] = values[base + self.rows + col]
        zero = self.values[REQUANT_ZERO_POINT] & ((1 << self.bits) - 1)
        if zero & (1 << (self.bits - 1)):
            zero -= 1 << self.bits
        quant = Quantization(self.values[REQUANT_MULTIPLIER],
                             self.values[REQUANT_SHIFT], zero)
        result = gemm_reference(a, b, quant, self.bits)
        output = pack_signed([value for row in result for value in row], self.bits)
        self.memory.write(self.values[DESTINATION_ADDRESS], output)
        compute = k_tiles * (self.k_tile + self.rows + self.cols - 2)
        self.values[TOTAL_CYCLES] = compute
        self.values[COMPUTE_CYCLES] = compute
        self.values[INPUT_STALL_CYCLES] = 0
        self.values[OUTPUT_STALL_CYCLES] = 0
        self.values[MEMORY_READ_BEATS] = total_k
        self.values[MEMORY_WRITE_BEATS] = (len(output) + beat_bytes - 1) // beat_bytes
        self.values[TILES_COMPLETED] = k_tiles
        self.values[RESULTS_TRANSFERRED] = 1
        self.values[STATUS] = 0b010
