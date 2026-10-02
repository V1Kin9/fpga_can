# CAN-only 上板实测记录（2026-10-01）

## 测试条件

- Kintex-7 `xc7k325t`、Vivado 2020.1，经 JTAG 加载仓库 CAN-only 流生成的 `build/impl_ila/can_ila.bit` 及匹配的 `.ltx`。测试时 RTL 对应 PR #7 的 `7cfef22`；这轮后续只修改主机工具和文档。
- 隔离桌面总线只有 CANable 与标称 SN65HVD230 的 3.3 V 蓝色收发器模块，没有连接车辆或 OBD。两端 CANH 对 CANH、CANL 对 CANL，并接公共地；模块 RX 接 FPGA D13，TX 未连接。FPGA B14 的 `can_tx` 在 RTL 中恒为隐性高电平。
- CANable 使用串口固件、500 kbit/s，发送前配置 `A0`（关闭自动重发），发送标准数据帧 `t1231A5`（ID `0x123`、DLC 1、数据 `A5`）。
- 蓝色模块上的黄色跨接帽所处两针是 CANH、CANL 引出针；跨接会短路总线。移除后 FPGA 才捕获到 D13 下降沿。模块板上可见 120 Ω 电阻，CANable 的 120 Ω 跳帽已接入，但万用表故障，未量得实际 CANH–CANL 终端阻值。微雪资料也明确提醒[不要短接 CANH 与 CANL](https://www.waveshare.net/wiki/SN65HVD230_CAN_Board)。

## 实测结果

Vivado 报告配置完成，找到一个 ILA。原有 bitstream 对 `debug_frame_valid=1` 触发后，导出的 `build/board_test/board_frame_valid.csv`（本地忽略文件）关键样本为：

| ILA 样本 | `debug_frame_valid` | `debug_crc_ok` | `fifo_valid` | ID | DLC | DATA | 错误 |
| ---: | ---: | ---: | ---: | --- | ---: | --- | ---: |
| 0 | 1 | 1 | 0 | `0x123` | 1 | `0xA5` | 0 |
| 1 | 0 | 0 | 1 | `0x123` | 1 | `0xA5` | 0 |

临时诊断 ILA 还直接观察到 D13 从空闲高电平变低，且 parser 经过 CRC 到 ACK 字段。原有 bitstream 的结果证明一帧 500 kbit/s 标准数据帧已通过接收、校验和 FIFO 路径。仓库跟踪的 RTL 未因本次实测修改。

## 当前 `main` 的定向实测

在合并 PR #7 后的 `main` `53345a187af8cbeaa7b9a4b83550b228300b704a` 上重新执行 `scripts/run_impl_ila.ps1`，用新生成的匹配 `.bit`/`.ltx` 配置 `xc7k325t`。Vivado 2020.1 bitgen 成功；[布线后时序](evidence/can_ila_impl_20261001/routed_timing.rpt) WNS `+14.866 ns`、WHS `+0.049 ns`，[四组 bus skew 约束](evidence/can_ila_impl_20261001/routed_bus_skew.rpt)全部满足。[DRC](evidence/can_ila_impl_20261001/routed_drc.rpt) 无 Error，有一项 `RTSTAT-10` Warning，涉及调试核内部 25 条无可布线负载的 net。bitstream 和匹配探针文件保留在本地忽略的 `build/impl_ila/`。

在上述隔离桌面总线，以 CANable COM7 串口固件 `2022 0726`、500 kbit/s、单次发送且关闭自动重发执行：

```powershell
.\scripts\run_board_can_matrix.ps1
```

| 用例 | 标识符 | IDE | RTR | DLC | 接收 DATA（低字节在前） | 结果 |
| --- | --- | ---: | ---: | ---: | --- | --- |
| `std_dlc0` | `0x321` | 0 | 0 | 0 | `0x0000000000000000` | PASS |
| `std_dlc1` | `0x123` | 0 | 0 | 1 | `0x00000000000000A5` | PASS |
| `std_dlc8` | `0x100` | 0 | 0 | 8 | `0x8877665544332211` | PASS |
| `std_stuff` | `0x000` | 0 | 0 | 8 | `0xFFFF0000FFFF0000` | PASS |
| `ext_data` | `0x18DAF110` | 1 | 0 | 2 | `0x000000000000BBAA` | PASS |
| `std_rtr` | `0x456` | 0 | 1 | 4 | `0x0000000000000000` | PASS |
| `ext_rtr` | `0x01ABCDE3` | 1 | 1 | 2 | `0x0000000000000000` | PASS |

每份 1024 样本的原始 ILA CSV 都只有一个 `debug_frame_valid` 脉冲；该样本的 ID、IDE、RTR、DLC、DATA、CRC 均匹配预期，下一样本有且仅有一次 `fifo_valid`。整个捕获窗口均未见 `debug_error` 或 `fifo_overflow`。[首轮汇总](evidence/can_board_matrix_20261001/summary.csv)和[首轮清单](evidence/can_board_matrix_20261001/manifest.json)保留为历史记录。其中 `GitHead` 仅表示执行测试时的源码 HEAD，不能单独证明 bitstream 由该 HEAD 构建。ILA 在 50 MHz 下的 1024 样本只覆盖帧结束附近约 20.48 µs，不能据此声称捕获了整个 CAN 波形。

## PR #8 review 修复后的复测

修复测试脚本后，用相对 `-WorkRoot '.'` 在 ASCII 映射盘 `W:` 重新运行 Vivado 2020.1；CAN-only ILA bitgen 成功。构建时 Git HEAD 为 `ec862713ae8c428718b9e50c69582852ef5f6d69`，来源记录中的 `SourceTreeDirty=false`。布线后[时序](evidence/can_ila_impl_20261001_verified/routed_timing.rpt) WNS `+14.866 ns`、WHS `+0.049 ns`；[四组 bus skew](evidence/can_ila_impl_20261001_verified/routed_bus_skew.rpt) 均满足；[DRC](evidence/can_ila_impl_20261001_verified/routed_drc.rpt) 无 Error，保留调试核内部一项 `RTSTAT-10` Warning。

新脚本在上板前核对源码、约束、实现脚本、bitstream 与探针文件的 SHA-256；将匹配的 `.bit/.ltx` 复制到本次输出目录，Vivado 从该目录配置 FPGA。2026-10-01 对上述七种 500 kbit/s 单次帧全部重新捕获并通过。每份 CSV 仍只有一个 `frame_valid`，CRC、字段与随后一次 FIFO 脉冲均符合预期，捕获窗口中无 `debug_error` 或 `fifo_overflow`。[原始 CSV 与汇总](evidence/can_board_matrix_20261001_verified/summary.csv)、[测试清单](evidence/can_board_matrix_20261001_verified/manifest.json)和[构建来源](evidence/can_board_matrix_20261001_verified/provenance.json)已归档。清单分别记录构建时 HEAD `ec86271`、捕获时 HEAD `c7ee5a5`、bitstream/探针及来源记录哈希；来源记录逐文件列出哈希，避免把捕获时的源码版本误当成 bitstream 来源。

CANable 固件版本 `2022 0726` 对 `C/S6/A0/M0/O` 不返回逐条成功确认。脚本在每条配置命令后查询 `V` 并等待版本响应，确认解析器按顺序处理命令；若收到 BEL、异常响应或超时就中止。`V` 响应不能独立证明前一条命令被接受，关闭自动重发仍依据[该版本固件的 SLCAN 命令实现](https://github.com/normaldotcom/canable2-fw/blob/main/src/slcan.c)和[CAN 初始化实现](https://github.com/normaldotcom/canable2-fw/blob/main/src/can.c)。1024 样本的短窗口也无法排除窗口外重发。

## 边界与后续

已覆盖上述七种单次帧，尚未在实体总线上覆盖原始 DLC 9～15、125/250/1000 kbit/s、连续帧或长时间误码。当前 CANable 串口固件的 [SLCAN 实现](https://github.com/normaldotcom/canable2-fw/blob/main/src/slcan.c)限制 DLC 不超过 8，无法用它直接发出原始 DLC 9～15。FPGA 被动监听不发 ACK；parser 的 ACK slot 接受任一总线值，因此 `frame_valid` 不能证明发送端获得 ACK。当前仅一块主动 CAN 控制器，持续无错误发送还需要第二个能够 ACK 的节点。收发器芯片表面丝印尚未读清，终端阻值及 3.3 V 电压也未用仪表复测。测试结论不适用于车辆总线。

当时的后续计划是在隔离桌面总线增加第二个能够 ACK 的 CAN 控制器，进行连续帧、丢帧统计和多速率实测，并用可用的万用表确认终端电阻。此处 ETH1 相关边界只描述 2026-10-01 的状态；2026-10-03 的更新见下节。

## 2026-10-03 复测补充

ETH1 RGMII 与固定 UDP 已经实测，详见[新上板记录](eth1_udp_board_bringup.md)。但在当前桌面接线上，重新下载上述匹配的 CAN-only ILA 配置并单发 `t1231A5`，未再次得到 `frame_valid`。改以 `debug_error` 触发，观察到 ACK slot 为隐性而 ACK delimiter 为显性，parser 报 form error。集成 ETH1 顶层的路由器抓包也只有状态及 form-error 记录，没有 CAN_FRAME。2026-10-01 的七种帧 PASS 是当时的真实短窗口捕获；它们不保证当前无 ACK 的桌面总线每次都能形成完整帧。后续实帧复测需要增加第二个正常模式、能够 ACK 的 CAN 节点，并保持 FPGA 的物理被动监听。
