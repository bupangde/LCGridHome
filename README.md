# LCGridHome

把 LiveContainer（dompling LC-SS 分支）宿主主页的 App 列表换成桌面式 **4 列图标网格**：点图标直接启动，长按出 LC 原装菜单。独立 dylib，走 LC 的宿主 UI 插件机制（`LCLoadTweaksToSelf`）加载，不改 LC 本体；做法是扫描 LC 的 App 目录，把网格同层内嵌进 App 标签页替换列表区域，顶栏与底栏保持原生。

## 功能

- 排序跟随 LC 偏好（默认/字母/反字母/最近启动/安装日期/自定义拖拽），下拉刷新、顶部搜索；隐藏 App 不进网格
- 长按借用原列表横幅本人的上下文菜单，末尾附「回原列表管理」；借不到时退回复刻子集
- 图标角标与 LC 横幅同规格：JIT 紫底闪电、32 位蓝底「32」、锁定橙底白锁、共享橙底回箭头；容器异常等真问题才拦启动并提示原因
- 锁定 App 点开先做系统认证（本次运行只问一次）；JIT App 复刻原版 askForJIT +「等待JIT」页，含 StikDebug / StosDebug 的 LC 变体启用器
- 深色图标走 LC 的 `iconIsDarkIcon:`，跟随「深色图标」开关；只有 Assets.car 的 App 也有真图标
- 读 LC「源」页自加的 AltStore 源做更新提醒：图标角标 + 顶栏横幅 + 更新列表，点更新走 LC 自己的安装流程
- 启动前先补签再分发；新装 App 可在网格直接建默认容器打开；卸载补齐第二道「删除数据」弹窗（借用菜单在网格里过不了 LC 的呈现守卫）
- 多任务按 LC 全局开关与每 App 指定走；与 LCFloatingMenu 共存时，其全屏多任务开启则委托 `LCOrbitGuestService` 启动

## 安装

1. 把 `LCGridHome.dylib` 放进 LC 私有 `Documents/Tweaks` 根目录；
2. 在 LC 的「模块/Tweaks」页用 Sign All Tweaks 给它签名；
3. LC 设置里连点版本号 5 次打开开发者选项，开启 **Load Tweaks to LiveContainer Itself**；
4. 完全退出 LC 再重开。

> 注意：该开关会把私有 Tweaks 根目录里**所有** dylib 加载进宿主 UI，不兼容的会让 LC 闪退；起不来时用 iOS「文件」进 LC 的 `Documents/Tweaks` 删掉这个 dylib 即可恢复。

## 构建

自己重编需用官方 LLVM 的 clang + ld64.lld 手工两步链接（`-fixup_chains` + `-adhoc_codesign`）——zig 内置 lld 的产物结构与苹果 ld64 不同，会被 LC 的签名工具签出无效签名。源码单文件 `LCGridHome.m`，无第三方依赖（纯 ObjC + 运行时调用）。

## 卸载

删掉 LC 私有 `Documents/Tweaks` 里的 `LCGridHome.dylib`，重开 LC。
