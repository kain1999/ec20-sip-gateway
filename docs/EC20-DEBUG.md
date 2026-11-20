# EC20 调试手册（Ubuntu 20.04 aarch64 落地版）

> 上游教程：[语雀《飞牛NAS 4G模块调试教程》](https://www.yuque.com/yueshangzhuzhonghuo/gk02ap/yidvzn57e05aatew?singleDoc)。
> 本文档是该教程在 Ubuntu 20.04 (aarch64) + 本网关架构下的完整落地版，二者可对照使用。

## 0. 硬件与供电

- EC20（MiniPCIe / USB 转接板）独立供电 **≥2A**，不要从 SBC USB 口取电：
  峰值电流超 USB 口限值会导致随机掉卡（ttyUSB 消失、Asterisk 报 device lost）。
- 天线拧紧，SIM 卡开通语音+短信。EC20 语音走 **CSFB（回落 2G/3G）**，当地需有 2G/3G 覆盖；
  EC20 不支持 VoLTE。
- 语音能力确认：产品页若有《Voice over USB and UAC》或《Voice over UAC》应用说明即可用 UAC 语音。

## 1. USB 枚举与端口映射

```bash
lsusb | grep 2c7c          # EC20/EC25: 2c7c:0125
ls -l /dev/ttyUSB*
```

默认 USB 组合的端口映射：

| 设备 | 接口 | 用途 |
|---|---|---|
| ttyUSB0 | 00 | DM 诊断 |
| ttyUSB1 | 01 | GPS NMEA |
| **ttyUSB2** | **02** | **AT 控制口（chan_quectel 的 `data=`）** |
| ttyUSB3 | 03 | modem/PPP |

本仓库 udev 规则把 AT 口固定为 `/dev/ec20-at`，重启后编号漂移不影响服务：

```bash
sudo cp configs/udev/99-ec20.rules /etc/udev/rules.d/
sudo udevadm control --reload-rules && sudo udevadm trigger
ls -l /dev/ec20-at
```

## 2. AT 口基础操作

```bash
sudo apt install screen
sudo screen /dev/ec20-at 115200     # Ctrl-A K 退出
```

速查表（蜂窝调试 90% 的场景）：

| AT 命令 | 作用 | 期望 |
|---|---|---|
| `ATI` | 模组型号/固件 | `EC20 ...` |
| `AT+CPIN?` | SIM 就绪 | `READY` |
| `AT+CSQ` | 信号（10-31 可用，99=无） | `+CSQ: 20,99` |
| `AT+CREG?` | CS 域注册（语音要 0/1/5） | `+CREG: 0,1` |
| `AT+CEREG?` | PS 域注册 | `0,1/0,5` |
| `AT+COPS?` | 运营商 | 返回名称 |
| `AT+CGATT?` | PS 附着 | `1` |
| `AT+CMGF=1` | 短信文本模式（仅手工测试用） | OK |
| `AT+CMGL="ALL"` | 列出短信 | 内容 |
| `ATD13800138000;` | 外呼 | OK 后 RING/接通 |
| `ATA` | 接听 | OK |
| `AT+CHUP` | 挂断 | OK |
| `AT+CLVL=2?`/`AT+CLVL?` | 听筒音量档 | OK |
| `AT+QAUDMOD=3` | 关 DSP 处理（防杂音/单通） | OK（NVM 保存） |
| `AT+QPCMV=1,2` | 开 UAC 音频输出（chan_quectel 通话时自动下发） | OK |
| `AT+QPCMV=0` | 关闭（挂断复位，本仓库补丁自动做） | OK |

> ModemManager 冲突：Ubuntu 默认的 ModemManager 会抓走 AT 口，导致 chan_quectel
> 报 `device busy`。install.sh 已自动 stop+disable；手工恢复：
> `sudo systemctl stop ModemManager && sudo systemctl disable ModemManager`

## 3. UAC 声卡验证（语音路径）

chan_quectel 的 UAC 模式要求 EC20 以 USB Audio Class 枚举出声卡：

```bash
aplay -l        # 应看到 EC20 声卡，卡名形如 EC20CEHDLG（EC25 可能是 Android）
cat /proc/asound/cards
```

录音 5 秒自测（对它说话，看是否有数据）：

```bash
sudo arecord -D plughw:CARD=<卡名>,DEV=0 -f S16_LE -r 8000 -c 1 -d 5 /tmp/test.wav
sudo aplay    -D plughw:CARD=<卡名>,DEV=0 -f S16_LE -r 8000 -c 1 /tmp/test.wav
```

无声卡时的处理顺序：

1. 确认固件较新（`ATI` 看 revision），老固件先升级（Quectel 官网工具链）；
2. `AT+QPCMV=1,2`（UAC 模式）后重新插拔 USB，看是否枚举；
3. 部分批次需要先 `AT+QPCMV=1,0` 触发一次 USB 重枚举再换 `1,2`；
4. 卡名探不到时 install.sh 会写占位 `plughw:CARD=EC20CEHDLG,DEV=0`，
   按实际卡名改 `/etc/asterisk/quectel.conf` 的 `alsadev=` 后
   `systemctl restart asterisk`。

## 4. 音频质量

- 杂音 / 单通 / 遥远回声：`AT+QAUDMOD=3`（关掉听筒 EC/NS，输出干净 PCM）。
  面板“AT 预备”按钮和开机 `ec20-modem-prep.service` 都会下发该命令。
- 远端听不清：试 `AT+QAUDMOD=0`（保留 DSP 处理）对比。
- 音量：`AT+CLVL=<0..5>`。
- 第二通电话静音：确认补丁已打
  （`grep 'AT+QPCMV=0' /usr/src/chan_quectel/channel.c` 应有挂断分支），
  或手工 `asterisk -rx "quectel cmd ec20 AT+QPCMV=0"` 后再打一通验证。

## 5. 语音链路验收（不装任何东西的最小闭环）

在 Asterisk 侧确认前，先用 AT 口人工跑通蜂窝语音：

1. `ATD13xxxxxxxxx;` 给另一台手机打电话；
2. 对方接听后 `AT+QPCMV=1,2`（或让 chan_quectel 做）；
3. `arecord` 录 5 秒应有对方声音，`aplay` 放音对方应能听到；
4. 任何一步没有声音 → 回到 §3/§4 排 UAC 和 QAUDMOD。

## 6. 数据侧（可选：EC20 做上行）

EC20 同时可作为数据上行（qmi_wwan + quectel-CM / uqmi）。本网关默认不配置
（假设 SBC 有以太网/WiFi 上行）。需要时：

```bash
sudo apt install libqmi-utils
sudo ip link set wwan0 up
sudo qmicli -d /dev/cdc-wdm0 --wds-start-network=--client-cid-execute
sudo qmicli -d /dev/cdc-wdm0 --wds-get-current-settings   # 取 IP/DNS
sudo ip addr add <ip>/30 dev wwan0 && sudo ip route add default via <gw> dev wwan0
```

## 7. 故障速查

| 现象 | 处置 |
|---|---|
| lsusb 无 2c7c | 供电/线/USB 口，换独立供电 |
| ttyUSB 时有时无 | 供电不足或 USB 2.0 兼容，加 powered hub |
| `AT+CPIN?` 返回 SIM PIN | `AT+CPIN=<pin>` 或关闭 SIM PIN |
| CSQ=99 | 天线/信号，换天线位置 |
| CREG=2 | 漫游/未注册，检查 SIM 语音权限 |
| 拨号无回铃 | CSFB 未回落，确认当地 2G/3G，或换运营商 |
| Asterisk 报 device busy | ModemManager 抢口（见 §2 末尾） |
| arecord 无数据 | QPCMV 未开 / 固件不支持 UAC（§3） |
