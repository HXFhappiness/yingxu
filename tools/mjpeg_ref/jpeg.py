"""Strict SOF0/4:2:0 decoder. All offsets refer to the original JPEG bytes."""
from dataclasses import dataclass

class ProfileError(ValueError):
    def __init__(self, code, message):
        self.code = code
        super().__init__(f'{code}: {message}')

def require(ok, code, message):
    if not ok:
        raise ProfileError(code, message)

ZIGZAG = (0,1,8,16,9,2,3,10,17,24,32,25,18,11,4,5,
          12,19,26,33,40,48,41,34,27,20,13,6,7,14,21,28,
          35,42,49,56,57,50,43,36,29,22,15,23,30,37,44,51,
          58,59,52,45,38,31,39,46,53,60,61,54,47,55,62,63)

def marker(data, pos):
    require(pos < len(data) and data[pos] == 255, 'MARKER', f'expected FF at {pos}')
    while pos < len(data) and data[pos] == 255:
        pos += 1
    require(pos < len(data), 'TRUNCATED', 'partial marker')
    code = data[pos]
    require(code != 0, 'MARKER', 'stuffed byte outside entropy')
    return code, pos + 1

def segment(data, pos):
    require(pos + 2 <= len(data), 'TRUNCATED', 'segment length')
    n = int.from_bytes(data[pos:pos+2], 'big')
    require(n >= 2 and pos + n <= len(data), 'SEGMENT_LENGTH', f'length={n}, offset={pos}')
    return data[pos+2:pos+n], pos+n

def canonical(counts, symbols, kind):
    require(len(counts) == 16 and 0 < sum(counts) == len(symbols) <= 256,
            'DHT_LENGTH', 'counts/symbol count')
    require(len(set(symbols)) == len(symbols), 'DHT_SYMBOL', 'duplicate symbol')
    if kind == 0:
        require(all(s <= 11 for s in symbols), 'DHT_SYMBOL', 'baseline DC category > 11')
    else:
        require(all(s in (0,240) or 1 <= (s & 15) <= 10 for s in symbols),
                'DHT_SYMBOL', 'baseline AC category or zero-size run')
    table, descriptors, code, base = {}, [], 0, 0
    for length, count in enumerate(counts, 1):
        require(code + count <= 1 << length, 'DHT_TREE', 'oversubscribed tree')
        require(not count or code + count < 1 << length, 'DHT_TREE', 'all-ones code forbidden')
        descriptors.append((code, count, base))
        for j in range(count):
            table[length,code+j] = symbols[base+j]
        base += count
        code = (code + count) << 1
    return table, tuple(descriptors)

class Bits:
    def __init__(self, data, pos):
        self.data, self.pos, self.value, self.left = data, pos, 0, 0
        self.huffman_bits = self.amplitude_bits = self.stuffed = 0
    def bit(self):
        if not self.left:
            require(self.pos < len(self.data), 'TRUNCATED', 'entropy byte')
            value = self.data[self.pos]
            self.pos += 1
            if value == 255:
                require(self.pos < len(self.data), 'TRUNCATED', 'FF in entropy')
                require(self.data[self.pos] == 0, 'ENTROPY_MARKER',
                        f'unexpected FF{self.data[self.pos]:02X} at {self.pos-1}')
                self.pos += 1
                self.stuffed += 1
            self.value, self.left = value, 8
        self.left -= 1
        return (self.value >> self.left) & 1
    def amplitude(self, size):
        self.amplitude_bits += size
        value = 0
        for _ in range(size):
            value = (value << 1) | self.bit()
        return value if not size or value >= 1 << (size-1) else value - ((1 << size)-1)
    def symbol(self, table):
        code = 0
        for n in range(1,17):
            code = (code << 1) | self.bit()
            self.huffman_bits += 1
            if (n,code) in table:
                return table[n,code]
        raise ProfileError('HUFFMAN_CODE', 'no code within 16 bits')
    def align(self):
        mask = (1 << self.left)-1
        require(self.value & mask == mask, 'PAD_BITS', 'entropy padding must be ones')
        self.left = 0

@dataclass
class Block:
    mcu: int
    component: int
    subblock: int
    huffman_bits: int
    symbols: int
    coefficients: tuple | None = None
    tokens: tuple | None = None
    stuffed_bytes: int = 0
    @property
    def cycles(self):
        return 64 + 2*self.huffman_bits + 4*self.symbols + 16 + 2*self.stuffed_bytes

@dataclass
class JPEG:
    width: int
    height: int
    size: int
    header_bytes: int
    entropy_bytes: int
    stuffed_bytes: int
    restart_interval: int
    restarts: int
    quant_tables: dict
    huffman_descriptors: dict
    blocks: list
    huffman_tables: dict

def inspect_jpeg(data, *, collect_coefficients=False, collect_trace=False, max_bytes=40960):
    require(len(data) <= max_bytes, 'FRAME_SIZE', f'{len(data)} > {max_bytes}')
    require(data[:2] == b'\xff\xd8', 'SOI', 'missing SOI')
    pos, quant, huff, desc, sof, dri = 2, {}, {}, {}, None, 0
    while True:
        code, pos = marker(data,pos)
        require(code not in (0xD8,0xD9) and not 0xD0 <= code <= 0xD7,
                'JPEG_PROCESS', 'unexpected standalone marker before SOS')
        payload, pos = segment(data,pos)
        require(pos <= 4096, 'HEADER_SIZE', 'JPEG header > 4KiB')
        if code == 0xDB:
            qpos = 0
            while qpos < len(payload):
                info = payload[qpos]; qpos += 1
                require(info >> 4 == 0 and (info & 15) <= 1, 'DQT_PROFILE', '8-bit table ID 0/1 only')
                require(qpos+64 <= len(payload), 'DQT_LENGTH', 'partial quant table')
                values = tuple(payload[qpos:qpos+64]); qpos += 64
                require(all(values), 'DQT_VALUE', 'zero quantizer')
                quant[info & 15] = values
        elif code == 0xC4:
            hp = 0
            while hp < len(payload):
                require(hp+17 <= len(payload), 'DHT_LENGTH', 'partial counts')
                info = payload[hp]; hp += 1
                kind, tid = info >> 4, info & 15
                require(kind <= 1 and tid <= 1, 'DHT_PROFILE', 'DC/AC ID 0/1 only')
                counts = tuple(payload[hp:hp+16]); hp += 16
                ns = sum(counts)
                require(hp+ns <= len(payload), 'DHT_LENGTH', 'partial symbols')
                symbols = tuple(payload[hp:hp+ns]); hp += ns
                huff[kind,tid], desc[kind,tid] = canonical(counts,symbols,kind)
        elif code == 0xC0:
            require(sof is None and len(payload) == 15 and payload[0] == 8 and payload[5] == 3,
                    'SOF_PROFILE', 'single 8-bit, 3-component SOF0 required')
            height, width = int.from_bytes(payload[1:3],'big'), int.from_bytes(payload[3:5],'big')
            require((width,height) == (640,480), 'DIMENSIONS', f'{width}x{height}; default profile is 640x480')
            sof = [tuple(payload[i:i+3]) for i in (6,9,12)]
            require([c[0] for c in sof] == [1,2,3] and [c[1] for c in sof] == [0x22,0x11,0x11],
                    'SAMPLING', 'YCbCr IDs 1/2/3 with sampling 22/11/11 required')
            require(all(c[2] <= 1 for c in sof) and sof[1][2] == sof[2][2],
                    'TABLE_SELECT', 'Cb/Cr must share quant table ID 0/1')
        elif code == 0xDD:
            require(len(payload) == 2, 'DRI_LENGTH', 'DRI requires 2 bytes')
            dri = int.from_bytes(payload,'big')
        elif code == 0xDA:
            require(sof is not None and len(payload) == 10 and payload[0] == 3,
                    'SOS_PROFILE', 'one interleaved scan requires SOF0 first')
            require(payload[-3:] == bytes([0,63,0]), 'SOS_PROFILE', 'sequential scan parameters')
            scan = [tuple(payload[i:i+2]) for i in (1,3,5)]
            require([c[0] for c in scan] == [1,2,3] and scan[1][1] == scan[2][1],
                    'SOS_PROFILE', 'component order or shared chroma tables')
            for comp, selectors in scan:
                dc, ac = selectors >> 4, selectors & 15
                require(dc <= 1 and ac <= 1 and (0,dc) in huff and (1,ac) in huff,
                        'MISSING_TABLE', f'DHT for component {comp}')
            require(all(c[2] in quant for c in sof), 'MISSING_TABLE', 'missing DQT')
            break
        elif code == 0xFE or 0xE0 <= code <= 0xEF:
            pass
        else:
            raise ProfileError('JPEG_PROCESS', f'unsupported marker FF{code:02X}')
    start = pos
    bits = Bits(data,pos)
    predictors, blocks, rst_count = [0,0,0], [], 0
    for mcu in range(1200):
        for comp, sub in ((0,0),(0,1),(0,2),(0,3),(1,0),(2,0)):
            coeff = [0]*64
            selectors = scan[comp][1]
            dc, ac = huff[0,selectors >> 4], huff[1,selectors & 15]
            bh, ns, stuffed_before = bits.huffman_bits, 1, bits.stuffed
            tokens = [] if collect_trace else None
            size = bits.symbol(dc)
            predictors[comp] += bits.amplitude(size)
            require(-32768 <= predictors[comp] <= 32767, 'DC_RANGE', 'DC predictor overflow')
            coeff[0] = predictors[comp]
            if tokens is not None:
                tokens.append({'kind':'DC','k':0,'quantized':coeff[0]})
            k = 1
            while k < 64:
                rs = bits.symbol(ac); ns += 1
                if rs == 0:
                    if tokens is not None:
                        tokens.append({'kind':'EOB','k':k})
                    break
                if rs == 240:
                    require(k+16 <= 64, 'AC_RUN', 'ZRL crosses block')
                    if tokens is not None:
                        tokens.append({'kind':'ZRL','k':k})
                    k += 16
                    continue
                run, size = rs >> 4, rs & 15
                k += run
                require(1 <= size <= 10 and k < 64, 'AC_RUN', 'AC run/size crosses block')
                coeff[ZIGZAG[k]] = bits.amplitude(size)
                if tokens is not None:
                    tokens.append({'kind':'AC','k':k,'quantized':coeff[ZIGZAG[k]]})
                k += 1
            q = quant[sof[comp][2]]
            for k, index in enumerate(ZIGZAG):
                coeff[index] *= q[k]
                require(-2048 <= coeff[index] <= 2047, 'COEFFICIENT_RANGE',
                        f'MCU {mcu}, component {comp}, coefficient {index}')
            blocks.append(Block(mcu,comp,sub,bits.huffman_bits-bh,ns,
                                tuple(coeff) if collect_coefficients else None,
                                tuple(tokens) if tokens is not None else None,bits.stuffed-stuffed_before))
        if dri and (mcu+1) % dri == 0 and mcu != 1199:
            bits.align()
            code, bits.pos = marker(data,bits.pos)
            require(code == 0xD0+(rst_count % 8), 'RST_SEQUENCE',
                    f'MCU {mcu}, expected RST{rst_count%8}, got FF{code:02X}')
            rst_count += 1
            predictors = [0,0,0]
    bits.align()
    code, end = marker(data,bits.pos)
    require(code == 0xD9, 'EOI', 'extra data/marker after last MCU')
    require(end == len(data), 'TRAILING_DATA', f'{len(data)-end} bytes after EOI')
    return JPEG(width,height,len(data),start,len(data)-start-2,bits.stuffed,dri,rst_count,
                quant,desc,blocks,huff)

def split_mjpeg(data):
    """Segment-aware splitting: FFD9 inside APP/COM is not an EOI."""
    frames, pos = [], 0
    while pos < len(data):
        start = pos
        require(data[pos:pos+2] == b'\xff\xd8', 'SOI', f'MJPEG offset {pos}')
        pos += 2
        while True:
            code, pos = marker(data,pos)
            _, pos = segment(data,pos)
            if code == 0xDA:
                break
        while True:
            require(pos < len(data), 'TRUNCATED', 'MJPEG entropy/EOI')
            if data[pos] != 255:
                pos += 1
                continue
            tail = pos+1
            while tail < len(data) and data[tail] == 255:
                tail += 1
            require(tail < len(data), 'TRUNCATED', 'MJPEG FF')
            code = data[tail]
            if code == 0 or 0xD0 <= code <= 0xD7:
                pos = tail+1
                continue
            require(code == 0xD9, 'JPEG_PROCESS', f'unsupported entropy marker FF{code:02X}')
            pos = tail+1
            frames.append(data[start:pos])
            break
    return frames
