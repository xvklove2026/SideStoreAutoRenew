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

2026-11-26，0.1.1 的双架构云构建已成功，更新后设置页可正常打开，手动请求可唤起 SideStore，但应用内回环 TCP 探测失败，未进入续签。SideStore 健康检查显示 Minimuxer 未启动、配对文件已加载但连接断开，配置为 Remote Server / 127.0.0.1 / Lockdown。设备外部对回环与设备自身 Wi-Fi 地址的 62078 端口探测均成功，这不证明应用沙盒内连接成功。

0.1.2 尝试在连接配置初始化前选择本机 en0 IPv4 地址，无 Wi-Fi 时保留回环；配置与探测使用同一地址，网络地址变更时要求重启 SideStore，并记录 TCP errno（不记录 IP 或配对数据）。新版仍需安装后验证应用内可达性、Minimuxer 启动、配对及实际签名有效期，尚未证明免 LocalDevVPN 续签成功。
0.1.2 安装实测：SideStore 已采用本机 Wi-Fi 地址，但插件与应用后端均报告连接不可达，Minimuxer 未启动，未证明续签成功。Wi-Fi 数据策略为允许；系统本地网络列表未出现 SideStore，此结果本身不能确定拒绝原因。

2026-11-27 实测：系统“隐私与安全性 → 本地网络”中的 SideStore 已开启；重启应用并重试后，安装版 c85d262 的应用内日志仍为 wifi=1、reachable=0、errno=1，未进入续签。监听期间未取得明确的系统沙盒拒绝规则，因此不能仅凭 EPERM 认定具体原因。

当前工作区新增尚未编译安装的分阶段诊断：区分地址检查、socket、fcntl、connect、poll、SO_ERROR；通过 Darwin 数值状态的高 32 位传阶段、低 32 位传 errno，旧版仅 errno 数据显示为未知阶段。新请求清除旧阶段与错误。设置页不再将 EPERM 单独归因为本地网络未授权。本机构建仍在 SDKROOT 检查处停止，未取得本补丁的编译结果；尚未修复实际连接问题。

本机本轮构建仍停在 SDKROOT 未设置；本机无工具链和 SDK，目录内所有可选工具链均要求设备缺少的 FEAT_LRCPC，因此需用云端构建。
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
账号、配对文件与网络仍依赖 SideStore 自己的配置。实验性本机直连：Sources/SRADirect.m 在 SideStore 内 Hook 标准 UserDefaults 的 useLocalVPN 和 RemoteServerIp 读取，选择非 VPN 模式及启动时发现的本机 Wi-Fi IPv4 地址（无 Wi-Fi 时使用回环），不持久化覆盖原设置。续签前从 SideStore 自身异步检测相同地址的 62078 端口；保留后端真实配对和可达性检查。shell 中端口可连不代表 SideStore 沙盒内可达；新版应用内 TCP、Minimuxer 启动和实际配对仍需安装验证。

## 构建和安装

工作区保留 external 类型，入口 apelin/build.sh。本机通过 apelin_project_build 构建；用户指定的 GitHub Actions 云构建通过 .github/workflows/build.yml 调用同一脚本，使用 macOS Xcode SDK，分别输出 roothide 与 rootless 的 deb 和 SHA-256 校验文件。推送 main 或手动运行工作流即可构建，在 Actions 对应运行的 Artifacts 下载。云端包不属于 Apelin 本机构建产物，需用户通过包管理器安装。
编译需注册的兼容工具链与 SDK，脚本使用构建提供的 SDKROOT、APELIN_* 变量，不持久化 bootstrap 实际路径。
roothide 与 rootless 均编译 arm64 与 arm64e 后合并，并在签名前校验两种切片；设置 bundle 通过 Vendor 的最小 Preferences 声明链接。
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
