# Kintex BaseC ETH1 板级接口核对

本记录核对了随板资料中的原理图、RTL8211E 手册和示例约束，作为 CAN→UDP 上板实现的输入。2026-10-02 的[独立 ETH1 PHY/MDIO 探测（PR #10）](https://github.com/V1Kin9/fpga_can/pull/10)已下载实板 bitstream 并读回 PHY 寄存器；2026-10-03 J1 与软路由完成千兆全双工协商，并通过固定 UDP 物理抓包，见 [ETH1 UDP 上板记录](eth1_udp_board_bringup.md)。本审计的 PCB 走线偏差和 TXC 延迟容差仍未实测。

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

原理图第 10 页的 `X2` 是 PHY 自带的 25 MHz 晶体，`CLK125` 脚未连接到 FPGA。1000M RGMII 发送时钟仍须由 FPGA 提供；独立 PHY 探测顶层已从 50 MHz 板载时钟经 MMCM 生成 125 MHz，并确认 `LOCKED`，后续数据通路仍须正确处理 MMCM 失锁复位。PHY 的 `PHYRSTB` 为低有效，RTL8211E 手册 §7.16 要求低电平至少 10 ms，释放后还须等待至少 30 ms 才能首次访问 MDIO 寄存器；下载后由 FPGA 主动保持复位并完成两段计时，不能只依赖板上上拉电阻。

## PHY 配置脚与时钟延时

原理图第 10 页显示两颗 PHY 的以下上拉/下拉；手册规定配置值在上电或硬件复位时采样。实板 MDIO 已确认 ETH1 地址为 1、PHY ID 为 `001c:c915`；时钟延时等 strap 功能及链路速率仍须在有活动 RGMII 数据和链路协商时验证。

| ETH1 配置脚 | 原理图连接 | 手册含义 |
| --- | --- | --- |
| `RXD0/SELRGV` | 4.7 kΩ 上拉到 1.8 V | RTL8211E-VL 使用 1.8 V RGMII |
| `RXD1/TXDLY` | 4.7 kΩ 上拉到 1.8 V | PHY 内部给 TXC 增加约 2 ns 延时 |
| `LED2/RXDLY` | 4.7 kΩ 上拉到 3.3 V | PHY 内部给 RXC 增加约 2 ns 延时 |
| `RXCTL/PHY_AD2`、`LED1/PHY_AD1`、`LED0/PHY_AD0` | 下拉、下拉、上拉 | 预期 PHY 地址 `001`（MDIO 地址 1） |
| `RXD2/AN0`、`RXD3/AN1` | 均上拉 | 预期自动协商全部速率 |

**TXC 只做同相转发。** RGMII 发送数据和 TXC 均应经 FPGA IOB 的 DDR 输出寄存器，数据上升沿发送低半字节、下降沿发送高半字节；`TX_CTL` 上升沿发送 `TX_EN`、下降沿发送 `TX_EN XOR TX_ER`。由于板上 `TXDLY=1`，不要再给 FPGA 的 TXC 加 90° 相移；否则可能叠加两次约 2 ns 的偏移。[AMD 的 7 系列 RGMII 指南](https://docs.amd.com/r/en-US/pg051-tri-mode-eth-mac/Transmitter-Logic-for-7-Series-Using-HR-I/O)给出了在**PHY 不提供延时**时由 FPGA 引入约 2 ns 的另一方案，本板须按已确认的 PHY 配置选择其一。

示例 `eth1_loopback.xdc` 只提供引脚、电平和几个输入时钟，没有活动 TX 数据的源同步输出延时约束。本工程的 `kintex7_base_eth1_udp.xdc` 已按 PHY 内部 TXC 名义延时 2.0 ns、手册内部延时模式下最小建立/保持时间 1.2 ns、假定每边 0.2 ns 板级偏差建立模型，完成布线后 setup/hold、DRC 和 `check_timing` 检查。本资料包尚未发现 ETH1 的 PCB 走线长度/偏差数据，也未实测 PHY 延迟容差，因此这些正时序余量只适用于当前模型，不能宣称最终板级时序签核。

## 最小上板验证次序

1. **PHY/时钟检查 bitstream（部分完成）**：独立 ETH1 PHY 探测顶层已在实板确认 MMCM 锁定、PHY 地址 1、PHY ID `001c:c915`、BMCR `1140`、BMSR `7949`；当前 `link_up=0`。PHY 低有效复位须保持至少 10 ms，释放后等待至少 30 ms 才开始 MDIO 访问。仍需用电脑千兆网口或交换机连接 J1，确认链路协商、速率与双工。此阶段不接 CAN 数据流。
2. **单向已知帧**：把现有 GMII MAC 输出接到独立的 GMII→RGMII DDR 发送适配层，先周期发送固定 UDP 测试帧。在电脑抓包核对目标 MAC/IP、UDP 长度与载荷、FCS 错误计数，并检查完整实现报告。现有默认目的 MAC `02:00:00:00:00:02` 未必是电脑网卡地址，测试前应显式配置。
3. **CAN→UDP 集成**：已接入 `can_gmii_pipeline_top`，用固定 `session_id=0x20261003` 完成桌面台架状态包抓取。当前没有第二个 ACK 节点，尚未收到 CAN_FRAME；生产环境还需生成跨重启唯一的 session ID，并用收到的 CAN 帧对照 CAN 发端及 Linux SocketCAN bridge。

10/100 Mb/s 的 RGMII 时钟分别不同于 125 MHz；当前发包 bitstream 只面向 **1000 Mb/s**，不把低速链路亮灯视为 UDP 路径通过。PHY 探测已有实板 MDIO 读回与独立探测顶层实现报告（详见 [PR #10](https://github.com/V1Kin9/fpga_can/pull/10) 的 `docs/eth1_phy_bringup.md`）。固定 UDP 实包与源同步 STA 模型已验证；CAN→UDP、PCB skew 和 PHY 延迟容差的硬件边界见 [后续上板记录](eth1_udp_board_bringup.md)。
