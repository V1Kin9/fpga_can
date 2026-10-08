# FCAN UDP 载荷协议

本文定义 FPGA 与主机之间的 FCAN UDP **载荷**格式。集成顶层默认发送 v2，`FCAN_PROTOCOL_VERSION=1` 可保留既有 v1 发送格式；主机解码器和 SocketCAN bridge 同时接收 v1/v2。ETH1 板级 RGMII 单向发送已实现并通过固定 UDP 实包测试；FCAN 实包测试见 [ETH1 UDP 上板记录](eth1_udp_board_bringup.md)。

所有多字节整数均采用网络字节序（大端）。CAN 的 DATA0 是总线上的第一个数据字节。

## FCAN v1 数据报头（兼容）

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

## FCAN v1 CAN 帧记录

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

## FCAN v2 数据报头

| 偏移 | 字节 | 字段 | 定义 |
| ---: | ---: | --- | --- |
| 0 | 4 | magic | ASCII `FCAN` |
| 4 | 1 | version | `2` |
| 5 | 1 | header length | `20` |
| 6 | 1 | record length | `32` |
| 7 | 1 | record count | 本数据报中的全部类型记录数，默认最多 16 |
| 8 | 4 | sequence | 32 位数据报序号，自然环绕；复位后从零开始 |
| 12 | 4 | session ID | 由顶层 `session_id[31:0]` 提供，打包器只复制它 |
| 16 | 4 | reserved | 零 |

所有多字节字段均为大端。`session_id` 在首条记录进入打包器时锁存并保持到本包发完；系统集成者应在复位后提供新的、稳定的值。当前 RTL **没有**可靠的持久化启动计数或随机源，也不保证默认零值可区分重启。ETH1 板级顶层用不受链路复位影响的 32 位计数器，在每次观测到 link-ready 由高变低时递增 session，保证链路恢复的新轮次不再复用旧 ID；`INITIAL_SESSION` 顶层参数可覆盖初值（默认 `0x20261003`）。**完整 core 复位、掉电或重新配置会恢复该初值，不能保证启动唯一性；计数器环绕也会重用 ID。** 生产集成仍需要真实的外部或持久化启动身份来源，修改常量不能替代它。主机以 v2 的 `session_id` 改变作为新轮次，即使新轮次的序号零包丢失也能识别；若不同启动轮次重用同一值，则仍无法可靠区分。

## FCAN v2 固定记录

每条记录固定 32 字节，通用布局为：byte 0 类型，byte 1 flags/code，byte 2～3 为类型相关字段，byte 4～7 ID/辅助字段，byte 8～15 时间戳，byte 16～31 载荷。类型 `0x00=CAN_FRAME`、`0x01=CAN_ERROR`、`0x02=DEVICE_STATUS`。记录总数计入头部 `record count`；`packet_length=20+32×record_count`。

| 偏移 | 字节 | CAN_FRAME (`0x00`) | CAN_ERROR (`0x01`) | DEVICE_STATUS (`0x02`) |
| ---: | ---: | --- | --- | --- |
| 0 | 1 | 类型 `0` | 类型 `1` | 类型 `2` |
| 1 | 1 | IDE/RTR/CRC_OK flags | parser error code | status flags |
| 2 | 1 | raw DLC | subtype，当前零 | queue level，u8 饱和 |
| 3 | 1 | 保留零 | 保留零 | high watermark，u8 饱和 |
| 4 | 4 | CAN ID，高 3 位零 | auxiliary，当前零 | 保留零 |
| 8 | 8 | SOF 50 MHz tick | 错误事件 50 MHz tick | uptime 50 MHz tick |
| 16 | 8 | DATA0～7 | 保留零 | 前四个大端 u16 计数 |
| 24 | 8 | 保留零 | 保留零 | 后四个大端 u16 计数 |

| 类型 | byte 1 | byte 2 | byte 4～7 | byte 8～15 | byte 16～31 |
| --- | --- | --- | --- | --- | --- |
| CAN_FRAME `0x00` | bit0 IDE、bit1 RTR、bit2 CRC_OK；其余零 | 原始 DLC 0～15 | 29 位 ID，高 3 位零 | SOF，50 MHz tick | byte 16～23 DATA0～7；byte 24～31 零 |
| CAN_ERROR `0x01` | parser error code | subtype，当前零 | auxiliary，当前零 | 事件时间戳，50 MHz tick | 当前全零 |
| DEVICE_STATUS `0x02` | status flags | 队列水位，u8 饱和 | byte 4～7 零 | uptime，50 MHz tick | 8 个大端 u16 饱和计数 |

CAN_FRAME 的 byte 3 为零。DLC 9～15 保留原始值，有效 DATA 长度钳为 8。RTR 不带数据。CAN_ERROR 不代表有效 CAN 帧；parser 错误码 `1=stuff`、`2=CRC`、`3=form`、`5=abort/internal`。诊断记录空间不足时采用明确的丢弃计数，见 [诊断架构](diagnostics.md)。

DEVICE_STATUS 的 byte 2 是当前队列水位，byte 3 是启动以来队列高水位，二者大于 255 时饱和为 `0xff`。byte 1 的 bit0 表示任一 u16 计数达到 `0xffff`，bit1 表示当前队列水位超过 255，bit2 表示高水位超过 255，其余位为零。byte 16～31 依次是 `rx_frames_total`、`crc_errors`、`stuff_errors`、`form_errors`、`queue_drop_count`、`cdc_protocol_error_count`、`mac_underrun_count`、`diagnostic_drop_count`，各占 2 字节。计数到 `0xffff` 后保持不变，复位清零；不发生隐式环绕或截断。`STATUS_INTERVAL_CYCLES=50_000_000` 在 50 MHz 下约为 1 秒，可缩小供仿真使用。状态时间戳是模块 uptime，不是外部 UTC。

| DEVICE_STATUS 偏移 | 字节 | 大端 u16 计数 |
| ---: | ---: | --- |
| 16 | 2 | `rx_frames_total` |
| 18 | 2 | `crc_errors` |
| 20 | 2 | `stuff_errors` |
| 22 | 2 | `form_errors` |
| 24 | 2 | `queue_drop_count` |
| 26 | 2 | `cdc_protocol_error_count` |
| 28 | 2 | `mac_underrun_count` |
| 30 | 2 | `diagnostic_drop_count` |

## RTL 接口

`can_udp_pipeline_top` 的路径为：

```text
CAN RX → 单帧缓冲 → 多帧队列 → FCAN 打包器 → 数据报请求/字节流
```

- `packet_valid / packet_ready`：每个数据报进行一次握手。
- `packet_length`：完整 FCAN UDP 载荷长度。
- `packet_sequence`：当前数据报的序号。
- `tx_valid / tx_ready / tx_data / tx_last`：可反压的 8 位字节流。

打包器序列化数据报时不接收下一帧；上游队列吸收这段间隔。v2 的待发送 CAN_ERROR 使用单槽暂存；该槽已满时，额外错误计入 `diagnostic_drop_count`。状态记录同样暂存，周期到来但前一条未被接收时计入该计数。错误优先于状态，状态优先于 CAN_FRAME。默认网络链路按 1 GbE GMII 设计，但实际吞吐仍须上板验证。

## 主机使用与校验

仅查看 FCAN 内容时运行：

```bash
python3 host/can_udp_decode.py --bind 0.0.0.0 --port 5000
```

`can_udp_decode.py` 校验 magic、版本、头/记录长度、保留位、ID 范围和载荷总长度。`fcan_socketcan_bridge.py` 只把 CRC 正确的 CAN_FRAME 写入 Linux SocketCAN；CAN_ERROR/DEVICE_STATUS 以日志报告。普通 `can_frame.len` 将 DLC 9～15 钳为 8。bridge 拒绝不含记录的空包，避免它改变当前 session；还检测序号间隙、重复、倒序和自然环绕。v2 session ID 改变时保存旧 ID，之后到达的最近 256 个已退休 session 的延迟包会被丢弃。超过窗口的旧 ID 无法无限期识别。非回环 UDP 监听必须配置 `--source-ip`，只接受该来源；这不是身份认证，实包接入应使用可信隔离网络。只有 v1 对非环绕的序号归零保留启发式重启判断，其迟到零号包和丢失重启零号包仍有歧义。v2 只通过 session 改变识别新轮次；同一 session 内的重复、倒序和迟到零号包均丢弃，不回退序号水位。完整重启后若 session 重用，则无法无歧义自动恢复；当前板级实现的可靠恢复范围是一次 core 运行内的链路复位。离线抓包工具见 [诊断架构](diagnostics.md)。

## 验证边界

CI 覆盖队列顺序/反压、打包、字段编码、主机解码、SocketCAN 转换及完整 CAN 波形→GMII 仿真；Vivado 综合和 CDC/DRC 报告由本地脚本生成。CAN-only 500 kbit/s 单帧已通过 [板级实测](can_board_bringup.md)。ETH1 固定 UDP、集成顶层的 FCAN 状态包和 8 个 CRC 正确的 CAN_FRAME 已通过物理抓包，见 [上板记录](eth1_udp_board_bringup.md)。当前无第二个 ACK 节点，发送端成功确认、车辆总线、持续无错 CAN 和 Linux SocketCAN 的实体链路尚未验证。[无板验证记录](pre_board_verification.md)保留之前阶段的快照，不代表当前板级进度。
