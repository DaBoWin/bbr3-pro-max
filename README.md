# BBR3-Pro-Max 🚀

[![License](https://img.shields.io/github/license/DaBoWin/bbr3-pro-max?color=blue)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-Debian%20%7C%20Ubuntu-orange)](https://github.com/DaBoWin/bbr3-pro-max)

**BBR3-Pro-Max** 是一个极简且智能的 Linux TCP 加速工具。它能自动分析当前系统网络瓶颈，并一键升级至支持 **BBRv3** 的 XanMod 内核，旨在为你的服务器提供更低的延迟和更高的吞吐量。

---

## ✨ 功能亮点

- **📊 状态洞察**：启动即显示当前内核、TCP 算法、BBR 版本及队列调度算法（Qdisc）。
- **🧠 智能适配**：自动识别 CPU 指令集（x86-64-v1/v2/v3），安装最适合硬件的内核版本。
- **🛡️ 安全守护**：自动检测 OpenVZ/LXC 虚拟化环境，避免在不支持更换内核的环境下盲目安装。
- **🚀 性能调优**：预设 `fq_pie` 与 `ECN` 等优化参数，配合 BBRv3 压榨网络性能。
- **🧹 优雅配置**：采用独立配置文件管理，支持一键卸载或手动还原。

---

## 🚀 快速安装

在终端输入以下命令（需要 **root** 权限）：

```bash
wget -qO bbr3.sh https://raw.githubusercontent.com/DaBoWin/bbr3-pro-max/main/main.sh && chmod +x bbr3.sh && ./bbr3.sh
