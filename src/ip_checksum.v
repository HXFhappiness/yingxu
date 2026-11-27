/////////////////////////////////////////////////////////////////////////////////
// Company       : �人о·��Ƽ����޹�˾
//                 http://xiaomeige.taobao.com
// Web           : http://www.corecourse.cn
// 
// Create Date   : 2019/05/01 00:00:00
// Module Name   : ip_checksum
// Description   : ipͷ��У��ģ��
// 
// Dependencies  : 
// 
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
// 
/////////////////////////////////////////////////////////////////////////////////

module ip_checksum(
    input                               clk                        ,
    input                               reset_p                    ,

    input                               cal_en                     ,

    input              [   3: 0]        IP_ver                     ,
    input              [   3: 0]        IP_hdr_len                 ,
    input              [   7: 0]        IP_tos                     ,
    input              [  15: 0]        IP_total_len               ,
    input              [  15: 0]        IP_id                      ,
    input                               IP_rsv                     ,
    input                               IP_df                      ,
    input                               IP_mf                      ,
    input              [  12: 0]        IP_frag_offset             ,
    input              [   7: 0]        IP_ttl                     ,
    input              [   7: 0]        IP_protocol                ,
    input              [  31: 0]        src_ip                     ,
    input              [  31: 0]        dst_ip                     ,

    output             [  15: 0]        checksum                    
);

    reg                [  31: 0]        suma                       ;
    wire               [  16: 0]        sumb                       ;
    wire               [  15: 0]        sumc                       ;

  // ==========================================================================
  // ★ P5 修正（2026-11-24）：原实现在**单拍**内把 9 个 16 位操作数相加，
  //   TD 综合成 7 级线性 ADDER 链（实测 Data Path 8.229ns > 8ns 预算，
  //   setup −563ps / 7 个违例端点，见 docs/YX_BBOARD_P5_PHY1_20261124.md §2）。
  //
  // ★ P6 修正（2026-11-26）：P5 的分级版本把级数压到 2，但**采样点错了**：
  //   它把操作数分成 p1a/p1b/p2a/p2b 各打 1~2 拍寄存器，`suma` 在 cal_en 拍
  //   只做 p1_r + p2_r + dst_ip[15:0]。而 p1_r/p2_r 里的操作数是 **2 拍前**的值，
  //   dst_ip[15:0] 却是**当拍**的值 —— 混了两个时间点。
  //
  //   实测症状（P6 端到端）：板 A 发出的第 1 个 UDP 包 IP 头校验和为 0xF91A，
  //   而该头（total_len=0x05DC）的正确值是 0xF35A。反解 0xF91A 对应的
  //   total_len 恰好是 0x001C = 28，即 data_length 被当成 0。
  //   原因：yx_a_vq_sender 在 T+1 才把 frag_bytes 从 0 置成 1472，tx_en_pulse
  //   在 T+2 到达 → p1_r 里锁的是 total_len=28。从第 2 个包起 data_length 早已
  //   稳定，校验和正确。于是**只有首个包被 eth_udp_rx_gmii 按坏 IP 头丢弃**，
  //   B 侧字节流从第 2 个分片开始（少了整个 1472B 首片 = YXV2 头 + 码本开头），
  //   hdr_parse 从码本中间解析 → hdr_err、一帧不解。
  //
  //   正确语义：**全部 9 个操作数都必须在 cal_en 当拍采样**（与原始实现一致）。
  //
  // ★ P6 时序修正（2026-11-27）：上面的平衡树在 RTL 里名义深度 4，但 TD 把
  //   `s1..s4 → t1,t2 → suma` **合成了一条进位链**（route 后实测 6 级 ADDER
  //   串联：add1_313 → add1_314 → add1_304 → add1_305 → add0_552 → add0_541
  //   → add0_542，arrival 11.899ns vs 8ns 周期，SWNS −0.457ns / 8 个违例端点）。
  //   ⇒ 必须**真正打拍切断**进位链，但又要保持"同一批操作数"。
  //
  //   可行性依据（RX 侧实测时序余量，见 eth_udp_rx_gmii.v 状态机）：
  //     · 操作数在 cnt_ip_header = 0..19 逐字节锁存，到 19 全部稳定；
  //     · curr_state 在 cnt_ip_header==19 的**下一拍**转 RX_UDP_HEADER，
  //       cal_en 也在那一拍置位；
  //     · 消费点 ip_header_check_ok 在 cnt_udp_header==2 采样，
  //       即 cal_en 之后**第 3 拍**（cnt_udp_header 从 0 数到 2）。
  //   ⇒ 原设计 suma 在 cal_en+1 有效、check_ok 在 cal_en+2 锁存、消费 cal_en+3，
  //     **只剩 1 拍余量**。任何额外延时都会破坏它（实测：加 1 拍 → eth_rx 卡死）。
  //
  //   实现（**latency 零增加**，且不混时间点）：
  //     · 9 个操作数里，**只有 dst_ip[15:0] 在 cal_en 前一拍还没稳定**
  //       （rx_dst_ip[7:0] 在 cnt_ip_header==19 那拍写入，下一拍才可见）；
  //       其余 8 项在 cnt_ip_header==18 时就全部稳定了。
  //     · 于是：**每拍**把前 8 项的部分和算好锁进 acc8_r（深度 3，独立进位链）；
  //       cal_en 当拍只做「acc8_r + dst_ip[15:0]」一次加法（深度 1）。
  //     · acc8_r 在 cal_en 当拍装的是"上一拍算的 8 项和"，而这 8 项在上一拍
  //       与当拍**完全相同**（它们早在 cnt==18 就稳定）→ 不混时间点。
  //       ★ 唯一的 dst_ip[15:0] 用 cal_en **当拍**值 —— 它才是刚稳定的那一项。
  //     · suma 仍在 cal_en+1 有效（与原设计一致），消费点余量不变。
  // ==========================================================================
    // 前 8 项（不含 dst_ip[15:0]），深度 3 的平衡树
    wire [17:0] q1 = {IP_ver,IP_hdr_len,IP_tos} + IP_total_len;
    wire [16:0] q2 = IP_id + {IP_rsv,IP_df,IP_mf,IP_frag_offset};
    wire [16:0] q3 = {IP_ttl,IP_protocol} + src_ip[31:16];
    wire [16:0] q4 = src_ip[15:0] + dst_ip[31:16];
    wire [18:0] qa = {1'b0,q1} + {2'b00,q2};      // 深度 3
    wire [18:0] qb = {2'b00,q3} + {2'b00,q4};     // 深度 3
    wire [19:0] acc8 = {1'b0,qa} + {1'b0,qb};     // 深度 4（独立进位链）

    reg  [19:0] acc8_r;                            // 每拍锁存前 8 项和

  always@(posedge clk or posedge reset_p)
  if(reset_p) begin
    acc8_r <= 20'd0;
    suma   <= 32'd0;
  end else begin
    acc8_r <= acc8;                                // 无条件打拍：切断进位链
    if(cal_en)
      // 只加一次（深度 1）。dst_ip[15:0] 取 cal_en 当拍值 —— 它是唯一刚稳定的项。
      suma <= {12'd0, acc8_r} + {16'd0, dst_ip[15:0]};
  end

    assign                              sumb                      = suma[31:16]+suma[15:0];
    assign                              sumc                      = sumb[16]+sumb[15:0];

    assign                              checksum                  = ~sumc;

endmodule
