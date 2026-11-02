# 菜单、照片、视频统一构建

统一分支：`feat/unified-menu-photo-video`。

当前版本已在 `0f92aac` 基础上集成 D6 + D7，菜单改为纯硬件绘制、加入游戏
子菜单与 SW7+key0 返回、0.5 秒开机窗口。当前行为、验证和仿真图见
[D7 交付](D7_DELIVERY.md)。下文保留 `0f92aac` 的合并/验证历史；其中菜单
BMP 首读和视频回退 LBA 的行为已由 D7 硬件菜单替代。构建生成器现验证 65
个工程引用，包含两个新增字模/菜单模块。

合并顺序：

```
0863c41
  └─ e9bfba6  照片首读：load_idx 复位为15
      └─ e2c16b5  照片首读：等待 sd_dbg_init_done
          └─ c218ed1  add9742 视频修复重放后的提交
              └─ 本提交：菜单实体DIP稳定确认及统一验证/构建入口
```

`git range-diff 0863c41..add9742 e2c16b5..c218ed1` 确认视频补丁完全相同。生产视频 arbiter/loader/pipeline 与 add9742 字节一致；照片上电哨兵与等待初始化门禁均保留，LBA 表与 e2c16b5 一致。保留已经通过本地 TD 的 wrapper 菜单条实现。本分支完整包含照片分支两个提交，原分支未改写。

## 统一时补齐的视频回退索引

e9bfba6 把 load_idx 设为15的分支同时用于整机复位和视频模式复位。在SW=77维修直通的坏头回退测试中，video_requested仍为1，load_idx持续为15，实际仿真读出了越界LBA=0。

本版仅在 !rst_n 时设15，以保留上电首次加载；video_requested/owned 的运行时复位设0，保证退出/失败的 photo_reload 脉冲使用菜单 LBA76032。初始化门禁和其余TR流程保留。增加坏头回退的合法LBA断言，修复前预期失败，修复后实际UART/回退验证通过。

## menu_real_change 风险结论

稳定实体 SW 输入时，四种虚拟模式切换本身均不会触发 menu_real_change：检测器原本比较的是实体 sw，不是 sw_eff。

但旧实现直接比较前一拍与当前原始 sw。模式确认后一个周期，给实体 SW0 一个20ns毛刺，可复现误退出：menu_real_change 拉高，随后清除 menu_override，落入实体开关的维修直通/照片路径。这是**故障注入复现**，不是已经测得板上存在该毛刺。

本版增加：

- 两级同步实体 SW；
- 整个8bit开关值稳定20ms后才发布一次改变事件；
- 首次上电只建立基线，不把预置DIP当成操作；
- 维修直通中持续跟踪实体开关，长按回菜单后重新建立基线，避免此前尚未确认的开关动作在回菜单后把它再次退出。

仅确认实体DIP改变时才清 menu_override；menu_pattern/sw_eff 不参与该检测。真正拨动DIP仍进入维修直通，约增加20ms确认时间；菜单 key0/key1 的响应逻辑保持。改动仅在50MHz顶层，未修改MEM域视频修复、PLL或时序约束；新增控制逻辑仍需本地TD时序检查。

## 已执行验证

`python3 tools/menu_mode_verify.py` 使用实际 hardware_test、wrapper、视频pipeline、物理服务和既有厂商/媒体模型，逐项验证：

| sel | key0后结果 | 长按返回 |
| --- | --- | --- |
| 0 图片 | pattern=FF、img_idx=1、照片模式、override保持1 | idx0/sel0/FF，菜单恢复 |
| 1 游戏 | pattern=1F、game_mode=1、cart_active=1 | game/cart关闭，菜单恢复 |
| 2 视频 | pattern=77、video_requested=1、实际owned=1、首LBA=3000000 | 等真实当前事务/解码释放owned后确认回菜单 |
| 3 音乐 | pattern=6F、music_on_w=1、cart_active=0 | music/game关闭，菜单恢复 |

每种模式均做稳定输入、确认瞬间单拍实体SW毛刺两组，共8组；每次进入后都**停留超过真实20ms门限**，确认没有延迟误退出。全部通过。

另外验证8个实体开关位的单拍毛刺均被拒绝；未满20ms的改变随后抖回旧值会重置计时；稳定改变只退出一次；在维修直通中再次拨动DIP后立刻长按返回，菜单仍保持。key_lock仅为测试选项切换加速；长按计数器只预置到2s终点前两拍，仍逐拍验证提前、终点、按住不重复确认。20ms实体DIP计时没有加速。

这是模式控制路径验证，不是各游戏/照片/音乐素材的完整内容回归。初始卡复位使用现有 SIM_FAST_BOOT=1；真实reader/所有权退场流程保留，未 force menu_override、模式译码或owned结果。

其他通过项：

- `python3 tools/d5_menu_verify.py`：五档循环、原菜单条坐标/清表后恢复、模式和返回、实体DIP维修直通。旧30ms测试超时窗按新增真实20ms确认窗口调整为100ms。
- `python3 tools/yxv_d3_verify.py --frames 2`：统一实际顶层，4001样本、HDMI4000样本、460800解码写字、1985280扫描像素零差异，48k误差0ppm，退出一次。测试入口使用稳定实体DIP操作而非已被过滤的短脉冲。
- `python3 tools/yxv_preload_verify.py --fast-card --block 8`：统一分支上的一次漏写命令恢复，486帧/7594扇区、121504 bursts、972032 words 零差异，无额外SD复位；快卡仅为事务模型加速。
- 视频坏头回退实际顶层/UART测试通过，断言回退LBA=76032；不再读取哨兵索引15。
- 对直接提取的生产DIP滤波过程及原菜单条过程，Yosys read/proc/check通过。
- `python3 tools/prepare_unified_td.py`：两次执行验证工程绑定，63个工程引用均存在、124个源码/IP文件哈希一致，原工程文件不变。

旧问题可复现：

```
python3 tools/menu_mode_verify.py --baseline-ref c218ed1
```

该命令在 out 下建立历史顶层副本，不修改工作树。四个稳定模式通过后，实体毛刺测试**预期失败**；此日志不计为通过项。原始日志、补丁等价及源码哈希见 [evidence/UNIFIED_MENU_PHOTO_VIDEO](evidence/UNIFIED_MENU_PHOTO_VIDEO)。

## 本地一次统一构建

首次检出：

```powershell
git fetch origin feat/unified-menu-photo-video
git switch -c feat/unified-menu-photo-video FETCH_HEAD
python tools/prepare_unified_td.py
```

若该本地分支已存在，切换到该分支并 fast-forward 到刚 fetch 的版本即可。也可将当前 fix/photo-startup fast-forward 到统一分支，它是其后代。

**必须在实际用于TD构建的Windows检出目录里运行生成器**。仓库原 .al 的 Project.Path 仍绑定旧绝对目录；生成器不改它，而是产生：

- `out/unified/AC201_AL_board_test.al`：Project.Path绑定当前检出目录，文件列表、器件和约束保持；
- `out/unified/build_full.tcl`：基于仓库既有TD命令，重置syn/phy后完整构建；
- `out/unified/build_phy_only.tcl`：沿用既有phy-only重跑方式；
- `out/unified/source_manifest.json`：实际git提交、工作树状态、输入文件SHA256和预期bit路径。

用TD打开这个**生成的工程副本**构建，或把生成的Tcl送入既有td_commands_prompt。不要把云端生成的Linux绝对路径工程直接复制到Windows使用；应在本地重生成。工程输入均来自统一检出，避免UI打开新工程而实际读取另一个旧目录。

云端没有安路TD，本轮未执行syn/phy、未生成.bit。交付为统一可构建源码和验证证据；本地TD完成后，再按既有MEM时序门禁检查和板测流程使用新产物。生成器显示的expected_bit是路径信息，不表示文件已生成。

