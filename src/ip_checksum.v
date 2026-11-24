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
  //   改为分级求和。依据（时序账，来自 eth_udp_rx_gmii.v 的解析时序）：
  //     · IP 头字段在 cnt_ip_header = 0..19 逐字节锁存，到第 19 拍全部稳定；
  //     · ip_checksum_cal_en 是"第 19 拍"之后的那一拍（单拍脉冲）；
  //     · 下游 ip_header_check_ok 在 cnt_udp_header == 2 采样，即 cal_en 后还有
  //       2 拍余量。
  //   因此：早稳定的字段可以提前算好并寄存，cal_en 拍只做最后 3 项相加。
  //   **suma 仍在 cal_en 拍后一拍有效（与原实现同拍），功能完全等价。**
  //
  //   分组（o1..o9 为原式的 9 个操作数）：
  //     p1a = o1+o2+o3  （{ver,hdr_len,tos} + total_len + id）      cnt 5 前稳定
  //     p1b = o4+o5     （{rsv,df,mf,frag} + {ttl,protocol}）        cnt 9 前稳定
  //     p1_r = p1a_r + p1b_r                                        → 1 级
  //     p2a = o6+o7     （src_ip 高低半）                            cnt 15 前稳定
  //     p2b = o8        （dst_ip 高半）                              cnt 16 前稳定
  //     p2_r = p2a_r + p2b_r                                        → 1 级
  //     suma = p1_r + p2_r + o9 （o9 = dst_ip 低半，cnt 19 才稳定）  → 2 级
  //   最大逻辑级数从 7 降到 2。
  // ==========================================================================
    wire [17:0] p1a = {IP_ver,IP_hdr_len,IP_tos} + IP_total_len + IP_id;
    wire [16:0] p1b = {IP_rsv,IP_df,IP_mf,IP_frag_offset} + {IP_ttl,IP_protocol};
    wire [16:0] p2a = src_ip[31:16] + src_ip[15:0];
    wire [15:0] p2b = dst_ip[31:16];

    reg  [17:0] p1a_r, p1b_r;
    reg  [18:0] p1_r;
    reg  [16:0] p2a_r, p2b_r;
    reg  [17:0] p2_r;

  always@(posedge clk or posedge reset_p)
  if(reset_p) begin
    p1a_r <= 18'd0; p1b_r <= 18'd0; p1_r <= 19'd0;
    p2a_r <= 17'd0; p2b_r <= 17'd0; p2_r <= 18'd0;
  end else begin
    p1a_r <= p1a;
    p1b_r <= p1b;
    p1_r  <= p1a_r + p1b_r;
    p2a_r <= p2a;
    p2b_r <= p2b;
    p2_r  <= p2a_r + p2b_r;
  end

  always@(posedge clk or posedge reset_p)
  if(reset_p)
    suma <= 32'd0;
  else if(cal_en)
    suma <= p1_r + p2_r + dst_ip[15:0];
  else
    suma <= suma;

    assign                              sumb                      = suma[31:16]+suma[15:0];
    assign                              sumc                      = sumb[16]+sumb[15:0];

    assign                              checksum                  = ~sumc;

endmodule
