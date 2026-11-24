// yingxu_vq_board_b.v — 板 B TD 综合顶层（板级包装；仿真不使用）
//
// 只引出 IO_b.adc 中的板级引脚，内部例化 yingxu_vq_board_top 体系模式
// （SIM_ABSTRACT=0：头解析/索引写/取带读出全部内部实例化）。
// yingxu_vq_board_top 的其余端口是 TB 观测/抽象仿真口，板上不存在：
//   - 输入（stream_* / ix_wr_gnt / cp_* / band_rd_*）：SIM_ABSTRACT=0 + USE_ETH 下
//     均不被消费，恒 0；
//   - 输出（video_* / 计数器 / scan_* / dbg_clk*）：悬空，由综合按需裁剪；
//   - DRAM_*：控制器 ↔ sdram_ip（EG_PHY_SDRAM_2M_32）在 top 内部直连，属专用
//     SDRAM 硬接口，不占通用引脚（与 A 板 yingxu_sdram_framebuffer 同构），悬空。
//
// 构建要求：TD 工程定义宏 EMIT_HDMI 与 USE_ETH（缺任一则下方守卫令综合报错，
// 防止无声地综合出被大面积裁剪的设计）。
module yingxu_vq_board_b #(
    parameter [47:0] LOCAL_MAC  = 48'h00_0a_35_02_00_01,
    parameter [31:0] LOCAL_IP   = 32'hc0_a8_00_64,     // 192.168.0.100
    parameter [15:0] LOCAL_PORT = 16'd5000
)(
    input  wire       ref_clk,
    input  wire       rst_n,
    // 以太网 RGMII（只收）+ PHY 控制
    input  wire       eth_rxc,
    input  wire [3:0] eth_rxd,
    input  wire       eth_rxdv,
    output wire       eth_rst_n,
    output wire       eth_mdc,
    output wire       eth_mdio,
    // HDMI TMDS
    // ★ 不含 DDC：AC201 的 HDMI 口 DDC 未接到 FPGA（引脚信息表 HDMI 段只有
    //   TMDS 四对差分，见 D:\pin_table.txt:95-103；A 板 design_top_wrapper 也
    //   同样不把 DDC 引出顶层）。把 DDC 引成顶层端口又无管脚可约束，会触发
    //   BIT-8123 "unconstrained io" 挡死 bitgen。当前 I_edid_read_trig 恒 0，
    //   DDC 在核内部悬空即可；将来真要读 EDID，先确认硬件改版有这两根线。
    output wire       tmds_ch0_p,
    output wire       tmds_ch1_p,
    output wire       tmds_ch2_p,
    output wire       tmds_clk_p
);

`ifndef USE_ETH
    YX_B_BOARD_BUILD_REQUIRES_DEFINE_USE_ETH u_missing_use_eth ();
`endif
`ifndef EMIT_HDMI
    YX_B_BOARD_BUILD_REQUIRES_DEFINE_EMIT_HDMI u_missing_emit_hdmi ();
`endif

    yingxu_vq_board_top #(
        .SIM_ABSTRACT (0),
        .LOCAL_MAC    (LOCAL_MAC),
        .LOCAL_IP     (LOCAL_IP),
        .LOCAL_PORT   (LOCAL_PORT)
    ) u_top (
        .ref_clk       (ref_clk),
        .rst_n         (rst_n),
        .stream_valid  (1'b0),
        .stream_data   (8'd0),
        .stream_ready  (),
        .eth_rxc       (eth_rxc),
        .eth_rxd       (eth_rxd),
        .eth_rxdv      (eth_rxdv),
        .eth_rst_n     (eth_rst_n),
        .eth_mdc       (eth_mdc),
        .eth_mdio      (eth_mdio),
        .ix_wr_valid   (),
        .ix_wr_addr    (),
        .ix_wr_data    (),
        .ix_wr_gnt     (1'b0),
        .cp_rd         (),
        .cp_addr       (),
        .cp_dvld       (1'b0),
        .cp_data       (16'd0),
        .band_rd_req   (),
        .band_rd_addr  (),
        .band_rd_dvld  (1'b0),
        .band_rd_data  (16'd0),
        .video_user    (),
        .video_valid   (),
        .video_last    (),
        .video_data    (),
        .win_show      (),
        .disp_pass     (),
        .disp_stall    (),
        .commit_no     (),
        .rendered_no   (),
        .frame_done_vq (),
        .scan_done     (),
        .scan_band_no  (),
        .scan_ack      (),
        .band_pend_cnt (),
        .dbg_clk100    (),
        .dbg_pixel_clk (),
        .tmds_ch0_p    (tmds_ch0_p),
        .tmds_ch1_p    (tmds_ch1_p),
        .tmds_ch2_p    (tmds_ch2_p),
        .tmds_clk_p    (tmds_clk_p),
        // DDC 不引出（见端口注释）：顶层内部悬空，与 A 板 design_top_wrapper 同做法
        .tmds_ddc_scl  (),
        .tmds_ddc_sda  (),
        .DRAM_DQ       (),
        .DRAM_ADDR     (),
        .DRAM_BA       (),
        .DRAM_CS_N     (),
        .DRAM_CKE      (),
        .DRAM_RAS_N    (),
        .DRAM_CAS_N    (),
        .DRAM_WE_N     (),
        .DRAM_DQM      (),
        .DRAM_CLK      ()
    );

endmodule
