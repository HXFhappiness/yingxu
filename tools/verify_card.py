# -*- coding: utf-8 -*-
"""verify_card.py — 抽查照片区 'BM' 头 + 卡带 YXCA 头"""
import sys
sys.path.insert(0, r'C:\Users\HXF\Desktop\YX\tools')
from write_cart import Vol, find_partition_offset

v = Vol('E')
off = find_partition_offset(v)
print('分区偏移:', off)
for lba, name in [(32672, 'photo1'), (38080, 'photo2'), (43488, 'photo3'),
                  (70560, 'photo8')]:
    v.seek(lba - off)
    sec = v.read(512)
    ok = sec[:2] == b'BM'
    print(name, 'LBA', lba, '->', sec[:2].hex(), 'OK' if ok else 'BAD!')
v.seek(1_000_000 - off)
sec = v.read(512)
print('cartridge LBA 1000000 ->', sec[:4], 'OK' if sec[:4] == b'YXCA' else 'BAD!')
v.close()
