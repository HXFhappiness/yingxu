"""D1 regression: syntax, entropy, fixed point, bounded scheduling and YXV safety."""
import copy
import random
import struct
import sys
import unittest
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'tools'))
from mjpeg_ref.jpeg import (Bits, ProfileError, canonical, inspect_jpeg, split_mjpeg, ZIGZAG)
from mjpeg_ref.vectors import make_jpeg, seg
from mjpeg_ref.cycles import schedule
from mjpeg_ref.container import build_container, inspect_container
from mjpeg_ref.image import idct_int, idct_float, rgb565, decode_rgb565

class ProfileTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.flat=make_jpeg()
    def error(self,code,call,*args,**kwargs):
        with self.assertRaises(ProfileError) as caught:
            call(*args,**kwargs)
        self.assertEqual(caught.exception.code,code)
    def test_flat_complete_frame(self):
        j=inspect_jpeg(self.flat,collect_coefficients=True)
        self.assertEqual(len(j.blocks),7200)
        self.assertTrue(all(b.coefficients == (0,)*64 for b in j.blocks))
        self.assertEqual(sum(b.symbols for b in j.blocks),14400)
    def test_custom_quant_huffman_and_negative_dc(self):
        j=inspect_jpeg(make_jpeg(7200,quantizer=3,dc_values=(-8,4,-2)),collect_coefficients=True)
        self.assertEqual(j.blocks[0].coefficients[0],-24)
        self.assertEqual(j.blocks[4].coefficients[0],12)
        self.assertEqual(j.blocks[5].coefficients[0],-6)
        self.assertEqual(j.blocks[0].coefficients[1],-3)
    def test_long_huffman(self):
        j=inspect_jpeg(make_jpeg(7200,long_codes=True))
        self.assertEqual(j.blocks[0].huffman_bits,33)
    def test_restart_wrap_predictor(self):
        for interval in (1,3,40):
            with self.subTest(interval=interval):
                j=inspect_jpeg(make_jpeg(restart=interval,dc_values=(-8,4,-2)),collect_coefficients=True)
                self.assertEqual(j.restarts,1199//interval)
                self.assertTrue(all(b.coefficients[0] == (-8,4,-2)[b.component] for b in j.blocks))
    def test_bad_restart_number(self):
        b=make_jpeg(restart=40).replace(b'\xff\xd0',b'\xff\xd2',1)
        self.error('RST_SEQUENCE',inspect_jpeg,b)
    def test_coefficient_limit(self):
        self.error('COEFFICIENT_RANGE',inspect_jpeg,make_jpeg(quantizer=255,dc_values=(9,0,0)))
    def test_zero_quant(self):
        self.error('DQT_VALUE',inspect_jpeg,make_jpeg(quantizer=0))
    def test_progressive(self):
        self.error('JPEG_PROCESS',inspect_jpeg,self.flat.replace(b'\xff\xc0',b'\xff\xc2',1))
    def test_sampling_444(self):
        self.error('SAMPLING',inspect_jpeg,self.flat.replace(bytes([1,0x22,0,2,0x11]),bytes([1,0x11,0,2,0x11]),1))
    def test_missing_table(self):
        pos=self.flat.index(b'\xff\xc4'); n=int.from_bytes(self.flat[pos+2:pos+4],'big')
        self.error('MISSING_TABLE',inspect_jpeg,self.flat[:pos]+self.flat[pos+n+2:])
    def test_unsupported_dqt_precision(self):
        b=bytearray(self.flat); b[b.index(b'\xff\xdb')+4]=0x10
        self.error('DQT_PROFILE',inspect_jpeg,b)
    def test_table_id_one(self):
        b=bytearray(self.flat)
        b[b.index(b'\xff\xdb')+4]=1
        sof=b.index(b'\xff\xc0')
        for n in (12,15,18):
            b[sof+n]=1
        dht=b.index(b'\xff\xc4')
        b[dht+4]=1; b[dht+33]=0x11
        sos=b.index(b'\xff\xda')
        for n in (6,8,10):
            b[sos+n]=0x11
        j=inspect_jpeg(b)
        self.assertIn(1,j.quant_tables)
        self.assertIn((1,1),j.huffman_descriptors)
    def test_zrl_crosses_block(self):
        from mjpeg_ref.vectors import Writer
        header=inspect_jpeg(self.flat).header_bytes
        bits=Writer(); bits.put(0,1)
        for _ in range(4):
            bits.put(0b110,3)
        bits.align()
        bad=self.flat[:header]+bytes(bits.out)+b'\xff\xd9'
        self.error('AC_RUN',inspect_jpeg,bad)
    def test_size_limit(self):
        self.error('FRAME_SIZE',inspect_jpeg,self.flat+bytes(40961))
    def test_truncated_segment(self):
        self.error('SEGMENT_LENGTH',inspect_jpeg,b'\xff\xd8\xff\xdb\xff\xff')
    def test_missing_eoi(self):
        self.error('MARKER',inspect_jpeg,self.flat[:-2])
    def test_trailing_bytes(self):
        self.error('TRAILING_DATA',inspect_jpeg,self.flat+b'x')
    def test_split_ignores_eoi_inside_app(self):
        data=make_jpeg(app_payload=b'Exif\0\xff\xd8\xff\xd9\0')
        self.assertEqual(split_mjpeg(data+self.flat),[data,self.flat])
        inspect_jpeg(data)
    def test_split_rejects_truncation(self):
        self.error('TRUNCATED',split_mjpeg,self.flat[:-1])
    def test_canonical_oversubscribed(self):
        self.error('DHT_TREE',canonical,[3]+[0]*15,[0,1,2],0)
    def test_canonical_all_ones(self):
        self.error('DHT_TREE',canonical,[2]+[0]*15,[0,1],0)
    def test_canonical_duplicate(self):
        self.error('DHT_SYMBOL',canonical,[1,1]+[0]*14,[0,0],0)
    def test_ff00_and_negative_amplitude(self):
        b=Bits(b'\xff\x00\x00',0)
        self.assertEqual(b.amplitude(8),255)
        self.assertEqual(b.amplitude(8),-255)
        self.assertEqual(b.stuffed,1)
    def test_padding(self):
        b=Bits(b'\x00',0); b.bit()
        self.error('PAD_BITS',b.align)
    def test_entropy_marker_not_byte(self):
        self.error('ENTROPY_MARKER',Bits(b'\xff\xd0',0).bit)
    def test_zigzag_is_permutation(self):
        self.assertEqual(sorted(ZIGZAG),list(range(64)))
        self.assertEqual(ZIGZAG[:6],(0,1,8,16,9,2))

class ContainerTests(unittest.TestCase):
    error=ProfileTests.error
    @classmethod
    def setUpClass(cls):
        cls.frame=make_jpeg()
        cls.data,cls.audio_off=build_container([cls.frame],bytes(8000))
    def test_valid(self):
        r=inspect_container(self.data)
        self.assertEqual(r['audio_bytes'],8000)
        self.assertEqual(r['audio_off'],self.audio_off)
        self.assertEqual(r['frames'],1)
    def test_overlap(self):
        data,_=build_container([self.frame,self.frame],bytes(16000))
        b=bytearray(data); first=struct.unpack_from('<I',b,32)[0]; struct.pack_into('<I',b,40,first)
        self.error('YXV_OVERLAP',inspect_container,b)
    def test_bad_count(self):
        b=bytearray(self.data); struct.pack_into('<I',b,12,513)
        self.error('FRAME_COUNT',inspect_container,b)
    def test_audio_tail(self):
        self.error('YXV_AUDIO',inspect_container,self.data+b'1234')
    def test_short_audio(self):
        data,_=build_container([self.frame],bytes(192000))
        self.error('AV_DURATION',inspect_container,data)
    def test_unaligned(self):
        b=bytearray(self.data); struct.pack_into('<I',b,28,513)
        self.error('YXV_TABLE',inspect_container,b)
    def test_huge_extent(self):
        b=bytearray(self.data); struct.pack_into('<I',b,32,0xfffffe00)
        self.error('YXV_FRAME_RANGE',inspect_container,b)
    def test_bad_header(self):
        b=bytearray(self.data); b[5]=1
        self.error('YXV_HEADER',inspect_container,b)
    def test_bad_profile(self):
        b=bytearray(self.data); struct.pack_into('<H',b,10,15)
        self.error('YXV_PROFILE',inspect_container,b)

class ImageTests(unittest.TestCase):
    def test_dc_and_clip(self):
        for dc,expected in ((0,128),(8,129),(-8,127),(2047,255),(-2048,0)):
            with self.subTest(dc=dc):
                self.assertEqual(idct_int([dc]+[0]*63),[expected]*64)
    def test_independent_float_reference(self):
        rng=random.Random(20261031)
        for _ in range(20):
            coeff=[rng.randint(-2048,2047) for _ in range(64)]
            self.assertLessEqual(max(abs(a-b) for a,b in zip(idct_int(coeff),idct_float(coeff))),3)
    def test_single_ac_and_negative_rounding(self):
        for k in (1,8,63):
            c=[0]*64; c[k]=-37
            self.assertLessEqual(max(abs(a-b) for a,b in zip(idct_int(c),idct_float(c))),3)
    def test_neutral_color(self):
        self.assertEqual(rgb565(128,128,128),0x8410)
        self.assertEqual(rgb565(0,128,128),0)
        self.assertEqual(rgb565(255,128,128),65535)
    def test_mcu_quadrant_mapping(self):
        j=inspect_jpeg(make_jpeg(),collect_coefficients=True)
        for k,dc in enumerate((-512,0,512,1016)):
            j.blocks[k].coefficients=(dc,)+(0,)*63
        pixels=decode_rgb565(j)
        for x,y,luma in ((0,0,64),(8,0,128),(0,8,192),(8,8,255)):
            self.assertEqual(pixels[y*640+x],rgb565(luma,128,128))
        self.assertEqual(len(pixels),640*480)

class CycleTests(unittest.TestCase):
    def test_counts_and_actual_rejection(self):
        j=inspect_jpeg(make_jpeg())
        r=schedule(j,trace=True)
        self.assertTrue(r['accepted'])
        self.assertEqual(r['idct_cycles_sum'],1267200)
        self.assertEqual(len(r['events']),7200)
        for prior,next_event in zip(r['events'],r['events'][2:]):
            self.assertGreaterEqual(next_event['h_start'],prior['i_end'])
        dense=copy.deepcopy(j)
        for block in dense.blocks:
            block.huffman_bits=1000; block.symbols=64
        self.assertFalse(schedule(dense)['accepted'])
    def test_distribution_changes_latency(self):
        a=schedule(inspect_jpeg(make_jpeg(100000)))
        b=schedule(inspect_jpeg(make_jpeg(100000,style='frontloaded')))
        self.assertGreater(a['huffman_cycles_sum'],b['huffman_cycles_sum'])
        self.assertLess(a['frame_cycles'],b['frame_cycles'])

if __name__=='__main__':
    unittest.main()
