# Classical CAN 接收设计

## 1. 范围与接口

目标为 Kintex-7 XC7K325T-2FFG676C、50 MHz 主时钟、默认 500 kbit/s Classical CAN。can_rx_top 只观察 CAN 收发器 RXD。can_sniffer_top 将 TXD 恒置隐性电平；实体收发器的 Silent 引脚仍需硬件上拉。支持 CAN 2.0A 的 11 位 ID 与 CAN 2.0B 的 29 位 ID、数据帧和远程帧。保留 4 位原始 DLC；DLC 9 至 15 在 Classical CAN 中仍只接收 8 字节有效载荷。

## 2. 数据路径与模块职责

RXD → can_rx_sync → can_bit_timing → can_destuff → can_frame_parser → can_rx_fifo_if。can_crc15 与解析器并行计算校验值。can_rx_top 集成所有逻辑和时间戳，can_sniffer_top 提供板级引脚和供 ILA 探测的 MARK_DEBUG 网络。

can_rx_sync 用两级 ASYNC_REG 触发器降低异步输入亚稳态传播，并检测隐性到显性边沿。can_bit_timing 产生单周期采样脉冲和同步事件。can_destuff 消除 SOF 至 CRC 序列的填充位。can_frame_parser 负责字段、长度、校验、帧边界和错误恢复。can_rx_fifo_if 是单帧 ready/valid 缓冲。

## 3. 位时序

50 MHz / 500 kbit/s = 每位 100 个时钟。每位分成 10 TQ，每 TQ 10 个时钟：Sync 1 TQ、Prop 5 TQ、Phase1 2 TQ、Phase2 2 TQ。采样位于 8 TQ，即 80%。SJW 为 1 TQ。计时从 SOF 显性边沿硬同步开始；帧内隐性到显性边沿触发最多一次、有界的相位调整，调整量不超过 SJW。边沿位于采样点之前（TSEG1）时延长当前位，位于采样点之后（TSEG2）时缩短当前位；正负 phase error 的分类以配置的 sample point 为界，而不是固定半 bit。参数位于 can_bit_timing，可修改但需满足整数分频和各段总和条件，并重跑仿真。

两级输入同步会带来固定的若干时钟延迟；SOF 时间戳记录同步后检测到的边沿，而非模拟引脚的绝对到达时刻。主测试覆盖标称速率及发送端相对 ±0.5% 的位时间偏差。

## 4. 去填充与 CRC

SOF 到 CRC 序列末尾适用动态位填充：连续五个相同的总线位后，下一位必须取反，该填充位不交给解析器。填充位自身记作新一段同值运行的第一位。若 CRC 最后一个有效位导致需填充，后续填充位仍被消耗，然后才处理 CRC delimiter。CRC delimiter、ACK、EOF 和 intermission 不启用填充。

CRC-15 初始化 0，多项式 0x4599，按 CAN 线上 MSB 首先的顺序计算 SOF、仲裁、控制及数据字段；不把填充位和收到的 CRC 序列再次纳入计算。结束 CRC 序列时比较收到的 15 位与计算值。单元测试包含固定向量和 CRC 错帧。

## 5. 帧解析

状态依次包括 SOF、11 位基本 ID、RTR/SRR、IDE、可选 18 位扩展 ID 与扩展 RTR、保留位、DLC、可选数据、CRC 序列、CRC delimiter、ACK slot、ACK delimiter、7 位 EOF、3 位 intermission。标准帧的 ID 位于 frame_id[10:0]；扩展帧为 frame_id[28:0]。远程帧保留 DLC 但不读取数据字段。数据帧的原始 DLC 9 至 15 同样保留在 frame_dlc 中，但数据字段只读取 8 字节。DATA0 存在 frame_data[7:0]，每个字节内按 MSB 首先接收。扩展帧还检查 SRR 必须为隐性。

ACK slot 可以是显性或隐性；被动监听器不负责 ACK。CRC delimiter、ACK delimiter 和 EOF 必须为隐性。解析器在第七个 EOF 位正确采样后产生一个时钟的 frame_valid 和 crc_ok；随后检查 intermission。若 intermission 被破坏，会额外产生形式错误事件，已经发出的帧事件不会撤回。

## 6. 错误与恢复

error_valid 和 frame_error 为单周期事件。error_code：0x01 位填充错误，0x02 CRC 错误，0x03 形式错误，0x05 起始位或内部状态异常。DLC 9 至 15 是合法的 Classical CAN 原始 DLC，不作为接收错误。stuff_error 和 form_error 只在相应事件周期有效。出错帧不产生新的 frame_valid。RECOVER 状态连续观察 11 个隐性采样位后回到 IDLE，以避开错误帧尾和总线恢复过程。该模块仅报告接收错误，不生成主动错误帧。

## 7. 时间戳与输出缓冲

64 位自由运行计数器在 50 MHz 时钟上递增；硬同步 SOF 边沿时锁存 frame_timestamp，单位为 20 ns。第七个 EOF 位产生的帧事件及数据可供同一时钟域逻辑接收。单帧 FIFO 接口保持 fifo_valid 与各字段，直到 fifo_ready 握手。满而无法接收新帧时，fifo_overflow 脉冲指示丢帧。板级顶层目前将 fifo_ready 接为 1，并通过 MARK_DEBUG 保留观测信号；外部 UDP 或其他输出应连接 can_rx_top 的 FIFO 接口，并按最大帧到达速率选择更深缓冲。

## 8. 时钟、复位与引脚

配置 Bank 属性 CFGBVS=VCCO 和 CONFIG_VOLTAGE=3.3 依据板卡原始 XDC 设置。

XDC 指定 G22 50 MHz 时钟、D26 低有效复位、D13 RXD、B14 TXD，I/O 标准为 LVCMOS33。can_rx 通过两级 ASYNC_REG 同步；外部 rst_n 先经过 reset_sync，以异步方式拉低并在 clk_50m 域同步释放。XDC 将这两个外部异步入口从同步时序分析中排除，而内部同步级之间仍由 clk_50m 正常约束。D13/B14 在板卡原设计中兼作 camera2 信号，不能与该相机功能同时使用。将 CANH/CANL 接收发器总线侧，不可直连 FPGA。使用 TJA1051T/3 时，器件 VIO 应为 3.3 V，VCC 为其规定电源；S 脚需在未配置、复位和运行期间均由硬件保持 Silent 电平。接线与供电须按实际收发器版本和开发板原理图复核。

## 9. 验证和上板步骤

运行 scripts/run_all.ps1，检查全部仿真顶层的 PASS（包含 sample-point/TSEG1/TSEG2 重同步回归）；运行 scripts/run_synth.ps1，检查 build/synth 的利用率、时序和 DRC 报告。运行 scripts/run_impl_ila.ps1，检查 build/impl_ila 下的 routed_timing.rpt、routed_drc.rpt、routed_bus_skew.rpt、can_ila.bit 和 can_ila.ltx。该脚本使用非工程模式，将 ILA 插入综合后网表，并完成布局布线。若需图形界面工程，可另用 scripts/create_project.tcl 建立。

ILA 时钟为 clk_50m，采样深度为 1024 个 50 MHz 周期（20.48 微秒）。probe0 至 probe14 依次为 debug_sample_tick、debug_bit、debug_state[4:0]、debug_frame_valid、debug_frame_id[28:0]、debug_frame_ide、debug_frame_rtr、debug_dlc[3:0]、debug_frame_data[63:0]、debug_crc_ok、debug_error、debug_error_code[7:0]、debug_timestamp[31:0]、fifo_valid、fifo_overflow。可先以 debug_frame_valid 上升沿触发检查有效帧的最终字段，再以 debug_error 触发检查错误代码；若要看整帧原始波形，应扩展采样深度，或用外部 CAN 分析仪同步记录，因为默认 ILA 窗口不足以覆盖最长 CAN 帧。

连接总线前先确认 TXD 为隐性且收发器 Silent 已由硬件固定。确认引脚、电源、终端电阻及公共地后，将 D13 接收发器 RXD，以外部工具发送 500 kbit/s 的标准、扩展、远程、DLC 0/8/9/15 和连续帧。加载 can_ila.bit 与匹配的 can_ila.ltx，逐帧比对 ID、IDE、RTR、原始 DLC、数据、CRC/错误事件和时间戳；观察 fifo_overflow。若硬件条件允许，先在隔离的测试总线上进行。

当前自动测试无法替代收发器电气、布线、终端电阻、总线共模及实际上板误码验证。综合报告为综合后估计，最终时序以实现后的报告为准。
