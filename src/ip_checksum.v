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
  //   修法：去掉"操作数提前打拍"的分组，改为**平衡加法树** —— 深度 4 级，
  //   所有操作数在 cal_en 当拍组合取用。既恢复单拍语义，又把级数压到 4
  //   （原线性链 7 级 ≈ 8.23ns，按每级约 1.18ns 估算，4 级约 4.7ns）。
  //   latency 不变：suma 仍是 cal_en 后一拍有效，RX 侧 cnt_udp_header==2 的
  //   采样余量不受影响。
  // ==========================================================================
    wire [17:0] p1a = {IP_ver,IP_hdr_len,IP_tos} + IP_total_len + IP_id;          // 深度 2
    wire [16:0] p1b = {IP_rsv,IP_df,IP_mf,IP_frag_offset} + {IP_ttl,IP_protocol}; // 深度 1
    wire [16:0] p2a = src_ip[31:16] + src_ip[15:0];                               // 深度 1
    wire [15:0] p2b = dst_ip[31:16];                                              // 深度 0
    wire [15:0] p2c = dst_ip[15:0];                                               // 深度 0

    wire [18:0] t1  = {1'b0,p1a} + {2'b00,p1b};                                   // 深度 3
    wire [17:0] t2  = {1'b0,p2a} + {2'b00,p2b} + {2'b00,p2c};                     // 深度 3

  always@(posedge clk or posedge reset_p)
  if(reset_p)
    suma <= 32'd0;
  else if(cal_en)
    // ★ 全部操作数在 cal_en 当拍取用（见上 P6 修正）
    suma <= {12'd0, t1} + {12'd0, t2};                                            // 深度 4
  else
    suma <= suma;

    assign                              sumb                      = suma[31:16]+suma[15:0];
    assign                              sumc                      = sumb[16]+sumb[15:0];

    assign                              checksum                  = ~sumc;

endmodule
