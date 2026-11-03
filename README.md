# loop-download

固定速率循环下载工具，带交互式面板。

核心就三点，都是按需求做的：

1. **任意直链都行**：内置几个公开大文件测速源做示例，也支持自填链接 —— 比如去官网下载页右键复制的荣耀安装包、驱动、系统镜像直链，粘贴进去就能跑，跑通后可以保存为预设，下次一键选。
2. **固定速率，不占满带宽**：速率单位是 **Mbps**（跟宽带测速口径一致），菜单里可选 2 / 5 / 10 / 16 / 20 / 50 / 100 Mbps，也能自定义（比如 2.5）。内部换算给 `curl --limit-rate` / `wget --limit-rate` 用：1 Mbps = 125000 字节/秒，所以 16 Mbps ≈ 2 MB/s。默认 16 Mbps，等于旧版默认 2 MB/s，速度没变。
3. **下载完直接丢弃，不占硬盘**：每次下载都输出到 `/dev/null`，不落盘、不留临时文件，循环多少轮硬盘都不会涨。只产生下行流量，适合长时间挂机拉流量。

## 快速开始

支持主流 Linux：Ubuntu / Debian / CentOS / RHEL / Rocky / AlmaLinux / Fedora，amd64 / arm64。

装完之后，一键呼出面板的命令都是一样的（名字定为 `loopdl`）：

```bash
loopdl
```

不用每次 `cd` 到下载目录再 `./loop_download.sh`，任意目录打 `loopdl` 就进面板。没装全局命令时，才需要在下载目录跑 `./loop_download.sh`。

### 国内机器

```bash
curl -fsSL https://cdn.jsdelivr.net/gh/emmaforge/loop-download@main/install.sh | bash
loopdl
```

只下载脚本的话，也走 jsDelivr，别走 raw：

```bash
curl -LO https://cdn.jsdelivr.net/gh/emmaforge/loop-download@main/loop_download.sh
chmod +x loop_download.sh
./loop_download.sh
# 手动装一键命令: sudo cp loop_download.sh /usr/local/bin/loopdl && sudo chmod +x /usr/local/bin/loopdl
```

### 国外机器

```bash
curl -fsSL https://raw.githubusercontent.com/emmaforge/loop-download/main/install.sh | bash
loopdl
```

只下载脚本 / 用 git：

```bash
curl -LO https://raw.githubusercontent.com/emmaforge/loop-download/main/loop_download.sh
chmod +x loop_download.sh
./loop_download.sh
```

```bash
git clone https://github.com/emmaforge/loop-download.git
cd loop-download
chmod +x loop_download.sh
./loop_download.sh
# 手动装一键命令: sudo cp loop_download.sh /usr/local/bin/loopdl && sudo chmod +x /usr/local/bin/loopdl
```

> 为什么国内不要用 raw？国内服务器直连 `raw.githubusercontent.com` 常报 `curl: (35) Recv failure: Connection reset by peer`，文件根本没下载下来，后面的 `chmod` / `./loop_download.sh` 自然报 `No such file or directory`。这不是脚本的问题，是下载源被重置了。国内那句走的是 jsDelivr，实测国内机器能用。`install.sh` 本身还会按 jsDelivr → fastly → gcore → ghproxy → raw 的顺序挨个试，并校验下载到的确实是脚本（不是代理返回的 HTML），一个不行自动换下一个。
>
> 另外一个坑：jsDelivr 缓存经常还是旧版，旧版面板里没有菜单 6、没有国内预设，但装完看起来又像成功了。现在 `install.sh` 会按版本号校验（当前 `1.5`，面板顶部也显示版本），旧版缓存会被直接跳过，继续试下一个镜像，直到 raw。国外机器能直连 raw，所以用国外命令重装一定能拿到新版；国内机器如果 raw 被重置，就只能等 jsDelivr 缓存刷新后再重装。判断是不是新版很简单：进面板看顶部版本是不是 `1.5`，有没有菜单 6 和国内预设。

菜单：

```
1) 选择下载源 (预设 / 自填链接)
2) 选择固定速率 (当前 16 Mbps)
3) 设置循环模式 / 间隔
4) 开始下载 (后台运行, 回菜单后可用 6 停止)
5) 管理预设链接
6) 停止下载任务
7) 查看后台任务状态和日志
8) 开始下载 (前台运行, 按 Ctrl+C 停止)
0) 退出
```

## 停止任务

以前前台跑的时候菜单被占住，想停只能 Ctrl+C，关了终端就没法从别处停。现在默认是后台跑：

- 在面板里选 `6` 停止
- 在别的终端（不用进面板）打 `loopdl stop` 停止
- 看状态：`loopdl status`，看日志：`loopdl log`，日志在 `~/.config/loop_download/loop_download.log`

后台任务的 PID 在 `~/.config/loop_download/loop_download.pid`，停止时会连同正在跑的 curl 一起杀掉，不会只杀壳留下载继续跑。前台模式还留着（菜单 `8`），按 Ctrl+C 也能停，适合想盯着进度看的时候用。

## 用法说明

- **自填荣耀安装包链接**：荣耀官网的下载链接常带 token、会过期，不要硬编码。去下载页右键下载按钮 → 复制链接地址 → 菜单选 `1` → `c` 自填 → 粘贴，选 `y` 保存为预设即可。
- **循环模式**：无限循环（Ctrl+C 停止）、固定轮数、固定时长（分钟）三种，每轮默认间隔 3 秒，可改，避免一直 hammer 服务器。
- **内置预设**：国内的放前面 —— 清华 / 华为云 / 网易的 Ubuntu 24.04.5.1 ISO（约 6.25GB）和清华 Ubuntu 22.04.5 ISO（约 4.76GB），都是镜像站长期保留的 LTS 版本，实测 Range 请求返回 206；国外的放后面 —— Cloudflare 测速和 Ubuntu 官网。阿里云、USTC、腾讯那几个在境外实测分别返回 302 跳 http 失败 / 403 / 567，没放进来。
- **预设保存位置**：自定义预设存在 `~/.config/loop_download/presets.txt`，换机器把这个文件拷过去就行。
- **依赖**：`curl`（优先）或 `wget`，`bash`，`awk`。缺 curl 时，`install.sh` 会按发行版自动装：Ubuntu/Debian 用 `apt`，RHEL/Rocky/AlmaLinux/Fedora 用 `dnf`，老 CentOS 用 `yum`。

## 注意事项

- 限速是固定值，不是上限浮动，选 16 Mbps 就是 16 Mbps 左右（约 2 MB/s），不会突然占满。注意别跟 MB/s 搞混：2 Mbps 只有 0.25 MB/s。
- 只在自己的机器、自己的网络上用，别拿小站的直链无限循环刷。
- 下载内容直接丢弃，跑完不需要手动清理。
