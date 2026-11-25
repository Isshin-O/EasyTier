# fork 的正式版发布流程

设备只跟 **Latest 发布** 和 **`:stable` 镜像**，所以只有 Fork Promote 会把更新发到设备上。
现在 Promote 只发通过了 **Fork Release Check** 的 nightly，出了问题用 **Fork Rollback** 一键回到上一个版本。

```
Fork Sync（每周）→ Nightly（构建 + 上游测试）→ Fork Docker → Fork Release Check（自动）
                                                                   │ 全部通过才记一条“可发布”
                                         你手动点 Fork Promote ────┘ 没有记录就当场重新检查一遍
                                         出问题手动点 Fork Rollback
```

## Fork Release Check 查什么

| 部分 | 内容 | 卡发布 |
|---|---|---|
| 门禁 `gate.sh` | nightly 就是 main 的头部；这个提交的 Core、GUI、Mobile、Test 每个任务都成功（只有 PR 专用的 Check 任务可以是 skipped）；`:版本-sha8` 镜像存在且有 amd64 和 arm64；提交包含上游最新正式 tag；下载的安装包和 SHA256SUMS 一致 | 是 |
| Linux 冒烟 `linux-smoke.sh` | x86_64 和原生 arm64 runner 上各跑一遍，见下文 | 是 |
| arm64 测试 | 上游测试套件在原生 arm64 runner 上跑一遍（上游只在 x86_64 跑，x86_64 的结果门禁里已经查过） | 是 |
| Windows `windows-smoke.ps1` | 解压 Windows zip，起两个节点：一个带 Wintun 网卡，一个不带 TUN 代替远端节点；Windows 自己 ping 对方虚拟 IP（流量真的经过 Wintun 网卡和隧道），持续 60 秒 | 是 |
| Windows GUI `windows-gui.ps1` | 静默安装 GUI，启动后看进程和窗口，截图 | 否，只报告 |
| 安卓 `android-smoke.sh` | x86_64 模拟器装 APK、预先授权 VPN、启动 30 秒看有没有崩溃，截图和 logcat | 否，只报告 |

还会提醒（不卡发布）：上游 main 又往前走了、fork 提交 rebase 到最新上游会不会冲突、上次 Fork Sync 失败了。

### Linux 冒烟测试的拓扑

全部用待发布的镜像（按 digest 拉取，并先核对镜像里的程序和发布 zip 里的完全相同）：

- `a`：公网节点，所有人的初始节点，IPv4/IPv6 双栈监听
- `b`、`c`：分别在两个 NAT 路由器后面（MASQUERADE + 丢弃主动进来的连接，像家用路由器）
- 测：通过 a 中转连通 → b、c 打洞直连 → 暂停 a 后 b、c 仍然互通 → 覆盖网 IPv6 → 走 IPv6 底层连接 a →
  公网 IPv6 Provider（租约、NDP 代理让 WAN 上的普通主机能 ping 到租出去的地址、`accept_ra` 从 1 改成 2、`all/proxy_ndp=1`）→
  禁用的初始节点不会去连（同一配置改成启用就能连上，证明不是配置坏了）→
  Web 控制台：登录、设备上线、建网络、暂停后配置保留、恢复、在控制台禁用初始节点 →
  几分钟持续 ping（丢包 ≤2%）、没有进程重启或 panic、镜像的 HEALTHCHECK 是 healthy

本地跑：`sudo .github/fork-release/linux-smoke.sh ghcr.io/isshin-o/easytier:nightly`（内核没有 IPv6 时加 `SMOKE_IPV6=0`）。

## 测不到的

- 真实家用路由器、运营商 NAT、对称型 NAT 的打洞
- Windows 上连真实的 Linux 远端（GitHub 的 Windows 和 Linux runner 之间不能互连，所以用本机的无 TUN 节点代替）、杀毒软件、真实桌面
- 安卓真机、各厂商系统差异、在 App 里配置网络并连上节点（需要界面自动化，目前只测启动）
- macOS（fork 不构建 macOS）

## 发布和回滚

- **Fork Promote**：Actions 页面手动运行。如果当前 nightly 已经有通过记录（30 天内、同一提交、安装包校验和一致、镜像 digest 还在），直接发布；否则先完整跑一遍检查（arm64 测试要编译，大约一小时）。发布时 `:stable` 和 `:版本-sha8` 指向**检查时测过的那个镜像 digest**，发布说明里记下镜像、检查记录和上一个 Latest。
- **Fork Rollback**：Actions 页面手动运行，不填参数就回到上一个正式版。它把那个版本重新设为 Latest、把 `:stable` 指回它的镜像，把出问题的版本改成预发布（不删除）。设备下次运行更新脚本就会装回去（脚本只比较版本是否和 Latest 相同，所以能降级）。
