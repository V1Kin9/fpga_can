# Kintex BaseC ETH1 板级接口核对

本记录核对了随板资料中的原理图、RTL8211E 手册和示例约束，作为 CAN→UDP 上板实现的输入。结论仍属于**资料核对**；尚未下载以太网 bitstream、读取 PHY 寄存器或验证 RJ45 链路。

## 资料与选用接口

- `03Kintex7_Base硬件资料/原理图/Kintex7_BaseC_SCH.pdf`：第 2 页 FPGA Bank 供电、第 4 页 FPGA 引脚、第 10 页两个千兆 PHY 与 RJ45。
- `03Kintex7_Base硬件资料/芯片手册/外围/RTL8211E.PDF`：RTL8211E/RTL8211EG Rev. 1.6；第 18、20、25、28、72～74 页分别说明 RGMII、复位、配置脚、时钟和时序。
- `03Kintex7_Base硬件资料/引脚分配的常用约束文件/eth1_loopback.xdc`：板厂 ETH1 示例引脚。
- `01教程和配套例程/例程工程/DEMO.zip` 中的 `37eth_udp_loopback1`：板厂 RGMII 例程，仅用于交叉核对，不能直接作为本工程的板级时序签核。

先用 **ETH1（U9 RTL8211E-VL、J1 RJ45）**。它与 CAN-only 的 D13/B14 分属不同引脚组；ETH2 可在 ETH1 跑通后复用同一逻辑。原理图显示 ETH1 的 FPGA Bank 34 接 `VCC_1V8`，PHY RGMII/MDIO 域接 `ETH1_1V8`；示例 XDC 对这些信号均采用 `LVCMOS18`。PHY 另有 3.3 V 和 1.0 V 电源，不能因此把 FPGA RGMII 引脚设成 3.3 V。

## ETH1 引脚核对

以下封装引脚在原理图第 4 页与示例 XDC 中一致。测试顶层只约束实际使用的端口；不应直接复制示例中的未使用输入时钟和 LED 约束。

| 信号 | FPGA 封装引脚 | 方向（相对 FPGA） |
| --- | --- | --- |
| `clk_50m` | G22 | 输入，`LVCMOS33` |
| `rst_n` | D26 | 输入，`LVCMOS33` |
| `phy_rstn` | Y2 | 输出，`LVCMOS18` |
| `mdc` / `mdio` | W1 / AF5 | 输出 / 双向，`LVCMOS18` |
| `rgmii_txc` / `rgmii_tx_ctl` | AC2 / Y1 | 输出，`LVCMOS18` |
| `rgmii_txd[0:3]` | AC1 / AB1 / AB4 / Y3 | 输出，`LVCMOS18` |
| `rgmii_rxc` / `rgmii_rx_ctl` | AB2 / AF4 | 输入，`LVCMOS18` |
| `rgmii_rxd[0:3]` | AF3 / AC3 / AE2 / AE1 | 输入，`LVCMOS18` |

原理图第 10 页的 `X2` 是 PHY 自带的 25 MHz 晶体，`CLK125` 脚未连接到 FPGA。1000M RGMII 发送时钟仍须由 FPGA 提供；计划从已用于 CAN 的 50 MHz 板载时钟经 MMCM 生成 125 MHz，并以 MMCM `LOCKED` 控制数据通路复位。PHY 的 `PHYRSTB` 为低有效，RTL8211E 手册 §7.16 要求低电平至少 10 ms，释放后还须等待至少 30 ms 才能首次访问 MDIO 寄存器；下载后由 FPGA 主动保持复位并完成两段计时，不能只依赖板上上拉电阻。

## PHY 配置脚与时钟延时

原理图第 10 页显示两颗 PHY 的以下上拉/下拉；手册规定配置值在上电或硬件复位时采样。实际值仍应由 MDIO 读回和链路测试确认。

| ETH1 配置脚 | 原理图连接 | 手册含义 |
| --- | --- | --- |
| `RXD0/SELRGV` | 4.7 kΩ 上拉到 1.8 V | RTL8211E-VL 使用 1.8 V RGMII |
| `RXD1/TXDLY` | 4.7 kΩ 上拉到 1.8 V | PHY 内部给 TXC 增加约 2 ns 延时 |
| `LED2/RXDLY` | 4.7 kΩ 上拉到 3.3 V | PHY 内部给 RXC 增加约 2 ns 延时 |
| `RXCTL/PHY_AD2`、`LED1/PHY_AD1`、`LED0/PHY_AD0` | 下拉、下拉、上拉 | 预期 PHY 地址 `001`（MDIO 地址 1） |
| `RXD2/AN0`、`RXD3/AN1` | 均上拉 | 预期自动协商全部速率 |

**TXC 只做同相转发。** RGMII 发送数据和 TXC 均应经 FPGA IOB 的 DDR 输出寄存器，数据上升沿发送低半字节、下降沿发送高半字节；`TX_CTL` 上升沿发送 `TX_EN`、下降沿发送 `TX_EN XOR TX_ER`。由于板上 `TXDLY=1`，不要再给 FPGA 的 TXC 加 90° 相移；否则可能叠加两次约 2 ns 的偏移。[AMD 的 7 系列 RGMII 指南](https://docs.amd.com/r/en-US/pg051-tri-mode-eth-mac/Transmitter-Logic-for-7-Series-Using-HR-I/O)给出了在**PHY 不提供延时**时由 FPGA 引入约 2 ns 的另一方案，本板须按已确认的 PHY 配置选择其一。

示例 `eth1_loopback.xdc` 只提供引脚、电平和几个输入时钟，并没有本工程完整的 TX 源同步输出延时约束。正式实现须根据 PHY 手册的 RGMII 建立/保持时间、板级走线偏差和实际输出时钟建立约束，检查布线后的 setup/hold、DRC、`check_timing` 与未约束路径。手册第 74 页给出的内部延时模式下建立/保持时间最小值为 1.2 ns；本资料包尚未发现 ETH1 的 PCB 走线长度/偏差数据，因此不能仅凭示例 XDC 宣称 I/O 时序通过。

## 最小上板验证次序

1. **PHY/时钟检查 bitstream**：只启用 ETH1，50 MHz→125 MHz MMCM，PHY 低有效复位保持至少 10 ms；释放后等待至少 30 ms，再开始 MDIO 扫描并读取 PHY ID、链路状态和协商速率。预期地址 1，实际读回为准。用电脑网口连接 J1，确认 1000 Mb/s 链路。此阶段不接 CAN 数据流。
2. **单向已知帧**：把现有 GMII MAC 输出接到独立的 GMII→RGMII DDR 发送适配层，先周期发送固定 UDP 测试帧。在电脑抓包核对目标 MAC/IP、UDP 长度与载荷、FCS 错误计数，并检查完整实现报告。现有默认目的 MAC `02:00:00:00:00:02` 未必是电脑网卡地址，测试前应显式配置。
3. **CAN→UDP 集成**：最小以太网帧确认后接入 `can_gmii_pipeline_top`，为其 32 位 `session_id` 确定板上生成方式，再对照 CAN 发端、FPGA 诊断和 Linux SocketCAN bridge。连续 CAN 流仍需第二个能够 ACK 的节点。

10/100 Mb/s 的 RGMII 时钟分别不同于 125 MHz；首个测试 bitstream 明确只面向 **1000 Mb/s**，不把低速链路亮灯视为 UDP 路径通过。当前没有实体网线/主机抓包、PHY 寄存器读回或以太网实现报告，以上各项仍是待执行门槛。
