# 无实体板卡时的验证边界

本记录对应 `can_gmii_pipeline_top`，目标器件 `xc7k325tffg676-2`，本地工具 Vivado 2020.1。它验证可移植的 CAN→GMII RTL 与 Linux FCAN→SocketCAN 转换；GMII 后的物理以太网链路尚不存在。

## 重跑方法

```powershell
.\scripts\run_all.ps1
.\scripts\run_gmii_synth.ps1
```

```bash
bash scripts/run_iverilog.sh
python3 -m unittest discover -s host -p 'test_*.py' -v
```

GMII 综合报告位于本地忽略目录 `build/gmii_synth/`：`utilization.rpt`、`utilization_hierarchical.rpt`、`timing_summary.rpt`、`check_timing.rpt`、`clock_interaction.rpt`、`drc.rpt`、`cdc.rpt`、`synth_console.log`、`synthesized_gmii.dcp`。脚本保留既有 `can_sniffer_top` 综合与 ILA 流，不将 GMII 的无板约束用于 CAN-only bitstream。

## 已验证

| 项目 | 证据 |
| --- | --- |
| CAN 2.0A/2.0B 接收、标准/扩展/RTR、raw DLC 0～15、CRC-15、位填充和重同步 | 既有 CAN RX 单元与端到端 HDL 回归 |
| 64 位 SOF 时间戳、帧队列、backpressure、FCAN 顺序 | 分层回归和完整 37 帧回归 |
| UDP/IPv4/Ethernet II 字节序与长度、IPv4 checksum | 完整 CAN→GMII golden 字节比较 |
| preamble/SFD、以太网 FCS、96-bit IFG | 独立多项式方向的 FCS 参考、完整 GMII 字节比较、IFG 断言 |
| 50→125 MHz 帧 CDC 功能 | 20 ns/8 ns 独立时钟；32 帧持续输入期间强制网络帧入口 backpressure，检查队列非空和 CDC busy；恢复后无丢失、乱序、重复及字节错误 |
| FCAN host decoder 和 SocketCAN 转换 | 无 vcan 权限的 fake sink 单元测试，含标准/扩展/RTR、DLC 0/8/15、序号丢失/倒序/环绕、无效包 |
| Vivado 网路顶层综合 | 本地 `can_gmii_pipeline_top` 综合生成网表和全部报告，综合引擎 0 error / 0 critical warning；无推导锁存器、无组合环；没有发现 multi-driven net |

完整回归使用现有 CAN bitstream encoder，其中包含标准 ID `0x321`/DLC8/`11 22 33 44 55 66 77 88`、扩展 ID `0x18DAF110`/DLC2/`AA BB`、DLC0、DLC15、RTR，以及 ID `0x100` 开始的 32 帧。比较覆盖前导码到 FCS 的全部 94 字节、包序号、SOF 时间戳、IFG 与错误信号。测试中的 32 帧积压通过仿真控制网络帧接收端构造；它验证缓冲逻辑，不能证明实体链路的流量性能。

## Vivado 2020.1 综合、STA、DRC 与资源

`constraints/gmii_virtual_clocks.xdc` 为两个顶层输入分别指定 20.000 ns / 8.000 ns，声明异步时钟组；`can_rx` 与外部复位输入是异步输入 false path。异步组仅切断不具有确定相位关系的跨域 STA，不能当作 CDC 安全证明。

| 指标 | 本地综合结果 | 解释 |
| --- | ---: | --- |
| 50 MHz 域 setup WNS | +15.038 ns | 仅综合网表估计 |
| 125 MHz 域 setup WNS | +4.488 ns | 仅综合网表估计 |
| hold WHS / 失败端点 | −0.028 ns / 7 | 未布局布线，不能宣称 hold 收敛 |
| Slice LUT | 6,286 / 203,800 (3.08%) | 含异步读帧缓冲的选择逻辑 |
| Slice FF | 18,139 / 407,600 (4.45%) | 主要来自帧队列和完整帧 CDC 缓冲 |
| BRAM / DSP | 0 / 0 | 当前存储未推导成 BRAM |

`can_frame_queue` 占 2,954 LUT / 10,586 FF，其 64×164-bit 存储采用异步读；`eth_frame_cdc_buffer` 占 1,757 LUT / 4,186 FF，其 512×8-bit 双时钟帧存储也采用异步读。Vivado 因这些读端口与当前结构未推导成 BRAM；不为减少数字而改变已验证协议行为。上板前可在功能不变的前提下单独评估同步读/BRAM 重构。

DRC 报告有 **NSTD-1、UCIO-1 两类 Critical Warning** 和 CFGBVS-1 Warning，均由刻意未设置的 34 个 GMII 顶层 I/O 引脚、电平标准和配置电压引起。它们保留在 `drc.rpt` 中，没有降低严重级别，也没有假称 bitstream 可以生成。`check_timing.rpt` 还列出 20 个没有 output delay 的输出；这些是尚未决定的板级 GMII/调试端口时序。当前只能说综合成功和内部 setup 估计为正，不能说 DRC、hold、I/O 或最终时序已签核。

## CDC 人工复核

Vivado `report_cdc -details` 识别请求与应答各两级 `ASYNC_REG`/`SHREG_EXTRACT=NO` 同步器，并将跨域的 `stored_length`/帧数据列为 **119 个 CDC-1 Critical、96 个 CDC-15 Warning**。这些并非通过设置异步组消失的路径；详细起点/终点保存在 `cdc.rpt`。工具无法从组合使用帧数据的网表自动证明 bundled-data 握手，故不能把这些数量解释为“CDC 全绿”。

人工检查的协议不变量：

1. 应用时钟域先完成 `mem[]` 全帧写入和 `stored_length` 锁存，仅在接受正确的末字节时翻转 `req_toggle`。
2. 网络域的 `req_sync1/2` 连续两级采样请求；仅在同步后的请求与 `ack_toggle` 不同时接受帧，并在此后读取 `stored_length` 与 `mem[]`。
3. 单帧传送完才翻转 `ack_toggle`；应用域经 `ack_sync1/2` 观察应答之前不再写下一帧，因此被消费的 bundled data 在整个传送窗口保持稳定。
4. 外部 `rst_n` 异步断言，各域分别同步释放；请求、应答和两个同步链复位为零，启动时无虚假待处理请求。只允许该共同外部复位，不支持单独复位其中一个时钟域。
5. `app_frame_ready` 依赖请求/应答相等，约束最多一帧 outstanding；短帧、过长帧不公布请求而报告协议错误。

这给出 RTL 级握手理由和仿真证据。**尚未证明** 后布线 bundled-data 路径在同步请求到达前稳定，也未做形式化亚稳态/物理 MTBF 分析。上板实现时需要检查同步器布局、跨域数据路径延迟和两域复位时序，不能仅凭当前异步组约束或 `report_cdc` 摘要签核。

## Host SocketCAN ABI 与时间戳

Linux [UAPI `can.h`](https://github.com/torvalds/linux/blob/master/include/uapi/linux/can.h) 定义 16 字节 Classical `struct can_frame`：native-endian 32-bit `can_id`、`len`、三个单字节 pad/reserved/`len8_dlc`、8 字节数据；`data` 位于偏移 8。bridge 显式封装为 `=IBBBB8s` 并由测试检查全部 16 字节。标准/扩展和 RTR 标志分别按 Linux UAPI 置位。raw DLC 9～15 在普通 `len` 字段钳为 8，`len8_dlc` 保持零；原始 DLC 仍在 FCAN 及 verbose 日志中，不依赖可选的 `CAN_CTRLMODE_CC_LEN8_DLC`。RTR 保留请求长度，数据清零。

FPGA SOF 时间戳为 50 MHz 计数，1 tick = 20 ns。普通 SocketCAN 写入不能赋予该帧外部 RX 时间戳；`candump` 所见时间由 Linux/vcan 产生。bridge 可用 `--verbose` 打印原始 `fpga_ts`，不伪造内核时间。实际 vcan/candump 贯通测试需在可用 Linux 主机上执行；本轮只运行 fake sink 测试。

FPGA 复位会让 FCAN sequence 从 0 重启。bridge 将正常的 `0xffffffff → 0` 视为环绕，将非环绕的重新到 0 视为新一轮并记录日志；同一个 0 的重复包仍丢弃。FCAN v1 没有 epoch ID，如果新一轮的首个 0 包恰好丢失，接收方无法仅凭序号可靠地区分后续新包和旧包；后续协议版本应加入 epoch/boot ID。

## 尚未验证与板到手后的次序

- CAN 收发器电气、真实 500 kbit/s 总线、车辆/OBD 捕获以及实体 FPGA 引脚正确性。
- 以太网 125 MHz 时钟来源、RGMII DDR、TXC 相位/PCB skew、RTL8211E strap/MDIO、物理链路和 Wireshark 实包。
- 板级 I/O 电平/位置、输出延迟、place/route、hold 与最终 DRC/STA。

板到手后先核对板卡版本、原理图、收发器与电压；用既有 CAN-only ILA 流在安全隔离的测试总线上核对 RXD。随后确定 125 MHz 时钟及 RTL8211E 的 TXC 延时方案，依据实物添加引脚和源同步时序约束，再实现 RGMII/PHY 层并完成 place/route、CDC、DRC、时序和实包抓取。最后将 FPGA 发出的 FCAN UDP 接入 Linux bridge，用 `candump`/`cansniffer` 对照 FPGA 时间戳与 CAN 发端测试向量。
