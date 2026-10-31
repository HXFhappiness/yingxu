"""Reproducible synthetic JPEGs, including entropy-heavy exact-40KiB cases."""
import struct
from .jpeg import canonical, require

def seg(code,payload):
    return bytes([255,code])+struct.pack('>H',len(payload)+2)+payload

class Writer:
    def __init__(self):
        self.out, self.value, self.n = bytearray(), 0, 0
    def put(self,value,n):
        self.value = (self.value << n) | value
        self.n += n
        while self.n >= 8:
            self.n -= 8
            b = (self.value >> self.n) & 255
            self.out.append(b)
            if b == 255:
                self.out.append(0)
            self.value &= (1 << self.n)-1
    def align(self):
        if self.n:
            self.put((1 << (8-self.n))-1,8-self.n)
    def rst(self,index):
        self.align()
        self.out.extend([255,0xD0+index % 8])

def table(kind,counts,symbols):
    decoded,_ = canonical(counts,symbols,kind)
    return bytes([kind << 4])+bytes(counts)+bytes(symbols), {v:(code,n) for (n,code),v in decoded.items()}

def make_jpeg(nonzeros=0, *, style='balanced', long_codes=False, restart=0,
              quantizer=1, dc_values=(0,0,0), app_payload=None, exact_size=None):
    if isinstance(nonzeros,int):
        total = nonzeros
        require(0 <= total <= 7200*63,'VECTOR','nonzero coefficient count')
        if style == 'balanced':
            counts = [total//7200 + (i < total%7200) for i in range(7200)]
        else:
            counts = [min(63,max(0,total-i*63)) for i in range(7200)]
            if style == 'backloaded':
                counts.reverse()
    else:
        counts = list(nonzeros)
        require(len(counts) == 7200 and all(0 <= x <= 63 for x in counts),'VECTOR','block counts')
    dc_counts = [1,0,0,0,11]+[0]*11
    dc_blob,dc_codes = table(0,dc_counts,list(range(12)))
    ac_counts = ([0]*15+[3]) if long_codes else ([1,1,1]+[0]*13)
    ac_blob,ac_codes = table(1,ac_counts,[1,0,240])
    header = b'\xff\xd8'
    if app_payload is not None:
        header += seg(0xE1,app_payload)
    header += seg(0xDB,bytes([0])+bytes([quantizer])*64)
    header += seg(0xC0,bytes([8])+struct.pack('>HHB',480,640,3)+bytes([1,0x22,0,2,0x11,0,3,0x11,0]))
    header += seg(0xC4,dc_blob+ac_blob)
    if restart:
        header += seg(0xDD,struct.pack('>H',restart))
    sos = seg(0xDA,bytes([3,1,0,2,0,3,0,0,63,0]))
    out, pred, rst = Writer(), [0,0,0], 0
    for mcu in range(1200):
        for local,comp in enumerate((0,0,0,0,1,2)):
            value = dc_values[comp]
            diff = value-pred[comp]; pred[comp]=value
            size = abs(diff).bit_length()
            code,n = dc_codes[size]; out.put(code,n)
            out.put(diff if diff >= 0 else diff+(1 << size)-1,size)
            count = counts[mcu*6+local]
            code,n = ac_codes[1]
            for k in range(count):
                out.put(code,n)
                # Alternate sign; predominantly short codewords, not APP padding.
                out.put((mcu+local+k) & 1,1)
            if count < 63:
                code,n = ac_codes[0]; out.put(code,n)
        if restart and (mcu+1) % restart == 0 and mcu != 1199:
            out.rst(rst); rst+=1; pred=[0,0,0]
    out.align()
    result = header+sos+bytes(out.out)+b'\xff\xd9'
    if exact_size is not None:
        padding = exact_size-len(result)
        require(padding == 0 or 4 <= padding <= 3500,'VECTOR','exact-size COM padding range')
        if padding:
            result = header+seg(0xFE,bytes(padding-4))+sos+bytes(out.out)+b'\xff\xd9'
    return result

def boundary_frame(*,style='balanced',long_codes=False):
    lo,hi=0,7200*63
    while lo < hi:
        mid=(lo+hi+1)//2
        if len(make_jpeg(mid,style=style,long_codes=long_codes)) <= 40956:
            lo=mid
        else:
            hi=mid-1
    return make_jpeg(lo,style=style,long_codes=long_codes,exact_size=40960)
