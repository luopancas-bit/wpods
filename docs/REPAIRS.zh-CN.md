# 修复记录与兼容性

更新日期：2026-11-24。

本次提交基于本仓库 `main` 的 WPods **0.4.3**，基线提交为 `b64afdb8bcafeb4fba4c03d75d919cd02e216527`。同一取消读取修复也在上游 **0.4.4**（`2352b1e8de0e8b4af7bd881e288ef0177018d95b`）源码上单独移植、构建和实机测试。本提交不是完整的 0.4.4 升级，也没有发布经过全面验证的新安装包。

## 修复与修改

| 项目 | 状态 | 内容及边界 |
| --- | --- | --- |
| 取消 Windows 读取导致共享蓝牙数据丢失 | 已定位并修复代码路径 | Windows 取消事件或 ACL 读取请求时，不再中止真实控制器的共用读取。已读字节继续进入 HCI/ACL 解析器；取消仍向 Windows 确认。 |
| 普通端点取消及服务关闭 | 保留原行为 | 非共用端点仍可中止；整个服务会话关闭时仍中止物理管道以释放阻塞读取。 |
| 取消读取回归验证 | 新增 | 调用真实 `RadioLink.Unlink`，验证事件、ACL、非共用和排队请求四类情况。测试使用回环 TCP 和替代中止回调，不访问蓝牙硬件。 |
| 输出端点恢复 | 新增手动恢复工具，尚非根因修复 | 耳机音频已连接后刷新 Windows 音频端点服务，在测试机上曾恢复播放，且用户确认有声。重连或服务重启后仍可能再次缺失输出，不能标为彻底修复。 |
| 保留隐藏音频节点的兼容方案 | 未纳入本提交 | 试验中仍无法保证服务重启后生成输出。没有把未通过验证的方案作为已修复功能发布。 |

## 为什么修复取消读取

原版 `RadioLink.Unlink` 在取消运行中的 Windows 请求时调用 `WinUsbDevice.Abort`，包括 WPods 与 Windows 共用的 HCI 事件输入和 ACL 输入。实机诊断曾观察到读取已收到 7 或 16 字节，却同时返回 `ERROR_OPERATION_ABORTED`（995）；原代码进入错误分支丢弃这些字节，随后出现不完整事件和解析错位。

修复将取消限制在 Windows 的请求本身：共享物理读取继续完成并路由数据，`ReadIn` 随后观察取消状态；必要时已取出的 Windows 数据由既有 `PutBack` 路径返还队列。关闭整个会话时仍可中止物理读取。

这修复了已确认的丢包来源，不代表所有断连原因都被排除。

## 设备和版本验证范围

| 维度 | 实际验证 | 未验证或限制 |
| --- | --- | --- |
| 耳机 | AirPods 4 降噪版（ANC），产品 ID `201B` | 其他 AirPods、Beats 型号未在本次修复中实测；耳机固件版本未记录。 |
| 蓝牙适配器 | 设备自报 `CSR8510 A10`，USB `VID_0A12&PID_0001` | 该 USB ID 不能唯一确定实际芯片或真伪，不能推广至所有同 ID 适配器。Intel、Realtek、MediaTek、Broadcom 等其他硬件未实测。 |
| 原生驱动信息 | Windows 显示 `Mediatek Bluetooth Adaptor`，包版本 `2.3.0.0`，其 INF 为此硬件调用 Windows `BthUsb` | 显示名称不能据此证明芯片是 MediaTek，也不能据此判定驱动装错。 |
| 系统 | Windows 24H2 x64，内核构建 `26100.9457` | 其他系统版本，包括 Windows 10、ARM64 和其他 Windows 11 构建，未在本次修复中实测。 |
| WPods | fork 基线 0.4.3；取消读取修复单独移植验证于上游 0.4.4 | 不承诺以后版本可直接套用补丁。 |
| 开发工具 | .NET SDK `10.0.402`；服务 Release 构建及四项回归测试通过 | 完整安装包、更新流程及全量硬件组合没有完成验证。 |

以上是**本次实测范围**，不替代上游原有功能支持列表，也不表示该组合下所有功能已经正常。

## 验证结果

原版取消逻辑下：

```text
FAIL shared event input: physical abort called
FAIL shared ACL input: physical abort called
PASS non-shared running endpoint cancellation
PASS queued request cancellation
```

修复后：

```text
PASS shared event input: no physical abort, cancellation acknowledged
PASS shared ACL input: no physical abort, cancellation acknowledged
PASS non-shared running endpoint cancellation
PASS queued request cancellation
```

一次约 90 秒实机候选验证中，没有再记录不完整事件、取消读取错误或链路断开，麦克风音频持续超过一分钟。之后的服务重启测试仍复现了缺少播放输出端点。因此本提交只将取消读取代码路径列为已修复，长期稳定性及输出枚举仍需继续验证。

在源码根目录运行：

```powershell
dotnet run --project tests/WPods.RepairTests -c Release -p:PublishReadyToRun=false
dotnet publish src/WPods.Service/WPods.Service.csproj -c Release -p:PublishReadyToRun=false
```

测试需要 Windows x64、仓库指定的 .NET SDK，以及本机 TCP 回环通信权限。

## 暂时恢复缺失的输出端点

首先在 Windows 或 WPods 中连接耳机音频，再检查输出列表。如果耳机已连接但播放输出仍缺失，可在**管理员 PowerShell** 中运行：

```powershell
./tools/Recover-AudioEndpoints.ps1
```

此旧工具会短暂中断本机所有音频流，刷新 `AudioEndpointBuilder` 后启动 `Audiosrv`。后续排查发现，重启该服务可能重新载入有问题的蓝牙名称，因此不再推荐将它作为常规恢复或开机任务。

## 提交节奏

按一个主要问题修复并验证后集中提交。实验性改动保留在本地；上传时写明修复内容、修改内容、实测设备和版本、验证结果及已知限制。

## 0.4.4 播放重连修复

故障：AirPods 入盒后重新戴上，WPods 已显示连接，但 Windows 立体声输出可能仍为 Unplugged，或输出已活动却因设备名 @2 读取失败而显示为设备 ID。

- 完整预读 L2CAP 连接响应，保留 pending 请求直到最终响应，跳过重复响应。混合信令拆包后也更新 AVDTP 跟踪。
- 观察到 AVDTP OPEN 请求后才把后续通道登记为媒体通道，减少重连时把新控制通道误记为媒体通道的情况。
- 监听 Windows 播放端点通知，按耳机身份检查立体声输出。端点活动后修复前导 @ 的名称。若持续未插入且耳机仍在线，延迟补发一次音频连接请求；遇到禁用或主动断开则停止。
- 免提状态读取失败时跳过写入，避免在状态未知时修改 Windows 服务关联。

实测环境：Windows x64 24H2（26100 系列），AirPods 4 ANC（201B，名称 @2），CSR8510 A10 USB 蓝牙 4.0（0A12:0001），Windows BTHUSB/BthA2dp，WPods 接管使用 WinUSB 与 usbip-win2。停用免提、低音频延迟、低麦克风延迟三个开关均关闭。

实测版本：基于上游 0.4.4 的 media-trace.8 服务及 playback.10 前台。单耳入盒断链再戴回连续三轮恢复有声，最近一次稳定连接至输出恢复分别约 33、27、7 秒。未重建 Audio Sink。该记录只适用于本机组合；其他硬件、麦克风与立体声同时使用、长期稳定性以及此前蓝屏的根因尚未验收。三轮结果不将所有无声事件归因于单一改动。
