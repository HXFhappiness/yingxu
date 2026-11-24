// Company       : �人о·��Ƽ����޹�˾
//                 http://xiaomeige.taobao.com
// Web           : http://www.corecourse.cn
// 
// Create Date   : 2021/07/21 00:00:00
// Module Name   : rgmii_to_gmii
// Description   : ��̫������rgmiiתgmii
// 
// Dependencies  : 
// 
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
// 
/////////////////////////////////////////////////////////////////////////////////

module rgmii_to_gmii(
  reset,

  rgmii_rx_clk,
  rgmii_rxd,
  rgmii_rxdv,

  gmii_rx_clk,
  gmii_rxdv,
  gmii_rxd,
  gmii_rxer
);



    input                               reset                      ;

    input                               rgmii_rx_clk               ;
    input              [   3: 0]        rgmii_rxd                  ;
    input                               rgmii_rxdv                 ;

    output                              gmii_rx_clk                ;
    output             [   7: 0]        gmii_rxd                   ;
    output                              gmii_rxdv                  ;
    output                              gmii_rxer                  ;
  
    wire                                gmii_rxer_r                ;
  

    assign                              gmii_rx_clk               = rgmii_rx_clk;

  // ★ P5（2026-11-24）：RXC 先过 BUFG 再给 IDDR 采样——与厂商参考设计一致
  //   （TD 安装目录 ip/depot/OneG_Ethernet_Subsystem_1.0/.../rgmii_interface.v:212-217
  //    的 EG4 分支：EG_LOGIC_BUFG rgmii_rxc_BUFG → rgmii_rxc_int → IDDR.clk）。
  //   注：本模块仅 B 板使用（A 板综合源单不含任何以太网模块），改动不影响 A 板。
  //   ⚠ 实测结论（phy_1，见 docs/YX_BBOARD_P5_PHY1_20261124.md §3）：加 BUFG 后
  //     插入延时仍是 3.705ns（PAD 1.831 + 时钟网 1.874），**hold 违例没有改善**
  //     （−3.237ns / 10 端点）。保留本结构是因为它与厂商参考设计同构、结构上更
  //     正确；真正的修法是给采样时钟加受控相移（厂商用 PLL 的 90° 输出），
  //     本设计暂无 eth 专用 PLL —— 属上板前待解决项。
  wire rgmii_rxc_int;
  BUFG_0 u_bufg_rxc (
    .i (rgmii_rx_clk),
    .o (rgmii_rxc_int)
  );

  genvar i;
  generate
    for(i=0;i<4;i=i+1)
    begin: rgmii_rxd_i

IDDR_0  IDDR_rxd(
    .q1                                 (gmii_rxd[i+4]             ),//  1-Bit output. 1 bit negedge data output.     
    .q0                                 (gmii_rxd[i]               ),//  1-Bit output. 1 bit posedge data output.     
    .clk                                (rgmii_rxc_int             ),//  1-Bit input. Sampling clock (BUFG 后).
    .d                                  (rgmii_rxd[i]              ),//  1-Bit input. DDR data entered on I/O.       
    .rst                                (reset                     ) //  1-Bit input. Reset signal,high active.      
);

    end
  endgenerate


IDDR_0 IDDR_rxdv(
    .q1                                 (gmii_rxer_r               ),//  1-Bit output. 1 bit negedge data output.     
    .q0                                 (gmii_rxdv                 ),//  1-Bit output. 1 bit posedge data output.     
    .clk                                (rgmii_rxc_int             ),//  1-Bit input. Sampling clock (BUFG 后).
    .d                                  (rgmii_rxdv                ),//  1-Bit input. DDR data entered on I/O.       
    .rst                                (reset                     ) //  1-Bit input. Reset signal,high active.      
);

    assign                              gmii_rxer                 = gmii_rxer_r^gmii_rxdv;
endmodule