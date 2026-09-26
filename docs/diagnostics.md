# FCAN 诊断与离线抓包

## RTL 计数与事件

FCAN v2 每 `STATUS_INTERVAL_CYCLES` 个 50 MHz 周期排入一条 DEVICE_STATUS，默认 50,000,000（约 1 秒）。八个 u16 计数按 [FCAN 协议](can_udp_protocol.md)固定次序编码，达到 65,535 后饱和；外部复位清零。`rx_frames_total` 在 parser 宣告通过校验时增加；`queue_drop_count` 在接收单帧缓冲因下游背压而溢出时增加。因此二者之差不能直接代替主机收包数，还要考虑正在队列、打包器和以太网 CDC 中的帧及网络丢包。

| 计数/字段 | 事件与时钟域 | 约束 |
| --- | --- | --- |
| `rx_frames_total` | 有效 CAN 帧，50 MHz | 包含随后可能因队列满而丢弃的帧 |
| `crc_errors`、`stuff_errors`、`form_errors` | parser `error_valid/error_code`，50 MHz | 错误帧不产生 CAN_FRAME |
| `queue_drop_count` | `rx_fifo_overflow`，50 MHz | 溢出是显式丢弃；主机应报警 |
| `cdc_protocol_error_count` | `eth_frame_cdc_buffer.app_protocol_error`，50 MHz | 帧长度不符、零长或超容量 |
| `mac_underrun_count` | MAC 本地 125 MHz 先饱和计数，再 Gray 码双触发器同步至 50 MHz | 状态快照可滞后数个时钟周期；多次事件不因采样稀疏而漏计 |
| `diagnostic_drop_count` | CAN_ERROR 单槽已满或上一条状态记录未被接收而新周期到来，50 MHz | 同周期两种丢弃分别计数，达到 u16 上限后饱和 |
| queue level / high watermark | 50 MHz 帧队列水位 | 状态中为 u8 饱和，高水位复位清零 |

MAC 计数器在源域每次收到 `mac_underrun_error` 加一并编码 Gray；目的域同步 Gray 值后解码，避免把 125 MHz 脉冲直接送到 50 MHz。该路径仍需在实体板卡布局布线后检查同步器布置和 MTBF。跨域的 Ethernet 帧缓存仍使用已审查的 bundled-data request/ack 握手；验证层增加了未应答时不得覆盖帧/长度、请求与应答唯一性及队列上界检查。共同外部复位必须同时复位两个时钟域；单独复位一个域不受支持。

CAN_ERROR 先暂存在一个待发送槽，再由打包器取走。持续背压期间的其他错误会增加 `diagnostic_drop_count`，因此状态计数能表明事件记录并不完整。状态记录也可能被合并：若前一条仍待发，新的周期事件只增加丢弃计数。v1 输出保持原格式，不能承载这些诊断记录；诊断监视应使用 v2。

## 抓包工具

```bash
python3 host/fcan_capture.py --bind 0.0.0.0 --port 5000 \
  --pcap capture.pcapng --log capture.log --interface can0
```

`--pcap` 与 `--log` 可分别启用。PCAPNG 写入 `LINKTYPE_CAN_SOCKETCAN=227` 的 16 字节 Classical CAN 帧：ID/IDE/RTR 为网络字节序，长度和 DATA 与 SocketCAN 帧兼容；CAN_ERROR/DEVICE_STATUS 不伪装成 CAN 帧，而是写入日志中的 `#` 诊断行及标准错误输出。`capture.log` 使用 can-utils compact log 的 `(秒.微秒) can0 ID#DATA` / `ID#R长度` 形式，扩展 ID 使用 8 位十六进制，标准 ID 使用 3 位。raw DLC 9～15 的数据帧使用 can-utils `_9`～`_F` 后缀。该日志中的秒数是 **FPGA 复位后的相对时间**，不是 Unix 时间。

SOF tick 乘以 20 ns 是测量依据。PCAPNG 的 EPB 时间字段需要 Unix epoch；工具只在每个 session 的首帧用主机 UDP 到达时间建立绝对时间锚点，之后的帧间隔全部从 FPGA tick 推导。每个 EPB 的 comment 同时保存原始 `fpga_sof_ticks`、`host_arrival_ns` 和 session ID。网络延迟使绝对时间锚点存在偏差，不能把 PCAPNG 的绝对时间当成同步 UTC 的 CAN SOF。v1 时间戳回退或 v2 session 改变时重新建立锚点。PCAPNG 使用纳秒分辨率 `if_tsresol=9`，可无损表示 20 ns tick。ASC 未实现；在确认目标工具链格式前不生成猜测性文件。

抓包格式依据：[libpcap 的 LINKTYPE_CAN_SOCKETCAN 定义](https://github.com/the-tcpdump-group/libpcap/blob/master/pcap-common.c)、[Wireshark SocketCAN dissector](https://github.com/wireshark/wireshark/blob/master/epan/dissectors/packet-socketcan.c)、[IETF pcapng 的 IDB/EPB/时间分辨率定义](https://datatracker.ietf.org/doc/draft-ietf-opsawg-pcapng/03/)、[can-utils compact frame 语法](https://github.com/linux-can/can-utils/blob/master/lib.h)。本地单元测试解析每个 PCAPNG block，并验证两帧的 ID、IDE、RTR、DATA 与 20 ns 时间差；尚无实体链路上的 Wireshark 人工打开记录。

## 真实 vcan 可选集成

```bash
bash scripts/test_vcan_integration.sh
```

脚本创建临时 vcan 接口，启动 bridge，注入 FCAN v2 UDP 并从原生 SocketCAN socket 验证 16 字节帧，结束后清理接口。缺少 Linux、`ip`、SocketCAN、vcan 模块或 `CAP_NET_ADMIN` 时输出 `[SKIP]` 并以成功状态退出。CI 不要求 root；普通主机单元测试继续使用 fake sink。
