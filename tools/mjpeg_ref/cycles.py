"""Finite-bank deterministic scheduling model, not measured RTL performance."""
CLOCK_HZ = 50_000_000
CORE_LIMIT = 1_750_000

def schedule(jpeg, *, trace=False):
    # Two coefficient banks, two MCU sample banks, two two-MCU RGB stripes.
    header = 2*jpeg.header_bytes + 16*len(jpeg.huffman_descriptors) + 64*len(jpeg.quant_tables)
    h = i = c = w = header
    coef_free, mcu_free, stripe_free = [0,0], [0,0], [0,0]
    events, hsum, max_block, max_mcu, hwait, iwait, cwait = [], 0, 0, 0, 0, 0, 0
    for mcu in range(1200):
        if mcu and jpeg.restart_interval and mcu % jpeg.restart_interval == 0:
            h += 16  # align, RST sequence check and three predictor resets
        mh = 0
        for local in range(6):
            index = mcu*6+local
            block = jpeg.blocks[index]
            cost = block.cycles
            hs = max(h,coef_free[index % 2])
            hwait += hs-h
            h = hs+cost
            earliest = max(i,h)
            ins = max(earliest,mcu_free[mcu % 2])
            iwait += ins-earliest
            i = ins+176
            coef_free[index % 2] = i
            hsum += cost; mh += cost; max_block = max(max_block,cost)
            if trace:
                events.append({'block':index,'mcu':mcu,'h_start':hs,'h_end':h,'i_start':ins,'i_end':i})
        pair = mcu // 2
        earliest = max(c,i)
        cs = max(earliest,stripe_free[pair % 2])
        cwait += cs-earliest
        c = cs+784
        mcu_free[mcu % 2] = c
        if mcu % 2:
            ws = max(w,c)
            w = ws+288
            stripe_free[pair % 2] = w
        max_mcu = max(max_mcu,mh)
    result = {'model':'finite-bank-v1','clock_hz':CLOCK_HZ,'blocks':len(jpeg.blocks),
              'header_cycles':header,'restart_cycles':jpeg.restarts*16,'huffman_cycles_sum':hsum,'idct_cycles_sum':7200*176,
              'mcu_rgb_cycles_sum':1200*784,'stripe_cycles_sum':600*288,
              'max_huffman_block_cycles':max_block,'max_huffman_mcu_cycles':max_mcu,
              'coefficient_bank_wait_cycles':hwait,'idct_mcu_bank_wait_cycles':iwait,
              'rgb_stripe_wait_cycles':cwait,'frame_cycles':w,'frame_ms':w/CLOCK_HZ*1000,
              'period_ratio':w/(CLOCK_HZ/24),'core_limit_cycles':CORE_LIMIT,
              'accepted':w <= CORE_LIMIT,
              'assumptions':['JPEG bytes always available; SD stalls excluded',
                             '16-word output sink unstalled; SDRAM commit excluded',
                             'IDCT 176 cycles/block and MCU RGB 784 cycles/MCU are design assumptions']}
    if trace:
        result['events'] = events
    return result
