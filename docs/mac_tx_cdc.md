# Ethernet MAC TX 与跨时钟边界

便携式顶层 `can_gmii_pipeline_top` 将 50 MHz CAN/网络应用域的完整帧交给 125 MHz GMII 发送域，不依赖实体板卡的 RGMII 或 PHY。

## 数据路径

```text
50 MHz 应用域
CAN RX → 帧队列 → FCAN 打包 → Ethernet II/IPv4/UDP 帧构建
                                        ↓
                              eth_frame_cdc_buffer
                              请求/应答翻转握手
                                        ↓
125 MHz GMII 域               ethernet_mac_tx
                              GMII TXD[7:0] / TX_EN / TX_ER
                                        ↓
                              [板级 RGMII 数据：尚未实现；PHY 探测独立进行]
```

## 完整帧 CDC 缓冲

`eth_frame_cdc_buffer` 一次只容纳一帧 MAC 客户端数据。应用域先握手长度、写完全部字节，再翻转 `req_toggle`。网络域通过 `req_sync1/2` 两级同步器观察请求，然后读取保持稳定的长度和帧内容。整帧消费完成后，网络域翻转 `ack_toggle`；应用域通过 `ack_sync1/2` 两级同步器收到应答，才允许覆盖存储。

帧存储 `mem[]` 与 `stored_length` 不逐位同步，而遵循 bundled-data 约定：数据先于请求发布，且在应答返回前保持不变。两条翻转同步链均标有 `ASYNC_REG` 和 `SHREG_EXTRACT=NO`。两个时钟域使用共同的外部低有效复位，异步断言、各域同步释放；不支持仅复位其中一个域。

实际字节数与声明长度不符时，缓冲区丢弃该帧并产生一个 `app_protocol_error` 脉冲。超长帧或超出容量的非零长度帧会继续接收直至 `app_tx_last`，丢弃其字节后恢复接受下一帧；零长度帧在首个握手处拒绝。若上游始终不发送非零帧的 `app_tx_last`，仍需系统复位或外部中止策略。

默认容量至少为 512 字节，并随 `MAX_FRAMES_PER_PACKET` 增长。集成帧的最大长度为 `58 + 24 × MAX_FRAMES_PER_PACKET` 字节；若显式设置的 `MAX_ETH_FRAME_BYTES` 小于所需值，超长数据报会被丢弃并报告错误。

综合阶段的 `report_cdc -details` 无法自动证明 bundled-data 握手，将部分数据路径列为 CDC-1/CDC-15。异步时钟组约束也不能代替检查。握手不变量、告警数量及尚需后布线确认的路径见 [无板验证记录](pre_board_verification.md)。

## MAC TX

`ethernet_mac_tx` 从完整帧缓冲区取字节，以 125 MHz 时钟每周期发送一个 GMII 字节，并生成：

- 7 字节前导码 `55 55 55 55 55 55 55` 和 SFD `D5`；
- MAC 客户端帧及不足 60 字节时的零填充；
- IEEE 802.3 CRC32/FCS；
- 12 字节时间（96 bit）的帧间间隔。

CRC 使用反射多项式 `0xEDB88320`，初始值 `0xFFFFFFFF`，最终取反；FCS 按低字节先发。以太网帧一旦启动，MAC 无法暂停。如果数据阶段上游未提供字节，`gmii_tx_er` 和 `mac_underrun_error` 会标记无效发送。

## GMII 接口与后续板级工作

顶层输入为 `gmii_clk_125m`，输出为 `gmii_txd[7:0]`、`gmii_tx_en` 和 `gmii_tx_er`。此便携式顶层仍需外部 125 MHz 时钟。独立的 [ETH1 PHY 探测顶层](eth1_phy_bringup.md)已从板载 50 MHz 生成 125 MHz，不能直接视为 CAN→GMII 与 PHY 已集成。

下一阶段在已核对的 ETH1 引脚与 PHY 延时配置基础上，加入 GMII→RGMII DDR 数据层和源同步时序约束，完成布局布线、CDC/DRC/STA 和 PC 端抓包。当前便携式顶层的仿真、综合及主机桥接不等同于物理 Ethernet 实包验证。
