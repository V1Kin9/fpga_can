# Vivado 2020.1 ILA 实现记录

2026-09-26 在 Windows 上以 PR #1 的 RTL（315ec90）和本仓库的 ILA 脚本运行。目标器件为 xc7k325tffg676-2，输入时钟约束为 50 MHz。输出保存在本地 `build/impl_ila/`，该构建目录不纳入 Git；可用 `scripts/run_impl_ila.ps1` 重建。

| 检查项 | 实测结果 |
| --- | --- |
| 综合 | 完成；无 Vivado error 或 critical warning |
| 布局布线 | 完成，设计状态 Fully Routed |
| 建立时序 WNS / 失败端点 | +15.789 ns / 0 |
| 保持时序 WHS / 失败端点 | +0.044 ns / 0 |
| Bus skew | 4 个约束均满足；最小裕量 +19.488 ns |
| Routed DRC | 0 error；1 条 RTSTAT-10 warning |
| Bitstream / 探针 | `can_ila.bit`（11,443,724 B）和 `can_ila.ltx`（37,442 B）已生成 |
| ILA 后资源 | 2,087 Slice LUT、3,246 Slice Register、4.5 Block RAM Tile、2 BUFG |

RTSTAT-10 指出 25 个无可布线负载的网络，列出的网络来自 Xilinx ILA 和 Debug Hub 内部。`write_bitstream` 已完成，但这条 warning 仍保留在 `routed_drc.rpt` 中。Vivado 在 timing report 中提示另查 bus skew；独立从 routed checkpoint 执行 `report_bus_skew` 后，4 个约束全部满足。脚本现已将该报告加入常规构建。

当前 Windows 系统未检测到已连接的 Xilinx/JTAG 设备，因此尚未下载 bitstream，也没有在实体 CAN 总线上验证 RXD 电平、收发器 Silent 接线和 500 kbit/s 帧接收。板级验证方法见 `can_rx_design.md` 第 9 节。
