# Kintex-7 Classical CAN 接收器

这是一个独立可验证的 Classical CAN 2.0A/2.0B 被动接收工程，目标器件为 XC7K325T-2FFG676C。输入为 50 MHz 时钟和收发器 RXD，默认 CAN 比特率为 500 kbit/s。RTL 不包含发送、ACK 或错误帧驱动逻辑，板级输出 TXD 恒为隐性电平。

## 目录

- rtl：同步、位时序、去填充、帧解析、CRC-15、单帧 ready/valid 缓冲及板级顶层。
- tb：独立单元仿真与端到端帧激励。
- constraints：Kintex7_BaseC 引脚与 50 MHz 时钟约束。
- scripts：Vivado 2020.1 仿真、综合和工程创建入口。
- docs/can_rx_design.md：设计与板级验证说明。

## 快速验证

在本目录的 PowerShell 中执行：

    .\scripts\run_all.ps1
    .\scripts\run_synth.ps1

两个脚本默认使用 C:\Xilinx\Vivado\2020.1\bin，可通过 -VivadoBin 指定其他版本。脚本在系统临时目录建立纯 ASCII 路径执行 Vivado，并将综合报告保存到 build/synth。单独运行主测试：

    .\scripts\run_sim.ps1 -Top tb_can_rx_top

可使用 Vivado 批处理创建可继续实现的工程：

    C:\Xilinx\Vivado\2020.1\bin\vivado.bat -mode batch -source scripts/create_project.tcl

建议在 Vivado 工程中运行 implementation、检查时序和 DRC 后生成 bitstream。无实体开发板和外部 CAN 收发器连接时，仿真及综合不能证明板上电气行为。

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

支持标准/扩展数据帧及远程帧、DLC 0 至 8、位填充、CRC-15、ACK/EOF 形式检查、错误后总线空闲恢复和连续帧。当前没有物理板卡联调、CAN FD、发送器、错误帧驱动或多帧存储。后续接 UDP 等输出通道时，可在 fifo_ready/fifo_valid 接口后扩展队列和编码层。
