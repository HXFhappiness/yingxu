# check_cp_trace.py — YX6 排障：CPDBG DELIV 迹线 vs 金标窗逐字对账
# 用法: python -I tools\sim\check_cp_trace.py <cpdbg_sim.log> <goldens\vp_720_5f\idx.mem>
# 会话归属（按观测到的迹线时间序）:
#   S1 base=0  → merge f1 (src=窗0)   S2 base=57600(0交付) 跳过
#   S3 base=57600 → merge f2 (src=窗1)
#   S4/S5 base=57600 → merge f4 (src=窗3, 在 pos=57743 处被抢占分段)
import re, sys

log_path, golden_path = sys.argv[1], sys.argv[2]
lines = open(log_path, encoding="utf-8", errors="replace").read().splitlines()

# 金标窗
gold = [int(l, 16) for l in open(golden_path) if l.strip()]
NBW = 57600
assert len(gold) == 5 * NBW, f"golden size {len(gold)}"

deliv_re = re.compile(r"DELIV wa=(\d+) d=([0-9a-f]{4})")
load_re = re.compile(r"LOAD-DONE addr=(\d+)")

sessions = []   # (base, [(wa,d)...])
cur = None
for ln in lines:
    m = load_re.search(ln)
    if m:
        if cur is not None:
            sessions.append(cur)
        cur = (int(m.group(1)), [])
        continue
    m = deliv_re.search(ln)
    if m and cur is not None:
        cur[1].append((int(m.group(1), 10), int(m.group(2), 16)))
if cur is not None:
    sessions.append(cur)

print(f"sessions={len(sessions)} deliveries={[len(s[1]) for s in sessions]}")

# 归属：有交付的会话依时间序 → f1, f2, f4(可能分段)
attrib = []  # (base, deliveries, frame)
with_d = [s for s in sessions if len(s[1]) > 0]
frame_map = []
for i, s in enumerate(with_d):
    if len(s[1]) and s[1][0][0] < NBW:
        frame_map.append(1)          # base 0 → merge f1
    else:
        frame_map.append(2 if sum(1 for x in frame_map if x >= 2) == 0 else 4)
print("frame attribution:", frame_map)

si = 0
total_err = 0
for s in sessions:
    base, dl = s
    if not dl:
        print(f"session base={base}: 0 deliveries (race-kill, skip)")
        continue
    f = frame_map[si]; si += 1
    win = gold[(f - 1) * NBW:(f) * NBW]
    errs = 0
    first = None
    prev_wa = -1
    wa_desc = 0
    for k, (wa, d) in enumerate(dl):
        if wa < base or wa >= base + NBW:
            print(f"  f{f} OUT-OF-WINDOW wa={wa} base={base}")
            errs += 1
            continue
        exp = win[wa - base]
        if d != exp:
            errs += 1
            if first is None:
                first = k
            if errs <= 6:
                print(f"  f{f} MISMATCH idx={wa-base} wa={wa} got={d:04x} exp={exp:04x} (deliv#{k})")
        if wa < prev_wa:
            wa_desc += 1
        prev_wa = wa
    total_err += errs
    print(f"session base={base} frame=f{f}: deliv={len(dl)} errs={errs} first_err_at={first} wa_descents={wa_desc}")
print(f"TOTAL mismatch={total_err}")
