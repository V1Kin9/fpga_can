# FCAN UDP 载荷协议

本文定义 FPGA 与主机之间的 FCAN UDP **载荷**格式。`can_udp_pipeline_top` 生成 FCAN；上层 `can_udp_ipv4_eth_pipeline_top` 和 `can_gmii_pipeline_top` 再生成 UDP/IPv4/Ethernet 帧及 GMII 发送信号。板级 RGMII 和 RTL8211E 尚未实现。

所有多字节整数均采用网络字节序（大端）。CAN 的 DATA0 是总线上的第一个数据字节。

## 数据报头

每个 UDP 载荷以 16 字节头部开始。

| 偏移 | 长度（字节） | 字段 | 定义 |
| ---: | ---: | --- | --- |
| 0 | 4 | magic | ASCII `FCAN` |
| 4 | 1 | version | `1` |
| 5 | 1 | header length | `16` |
| 6 | 1 | record length | `24` |
| 7 | 1 | frame count | 本数据报中的 CAN 记录数 |
| 8 | 4 | sequence | 32 位数据报序号，递增并自然环绕 |
| 12 | 4 | reserved | 零 |

默认 `MAX_FRAMES_PER_PACKET=16`。批次未满时，`FLUSH_CYCLES=50000` 会在 50 MHz 时钟下约 1 ms 后触发发送。FPGA 复位后，序号从 0 重新开始；FCAN v1 未定义独立的启动轮次标识。

## CAN 帧记录

每条记录固定为 24 字节。

| 偏移 | 长度（字节） | 字段 | 定义 |
| ---: | ---: | --- | --- |
| 0 | 4 | CAN ID | 低 29 位有效，高 3 位为零；标准帧仅用低 11 位 |
| 4 | 1 | flags | bit0=`IDE`、bit1=`RTR`、bit2=`CRC_OK`；其余位为零 |
| 5 | 1 | raw DLC | Classical CAN 原始 DLC，范围 0～15 |
| 6 | 2 | reserved | 零 |
| 8 | 8 | timestamp | 50 MHz SOF 时间戳，1 tick = 20 ns |
| 16 | 8 | data | DATA0～DATA7；未使用字节为零 |

DLC 9～15 保留原始 4 位值，但 Classical CAN 的有效载荷仍为 8 字节。远程帧保留请求的 DLC，不携带数据。

## RTL 接口

`can_udp_pipeline_top` 的路径为：

```text
CAN RX → 单帧缓冲 → 多帧队列 → FCAN 打包器 → 数据报请求/字节流
```

- `packet_valid / packet_ready`：每个数据报进行一次握手。
- `packet_length`：完整 FCAN UDP 载荷长度。
- `packet_sequence`：当前数据报的序号。
- `tx_valid / tx_ready / tx_data / tx_last`：可反压的 8 位字节流。

打包器序列化数据报时不接收下一帧；上游队列吸收这段间隔。默认网络链路按 1 GbE GMII 设计，但实际吞吐仍须上板验证。

## 主机使用与校验

仅查看 FCAN 内容时运行：

```bash
python3 host/can_udp_decode.py --bind 0.0.0.0 --port 5000
```

`can_udp_decode.py` 校验 magic、版本、头/记录长度、记录保留位和载荷总长度。`fcan_socketcan_bridge.py` 还校验头部保留字节与标准/扩展 ID 范围，并将 CRC 正确的记录写入 Linux SocketCAN；普通 `can_frame.len` 将 DLC 9～15 钳为 8。bridge 检测序号间隙、重复、倒序、`0xffffffff → 0` 环绕及非环绕的序号归零。由于协议没有 epoch ID，如果复位后的首个零序号包丢失，主机无法仅凭后续序号无歧义地区分新轮次和旧包。

## 验证边界

CI 覆盖队列顺序/反压、打包、字段编码、主机解码、SocketCAN 转换及完整 CAN 波形→GMII 仿真；Vivado 综合和 CDC/DRC 报告由本地脚本生成。实际 RGMII、PHY、线缆、车辆总线和主机实包仍需实体板卡。详见 [无板验证记录](pre_board_verification.md)。
