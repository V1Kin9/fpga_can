# Ethernet II / IPv4 / UDP 封装

`can_udp_ipv4_eth_pipeline_top` 将 FCAN UDP 载荷封装为 Ethernet II、IPv4 和 UDP 帧，并提供 8 位 MAC 客户端字节流；该模块不依赖实体 FPGA 板卡。完整 GMII 顶层在此基础上连接帧 CDC 和 MAC TX。

## 模块边界

输出字节顺序为：

```text
目的 MAC → 源 MAC → EtherType 0x0800 → IPv4 头 → UDP 头 → FCAN 载荷
```

本层不生成前导码、SFD、最小帧填充、以太网 FCS 或帧间间隔；这些由 `ethernet_mac_tx` 完成。RGMII DDR、PHY 复位和 MDIO 仍属于后续板级工作。最小 FCAN 数据报包含 1 条 24 字节记录，形成 68 字节 IPv4 数据报和 82 字节 MAC 客户端帧，因此当前正常流量不需要以太网最小帧填充；MAC 仍具备填充能力。

## 默认网络参数

这些值是可配置的 RTL 参数。连接实际网络前，需要依据主机网卡和网络环境重新核对。

| 字段 | 默认值 |
| --- | --- |
| FPGA 源 MAC | `02:00:00:00:00:01` |
| PC 目的 MAC | `02:00:00:00:00:02` |
| FPGA 源 IPv4 | `192.168.50.2` |
| PC 目的 IPv4 | `192.168.50.1` |
| UDP 源端口 | `5000` |
| UDP 目的端口 | `5000` |
| IPv4 TTL | `64` |

目的 MAC 目前为静态参数，没有 ARP。

## IPv4 与 UDP 字段

IPv4 头为 version 4、IHL 5，无选项；设置 Don't Fragment，TTL 为 64，协议号为 17（UDP）。Identification 取 FCAN 数据报序号的低 16 位，头校验和由 RTL 计算。源/目的地址由顶层参数给出。

UDP 长度为 `8 + FCAN 载荷长度`。UDP checksum 置零；这在 IPv4 中允许，但不提供额外的 UDP 载荷校验。以太网 FCS 由后级 MAC 计算。

## 握手与反压约定

发送新帧前，上游提供 `packet_valid`、长度和序号，帧构建器以 `packet_ready` 完成握手。此后先输出 Ethernet/IP/UDP 头，再请求 FCAN 字节。字节流使用 `tx_valid / tx_ready / tx_data[7:0] / tx_last`；`tx_valid=1` 且 `tx_ready=0` 时，头和载荷字节都保持稳定。

## 验证

分层回归检查目的/源 MAC、EtherType、IPv4 总长度与 Identification、DF/TTL/协议号、IPv4 头校验和、UDP 端口/长度、零 UDP checksum 和反压时的载荷保持。完整 CAN→GMII 回归进一步逐字节检查从前导码到 FCS 的发送结果。上述仿真不证明板级 RGMII 时序或物理链路；具体边界见 [无板验证记录](pre_board_verification.md)。
