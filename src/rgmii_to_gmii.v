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

  // ★ P6（2026-11-24）：RGMII RX 数据路径加 IOB 输入延时（EG_LOGIC_IDELAY）。
  //
  //   为什么：RGMII 在 PHY 引脚上数据与 RXC **边沿对齐**（数据翻转与时钟沿同时）。
  //   进 FPGA 后两条路径的插入延时不同（TD 实测）：
  //       数据 → IDDR.d   : PAD 1.075ns
  //       时钟 → IDDR.clk : PAD 1.831 + BUFG 0.000 + 网 1.874 = 3.705ns
  //   时钟比数据晚 2.63ns，而一个 bit 只有 4ns（125MHz DDR）→ 采样点落在数据眼
  //   的 2.63/4 = **66%**，偏晚；到下一位翻转只剩 1.37ns（扣 IDDR hold 0.207 后
  //   1.16ns）。理想是 50%（2.0ns）。所以给数据加 ~0.63ns。
  //
  //   ★★ 必须用**字面量**写 INDEL，不能用模块 parameter 传递。
  //     实测（EG4，TD Release_2026.2）：把值写成模块体内 parameter `RX_IDEL_TAP`
  //     再传给原语，INDEL=2 / 3 / 32 三种取值 TD 全部按默认档（INDEL=1）实现，
  //     报告里 Data Path Delay 恒为 1.147ns；改成字面量 `#(.INDEL(3))` 后立即
  //     响应（1.348ns）。原因未查明（疑似 TD 对"模块 parameter → 原语 parameter"
  //     的常量传播不完整）。**不要为"优雅"改回参数化——那会让调参静默失效。**
  //
  //   ★ TAP=3 的实测依据（EG4 真实模型，不是仿真库标称值）：
  //       INDEL=1  → 附加 0.472ns → 相对差 2.158ns（54.0%）
  //       INDEL=3  → 附加 0.673ns → 相对差 1.957ns（**48.9%**）← 选这个
  //       INDEL=32 → 附加 2.625ns → 相对差 0.680ns（17.0%，过冲）
  //     物理余量 1.16ns → **1.75ns**。
  //     （仿真库 sim_release/eg4/eg_logic_io.v:25 标称 0.52 + (n−1)×0.12 与实际
  //       不符，不要用标称值推算档位，只能按 TD 报告的 Data Path Delay 标定。）
  //
  //   ★★★ 重要认知：**TD 的 hold slack 与物理余量方向相反，不能用来调参。**
  //       该违例的判据是 hold_slack = input_delay_min + data_path − (clk_latency + hold)
  //       即要求"数据在捕获时钟之后到达"，而本设计恰恰靠"时钟晚于数据"实现中心对齐。
  //       实测三个档位：
  //         TAP=1 : slack −2.765ns，采样点 54.0%，余量 1.64ns
  //         TAP=3 : slack −2.564ns，采样点 48.9%，余量 1.75ns   ← 物理最优
  //         TAP=32: slack −0.092ns（几乎"通过"），采样点 17.0%，余量 0.68ns ← 物理最差
  //       **slack 越"好看"，设计越坏。** 所以这条违例永远留着，调参只看采样点
  //       位置（相对差 / 4ns），不看 slack。
  //
  //   ★ 注意 IDELAY 无法旁路：最小档 INDEL=1 已有 0.472ns。若将来某次 build 的
  //     相对差已经 ≤ 2.0ns，加延时就会过冲，届时应复核是否需要保留本段。

  genvar i;
  generate
    for(i=0;i<4;i=i+1)
    begin: rgmii_rxd_i

      wire rxd_dly;                      // IDELAY 之后的 D（进 IDDR 数据脚）

      EG_LOGIC_IDELAY #(.INDEL(3)) IDELAY_rxd (
    .i                                  (rgmii_rxd[i]              ),//  1-Bit input.  IO PAD 输入.
    .o                                  (rxd_dly                   ) //  1-Bit output. 延时后的数据.
);

IDDR_0  IDDR_rxd(
    .q1                                 (gmii_rxd[i+4]             ),//  1-Bit output. 1 bit negedge data output.     
    .q0                                 (gmii_rxd[i]               ),//  1-Bit output. 1 bit posedge data output.     
    .clk                                (rgmii_rxc_int             ),//  1-Bit input. Sampling clock (BUFG 后).
    .d                                  (rxd_dly                   ),//  1-Bit input. DDR data（IDELAY 后）.
    .rst                                (reset                     ) //  1-Bit input. Reset signal,high active.      
);

    end
  endgenerate

  wire rgmii_rxdv_dly;

  EG_LOGIC_IDELAY #(.INDEL(3)) IDELAY_rxdv (
    .i                                  (rgmii_rxdv                ),
    .o                                  (rgmii_rxdv_dly            )
  );

IDDR_0 IDDR_rxdv(
    .q1                                 (gmii_rxer_r               ),//  1-Bit output. 1 bit negedge data output.     
    .q0                                 (gmii_rxdv                 ),//  1-Bit output. 1 bit posedge data output.     
    .clk                                (rgmii_rxc_int             ),//  1-Bit input. Sampling clock (BUFG 后).
    .d                                  (rgmii_rxdv_dly            ),//  1-Bit input. DDR data（IDELAY 后）.
    .rst                                (reset                     ) //  1-Bit input. Reset signal,high active.      
);

    assign                              gmii_rxer                 = gmii_rxer_r^gmii_rxdv;
endmodule