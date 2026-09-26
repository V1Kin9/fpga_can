# Kintex-7 Classical CAN → GMII 接收链

这是一个独立可验证的 Classical CAN 2.0A/2.0B 被动接收工程，目标器件为 XC7K325T-2FFG676C。输入为 50 MHz 时钟和收发器 RXD，默认 CAN 比特率为 500 kbit/s。RTL 不包含 CAN 主动发送、ACK 或错误帧驱动逻辑，板级输出 TXD 恒为隐性电平。

```text
CAN PHY → CAN RX → Parser → Frame Queue → FCAN → UDP → IPv4
        → Ethernet II → 50/125 MHz Frame CDC → Ethernet MAC TX → GMII
        → [板级 RGMII/RTL8211E：尚未实现] → RJ45 → PC
        → FCAN SocketCAN bridge → vcan0 → candump / cansniffer
```

当前没有实体 FPGA；GMII 是已验证的 RTL 边界，未生成以太网物理链路。验证结果与板级剩余事项见 [无板验证记录](docs/pre_board_verification.md)。

## 目录

- rtl：CAN 接收、FCAN/UDP/IP/Ethernet 封装、跨时钟帧缓冲及 GMII MAC TX。
- tb：分层测试与完整 CAN 波形到 GMII 字节流回归。
- constraints：既有 CAN-only 板级约束和独立 GMII 综合用双时钟约束。
- scripts：Vivado 2020.1 仿真、CAN-only ILA 和完整 GMII 综合入口。
- host：FCAN 解码器、Linux SocketCAN bridge 与无需 vcan 的单元测试。
- docs/can_rx_design.md：设计与板级验证说明。

## 快速验证

在本目录的 PowerShell 中执行：

    .\scripts\run_all.ps1
    .\scripts\run_synth.ps1

Linux/CI 也可使用 Icarus Verilog 运行同一组 RTL 回归：

    bash scripts/run_iverilog.sh

这些 PowerShell 脚本默认使用 C:\Xilinx\Vivado\2020.1\bin，可通过 -VivadoBin 指定其他版本。脚本在系统临时目录建立纯 ASCII 路径执行 Vivado，并将综合报告保存到 build/synth。单独运行主测试：

    .\scripts\run_sim.ps1 -Top tb_can_rx_top

可使用 Vivado 批处理创建可继续实现的工程：

    C:\Xilinx\Vivado\2020.1\bin\vivado.bat -mode batch -source scripts/create_project.tcl

生成带 ILA 的板级 bitstream 与探针文件：

    .\scripts\run_impl_ila.ps1

脚本按 synth → debug core insertion → opt/place/route → DRC/timing/bus skew → bitstream 执行，产物在 build/impl_ila/can_ila.bit 和 build/impl_ila/can_ila.ltx；同时保留报告和 routed_ila.dcp。ILA 使用 50 MHz 时钟、1024 点深度，探针字段及触发建议见 docs/can_rx_design.md。bitstream 用于上板验证，生成成功不代表实际 CAN 收发器及总线已经验证。

## 板级连接

| 信号 | FPGA 引脚 | 电平 | 作用 |
| --- | --- | --- | --- |
| clk_50m | G22 | LVCMOS33 | 板载 50 MHz 时钟 |
| rst_n | D26 | LVCMOS33 | 低有效复位 |
| can_rx | D13 | LVCMOS33 | 收发器 RXD |
| can_tx | B14 | LVCMOS33 | 恒为 1 的 TXD |

D13 和 B14 也是板卡 camera2 接口引脚，CAN 接线时不能同时使用 camera2 功能。FPGA 不应直接接 CANH/CANL，必须使用 CAN 收发器。若使用 TJA1051T/3，VIO 应匹配 FPGA 3.3 V I/O，VCC 按器件要求供电，S 引脚应由硬件上拉到 Silent 模式，保证上电及 FPGA 配置前均不会主动驱动总线。请先核对所用收发器型号和板卡电气连接。

## 输出约定

can_rx_top 的 frame_valid 是单个 50 MHz 时钟周期脉冲，只在帧校验通过时发出。frame_id 为 29 位，标准帧使用低 11 位；frame_ide 和 frame_rtr 分别表明扩展帧和远程帧。frame_data[7:0] 为 DATA0，frame_data[15:8] 为 DATA1，以此类推，未使用字节为 0。frame_timestamp 是检测 SOF 边沿时锁存的自由运行 50 MHz 计数值，单位 20 ns。

fifo_valid/fifo_ready 是深度 1 的 ready/valid 缓冲接口；fifo_valid 为 1 时输出保持，握手后弹出。缓冲满而又收到新帧时 fifo_overflow 脉冲指示丢帧。error_valid 与 error_code 对应接收错误，详见设计说明。

## 范围

CAN 接收核心支持标准/扩展数据帧及远程帧、Classical CAN 原始 DLC 0 至 15（DLC 9 至 15 保留原值但有效载荷按 8 字节接收）、位填充、CRC-15、ACK/EOF 形式检查、错误后总线空闲恢复和连续帧。独立 can_rx_top 只有单帧缓冲；仓库的后续集成层已增加多帧队列、FCAN/UDP 封装和 GMII 发送。当前仍没有 CAN FD、CAN 主动发送、CAN 错误帧驱动或物理板卡联调。

## CAN-over-UDP payload layer

The repository also contains a hardware-independent transport layer for the next stage:

- `can_frame_queue`: configurable multi-frame ready/valid queue (default integration depth 64).
- `can_udp_payload_packetizer`: batches CAN records into the versioned `FCAN` UDP payload format.
- `can_udp_pipeline_top`: passive CAN RX → queue → UDP payload request/byte stream.
- `host/can_udp_decode.py`: PC-side decoder/listener for the same byte contract.

This module exposes the UDP **payload** boundary. The repository also integrates Ethernet/IPv4/UDP framing and GMII TX above it. RGMII DDR I/O and RTL8211E PHY bring-up remain board work. See `docs/can_udp_protocol.md`.

Host-side format tests can be run with:

    python -m unittest discover -s host -p 'test_*.py' -v


## Ethernet / IPv4 / UDP framing

The hardware-independent network layer now also includes `udp_ipv4_eth_frame_builder` and `can_udp_ipv4_eth_pipeline_top`. They wrap an FCAN payload in Ethernet II + IPv4 + UDP and expose a byte-stream MAC-client interface.

This layer calculates the IPv4 header checksum and uses a legal zero UDP checksum for IPv4. The following GMII TX stage supplies preamble/SFD, FCS and IFG. RGMII DDR signaling, MDIO and RTL8211E PHY bring-up remain board-level work.

See `docs/ethernet_udp_frame.md`.


## GMII transmit boundary

The hardware-independent transmit path now continues through a complete-frame 50→125 MHz CDC buffer and an Ethernet MAC TX block. The MAC adds preamble/SFD, Ethernet padding, IEEE CRC32/FCS and the 96-bit inter-frame gap, then exposes GMII TX bytes/control.

`can_gmii_pipeline_top` is the highest portable integration top. Its default CDC capacity is at least the maximum frame produced by `MAX_FRAMES_PER_PACKET`; explicitly overridden capacities must accommodate 58 + 24 × `MAX_FRAMES_PER_PACKET` bytes. RGMII DDR I/O, 125 MHz clock generation/phase, RTL8211E reset/MDIO and board timing constraints remain physical-board integration work.

See `docs/mac_tx_cdc.md`.

## 完整 GMII 验证

运行完整 CAN 波形到 GMII 字节流回归：

    .\scripts\run_sim.ps1 -Top tb_can_gmii_pipeline_top

运行 Vivado 2020.1 无板综合，报告保存在 `build/gmii_synth`：

    .\scripts\run_gmii_synth.ps1

该流程约束 20 ns 和 8 ns 双输入时钟并检查内部时序、详细 CDC、DRC 与资源；未提供 GMII 引脚或输出延迟，因此不能代替板级时序收敛。已有 CAN-only ILA 流保持独立。

## Linux FCAN → SocketCAN

在 Linux 主机上创建测试接口并启动原生 SocketCAN bridge（无需 `python-can`）：

```bash
sudo modprobe vcan
sudo ip link add dev vcan0 type vcan
sudo ip link set up vcan0
python3 host/fcan_socketcan_bridge.py --bind 0.0.0.0 --port 5000 --interface vcan0
candump vcan0
```

`--verbose` 打印 FCAN 序号、FPGA 50 MHz 时间戳和原始 DLC。bridge 识别 UDP 丢包、重复和倒序；普通 SocketCAN 时间戳由主机内核产生，不能代表 FPGA SOF 时间。DLC 9～15 在 `can_frame.len` 中钳为 8，原始值仍存在 FCAN 和日志中。测试无需 vcan：

```bash
python3 -m unittest discover -s host -p 'test_*.py' -v
```
