#!/usr/bin/env python3
"""Minimal PNG decode/encode for screenshot content comparison (standard library only).

iCTRL screenshots can be requested as lossless PNG. Pixel diffing needs decoded
RGB samples, and the QA scripts may not add third-party packages, so this module
implements the subset iOS screenshots use: 8-bit grayscale, RGB or RGBA,
non-interlaced, all five PNG row filters. Unsupported variants raise `PNGError`
with a message that says to capture a supported PNG instead of guessing.
"""
from __future__ import annotations

from dataclasses import dataclass
import struct
import zlib

PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"


class PNGError(RuntimeError):
    """The PNG is malformed or uses a variant this decoder does not support."""


@dataclass(frozen=True)
class PNGImage:
    width: int
    height: int
    channels: int
    data: bytes  # row-major, 8 bits per channel

    def __post_init__(self) -> None:
        expected = self.width * self.height * self.channels
        if len(self.data) != expected:
            raise PNGError(f"pixel buffer has {len(self.data)} bytes, expected {expected}")

    def rgb(self) -> bytes:
        """Return row-major RGB bytes (alpha is dropped)."""
        if self.channels == 3:
            return self.data
        if self.channels == 1:
            return bytes(value for sample in self.data for value in (sample, sample, sample))
        if self.channels == 4:
            result = bytearray(self.width * self.height * 3)
            for index in range(self.width * self.height):
                result[index * 3:index * 3 + 3] = self.data[index * 4:index * 4 + 3]
            return bytes(result)
        raise PNGError(f"unsupported channel count {self.channels}")


def _paeth(left: int, above: int, upper_left: int) -> int:
    estimate = left + above - upper_left
    distance_left = abs(estimate - left)
    distance_above = abs(estimate - above)
    distance_upper_left = abs(estimate - upper_left)
    if distance_left <= distance_above and distance_left <= distance_upper_left:
        return left
    if distance_above <= distance_upper_left:
        return above
    return upper_left


def _unfilter(raw: bytes, width: int, height: int, channels: int) -> bytes:
    stride = width * channels
    output = bytearray(height * stride)
    previous = bytearray(stride)
    offset = 0
    for row in range(height):
        if offset >= len(raw):
            raise PNGError("PNG data ended before the last row")
        filter_type = raw[offset]
        offset += 1
        line = bytearray(raw[offset:offset + stride])
        if len(line) != stride:
            raise PNGError("PNG row is shorter than the declared width")
        offset += stride
        if filter_type == 0:
            pass
        elif filter_type == 1:
            for index in range(channels, stride):
                line[index] = (line[index] + line[index - channels]) & 0xFF
        elif filter_type == 2:
            for index in range(stride):
                line[index] = (line[index] + previous[index]) & 0xFF
        elif filter_type == 3:
            for index in range(stride):
                left = line[index - channels] if index >= channels else 0
                line[index] = (line[index] + ((left + previous[index]) >> 1)) & 0xFF
        elif filter_type == 4:
            for index in range(stride):
                left = line[index - channels] if index >= channels else 0
                upper_left = previous[index - channels] if index >= channels else 0
                line[index] = (line[index] + _paeth(left, previous[index], upper_left)) & 0xFF
        else:
            raise PNGError(f"unsupported PNG row filter {filter_type}")
        output[row * stride:(row + 1) * stride] = line
        previous = line
    if offset != len(raw):
        raise PNGError("PNG data has trailing bytes after the last row")
    return bytes(output)


def decode_png(blob: bytes) -> PNGImage:
    """Decode a non-interlaced 8-bit grayscale/RGB/RGBA PNG."""
    if not blob.startswith(PNG_SIGNATURE):
        raise PNGError("not a PNG file")
    offset = len(PNG_SIGNATURE)
    width = height = bit_depth = color_type = interlace = None
    compressed = bytearray()
    saw_end = False
    while offset < len(blob):
        if offset + 8 > len(blob):
            raise PNGError("truncated PNG chunk header")
        length, kind = struct.unpack(">I4s", blob[offset:offset + 8])
        offset += 8
        payload = blob[offset:offset + length]
        if len(payload) != length or offset + length + 4 > len(blob):
            raise PNGError("truncated PNG chunk")
        crc = struct.unpack(">I", blob[offset + length:offset + length + 4])[0]
        offset += length + 4
        if zlib.crc32(kind + payload) & 0xFFFFFFFF != crc:
            raise PNGError(f"PNG chunk {kind!r} failed its CRC check")
        if kind == b"IHDR":
            if length != 13:
                raise PNGError("malformed IHDR chunk")
            (width, height, bit_depth, color_type, compression,
             filter_method, interlace) = struct.unpack(">IIBBBBB", payload)
        elif kind == b"IDAT":
            compressed.extend(payload)
        elif kind == b"IEND":
            saw_end = True
            break
    if not compressed:
        raise PNGError("PNG has no image data")
    if width is None or height is None:
        raise PNGError("PNG has no IHDR chunk")
    if width <= 0 or height <= 0:
        raise PNGError("PNG has invalid dimensions")
    if bit_depth != 8:
        raise PNGError(f"unsupported PNG bit depth {bit_depth}; capture 8-bit PNG")
    channels = {0: 1, 2: 3, 4: 2, 6: 4}.get(color_type)
    if channels is None or color_type == 4:
        raise PNGError(f"unsupported PNG color type {color_type}; capture RGB or RGBA PNG")
    if compression != 0 or filter_method != 0:
        raise PNGError("unsupported PNG compression or filter method")
    if interlace != 0:
        raise PNGError("interlaced PNG is unsupported; capture a non-interlaced screenshot")
    try:
        raw = zlib.decompress(bytes(compressed))
    except zlib.error as error:
        raise PNGError(f"PNG image data does not decompress: {error}") from error
    expected = height * (1 + width * channels)
    if len(raw) != expected:
        raise PNGError(f"PNG image data is {len(raw)} bytes, expected {expected}")
    data = _unfilter(raw, width, height, channels)
    return PNGImage(width=width, height=height, channels=channels, data=data)


def _chunk(kind: bytes, payload: bytes) -> bytes:
    return (struct.pack(">I", len(payload)) + kind + payload +
            struct.pack(">I", zlib.crc32(kind + payload) & 0xFFFFFFFF))


def _filter_row(line: bytes, previous: bytes, filter_type: int, bpp: int) -> bytes:
    if filter_type == 0:
        return line
    result = bytearray(len(line))
    if filter_type == 1:
        for index, value in enumerate(line):
            left = line[index - bpp] if index >= bpp else 0
            result[index] = (value - left) & 0xFF
        return bytes(result)
    if filter_type == 2:
        for index, value in enumerate(line):
            result[index] = (value - previous[index]) & 0xFF
        return bytes(result)
    if filter_type == 3:
        for index, value in enumerate(line):
            left = line[index - bpp] if index >= bpp else 0
            result[index] = (value - ((left + previous[index]) >> 1)) & 0xFF
        return bytes(result)
    if filter_type == 4:
        for index, value in enumerate(line):
            left = line[index - bpp] if index >= bpp else 0
            upper_left = previous[index - bpp] if index >= bpp else 0
            result[index] = (value - _paeth(left, previous[index], upper_left)) & 0xFF
        return bytes(result)
    raise PNGError(f"unsupported PNG row filter {filter_type}")


def encode_png(image: PNGImage, *, filter_type: int = 0) -> bytes:
    """Encode an 8-bit PNG; used by tests to feed every row filter to the decoder."""
    if image.channels not in (1, 3, 4):
        raise PNGError(f"unsupported channel count {image.channels}")
    color_type = {1: 0, 3: 2, 4: 6}[image.channels]
    stride = image.width * image.channels
    rows = bytearray()
    previous = bytes(stride)
    for row in range(image.height):
        line = image.data[row * stride:(row + 1) * stride]
        rows.append(filter_type)
        rows.extend(_filter_row(line, previous, filter_type, image.channels))
        previous = line
    header = struct.pack(">IIBBBBB", image.width, image.height, 8, color_type, 0, 0, 0)
    return (PNG_SIGNATURE + _chunk(b"IHDR", header) +
            _chunk(b"IDAT", zlib.compress(bytes(rows), 6)) + _chunk(b"IEND", b""))
