# Kintex-7 被动 CAN 接收与 GMII 发送链

本工程面向 Kintex-7 `XC7K325T-2FFG676C`，实现 Classical CAN 2.0A/2.0B 被动接收、FCAN UDP 封装及 GMII 发送。CAN 速率可在 125/250/500/1000 kbit/s 间用 `CAN_BITRATE` 参数选择，默认 500 kbit/s，采样点维持 80%。集成顶层默认发送 FCAN v2，主机仍支持 v1。CAN TXD 恒为隐性电平；RTL 不生成 ACK、主动 CAN 帧或错误帧。当前没有实体 FPGA，验证边界位于 GMII 与 Linux 主机的 SocketCAN 转换。

```text
CAN 收发器 RXD → CAN RX/Parser → 帧队列 → FCAN v2 + 诊断 → UDP/IPv4/Ethernet II
              → 50/125 MHz 帧 CDC → Ethernet MAC TX → GMII
              → [板级 RGMII / RTL8211E / RJ45：尚未实现]

主机收到 FCAN UDP → Linux SocketCAN bridge → vcan0 → candump/cansniffer
                   ↘ PCAPNG / candump compact log 离线抓包
```

## 当前验证状态

- 既有 16 个 HDL 顶层保留；新增 FCAN v2 字节布局、诊断/CDC、10,000 条帧队列入口随机压力、128 条实际 CAN 总线随机波形和四速率矩阵。完整 CAN→GMII 测试比较 37 帧的全部 GMII 字节、FCS 和 IFG。
- 主机单元测试覆盖双版本解码、session 切换、类型记录、SocketCAN 16 字节转换、PCAPNG 与 compact log 的字节布局；无需真实 vcan。Linux 可选 `scripts/test_vcan_integration.sh` 会在缺少权限时清楚跳过。
- Vivado 2020.1 综合、时序、DRC 和 CDC 报告由 `run_gmii_synth.ps1` 生成。未指定的板级引脚使 DRC 保留告警；综合结果不代表板级时序签核。

各项证据、告警解释和剩余板级工作见 [无实体板卡验证记录](docs/pre_board_verification.md)。

## 目录与文档

| 路径 | 内容 |
| --- | --- |
| `rtl/`、`tb/` | CAN 接收、封装、CDC、MAC TX RTL，以及分层和完整端到端仿真 |
| `constraints/` | CAN-only 板级约束和独立 GMII 无板双时钟约束 |
| `scripts/` | Vivado 2020.1 仿真、综合、CAN-only ILA 实现脚本 |
| `host/` | FCAN v1/v2 解码器、Linux SocketCAN bridge、PCAPNG/compact log 抓包及单元测试 |
| [CAN 接收设计](docs/can_rx_design.md) | 协议、位时序、复位和安全接线 |
| [FCAN 载荷协议](docs/can_udp_protocol.md) | 数据报和记录的字节格式 |
| [诊断与抓包](docs/diagnostics.md) | 错误/状态计数、CDC、时间戳及离线格式 |
| [Ethernet/IPv4/UDP 封装](docs/ethernet_udp_frame.md) | 网络头部、默认地址及握手 |
| [MAC TX 与帧 CDC](docs/mac_tx_cdc.md) | 跨时钟握手、FCS、IFG、GMII |
| [CAN-only ILA 实现记录](docs/ila_impl_result.md) | 历史实现结果及适用范围 |

## 运行验证

在本目录的 PowerShell 中，运行全部 Vivado xsim 顶层和两个独立综合流：

```powershell
.\scripts\run_all.ps1
.\scripts\run_synth.ps1        # can_sniffer_top，CAN-only
.\scripts\run_gmii_synth.ps1   # can_gmii_pipeline_top，无板双时钟
```

脚本默认使用 `C:\Xilinx\Vivado\2020.1\bin`，可用 `-VivadoBin` 指定其他安装目录。Vivado 在临时 ASCII 路径运行；CAN-only 报告写入 `build/synth/`，GMII 报告写入 `build/gmii_synth/`。单独运行完整顶层仿真：

```powershell
.\scripts\run_sim.ps1 -Top tb_can_gmii_pipeline_top
```

Linux/CI 使用 Icarus Verilog 和 Python 标准库运行便携式回归；默认压力测试接收 10,000 条记录，固定 seed 可覆盖：

```bash
bash scripts/run_iverilog.sh
python3 -m unittest discover -s host -p 'test_*.py' -v
SEED=1234 FRAME_COUNT=100000 bash scripts/run_stress.sh
```

不要求 CI 安装 Vivado。`build/` 为本地构建目录，不提交综合报告或 bitstream。

## CAN 专用 ILA 与安全接线

既有 CAN-only 流可创建工程或生成带 ILA 的 bitstream：

```powershell
C:\Xilinx\Vivado\2020.1\bin\vivado.bat -mode batch -source scripts/create_project.tcl
.\scripts\run_impl_ila.ps1
```

ILA 产物位于 `build/impl_ila/can_ila.bit` 和 `can_ila.ltx`。脚本完成综合、调试核插入、布局布线与报告生成；生成 bitstream 不代表已在实体板卡和 CAN 总线上验证。

| 信号 | FPGA 引脚 | 电平 | 作用 |
| --- | --- | --- | --- |
| `clk_50m` | G22 | LVCMOS33 | 板载 50 MHz 时钟 |
| `rst_n` | D26 | LVCMOS33 | 低有效复位 |
| `can_rx` | D13 | LVCMOS33 | CAN 收发器 RXD |
| `can_tx` | B14 | LVCMOS33 | 恒为隐性的 TXD |

D13/B14 与板卡 camera2 接口复用，不能同时启用。FPGA 不可直接连接 CANH/CANL，必须经 CAN 收发器。若采用 TJA1051T/3，需核对 VIO、VCC 与板卡 I/O 电平，并通过硬件将 S 引脚保持在 Silent 模式；上电和 FPGA 未配置期间也应保持总线被动。实体接线以实际板卡和收发器原理图为准。

## 输出格式与主机桥接

`can_rx_top` 的 `frame_valid` 为单个 50 MHz 周期脉冲，仅在帧校验通过时产生。标准帧 ID 使用 `frame_id[10:0]`；扩展帧使用 29 位 ID。DATA0 位于 `frame_data[7:0]`；SOF 时间戳以 20 ns 为单位。Classical CAN 原始 DLC 0～15 均保留，DLC 9～15 的数据长度钳为 8。详细接口见 [CAN 接收设计](docs/can_rx_design.md)。

在 Linux 主机上，可用原生 SocketCAN 将 FCAN UDP 数据写入 vcan，无需 `python-can`：

```bash
sudo modprobe vcan
sudo ip link add dev vcan0 type vcan
sudo ip link set up vcan0
python3 host/fcan_socketcan_bridge.py --bind 0.0.0.0 --port 5000 --interface vcan0
candump vcan0
```

`--verbose` 打印 FPGA 时间戳、数据报序号和原始 DLC。bridge 检测丢包、重复、倒序和序号环绕；v2 通过外部提供的 `session_id` 识别重启，v1 仍使用归零启发式判断。普通 SocketCAN 时间戳由主机内核产生，不能替代 FPGA SOF 时间戳。真实 vcan 可选脚本与离线抓包方式见 [诊断与抓包](docs/diagnostics.md)；尚未在实体以太网链路上贯通。

## 当前不包含

工程不包含 CAN FD、CAN 主动发送、Ethernet RX、ARP、DHCP、RGMII DDR、125 MHz 板级时钟实现、RTL8211E 复位/MDIO 或实体引脚与源同步约束。这些工作须在拿到板卡并核对 PHY、电源、时钟和布线后开展。
