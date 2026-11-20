# 故障排查手册（按失败阶段组织）

## A. 安装 / 编译阶段

### A1. `cc1: out of memory` / OOM Killer 杀掉 make
- 确认 swap：`free -m`（SwapTotal ≥ 1024）。install.sh 默认已建 `/swapfile`，
  手工恢复：`dd if=/dev/zero of=/swapfile bs=1M count=1024 && mkswap /swapfile && swapon /swapfile`
- 确认 zram（可选）：`apt install zram-tools`，`/etc/default/zramswap` SIZE=512
- 仍失败 → 交叉/异机编译后搬运，见 [CROSS-COMPILE.md](CROSS-COMPILE.md)
- 快速路径：`sudo ./install.sh --mode apt`（Ubuntu 包，RSS 稍高但 10 分钟装完）

### A2. chan_quectel `configure: error: Please set --with-astversion`
- install.sh 自动用 `asterisk -V` 探测；手工编译示例：
  `./bootstrap && ./configure --with-asterisk=/usr/include --with-astversion=20.5.2`

### A3. make install 后没有 chan_quectel.so
- 确认 `apt install libasound2-dev`（ALSA 必需）；重跑 install.sh

## B. EC20 / chan_quectel 阶段

### B1. `quectel show devices` 为空
1. `ls /dev/ec20-at` 存在？无 → udev 规则未生效：`sudo udevadm trigger`，或 EC20 未插好
2. `sudo lsof /dev/ec20-at` 被占用？→ `systemctl disable --now ModemManager`
3. `/var/log/asterisk/messages` 里找 `Quectel ... needs PIN` → SIM PIN 未解锁

### B2. `snd_pcm_open failed: No such device`
- `cat /proc/asound/cards` 无 EC20 → UAC 未枚举，见 [EC20-DEBUG.md §3](EC20-DEBUG.md)
- 卡名与 `alsadev=` 不一致 → 改 `/etc/asterisk/quectel.conf` 后重启 asterisk

### B3. 第一通有声音，第二通静音
- QPCMV 挂断复位补丁未生效。验证：
  `grep 'AT+QPCMV=0' /usr/src/chan_quectel/channel.c`
- 应急：`asterisk -rx "quectel cmd ec20 AT+QPCMV=0"`，等 5 秒再拨
- 重装时去掉 `--no-patch` 让 install.sh 重新打补丁

### B4. 杂音 / 单通 / 远端听不清
- `AT+QAUDMOD=3`（面板“AT 预备”按钮可发）；仍差则试 0/1/2 档对比
- 供电不足也会造成音频爆音（见 EC20-DEBUG.md §0）

## C. Kamailio / SIP 注册阶段

### C1. 分机注册 401
- realm 必须是 `ec20-gw`（软电话里 SIP 域/realm 填 `ec20-gw`）
- 分号检查：`sqlite3 /etc/kamailio/kamailio.db 'select * from subscriber;'`
- 密码忘了：重跑 `sudo ./install.sh --mode trim --sip-pass 新密码`（只重建 subscriber）

### C2. `kamcmd dispatcher.list` DOWN（或软电话呼出 503）
- Asterisk 是否在听 5062：`ss -lun | grep 5062`
- `systemctl status asterisk`；查 `/var/log/asterisk/messages`
- dispatcher.list 目标是 `sip:127.0.0.1:5062`，改过端口要同步改

### C3. 呼出 403 Register first
- Kamailio 要求先注册（防滥用）；软电话注册成功后再拨

### C4. 双向无声音（能振铃能接）
- SD 媒体地址问题：Asterisk transport 绑定必须是 `0.0.0.0:5062`（不能 127.0.0.1，
  否则 SDP c= 是 127.0.0.1，软电话把 RTP 发给自己）
- 防火墙放行 UDP 10000-20000（rtp.conf 端口段）和 UDP 5060
- 公网部署需要 rtpengine/nathelper（LAN 部署无需）——属于扩展场景

## D. 短信阶段

### D1. 收到短信但钉钉/邮件没收到
- `tail /var/log/ec20-gateway.log`：看 dingtalk/email 行的 rc 与响应
- 钉钉 errcode=310000：加签计算失败 → SECRET 复制错/时间偏移大
  （`timedatectl` 开 NTP）
- errcode=310100：机器人关键词/加签模式不符
- 邮件失败：`cat /var/log/msmtp.log`，检查 /etc/msmtprc（465=SSL，587=STARTTLS
  需在 msmtprc 加 `tls_starttls on`）

### D2. 短信中文乱码
- chan_quectel 内部做 UCS-2→UTF-8；确认 `${SMS_BASE64}` 路径（dialplan 用 base64
  变量而不是 ${SMS}）；手工验证：面板收件箱显示正常则链路 OK

### D3. 长短信只收到半截
- 多段短信由 chan_quectel smsdb 拼接（/var/lib/asterisk/smsdb），确认目录存在且
  asterisk 用户可写

### D4. 软电话发短信失败
- dialplan `messaging` 上下文需要 `func_base64`（trim 安装已含）：
  `asterisk -rx "module show like func_base64"`
- 号码必须纯数字 3-20 位（脚本白名单）；看 `journalctl -u asterisk` 里 System() 输出

## E. Web 面板阶段

| 现象 | 处置 |
|---|---|
| 502/连不上 | `systemctl status ec20-web`；端口看 `/etc/ec20-gateway.conf` WEB_BIND/WEB_PORT |
| 密码忘了 | 重跑 install.sh `--web-pass 新密码` 或手工：`echo -n '新密码' \| sha256sum` 更新 WEB_PASS_HASH |
| 按钮无反应 | 面板以 root 跑（systemd 单元默认）；看 `journalctl -u ec20-web` |

## F. 内存守护

- `./scripts/ec20_check.sh` 看 Top 进程与阈值
- Kamailio OOMScoreAdjust=-500 保证信令层最后死；Asterisk 被杀后 5 秒内 systemd 拉起
- shm 不足（Kamailio 日志 out of shared memory）：`/etc/default/kamailio` SHM_MEMORY 48→64→96
