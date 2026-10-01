# ETH1 PHY/MDIO 最小上板验证

本阶段使用 Kintex BaseC 的 ETH1（U9 RTL8211E-VL、J1 RJ45），只验证 FPGA 时钟、PHY 复位、MDIO 寄存器与物理链路。它**不发送以太网帧**，也不驱动 CAN 引脚；既有 CAN-only ILA bitstream 和证据独立保留。引脚、电压与 strap 的资料核对见 [PR #9](https://github.com/V1Kin9/fpga_can/pull/9) 中的 `docs/eth1_board_audit.md`。

## 实现范围

- G22 的 50 MHz 板载时钟经 MMCM 产生 125 MHz，使用 ODDR 在 AC2 输出空闲 RGMII TXC。`TX_CTL=0`、`TXD=0`，PHY 内部 TXDLY strap 已提供时钟延时，此阶段不发送数据。
- D26 外部复位或 MMCM 失锁后，同步释放内部复位；Y2 的 `PHYRSTB` 保持低电平 20 ms。为让 JTAG 在一次性地址扫描前布防 ILA，当前诊断顶层释放 PHY 复位后等待 15 s，再开始扫描。
- MDC 在 W1，频率 1.25 MHz；MDIO 在 AF5。读事务扫描 PHY 地址 1–31 的寄存器 2，跳过 RTL8211E 定义的广播地址 0，再读取寄存器 3、0、1、1、17；之后每 100 ms 重读 1、1、17。每次事务后发送一个高阻态空闲 MDC 周期。BMSR 连读两次以越过 link bit 的锁存低状态。MAC 在 MDC 低电平中段切换 MDIO，保证上升沿附近稳定。
- RTL8211E 手册规定 PHY 数据在 MDC 上升沿后最多 300 ns 有效；板上原始 ILA 波形显示该器件的 TA 和 16 位数据在按下降沿采样时分别落在本读控制器的位槽 46、47–62，比通用 Clause 22 位槽早一位。`PHY_RX_ADVANCE=1` 只用于本板 ETH1 核心；通用读器默认仍使用标准位槽。若更换 PHY 或板卡，应重新抓原始波形确认。
- ILA 记录 MMCM 锁定、125 MHz 域翻转、PHY 复位、扫描结果和寄存器，并以 4096 个 50 MHz 样本观察一帧完整 MDC/MDIO 读波形。上板脚本捕获地址 1 的 ID1 读周期、周期性 BMSR 读周期和一次状态快照。

## 构建与捕获

在仓库根目录的 PowerShell 中：

```powershell
.\scripts\run_sim.ps1 -Top tb_eth1_phy_probe
.\scripts\run_impl_eth1_phy.ps1
.\scripts\run_board_eth1_phy.ps1
```

实现脚本在临时 ASCII 路径运行 Vivado 2020.1，生成 `build/eth1_phy_impl/eth1_phy.bit`、匹配的 `.ltx`、布线报告和 `provenance.json`。上板脚本要求构建时相关源码已提交、当前 HEAD 与源码哈希仍匹配，随后经 JTAG 下载并采集状态及两次原始 MDIO ILA CSV 到 `build/board_test/eth1_phy_*/`。运行后可用 Vivado Hardware Manager 打开同一 `.bit/.ltx` 查看波形。重新下载此 bitstream 会结束原 CAN-only ILA 的运行。

## 判读

无网线也应读到 PHY ID。预期 `found_mask=0x00000002`、`found_addr=1`、`PHYID1=0x001c`；手册给出的 RTL8211E model/revision 对应 `PHYID2=0xc915`，实物修订位可不同。`debug_clk125_toggle` 在 50 MHz ILA 窗口内应反复翻转。

把 J1 接到电脑千兆网口或千兆交换机后，再看链路状态：BMSR bit 2 为 link、bit 5 为自动协商完成；PHYSR（寄存器 17）bit 10 为实时 link、bit 11 为速率/双工已解析、bit 13 为全双工、bits 15:14 中 `10` 为 1000 Mb/s、`01` 为 100 Mb/s、`00` 为 10 Mb/s。两端读数应与电脑网卡报告的速率相符。仅有网口 LED 亮起不足以证明 UDP 发送。

## 验证边界

构建报告检查 50/125 MHz 内部时序、引脚电平和 DRC。MDIO 是由 FPGA 产生 MDC 的低速管理协议；本阶段依据手册时序留出采样裕量并通过实板读回验证，`check_timing` 中 MDIO 输入及 MDIO/MDC/复位等输出未设置与外部捕获时钟对应的 I/O delay。空闲 TXC 是时钟输出，后续有活动 RGMII 数据时须另外加入源同步输出约束、PCB skew 假设及布线后 setup/hold 检查。本阶段不证明 GMII→RGMII、UDP/FCS、CAN→UDP 或主机 SocketCAN 链路。
