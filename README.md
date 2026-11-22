# Hermes Desktop Lite

简体中文 · [English](README.en.md)

Hermes Agent 的轻量客户端，包含桌面端与移动端。

## 性能

在 Windows x64 上冷启动并恢复同一会话，Lite v0.1.0 显示历史回复的耗时比官方 Hermes Desktop **缩短 84%**，进程树专用内存**减少 86%**。

| 指标 | Hermes Desktop Lite v0.1.0 | 官方 Hermes Desktop |
| --- | ---: | ---: |
| 冷启动至主窗口出现 | 0.851 秒 | 3.141 秒 |
| 冷启动至历史回复可见 | 1.270 秒 | 8.159 秒 |
| 冷启动后专用内存 | 65.0 MiB | 466.8 MiB |
| 热启动至主窗口出现 | 204 毫秒 | 358 毫秒 |
| 热启动后专用内存 | 191.0 MiB | 747.4 MiB |

两个客户端使用同一 Profile，恢复同一个仅含一问一答的会话。表中数据取三轮测量的中位数。官方客户端基于上游提交 `e96221fa73d2` 构建。

## 技术栈

| 模块 | 技术 |
| --- | --- |
| 桌面端 | Rust、GPUI |
| 移动端 | Dart、Flutter |
| 共享会话协议 | Rust（`hermes-client-core`） |

## 构建目标

| 桌面端 | 移动端 |
| --- | --- |
| Windows x64、Linux x64、macOS Apple Silicon | Android ARM64 / x86_64、iOS |

## Windows 运行库

若启动时提示缺少 `VCRUNTIME140.dll`，请安装 Microsoft Visual C++ v14 x64 可再发行组件。[微软官方下载](https://aka.ms/vc14/vc_redist.x64.exe)

## 设计与许可

桌面端界面风格借鉴自官方 Hermes Desktop。源码采用 MIT 许可证，随附素材按各自的许可分发。[上游项目](https://github.com/NousResearch/hermes-agent/tree/f7e2898aaefc8f967dbf7345e3999a65672fe60e/apps/desktop) · [MIT 许可证](LICENSE) · [第三方声明](THIRD_PARTY_NOTICES.md)
