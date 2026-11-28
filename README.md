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

0.2.3 工作区已改为仅在 SideStore 内 hook Network.framework 的 nw_path_uses_interface_type C 接口；蜂窝路径仅对刷新策略报告为 Wi-Fi，不开关蜂窝数据或调用快捷指令。保留真实路由、在线准备、Minimuxer 端点检查、配对校验和签名有效期核对。

当前网络策略只在 SideStore 内将纯蜂窝路径用于刷新策略的 Wi-Fi 查询返回为真；不修改蜂窝数据开关，也不调用快捷指令。

本机编译停在 SDKROOT 缺失处；0.2.3 尚未云构建或安装验证。0.2.2 曾因 Swift NWPath 方法 ABI 假设错误导致 SideStore SIGSEGV，已在 0.2.3 改用 Network.framework C 接口；新 hook 的运行时行为和签名有效期仍待确认。

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

## 实验性本机转发（尚未编译验证）

2026-11-27，33ee6b1 安装实测定位到发起 TCP connect 阶段 errno=1；Wi-Fi 与蜂窝策略均允许。未捕获到明确的系统拒绝规则，因此具体原因仍未确认。

Sources/SRARelay.m 新增实验性通道：SpringBoard 在运行时定位 SideStore 容器，在其 tmp 内建立 Unix socket；核对客户端进程路径后，仅向本机回环 62078 或 49152 以上端口连接，通过 SCM_RIGHTS 交付已连接描述符。SideStore 中 Hook connect，仅处理配置的本机地址和回环地址，其他连接保持原实现。不改 SideStore 的账号、配对文件或签名校验。转发准备和服务均在后台队列执行。

已通过 sh -n apelin/build.sh；本机构建停在 SDKROOT 缺失，尚未进入 Objective-C 编译。当前设备无已注册工具链或 SDK，可选工具链均要求设备缺少的 FEAT_LRCPC。本改动将通过 GitHub Actions 获取编译诊断；设备安装和实际续签验证仍待进行。

待验证：双目标编译及链接；SpringBoard 创建容器内监听的权限；SideStore 的 Unix socket 连接及描述符接收权限；后端是否经过被 Hook 的 connect、动态服务端口是否落在允许范围；Minimuxer 启动、配对和真实签名有效期。当前端口范围是实验假设，尚未证实覆盖所有设备服务。收到描述符仍不证明应用读写或续签成功。应用容器变化后要求重启 SpringBoard。

## 原 socket 连接修补（2026-11-27）

第 12 次构建 ee2d5da 已安装：SideStore 控制台确认 hook-ready，62078 的 IPC 与描述符置换均返回成功，但随后心跳 Broken pipe、首次心跳 10 秒超时；尚未证明续签成功。

本轮移除客户端 dup2 置换，改由 SideStore 通过 SCM_RIGHTS 传出原始未连接 socket，SpringBoard 校验后在同一个 socket 上连接回环目标，仅返回连接结果。这样保留原 socket 的身份、选项及已有事件注册；旧版置换可能影响异步后端事件绑定，这是待实测的原因假设。客户端还会核对连接端点和描述符标志，成功阶段为 connected-original。协议标记升级为 SRA2，避免新旧方式静默混用。

安装新包后必须重启 SpringBoard 并重新启动 SideStore，使两端协议一起更新；再核对 connected-original、心跳、Minimuxer 和签名有效期。若原 socket 的跨进程连接被系统限制，记录真实错误，不能把编译成功当作通信成功。

第 13 次构建 706a50e 已安装实测：62078 返回 connected-original / errno=0，心跳仍报告 early eof。保留原 socket 并未解决断开，尚无证据将失败归因于配对文件或 TLS。

当前新增限量读写诊断：仅观察成功转发的 socket，每连接最多记录前八次 read/write/recv/send 及向量调用，另记录 close；包含连接编号、操作、返回字节数和 errno，不读取或输出请求正文、配对信息或 TLS 内容。调用保持原结果和 errno，并有线程递归保护。诊断本身不是续签修复，需新版安装后确定首次失败操作。

## 保留本机接口地址（2026-11-27，待安装实测）

第 15 次构建 12c86c7 已安装：心跳连接先发送 4 与 329 字节，接收返回 0，随后发送 4 与 419 字节，接收仍为 0，最终 early eof。旧诊断未记录请求接收长度，单凭该日志不足以确定对端关闭原因。

独立进程以相同的四字节大端长度头和只读 GetValue / ProductVersion 请求对照：回环 62078 的读取报 Connection reset by peer；应用现有设备地址 62078 返回四字节响应头 00 00 01 48。该对照提示强制回环改写是当前失败的候选原因，尚未验证 SpringBoard 及 SideStore 的完整会话。

协议升级为 SRA3，传递运行时配置的设备地址；SpringBoard 仅允许当前已启用本机 IPv4 接口地址，保留端口和对端进程校验，在原 socket 上连接该地址。客户端校验实际端点与请求一致。不将测试地址硬编码进源码。安装后需重启 SpringBoard 并重启 SideStore，核对两端协议、新构建标记、心跳、Minimuxer 及签名有效期。

0.1.3 工作区修补：连接地址选择从仅 en0 扩展为 en0 优先、pdp_ip* 蜂窝接口回退；仍不持久化改写 SideStore 配置，保留配对和服务校验。每次探测重新枚举当前地址并要求与启动时一致，网络切换后需重启 SideStore。尚未云构建、安装或验证蜂窝续签。

## 自动切换网络（0.1.4，待安装验证）

每次新建本机服务连接时重新枚举 en0 / pdp_ip*，Wi-Fi 优先、蜂窝回退。SideStore 启动时缓存的地址仅作中继识别入口；实际目标使用当次选中的本机地址，并由 SpringBoard 再校验其属于当前接口。续签前探测不再因启动地址变化而要求重启。未重复安装 hook，未调用未经确认的 Swift 私有重置接口。

此逻辑在下一次新建连接时生效，不迁移正在使用的 TCP/TLS 会话，也不自动重放刷新请求。网络切换期间的已有会话可能失败；后端是否自行重连、IPv4 缺失的蜂窝网络、双向切换和真实签名有效期均需设备验证。

## 构建和安装
工作区保留 external 类型，入口 apelin/build.sh。本机通过 apelin_project_build 构建；用户指定的 GitHub Actions 云构建通过 .github/workflows/build.yml 调用同一脚本，使用 macOS Xcode SDK，分别输出 roothide 与 rootless 的 deb 和 SHA-256 校验文件。推送 main 或手动运行工作流即可构建，在 Actions 对应运行的 Artifacts 下载。云端包不属于 Apelin 本机构建产物，需用户通过包管理器安装。
编译需注册的兼容工具链与 SDK，脚本使用构建提供的 SDKROOT、APELIN_* 变量，不持久化 bootstrap 实际路径。
roothide 与 rootless 均编译 arm64 与 arm64e 后合并，并在签名前校验两种切片；设置 bundle 通过 Vendor 的最小 Preferences 声明链接。
包内安装 tweak、过滤器和 PreferenceLoader 设置入口，依赖 mobilesubstrate、preferenceloader。
包标识已确定为 com.xx.autosidestore，作者和维护者为 xx；包内偏好域为同名标识，设置 bundle 使用 com.xx.autosidestore.preferences。

## 已做检查

- sh -n apelin/build.sh 通过。
- Root.plist 经 icli fs plist 原生解析成功，七个独立星期选项存在。
- apelin_project_build 失败：SDKROOT 未设置，未到 Objective-C 编译阶段。

当前发布版本为 0.2.3，包标识为 com.xx.autosidestore，作者和维护者为 xx。

安装版 SideStore 日志包含 `CellularRefreshManager` 的 `Wi-Fi is active, skipping turnOff shortcut` 分支。0.2.3 的 `Sources/SRACellular.m` 改 hook Network.framework 的 C 接口 `nw_path_uses_interface_type`；0.2.2 曾因 Swift `NWPath` 值类型方法 ABI 不匹配而令 SideStore 崩溃，故不再用 Swift wrapper hook。蜂窝路径仅在刷新策略中按 Wi‑Fi 分类；实际路由、socket、配对和签名校验不改动。新实现仍待云构建和设备运行时验证。

当前 0.2.3 已改用 Network.framework C 接口 hook；仍需云构建、加载和 iOS 16 运行时验证，并核对实际签名有效期。

1. 获得兼容编译环境，处理编译错误和警告并生成构建产物。
2. 安装并确认 SpringBoard、SideStore 中的构建加载标记。
3. 检查设置页、时间保存和星期多选，重开设置后值保持。
4. 用一分钟后的计划验证触发、无重复、关闭开关后停止。
5. 验证锁屏延后、解锁补执行、跨午夜和时区变化。
6. 手动执行并比较 SideStore 我的应用中的签名有效期；验证失败状态不误报完成。
