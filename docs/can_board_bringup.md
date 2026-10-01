# CAN-only 首次上板记录（2026-10-01）

## 测试条件

- Kintex-7 `xc7k325t`、Vivado 2020.1，经 JTAG 加载仓库 CAN-only 流生成的 `build/impl_ila/can_ila.bit` 及匹配的 `.ltx`。测试时 RTL 对应 PR #7 的 `7cfef22`；这轮后续只修改主机工具和文档。
- 隔离桌面总线只有 CANable 与标称 SN65HVD230 的 3.3 V 蓝色收发器模块，没有连接车辆或 OBD。两端 CANH 对 CANH、CANL 对 CANL，并接公共地；模块 RX 接 FPGA D13，TX 未连接。FPGA B14 的 `can_tx` 在 RTL 中恒为隐性高电平。
- CANable 使用串口固件、500 kbit/s、关闭自动重发，发送标准数据帧 `t1231A5`（ID `0x123`、DLC 1、数据 `A5`）。
- 蓝色模块上的黄色跨接帽所处两针是 CANH、CANL 引出针；跨接会短路总线。移除后 FPGA 才捕获到 D13 下降沿。模块板上可见 120 Ω 电阻，CANable 的 120 Ω 跳帽已接入，但万用表故障，未量得实际 CANH–CANL 终端阻值。微雪资料也明确提醒[不要短接 CANH 与 CANL](https://www.waveshare.net/wiki/SN65HVD230_CAN_Board)。

## 实测结果

Vivado 报告配置完成，找到一个 ILA。原有 bitstream 对 `debug_frame_valid=1` 触发后，导出的 `build/board_test/board_frame_valid.csv`（本地忽略文件）关键样本为：

| ILA 样本 | `debug_frame_valid` | `debug_crc_ok` | `fifo_valid` | ID | DLC | DATA | 错误 |
| ---: | ---: | ---: | ---: | --- | ---: | --- | ---: |
| 0 | 1 | 1 | 0 | `0x123` | 1 | `0xA5` | 0 |
| 1 | 0 | 0 | 1 | `0x123` | 1 | `0xA5` | 0 |

临时诊断 ILA 还直接观察到 D13 从空闲高电平变低，且 parser 经过 CRC 到 ACK 字段。原有 bitstream 的结果证明一帧 500 kbit/s 标准数据帧已通过接收、校验和 FIFO 路径。仓库跟踪的 RTL 未因本次实测修改。

## 边界与后续

当前只有一帧首测，尚未在实体总线上覆盖扩展帧、RTR、其他 DLC、连续帧、四种速率或长时间误码。FPGA 被动监听不发 ACK；parser 的 ACK slot 接受任一总线值，因此 `frame_valid` 不能单独证明发送端获得 ACK。收发器芯片表面丝印尚未读清，终端阻值及 3.3 V 电压也未用仪表复测。测试结论不适用于车辆总线。

下一步先在隔离总线上补标准/扩展、RTR、DLC 与连续帧定向测试，再进行 GMII→RGMII/RTL8211E 板级引脚、时钟与时序约束工作。实体以太网链路及 FCAN UDP→Linux bridge 尚未验证。
