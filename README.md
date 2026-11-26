# SideStore 自动续签（开发中）

## 已写入的功能源码

- 系统设置入口、自动续签开关。
- 每周星期一至星期日独立开关，可任意多选。
- 一个每日执行时间，使用本地时区，默认 09:00；默认关闭执行且不选星期。
- 下次计划时间、立即续签、最近执行状态。
- SpringBoard 每 20 秒检查一次计划；锁屏等待解锁，最多补最近 24 小时内的一次任务；更改设置前的时段不回放。
- SideStore 内调用已有 RefreshAllIntent 处理器；调用前检查类和 selector，缺失时记录接口未就绪。
- 同时只允许一个请求；计划时段在派发前记为已消费，失败不自动重试。

## 当前状态

2026-11-26，GitHub Actions 第 3 轮构建（提交 2df5f23）已成功编译、签名并打包 roothide 和 rootless 两个目标，产物已上传。运行地址：https://github.com/xvklove2026/SideStoreAutoRenew/actions/runs/45829062567 。尚未安装或实机验证，免 LocalDevVPN 续签仍属实验功能。
本机先前构建停在 SDKROOT 未设置；本机无工具链和 SDK，目录内所有可选工具链均要求设备缺少的 FEAT_LRCPC，因此改用云端构建。
不要绕过 CPU 检查，也不要把主机二进制能构建等同于行为已验证。

## 兼容性依据与待验证项

本机 SideStore 显示版本 0.7.0-20261024.43+81eb7e50，模块名 SideStore，声明支持 RefreshAllIntent。
对应短提交号在官方仓库查询返回 404，因此参考的是官方 develop 分支，不能视为与本机版本完全一致。

参考文件：
- https://github.com/SideStore/SideStore/blob/develop/AltStore/Intents/Legacy/IntentHandler.swift
- https://github.com/SideStore/SideStore/blob/develop/SideStore/DeepLinks/URLHandler.swift

待确认运行时类 RefreshAllIntent、confirmRefreshAll:completion:、handleRefreshAll:completion: 和响应 code 的生成值。
SideStore 可能提前返回成功；当前显示“SideStore 返回成功，请核对有效期”，没有读取数据库证明续签完成。
打开 URL 不等于续签完成，未收到响应会标记未确认。未知的 sra-refresh host 仅用于拉起应用，实际刷新依赖插件收到通知。
必须验证 SpringBoard 的 openURL 行为、锁屏判断、跨沙盒 Darwin 通知状态，以及 roothide 对 SideStore 的插件注入是否生效。
在不支持注入的设备上，本插件不运行。关机、退出越狱、系统深度休眠时不保证准点，解锁补执行需要实机验证。
账号、配对文件与网络仍依赖 SideStore 自己的配置。新增实验性本机直连：Sources/SRADirect.m 在 SideStore 内 Hook 标准 UserDefaults 的 useLocalVPN 和 RemoteServerIp 读取，选择非 VPN 连接模式及 127.0.0.1，不持久化覆盖原设置。续签前从 SideStore 自身异步检测 127.0.0.1:62078；保留后端真实配对和可达性检查。shell 中已探测到该端口可连，但 SideStore 沙盒内 TCP、连接配置初始化时机和实际配对尚待验证，不能据此宣称免 LocalDevVPN 续签已成功。

## 构建和安装

工作区保留 external 类型，入口 apelin/build.sh。本机通过 apelin_project_build 构建；用户指定的 GitHub Actions 云构建通过 .github/workflows/build.yml 调用同一脚本，使用 macOS Xcode SDK，分别输出 roothide 与 rootless 的 deb 和 SHA-256 校验文件。推送 main 或手动运行工作流即可构建，在 Actions 对应运行的 Artifacts 下载。云端包不属于 Apelin 本机构建产物，需用户通过包管理器安装。
编译需注册的兼容工具链与 SDK，脚本使用构建提供的 SDKROOT、APELIN_* 变量，不持久化 bootstrap 实际路径。
roothide 编译 arm64e；rootless 编译 arm64 与 arm64e 后合并；设置 bundle 通过 Vendor 的最小 Preferences 声明链接。
包内安装 tweak、过滤器和 PreferenceLoader 设置入口，依赖 mobilesubstrate、preferenceloader。
临时包标识 local.apelin.sidestore.autorenew，首次安装前必须由用户确定保留或替换，并同步所有源码与配置。

## 已做检查

- sh -n apelin/build.sh 通过。
- Root.plist 经 icli fs plist 原生解析成功，七个独立星期选项存在。
- apelin_project_build 失败：SDKROOT 未设置，未到 Objective-C 编译阶段。

## 后续验证

1. 获得兼容编译环境，处理编译错误和警告并生成构建产物。
2. 安装并确认 SpringBoard、SideStore 中的构建加载标记。
3. 检查设置页、时间保存和星期多选，重开设置后值保持。
4. 用一分钟后的计划验证触发、无重复、关闭开关后停止。
5. 验证锁屏延后、解锁补执行、跨午夜和时区变化。
6. 手动执行并比较 SideStore 我的应用中的签名有效期；验证失败状态不误报完成。
