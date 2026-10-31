# WCRefine for Mac

Mac微信增强工具，**基于微信 4.1.15.55（构建 270135）制作**。

安装器复制一份微信并载入本地动态库，原版 App 不被改写。

当前仅支持 Apple Silicon（arm64）和 macOS 12+。

> **非官方项目**：WCRefine 与腾讯、微信、Apple 均无隶属、授权或背书关系。「WeChat」「微信」「Mac」等名称仅用于说明兼容对象。本项目不包含、不分发微信安装包，也不提供绕过账号限制或解密聊天数据的能力。



## 兼容版本

当前微信官方公开下载版是 **4.1.15.55（构建 270135）**，**其他版本未适配！**

官方下载：[微信 Mac 4.1.15.55（构建 270135）](https://dldir1v6.qq.com/weixin/Universal/Mac/WeChatMac_4.1.15.dmg)

安装前可只读检查：

```bash
build/wcrefine-check --app /Applications/WeChat.app
```



## 主要功能

- **消息防撤回**：对方撤回的私聊和群聊留在原会话，可显示提示和原文，可选择通知或转发通知。
- **原始ID查询**：右下角桌宠点击即可复制当前会话 ID。
- **语音转发**：语音气泡可以像文字一样可以自由转发。
- **消息复读**：长按消息，菜单最顶部会多出「复读」，支持文字、语音、图片、视频、文件/链接、表情等常规消息；
- **圆角头像**：头像圆角从直角到纯圆可调。
- **退群监控**：有人退出或被移出时，聊天里出现灰字；可选发送文字通知。
- **禁用截图检测**：普通截图可以截到微信主窗口，防止使用 AI 接管时获取不到窗口信息。
- **微信多开**：可生成独立沙盒的多开副本。

功能是否可用取决于当前构建；菜单中的不可用项会置灰。



## 隐私与本地数据

- 本工具不上传聊天内容，不包含分析、遥测或远程配置 SDK。
- 开启原文显示时，撤回正文只在微信进程内存中短暂保留，并按服务器消息 ID 限量缓存。
- 联系人名称缓存、开关、模板、目标会话和桌宠外观保存在微信副本自己的容器中。主副本与原版共享同一微信数据目录；多开副本使用独立容器。
- 「导出配置」会把 `WCRefineMac*` 偏好和已学习联系人名称写入用户选择的 plist 文件。
- 退群/复读模块可能写入 `~/Library/Logs/WCRefine/` 的本地诊断日志；日志不记录消息正文。
- 退出增强副本后，可以删除它自己的容器和日志来清理本地数据。删除主副本不会删除原版微信数据。

更完整的边界见 [`PRIVACY.md`](PRIVACY.md)。



## 环境要求

- Apple Silicon Mac
- macOS 12 或更高
- Xcode Command Line Tools（`xcrun clang++`、`codesign`、`ditto`）
- 从 `/Applications/WeChat.app` 或 `/Applications/微信.app` 读取原始微信副本

## 如何构建

```bash
make all
make dist
```

`make all` 生成：

- `build/WCRefine-for-Mac.app`
- `build/WCRefineMac.dylib`
- `build/wcrefine-check`

`make dist` 生成源码归档和 arm64 安装包，并输出 SHA-256 校验文件。

## 如何使用

打开 `build/WCRefine-for-Mac.app`。第一次或还没有增强版时会看到说明，点「继续」后选择微信，再「生成增强版」。完成后先退出原版，再「启动」。

```bash
Installer/install.sh --app /Applications/WeChat.app --replace
Installer/launch.sh
```

### 如何多开

```bash
Installer/install.sh --multi 2
Installer/launch.sh ~/Applications/WCRefine-WeChat-2.app
```

多开副本会改写 `CFBundleIdentifier`，用于获得独立容器。

创建后建议先确认登录、视频、朋友圈和辅助进程均正常，再依赖该副本保存数据。管理器中的「删除副本」会先确认，再移到废纸篓；独立数据容器不会自动删除。

### 如何恢复

退出增强副本，把 `~/Applications/WCRefine-WeChat.app` 移到废纸篓。原版不受影响。管理器菜单里的「清理旧版本备份…」可以把早期覆盖安装留下的完整副本移到废纸篓。

## 安装器说明

安装器只修改用户指定的副本，不会改写 `/Applications/WeChat.app`：

1. 校验微信 bundle、arm64 架构和可用版本配置。
2. 用 `ditto` 复制副本并写入本地 dylib 加载命令。
3. 保留原版 entitlements，并按自己的权限重签辅助组件。
4. 对副本做 ad-hoc 签名和完整性校验。
5. 多开时改写 bundle id 和显示名。

视频和朋友圈依赖 `XPlayer`、`WeChatAppEx`、`WeChatHelper` 继承微信沙盒。

不要只替换 dylib 后手工重签主 App；请使用安装器重新生成副本。

## 社区与更新

- GitHub：<https://github.com/plumblossom26/WCRefine-For-Mac>
- Telegram 频道：<https://t.me/WCRefine>

## 许可与边界

项目自有源码以 [`LICENSE`](LICENSE)（MIT）发布。第三方组件和商标边界见 [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md)。

本项目修改的是用户本机微信副本，可能违反微信服务条款或影响账号安全。请在遵守当地法律和软件许可的前提下使用；作者不对账号限制、数据损坏或服务中断承担责任。
