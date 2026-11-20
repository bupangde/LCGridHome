# LCGridHome

把 LiveContainer 宿主主页的 App 列表（每个 App 一整栏）换成桌面式图标网格：**一行 4 个，只显示图标 + 名称**，点图标直接启动。和 LCFloatingMenu 一样是独立 dylib，走 LC 的宿主 UI 插件机制加载，不改 LC 本体。

## 原理（先说清，免得期望错位）

LC 的主页是 SwiftUI 写的（`LCAppListView` 里 ScrollView + LazyVStack 逐行排 banner），SwiftUI 的布局没法靠 hook 在原地改成网格。所以这个插件的做法是**同层内嵌替换**：

- dylib 被加载进 LC 宿主进程后，确认自己在宿主 UI（不是 Guest）里；
- 直接扫描 LC 的 App 目录（私有 `Documents/Applications` + 共享 AppGroup 的 `LiveContainer/Applications`，读每个 `.app` 的 `LCAppInfo.plist` / `Info.plist`）拿到全部已装 App；
- 沿视图层级从 App 横幅找到 App 标签页的托管控制器，把网格作为子控制器**内嵌进标签页、直接替换列表区域**——LC 底部的标签栏、顶栏、多任务窗口与 Dock 的层级全部保持原生，没有模态盖屏；只有找不到内嵌位置时才退回全屏模态展示；
- 点图标启动前先补签（见下），再走 LC 自己的启动入口，与 LCOrbit/LCFloatingMenu 在宿主里切换 Guest 是同一条路，经典模式、多容器 UUID 都按 LC 的数据来；
- 长按任意 App，菜单末尾有「回原列表管理」，点它回到 LC 原界面——安装 App、App 设置、排序、隐藏 App 解锁这些管理操作都还在原列表里，网格不碰；此时会出现一个小悬浮按钮，点它切回网格。

## 功能

- 4 列图标网格（iPad/横屏按宽度自动加列），图标下两行名称，支持深色模式
- **排列顺序与原列表一致**：读 LC 自己的排序偏好（默认/字母/反字母/最近启动/安装日期/自定义拖拽顺序，存在 AppGroup suite 里），原列表怎么排网格就怎么排；用 LC 顶部菜单改排序时，网格检测到偏好变化会自动跟着重排。刷新靠下拉（无刷新按钮）
- **长按菜单与原列表一致**：直接借用原列表横幅本人的上下文菜单（容器切换、打开数据文件夹、反模式启动、添加到主屏幕、设置、卸载全是 LC 原装动作），并在末尾追加一条「回原列表管理」；网格滚动时会把原列表的滚动位置同步过来，确保要长按的 App 的横幅已被 LC 实现出来；极少数借不到时退回一个复刻子集（数据文件夹/反模式启动/添加到主屏幕子集/回原列表管理）
- 启动已预热：宿主一就绪就在后台完成扫描与图标解码（图标预先缩到展示尺寸），网格按标签结构提前就位；窗口出现时先盖一层同色遮罩、网格嵌好后淡出，原列表不再闪现
- 顶部搜索（按名称 / Bundle ID 过滤）、下拉刷新、「刷新」按钮重扫目录
- 点图标直接启动；长按出菜单：启动 / 复制 Bundle ID / 回原列表管理
- 悬浮按钮只在原列表模式下出现（可拖动、吸边），点它切回网格；**长按悬浮按钮**切换「打开 LC 自动显示网格」开关（默认开）
- 点图标启动前会先调 LCAppInfo 的补丁+重签（与原列表启动时 signApp 一步等价），签名过期、补丁版本旧的应用会在网格里就地修好再启动，不必先回原列表跑一次；「正在准备」提示只在补签超过约 0.35 秒时才出现，健康 App 是瞬间空转、直接启动，没有多余转场
- 隐藏 App 不进网格；其他不能安全快捷启动的 App（容器异常、文件不完整等）图标会变淡并带感叹号角标，点它只提示原因、请回原列表处理，不会硬启（判定口径与 LCOrbit 的 `LCOrbitGuestService` 一致）
- **JIT / 锁定 App 与原列表一致**（v24）：图标右下角有角标——JIT 是紫底白色闪电、32 位是蓝底「32」、锁定是橙底白锁（规格与颜色同 LC 横幅角标）。这类 App 在网格里可以直接打开：锁定的点开先弹系统认证（面容/指纹/密码，本次 LC 运行内只认证一次）；JIT 的经典启动会先按 LC 设置的启用方式（SideJITServer / JitStreamer-EB / StikDebug / StosDebug / SideStore，含 LC 变体）联系启用器，再出「等待JIT」页，启用完点「启动」打开；多任务 JIT（iOS 17.4+）是窗口起来后自动打开带 pid 的启用链接
- **深色图标**（v24）：图标改走 LC 自己的 `-[LCAppInfo iconIsDarkIcon:]` 取图，LC 设置里的「深色图标」开关在网格里同样生效（切换时自动清缓存重取），与原列表显示同一张图；只有 Assets.car 的 App 也能显示真图标，不再是占位图
- **源更新提醒**（v25）：读 LC「源」页里你自己添加的源，宿主启动后与下拉刷新时自动拉取比对（半小时内不重复拉）；有新版的 App 图标右上角有蓝底上箭头角标，顶栏下方出「有 N 个 App 可更新」横幅，点横幅进列表、点「更新」即走 LC 自己的安装流程（与在「源」页点安装等价）
- 内置 SideStore（LC+SS 构建）会作为一项出现在网格里

## 构建

**已有编译好的 `LCGridHome.dylib`**（同目录，arm64）。签名/加载问题已定版（v1.0.3）：根因是 zig 内置 lld 的产物结构与苹果 ld64 不同——经典 DYLD_INFO 绑定、各段 filesize 不齐、签名靠事后追加且落在 `__LINKEDIT` 声明范围之外，LC 的签名工具（ZSign 系）对这种文件签出的结果被 dyld 判为无效（先报「无法签名」，后报 code signature invalid）。定版构建改用官方 LLVM 的 clang + ld64.lld 手工链接，与 LCFloatingMenu 的 build.sh 同路：`-fixup_chains`（LC_DYLD_CHAINED_FIXUPS + EXPORTS_TRIE）+ `-adhoc_codesign`（链接器自带 ad-hoc 签名，落在 `__LINKEDIT` 范围内、flags 带 LINKER_SIGNED），产物已验：Mach-O arm64、只链接系统框架、签名逐页哈希自洽。导入 LC 后照常 Sign All Tweaks 换成 LC 证书即可。

自己重编（可选）：Mac + theos `make` 即可；或用 Xcode 建 iOS dylib target，把 `LCGridHome.m` 单文件加进去（无第三方依赖，纯 ObjC + 运行时调用）。

## 安装（与 LCFloatingMenu 的宿主模式相同）

1. 在 LC 的「模块/Tweaks」页把 `LCGridHome.dylib` 放进**顶层私有** `Documents/Tweaks` 根目录（不是某个 Guest 的命名文件夹）；
2. 用 Tweaks 页的签名功能给它签名（Sign All Tweaks）；
3. LC 设置里连点版本号 5 次打开开发者选项，开启 **Load Tweaks to LiveContainer Itself**（`LCLoadTweaksToSelf`）；
4. 完全退出 LC 再重开。打开后 App 标签页应直接是网格主页（顶部菜单与底部标签栏照常在），长按任意 App、菜单末尾「回原列表管理」可切回。

> 注意：开发者选项会把私有 Tweaks 根目录里**所有** dylib 都加载进宿主 UI，不兼容的会让 LC 闪退。装之前留好原文件备份；万一 LC 起不来，用 iOS「文件」进 LC 的 Documents/Tweaks 删掉这个 dylib 即可恢复。

## 已知限制

- **已编译但未经真机验证**：dylib 已成功构建并做过二进制层面的校验（架构、链接库、类与方法、关键接口字符串都在），接口名与数据格式都对着 dompling 的 `lcss-original` 分支（commit db034b9）源码核过；但还没在真机上跑过，第一次装若有问题（不显示、闪退），按上面的办法删掉 dylib 即可恢复，再把现象发我修。
- 图标走 LC 自己的取图接口（v24 起）；万一某个 App 在 LC 里取图失败，网格会退回读 `.app` 内的 `AppIcon*.png`，再取不到才显示「首字 + 底色」占位图。LC 变体启用器（StosDebugLC/StikJITLC）按原版处理：经典流程把启用链接递给空闲 LC 打开，多任务流程把带 pid 的链接作为启动 URL、在当前多任务会话里把 LC 内那个 Guest 本人拉起来消费。
- 与 LCFloatingMenu 共存兼容：检测到它且其「全屏多任务」开着时，启动（含已运行窗口的调前台）委托给它的 LCOrbitGuestService，与悬浮菜单自己的行为一致；它不在场或没开多任务时，用 LC 原生接口。
- 多任务（虚拟窗口）同样接管，且启动模式与原列表完全同口径：跟着 LC 多任务设置里的「自动以多任务模式启动」全局开关和每个 App 自己的多任务指定（MultitaskSpecified）走，开了就开成窗口、没开就经典启动；已有多任务窗口在跑时新 App 也进多任务。网格内嵌在标签页里、层级低于多任务窗口，App 窗口会自然盖住网格（和盖住原列表一样），关掉窗口就回到网格。已经在窗口里运行的 App 点一下会直接把它的窗口调到前台（与原列表行为一致）。两个例外：标记为经典兼容模式的 App 在多任务下点会提示回原列表启动；被其他 LC 实例占用的 App 只能提示、切不回来。内置 SideStore 始终走经典启动。
- 网格顺序按名称排序，与原列表的自定义排序不联动。
- 与 LCFloatingMenu 可共存（类名前缀不同），但两个都开自动呈现时以先呈现的为准，关掉其中一个的自动显示即可。

## 卸载

删掉 LC 私有 `Documents/Tweaks` 里的 `LCGridHome.dylib`，重开 LC。
