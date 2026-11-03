# loop-download

固定速率循环下载工具，带交互式面板。

核心就三点，都是按需求做的：

1. **任意直链都行**：内置几个公开大文件测速源做示例，也支持自填链接 —— 比如去官网下载页右键复制的荣耀安装包、驱动、系统镜像直链，粘贴进去就能跑，跑通后可以保存为预设，下次一键选。
2. **固定速率，不占满带宽**：速率单位是 **Mbps**（跟宽带测速口径一致），菜单里可选 2 / 5 / 10 / 16 / 20 / 50 / 100 Mbps，也能自定义（比如 2.5）。内部换算给 `curl --limit-rate` / `wget --limit-rate` 用：1 Mbps = 125000 字节/秒，所以 16 Mbps ≈ 2 MB/s。默认 16 Mbps，等于旧版默认 2 MB/s，速度没变。
3. **下载完直接丢弃，不占硬盘**：每次下载都输出到 `/dev/null`，不落盘、不留临时文件，循环多少轮硬盘都不会涨。只产生下行流量，适合长时间挂机拉流量。

## 快速开始

```bash
curl -LO https://raw.githubusercontent.com/emmaforge/loop-download/main/loop_download.sh
chmod +x loop_download.sh
./loop_download.sh
```

或者用 git：

```bash
git clone https://github.com/emmaforge/loop-download.git
cd loop-download
chmod +x loop_download.sh
./loop_download.sh
```

菜单：

```
1) 选择下载源 (预设 / 自填链接)
2) 选择固定速率 (当前 16 Mbps)
3) 设置循环模式 / 间隔
4) 开始下载
5) 管理预设链接
0) 退出
```

## 用法说明

- **自填荣耀安装包链接**：荣耀官网的下载链接常带 token、会过期，不要硬编码。去下载页右键下载按钮 → 复制链接地址 → 菜单选 `1` → `c` 自填 → 粘贴，选 `y` 保存为预设即可。
- **循环模式**：无限循环（Ctrl+C 停止）、固定轮数、固定时长（分钟）三种，每轮默认间隔 3 秒，可改，避免一直 hammer 服务器。
- **预设保存位置**：自定义预设存在 `~/.config/loop_download/presets.txt`，换机器把这个文件拷过去就行。
- **依赖**：`curl`（优先）或 `wget`，`bash`。

## 注意事项

- 限速是固定值，不是上限浮动，选 16 Mbps 就是 16 Mbps 左右（约 2 MB/s），不会突然占满。注意别跟 MB/s 搞混：2 Mbps 只有 0.25 MB/s。
- 只在自己的机器、自己的网络上用，别拿小站的直链无限循环刷。
- 下载内容直接丢弃，跑完不需要手动清理。
