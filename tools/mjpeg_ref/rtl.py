"""D2 integer reference and transport contracts (NumPy only for image batches).

This opts into 64KiB/s24 inspection; the D1 converter's narrower defaults remain.
"""
from .jpeg import inspect_jpeg
from .image import K


def decode(data):
    import numpy as np
    jpeg = inspect_jpeg(data, collect_coefficients=True, max_bytes=65535, coefficient_bits=24)
    c = np.array([b.coefficients for b in jpeg.blocks], dtype=np.int64).reshape(-1, 8, 8)
    k = np.array(K, dtype=np.int64)
    first = (c @ k.T + 32768) // 65536
    samples = np.clip((k @ first + 32768) // 65536 + 128, 0, 255)
    a = samples.reshape(30, 40, 6, 8, 8)
    luma = np.empty((30, 16, 40, 16), dtype=np.int64)
    for by in range(2):
        for bx in range(2):
            luma[:, by*8:by*8+8, :, bx*8:bx*8+8] = a[:, :, by*2+bx].transpose(0, 2, 1, 3)
    y = luma.reshape(480, 640)
    cb = a[:, :, 4].transpose(0, 2, 1, 3).reshape(240, 320).repeat(2, 0).repeat(2, 1)-128
    cr = a[:, :, 5].transpose(0, 2, 1, 3).reshape(240, 320).repeat(2, 0).repeat(2, 1)-128
    rgb = np.stack([y+(22970*cr+8192)//16384,
                    y+(-5638*cb-11700*cr+8192)//16384,
                    y+(29032*cb+8192)//16384], axis=2).clip(0, 255)
    pixels = (((rgb[:, :, 0] >> 3) << 11) | ((rgb[:, :, 1] >> 2) << 5) |
              (rgb[:, :, 2] >> 3)).astype('>u2')
    return jpeg, c, first, samples, pixels


def table_images(jpeg):
    symbols, smask, desc, dmask = [0]*1024, [0]*1024, [0]*128, [0]*128
    for qid, values in jpeg.quant_tables.items():
        for i, v in enumerate(values):
            symbols[576+qid*64+i], smask[576+qid*64+i] = v, 1
    for (kind, tid), table in jpeg.huffman_tables.items():
        base = 64+tid*256 if kind else tid*16
        for i, (_, symbol) in enumerate(sorted(table.items())):
            symbols[base+i], smask[base+i] = symbol, 1
        for length, (first, count, offset) in enumerate(jpeg.huffman_descriptors[kind, tid]):
            index = ((kind*2+tid)*16+length)*2
            desc[index:index+2] = [first & 65535, (count << 8) | offset]
            dmask[index:index+2] = [1, 1]
    return symbols, smask, desc, dmask


def burst_addresses(dst=0):
    """MCU-order 8-word row bursts; RGB565 earlier pixel is high halfword."""
    return [dst+(my*16+row)*320+mx*8
            for my in range(30) for mx in range(40) for row in range(16)]


def choose_owner(valid, held=None):
    if held is not None:
        return held
    return next((i for i in range(3) if valid & (1 << i)), None)


def mailbox_status(payload):
    return (payload & 511) ^ 0x155
