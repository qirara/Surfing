# Surfing v7.9.0 安全与隐私审计（qirara/Surfing 加固版）

审计对象：GitMetaio/Surfing `main`（v7.9.0 / versionCode 1654，commit 5bf75b4）。方法：逐个阅读模块脚本、默认配置、构建脚本和 workflow，并对打包进模块的 SurfingTile APK（v7.2.2）做静态分析（清单、资源、字符串）。**没有在真机上抓包。**

## 结论

模块脚本本身没有发现遥测或回传，网络行为都来自 mihomo 的配置和 SurfingTile App。真正的问题有两类：

1. 模块会自动安装闭源的 SurfingTile App，它内置 Google Firebase 的统计、崩溃上报、远程配置和推送，并且持有 root。
2. 默认配置把 mihomo 的控制 API 和代理端口无密码开放给同一 Wi-Fi/热点下的所有设备。

这两点都值得出一个加固版。其余是中低风险的供应链和 DNS 问题。

## 发现

| # | 严重度 | 问题 | 位置 | 加固版处理 |
|---|---|---|---|---|
| 1 | 高 | **SurfingTile App 闭源并内置 Firebase**：Analytics（app-measurement.com）、Crashlytics、Remote Config（含 realtime）、FCM 推送、Firebase Installations，申请 `AD_ID`、`ACCESS_ADSERVICES_AD_ID/ATTRIBUTION`、`REQUEST_INSTALL_PACKAGES`、`MANAGE_EXTERNAL_STORAGE`。Firebase 项目 `surfingtile-6666` 已配置（google_app_id 存在、清单中未关闭采集），默认会上报。代码有加密资产（`assets/*.enc`）和原生库 `libsurfcore.so`，无法完整审计。App 通过 root 控制模块，所以开发者可以通过远程配置/推送影响一个持有 root 的 App（这是能力上的风险，未证实被滥用）。 | `build.sh` 打包 APK；`customize.sh` **首次安装时不询问直接 `pm install`**，更新时自动升级 | 不再打包、安装或更新 SurfingTile；安装时如检测到已装会提示卸载命令 |
| 2 | 高 | **控制 API 对局域网无密码开放**：`external-controller: 0.0.0.0:9090` + `secret: ""`。同一 Wi-Fi/热点的任何设备都能查看你的全部连接（等于浏览记录）、切换节点和模式、热加载配置、触发核心升级。 | `config.yaml` | 改为 `127.0.0.1:9090`；安装时随机生成 secret（沿用旧值），写入 `clash/secret.txt`（600 权限） |
| 3 | 高 | **代理和 DNS 端口对局域网开放**：`allow-lan: true`，`mixed-port 7890` 无认证，DNS `0.0.0.0:1053`。别人可以蹭你的节点，流量从你的节点出去。`BOX_INPUT_FILTER` 只拦了目的地是 127.0.0.1 的包。 | `config.yaml`、`box.iptables` | 新增 `filter INPUT` 链 `BOX_LAN_GUARD`：本机、TPROXY 打标记的转发流量、被 REDIRECT 的流量（热点 DNS）放行，其他外部设备直连这些端口一律 DROP。热点共享不受影响。`box.config` 中 `lan_guard="false"` 可关闭 |
| 4 | 中 | **自动更新指向上游**：`updateJson` 让 Root 管理器提示更新上游包，一点就装回原版（包括第 1 条的 APK）。 | `module.prop` | 删除 `updateJson` |
| 5 | 中 | **构建时下载的二进制不锁版本、不校验**：mihomo、Zashboard 取 latest；curl 取第三方仓库 `master` 分支的原始文件。 | `build.sh` | 资产按 GitHub 发布记录的 sha256 digest 校验；curl 锁定到具体 commit；可在 workflow 手动指定版本；所有哈希写进 zip 内 `BUILD-MANIFEST.txt` 和 Actions 摘要 |
| 6 | 中 | **仓库内自带的 busybox、ASN.mmdb 来源不明**：只有提交记录，没有来源和校验。 | `box_bll/bin/busybox` | 未替换，哈希记录在 manifest。可以改用 KernelSU 自带的 busybox |
| 7 | 中 | **规则和图标从上游作者仓库远程拉取**：`WebRTC.list` 和 35 个图标来自 `cdn.jsdelivr.net/gh/GitMetaio/Surfing@main`，作者改仓库就能远程改你的分流（每天自动更新一次）。 | `config.yaml` | 改为从你的 fork `qirara/Surfing@main` 拉取 |
| 8 | 中（看你所在地区） | **DNS 发往中国大陆**：`proxy-server-nameserver` 用腾讯 DNSPod（1.12.12.12、120.53.53.53）和阿里（223.5.5.5/6），所以代理服务器域名会被这两家看到；`nameserver-policy` 把 CN、Apple、Microsoft 域名交给它们；`direct-nameserver` 用**明文 UDP** 发给 1.12.12.12、223.6.6.6、192.168.1.1。 | `config.yaml` | `direct-nameserver` 改为 DoH（去掉明文和 192.168.1.1）。另外两项没改：在大陆境内换成境外 DoH 可能连代理都解析不了。人在境外可以改成 1.1.1.1 / 8.8.8.8 |
| 9 | 低 | mihomo 以 root（`root:net_admin`）运行，权限大于需要。 | `box.config` | 未改（改成非 root 需要在设备上测试 capabilities） |
| 10 | 低 | `geo-auto-update: true`，每 24h 从 GitHub 拉 ASN 库；规则集每 24h 从 jsDelivr 拉取。这是正常功能，会暴露 IP 和使用特征给 CDN。 | `config.yaml` | 未改 |
| 11 | 低 | `run.log` 记录 Wi-Fi SSID、BSSID、IP；日志保留 3 天，在 `/data/adb` 下，普通 App 读不到。 | `ctr.inotify` | 未改 |
| 12 | 信息 | `settings put global surfing_sync_data`（给 SurfingTile 用，任何 App 都能读 Settings.Global）；`Surfing_service.sh` 只在 OPPO/一加/realme 上删除系统防火墙的 REJECT 规则；`optimize_kernel` 修改 conntrack 超时和 `route_localnet`。 | — | 删除 sync_data 写入；其他与小米设备无关或属于正常功能 |
| 13 | 信息 | 上游 workflow 在 fork 中会尝试推送 `data` 分支、发布 Release、每天删除 Actions 记录。 | `.github/workflows` | 仅在上游仓库运行；新增 `Hardened Build` workflow |

没有发现：模块脚本向外发送设备信息、隐藏的下载或执行远程脚本、修改系统分区以外的持久化。`net.inotify` 里的 curl 只访问本机的控制 API。

## 与 Anximi 的关系

- iptables：Surfing 只在 `filter` 表加了 `INPUT` 的 `BOX_INPUT_FILTER`/`BOX_LAN_GUARD` 和 `OUTPUT` 的 `SURF_BLOCK`，从不清空 `OUTPUT`。`ANXIMI_OUT` 的假设成立。
- hosts：**冲突**。Surfing 会把 `/data/adb/box_bll/clash/etc/hosts` bind mount 到 `/system/etc/hosts`，盖住 Anximi 的 hosts。已在 Anximi 一侧修复（同步到 Surfing 的 hosts 文件）。
- 规则集：加固版默认配置直接引用 `./rules/anximi-domains.yaml` 和 `./rules/anximi-process.yaml`（REJECT，在 DNS 规则之后的第一位），安装时放好占位文件；Anximi 会自动复制到这里。

## 使用注意

- 面板：KernelSU 的 WebUI 会跳转到 `http://127.0.0.1:9090/ui`，Zashboard 里填 secret（安装日志会显示，也在 `/data/adb/box_bll/clash/secret.txt`）。
- 已安装的 SurfingTile 不会被自动卸载：`pm uninstall com.github.surfing`。
- 更新加固版时，如果选「使用新默认配置」，会用加固版的默认配置（订阅块会保留）；选「保留我的配置」则保留你的旧配置，第 2、3、7、8 条的修改不会进入旧配置，需要手动改（`BOX_LAN_GUARD` 仍然生效）。
