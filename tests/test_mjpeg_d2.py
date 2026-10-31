"""Independent D2 transport/extended-profile reference checks."""
import unittest
import sys
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'tools'))
from mjpeg_ref.rtl import burst_addresses, choose_owner, mailbox_status, decode
from mjpeg_ref.jpeg import inspect_jpeg, ProfileError
from mjpeg_ref.vectors import make_jpeg

class D2ReferenceTests(unittest.TestCase):
    def test_burst_map_is_exact_frame_partition(self):
        addresses = burst_addresses()
        self.assertEqual(len(addresses), 19200)
        self.assertEqual(sorted(a+i for a in addresses for i in range(8)), list(range(153600)))
        self.assertEqual(burst_addresses(500)[16], 508)
    def test_arbitration_and_stalled_selection(self):
        self.assertEqual([choose_owner(v) for v in range(8)], [None,0,1,0,2,0,1,0])
        self.assertEqual(choose_owner(5,held=2), 2)
    def test_mailbox_status_vectors(self):
        self.assertEqual(mailbox_status(0x12345678000000), 0x155)
        self.assertEqual(mailbox_status(0x12345678000015), 0x140)
    def test_d1_default_profile_preserved_and_d2_accepts_wide(self):
        data=make_jpeg(7200,quantizer=255,dc_values=(1000,-600,300))
        with self.assertRaises(ProfileError): inspect_jpeg(data)
        jpeg,c,first,samples,pixels=decode(data)
        self.assertEqual(int(c[0,0,0]),255000)
        self.assertEqual(int(c[4,0,0]),-153000)
        self.assertLess(int(abs(first).max()),1<<26)
        self.assertEqual(pixels.shape,(480,640))
        self.assertEqual(samples.shape,(7200,8,8))

if __name__=='__main__': unittest.main()
