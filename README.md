# ec20-sip-gateway

**Kamailio + 裁剪版 Asterisk + 移远 EC20**：在 Ubuntu 20.04 (aarch64, 运存 ≤ 500MB) 上搭建的低内存 SIP 网关。蜂窝来电经 SIP 分机接听，蜂窝短信自动推送到钉钉机器人 / 邮箱，并附带轻量网页管理面板。

[![Platform](https://img.shields.io/badge/platform-ubuntu%2020.04%20aarch64-blue)](#系统要求) [![RAM](https://img.shields.io/badge/RAM-%E2%89%A4500MB-green)](#内存预算) [![License: MIT](https://img.shields.io/badge/license-MIT-orange)](LICENSE)

---

## 架构

```
                    ┌─────────────────────────────────────────────────────┐
                    │                 Ubuntu 20.04 aarch64 (≤500MB)       │
                    │                                                     │
 软电话(手机/PC)      │  ┌──────────────┐   INVITE/MESSAGE   ┌───────────┐  │
 (Linphone/Zoiper)──┼──▶  Kamailio     ├───────────────────▶  Asterisk   │  │
        ▲           │  │  :5060       │    127.0.0.1:5062  │  裁剪版    │  │
        │  SIP注册   │  │  注册/鉴权/路由 │◀───────────────────┤  +PJSIP   │  │
        └───────────┼──│  location表   │   蜂窝来电转分机     │  仅网关职责 │  │
                    │  └──────────────┘                    └─────┬─────┘  │
                    │        ▲                                  │        │
                    │        │ 分机互打：Kamailio 直接路由         │ chan_quectel
                    │        │ (RTP 软电话↔软电话直连)             │ (AT+UAC音频)│
                    │        │                                  ▼        │
                    │   ┌────┴─────┐                     ┌───────────┐  │
                    │   │ Web 面板  │◀──── 状态/日志/短信 ──│   EC20    │  │
                    │   │ :8090    │                     │ (USB)     │  │
                    │   └──────────┘                     └───────────┘  │
                    └─────────────────────────────────────────────────────┘
                                                  │
                                        ┌─────────┴─────────┐
                                        │  短信 → 钉钉机器人   │
                                        │  短信/未接来电 → 邮件 │
                                        └───────────────────┘
```

分工原则（针对 500MB 内存）：

| 组件 | 职责 | 稳态内存 |
|---|---|---|
| **Kamailio** | SIP 注册、digest 鉴权（SQLite）、分机路由、外线呼叫转发 | 15–25MB |
| **Asterisk（源码裁剪）** | 只做媒体网关：PJSIP ⇄ chan_quectel，短信落地 | 35–55MB |
| **chan_quectel** | EC20 通道驱动（AT 控制口 + UAC 音频 + PDU 短信） | 1–2MB |
| **Web 面板**（Python3 标准库，零依赖） | 状态/日志/短信收发/配置/重启操作 | 15–20MB |
| 系统底座（headless + zram） | — | 150–220MB |
| **合计** | | **约 220–320MB** |

> Asterisk 为什么必须存在：EC20 的 UAC 音频 + AT 信令需要 chan_quectel 这类专用通道驱动，它只能以 Asterisk 模块形式运行。除此之外的全部 SIP 职责（注册、鉴权、路由）都交给更轻的 Kamailio。Asterisk 只监听 `0.0.0.0:5062`，公网部署时防火墙只放行 5060 + RTP 端口段。

---

## 功能

- 📞 **蜂窝来电 → SIP 分机振铃接听**：外部手机拨打 SIM 卡号，1001/1002 分机同响，任一接听
- 📞 **SIP 分机 → 蜂窝呼出**：软电话直接拨手机号，经 EC20 外呼
- 📞 **分机互打**：1XXX 三位段以内分机由 Kamailio 直接路由（不经 Asterisk）
- 💬 **蜂窝短信 → 钉钉机器人（加签）+ 邮箱（msmtp）**，面板收件箱留档，支持长短信拼接（UCS-2）
- 💬 **SIP MESSAGE → 蜂窝发短信**：软电话给任意号码发 SIP MESSAGE 即转发短信
- 🌐 **网页管理面板**：仪表盘（信号/内存/服务状态）、短信收发、日志、配置、重启操作
- 🛡️ **OOM 分级保护**：Kamailio `OOMScoreAdjust=-500` 优先存活，Asterisk 允许被杀后自动拉起
- 📦 udev 固定设备名（`/dev/ec20-at`），ALSA 卡名自动探测，QPCMV 挂断复位补丁（修复第二通电话静音）

## 系统要求

- Ubuntu 20.04 LTS，aarch64（armv8），**可用运存 ≤ 500MB**（安装脚本会自动建 swap/zram 保编译）
- 移远 EC20（USB MiniPCIe/转接板均可），固件需支持 **UAC 语音**（产品页有 "Voice over USB and UAC" 应用说明，见 [docs/EC20-DEBUG.md](docs/EC20-DEBUG.md)）
- EC20 独立供电 ≥ 2A（USB 口供电不足会随机掉卡，见上游 README 的 Pi 供电警告）
- SIM 卡：已开通语音 + 短信；EC20 语音走 CSFB（回落 2G/3G），当地需有 2G/3G 覆盖，EC20 不支持 VoLTE
- 首选网络环境能访问 GitHub / downloads.asterisk.org（可带代理，见安装参数 `--proxy`）

## 快速开始

```bash
git clone https://github.com/<YOUR>/ec20-sip-gateway.git
cd ec20-sip-gateway
sudo ./install.sh \
  --ext "1001,1002" \
  --webhook "https://oapi.dingtalk.com/robot/send?access_token=xxxx" \
  --dingtalk-secret "SECxxxx" \
  --email "you@example.com" \
  --smtp-host smtp.example.com --smtp-port 465 --smtp-user you@example.com
```

安装完成会打印：SIP 分机账号/密码、Web 面板地址/密码、验证命令清单。

常用参数：

| 参数 | 说明 |
|---|---|
| `--mode trim\|apt` | `trim`=Asterisk 20 源码裁剪编译（默认，内存最优）；`apt`=Ubuntu 包（10 分钟装完，内存稍高） |
| `--ext 1001,1002` | 分机号（必须 `1` 开头的 4 位数字） |
| `--sip-pass` / `--web-pass` | 不传则随机生成 |
| `--webhook` / `--dingtalk-secret` | 钉钉机器人（加签模式） |
| `--email/--smtp-*` | msmtp 发信配置；密码留空则装后手填 `/etc/msmtprc` |
| `--proxy socks5://127.0.0.1:10808` | git/下载走代理 |
| `--qaudmod 3` | EC20 音频模式（3=关 DSP 处理，杂音/单通首选修复，存 NVM） |

单测重跑（不动已装系统）：`sudo ./install.sh --mode trim` 会先备份再覆盖配置；卸载用 `sudo ./uninstall.sh`。

## 日常使用

**软电话注册**（指向 Kamailio 5060）：

| 项 | 值 |
|---|---|
| 服务器 | 板子 IP |
| 端口 / 传输 | 5060 / UDP |
| 用户名 / 密码 | `1001` / 安装时生成 |
| 编解码 | alaw / ulaw |
| SIP 域/Realm | `ec20-gw` |

**网页面板**：`http://<板子IP>:8090`（登录密码见安装输出），功能：仪表盘、收件箱/发短信、日志、编辑钉钉/邮件/音频配置、重启服务、测试钉钉/邮件。

**常用 CLI**：

```bash
asterisk -rx "quectel show devices"          # EC20 绑定状态与信号
asterisk -rx "quectel show device state ec20"
asterisk -rx "quectel cmd ec20 AT+CSQ"       # 直发 AT
asterisk -rx "dialplan reload"
sudo ./scripts/ec20_check.sh                 # 全链路自检
```

## 短信推送配置

钉钉机器人：群设置 → 智能群助手 → 自定义机器人 → 安全设置选 **加签** → 复制 Webhook 与 `SEC` 密钥 → 填入 `--webhook`/`--dingtalk-secret` 或面板配置页。邮件走 msmtp（支持 465 SSL），配置写入 `/etc/msmtprc`。全部可随时在 Web 面板改，无需重装。

## 目录结构

```
install.sh                  一键安装（swap→依赖→Asterisk 裁剪编译→chan_quectel→Kamailio→服务编排）
uninstall.sh                卸载与配置回滚
configs/
  asterisk/                 pjsip / extensions / quectel / modules / logger / rtp
  kamailio/                 kamailio.cfg + dispatcher.list（SQLite 鉴权）
  systemd/                  服务单元与 OOM drop-in
  udev/                     /dev/ec20-at 固定规则
  rsyslog/ logrotate/       日志落盘与 SD 卡写放大控制
patches/                    QPCMV 挂断复位补丁（修第二通电话静音）
scripts/                    sms_forward.sh / sms_send_cli.sh / ec20_check.sh / ec20_modem_prep.sh
web/                        网页管理面板（Python3 标准库单文件，零依赖）
etc-template/               /etc/ec20-gateway.conf 推送配置模板
docs/                       EC20-DEBUG / TROUBLESHOOTING / CROSS-COMPILE
```

## 排障速查

| 症状 | 首查 | 详见 |
|---|---|---|
| 编译 cc1 out of memory | swap 是否生效，`--mode apt`，或异机编译搬运 | [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md)、[docs/CROSS-COMPILE.md](docs/CROSS-COMPILE.md) |
| `quectel show devices` 无设备 | `/dev/ec20-at`、ModemManager 占用 AT 口 | [docs/EC20-DEBUG.md](docs/EC20-DEBUG.md) |
| `snd_pcm_open failed` | `/proc/asound/cards` 有无 EC20 卡、alsadev 是否匹配 | [docs/EC20-DEBUG.md](docs/EC20-DEBUG.md) |
| 第二通电话无声音 | QPCMV 挂断复位补丁是否生效 | [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) |
| 杂音/单通 | `AT+QAUDMOD=3`（面板/CLI 可发） | [docs/EC20-DEBUG.md](docs/EC20-DEBUG.md) |
| 钉钉收不到 | sign 报错 310000、时间偏移 | [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) |
| 分机注册 401 | realm 必须是 `ec20-gw`、SQLite subscriber | [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) |

## 致谢与参考

- [IchthysMaranatha/asterisk-chan-quectel](https://github.com/IchthysMaranatha/asterisk-chan-quectel)（默认驱动源，OpenWrt telephony 官方 pin `3d45c7f`，`--with-astversion=20` 可编译；可用 `CHAN_QUECTEL_REPO` 切换 `daifai/asterisk-chan-quectel` 等同源分支）
- [语雀：飞牛NAS 4G模块调试教程](https://www.yuque.com/yueshangzhuzhonghuo/gk02ap/yidvzn57e05aatew?singleDoc)（EC20 上手，本仓库 [docs/EC20-DEBUG.md](docs/EC20-DEBUG.md) 给出 Ubuntu aarch64 完整落地版）
- [wdoekes/asterisk-chan-dongle](https://github.com/wdoekes/asterisk-chan-dongle)（chan_dongle 系鼻祖，配置约定出处）
- Asterisk / Kamailio / Quectel 社区

## License

MIT（本仓库）。`chan_quectel` 上游为 GPL-2.0，以模块形式在运行时加载，不影响本项目许可；上游声明见其仓库 [COPYRIGHT.txt](https://github.com/IchthysMaranatha/asterisk-chan-quectel/blob/master/COPYRIGHT.txt)。
