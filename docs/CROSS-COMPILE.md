# 低内存设备编译失败 → 异机/交叉编译搬运指南

目标机 RAM ≤500MB 时，Asterisk 全量编译（即使 -j1）仍可能失败。两条路：

## 方案 1：同架构异机编译（推荐，最省心）

1. 准备一台 **Ubuntu 20.04 aarch64** 云主机/开发板（≥2GB RAM）。
2. 在异机上跑同一个安装脚本到编译为止（只编译不部署）：

```bash
sudo ./install.sh --mode trim --ext 1001 --skip-deploy   # 见下方说明
```

或手工执行编译段：

```bash
sudo apt install -y build-essential libncurses5-dev libssl-dev libxml2-dev \
  libsqlite3-dev uuid-dev libjansson-dev pkg-config autoconf automake libtool \
  bison flex libasound2-dev
cd /usr/src
wget https://downloads.asterisk.org/pub/telephony/asterisk/asterisk-20-current.tar.gz
tar xzf asterisk-20-current.tar.gz && cd asterisk-20.*
./configure --with-pjproject-bundled
make menuselect.makeopts
MS=menuselect/menuselect
$MS --disable BUILD_NATIVE menuselect.makeopts
$MS --enable LOW_MEMORY menuselect.makeopts
$MS --disable-category MENUSELECT_CHANNELS menuselect.makeopts && $MS --enable chan_pjsip menuselect.makeopts
$MS --disable-category MENUSELECT_APPS menuselect.makeopts
for a in app_dial app_echo app_playback app_system app_verbose; do $MS --enable $a menuselect.makeopts; done
$MS --disable-category MENUSELECT_FUNCS menuselect.makeopts
for f in func_callerid func_base64 func_strings; do $MS --enable $f menuselect.makeopts; done
$MS --disable-category MENUSELECT_CODECS menuselect.makeopts
for c in codec_alaw codec_ulaw; do $MS --enable $c menuselect.makeopts; done
$MS --disable-category MENUSELECT_FORMATS menuselect.makeopts
for f in format_sln format_wav format_pcm; do $MS --enable $f menuselect.makeopts; done
$MS --disable-category MENUSELECT_BRIDGES menuselect.makeopts
for b in bridge_simple bridge_native_rtp; do $MS --enable $b menuselect.makeopts; done
$MS --disable-category MENUSELECT_PBX menuselect.makeopts && $MS --enable pbx_config menuselect.makeopts
$MS --disable-category MENUSELECT_CDR menuselect.makeopts || true
$MS --disable-category MENUSELECT_CEL menuselect.makeopts || true
$MS --disable-category MENUSELECT_TESTS menuselect.makeopts || true
for r in res_xmpp res_phoneprov res_snmp res_odbc res_fax res_fax_spandsp res_pktccops \
         res_hep res_hep_pjsip res_stasis res_ari res_ari_asterisk res_ari_channels \
         res_ari_endpoints res_ari_events res_ari_model res_ari_playbacks res_ari_recordings \
         res_ari_device_states res_http_websocket res_adsi res_smdi res_security_log \
         res_musiconhold res_parking res_agi res_calendar res_corosync res_statsd; do
  $MS --disable $r menuselect.makeopts || true
done
make -j$(nproc) && sudo make install
# chan_quectel 同样在异机编译（--with-astversion=实际版本）
```

3. 打包运行时产物并拷到目标机：

```bash
tar czf asterisk-runtime.tgz /usr/sbin/asterisk /usr/lib/asterisk/modules \
    /var/lib/asterisk /var/spool/asterisk /etc/asterisk/*.sample 2>/dev/null
scp asterisk-runtime.tgz board:
```

4. 目标机解包 + 补运行时目录结构：

```bash
sudo tar xzf ~/asterisk-runtime.tgz -C /
sudo mkdir -p /var/log/asterisk /var/run/asterisk /usr/lib/asterisk/static-http
sudo useradd -r asterisk 2>/dev/null || true
sudo chown -R asterisk:asterisk /var/{lib,log,spool}/asterisk
sudo /usr/sbin/asterisk -V    # 能打印版本即 OK
```

5. 在目标机正常跑 `sudo ./install.sh --mode trim --skip-build`（脚本检测到
   `/usr/sbin/asterisk` 已存在时跳过编译段），或直接按 README 手工完成配置部署。

## 方案 2：qemu-user 交叉编译（无 aarch64 机器时）

```bash
sudo apt install -y qemu-user-static debootstrap binfmt-support
debootstrap --arch=arm64 focal /opt/focal-arm64 http://ports.ubuntu.com/ubuntu-ports
sudo mount --bind /dev /opt/focal-arm64/dev 2>/dev/null || true
sudo chroot /opt/focal-arm64 qemu-aarch64-static /bin/bash
# 之后在 chroot 内按方案 1 步骤执行；编译速度约为真机 1/3，但内存消耗在宿主机上
```

## 备注

- `BUILD_NATIVE` 必须保持 disabled（已包含在脚本里），否则异机编译的二进制
  搬到目标机会因 CPU 特性差异无法加载。
- pjproject bundled 与 Asterisk 静态链接在模块内，搬运 modules 目录即可带过去。
- chan_quectel.so 只依赖 libasound2（目标机已有）与 Asterisk 符号，直接拷贝可用；
  但务必保持目标机 Asterisk 版本与编译时一致（`asterisk -V` 校验）。
