# ETH1 单向 UDP 与 CAN→UDP 上板记录（2026-10-03）

## 测试连接与范围

Kintex7 BaseC 的 ETH1/J1 接 GL-MT3000 的千兆 LAN 口 `eth1`，路由器的 `br-lan` 地址为 `192.168.8.1/24`、MAC 为 `94:83:c4:2a:eb:74`。隔离桌面 CAN 总线沿用已验证接线：电脑 USB CANable 与 SN65HVD230 的 CANH/CANL/公共地相连，收发器 `RX` 接 FPGA D13、3.3 V 和 GND 接板卡，B14 的 `can_tx` 永久输出 recessive。没有连接车辆或 OBD 总线。

本轮的以太网链路仅实现 **FPGA→路由器单向 1000 Mb/s 发送**。RTL8211E 的 PHY 地址为 1；发送逻辑只在 MDIO 确认 link、自动协商完成、千兆和全双工后启动。PHY 的 `TXDLY` 上拉使 TXC 在 PHY 内部延迟约 2 ns，FPGA 通过 ODDR 同相转发 125 MHz TXC；TXD 低/高半字节分别在上升/下降沿发出，TX_CTL 在下降沿为 `TX_EN XOR TX_ER`。没有以太网 RX、ARP、DHCP 或 CAN 主动发送。

## 固定 UDP 门槛测试

独立顶层 `eth1_fixed_udp_top` 每 100 ms 发送 8 字节载荷：ASCII `FPGA` 加大端 32 位递增序号。测试使用源 `02:00:00:00:00:01` / `192.168.8.250:5000`，目的为上述路由器 MAC / `192.168.8.1:5000`；上板前确认 `.250` 不在路由器 DHCP 租约中。该地址只用于当前隔离测试网。

| 检查 | 结果 |
| --- | --- |
| XSim 固定帧黄金向量 | 两个完整 GMII 帧的 MAC/IP/UDP/填充/FCS、序号与链路门控通过 |
| XSim ODDR UNISIM | TXD/TX_CTL/TXC 双边沿映射通过 |
| Vivado 2020.1 固定顶层实现 | `xc7k325tffg676-2`；布线 WNS +0.282 ns、WHS +0.108 ns；RGMII 输出 setup/hold 最差分别 +0.282/+0.284 ns；DRC 0 |
| JTAG 与路由器 `eth1` 抓包 | 下载成功；`tcpdump` 捕获 20 包，序号 747～766 连续；平均间隔 99.990 ms；IP 头校验和均正确 |
| 路由器 PHY 计数 | `rx_fcs_errors` 在抓包前后均为 0；内核抓包丢包 0 |

原始抓包为 [fixed_udp.pcap](evidence/eth1_udp_20261003/fixed_udp.pcap)，SHA-256 为 `cff33f2ab14e632bbfc6883310dfcca7ece579b2f3d1cce04d8ff823b34c5e77`。复核命令：

```sh
python3 scripts/check_eth1_pcap.py fixed docs/evidence/eth1_udp_20261003/fixed_udp.pcap
```

PHY-ready 50 MHz 寄存器修订后，重新从当前源码实现固定顶层，bitstream SHA-256 为 `cda9b135dcad828512288c5d3ef451e884d5d57f543d2a08de5c882a30ae4ef5`；布线 WNS `+0.282 ns`、WHS `+0.108 ns`、DRC 0。重新 JTAG 下载并在路由器抓取的 [fixed_udp_final.pcap](evidence/eth1_udp_20261003/fixed_udp_final.pcap) 含 10 个序号 760～769 的连续包，平均间隔 99.951 ms，内核丢包 0；独立校验器通过。最终抓包 SHA-256 为 `9a422573f1f20cabb9c9f46305e9db15bc20e1fe2ba01839b4a3f15ed4b7b370`。最终恢复集成配置后再读路由器 `eth1`，`rx_fcs_errors` 仍为 0。

本地最终回归：Vivado XSim 的 31 个顶层全部 PASS，Python 主机单元测试 35 个 PASS。GitHub CI 的便携式 Icarus 回归仍需以 PR 的实际运行结果确认。

抓包由网卡交付给 `tcpdump`，不包含线上 FCS；`rx_fcs_errors=0` 是路由器驱动统计，不能替代示波器检查发送窗口。当前 XDC 对 PHY 内部延迟采用名义 2.0 ns，按 RTL8211E 最低 1.2 ns setup/hold 加每边 0.2 ns 板级偏差建立约束。资料包缺少走线偏差及 PHY 延迟容差实测，因此正的 Vivado slack 只证明该时序模型内通过，并非最终板级时序签核。`check_timing` 仍列出低速管理信号 MDIO 与 PHY 复位未设置外部 I/O delay；RGMII 活动数据的双边沿路径已约束。

## CAN→UDP 测试

`eth1_can_udp_top` 复用上述 ETH1 物理层，把现有 50 MHz 被动 CAN 接收、FCAN v2 打包、50→125 MHz 帧 CDC 与 GMII MAC 接到 RGMII TX。顶层使用固定 `session_id=0x20261003` 便于本次抓包识别；它在复位后不会变化，**不满足生产环境对重启轮次唯一性的要求**。链路断开会清空正在处理的数据，恢复后重新开始。

Vivado 2020.1 对集成顶层完成布线与 bitstream：WNS `+0.282 ns`、WHS `+0.086 ns`、DRC 0。JTAG 下载成功；路由器每秒收到该顶层的 FCAN v2 `DEVICE_STATUS`，说明集成配置中的 PHY、RGMII、MAC、帧 CDC 和状态封装确实工作。测试用 bitstream SHA-256 为 `a4baf4533b7de771caa8fbc59c9e8df3fda993229ffc104f700460a8e9577355`。

完成 CAN-only ILA 诊断后已重新下载这份集成 bitstream；最终[三包状态抓包](evidence/eth1_udp_20261003/fcan_status_final.pcap)经独立校验器通过，末条 `rx_frames_total=0`、`form_errors=0`、`queue_drops=0`，说明重配置后状态计数重新开始。该抓包 SHA-256 为 `22a005743accf619f58329684724c55017e097475704983ab6def6d2422e62bd`。测试结束时 FPGA 保持集成配置。

首次短测 **没有得到 CAN→UDP 成功帧**。在同一隔离总线上，用 CANable COM7 固件 `2022 0726` 配置 `S6/A0/M0/O`，分别发送三次 `t1231A5`（500 kbit/s、标准 ID `0x123`、DLC 1、数据 `A5`）。路由器[原始抓包](evidence/eth1_udp_20261003/can_no_ack.pcap)含 25 个 FCAN 数据报：22 个状态、3 个 `CAN_ERROR code=3`、0 个 `CAN_FRAME`；末条状态的 `rx_frames_total=0`、`form_errors=6`。抓包 SHA-256 为 `44b16579a23224483ed9f9446aa0a739c0634bf97ad6f001b913274ef768e653`。该状态计数包含抓包开始前的尝试，因此不应把 6 次 form error 都归于这三次发送。复核命令预期返回 `[FAIL] expected CAN frame is absent`：

```sh
python3 scripts/check_eth1_pcap.py fcan docs/evidence/eth1_udp_20261003/can_no_ack.pcap --can-id 0x123 --data a5
```

为区分集成 RTL 与物理总线问题，重新下载 2026-10-01 七种帧测试用、bitstream/探针哈希匹配的 CAN-only ILA 配置；其 CAN 接收 RTL 文件哈希仍与当前源码一致。在相同接线下再次发送一帧，ILA 没有触发 `frame_valid`。改为 `debug_error` 触发后的[原始 1024 样本 CSV](evidence/eth1_udp_20261003/can_ack_delimiter_error.csv)显示：CRC delimiter 样本 310 为 `1`，ACK slot 样本 410 为 `1`（没有节点 ACK），ACK delimiter 样本 510 为 `0`；样本 512 的 `debug_error_code=0x03`，parser 正处于恢复状态。CSV SHA-256 为 `47df71ab5b1b2e17cc259cc7c5d459fc3291cafdb1fd5995598e36bba0f66165`。CANable 固件的 `V` 命令只证明命令解析顺序，**不证明物理发送成功或获得 ACK**。

这些位值与“总线没有第二个 ACK 节点，发送控制器检测到 ACK 错误并发出主动错误标志”相符；仅凭现有波形不能排除另一个同时发生的总线错误。[Bosch CAN 2.0 规范](https://tech-tools.com/files/can2spec.pdf)规定 ACK delimiter 为隐性，错误主动节点会发送显性错误标志，而错误被动节点只能发送隐性错误标志。当前 parser 报 form error 是正确行为，不能为使测试变绿而接受这帧。FPGA 继续保持被动监听，B14 不参与 ACK。

随后保持集成 bitstream 和同一桌面接线，单次打开 COM7，关闭自动重发并连续发送 24 次 `t1231A5`：

```powershell
.\scripts\send_canable_once.ps1 -Count 24 -FrameCommand 't1231A5'
```

路由器[原始抓包](evidence/eth1_udp_20261003/can_no_ack_burst24.pcap)含 45 个 FCAN v2 UDP 数据报：21 个 `DEVICE_STATUS`、先后 16 个 `CAN_ERROR code=3`、随后 8 个 `CAN_FRAME`。8 帧全部为标准 ID `0x123`、DLC 1、DATA `A5`、`CRC_OK=True`；按抓包顺序，首个成功帧紧随第 16 个 form error。状态每秒发送一次；最后一条状态在最后三帧之前，因此其 `rx_frames_total=5` 与抓包中的 8 个帧事件不矛盾。路由器报告 0 个内核抓包丢包。PCAP SHA-256 为 `fd600cc1342492641813ef8b53fadf22f650f60c269c661e318f37745ed15d63`。复核命令实际返回 `[PASS]`：

```sh
python3 scripts/check_eth1_pcap.py fcan docs/evidence/eth1_udp_20261003/can_no_ack_burst24.pcap --can-id 0x123 --data a5
```

因此当前 FPGA **CAN 接收→FCAN 封装→ETH1 UDP→路由器抓包** 的实帧路径已经验证。错误记录先出现 16 次、随后出现完整帧，与发送控制器经历 ACK 错误后进入错误被动状态的解释一致：错误被动节点的隐性错误标志可使旁路监听器观察到完整帧。**没有直接读取 CANable 的发送错误计数或状态，不能断言状态切换已被证明；也不能据此声称 CANable 成功发送、获得 ACK。**这与 2026-10-01 CAN-only 七种帧 PASS 并不矛盾，旧 ILA 结果仍证明当时 FPGA 的接收、CRC 和 FIFO 路径完成单帧验证。若要稳定复测并确认发送端也认可该帧，需要在桌面总线上增加一台 500 kbit/s 正常模式、能够 ACK 的控制器；FPGA 继续物理被动监听，新增节点不要使总线出现第三个 120 Ω 终端。

## 250 kbit/s 对照：CANable 未断电复位

使用 `synth_design -generic CAN_BITRATE=250000` 构建同一集成顶层，来源 HEAD 为 `0c6a651`，构建时源码树干净。250 kbit/s bitstream SHA-256 为 `24c528886a6b6d4b5db89aa58ca59c4f7dffdcb592ae2a8049662640e036bac7`；布线 WNS `+0.282 ns`、WHS `+0.055 ns`，DRC 0。Vivado XSim 的 `tb_can_bitrate_250000` 通过；JTAG 下载成功。CANable 从上一轮 500 kbit/s 试验后一直供电，重新打开 COM7 并用 `S5/A0/M0/O` 配置 250 kbit/s，随后发送 24 次 `t1231A5`。

路由器[原始抓包](evidence/eth1_udp_20261003/can_250k_warm_burst24.pcap)有 51 个序号连续的 FCAN v2 UDP 包：27 个状态、24 个 CAN_FRAME、0 个 CAN_ERROR。全部 24 帧均为标准 ID `0x123`、DLC 1、DATA `A5`、`CRC_OK=True`；末条状态计数为 `rx_frames_total=24`、CRC/填充/格式错误及队列丢弃均为 0。路由器报告 0 个内核抓包丢包；PCAP SHA-256 为 `30a174acb2cf42d8417b1fcaf1c24119b7f756d4c204cfd3190227a0888f4311`。

```powershell
.\scripts\run_impl_eth1_udp.ps1 -Top eth1_can_udp_top -CanBitrate 250000 -WorkRoot 'X:\'
.\scripts\run_board_eth1_udp.ps1 -Top eth1_can_udp_top -CanBitrate 250000 -WorkRoot 'X:\'
.\scripts\send_canable_once.ps1 -CanBitrate 250000 -Count 24 -FrameCommand 't1231A5'
```

```sh
python3 scripts/check_eth1_pcap.py fcan docs/evidence/eth1_udp_20261003/can_250k_warm_burst24.pcap --can-id 0x123 --data a5
```

**不能把 500 kbit/s 的 8/24 与这里的 24/24 当成速率导致的可靠率改善。**在两轮之间 CANable 未断电复位，缺少 ACK 时的发送错误状态可能延续；本次没有测量 CANable 的发送错误计数，也没有第二个 ACK 节点。需要从明确的上电初始状态重测，才能比较初始错误行为；要验证稳定、发送端确认的通信仍需第二个正常模式 CAN 节点。

对照结束后重新从同一干净源码 HEAD 构建并下载 500 kbit/s 集成顶层，bitstream SHA-256 为 `318ae10482f51230f005b80105ca62aefda259eef49576449714019a373922c6`；布线 WNS `+0.282 ns`、WHS `+0.086 ns`、DRC 0。JTAG 显示配置完成，软路由 `eth1` 随后连续收到两个每秒一次的 UDP 状态包，抓包内核丢包 0。测试结束时 FPGA 已恢复 500 kbit/s 配置。

## 500 kbit/s 上电初始状态复测

用户将 CANable USB 拔下并重新插入，Windows 重新出现 COM7；FPGA 保持上述 500 kbit/s bitstream。再次以 `S6/A0/M0/O` 配置 CANable，单次打开串口发送 24 次标准帧 `t1231A5`。路由器[原始抓包](evidence/eth1_udp_20261003/can_500k_cold_burst24.pcap)含 49 个序号 877～925 连续的 FCAN v2 UDP 包：25 个状态、**先后 16 个 `CAN_ERROR code=3`、随后 8 个 `CAN_FRAME`**。全部 8 帧为 ID `0x123`、DLC 1、DATA `A5`、`CRC_OK=True`；末条状态为 `rx_frames_total=8`、`form_errors=16`、CRC/填充错误及队列丢弃为 0。路由器内核抓包丢包 0。PCAP SHA-256 为 `c579991ed0872a7b9c01bd51cdf5eeb5ce2a85696f428291f056c16231866aaf`。

```sh
python3 scripts/check_eth1_pcap.py fcan docs/evidence/eth1_udp_20261003/can_500k_cold_burst24.pcap --can-id 0x123 --data a5
```

复测重现了未断电前 500 kbit/s 24 次发送得到 16 条格式错误和 8 条完整帧的顺序；它支持缺少 ACK 后发送控制器错误状态变化的解释，但仍没有直接读到 CANable 的发送错误计数，不能把该状态变化当作实测事实。冷启动 250 kbit/s 比较必须再次给 CANable 断电复位后进行。当前 FPGA 仍运行 500 kbit/s 配置。

## 250 kbit/s 上电初始状态对照

用户再次拔下、重新插入 CANable USB，Windows 重新出现 COM7。FPGA 下载前述已通过时序/DRC、哈希匹配的 250 kbit/s bitstream；CANable 使用 `S5/A0/M0/O`，在同一隔离总线上单次打开串口发送 24 次 `t1231A5`。路由器[原始抓包](evidence/eth1_udp_20261003/can_250k_cold_burst24.pcap)包含 49 个序号 31～79 连续的 FCAN v2 UDP 包：25 个状态、**先后 16 个 `CAN_ERROR code=3`、随后 8 个 `CAN_FRAME`**。8 帧全部为 ID `0x123`、DLC 1、DATA `A5`、`CRC_OK=True`；末条状态的 `rx_frames_total=8`、`form_errors=16`，CRC/填充错误及队列丢弃均为 0。路由器内核抓包丢包 0。PCAP SHA-256 为 `140009ec21f6f3bbb4269fb6f8f66349a4a9ab7cbe8a54a90a1d577fd1a7c8cd`。

```sh
python3 scripts/check_eth1_pcap.py fcan docs/evidence/eth1_udp_20261003/can_250k_cold_burst24.pcap --can-id 0x123 --data a5
```

| CANable 重新插入后的速率 | 单发命令 | 抓包中格式错误 | 随后的 CRC 正确帧 |
| --- | ---: | ---: | ---: |
| 500 kbit/s | 24 | 16 | 8 |
| 250 kbit/s | 24 | 16 | 8 |

两个上电初始状态试验的事件顺序相同；**本测试没有发现把 CAN 速率从 500 降到 250 kbit/s 能消除这 16 次初始格式错误**。先前未给 CANable 断电的 250 kbit/s 24/24 接收结果，不能归因于降速；它与发送器错误状态延续的解释相符。仍未直接读到发送错误计数或 ACK，因此不能把解释当成已证明的内部状态。下一步应在隔离总线上增加一个速率匹配、正常模式且能够 ACK 的节点，验证无初始错误和发送端确认成功。

对照后再次下载哈希匹配的 500 kbit/s bitstream，JTAG 配置成功；软路由连续收到两个每秒一次的 UDP 状态包，内核丢包 0。最终 FPGA 保持 500 kbit/s 集成配置。

## 复现入口

Windows Vivado 2020.1 在本机默认 `AppData` 临时路径下会丢失路径组件；把工作区内的 `build/vivado_stage` 临时映射为未占用的 ASCII 盘符后运行：

```powershell
subst X: 'C:\work\Kintex_BaseC开发板资料\fpga_can\build\vivado_stage'
.\scripts\run_impl_eth1_udp.ps1 -Top eth1_fixed_udp_top -WorkRoot 'X:\'
.\scripts\run_board_eth1_udp.ps1 -Top eth1_fixed_udp_top -WorkRoot 'X:\'
subst X: /D
```

构建脚本记录参与实现的源码 SHA-256、bitstream SHA-256、Git HEAD、脏树状态与时序/DRC 报告；下载脚本重新核对这些哈希。`build/` 中的 bitstream 和完整工具日志不入库。路由器上已安装 `tcpdump`；抓包示例：

```sh
tcpdump -i eth1 -nn -e -vv -XX -c 20 'udp dst port 5000 and src host 192.168.8.250'
```

随后可将两个命令的 `-Top` 改为 `eth1_can_udp_top`，路由器抓 FCAN v2 UDP，再用 `scripts/check_eth1_pcap.py fcan` 和预期 CAN ID/数据复核。JTAG 下载任一新顶层会替换当前 FPGA 配置；测试结束后应按所需功能重新下载相应配置。

时序参考：[AMD PG160 的外部 PHY 延迟及双边沿输出约束](https://docs.amd.com/r/en-US/pg160-gmii-to-rgmii/Constraining-the-Core)、[AMD UG903 的源同步输出约束说明](https://docs.amd.com/r/2022.1-English/ug903-vivado-using-constraints/Output-Delays)。板卡引脚及 TXDLY strap 核对见 [ETH1 板级审计](eth1_board_audit.md)。
