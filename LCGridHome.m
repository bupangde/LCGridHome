// LCGridHome.m
// 把 LiveContainer 宿主主页的 App 列表换成桌面式图标网格（默认 4 列）。
//
// 实现方式（不改 LC 本体、不动 SwiftUI 列表本身）：
//   本 dylib 由 LC 的开发者选项 LCLoadTweaksToSelf 加载进宿主 UI 进程后，
//   扫描 LC 的 Applications 目录拿到全部已装 App，并把网格控制器内嵌进
//   App 标签页的托管控制器——与原列表同层、直接替换呈现，LC 的标签栏、
//   多任务窗口层级都保持原生（找不到内嵌位置时退回全屏模态展示）。点图标先调 LCAppInfo 的
//   patchExecAndSignIfNeed（与 LC 原列表 runApp 里 signApp 一步等价，
//   负责补丁与重签），完成后再按模式分发启动：单任务走
//   +[LCSharedUtils launchToGuestAppWithURL:]，多任务（虚拟窗口）走
//   +[LCUtils launchMultitaskGuestApp:completionHandler:]（两条路与
//   LCOrbit/LCFloatingMenu 在宿主里切换 Guest 用的相同）。
//   少了补签这一步时，证书轮换后签名过期的 Guest 会在 dlopen 时报
//   code signature invalid。原列表随时可切回，管理类操作
//   （安装、设置、长按菜单）仍走原列表。
//
// v24 起与原列表对齐的三件事：
//   - 图标角标：JIT（紫底闪电；32 位时蓝底「32」）、锁定（橙底锁）按
//     LCAppInfo.plist 的 isJITNeeded/is32bit/isLocked 显示，与横幅同规格；
//   - 这类 App 可直接打开：锁定先走 LAContext 系统认证（本次运行内只
//     认证一次）；JIT 经典启动复刻 LCUtils.askForJIT + 等待页（按
//     LCJITEnablerType 联系 SideJITServer/JitStreamer/StikDebug/
//     StosDebug/SideStore，多任务 JIT 走 17.4+ 的 pid 启用链接）；
//   - 图标改走 -[LCAppInfo iconIsDarkIcon:] 取图，LC 设置里的深色图标
//     开关（AppGroup 偏好 darkModeIcon）在网格里同样生效，切换时自动
//     清缓存重取；只有 Assets.car 的 App 也因此能显示真图标。
//
// v25 起读 LC「源」页用户自加的源（宿主偏好 LCAltStoreSourceURLs）做
// 更新提醒：宿主启动与下拉刷新时拉源 JSON、按 Bundle ID 与已装版本
// 比对，可更新的 App 图标右上角有蓝底上箭头角标、顶栏下方出横幅；
// 点横幅进列表，点「更新」发 LC 自己的 InstallAppNotification 走它
// 的安装流程（与在「源」页点安装等价）。
//
// 宿主识别、App 扫描与可启动判定参照 dompling/LC-SS-widget-export
// （AGPL-3.0）中 LCOrbitGuestService / LCOrbitHost 的公开接口事实重写：
//   - NSUserDefaults 的 LC 分类类方法：lcUserDefaults / lcMainBundle /
//     lcAppGroupPath / lcAppUrlScheme / guestAppInfo
//   - 环境变量 LC_HOME_PATH；私有根 Documents/Applications，
//     共享根 <AppGroup>/LiveContainer/Applications
//   - 每个 .app 文件夹内 LCAppInfo.plist + Info.plist
//   - 启动 URL：<scheme>://livecontainer-launch?bundle-name=<文件夹名>
//     &container-folder-name=<容器UUID>
//
// 纯 Objective-C + 运行时调用，无 Logos 依赖，theos 或 Xcode 均可编译。

#import <UIKit/UIKit.h>
#import <LocalAuthentication/LocalAuthentication.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <stdlib.h>

#pragma mark - 小工具

static id LGClassCall(Class cls, NSString *name) {
    SEL sel = NSSelectorFromString(name);
    if (!cls || ![cls respondsToSelector:sel]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(cls, sel);
}

static NSString *LGString(id v) { return [v isKindOfClass:NSString.class] ? v : nil; }
static BOOL LGFlag(id v) { return [v respondsToSelector:@selector(boolValue)] && [v boolValue]; }
static NSInteger LGNumber(id v) { return [v respondsToSelector:@selector(integerValue)] ? [v integerValue] : 0; }

static NSUserDefaults *LGHostDefaults(void) {
    id d = LGClassCall(NSUserDefaults.class, @"lcUserDefaults");
    return [d isKindOfClass:NSUserDefaults.class] ? d : NSUserDefaults.standardUserDefaults;
}

// LC 的排序偏好存在 AppGroup suite 里（LCUtils.appGroupUserDefault），
// lcUserDefaults 不一定是同一个 suite——直接按组 ID 开 suite 读才准。
static NSUserDefaults *LGAppGroupDefaults(void) {
    NSString *gid = LGString(LGClassCall(NSClassFromString(@"LCSharedUtils"), @"appGroupID"));
    if (gid.length) {
        NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:gid];
        if (d) return d;
    }
    return LGHostDefaults();
}

// 只在 LC 宿主 UI 里激活：在 Guest 里 guestAppInfo 非空，直接退出一切安装。
static BOOL LGIsHostUI(void) {
    if (LGClassCall(NSUserDefaults.class, @"guestAppInfo")) return NO;
    if (![LGHostDefaults() boolForKey:@"LCLoadTweaksToSelf"]) return NO;
    NSBundle *main = LGClassCall(NSUserDefaults.class, @"lcMainBundle");
    if (![main isKindOfClass:NSBundle.class]) return NO;
    if (![main.bundlePath isEqualToString:NSBundle.mainBundle.bundlePath]) return NO;
    if (!NSClassFromString(@"LCSharedUtils")) return NO;
    return YES;
}

#pragma mark - App 扫描

static BOOL LGValidComponent(NSString *v) {
    return LGString(v).length && ![v isEqualToString:@"."] && ![v isEqualToString:@".."] &&
           [v isEqualToString:v.lastPathComponent] &&
           [v rangeOfString:@"/"].location == NSNotFound &&
           [v rangeOfString:@"\\"].location == NSNotFound;
}

// 与 LCOrbit 的判定口径一致：拿不准能不能安全快捷启动的，标记原因、
// 只提示去原列表启动，不硬启。
static NSString *LGContainerUUID(NSDictionary *lc, NSString **reason) {
    NSString *uuid = LGString(lc[@"LCDataUUID"]);
    if (uuid.length && LGValidComponent(uuid)) return uuid;
    id raw = lc[@"LCDataUUID"];
    if (raw && (!uuid || uuid.length)) { *reason = @"invalid-container"; return @""; }
    NSMutableSet<NSString *> *choices = [NSMutableSet set];
    id containers = lc[@"LCContainers"];
    if ([containers isKindOfClass:NSArray.class]) {
        for (id entry in containers) {
            if (![entry isKindOfClass:NSDictionary.class]) continue;
            NSString *name = LGString(entry[@"folderName"]);
            if (LGValidComponent(name)) [choices addObject:name];
        }
    }
    if (choices.count == 1) return choices.anyObject;
    *reason = choices.count ? @"select-container" : @"missing-container";
    return @"";
}

static NSString *LGStatusText(NSString *reason) {
    NSDictionary *labels = @{@"needs-jit": @"需要 JIT",
        @"manual-signing": @"请从 LC 启动", @"loader-disabled": @"插件未启用",
        @"loader-unavailable": @"插件不可注入", @"missing-executable": @"文件不完整",
        @"invalid-container": @"容器异常", @"missing-container": @"缺少容器",
        @"select-container": @"需选择容器", @"private-name-conflict": @"同名冲突",
        @"locked": @"已锁定"};
    return labels[reason] ?: @"";
}

// 排序与原列表完全同口径：读 LC 自己的排序偏好（AppGroup 偏好里的
// LCAppSortType / LCCustomSortOrder），逐项复刻 LCAppSortManager 的规则。
// 列表传入时是扫描原始顺序（私有目录序 + 共享目录序），「默认」即原样。
static NSArray<NSDictionary *> *LGApplyLCSort(NSMutableArray<NSDictionary *> *list) {
    NSUserDefaults *defs = LGAppGroupDefaults();
    NSString *type = [defs stringForKey:@"LCAppSortType"];
    if (!type) type = [LGHostDefaults() stringForKey:@"LCAppSortType"];
    if (!type) type = [NSUserDefaults.standardUserDefaults stringForKey:@"LCAppSortType"];
    if (!type.length || [type isEqualToString:@"default"]) return list;

    NSComparator byTitleAsc = ^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        NSComparisonResult r = [a[@"title"] localizedStandardCompare:b[@"title"]];
        return r == NSOrderedSame ? [a[@"folder"] compare:b[@"folder"]] : r;
    };
    if ([type isEqualToString:@"alphabetical"]) {
        [list sortUsingComparator:byTitleAsc];
        return list;
    }
    if ([type isEqualToString:@"reverse_alphabetical"]) {
        [list sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
            NSComparisonResult r = [b[@"title"] localizedStandardCompare:a[@"title"]];
            return r == NSOrderedSame ? [a[@"folder"] compare:b[@"folder"]] : r;
        }];
        return list;
    }
    if ([type isEqualToString:@"last_launched"] || [type isEqualToString:@"installationDate"]) {
        NSString *key = [type isEqualToString:@"last_launched"] ? @"lastLaunched" : @"installedAt";
        NSMutableArray *withDate = [NSMutableArray array];
        NSMutableArray *without = [NSMutableArray array];
        for (NSDictionary *app in list)
            [([app[key] isKindOfClass:NSDate.class] ? withDate : without) addObject:app];
        [withDate sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
            NSComparisonResult r = [b[key] compare:a[key]]; // 新的在前
            return r == NSOrderedSame ? [a[@"folder"] compare:b[@"folder"]] : r;
        }];
        [withDate addObjectsFromArray:without];
        return withDate;
    }
    if ([type isEqualToString:@"custom"]) {
        NSArray *order = [defs arrayForKey:@"LCCustomSortOrder"];
        if (![order isKindOfClass:NSArray.class])
            order = [LGHostDefaults() arrayForKey:@"LCCustomSortOrder"];
        if (![order isKindOfClass:NSArray.class])
            order = [NSUserDefaults.standardUserDefaults arrayForKey:@"LCCustomSortOrder"];
        if (!order.count) {
            [list sortUsingComparator:byTitleAsc];
            return list;
        }
        NSMutableArray *remaining = [list mutableCopy];
        NSMutableArray *out = [NSMutableArray array];
        for (id uid in order) {
            if (![uid isKindOfClass:NSString.class]) continue;
            NSUInteger idx = [remaining indexOfObjectPassingTest:^BOOL(NSDictionary *app, NSUInteger i, BOOL *stop) {
                NSString *mine = [NSString stringWithFormat:@"%@:%@", app[@"bundle"], app[@"path"]];
                return [mine isEqualToString:(NSString *)uid];
            }];
            if (idx != NSNotFound) {
                [out addObject:remaining[idx]];
                [remaining removeObjectAtIndex:idx];
            }
        }
        [remaining sortUsingComparator:byTitleAsc];
        [out addObjectsFromArray:remaining];
        return out;
    }
    return list;
}

static NSArray<NSDictionary *> *LGScanApps(void) {
    NSMutableArray<NSDictionary *> *list = [NSMutableArray array];
    const char *raw = getenv("LC_HOME_PATH");
    NSString *home = (raw && raw[0]) ? [NSString stringWithUTF8String:raw] : nil;
    if (!home.length) return list;
    NSString *privateRoot = [home stringByAppendingPathComponent:@"Documents/Applications"];
    NSMutableArray<NSDictionary *> *roots = [NSMutableArray arrayWithObject:@{@"path": privateRoot, @"shared": @NO}];
    NSString *group = LGString(LGClassCall(NSUserDefaults.class, @"lcAppGroupPath"));
    if (group.length) {
        [roots addObject:@{@"path": [group stringByAppendingPathComponent:@"LiveContainer/Applications"], @"shared": @YES}];
    }
    NSFileManager *fm = NSFileManager.defaultManager;
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    for (NSDictionary *rootInfo in roots) {
        NSString *root = rootInfo[@"path"];
        BOOL shared = [rootInfo[@"shared"] boolValue];
        NSArray *entries = [fm contentsOfDirectoryAtPath:root error:nil];
        for (NSString *entry in entries) { // 目录原始顺序（与 LC 的扫描一致，默认排序要用）
            if (!LGValidComponent(entry) || ![entry hasSuffix:@".app"]) continue;
            NSString *folder = [root stringByAppendingPathComponent:entry];
            NSDictionary *lc = [NSDictionary dictionaryWithContentsOfFile:[folder stringByAppendingPathComponent:@"LCAppInfo.plist"]];
            if (![lc isKindOfClass:NSDictionary.class]) continue;
            if (LGFlag(lc[@"isHidden"])) continue; // 隐藏 App 不进网格（LC 里需解锁，原列表处理）
            NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[folder stringByAppendingPathComponent:@"Info.plist"]];
            if (![info isKindOfClass:NSDictionary.class]) continue;
            NSString *canonical = [[folder stringByStandardizingPath] stringByResolvingSymlinksInPath];
            if ([seen containsObject:canonical]) continue;
            [seen addObject:canonical];

            NSString *reason = @"";
            NSString *uuid = LGContainerUUID(lc, &reason);
            // 一个容器都没有（新装 App）不算不可启动：LC 原列表 runApp
            // 会在启动前现建默认容器，网格启动时照办（见启动一节）
            BOOL needsContainer = [reason isEqualToString:@"missing-container"];
            if (needsContainer) reason = @"";
            // JIT 与锁定不再算「不可启动」：JIT 走 LC 的启用流程、锁定走
            // 系统认证，都能在网格里直接打开（见启动一节）；它们只作为
            // 独立标志存下来，供图标角标与启动分发使用。
            BOOL is32 = LGFlag(lc[@"is32bit"]);
            BOOL jit = LGFlag(lc[@"isJITNeeded"]) || is32;
            // dontSign / LCTweakLoaderCantInject / dontLoadTweakLoader /
            // dontInjectTweakLoader 都不算不可启动：它们只是 LC 启动时
            // 「不签名 / 不注入 TweakLoader」的开关，LC 自己的启动路径
            // 内部会照办（LCBootstrap、LCAppInfo 源码实证），原列表能
            // 正常打开这类 App。此前照 LCOrbit 快捷启动的口径拦截是
            // 误伤（实测 iCTRL 被拦「插件未启用」、原列表可开）。
            NSString *exec = LGString(info[@"CFBundleExecutable"]);
            BOOL isDir = NO;
            if (!LGValidComponent(exec) ||
                ![fm fileExistsAtPath:[folder stringByAppendingPathComponent:exec] isDirectory:&isDir] || isDir)
                reason = @"missing-executable";
            NSString *privateFolder = [privateRoot stringByAppendingPathComponent:entry];
            if (shared && [fm fileExistsAtPath:privateFolder] &&
                ![[[privateFolder stringByStandardizingPath] stringByResolvingSymlinksInPath] isEqualToString:canonical])
                reason = @"private-name-conflict";
            BOOL locked = LGFlag(lc[@"isLocked"]);

            NSString *bundle = LGFlag(lc[@"doUseLCBundleId"]) ? LGString(lc[@"LCOrignalBundleIdentifier"]) : nil;
            if (!bundle.length) bundle = LGString(info[@"CFBundleIdentifier"]);
            NSString *title = LGString(info[@"CFBundleDisplayName"]);
            if (!title.length) title = LGString(info[@"CFBundleName"]);
            if (!title.length) title = entry.stringByDeletingPathExtension;

            // 经典兼容模式标记（口径同 LCOrbit）：多任务下这类 App 只能经典启动
            NSDictionary *classicCache = [lc[@"LCClassicModeCache"] isKindOfClass:NSDictionary.class] ? lc[@"LCClassicModeCache"] : nil;
            NSNumber *cachedMode = classicCache[@"defaultClassicMode"];
            NSNumber *cachedSystem = classicCache[@"systemMajorVersion"];
            BOOL knownMode = [cachedMode isKindOfClass:NSNumber.class] && [cachedSystem isKindOfClass:NSNumber.class]
                && cachedSystem.integerValue == (NSInteger)NSProcessInfo.processInfo.operatingSystemVersion.majorVersion;
            BOOL classicOnly = LGFlag(lc[@"classicMode"]) && (!knownMode || cachedMode.unsignedIntegerValue != 0);

            // JIT 经典启动要用的 classicMode 值（口径同 LCAppInfo 的
            // defaultClassicMode）：没开经典模式恒 0；开了且缓存有效用缓存
            // 值；缓存无效记 -1，启动时再现场算。
            NSInteger defaultClassicMode = 0;
            if (LGFlag(lc[@"classicMode"]))
                defaultClassicMode = knownMode ? (NSInteger)cachedMode.unsignedIntegerValue : -1;

            [list addObject:@{@"path": entry, @"title": title, @"uuid": uuid ?: @"",
                              @"bundle": bundle ?: @"", @"folder": folder, @"shared": @(shared),
                              @"locked": @(locked), @"builtin": @NO, @"classicOnly": @(classicOnly),
                              @"needsContainer": @(needsContainer),
                              @"jit": @(jit), @"is32": @(is32),
                              @"jitScript": LGString(lc[@"jitLaunchScriptJs"]) ?: @"",
                              @"version": LGString(info[@"CFBundleShortVersionString"]) ?: @"",
                              @"defaultClassicMode": @(defaultClassicMode),
                              @"mtSpecified": @(LGNumber(lc[@"MultitaskSpecified"])),
                              @"lastLaunched": [lc[@"lastLaunched"] isKindOfClass:NSDate.class] ? lc[@"lastLaunched"] : NSNull.null,
                              @"installedAt": [lc[@"installationDate"] isKindOfClass:NSDate.class] ? lc[@"installationDate"] : NSNull.null,
                              @"launchable": @(!reason.length), @"status": LGStatusText(reason)}];
        }
    }
    // 内置 SideStore（仅 LC+SS 构建有）
    NSBundle *main = LGClassCall(NSUserDefaults.class, @"lcMainBundle");
    if ([main isKindOfClass:NSBundle.class]) {
        NSString *ss = [main.bundlePath stringByAppendingPathComponent:@"Frameworks/SideStoreApp.framework"];
        BOOL isDir = NO;
        if ([fm fileExistsAtPath:[ss stringByAppendingPathComponent:@"LCAppInfo.plist"]] &&
            [fm fileExistsAtPath:ss isDirectory:&isDir] && isDir) {
            [list addObject:@{@"path": @"builtinSideStore", @"title": @"SideStore", @"uuid": @"builtin",
                              @"bundle": @"builtinSideStore", @"folder": ss, @"shared": @NO,
                              @"locked": @NO, @"builtin": @YES, @"classicOnly": @NO, @"needsContainer": @NO, @"mtSpecified": @0,
                              @"jit": @NO, @"is32": @NO, @"jitScript": @"", @"version": @"", @"defaultClassicMode": @0,
                              @"lastLaunched": NSNull.null, @"installedAt": NSNull.null,
                              @"launchable": @YES, @"status": @""}];
        }
    }
    return LGApplyLCSort(list);
}

#pragma mark - 源更新检查

// 读 LC「源」页用户自加的源（存在宿主 standard UserDefaults 的
// LCAltStoreSourceURLs 里，插件与宿主同进程、同容器，可直读），拉源
// JSON 与已装版本比对；结果供图标更新角标与顶栏更新横幅使用。
static NSMutableDictionary<NSString *, NSDictionary *> *LGUpdateMap; // bundleId -> 更新信息
static BOOL LGUpdateCheckRunning = NO;
static NSTimeInterval LGUpdateLastCheck = 0;
static NSString *const LGUpdatesChangedNotification = @"LGGridHomeUpdatesChanged";

// 更新状态变化的通知走两个通道：NSNotificationCenter + 网格注册的
// 直接回调。实测在 LC 里只靠通知时横幅偶尔不刷新（角标已清、横幅要
// 杀掉 LC 重启才消失），直接回调兜底保证实时对齐。
static void (^LGUpdateUIHook)(void) = nil;
static void LGNotifyUpdatesChanged(void) {
    [[NSNotificationCenter defaultCenter] postNotificationName:LGUpdatesChangedNotification object:nil];
    if (LGUpdateUIHook) LGUpdateUIHook();
}

static NSDictionary *LGUpdateForBundle(NSString *bundle) {
    return bundle.length ? LGUpdateMap[bundle] : nil;
}

static NSComparisonResult LGCompareVersion(NSString *a, NSString *b);

// 「已处理」记录：有的 App 上游发布新版却不改包内版本字符串（Asspp
// 官方 4.2.2 包实测 CFBundleShortVersionString 仍是 4.2.0），按版本
// 字符串比对会永久误报。用户点过「更新」即把该源版本记为已处理，
// 源里出现更高版本时才再提醒。
static NSMutableDictionary<NSString *, NSString *> *LGUpdateAckMap(void) {
    NSDictionary *d = [[NSUserDefaults standardUserDefaults] dictionaryForKey:@"LCGridHomeUpdateAck"];
    NSMutableDictionary *m = [NSMutableDictionary dictionary];
    if ([d isKindOfClass:NSDictionary.class]) [m addEntriesFromDictionary:d];
    return m;
}

static void LGSetUpdateAck(NSString *bid, NSString *version) {
    if (!bid.length || !version.length) return;
    NSMutableDictionary *m = LGUpdateAckMap();
    m[bid] = version;
    [[NSUserDefaults standardUserDefaults] setObject:m forKey:@"LCGridHomeUpdateAck"];
}

static BOOL LGUpdateIsAcked(NSString *bid, NSString *sourceVersion, NSDictionary *ackMap) {
    NSString *ack = bid.length ? ackMap[bid] : nil;
    return ack.length && sourceVersion.length &&
        LGCompareVersion(sourceVersion, ack) != NSOrderedDescending;
}

static NSComparisonResult LGCompareVersion(NSString *a, NSString *b) {
    NSArray<NSString *> *pa = [a componentsSeparatedByString:@"."];
    NSArray<NSString *> *pb = [b componentsSeparatedByString:@"."];
    NSUInteger n = MAX(pa.count, pb.count);
    for (NSUInteger i = 0; i < n; i++) {
        NSString *sa = i < pa.count ? pa[i] : @"0";
        NSString *sb = i < pb.count ? pb[i] : @"0";
        NSInteger na = sa.integerValue, nb = sb.integerValue;
        if (na != nb) return na < nb ? NSOrderedAscending : NSOrderedDescending;
        if (![sa isEqualToString:sb]) {
            NSComparisonResult r = [sa localizedStandardCompare:sb];
            if (r != NSOrderedSame) return r;
        }
    }
    return NSOrderedSame;
}

// 源里混着 git 哈希之类不是版本号的条目（ryP0 源实测：40 位十六进制
// 哈希、还能以数字开头，只看首字符会漏过去），只认「数字.数字…」形态
// 的版本号：主干（-/+/空格之前）必须全是数字和点、长度受限。
static BOOL LGVersionLooksReal(NSString *v) {
    if (!v.length || v.length > 24) return NO;
    NSString *core = v;
    NSRange cut = [v rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"-+ "]];
    if (cut.location != NSNotFound) core = [v substringToIndex:cut.location];
    if (!core.length || core.length > 18) return NO;
    unichar first = [core characterAtIndex:0];
    if (first < '0' || first > '9') return NO;
    for (NSUInteger i = 0; i < core.length; i++) {
        unichar c = [core characterAtIndex:i];
        if (!(c == '.' || (c >= '0' && c <= '9'))) return NO;
    }
    return YES;
}

// 解析一个源 JSON（口径同 LC 自己的加载器：versions 数组第一个有效
// 条目，否则用 App 级的旧式 version/downloadURL；相对地址按源地址解析）
static void LGParseSourceJSON(NSData *data, NSURL *baseURL, NSMutableDictionary *out) {
    id root = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![root isKindOfClass:NSDictionary.class]) return;
    NSString *sourceName = LGString(root[@"name"]) ?: baseURL.host ?: @"";
    NSArray *apps = root[@"apps"];
    if (![apps isKindOfClass:NSArray.class]) return;
    for (id entry in apps) {
        if (![entry isKindOfClass:NSDictionary.class]) continue;
        NSString *bid = LGString(entry[@"bundleIdentifier"]);
        if (!bid.length) continue;
        NSString *ver = nil, *dl = nil;
        NSArray *versions = entry[@"versions"];
        if ([versions isKindOfClass:NSArray.class]) {
            for (id ve in versions) {
                if (![ve isKindOfClass:NSDictionary.class]) continue;
                NSString *vv = LGString(ve[@"version"]);
                NSString *dd = LGString(ve[@"downloadURL"]);
                if (LGVersionLooksReal(vv) && dd.length) { ver = vv; dl = dd; break; }
            }
        }
        if (!ver) {
            NSString *vv = LGString(entry[@"version"]);
            NSString *dd = LGString(entry[@"downloadURL"]);
            if (LGVersionLooksReal(vv) && dd.length) { ver = vv; dl = dd; }
        }
        if (!ver) continue;
        NSURL *dlURL = [NSURL URLWithString:dl relativeToURL:baseURL];
        if (!dlURL) continue;
        // 同一个 App 在多个源里都有时取版本号最高的那份（连同它的下载
        // 地址）：各源并发拉取、先到先得的话，提醒按高版本比、点更新
        // 却可能装了低版本源的包，两边对不上（Asspp 双源 4.2.0/4.2.2 实测）。
        NSDictionary *keptInfo = out[bid];
        if (keptInfo && LGCompareVersion(ver, LGString(keptInfo[@"version"])) != NSOrderedDescending) continue;
        out[bid] = @{ @"version": ver, @"source": sourceName,
                      @"downloadURL": dlURL.absoluteString,
                      @"name": LGString(entry[@"name"]) ?: @"" };
    }
}

// 等待本次检查结束的回调（下拉刷新要等检查完才收刷新动画）
static NSMutableArray<void (^)(void)> *LGUpdatePendingCompletions = nil;
static void LGRunUpdateCompletions(void) {
    NSArray<void (^)(void)> *pending = LGUpdatePendingCompletions.copy;
    LGUpdatePendingCompletions = nil;
    for (void (^c)(void) in pending) c();
}

static void LGCheckForUpdatesWithCompletion(BOOL force, void (^completion)(void)) {
    if (completion) {
        if (!LGUpdatePendingCompletions) LGUpdatePendingCompletions = [NSMutableArray array];
        [LGUpdatePendingCompletions addObject:[completion copy]];
    }
    if (LGUpdateCheckRunning) return; // 已在查：它结束时一并回调
    NSTimeInterval now = NSDate.timeIntervalSinceReferenceDate;
    if (!force && LGUpdateLastCheck > 0 && now - LGUpdateLastCheck < 1800) { LGRunUpdateCompletions(); return; } // 自动检查半小时内不重复
    NSArray *urlStrings = [[NSUserDefaults standardUserDefaults] arrayForKey:@"LCAltStoreSourceURLs"];
    if (![urlStrings isKindOfClass:NSArray.class] || !urlStrings.count) { LGRunUpdateCompletions(); return; }
    LGUpdateCheckRunning = YES;
    LGUpdateLastCheck = now;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSMutableDictionary *sourceMap = [NSMutableDictionary dictionary];
        dispatch_group_t group = dispatch_group_create();
        for (id u in urlStrings) {
            NSString *us = [u isKindOfClass:NSString.class] ? u : nil;
            NSURL *url = us.length ? [NSURL URLWithString:us] : nil;
            if (!url) continue;
            dispatch_group_enter(group);
            NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithURL:url
                completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
                    if (data.length) {
                        @synchronized (sourceMap) { LGParseSourceJSON(data, url, sourceMap); }
                    }
                    dispatch_group_leave(group);
                }];
            [task resume];
        }
        dispatch_group_wait(group, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(30 * NSEC_PER_SEC)));
        NSMutableDictionary *updates = [NSMutableDictionary dictionary];
        NSDictionary *ackMap = LGUpdateAckMap();
        for (NSDictionary *app in LGScanApps()) {
            if (LGFlag(app[@"builtin"])) continue;
            NSString *bid = LGString(app[@"bundle"]);
            NSDictionary *info = bid.length ? sourceMap[bid] : nil;
            if (!info) continue;
            if (LGUpdateIsAcked(bid, info[@"version"], ackMap)) continue;
            NSString *installed = LGString(app[@"version"]);
            if (installed.length && LGCompareVersion(info[@"version"], installed) == NSOrderedDescending) {
                NSMutableDictionary *one = [info mutableCopy];
                one[@"installedVersion"] = installed;
                one[@"title"] = LGString(app[@"title"]);
                one[@"bundle"] = bid;
                updates[bid] = one;
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            LGUpdateMap = updates;
            LGUpdateCheckRunning = NO;
            LGNotifyUpdatesChanged();
            LGRunUpdateCompletions();
        });
    });
}

static void LGCheckForUpdates(BOOL force) {
    LGCheckForUpdatesWithCompletion(force, nil);
}

#pragma mark - 图标

static NSCache<NSString *, UIImage *> *LGIconCache(void) {
    static NSCache *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSCache new]; });
    return cache;
}

// LC 设置里的「深色图标」开关（AppGroup 偏好 darkModeIcon）：原列表按它
// 在浅色/深色图标间二选一，网格跟随同一开关。
static BOOL LGDarkIconEnabled(void) {
    return [LGAppGroupDefaults() boolForKey:@"darkModeIcon"];
}

static NSString *LGIconCacheKey(NSDictionary *app) {
    return [NSString stringWithFormat:@"%@#%@", app[@"folder"], LGDarkIconEnabled() ? @"d" : @"l"];
}

// 优先走 LC 自己的取图 -[LCAppInfo iconIsDarkIcon:]：它内部用 IconServices
// 按浅/深风格渲染（含 Assets.car）并把结果落盘缓存成 LCAppIconLight/Dark.png，
// 与原列表显示的是同一张图——深色开关因此在网格里同样生效，只有
// Assets.car 的 App 也能拿到真图标而不是占位图。
static UIImage *LGIconViaLCAppInfo(NSDictionary *app, BOOL dark) {
    Class cls = NSClassFromString(@"LCAppInfo");
    SEL initSel = NSSelectorFromString(@"initWithBundlePath:");
    SEL iconSel = NSSelectorFromString(@"iconIsDarkIcon:");
    if (!cls || ![cls instancesRespondToSelector:iconSel]) return nil;
    static NSLock *lock;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ lock = [NSLock new]; });
    UIImage *image = nil;
    [lock lock]; // 取图会往 .app 里写缓存文件，串行化避免并发写同一文件
    @try {
        id info = ((id (*)(id, SEL, NSString *))objc_msgSend)([cls alloc], initSel, app[@"folder"]);
        if (info) image = ((id (*)(id, SEL, BOOL))objc_msgSend)(info, iconSel, dark);
    } @catch (NSException *e) { image = nil; }
    [lock unlock];
    return [image isKindOfClass:UIImage.class] ? image : nil;
}

// 兜底取图：.app 文件夹内的落地 PNG（解密包通常都有 AppIcon*.png）。
static UIImage *LGIconForApp(NSDictionary *app) {
    NSString *folder = app[@"folder"];
    NSString *cacheKey = LGIconCacheKey(app);
    UIImage *cached = [LGIconCache() objectForKey:cacheKey];
    if (cached) return cached;
    UIImage *image = LGIconViaLCAppInfo(app, LGDarkIconEnabled());
    NSFileManager *fm = NSFileManager.defaultManager;
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[folder stringByAppendingPathComponent:@"Info.plist"]];
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    id icons = info[@"CFBundleIcons"];
    id primary = [icons isKindOfClass:NSDictionary.class] ? icons[@"CFBundlePrimaryIcon"] : nil;
    id files = [primary isKindOfClass:NSDictionary.class] ? primary[@"CFBundleIconFiles"] : nil;
    if ([files isKindOfClass:NSArray.class]) for (id f in files) if ([f isKindOfClass:NSString.class]) [names addObject:f];
    if ([info[@"CFBundleIconFiles"] isKindOfClass:NSArray.class])
        for (id f in info[@"CFBundleIconFiles"]) if ([f isKindOfClass:NSString.class]) [names addObject:f];
    if (LGString(info[@"CFBundleIconFile"]).length) [names addObject:info[@"CFBundleIconFile"]];

    if (!image) {
        NSArray<NSString *> *suffixes = @[@"@3x.png", @"@2x.png", @"@3x~ipad.png", @"@2x~ipad.png", @".png"];
        for (NSString *base in names) {
            NSString *stem = [base hasSuffix:@".png"] ? [base substringToIndex:base.length - 4] : base;
            for (NSString *suf in suffixes) {
                NSString *p = [folder stringByAppendingPathComponent:[stem stringByAppendingString:suf]];
                if ([fm fileExistsAtPath:p]) { image = [UIImage imageWithContentsOfFile:p]; if (image) break; }
            }
            if (image) break;
        }
    }
    if (!image) { // 兜底：扫 AppIcon*.png 取体积最大的
        NSString *best = nil; unsigned long long bestSize = 0;
        for (NSString *f in [fm contentsOfDirectoryAtPath:folder error:nil]) {
            if (![f hasPrefix:@"AppIcon"] || ![f hasSuffix:@".png"]) continue;
            unsigned long long size = [[fm attributesOfItemAtPath:[folder stringByAppendingPathComponent:f] error:nil] fileSize];
            if (size > bestSize) { bestSize = size; best = f; }
        }
        if (best) image = [UIImage imageWithContentsOfFile:[folder stringByAppendingPathComponent:best]];
    }
    if (image) {
        // 缩到展示尺寸（62pt @3x）并在后台强制解码再缓存：原始 AppIcon 常有
        // 1024px，不处理的话贴图时在主线程解码，图标会逐个弹出、滚动也卡。
        CGFloat maxDim = 186;
        CGFloat scale = MIN(1.0, maxDim / MAX(image.size.width, image.size.height));
        CGSize size = CGSizeMake(MAX(1, floor(image.size.width * scale)), MAX(1, floor(image.size.height * scale)));
        UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size];
        UIImage *raw = image;
        image = [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
            [raw drawInRect:CGRectMake(0, 0, size.width, size.height)];
        }];
        [LGIconCache() setObject:image forKey:cacheKey];
    }
    return image;
}

static UIImage *LGPlaceholderIcon(NSString *title) {
    NSString *key = [@"ph:" stringByAppendingString:title ?: @""];
    UIImage *cached = [LGIconCache() objectForKey:key];
    if (cached) return cached;
    CGFloat s = 180;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(s, s)];
    NSUInteger hash = title.hash;
    UIColor *color = [UIColor colorWithHue:(hash % 360) / 360.0 saturation:0.45 brightness:0.75 alpha:1];
    NSString *letter = title.length ? [title substringToIndex:1] : @"?";
    UIImage *image = [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        [color setFill];
        [ctx fillRect:CGRectMake(0, 0, s, s)];
        UIFont *font = [UIFont systemFontOfSize:84 weight:UIFontWeightSemibold];
        NSDictionary *attrs = @{NSFontAttributeName: font, NSForegroundColorAttributeName: UIColor.whiteColor};
        CGSize size = [letter sizeWithAttributes:attrs];
        [letter drawAtPoint:CGPointMake((s - size.width) / 2, (s - size.height) / 2) withAttributes:attrs];
    }];
    if (image) [LGIconCache() setObject:image forKey:key];
    return image;
}

#pragma mark - 启动

static void LGShowAlert(UIViewController *host, NSString *title, NSString *message) {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [host presentViewController:alert animated:YES completion:nil];
}

#pragma mark - 锁定认证与 JIT 启动

static BOOL LGUnlockedThisSession = NO;

// 锁定 App 的系统认证（口径同 LC 的 LCUtils.authenticateUser）：
// deviceOwnerAuthentication = 面容/指纹/锁屏密码任一；本次 LC 运行内
// 成功一次后不再重复问（LC 用 isHiddenAppUnlocked 标记同理）。
static void LGAuthenticate(NSDictionary *app, UIViewController *host, void (^proceed)(void)) {
    LAContext *ctx = [LAContext new];
    NSError *error = nil;
    if (![ctx canEvaluatePolicy:LAPolicyDeviceOwnerAuthentication error:&error]) {
        if (error) LGShowAlert(host, LGString(app[@"title"]), error.localizedDescription);
        return;
    }
    [ctx evaluatePolicy:LAPolicyDeviceOwnerAuthentication localizedReason:@"需要授权。"
                  reply:^(BOOL success, NSError *evalError) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (success) {
                LGUnlockedThisSession = YES;
                proceed();
            } else if (evalError && evalError.code != LAErrorUserCancel &&
                       evalError.code != LAErrorAppCancel && evalError.code != LAErrorSystemCancel) {
                LGShowAlert(host, LGString(app[@"title"]), evalError.localizedDescription);
            }
        });
    }];
}

// LC 设置里的 JIT 启用方式（AppGroup 偏好 LCJITEnablerType）：
// 0=SideJITServer 1=StikJIT(StikDebug) 2=JitStreamer-EB 3=StikJITLC
// 4=SideStore 5=StosDebug 6=StosDebugLC
static NSInteger LGJITEnablerType(void) {
    return [LGAppGroupDefaults() integerForKey:@"LCJITEnablerType"];
}

static void LGOpenURLString(NSString *s) {
    NSURL *url = [NSURL URLWithString:s];
    if (url) [UIApplication.sharedApplication openURL:url options:@{} completionHandler:nil];
}

// 找一个空闲的 LC scheme（口径同 LCUtils.forEachInstalledLC(isFree:)）：
// 枚举全部 LC scheme，跳过自己、跳不开的和正在占用的。
static NSString *LGFreeLCScheme(void) {
    Class utils = NSClassFromString(@"LCSharedUtils");
    NSArray *schemes = LGClassCall(utils, @"lcUrlSchemes");
    NSString *mine = LGString(LGClassCall(NSUserDefaults.class, @"lcAppUrlScheme"));
    SEL inUseSel = NSSelectorFromString(@"isLCSchemeInUse:");
    if (![schemes isKindOfClass:NSArray.class]) return nil;
    for (NSString *scheme in schemes) {
        if (![scheme isKindOfClass:NSString.class] || [scheme isEqualToString:mine]) continue;
        NSURL *url = [NSURL URLWithString:[scheme stringByAppendingString:@"://"]];
        if (!url || ![UIApplication.sharedApplication canOpenURL:url]) continue;
        if ([utils respondsToSelector:inUseSel] &&
            ((BOOL (*)(id, SEL, NSString *))objc_msgSend)(utils, inUseSel, scheme)) continue;
        return scheme;
    }
    return nil;
}

// 在已扫描的 App 里找响应指定 URL scheme 的那个（LC 变体启用器要用：
// 启用器本身是 LC 里的 Guest，先定位它才能把启用链接递过去）。
static NSDictionary *LGFindEnablerGuestApp(NSString *schemeName) {
    for (NSDictionary *app in LGScanApps()) {
        NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[app[@"folder"] stringByAppendingPathComponent:@"Info.plist"]];
        id types = info[@"CFBundleURLTypes"];
        if (![types isKindOfClass:NSArray.class]) continue;
        for (id t in types) {
            if (![t isKindOfClass:NSDictionary.class]) continue;
            id schemes = t[@"CFBundleURLSchemes"];
            if ([schemes isKindOfClass:NSArray.class] && [schemes containsObject:schemeName]) return app;
        }
    }
    return nil;
}

// LC 变体启用器（StikJITLC/StosDebugLC）：把启用链接 base64 后用
// <空闲LC>://open-url 递给另一个 LC 里的启用器 Guest（口径同 askForJIT）。
static void LGJITLaunchViaOtherLC(NSString *schemeName, NSString *innerURL, void (^logLine)(NSString *)) {
    NSDictionary *enabler = LGFindEnablerGuestApp(schemeName);
    NSString *display = [schemeName isEqualToString:@"stikjit"] ? @"StikDebug" : @"StosDebug";
    if (!enabler) { logLine([NSString stringWithFormat:@"%@ 没有装在 LiveContainer 里。", display]); return; }
    if (!LGFlag(enabler[@"shared"])) {
        logLine([NSString stringWithFormat:@"%@ 装在 LC 里但不是共享 App，请先把它转成共享 App。", display]);
        return;
    }
    NSString *freeScheme = nil;
    Class utils = NSClassFromString(@"LCSharedUtils");
    SEL ownerSel = NSSelectorFromString(@"getContainerUsingLCSchemeWithFolderName:");
    if ([utils respondsToSelector:ownerSel]) {
        NSString *owner = ((id (*)(id, SEL, NSString *))objc_msgSend)(utils, ownerSel, enabler[@"uuid"]);
        if (owner.length) freeScheme = owner;
    }
    if (!freeScheme) freeScheme = LGFreeLCScheme();
    if (!freeScheme) {
        logLine(@"没有空闲的 LiveContainer 可用（请先关掉一个，或改用其他 JIT 启用方式）。");
        return;
    }
    NSUserDefaults *gd = LGAppGroupDefaults();
    [gd setObject:freeScheme forKey:@"LCLaunchExtensionScheme"];
    [gd setObject:enabler[@"path"] forKey:@"LCLaunchExtensionBundleID"];
    [gd setObject:NSDate.date forKey:@"LCLaunchExtensionLaunchDate"];
    NSString *b64 = [[innerURL dataUsingEncoding:NSUTF8StringEncoding] base64EncodedStringWithOptions:0];
    logLine(@"JIT 获取将在另一个 LiveContainer 中继续。");
    LGOpenURLString([NSString stringWithFormat:@"%@://open-url?url=%@", freeScheme, b64]);
}

// 复刻 LCUtils.askForJIT 的经典（非多任务）分支：按 LCJITEnablerType
// 联系/打开对应启用器给当前 LC 进程启用 JIT；真正的 Guest 启动在用户
// 回到等待页点「启动」后才发生（与原列表 JITEnablingModal 同一节奏）。
static void LGAskForJIT(NSDictionary *app, void (^logLine)(NSString *)) {
    NSString *hostId = NSBundle.mainBundle.bundleIdentifier ?: @"";
    NSString *script = LGString(app[@"jitScript"]);
    NSString *encScript = script.length ? [script stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLQueryAllowedCharacterSet] : nil;
    NSInteger type = LGJITEnablerType();
    NSUserDefaults *gd = LGAppGroupDefaults();
    if (type == 1 || type == 3) { // StikJIT / StikJITLC
        NSMutableString *inner = [NSMutableString stringWithFormat:@"stikjit://enable-jit?bundle-id=%@", hostId];
        if (encScript) [inner appendFormat:@"&script-data=%@", encScript];
        if (type == 1) {
            logLine(@"JIT 获取将在 StikDebug 中继续。");
            LGOpenURLString(inner);
        } else {
            LGJITLaunchViaOtherLC(@"stikjit", inner, logLine);
        }
        return;
    }
    if (type == 5 || type == 6) { // StosDebug / StosDebugLC
        NSString *encName = [LGString(app[@"title"]) stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLQueryAllowedCharacterSet];
        NSMutableString *inner = [NSMutableString stringWithFormat:@"stosdebug://enableJIT?bundleId=%@&appName=%@", hostId, encName];
        if (encScript) [inner appendFormat:@"&script=%@", encScript];
        if (type == 5) {
            logLine(@"JIT 获取将在 StosDebug 中继续。");
            LGOpenURLString(inner);
        } else {
            LGJITLaunchViaOtherLC(@"stosdebug", inner, logLine);
        }
        return;
    }
    if (type == 4) { // SideStore
        logLine(@"JIT 获取将在 SideStore 中继续。");
        LGOpenURLString([NSString stringWithFormat:@"sidestore://enable-jit?bundle-id=%@", hostId]);
        return;
    }
    if (type == 0) { // SideJITServer
        NSString *addr = [gd stringForKey:@"LCSideJITServerAddress"];
        NSString *udid = [gd stringForKey:@"LCDeviceUDID"];
        if (!addr.length || !udid.length) {
            logLine(@"未配置 SideJITServer（地址或设备 UDID 缺失）。");
            return;
        }
        logLine(@"若服务器不在局域网内，请确保 VPN 已连接。");
        logLine([NSString stringWithFormat:@"正在联系 SideJITServer %@…", addr]);
        NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"%@/%@/%@", addr, udid, hostId]];
        if (!url) { logLine(@"SideJITServer 地址不合法。"); return; }
        [[NSURLSession.sharedSession dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *resp, NSError *error) {
            if (error) { logLine([NSString stringWithFormat:@"联系 SideJITServer 失败：%@", error.localizedDescription]); return; }
            NSString *text = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
            if (text.length) logLine(text);
        }] resume];
        return;
    }
    if (type == 2) { // JitStreamer-EB
        NSString *addr = [gd stringForKey:@"LCSideJITServerAddress"];
        if (!addr.length) addr = @"http://[fd00::]:9172";
        logLine(@"若服务器不在局域网内，请确保 VPN 已连接。");
        logLine([NSString stringWithFormat:@"正在联系 JitStreamer-EB %@…", addr]);
        NSURL *mountURL = [NSURL URLWithString:[addr stringByAppendingString:@"/mount"]];
        [[NSURLSession.sharedSession dataTaskWithURL:mountURL completionHandler:^(NSData *data, NSURLResponse *resp, NSError *error) {
            if (error || !data) {
                logLine([NSString stringWithFormat:@"联系 JitStreamer-EB 失败：%@", error.localizedDescription ?: @"无响应"]);
                return;
            }
            NSDictionary *obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if (![obj isKindOfClass:NSDictionary.class] || !LGFlag(obj[@"ok"])) {
                NSString *e = [obj isKindOfClass:NSDictionary.class] ? LGString(obj[@"error"]) : @"";
                logLine(e.length ? e : @"挂载失败（未知错误）。");
                return;
            }
            if (LGFlag(obj[@"mounting"])) {
                logLine(@"设备正在挂载开发者磁盘镜像，挂载完成后请再试一次。");
                LGOpenURLString([addr stringByAppendingString:@"/mount_status"]);
                return;
            }
            logLine(@"JIT 获取将在默认浏览器中继续。");
            LGOpenURLString([NSString stringWithFormat:@"%@/launch_app/%@", addr, hostId]);
        }] resume];
        return;
    }
    logLine(@"未知的 JIT 启用方式，请回原列表启动。");
}

// 等待 JIT 的页面（对应原列表的 JITEnablingModal）：上方说明 + 启用器
// 日志，下方由导航栏的「取消 / 启动」收尾——取消清掉待启动的 selected，
// 启动才真正把 Guest 拉起来。
@interface LGJITWaitViewController : UIViewController
@property (nonatomic, strong) UITextView *logView;
@property (nonatomic, copy) void (^onProceed)(void);
@property (nonatomic, copy) void (^onCancel)(void);
- (void)appendLog:(NSString *)line;
- (void)setReady:(BOOL)ready;
@end

@implementation LGJITWaitViewController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.title = @"等待JIT";
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCancel target:self action:@selector(cancelTapped)];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"启动" style:UIBarButtonItemStyleDone target:self action:@selector(proceedTapped)];
    self.navigationItem.rightBarButtonItem.enabled = NO; // 补签/启用流程就绪后才放行
    UILabel *msg = [UILabel new];
    msg.text = @"请为LiveContainer启用JIT。\n启用完成后点右上角「启动」打开这个 App；若启用方式跳去了别的 App，启用完切回 LC 再点。";
    msg.numberOfLines = 0;
    msg.font = [UIFont systemFontOfSize:14];
    msg.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:msg];
    self.logView = [UITextView new];
    self.logView.editable = NO;
    self.logView.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
    self.logView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.logView];
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [msg.topAnchor constraintEqualToAnchor:safe.topAnchor constant:16],
        [msg.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16],
        [msg.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-16],
        [self.logView.topAnchor constraintEqualToAnchor:msg.bottomAnchor constant:12],
        [self.logView.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16],
        [self.logView.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-16],
        [self.logView.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-16],
    ]];
}
- (void)cancelTapped { if (self.onCancel) self.onCancel(); }
- (void)proceedTapped { if (self.onProceed) self.onProceed(); }
- (void)setReady:(BOOL)ready { self.navigationItem.rightBarButtonItem.enabled = ready; }
- (void)appendLog:(NSString *)line {
    if (!line.length) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString *cur = self.logView.text ?: @"";
        self.logView.text = cur.length ? [cur stringByAppendingFormat:@"\n%@", line] : line;
    });
}
@end

// JIT 经典启动用的 classicMode 值：扫描时存好的缓存值优先；缓存无效
// （-1）时现场调 LC 导出的 LCGetDefaultClassicMode 算，都拿不到用 0。
static NSUInteger LGDefaultClassicModeForApp(NSDictionary *app) {
    NSInteger stored = LGNumber(app[@"defaultClassicMode"]);
    if (stored >= 0) return (NSUInteger)stored;
    typedef NSNumber *(*LGGetModeFn)(NSURL *);
    LGGetModeFn fn = (LGGetModeFn)dlsym(RTLD_DEFAULT, "LCGetDefaultClassicMode");
    if (fn) {
        NSNumber *mode = fn([NSURL fileURLWithPath:LGString(app[@"folder"])]);
        if ([mode isKindOfClass:NSNumber.class]) return mode.unsignedIntegerValue;
    }
    return 0;
}

static UIWindow *LGKeyWindow(void); // 定义在呈现管理一节

// 从窗口根控制器沿 presented 链找到当前最顶层的控制器：等待页从它身上
// 呈现，避免从正处在转场中的控制器 present 被 UIKit 静默吞掉。
static UIViewController *LGTopPresenter(UIViewController *fallback) {
    UIWindow *w = LGKeyWindow();
    UIViewController *top = w ? w.rootViewController : nil;
    if (!top) return fallback;
    while (top.presentedViewController) top = top.presentedViewController;
    return top;
}

static NSString *LGJITEnablerName(NSInteger type) {
    switch (type) {
        case 0: return @"SideJITServer";
        case 1: return @"StikDebug";
        case 2: return @"JitStreamer-EB";
        case 3: return @"StikDebug（LC 变体）";
        case 4: return @"SideStore";
        case 5: return @"StosDebug";
        case 6: return @"StosDebug（LC 变体）";
        default: return @"未知";
    }
}

static BOOL LGLaunchAppMultitask(NSDictionary *app, UIViewController *host, BOOL jit);
static BOOL LGIsMultitasking(void);

// 不带 HUD 的补签（JIT 等待页自己有日志区，不再叠一层弹窗）：完成回调
// 在主队列执行；接口缺失时视为通过（与 prepare 的退化口径一致）。
static void LGRunSign(NSDictionary *app, void (^done)(BOOL ok, NSString *errorInfo)) {
    Class infoCls = NSClassFromString(@"LCAppInfo");
    SEL initSel = NSSelectorFromString(@"initWithBundlePath:");
    SEL patchSel = NSSelectorFromString(@"patchExecAndSignIfNeedWithCompletionHandler:progressHandler:forceSign:");
    if (!infoCls || ![infoCls instancesRespondToSelector:patchSel]) { done(YES, nil); return; }
    id info = ((id (*)(id, SEL, NSString *))objc_msgSend)([infoCls alloc], initSel, app[@"folder"]);
    if (!info) { done(YES, nil); return; }
    __block id keepInfo = info;
    void (^completion)(bool, NSString *) = ^(bool success, NSString *errorInfo) {
        dispatch_async(dispatch_get_main_queue(), ^{
            keepInfo = nil;
            done(success, errorInfo);
        });
    };
    void (^progress)(NSProgress *) = ^(NSProgress *p) { (void)p; };
    ((void (*)(id, SEL, id, id, BOOL))objc_msgSend)(info, patchSel, completion, progress, NO);
}

// JIT App 的启动：一律先出等待页再往下走（v24 前几版实测：JIT 点按
// 可能被静默吞掉、或绕过启用流程直接把 App 打开，页面先行让每一步都
// 看得见）。页面日志依次打：启用方式与类型、计划走经典还是多任务、
// 补签结果、askForJIT 的每一步；经典计划在日志跑完后点「启动」正式
// 打开，多任务计划点「启动」后走多任务启动、拿到 pid 再开启用链接。
static void LGLaunchJITFlow(NSDictionary *app, UIViewController *host, NSInteger mode) {
    Class utils = NSClassFromString(@"LCSharedUtils");
    SEL launchSel = NSSelectorFromString(@"launchToGuestAppWithClassicMode:");
    if (![utils respondsToSelector:launchSel]) {
        LGShowAlert(host, @"启动失败", @"当前 LC 缺少经典启动接口，请回原列表启动。");
        return;
    }
    // 计划：mode 1 强制经典、2 强制多任务；自动时与原列表同口径，
    // 多任务 JIT 还需要 iOS 17.4+ 的 pid 路径，低版本回经典等待流程。
    BOOL classicPlan;
    if (mode == 1) classicPlan = YES;
    else if (mode == 2) classicPlan = NO;
    else {
        BOOL wantMT = NO;
        if (!LGFlag(app[@"classicOnly"])) {
            NSInteger specified = LGNumber(app[@"mtSpecified"]);
            wantMT = specified == 2 ||
                (specified == 0 && [NSUserDefaults.standardUserDefaults boolForKey:@"LCLaunchInMultitaskMode"]);
            if (!wantMT && LGIsMultitasking()) wantMT = YES;
        }
        NSOperatingSystemVersion v = NSProcessInfo.processInfo.operatingSystemVersion;
        BOOL mtOK = v.majorVersion > 17 || (v.majorVersion == 17 && v.minorVersion >= 4);
        classicPlan = !(wantMT && mtOK);
    }
    NSUInteger classicMode = LGDefaultClassicModeForApp(app);
    NSUserDefaults *defs = LGHostDefaults();
    // TrollStore 安装的 LC：原版 askForJIT 直接把 Guest 拉起来、没有等待页
    NSString *tsPath = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"../_TrollStore"];
    if (classicPlan && [NSFileManager.defaultManager fileExistsAtPath:tsPath]) {
        [defs setBool:NO forKey:@"LCOpenSideStore"];
        [defs removeObjectForKey:@"launchAppUrlScheme"];
        [defs setObject:app[@"path"] forKey:@"selected"];
        [defs setObject:app[@"uuid"] forKey:@"selectedContainer"];
        ((BOOL (*)(id, SEL, NSUInteger))objc_msgSend)(utils, launchSel, classicMode);
        return;
    }
    LGJITWaitViewController *vc = [LGJITWaitViewController new];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    if (@available(iOS 13.0, *)) nav.modalPresentationStyle = UIModalPresentationPageSheet;
    UIViewController *presenter = LGTopPresenter(host);
    __block BOOL cancelled = NO;
    __block BOOL selectedSet = NO;
    vc.onCancel = ^{
        cancelled = YES;
        if (selectedSet) {
            [defs removeObjectForKey:@"selected"];
            [defs removeObjectForKey:@"selectedContainer"];
        }
        [presenter dismissViewControllerAnimated:YES completion:nil];
    };
    vc.onProceed = ^{
        if (classicPlan) {
            [presenter dismissViewControllerAnimated:YES completion:^{
                BOOL ok = ((BOOL (*)(id, SEL, NSUInteger))objc_msgSend)(utils, launchSel, classicMode);
                if (!ok) LGShowAlert(presenter, @"启动失败", @"LC 没有接受启动请求，请回原列表试一次。");
            }];
        } else {
            [presenter dismissViewControllerAnimated:YES completion:^{
                LGLaunchAppMultitask(app, host, YES);
            }];
        }
    };
    NSInteger type = LGJITEnablerType();
    [presenter presentViewController:nav animated:YES completion:^{
        [vc appendLog:[NSString stringWithFormat:@"%@ · JIT 启用方式：%@（类型 %ld）", LGString(app[@"title"]), LGJITEnablerName(type), (long)type]];
        [vc appendLog:classicPlan ? @"启动方式：经典（先启用 JIT 再打开）" : @"启动方式：多任务（打开后按 pid 启用 JIT）"];
        [vc appendLog:@"正在补签…"];
        LGRunSign(app, ^(BOOL ok, NSString *errorInfo) {
            if (cancelled) return;
            if (!ok) {
                [vc appendLog:[NSString stringWithFormat:@"补签失败：%@", errorInfo.length ? errorInfo : @"未知错误"]];
                return;
            }
            [vc appendLog:@"补签完成"];
            if (classicPlan) {
                [defs setBool:NO forKey:@"LCOpenSideStore"];
                [defs removeObjectForKey:@"launchAppUrlScheme"];
                [defs setObject:app[@"path"] forKey:@"selected"];
                [defs setObject:app[@"uuid"] forKey:@"selectedContainer"];
                selectedSet = YES;
                LGAskForJIT(app, ^(NSString *line) { [vc appendLog:line]; });
            }
            [vc setReady:YES];
        });
    }];
}

// LC 变体启用器（StikDebug/StosDebug 装在 LC 里当 Guest）在多任务 pid
// 路径下的原版做法（jitLaunch(withPID:) → openWebView → runApp(urlStr:)）：
// 把带 pid 的启用链接放进 launchAppUrlScheme，在当前多任务会话里把那个
// Guest 拉起来，链接由 Guest 自己消费——不是用 openURL 开独立 App。
static void LGLaunchEnablerGuest(NSDictionary *guest, NSString *urlStr, UIViewController *host) {
    Class utils = NSClassFromString(@"LCUtils");
    SEL launchSel = NSSelectorFromString(@"launchMultitaskGuestApp:completionHandler:");
    if (![utils respondsToSelector:launchSel]) {
        LGShowAlert(host, @"启用 JIT 失败", @"未找到 LC 多任务接口，无法打开 LC 内的 JIT 启用器。");
        return;
    }
    NSUserDefaults *defs = LGHostDefaults();
    [defs setBool:NO forKey:@"LCOpenSideStore"];
    [defs setObject:urlStr forKey:@"launchAppUrlScheme"];
    [defs setObject:guest[@"path"] forKey:@"selected"];
    [defs setObject:guest[@"uuid"] forKey:@"selectedContainer"];
    void (^completion)(NSNumber *, NSError *) = ^(NSNumber *pid, NSError *error) {
        if (error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                LGShowAlert(host, @"启用 JIT 失败", error.localizedDescription.length ? error.localizedDescription : @"LC 内的 JIT 启用器没有打开。");
            });
        }
    };
    ((void (*)(id, SEL, NSString *, id))objc_msgSend)(utils, launchSel, LGString(guest[@"title"]), completion);
    // 同 LGLaunchAppMultitask：键还留着原值说明没被同步消费，清掉防残留
    if ([[defs stringForKey:@"selected"] isEqualToString:guest[@"path"]] &&
        [[defs stringForKey:@"selectedContainer"] isEqualToString:guest[@"uuid"]]) {
        [defs removeObjectForKey:@"selected"];
        [defs removeObjectForKey:@"selectedContainer"];
    }
}

// 多任务 JIT（iOS 17.4+，口径同 runApp 的 jitLaunch(withPID:)）：Guest
// 窗口起来拿到 pid 后按启用方式送启用链接——独立 App 型（StikDebug/
// StosDebug 本体）直开链接；LC 变体型把链接交给 LC 里的 Guest 本人。
// 其余启用方式（SideJITServer/JitStreamer/SideStore）原列表在这条路上
// 同样不处理。
static void LGOpenJITEnablerForPID(NSDictionary *app, NSInteger pid, UIViewController *host) {
    NSInteger type = LGJITEnablerType();
    NSString *hostId = NSBundle.mainBundle.bundleIdentifier ?: @"";
    NSString *script = LGString(app[@"jitScript"]);
    NSString *encScript = script.length ? [script stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLQueryAllowedCharacterSet] : nil;
    if (type == 5) { // StosDebug 独立 App
        NSString *encName = [LGString(app[@"title"]) stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLQueryAllowedCharacterSet];
        NSMutableString *u = [NSMutableString stringWithFormat:@"stosdebug://enableJIT?bundleId=%@&appName=%@&pid=%ld&forcePID=true", hostId, encName, (long)pid];
        if (encScript) [u appendFormat:@"&script=%@", encScript];
        LGOpenURLString(u);
    } else if (type == 1) { // StikDebug 独立 App
        NSMutableString *u = [NSMutableString stringWithFormat:@"stikjit://enable-jit?bundle-id=%@&pid=%ld", hostId, (long)pid];
        if (encScript) [u appendFormat:@"&script-data=%@", encScript];
        LGOpenURLString(u);
    } else if (type == 6 || type == 3) { // LC 变体：链接交给 LC 里的 Guest
        NSString *scheme = type == 6 ? @"stosdebug" : @"stikjit";
        NSString *urlStr;
        if (type == 6) {
            NSString *encName = [LGString(app[@"title"]) stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLQueryAllowedCharacterSet];
            NSMutableString *u = [NSMutableString stringWithFormat:@"stosdebug://enableJIT?bundleId=%@&appName=%@&pid=%ld&relaunchApp=false&forcePID=true", hostId, encName, (long)pid];
            if (encScript) [u appendFormat:@"&script=%@", encScript];
            urlStr = u;
        } else {
            NSMutableString *u = [NSMutableString stringWithFormat:@"stikjit://enable-jit?bundle-id=%@&pid=%ld", hostId, (long)pid];
            if (encScript) [u appendFormat:@"&script-data=%@", encScript];
            urlStr = u;
        }
        NSDictionary *guest = LGFindEnablerGuestApp(scheme);
        if (!guest) {
            LGShowAlert(host, @"启用 JIT 失败", [NSString stringWithFormat:@"LC 里没找到能响应 %@ 的启用器 App，请确认 StikDebug/StosDebug 已装进 LiveContainer。", scheme]);
            return;
        }
        LGLaunchEnablerGuest(guest, urlStr, host);
    }
}

// 经典模式启动：与 LCOrbitGuestService 的经典路径等价。
static BOOL LGLaunchApp(NSDictionary *app, UIViewController *host) {
    NSUserDefaults *defs = LGHostDefaults();
    Class utils = NSClassFromString(@"LCSharedUtils");
    if (LGFlag(app[@"builtin"])) {
        SEL sel = NSSelectorFromString(@"launchToGuestAppWithClassicMode:");
        if (![utils respondsToSelector:sel]) { LGShowAlert(host, @"启动失败", @"当前 LC 缺少内置应用启动接口。"); return NO; }
        [defs setBool:NO forKey:@"LCOpenSideStore"];
        [defs setObject:@"builtinSideStore" forKey:@"selected"];
        [defs removeObjectForKey:@"selectedContainer"];
        [defs removeObjectForKey:@"launchAppUrlScheme"];
        BOOL ok = ((BOOL (*)(id, SEL, NSUInteger))objc_msgSend)(utils, sel, 0);
        if (!ok) { [defs removeObjectForKey:@"selected"]; LGShowAlert(host, @"启动失败", @"LC 没有接受启动请求。"); }
        return ok;
    }
    SEL sel = NSSelectorFromString(@"launchToGuestAppWithURL:");
    if (![utils respondsToSelector:sel]) { LGShowAlert(host, @"启动失败", @"当前 LC 版本不提供启动接口。"); return NO; }
    NSString *scheme = LGString(LGClassCall(NSUserDefaults.class, @"lcAppUrlScheme"));
    if (!scheme.length) { LGShowAlert(host, @"启动失败", @"无法确认当前 LC 的 URL Scheme。"); return NO; }
    NSURLComponents *url = [NSURLComponents new];
    url.scheme = scheme;
    url.host = @"livecontainer-launch";
    url.queryItems = @[[NSURLQueryItem queryItemWithName:@"bundle-name" value:app[@"path"]],
                       [NSURLQueryItem queryItemWithName:@"container-folder-name" value:app[@"uuid"]]];
    if (!url.URL) { LGShowAlert(host, @"启动失败", @"目标 URL 不合法。"); return NO; }
    [defs setBool:NO forKey:@"LCOpenSideStore"];
    [defs removeObjectForKey:@"launchAppUrlScheme"];
    BOOL ok = ((BOOL (*)(id, SEL, NSURL *))objc_msgSend)(utils, sel, url.URL);
    if (!ok) {
        [defs removeObjectForKey:@"selected"];
        [defs removeObjectForKey:@"selectedContainer"];
        LGShowAlert(host, @"启动失败", @"LC 未能接受启动请求，请回原列表试一次。");
    }
    return ok;
}

// LC 多任务（虚拟窗口）是否正在运行：MultitaskManager 是 @objc 类，可直调。
static BOOL LGIsMultitasking(void) {
    Class mm = NSClassFromString(@"MultitaskManager");
    SEL sel = NSSelectorFromString(@"isMultitasking");
    if (![mm respondsToSelector:sel]) return NO;
    return ((BOOL (*)(id, SEL))objc_msgSend)(mm, sel);
}

// 多任务启动：口径同 LCOrbit 的多任务路径——先占 selected/selectedContainer，
// 再调 +[LCUtils launchMultitaskGuestApp:completionHandler:]（参数是显示名）。
static BOOL LGLaunchAppMultitask(NSDictionary *app, UIViewController *host, BOOL jit) {
    if (LGFlag(app[@"classicOnly"])) {
        LGShowAlert(host, @"无法多任务启动", @"此 App 使用经典兼容模式，请回原列表启动。");
        return NO;
    }
    Class utils = NSClassFromString(@"LCUtils");
    SEL launchSel = NSSelectorFromString(@"launchMultitaskGuestApp:completionHandler:");
    NSString *live = LGString(LGClassCall(utils, @"liveProcessBundleIdentifier"));
    if (![utils respondsToSelector:launchSel] || !live.length) {
        LGShowAlert(host, @"启动失败", @"未找到 LC 多任务接口或 LiveProcess 扩展，请回原列表启动。");
        return NO;
    }
    Class sharedUtils = NSClassFromString(@"LCSharedUtils");
    SEL ownerSel = NSSelectorFromString(@"getContainerUsingLCSchemeWithFolderName:");
    if ([sharedUtils respondsToSelector:ownerSel]) {
        NSString *owner = ((id (*)(id, SEL, NSString *))objc_msgSend)(sharedUtils, ownerSel, app[@"uuid"]);
        if (owner.length) {
            // 容器已被占用：先试把本会话里已运行的窗口调到前台（与原列表点
            // 已运行 App 时 runApp 走的 openExistingAppWindow 同一条路）；
            // 调不动才是真被其他 LC 占用。
            BOOL front = NO;
            Class wm = NSClassFromString(@"MultitaskWindowManager");
            SEL openSel = NSSelectorFromString(@"openExistingAppWindowWithDataUUID:");
            if ([wm respondsToSelector:openSel])
                front = ((BOOL (*)(id, SEL, NSString *))objc_msgSend)(wm, openSel, app[@"uuid"]);
            if (front) {
                if (host.presentingViewController) [host dismissViewControllerAnimated:YES completion:nil];
                return YES;
            }
            LGShowAlert(host, @"已在运行中", @"此 App 已在其他 LC 中运行，无法从这里切回。");
            return NO;
        }
    }
    NSUserDefaults *defs = LGHostDefaults();
    if ([defs objectForKey:@"selected"] || [defs objectForKey:@"selectedContainer"]) {
        LGShowAlert(host, @"启动失败", @"LC 里已有待处理的启动请求，请稍后再试。");
        return NO;
    }
    [defs setBool:NO forKey:@"LCOpenSideStore"];
    [defs removeObjectForKey:@"launchAppUrlScheme"];
    [defs setObject:app[@"path"] forKey:@"selected"];
    [defs setObject:app[@"uuid"] forKey:@"selectedContainer"];
    void (^completion)(NSNumber *, NSError *) = ^(NSNumber *pid, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!error && pid.intValue > 0) {
                // JIT App：窗口已起来，先按启用方式把带 pid 的启用链接
                // 打开（StikDebug/StosDebug 会给这个 pid 的进程启用 JIT）。
                if (jit) LGOpenJITEnablerForPID(app, pid.intValue, host);
                // 启动成功：网格是模态盖在 LC 界面之上的，不退下会挡住 Guest 窗口，
                // 让出主界面给多任务窗口（悬浮按钮还在，随时能呼回网格）。
                if (host.presentingViewController) [host dismissViewControllerAnimated:YES completion:nil];
                return;
            }
            LGShowAlert(host, @"启动失败", error.localizedDescription.length ? error.localizedDescription : @"多任务启动失败，请回原列表检查。");
        });
    };
    ((void (*)(id, SEL, NSString *, id))objc_msgSend)(utils, launchSel, LGString(app[@"title"]), completion);
    // LCUtils 同步消费这两个键；若还留着原值说明没被消费，清掉避免残留。
    if ([[defs stringForKey:@"selected"] isEqualToString:app[@"path"]] &&
        [[defs stringForKey:@"selectedContainer"] isEqualToString:app[@"uuid"]]) {
        [defs removeObjectForKey:@"selected"];
        [defs removeObjectForKey:@"selectedContainer"];
    }
    return YES;
}

// 若 LCFloatingMenu(LCOrbit) 在场且开着它的全屏多任务：启动委托给
// LCOrbitGuestService——已运行窗口的登记与调前台都在它的注册表里，
// LC 原生的 MultitaskWindowManager 查不到，硬走原生路只会误报「在其他
// LC 中运行」。目标字典用它自己扫描的结果，保证 identity/folder 对得上；
// 委托失败不打扰用户，落回下面的自有路径。
static BOOL LGTryOrbitLaunch(NSDictionary *app, UIViewController *host) {
    Class svc = NSClassFromString(@"LCOrbitGuestService");
    Class mt = NSClassFromString(@"LCOrbitMultitask");
    SEL enabledSel = NSSelectorFromString(@"isEnabled");
    if (!svc || ![mt respondsToSelector:enabledSel]) return NO;
    if (!((BOOL (*)(id, SEL))objc_msgSend)(mt, enabledSel)) return NO;
    // Orbit 的全量扫描每次点按都跑一遍很费时（要读全部 App 的 plist）：
    // 结果缓存 10 秒，只用于按 folder 找目标字典，launchGuest 内部还会
    // 用它自己的新鲜扫描复核，缓存旧一点不会启错。
    static NSArray *cachedItems = nil;
    static NSTimeInterval cachedAt = 0;
    NSTimeInterval nowT = NSDate.timeIntervalSinceReferenceDate;
    NSArray *items = (cachedItems && nowT - cachedAt < 10) ? cachedItems : nil;
    if (!items) {
        SEL appsSel = NSSelectorFromString(@"installedApps");
        if (![svc respondsToSelector:appsSel]) return NO;
        items = ((id (*)(id, SEL))objc_msgSend)(svc, appsSel);
        if ([items isKindOfClass:NSArray.class]) { cachedItems = items; cachedAt = nowT; }
    }
    if (![items isKindOfClass:NSArray.class]) return NO;
    NSString *myFolder = [[LGString(app[@"folder"]) stringByStandardizingPath] stringByResolvingSymlinksInPath];
    NSDictionary *target = nil;
    for (NSDictionary *item in items) {
        if (![item isKindOfClass:NSDictionary.class]) continue;
        NSString *f = [[LGString(item[@"folder"]) stringByStandardizingPath] stringByResolvingSymlinksInPath];
        if (f.length && myFolder.length && [f isEqualToString:myFolder]) { target = item; break; }
    }
    if (!target) return NO;
    SEL launchSel = NSSelectorFromString(@"launchGuest:error:");
    if (![svc respondsToSelector:launchSel]) return NO;
    NSError *error = nil;
    BOOL ok = ((BOOL (*)(id, SEL, id, NSError **))objc_msgSend)(svc, launchSel, target, &error);
    if (ok && host.presentingViewController) [host dismissViewControllerAnimated:YES completion:nil];
    return ok;
}

// 按 LC 原列表 runApp 的口径分发启动模式：
//   多任务 = 非经典模式 App 且（已有多任务会话在跑，或该 App 的
//   MultitaskSpecified=2，或 =0(默认) 且全局开关 LCLaunchInMultitaskMode 开）。
//   注意 isMultitasking 只表示「已有窗口在跑」，不是启动偏好本身。
static void LGDispatchLaunchMode(NSDictionary *app, UIViewController *host, NSInteger mode) {
    if (LGFlag(app[@"builtin"])) { LGLaunchApp(app, host); return; }
    BOOL jit = LGFlag(app[@"jit"]);
    if (jit) { LGLaunchJITFlow(app, host, mode); return; }
    if (mode == 1) { LGLaunchApp(app, host); return; } // 强制经典
    // 非 JIT 才委托 LCOrbit：它自己的扫描把 JIT 标成不可快捷启动，
    // launchGuest 必然以「需要 JIT」拒绝（且失败在我们这层是静默的）。
    if (LGTryOrbitLaunch(app, host)) return;
    if (mode == 2) { LGLaunchAppMultitask(app, host, NO); return; } // 强制多任务
    BOOL wantMultitask = NO;
    if (!LGFlag(app[@"classicOnly"])) {
        NSInteger specified = LGNumber(app[@"mtSpecified"]);
        wantMultitask = specified == 2 ||
            (specified == 0 && [NSUserDefaults.standardUserDefaults boolForKey:@"LCLaunchInMultitaskMode"]);
        if (!wantMultitask && LGIsMultitasking()) wantMultitask = YES;
    }
    if (wantMultitask) LGLaunchAppMultitask(app, host, NO);
    else LGLaunchApp(app, host);
}

static void LGDispatchLaunch(NSDictionary *app, UIViewController *host) {
    LGDispatchLaunchMode(app, host, 0);
}

// 新装 App 还没有数据容器时，照 LC 原列表 runApp 的口径现建默认容器
// （LCAppModel.runApp 的 uiContainers.isEmpty 分支）：随机 UUID 文件夹
// + LCContainerInfo.plist（二进制，键同 LCContainer 的
// makeLCContainerInfoPlist，keychainGroupId 在 0..<128 随机，与 LC
// 自动建容器同口径），再用 LCAppInfo 的 setter 回写 LCContainers 与
// LCDataUUID（setter 自带 save）。建好返回容器名，失败返回 nil。
static NSString *LGCreateDefaultContainer(NSDictionary *app) {
    Class infoCls = NSClassFromString(@"LCAppInfo");
    SEL initSel = NSSelectorFromString(@"initWithBundlePath:");
    if (!infoCls || ![infoCls instancesRespondToSelector:initSel]) return nil;
    id info = ((id (*)(id, SEL, NSString *))objc_msgSend)([infoCls alloc], initSel, app[@"folder"]);
    if (!info) return nil;
    // LCAppInfo 现读到的容器列表仍为空才建，避免与别处刚建好的重复
    id existing = ((id (*)(id, SEL))objc_msgSend)(info, NSSelectorFromString(@"containerInfo"));
    if ([existing isKindOfClass:NSArray.class] && [existing count]) {
        NSString *uuid = LGString(((id (*)(id, SEL))objc_msgSend)(info, NSSelectorFromString(@"dataUUID")));
        if (uuid.length) return uuid;
        id first = [existing firstObject];
        return [first isKindOfClass:NSDictionary.class] ? LGString(first[@"folderName"]) : nil;
    }
    NSString *root = nil;
    if (LGFlag(app[@"shared"])) {
        NSString *group = LGString(LGClassCall(NSUserDefaults.class, @"lcAppGroupPath"));
        if (group.length) root = [[group stringByAppendingPathComponent:@"LiveContainer"] stringByAppendingPathComponent:@"Data/Application"];
    } else {
        const char *raw = getenv("LC_HOME_PATH");
        NSString *home = (raw && raw[0]) ? [NSString stringWithUTF8String:raw] : nil;
        if (home.length) root = [[home stringByAppendingPathComponent:@"Documents"] stringByAppendingPathComponent:@"Data/Application"];
    }
    if (!root.length) return nil;
    NSString *newName = NSUUID.UUID.UUIDString;
    NSString *containerPath = [root stringByAppendingPathComponent:newName];
    NSDictionary *plistDict = @{@"appIdentifier": LGString(app[@"bundle"]), @"name": newName,
        @"keychainGroupId": @(arc4random_uniform(128)), @"isolateAppGroup": @NO,
        @"spoofIdentifierForVendor": @NO};
    NSData *plistData = [NSPropertyListSerialization dataWithPropertyList:plistDict
        format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
    NSFileManager *fm = NSFileManager.defaultManager;
    if (!plistData ||
        ![fm createDirectoryAtPath:containerPath withIntermediateDirectories:YES attributes:nil error:nil] ||
        ![plistData writeToFile:[containerPath stringByAppendingPathComponent:@"LCContainerInfo.plist"] atomically:YES])
        return nil;
    ((void (*)(id, SEL, id))objc_msgSend)(info, NSSelectorFromString(@"setContainerInfo:"),
        @[@{@"folderName": newName, @"name": newName}]);
    ((void (*)(id, SEL, id))objc_msgSend)(info, NSSelectorFromString(@"setDataUUID:"), newName);
    return newName;
}

// 启动前先让 LC 给 Guest 补丁+重签（与原列表 runApp 里的 signApp 一步等价）：
// LCAppInfo -patchExecAndSignIfNeedWithCompletionHandler:progressHandler:forceSign:
// 健康的应用这一步是空转；签名过期（如 LC 被 SideStore 刷新换过证书）时
// 靠它修复，缺了它直接走 URL 启动会在 dlopen 时报 code signature invalid。
// mode: 0=按偏好自动，1=强制经典，2=强制多任务（长按菜单的反模式启动用）
static void LGPrepareAndLaunchMode(NSDictionary *app, UIViewController *host, NSInteger mode) {
    if (LGFlag(app[@"builtin"])) { LGLaunchApp(app, host); return; }
    // 锁定 App 先过系统认证（与原列表点横幅的顺序一致：认证在补签之前，
    // 认证不过就不启动），本次运行内认证过一次后不再重复问。
    if (LGFlag(app[@"locked"]) && !LGUnlockedThisSession) {
        LGAuthenticate(app, host, ^{ LGPrepareAndLaunchMode(app, host, mode); });
        return;
    }
    // 新装 App 还没容器：照 LC runApp 口径现建默认容器再启动，
    // 免去先去原列表打开一次（建在认证之后，与 LC 的顺序一致）
    if (LGFlag(app[@"needsContainer"])) {
        NSString *uuid = LGCreateDefaultContainer(app);
        if (!uuid.length) {
            LGShowAlert(host, @"启动失败", @"无法创建数据容器，请回原列表打开一次。");
            return;
        }
        NSMutableDictionary *m = [app mutableCopy];
        m[@"uuid"] = uuid;
        m[@"needsContainer"] = @NO;
        app = m;
    }
    // JIT App 走自有流程（等待页先行、内含补签），不经下面这段 HUD 补签
    if (LGFlag(app[@"jit"])) { LGLaunchJITFlow(app, host, mode); return; }
    Class infoCls = NSClassFromString(@"LCAppInfo");
    SEL initSel = NSSelectorFromString(@"initWithBundlePath:");
    SEL patchSel = NSSelectorFromString(@"patchExecAndSignIfNeedWithCompletionHandler:progressHandler:forceSign:");
    if (!infoCls || ![infoCls instancesRespondToSelector:patchSel]) { LGDispatchLaunchMode(app, host, mode); return; }
    id info = ((id (*)(id, SEL, NSString *))objc_msgSend)([infoCls alloc], initSel, app[@"folder"]);
    if (!info) { LGDispatchLaunchMode(app, host, mode); return; }
    // 「正在准备」HUD 延迟 0.35 秒才出现：健康 App 的补签是瞬间空转，
    // 赶在延迟前完成就直接启动，省掉 HUD 一进一出两次转场动画——
    // 这是点开 App 感觉慢的主要一环；只有真要重签（耗时）时才出提示。
    __block id keepInfo = info;
    __block BOOL finished = NO;
    __block UIAlertController *hud = nil;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (finished) return;
        hud = [UIAlertController alertControllerWithTitle:@"正在准备"
            message:[NSString stringWithFormat:@"%@…", LGString(app[@"title"])] preferredStyle:UIAlertControllerStyleAlert];
        [host presentViewController:hud animated:YES completion:nil];
    });
    void (^completion)(bool, NSString *) = ^(bool success, NSString *errorInfo) {
        dispatch_async(dispatch_get_main_queue(), ^{
            finished = YES;
            keepInfo = nil;
            void (^go)(void) = ^{
                if (!success) {
                    LGShowAlert(host, @"启动失败", errorInfo.length ? errorInfo : @"LC 补签失败，请回原列表启动一次。");
                } else {
                    LGDispatchLaunchMode(app, host, mode);
                }
            };
            if (hud && hud.presentingViewController) [hud dismissViewControllerAnimated:YES completion:go];
            else go();
        });
    };
    void (^progress)(NSProgress *) = ^(NSProgress *p) { (void)p; };
    ((void (*)(id, SEL, id, id, BOOL))objc_msgSend)(info, patchSel, completion, progress, NO);
}

static void LGPrepareAndLaunch(NSDictionary *app, UIViewController *host) {
    LGPrepareAndLaunchMode(app, host, 0);
}

// 数据容器根目录（私有 + 共享各一）：删除数据时两个都试着删——容器名
// 是 UUID、全局唯一，删错根目录顶多是空操作。
static NSArray<NSString *> *LGDataRoots(void) {
    NSMutableArray<NSString *> *roots = [NSMutableArray array];
    const char *raw = getenv("LC_HOME_PATH");
    NSString *home = (raw && raw[0]) ? [NSString stringWithUTF8String:raw] : nil;
    if (home.length) [roots addObject:[[home stringByAppendingPathComponent:@"Documents"] stringByAppendingPathComponent:@"Data/Application"]];
    NSString *group = LGString(LGClassCall(NSUserDefaults.class, @"lcAppGroupPath"));
    if (group.length) [roots addObject:[[group stringByAppendingPathComponent:@"LiveContainer"] stringByAppendingPathComponent:@"Data/Application"]];
    return roots;
}

static void LGRemoveAppKeychains(NSArray<NSString *> *containers) {
    Class utils = NSClassFromString(@"LCUtils");
    SEL sel = NSSelectorFromString(@"removeAppKeychainWithDataUUID:");
    if (!utils || ![utils respondsToSelector:sel]) return; // Swift 侧不可达就跳过，只是残留钥匙串条目
    for (NSString *fn in containers)
        ((void (*)(id, SEL, NSString *))objc_msgSend)(utils, sel, fn);
}

// 网格自己的卸载流程，文案与步骤照 LCAppBannerViewController.uninstall：
// 先「确认卸载」，有容器再问「删除数据」（否=保留数据）。借用菜单里 LC
// 的卸载动作在网格环境下第二道问询弹不出来（确认后直接删、数据被默认
// 保留），所以改由网格接管这一项，自己弹、自己删。
static void LGUninstallApp(NSDictionary *app, UIViewController *host) {
    if (!host) return;
    NSString *name = LGString(app[@"title"]);
    NSDictionary *lc = [NSDictionary dictionaryWithContentsOfFile:[LGString(app[@"folder"]) stringByAppendingPathComponent:@"LCAppInfo.plist"]];
    NSMutableArray<NSString *> *containers = [NSMutableArray array];
    id list = [lc isKindOfClass:NSDictionary.class] ? lc[@"LCContainers"] : nil;
    if ([list isKindOfClass:NSArray.class]) {
        for (id e in list) {
            if (![e isKindOfClass:NSDictionary.class]) continue;
            NSString *fn = LGString(e[@"folderName"]);
            if (fn.length && LGValidComponent(fn)) [containers addObject:fn];
        }
    }
    if (!containers.count) { // 老数据只有 LCDataUUID（同 LC containers 的 upgrade 口径）
        NSString *uuid = LGString([lc isKindOfClass:NSDictionary.class] ? lc[@"LCDataUUID"] : nil);
        if (uuid.length && LGValidComponent(uuid)) [containers addObject:uuid];
    }
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:NSLocalizedString(@"lc.appBanner.confirmUninstallTitle", @"")
        message:[NSString stringWithFormat:NSLocalizedString(@"lc.appBanner.confirmUninstallMsg %@", @""), name]
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"lc.common.cancel", @"")
        style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"lc.appBanner.uninstall", @"")
        style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
        void (^doDelete)(BOOL) = ^(BOOL removeData) {
            NSFileManager *fm = NSFileManager.defaultManager;
            [fm removeItemAtPath:LGString(app[@"folder"]) error:nil];
            if (removeData) {
                for (NSString *root in LGDataRoots())
                    for (NSString *fn in containers)
                        [fm removeItemAtPath:[root stringByAppendingPathComponent:fn] error:nil];
                LGRemoveAppKeychains(containers);
            }
            if ([host respondsToSelector:@selector(reloadApps)]) [host performSelector:@selector(reloadApps)];
        };
        if (!containers.count) { doDelete(NO); return; }
        UIAlertController *alert2 = [UIAlertController
            alertControllerWithTitle:NSLocalizedString(@"lc.appBanner.deleteDataTitle", @"")
            message:[NSString stringWithFormat:NSLocalizedString(@"lc.appBanner.deleteDataMsg %@", @""), name]
            preferredStyle:UIAlertControllerStyleAlert];
        [alert2 addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"lc.common.no", @"")
            style:UIAlertActionStyleCancel handler:^(UIAlertAction *a) { doDelete(NO); }]];
        [alert2 addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"lc.common.delete", @"")
            style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) { doDelete(YES); }]];
        [host presentViewController:alert2 animated:YES completion:nil];
    }]];
    [host presentViewController:alert animated:YES completion:nil];
}

// 把借用菜单里的「卸载」动作换成网格接管的版本（识别口径：destructive
// 且标题等于 LC 本地化的卸载串），其余动作原样保留；子菜单递归处理。
static NSArray<UIMenuElement *> *LGTransformMenuElements(NSArray<UIMenuElement *> *elements, NSDictionary *app, UIViewController *host) {
    NSString *uninstallTitle = NSLocalizedString(@"lc.appBanner.uninstall", @"");
    NSMutableArray<UIMenuElement *> *out = [NSMutableArray array];
    for (UIMenuElement *el in elements) {
        if ([el isKindOfClass:UIMenu.class]) {
            UIMenu *m = (UIMenu *)el;
            [out addObject:[UIMenu menuWithTitle:m.title image:m.image identifier:m.identifier
                options:m.options children:LGTransformMenuElements(m.children, app, host)]];
        } else if ([el isKindOfClass:UIAction.class]) {
            UIAction *a = (UIAction *)el;
            if ((a.attributes & UIMenuElementAttributesDestructive) && [a.title isEqualToString:uninstallTitle]) {
                __weak UIViewController *weakHost = host;
                [out addObject:[UIAction actionWithTitle:a.title image:a.image identifier:a.identifier
                    handler:^(__kindof UIAction *action) { LGUninstallApp(app, weakHost); }]];
            } else [out addObject:el];
        } else [out addObject:el];
    }
    return out;
}

#pragma mark - 网格界面

static NSString *const LGCellID = @"LGCell";

// 图标角标：与 LC 横幅的 LCAppBannerBadgeView 同规格——16×16 圆底、白色
// 8pt SF 符号（或文字），颜色优先取 LC 资源里的命名色、取不到用系统色。
// JIT 紫底 bolt.fill、锁定橙底 lock.fill、32 位蓝底文字「32」。
static UIView *LGMakeBadgeView(NSString *symbol, NSString *text, NSString *named, UIColor *fallback) {
    UIView *v = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 16, 16)];
    UIColor *bg = named ? [UIColor colorNamed:named] : nil;
    v.backgroundColor = bg ?: fallback;
    v.layer.cornerRadius = 8;
    v.clipsToBounds = YES;
    v.hidden = YES;
    v.userInteractionEnabled = NO;
    if (symbol) {
        UIImageView *iv = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:symbol withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:8]]];
        iv.tintColor = UIColor.whiteColor;
        iv.contentMode = UIViewContentModeCenter;
        iv.frame = v.bounds;
        iv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [v addSubview:iv];
    } else {
        UILabel *l = [[UILabel alloc] initWithFrame:v.bounds];
        l.text = text;
        l.textColor = UIColor.whiteColor;
        l.font = [UIFont systemFontOfSize:8];
        l.textAlignment = NSTextAlignmentCenter;
        l.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [v addSubview:l];
    }
    return v;
}

@interface LGGridCell : UICollectionViewCell
@property (nonatomic, strong) UIImageView *iconView;
@property (nonatomic, strong) UILabel *nameLabel;
@property (nonatomic, strong) UIView *badge;
@property (nonatomic, strong) UIView *jitBadge;
@property (nonatomic, strong) UIView *lockBadge;
@property (nonatomic, strong) UIView *bit32Badge;
@property (nonatomic, strong) UIView *sharedBadge;
@property (nonatomic, strong) UIView *updateBadge;
@end

@implementation LGGridCell
- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    _iconView = [[UIImageView alloc] init];
    _iconView.contentMode = UIViewContentModeScaleAspectFill;
    _iconView.clipsToBounds = YES;
    _iconView.backgroundColor = UIColor.secondarySystemBackgroundColor;
    [self.contentView addSubview:_iconView];
    _nameLabel = [[UILabel alloc] init];
    _nameLabel.font = [UIFont systemFontOfSize:11];
    _nameLabel.textAlignment = NSTextAlignmentCenter;
    _nameLabel.numberOfLines = 2;
    if (@available(iOS 13.0, *)) _nameLabel.textColor = UIColor.labelColor;
    [self.contentView addSubview:_nameLabel];
    _badge = LGMakeBadgeView(@"exclamationmark", nil, nil, UIColor.systemGrayColor);
    [self.contentView addSubview:_badge];
    _jitBadge = LGMakeBadgeView(@"bolt.fill", nil, @"JITBadgeColor", UIColor.systemPurpleColor);
    [self.contentView addSubview:_jitBadge];
    _lockBadge = LGMakeBadgeView(@"lock.fill", nil, @"BadgeColor", UIColor.systemOrangeColor);
    [self.contentView addSubview:_lockBadge];
    _bit32Badge = LGMakeBadgeView(nil, @"32", @"32BitBadgeColor", UIColor.systemBlueColor);
    [self.contentView addSubview:_bit32Badge];
    _sharedBadge = LGMakeBadgeView(@"arrowshape.turn.up.left.fill", nil, @"BadgeColor", UIColor.systemOrangeColor);
    [self.contentView addSubview:_sharedBadge];
    _updateBadge = LGMakeBadgeView(@"arrow.up", nil, nil, UIColor.systemBlueColor);
    [self.contentView addSubview:_updateBadge];
    return self;
}
- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = self.contentView.bounds.size.width;
    CGFloat icon = MIN(62, w - 14);
    self.iconView.frame = CGRectMake((w - icon) / 2, 2, icon, icon);
    self.iconView.layer.cornerRadius = icon * 0.225;
    // 角标排在图标右下角内侧成一行（左→右：共享、JIT/32、锁定、
    // 不可启动），最右边一个贴着图标右边缘。
    NSArray<UIView *> *badges = @[self.sharedBadge, self.jitBadge, self.bit32Badge, self.lockBadge, self.badge];
    CGFloat x = CGRectGetMaxX(self.iconView.frame) - 1;
    CGFloat y = CGRectGetMaxY(self.iconView.frame) - 17;
    for (UIView *b in badges.reverseObjectEnumerator) {
        if (b.hidden) continue;
        x -= 16;
        b.frame = CGRectMake(x, y, 16, 16);
        x -= 3;
    }
    // 更新角标独占图标右上角（蓝底白上箭头），与右下角的标志行分开
    self.updateBadge.frame = CGRectMake(CGRectGetMaxX(self.iconView.frame) - 17, CGRectGetMinY(self.iconView.frame) + 1, 16, 16);
    self.nameLabel.frame = CGRectMake(1, CGRectGetMaxY(self.iconView.frame) + 4, w - 2, 28);
}
@end

static void LGSetFloatButtonVisible(BOOL visible);
static UIContextMenuConfiguration *LGBorrowedMenuConfiguration(NSDictionary *app);
static void LGSyncOriginalList(NSInteger firstVisibleIndex);
static void LGNoteManualHide(void);

// 更新列表页：列出可更新的 App，点「更新」把下载地址交给 LC 自己的
// 安装流程（与在 LC「源」页点安装走的是同一个 InstallAppNotification）。
@interface LGUpdateListViewController : UITableViewController
@property (nonatomic, strong) NSArray<NSDictionary *> *items;
@end
@implementation LGUpdateListViewController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"可更新的 App";
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(doneTapped)];
    self.tableView.tableFooterView = [self footerLabel];
}
- (UIView *)footerLabel {
    UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(16, 12, UIScreen.mainScreen.bounds.size.width - 32, 60)];
    l.numberOfLines = 0;
    l.font = [UIFont systemFontOfSize:12];
    l.textColor = UIColor.secondaryLabelColor;
    l.text = @"点「更新」后走 LC 自己的安装流程（与在「源」页点安装相同），安装进度请回原列表查看。已经装好最新版、只是版本号对不上的，左滑该行选「忽略此版本」即可，出了更高版本才会再提醒。";
    [l sizeToFit];
    CGRect f = l.frame; f.origin.x = 16; f.origin.y = 12; f.size.width = UIScreen.mainScreen.bounds.size.width - 32; l.frame = f;
    UIView *wrap = [[UIView alloc] initWithFrame:CGRectMake(0, 0, UIScreen.mainScreen.bounds.size.width, CGRectGetMaxY(f) + 12)];
    [wrap addSubview:l];
    return wrap;
}
- (void)doneTapped { [self dismissViewControllerAnimated:YES completion:nil]; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return (NSInteger)self.items.count; }
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"upd"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"upd"];
    NSDictionary *u = self.items[indexPath.row];
    cell.textLabel.text = LGString(u[@"title"]);
    cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ → %@ · %@", LGString(u[@"installedVersion"]), LGString(u[@"version"]), LGString(u[@"source"])];
    UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
    [btn setTitle:@"更新" forState:UIControlStateNormal];
    btn.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    btn.tag = indexPath.row;
    [btn sizeToFit];
    CGRect f = btn.frame; f.size.width += 16; btn.frame = f;
    [btn addTarget:self action:@selector(updateTapped:) forControlEvents:UIControlEventTouchUpInside];
    cell.accessoryView = btn;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    return cell;
}
- (void)updateTapped:(UIButton *)sender {
    if (sender.tag < 0 || sender.tag >= (NSInteger)self.items.count) return;
    NSDictionary *u = self.items[sender.tag];
    NSURL *url = [NSURL URLWithString:LGString(u[@"downloadURL"])];
    if (!url) return;
    // 与 LC「源」页点安装发的完全相同：LCAppListView 收到后走 installFromUrl
    [[NSNotificationCenter defaultCenter] postNotificationName:@"InstallAppNotification" object:@{ @"url": url }];
    // 记为已处理并立刻摘掉提醒：上游包内版本字符串不跟着涨的 App
    // （如 Asspp 4.2.2 包里仍写 4.2.0）靠版本号永远追不平
    LGSetUpdateAck(LGString(u[@"bundle"]), LGString(u[@"version"]));
    if (LGString(u[@"bundle"]).length) [LGUpdateMap removeObjectForKey:LGString(u[@"bundle"])];
    LGNotifyUpdatesChanged();
    [self dismissViewControllerAnimated:YES completion:nil];
}

// 左滑「忽略此版本」：已经装好最新包、只是上游版本字符串没涨这类
// 情况，不必重装，忽略后同一版本不再提醒、出了更高版本才再报
- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.row < 0 || indexPath.row >= (NSInteger)self.items.count) return nil;
    NSDictionary *u = self.items[indexPath.row];
    UIContextualAction *ignore = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal title:@"忽略此版本" handler:^(UIContextualAction *action, UIView *sourceView, void (^completion)(BOOL)) {
        LGSetUpdateAck(LGString(u[@"bundle"]), LGString(u[@"version"]));
        if (LGString(u[@"bundle"]).length) [LGUpdateMap removeObjectForKey:LGString(u[@"bundle"])];
        LGNotifyUpdatesChanged();
        NSMutableArray *rest = [self.items mutableCopy];
        [rest removeObjectAtIndex:indexPath.row];
        self.items = rest;
        [tableView deleteRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationAutomatic];
        if (!self.items.count) [self dismissViewControllerAnimated:YES completion:nil];
        completion(YES);
    }];
    ignore.backgroundColor = UIColor.systemGrayColor;
    return [UISwipeActionsConfiguration configurationWithActions:@[ignore]];
}
@end

@interface LGGridViewController : UIViewController <UICollectionViewDataSource, UICollectionViewDelegate, UICollectionViewDelegateFlowLayout, UISearchBarDelegate>
@property (nonatomic, strong) UICollectionView *collectionView;
@property (nonatomic, strong) UISearchBar *searchBar;
@property (nonatomic, strong) NSArray<NSDictionary *> *apps;
@property (nonatomic, strong) NSArray<NSDictionary *> *shown;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, strong) NSLayoutConstraint *barTop;
@property (nonatomic, strong) UIView *updateBanner;
@property (nonatomic, strong) UILabel *updateBannerLabel;
@property (nonatomic, strong) NSLayoutConstraint *updateBannerHeight;
@property (nonatomic, assign) NSTimeInterval lastSyncTime;
@property (nonatomic, assign) NSInteger lastSyncIndex;
@end

@implementation LGGridViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    if (@available(iOS 13.0, *)) self.view.backgroundColor = UIColor.systemBackgroundColor;
    else self.view.backgroundColor = UIColor.whiteColor;

    UIView *bar = [[UIView alloc] init];
    bar.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:bar];

    UILabel *title = [[UILabel alloc] init];
    title.text = @"App";
    title.font = [UIFont systemFontOfSize:28 weight:UIFontWeightBold];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    [bar addSubview:title];

    self.searchBar = [[UISearchBar alloc] init];
    self.searchBar.placeholder = @"搜索";
    self.searchBar.searchBarStyle = UISearchBarStyleMinimal;
    self.searchBar.delegate = self;
    self.searchBar.translatesAutoresizingMaskIntoConstraints = NO;
    [bar addSubview:self.searchBar];

    self.updateBanner = [[UIView alloc] init];
    if (@available(iOS 13.0, *)) self.updateBanner.backgroundColor = UIColor.secondarySystemBackgroundColor;
    self.updateBanner.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.updateBanner];
    self.updateBannerLabel = [[UILabel alloc] init];
    self.updateBannerLabel.font = [UIFont systemFontOfSize:13.5 weight:UIFontWeightMedium];
    self.updateBannerLabel.textColor = UIColor.systemBlueColor;
    self.updateBannerLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.updateBanner addSubview:self.updateBannerLabel];
    // 横幅点击改用 UIControl 覆盖层承接（手势识别在 LC 的 Hosting 层级
    // 里实测不触发，UIControl 的 target-action 可靠）
    UIControl *bannerTap = [[UIControl alloc] init];
    bannerTap.translatesAutoresizingMaskIntoConstraints = NO;
    [bannerTap addTarget:self action:@selector(updatesBannerTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.updateBanner addSubview:bannerTap];
    self.updateBannerHeight = [self.updateBanner.heightAnchor constraintEqualToConstant:0];

    UICollectionViewFlowLayout *layout = [[UICollectionViewFlowLayout alloc] init];
    layout.minimumInteritemSpacing = 8;
    layout.minimumLineSpacing = 14;
    layout.sectionInset = UIEdgeInsetsMake(10, 14, 24, 14);
    self.collectionView = [[UICollectionView alloc] initWithFrame:CGRectZero collectionViewLayout:layout];
    self.collectionView.dataSource = self;
    self.collectionView.delegate = self;
    self.collectionView.backgroundColor = UIColor.clearColor;
    self.collectionView.alwaysBounceVertical = YES;
    self.collectionView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    [self.collectionView registerClass:LGGridCell.class forCellWithReuseIdentifier:LGCellID];
    self.collectionView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.collectionView];

    UIRefreshControl *rc = [[UIRefreshControl alloc] init];
    [rc addTarget:self action:@selector(reloadApps) forControlEvents:UIControlEventValueChanged];
    self.collectionView.refreshControl = rc;

    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleLarge];
    self.spinner.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.spinner];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    self.barTop = [bar.topAnchor constraintEqualToAnchor:self.view.topAnchor];
    [NSLayoutConstraint activateConstraints:@[
        self.barTop,
        [bar.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [bar.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [title.leadingAnchor constraintEqualToAnchor:bar.leadingAnchor constant:18],
        [title.topAnchor constraintEqualToAnchor:bar.topAnchor constant:6],
        [self.searchBar.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:2],
        [self.searchBar.leadingAnchor constraintEqualToAnchor:bar.leadingAnchor constant:8],
        [self.searchBar.trailingAnchor constraintEqualToAnchor:bar.trailingAnchor constant:-8],
        [self.searchBar.bottomAnchor constraintEqualToAnchor:bar.bottomAnchor],
        [self.updateBanner.topAnchor constraintEqualToAnchor:bar.bottomAnchor],
        [self.updateBanner.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.updateBanner.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        self.updateBannerHeight,
        [self.updateBannerLabel.leadingAnchor constraintEqualToAnchor:self.updateBanner.leadingAnchor constant:18],
        [self.updateBannerLabel.trailingAnchor constraintEqualToAnchor:self.updateBanner.trailingAnchor constant:-12],
        [self.updateBannerLabel.centerYAnchor constraintEqualToAnchor:self.updateBanner.centerYAnchor],
        [bannerTap.topAnchor constraintEqualToAnchor:self.updateBanner.topAnchor],
        [bannerTap.bottomAnchor constraintEqualToAnchor:self.updateBanner.bottomAnchor],
        [bannerTap.leadingAnchor constraintEqualToAnchor:self.updateBanner.leadingAnchor],
        [bannerTap.trailingAnchor constraintEqualToAnchor:self.updateBanner.trailingAnchor],
        [self.collectionView.topAnchor constraintEqualToAnchor:self.updateBanner.bottomAnchor],
        [self.collectionView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.collectionView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.collectionView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [self.spinner.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.spinner.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
    ]];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(refreshUpdateUI) name:LGUpdatesChangedNotification object:nil];
    __weak typeof(self) weakSelf = self;
    LGUpdateUIHook = ^{ [weakSelf refreshUpdateUI]; };
    [self reloadApps];
    [self refreshUpdateUI];
}

// 每次列表刷新后本地修剪更新提醒：已装版本已追上源版本（刚更新完）
// 或 App 已卸载的条目立刻摘掉，不等下一轮拉源检查（拉源有半小时
// 节流，v25 初版就是卡在这里：装完更新提醒不消失）。
- (void)pruneStaleUpdatesWithApps:(NSArray *)apps {
    if (!LGUpdateMap.count) return;
    NSDictionary *ackMap = LGUpdateAckMap();
    NSMutableSet *still = [NSMutableSet set];
    for (NSDictionary *app in apps) {
        NSString *bid = LGString(app[@"bundle"]);
        NSDictionary *u = bid.length ? LGUpdateMap[bid] : nil;
        if (!u) continue;
        if (LGUpdateIsAcked(bid, LGString(u[@"version"]), ackMap)) continue;
        NSString *installed = LGString(app[@"version"]);
        if (installed.length && LGCompareVersion(LGString(u[@"version"]), installed) == NSOrderedDescending)
            [still addObject:bid];
    }
    if (still.count == LGUpdateMap.count) return;
    NSMutableDictionary *kept = [NSMutableDictionary dictionary];
    for (NSString *bid in still) kept[bid] = LGUpdateMap[bid];
    LGUpdateMap = kept;
    [self refreshUpdateUI];
}

// 源更新检查有结果时刷新：横幅计数 + 图标角标
- (void)refreshUpdateUI {
    NSUInteger n = LGUpdateMap.count;
    self.updateBannerHeight.constant = n ? 34 : 0;
    self.updateBanner.hidden = (n == 0); // 高度约束之外再加 hidden 兜底
    if (!n) self.updateBannerLabel.text = nil;
    if (n) {
        NSArray *vals = LGUpdateMap.allValues;
        NSString *first = LGString(vals.firstObject[@"title"]);
        self.updateBannerLabel.text = n > 1
            ? [NSString stringWithFormat:@"↑ 有 %lu 个 App 可更新（%@ 等）", (unsigned long)n, first]
            : [NSString stringWithFormat:@"↑ %@ 可更新到 %@", first, LGString(vals.firstObject[@"version"])];
    }
    [self.collectionView reloadData];
    [self.view setNeedsLayout];
}

- (void)updatesBannerTapped {
    [self.searchBar resignFirstResponder];
    if (!LGUpdateMap.count) return;
    NSArray *items = [LGUpdateMap.allValues sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [LGString(a[@"title"]) localizedStandardCompare:LGString(b[@"title"])];
    }];
    LGUpdateListViewController *vc = [[LGUpdateListViewController alloc] initWithStyle:UITableViewStylePlain];
    vc.items = items;
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    if (@available(iOS 13.0, *)) nav.modalPresentationStyle = UIModalPresentationPageSheet;
    [LGTopPresenter(self) presentViewController:nav animated:YES completion:nil];
}

- (void)viewWillTransitionToSize:(CGSize)size withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator {
    [super viewWillTransitionToSize:size withTransitionCoordinator:coordinator];
    [coordinator animateAlongsideTransition:^(id ctx) { [self.collectionView.collectionViewLayout invalidateLayout]; } completion:nil];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    // 顶部给 LC 自己的导航栏让位：网格嵌在导航内容层里，导航栏（顶部
    // 菜单）在外层显示，我的顶栏从导航栏下沿开始排。
    CGFloat navBottom = 0;
    for (UIViewController *p = self.parentViewController; p; p = p.parentViewController) {
        if ([p isKindOfClass:UINavigationController.class]) {
            UINavigationBar *nb = ((UINavigationController *)p).navigationBar;
            if (nb && !nb.hidden) {
                CGRect r = [nb convertRect:nb.bounds toView:self.view];
                if (r.size.height > 0) navBottom = CGRectGetMaxY(r);
            }
            break;
        }
    }
    CGFloat wantTop = navBottom > 0 ? navBottom + 4 : self.view.safeAreaInsets.top;
    if (fabs(self.barTop.constant - wantTop) > 0.5) self.barTop.constant = wantTop;
    // 底栏避让：网格填满标签页托管视图、会伸到半透明底栏之下，自动安全区
    // 只给了主屏幕指示条那截，最后一行会被底栏压住滚不出来。把差额补进
    // 列表底部内边距，使内容总底部留白等于底栏高度。
    CGFloat tabBarHeight = 0;
    for (UIViewController *p = self.parentViewController; p; p = p.parentViewController) {
        if ([p isKindOfClass:UITabBarController.class]) {
            tabBarHeight = ((UITabBarController *)p).tabBar.bounds.size.height;
            break;
        }
    }
    CGFloat need = tabBarHeight - self.collectionView.safeAreaInsets.bottom;
    if (need < 0) need = 0;
    if (fabs(self.collectionView.contentInset.bottom - need) > 0.5) {
        UIEdgeInsets insets = self.collectionView.contentInset;
        insets.bottom = need;
        self.collectionView.contentInset = insets;
    }
}

- (void)reloadApps {
    [self.spinner startAnimating];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSArray *apps = LGScanApps();
        dispatch_async(dispatch_get_main_queue(), ^{
            self.apps = apps;
            [self pruneStaleUpdatesWithApps:apps];
            [self refreshUpdateUI]; // 横幅与角标每次刷新都强制对齐一次
            [self applyFilter];
            [self.collectionView layoutIfNeeded];
            [self syncOriginalListToVisible];
            [self.spinner stopAnimating];
            if (self.collectionView.refreshControl.refreshing) {
                // 用户下拉刷新：强制同步查一遍源更新（不走半小时节流），
                // 检查结束才收刷新动画，角标与横幅当场就是最新结果
                LGCheckForUpdatesWithCompletion(YES, ^{
                    [self.collectionView.refreshControl endRefreshing];
                });
            } else {
                [self.collectionView.refreshControl endRefreshing];
                LGCheckForUpdates(NO); // 程序触发的刷新只顺带自动检查（半小时节流）
            }
        });
    });
}

// 网格滚动时持续把原列表的滚动位置同步过来（让目标横幅被 LC 实现出来，
// 长按才能借到它本人的完整菜单）；点按/长按落点时更要抢先同步到那个
// App——从落指到菜单弹出约有半秒，正好够 LC 把横幅懒加载出来。
- (void)syncOriginalListToVisible {
    NSArray *ips = self.collectionView.indexPathsForVisibleItems;
    if (!ips.count) return;
    NSInteger lo = NSNotFound, hi = 0;
    for (NSIndexPath *ip in ips) {
        if (lo == NSNotFound || ip.item < lo) lo = ip.item;
        if (ip.item > hi) hi = ip.item;
    }
    if (lo != NSNotFound) LGSyncOriginalList((lo + hi) / 2);
}

- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
    if (scrollView != self.collectionView) return;
    NSTimeInterval t = NSDate.timeIntervalSinceReferenceDate;
    if (t - self.lastSyncTime < 0.12) return;
    NSArray *ips = self.collectionView.indexPathsForVisibleItems;
    if (!ips.count) return;
    NSInteger lo = NSNotFound, hi = 0;
    for (NSIndexPath *ip in ips) {
        if (lo == NSNotFound || ip.item < lo) lo = ip.item;
        if (ip.item > hi) hi = ip.item;
    }
    if (lo == NSNotFound) return;
    NSInteger mid = (lo + hi) / 2;
    if (mid == self.lastSyncIndex) return;
    self.lastSyncTime = t;
    self.lastSyncIndex = mid;
    LGSyncOriginalList(mid);
}

- (void)collectionView:(UICollectionView *)collectionView didHighlightItemAtIndexPath:(NSIndexPath *)indexPath {
    LGSyncOriginalList(indexPath.item);
}

- (void)scrollViewDidEndDecelerating:(UIScrollView *)scrollView {
    if (scrollView == self.collectionView) [self syncOriginalListToVisible];
}

- (void)scrollViewDidEndDragging:(UIScrollView *)scrollView willDecelerate:(BOOL)decelerate {
    if (scrollView == self.collectionView && !decelerate) [self syncOriginalListToVisible];
}

- (void)applyFilter {
    NSString *q = self.searchBar.text;
    if (!q.length) self.shown = self.apps;
    else {
        NSMutableArray *out = [NSMutableArray array];
        for (NSDictionary *app in self.apps) {
            if ([app[@"title"] localizedCaseInsensitiveContainsString:q] ||
                [app[@"bundle"] localizedCaseInsensitiveContainsString:q])
                [out addObject:app];
        }
        self.shown = out;
    }
    [self.collectionView reloadData];
}

- (void)closeTapped {
    if (self.parentViewController) {
        // 内嵌模式：藏起网格露出原列表，悬浮按钮出现作为回网格的入口
        LGNoteManualHide();
        self.view.hidden = YES;
        LGSetFloatButtonVisible(YES);
    } else {
        [self dismissViewControllerAnimated:YES completion:nil];
    }
}

- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)searchText { [self applyFilter]; }
- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar { [searchBar resignFirstResponder]; }

// 搜索时给出「取消」按钮作为明确的收键盘出口（此前只有键盘上的搜索
// 键能收，点图标会直接启动 App，用户找不到出口）
- (void)searchBarTextDidBeginEditing:(UISearchBar *)searchBar {
    [searchBar setShowsCancelButton:YES animated:YES];
}
- (void)searchBarTextDidEndEditing:(UISearchBar *)searchBar {
    [searchBar setShowsCancelButton:NO animated:YES];
}
- (void)searchBarCancelButtonClicked:(UISearchBar *)searchBar {
    searchBar.text = @"";
    [self applyFilter];
    [searchBar resignFirstResponder];
}

- (NSInteger)collectionView:(UICollectionView *)cv numberOfItemsInSection:(NSInteger)section { return self.shown.count; }

- (UICollectionViewCell *)collectionView:(UICollectionView *)cv cellForItemAtIndexPath:(NSIndexPath *)indexPath {
    LGGridCell *cell = [cv dequeueReusableCellWithReuseIdentifier:LGCellID forIndexPath:indexPath];
    NSDictionary *app = self.shown[indexPath.item];
    cell.nameLabel.text = app[@"title"];
    BOOL launchable = LGFlag(app[@"launchable"]);
    cell.iconView.alpha = launchable ? 1.0 : 0.5;
    cell.badge.hidden = launchable;
    BOOL is32 = LGFlag(app[@"is32"]);
    cell.jitBadge.hidden = !LGFlag(app[@"jit"]) || is32; // 与 LC 一致：32 位时只显示「32」不显示闪电
    cell.bit32Badge.hidden = !is32;
    cell.lockBadge.hidden = !LGFlag(app[@"locked"]);
    cell.sharedBadge.hidden = !LGFlag(app[@"shared"]);
    cell.updateBadge.hidden = !LGUpdateForBundle(LGString(app[@"bundle"]));
    [cell setNeedsLayout];
    NSString *folder = app[@"folder"];
    UIImage *cachedIcon = [LGIconCache() objectForKey:LGIconCacheKey(app)];
    if (cachedIcon) {
        cell.iconView.image = cachedIcon;
    } else {
        cell.iconView.image = LGPlaceholderIcon(app[@"title"]);
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            UIImage *icon = LGIconForApp(app);
            if (!icon) return;
            dispatch_async(dispatch_get_main_queue(), ^{
                // cell 可能已被复用，核对当前位置的应用再贴图（带淡入）
                NSIndexPath *now = [cv indexPathForCell:cell];
                if (now && now.item < (NSInteger)self.shown.count &&
                    [folder isEqualToString:self.shown[now.item][@"folder"]])
                    [UIView transitionWithView:cell.iconView duration:0.18
                                       options:UIViewAnimationOptionTransitionCrossDissolve
                                    animations:^{ cell.iconView.image = icon; } completion:nil];
            });
        });
    }
    return cell;
}

- (CGSize)collectionView:(UICollectionView *)cv layout:(UICollectionViewLayout *)layout sizeForItemAtIndexPath:(NSIndexPath *)indexPath {
    CGFloat width = cv.bounds.size.width;
    NSInteger columns = width >= 600 ? MAX(4, (NSInteger)(width / 110)) : 4;
    CGFloat itemW = floor((width - 28 - (columns - 1) * 8) / columns);
    return CGSizeMake(itemW, itemW + 30);
}

- (void)collectionView:(UICollectionView *)cv didSelectItemAtIndexPath:(NSIndexPath *)indexPath {
    [cv deselectItemAtIndexPath:indexPath animated:YES];
    [self.searchBar resignFirstResponder];
    NSDictionary *app = self.shown[indexPath.item];
    if (!LGFlag(app[@"launchable"])) {
        NSString *status = LGString(app[@"status"]);
        LGShowAlert(self, app[@"title"], status.length ? [NSString stringWithFormat:@"%@，请回原列表处理。", status] : @"请回原列表启动。");
        return;
    }
    LGPrepareAndLaunch(app, self);
}

// 长按菜单的复刻版：原列表横幅还没被 SwiftUI 实现出来（懒加载）时借不到
// 它本人的菜单，就按 LCAppBannerViewController.makeContextMenu 的构成
// 自己拼一个常用子集；设置/卸载/App Clip 需要 LC 的模型与委托，不复刻，
// 用「回原列表管理」兜底。
- (UIMenu *)fallbackMenuForApp:(NSDictionary *)app {
    NSMutableArray<UIMenuElement *> *section = [NSMutableArray array];
    BOOL builtin = LGFlag(app[@"builtin"]);
    BOOL shared = LGFlag(app[@"shared"]);
    NSString *uuid = LGString(app[@"uuid"]);
    if (!builtin && !shared && uuid.length) {
        NSString *documents = [[app[@"folder"] stringByDeletingLastPathComponent] stringByDeletingLastPathComponent];
        NSString *dataPath = [documents stringByAppendingPathComponent:@"Data/Application"];
        [section addObject:[UIAction actionWithTitle:@"打开数据文件夹" image:[UIImage systemImageNamed:@"folder"] identifier:nil
                                            handler:^(__kindof UIAction *action) {
            NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"shareddocuments://%@/%@", dataPath, uuid]];
            if (url) [UIApplication.sharedApplication openURL:url options:@{} completionHandler:nil];
        }]];
    }
    // 反模式启动（与原菜单一致：默认走多任务时给「启动」，反之给「多任务」）
    BOOL shouldMulti = NO;
    if (!LGFlag(app[@"classicOnly"])) {
        NSInteger specified = LGNumber(app[@"mtSpecified"]);
        shouldMulti = specified == 2 ||
            (specified == 0 && [NSUserDefaults.standardUserDefaults boolForKey:@"LCLaunchInMultitaskMode"]) ||
            LGIsMultitasking();
    }
    __weak typeof(self) weakSelf = self;
    [section addObject:[UIAction actionWithTitle:shouldMulti ? @"启动" : @"多任务"
                                           image:[UIImage systemImageNamed:shouldMulti ? @"play.fill" : @"macwindow.badge.plus"]
                                      identifier:nil
                                         handler:^(__kindof UIAction *action) {
        if (!LGFlag(app[@"launchable"])) {
            NSString *status = LGString(app[@"status"]);
            LGShowAlert(weakSelf, app[@"title"], status.length ? [NSString stringWithFormat:@"%@，请回原列表处理。", status] : @"请回原列表启动。");
            return;
        }
        LGPrepareAndLaunchMode(app, weakSelf, shouldMulti ? 1 : 2);
    }]];
    if (!builtin) {
        NSMutableString *launch = [NSMutableString stringWithFormat:@"livecontainer://livecontainer-launch?bundle-name=%@", [app[@"folder"] lastPathComponent]];
        if (uuid.length) [launch appendFormat:@"&container-folder-name=%@", uuid];
        UIAction *copyLink = [UIAction actionWithTitle:@"复制启动链接" image:[UIImage systemImageNamed:@"link"] identifier:nil
                                              handler:^(__kindof UIAction *action) {
            UIPasteboard.generalPasteboard.string = launch;
        }];
        // LC 的「保存图标」会先让用户选生成样式再存相册；这里直接存图标原图
        UIAction *saveIcon = [UIAction actionWithTitle:@"保存图标" image:[UIImage systemImageNamed:@"square.and.arrow.down"] identifier:nil
                                              handler:^(__kindof UIAction *action) {
            UIImage *icon = LGIconForApp(app);
            if (icon) UIImageWriteToSavedPhotosAlbum(icon, nil, nil, nil);
        }];
        [section addObject:[UIMenu menuWithTitle:@"添加到主屏幕" image:[UIImage systemImageNamed:@"plus.app"]
                                      identifier:nil options:0 children:@[copyLink, saveIcon]]];
    }
    UIMenu *sectionMenu = [UIMenu menuWithTitle:builtin ? @"" : [app[@"folder"] lastPathComponent]
                                          image:nil identifier:nil options:UIMenuOptionsDisplayInline children:section];
    UIAction *manage = [UIAction actionWithTitle:@"回原列表管理" image:[UIImage systemImageNamed:@"list.bullet"] identifier:nil
                                        handler:^(__kindof UIAction *action) { [weakSelf closeTapped]; }];
    return [UIMenu menuWithTitle:@"" children:@[sectionMenu, manage]];
}

- (UIContextMenuConfiguration *)collectionView:(UICollectionView *)collectionView contextMenuConfigurationForItemAtIndexPath:(NSIndexPath *)indexPath point:(CGPoint)point {
    NSDictionary *app = self.shown[indexPath.item];
    UIContextMenuConfiguration *borrowed = LGBorrowedMenuConfiguration(app);
    if (borrowed) {
        // LC 原装菜单里没有回原列表的入口，把「回原列表管理」追加到它
        // 末尾（LC 的菜单项原样装进一个 inline 组保持平铺，动作仍是原装的）
        id provider = nil;
        @try { provider = [borrowed valueForKey:@"actionProvider"]; } @catch (NSException *e) { }
        if (!provider) return borrowed;
        __weak typeof(self) weakSelf = self;
        return [UIContextMenuConfiguration configurationWithIdentifier:nil previewProvider:nil
            actionProvider:^UIMenu * _Nullable(NSArray<UIMenuElement *> * _Nonnull suggestedActions) {
                UIMenu *lcMenu = ((UIMenu *(^)(NSArray *))provider)(suggestedActions ?: @[]);
                UIAction *manage = [UIAction actionWithTitle:@"回原列表管理" image:[UIImage systemImageNamed:@"list.bullet"] identifier:nil
                                                    handler:^(__kindof UIAction *action) { [weakSelf closeTapped]; }];
                if (![lcMenu isKindOfClass:UIMenu.class]) return [UIMenu menuWithTitle:@"" children:@[manage]];
                UIMenu *inlineLC = [UIMenu menuWithTitle:@"" image:nil identifier:nil
                                                 options:UIMenuOptionsDisplayInline children:LGTransformMenuElements(lcMenu.children, app, weakSelf)];
                return [UIMenu menuWithTitle:@"" children:@[inlineLC, manage]];
            }];
    }
    __weak typeof(self) weakSelf = self;
    return [UIContextMenuConfiguration configurationWithIdentifier:nil previewProvider:nil
        actionProvider:^UIMenu * _Nullable(NSArray<UIMenuElement *> * _Nonnull suggestedActions) {
            return [weakSelf fallbackMenuForApp:app];
        }];
}

@end

// 预热：宿主 UI 一就绪就在后台把扫描与图标解码做完，网格首帧直接命中缓存。
static void LGPrewarm(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            for (NSDictionary *app in LGScanApps()) LGIconForApp(app);
            LGCheckForUpdates(NO); // 宿主起来后顺带查一次源更新
        });
    });
}

#pragma mark - 呈现管理

@interface LGPresenter : NSObject
+ (instancetype)shared;
- (void)buttonTapped;
- (void)buttonPan:(UIPanGestureRecognizer *)gesture;
- (void)buttonLongPress:(UILongPressGestureRecognizer *)gesture;
@end

static NSString *const LGPrefAutoShow = @"LCGridHomeAutoShow";
static BOOL LGDidAutoPresent = NO;
static UIButton *LGFloatButton = nil;
static BOOL LGFloatIntent = NO;
static LGGridViewController *LGGrid = nil;

static void LGPresentGrid(void);
static void LGInstallFloatButton(void);
static void LGRemoveCover(BOOL fade);

static UIWindow *LGKeyWindow(void) {
    // 启动早期场景还没到 ForegroundActive：优先活跃场景的窗口，
    // 找不到就退而取任意场景的窗口（遮罩/嵌入要赶在激活完成前就位）
    UIWindow *fallback = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        UIWindow *window = nil;
        for (UIWindow *w in ((UIWindowScene *)scene).windows) if (w.isKeyWindow) window = w;
        if (!window) window = ((UIWindowScene *)scene).windows.firstObject;
        if (!window) continue;
        if (scene.activationState == UISceneActivationStateForegroundActive) return window;
        if (!fallback) fallback = window;
    }
    return fallback;
}

// 启动遮罩：窗口一成为 key 就先盖一层与系统背景同色的遮罩（带小转圈），
// 网格嵌好后淡出撤掉。这样原列表在网格就位前不会被看到，最差也只是一瞬
// 的空白加载，不再闪原列表。4 秒兜底自动撤，异常也不会挡住界面。
static UIView *LGCover = nil;

static void LGRemoveCover(BOOL fade) {
    if (!LGCover) return;
    UIView *cover = LGCover;
    LGCover = nil;
    if (fade) {
        [UIView animateWithDuration:0.25 animations:^{ cover.alpha = 0; }
                         completion:^(BOOL finished) { [cover removeFromSuperview]; }];
    } else {
        [cover removeFromSuperview];
    }
}

static void LGInstallCover(UIWindow *window) {
    if (LGCover || (LGGrid && LGGrid.parentViewController)) return;
    if (!window) window = LGKeyWindow();
    if (!window) return;
    UIView *cover = [[UIView alloc] initWithFrame:window.bounds];
    if (@available(iOS 13.0, *)) cover.backgroundColor = UIColor.systemBackgroundColor;
    else cover.backgroundColor = UIColor.whiteColor;
    cover.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    UIActivityIndicatorView *spin = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    spin.center = CGPointMake(window.bounds.size.width / 2, window.bounds.size.height / 2);
    spin.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin |
                            UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin;
    [spin startAnimating];
    [cover addSubview:spin];
    [window addSubview:cover];
    LGCover = cover;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        LGRemoveCover(YES);
    });
}

// LCAppBannerViewController 是 Swift 类（运行时名带模块前缀），按后缀找。
static Class LGBannerClass(void) {
    static Class cls = Nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        int n = objc_getClassList(NULL, 0);
        if (n <= 0) return;
        Class *list = (Class *)malloc(sizeof(Class) * (unsigned)n);
        objc_getClassList(list, n);
        for (int i = 0; i < n; i++) {
            if ([NSStringFromClass(list[i]) hasSuffix:@"LCAppBannerViewController"]) { cls = list[i]; break; }
        }
        free(list);
    });
    return cls;
}

// 内嵌目标：从任意一个 App 横幅控制器往上找，父级是 UITabBarController 的
// 那一层就是 App 标签页的托管控制器——网格嵌进它便与原列表同层，标签栏、
// 多任务窗口、Dock 的层级都保持 LC 原生，不再需要模态盖屏。
static UIViewController *LGFindEmbedTarget(void) {
    Class bannerCls = LGBannerClass();
    UIWindow *window = LGKeyWindow();
    if (!bannerCls || !window.rootViewController) return nil;
    NSMutableArray<UIViewController *> *stack = [NSMutableArray arrayWithObject:window.rootViewController];
    UIViewController *banner = nil;
    while (stack.count) {
        UIViewController *vc = stack.lastObject;
        [stack removeLastObject];
        if ([vc isKindOfClass:bannerCls]) { banner = vc; break; }
        [stack addObjectsFromArray:vc.childViewControllers];
        if (vc.presentedViewController) [stack addObject:vc.presentedViewController];
    }
    if (!banner) return nil;
    // 首选导航内容层：父级是 UINavigationController 的那一层——网格嵌在
    // 这里只盖住列表内容，LC 的导航栏（顶部菜单）留在外层显示，和底部
    // 标签栏一样不被盖住。找不到导航层时退回标签层（父级是 TabBar 的）。
    UIViewController *node = banner;
    UIViewController *tabLevel = nil;
    while (node.parentViewController) {
        if ([node.parentViewController isKindOfClass:UINavigationController.class]) return node;
        if ([node.parentViewController isKindOfClass:UITabBarController.class]) tabLevel = node;
        node = node.parentViewController;
    }
    return tabLevel;
}

// 借用原列表横幅本人的长按菜单配置：按 Bundle ID / 容器 UUID 在横幅视图
// 的标签文本里对号入座，找到后直接调它自己的
// contextMenuInteraction:configurationForMenuAtLocation: ——拿回来的菜单
// （含容器切换、设置、卸载、添加到主屏幕）是 LC 原装的，动作也绑在它的
// 模型上，行为与原列表长按完全一致。横幅是懒加载的，没实现出来就借不到，
// 调用方会退回复刻菜单。
static UIContextMenuConfiguration *LGBorrowedMenuConfiguration(NSDictionary *app) {
    Class bannerCls = LGBannerClass();
    UIWindow *window = LGKeyWindow();
    if (!bannerCls || !window.rootViewController) return nil;
    NSString *bundle = LGString(app[@"bundle"]);
    NSString *uuid = LGString(app[@"uuid"]);
    NSString *folderName = [LGString(app[@"folder"]) lastPathComponent];
    NSMutableArray<UIViewController *> *stack = [NSMutableArray arrayWithObject:window.rootViewController];
    UIViewController *found = nil;
    while (stack.count) {
        UIViewController *vc = stack.lastObject;
        [stack removeLastObject];
        if ([vc isKindOfClass:bannerCls]) {
            NSMutableString *texts = [NSMutableString string];
            NSMutableArray<UIView *> *vs = [NSMutableArray arrayWithObject:vc.view];
            while (vs.count) {
                UIView *v = vs.lastObject;
                [vs removeLastObject];
                if ([v isKindOfClass:UILabel.class]) {
                    NSString *t = ((UILabel *)v).text;
                    if (t) { [texts appendString:t]; [texts appendString:@"\n"]; }
                }
                if (v.accessibilityLabel.length) { [texts appendString:v.accessibilityLabel]; [texts appendString:@"\n"]; }
                [vs addObjectsFromArray:v.subviews];
            }
            if ((bundle.length && [texts containsString:bundle]) ||
                (uuid.length && [texts containsString:uuid]) ||
                (folderName.length && [texts containsString:folderName])) { found = vc; break; }
            continue;
        }
        [stack addObjectsFromArray:vc.childViewControllers];
        if (vc.presentedViewController) [stack addObject:vc.presentedViewController];
    }
    if (!found) return nil;
    SEL sel = NSSelectorFromString(@"contextMenuInteraction:configurationForMenuAtLocation:");
    if (![found respondsToSelector:sel]) return nil;
    // interaction 只是令牌（LC 的实现不读它），现造一个即可
    UIContextMenuInteraction *interaction = [[UIContextMenuInteraction alloc] initWithDelegate:(id<UIContextMenuInteractionDelegate>)found];
    UIContextMenuConfiguration *config = ((UIContextMenuConfiguration *(*)(id, SEL, UIContextMenuInteraction *, CGPoint))objc_msgSend)(found, sel, interaction, CGPointZero);
    if (![config isKindOfClass:UIContextMenuConfiguration.class]) return nil;
    // 能提前取到菜单就校验非空（actionProvider 非公开 API，取不到就直接用）
    @try {
        id provider = [config valueForKey:@"actionProvider"];
        if (provider) {
            UIMenu *menu = ((UIMenu *(^)(NSArray *))provider)(@[]);
            if (![menu isKindOfClass:UIMenu.class]) return nil;
        }
    } @catch (NSException *e) { }
    return config;
}

// 原列表的滚动视图：SwiftUI 内部的 UIScrollView，在托管控制器子树里
// 找最大的那个（排除网格自己的 collectionView 所在子树）。
static UIScrollView *LGOriginalListScrollView(void) {
    if (!LGGrid || !LGGrid.parentViewController) return nil;
    UIView *root = LGGrid.parentViewController.view;
    UIScrollView *best = nil;
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:root];
    while (stack.count) {
        UIView *v = stack.lastObject;
        [stack removeLastObject];
        if (v == LGGrid.view) continue;
        if ([v isKindOfClass:UIScrollView.class]) {
            UIScrollView *sv = (UIScrollView *)v;
            if (!best || sv.bounds.size.height > best.bounds.size.height) best = sv;
        }
        [stack addObjectsFromArray:v.subviews];
    }
    return best;
}

// 横幅行高：相邻两个已实现横幅在窗口坐标里的间距，测不到用 100 兜底
static CGFloat LGBannerPitch(void) {
    Class cls = LGBannerClass();
    UIWindow *window = LGKeyWindow();
    if (!cls || !window.rootViewController) return 100;
    NSMutableArray<UIViewController *> *stack = [NSMutableArray arrayWithObject:window.rootViewController];
    NSMutableArray<NSNumber *> *tops = [NSMutableArray array];
    while (stack.count) {
        UIViewController *vc = stack.lastObject;
        [stack removeLastObject];
        if ([vc isKindOfClass:cls] && vc.view.window) {
            CGRect r = [vc.view convertRect:vc.view.bounds toView:nil];
            [tops addObject:@(r.origin.y)];
        }
        [stack addObjectsFromArray:vc.childViewControllers];
        if (vc.presentedViewController) [stack addObject:vc.presentedViewController];
    }
    [tops sortUsingSelector:@selector(compare:)];
    CGFloat pitch = 0;
    for (NSUInteger i = 1; i < tops.count; i++) {
        CGFloat d = tops[i].doubleValue - tops[i - 1].doubleValue;
        if (d > 40 && (pitch == 0 || d < pitch)) pitch = d;
    }
    return pitch > 0 ? pitch : 100;
}

// 把原列表的滚动位置同步到网格当前看到的位置：LC 的横幅是懒加载的，
// 只有滚到附近才会被 SwiftUI 实现出来；长按借它本人的菜单前，先确保
// 对应横幅已存在。顺带的好处：切回原列表时位置也大致对齐。
static void LGSyncOriginalList(NSInteger firstVisibleIndex) {
    UIScrollView *sv = LGOriginalListScrollView();
    if (!sv || firstVisibleIndex < 0) return;
    CGFloat pitch = LGBannerPitch();
    CGFloat target = firstVisibleIndex * pitch - sv.bounds.size.height * 0.5;
    CGFloat maxY = sv.contentSize.height - sv.bounds.size.height + sv.contentInset.bottom;
    if (target < -sv.contentInset.top) target = -sv.contentInset.top;
    if (target > maxY) target = maxY;
    if (fabs(sv.contentOffset.y - target) > pitch)
        [sv setContentOffset:CGPointMake(sv.contentOffset.x, target) animated:NO];
}

// 早期目标：横幅还没渲染出来时，先按标签结构定位 App 标签页（LC 的标签只有
// 4 个、或多 LC 精简时的 2 个两种形态，App 分别在下标 1 和 0），让网格赶在
// 原列表画出来之前就位，避免先闪一下原列表再硬切。横幅出现后安装流程会
// 再核对位置，不对就搬正。
static UIViewController *LGFindEmbedTargetEarly(void) {
    UIWindow *window = LGKeyWindow();
    if (!window.rootViewController) return nil;
    NSMutableArray<UIViewController *> *stack = [NSMutableArray arrayWithObject:window.rootViewController];
    UITabBarController *tab = nil;
    while (stack.count) {
        UIViewController *vc = stack.lastObject;
        [stack removeLastObject];
        if ([vc isKindOfClass:UITabBarController.class]) { tab = (UITabBarController *)vc; break; }
        [stack addObjectsFromArray:vc.childViewControllers];
        if (vc.presentedViewController) [stack addObject:vc.presentedViewController];
    }
    if (!tab || tab.viewControllers.count < 2) return nil;
    NSUInteger idx = tab.viewControllers.count == 2 ? 0 : 1;
    UIViewController *tabChild = tab.viewControllers[idx];
    // 同样优先落到导航内容层，让顶部菜单露出来
    NSMutableArray<UIViewController *> *stack2 = [NSMutableArray arrayWithObject:tabChild];
    while (stack2.count) {
        UIViewController *vc = stack2.lastObject;
        [stack2 removeLastObject];
        if ([vc isKindOfClass:UINavigationController.class]) {
            UIViewController *top = ((UINavigationController *)vc).topViewController;
            if (top && top != (UIViewController *)LGGrid) return top;
        }
        [stack2 addObjectsFromArray:vc.childViewControllers];
    }
    return tabChild;
}

static BOOL LGEmbedGrid(void) {
    UIViewController *target = LGFindEmbedTarget() ?: LGFindEmbedTargetEarly();
    if (!target) return NO;
    if (!LGGrid) LGGrid = [[LGGridViewController alloc] init];
    if (LGGrid.parentViewController == target && LGGrid.view.superview == target.view) return YES;
    BOOL fade = target.view.window != nil; // 目标已在屏上：淡入过渡，不硬切
    if (LGGrid.parentViewController) {
        [LGGrid willMoveToParentViewController:nil];
        [LGGrid.view removeFromSuperview];
        [LGGrid removeFromParentViewController];
    }
    [target addChildViewController:LGGrid];
    LGGrid.view.frame = target.view.bounds;
    LGGrid.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    static BOOL didZoomIn = NO;
    BOOL zoom = fade && !didZoomIn; // 首次出现才缩放，巡检搬正不重复播
    if (fade) {
        LGGrid.view.alpha = 0;
        if (zoom) LGGrid.view.transform = CGAffineTransformMakeScale(0.92, 0.92);
    }
    [target.view addSubview:LGGrid.view];
    [LGGrid didMoveToParentViewController:target];
    if (fade) {
        didZoomIn = YES;
        [UIView animateWithDuration:0.34 delay:0 usingSpringWithDamping:0.86 initialSpringVelocity:0 options:0
                         animations:^{ LGGrid.view.alpha = 1; LGGrid.view.transform = CGAffineTransformIdentity; }
                         completion:^(BOOL finished) { LGGrid.view.alpha = 1; LGGrid.view.transform = CGAffineTransformIdentity; }];
    }
    return YES;
}

static void LGSetFloatButtonVisible(BOOL visible) {
    LGFloatIntent = visible;
    if (visible) LGInstallFloatButton();
    if (LGFloatButton) LGFloatButton.hidden = !visible;
}

static void LGStartWatcher(void);
static void LGEnforceOriginalSearchHidden(BOOL hidden);
static void LGShowGrid(void) {
    LGNoteManualHide();
    LGStartWatcher();
    if (LGGrid && LGGrid.parentViewController) {
        LGGrid.view.hidden = NO;
        LGGrid.view.alpha = 0.4;
        LGGrid.view.transform = CGAffineTransformMakeScale(0.97, 0.97);
        [UIView animateWithDuration:0.22 delay:0 options:UIViewAnimationOptionCurveEaseOut
                         animations:^{ LGGrid.view.alpha = 1; LGGrid.view.transform = CGAffineTransformIdentity; }
                         completion:^(BOOL finished) { LGGrid.view.alpha = 1; LGGrid.view.transform = CGAffineTransformIdentity; }];
        LGSetFloatButtonVisible(NO);
    } else if (LGEmbedGrid()) {
        LGGrid.view.hidden = NO;
        LGSetFloatButtonVisible(NO);
    } else {
        LGPresentGrid();
    }
    LGEnforceOriginalSearchHidden(YES);
}

// —— LC 界面监视 ——
// 借来的菜单里「设置」这类动作，是 LC 把新页面推进它自己的 SwiftUI
// 导航层级里呈现的，那个层级在网格之下、会被网格盖住。监视宿主界面树
// （排除网格自己）：一旦发现层级里多出新的 Hosting 控制器（设置页被
// 推进来的信号），就自动把网格藏起来让它露出来；页面退出后，再自动把
// 网格放回来。被 present 出来的界面（上下文菜单、启动 App 的整屏接管、
// Safari 页、弹窗）天生在最上层，不触发让路。
// 用户手动切回原列表（LGNoteManualHide）不触发自动返回。
static NSSet *LGSubtreeSnapshot = nil;
static BOOL LGAutoHidden = NO;
static int LGClearStreak = 0;
static NSTimer *LGWatchTimer = nil;
static NSPointerArray *LGYieldVCs = nil;
static void LGScheduleInstall(void);
static int LGInstallTries;

static void LGNoteManualHide(void) {
    LGAutoHidden = NO;
    LGClearStreak = 0;
    LGSubtreeSnapshot = nil;
    LGYieldVCs = nil;
}

// 只收子控制器层级（不跟 presented 链）：被 present 出来的界面天生盖在
// 一切之上，不会被网格挡住，不需要让路；只有像设置页这样被推进既有
// 层级里的新 Hosting 控制器，才是真的被网格压在下面。
static void LGCollectSubtree(UIViewController *vc, NSMutableSet *out) {
    if (!vc || vc == (UIViewController *)LGGrid) return;
    [out addObject:[NSValue valueWithPointer:(__bridge const void *)vc]];
    for (UIViewController *c in vc.childViewControllers) LGCollectSubtree(c, out);
}

static BOOL LGHasNewHostingVC(NSSet *now) {
    if (!LGSubtreeSnapshot) return NO;
    for (NSValue *v in now) {
        if ([LGSubtreeSnapshot containsObject:v]) continue;
        UIViewController *vc = (__bridge UIViewController *)v.pointerValue;
        if ([NSStringFromClass(vc.class) containsString:@"Hosting"]) return YES;
    }
    return NO;
}

// LC 主窗口：根子树里带 UITabBarController 的那个窗口
static UIWindow *LGHostWindow(void) {
    UIWindow *fallback = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *w in ((UIWindowScene *)scene).windows) {
            if (!fallback) fallback = w;
            if (!w.rootViewController) continue;
            NSMutableArray<UIViewController *> *stack = [NSMutableArray arrayWithObject:w.rootViewController];
            while (stack.count) {
                UIViewController *c = stack.lastObject;
                [stack removeLastObject];
                if ([c isKindOfClass:UITabBarController.class]) return w;
                [stack addObjectsFromArray:c.childViewControllers];
                if (c.presentedViewController) [stack addObject:c.presentedViewController];
            }
        }
    }
    return fallback;
}

// 某控制器是否还挂在主窗口的界面树里（LC 重建层级后旧父级会脱离）
static BOOL LGIsReachable(UIViewController *vc) {
    UIWindow *w = LGHostWindow();
    if (!w.rootViewController || !vc) return NO;
    NSMutableArray<UIViewController *> *stack = [NSMutableArray arrayWithObject:w.rootViewController];
    while (stack.count) {
        UIViewController *c = stack.lastObject;
        [stack removeLastObject];
        if (c == vc) return YES;
        [stack addObjectsFromArray:c.childViewControllers];
        if (c.presentedViewController) [stack addObject:c.presentedViewController];
    }
    return NO;
}

// 让路时记住冒出来的那几个 Hosting 控制器：它们全部离场（或正在被 pop
// 滑出）就立刻还网格，不必等层级快照连续两轮干净——退出设置时网格能
// 跟着返回动画一起回来，不再先露一截原列表。
static BOOL LGYieldCleared(void) {
    if (!LGYieldVCs.count) return NO;
    for (UIViewController *vc in LGYieldVCs) {
        if (!vc) continue;
        UIView *v = vc.viewIfLoaded;
        if (!v || !v.window) continue;
        CGRect frame = [v convertRect:v.bounds toView:nil];
        if (frame.origin.x > 80) continue; // 正在被 pop 滑出
        return NO;
    }
    return YES;
}

static void LGReshowGrid(NSSet *now) {
    LGAutoHidden = NO;
    LGClearStreak = 0;
    LGYieldVCs = nil;
    LGSubtreeSnapshot = now;
    LGShowGrid();
    [LGGrid reloadApps]; // 在 LC 那边可能装/卸了 App，回来时刷新一遍
}

// —— 原列表搜索栏抑制 ——
// LCAppListView 用 SwiftUI .searchable 在导航栏里装了自己的搜索栏，
// 网格又有自己的，两个同屏就是重复（从别的标签页切回来时 SwiftUI 会
// 把原搜索栏重新装上，实测出现双搜索栏）。网格显示期间把原搜索控制器
// 从 navigationItem 上摘掉暂存，网格让路/切回原列表时原样装回；切标签
// 回来被 SwiftUI 重装的，监视 tick 会在 0.35 秒内再次摘掉。
static __weak UIViewController *LGSearchOwner = nil;
static UISearchController *LGStashedSearch = nil;

static void LGCollectSearchOwner(UIViewController *vc, UIViewController **owner) {
    if (!vc || *owner || vc == (UIViewController *)LGGrid) return;
    if (vc.navigationItem.searchController) { *owner = vc; return; }
    for (UIViewController *c in vc.childViewControllers) LGCollectSearchOwner(c, owner);
}

static void LGEnforceOriginalSearchHidden(BOOL hidden) {
    if (!LGGrid) return;
    if (hidden) {
        UIViewController *root = LGGrid.parentViewController;
        if (!root) return;
        UIViewController *owner = nil;
        LGCollectSearchOwner(root, &owner);
        if (!owner) {
            UIViewController *p = root;
            while (p && ![p isKindOfClass:UINavigationController.class]) p = p.parentViewController;
            if (p) for (UIViewController *vc in ((UINavigationController *)p).viewControllers) {
                LGCollectSearchOwner(vc, &owner);
                if (owner) break;
            }
        }
        if (owner) {
            UISearchController *sc = owner.navigationItem.searchController;
            if (sc.isActive) sc.active = NO;
            if (!LGStashedSearch) { LGStashedSearch = sc; LGSearchOwner = owner; }
            owner.navigationItem.searchController = nil;
        }
    } else {
        if (LGStashedSearch && LGSearchOwner && !LGSearchOwner.navigationItem.searchController)
            LGSearchOwner.navigationItem.searchController = LGStashedSearch;
        LGStashedSearch = nil;
        LGSearchOwner = nil;
    }
}

// 已装 App 指纹：两个 Applications 根目录下每个 .app 条目名 + 其
// LCAppInfo.plist 修改时间。在别处（原列表、设置页、借用菜单）安装、
// 卸载或原地更新 App，指纹都会变，监视 tick 据此自动刷新网格，不必
// 等用户下拉。读目录 + stat 开销很小，0.35 秒一轮无压力。
static NSString *LGAppsFingerprint(void) {
    const char *raw = getenv("LC_HOME_PATH");
    NSString *home = (raw && raw[0]) ? [NSString stringWithUTF8String:raw] : nil;
    if (!home.length) return @"";
    NSMutableArray<NSString *> *roots = [NSMutableArray arrayWithObject:[home stringByAppendingPathComponent:@"Documents/Applications"]];
    NSString *group = LGString(LGClassCall(NSUserDefaults.class, @"lcAppGroupPath"));
    if (group.length) [roots addObject:[group stringByAppendingPathComponent:@"LiveContainer/Applications"]];
    NSFileManager *fm = NSFileManager.defaultManager;
    NSMutableString *fp = [NSMutableString string];
    for (NSString *root in roots) {
        [fp appendString:@"#"];
        for (NSString *entry in [fm contentsOfDirectoryAtPath:root error:nil]) {
            if (![entry hasSuffix:@".app"]) continue;
            NSString *plist = [[root stringByAppendingPathComponent:entry] stringByAppendingPathComponent:@"LCAppInfo.plist"];
            NSDate *mtime = [fm attributesOfItemAtPath:plist error:nil][NSFileModificationDate];
            [fp appendFormat:@"%@|%.0f;", entry, mtime ? mtime.timeIntervalSinceReferenceDate : 0.0];
        }
    }
    return fp;
}

static void LGWatchTick(void) {
    if (!LGGrid || !LGGrid.parentViewController || !LGIsHostUI()) return;

    // 网格显示时摘掉原列表的搜索栏、网格藏起时装回（详见抑制一节）
    LGEnforceOriginalSearchHidden(!LGGrid.view.hidden);

    // 自愈：LC 重建界面层级后网格父级会脱离窗口，重新走安装链嵌回新层级；
    // 悬浮按钮若被别的窗口顶掉（装在旧窗口里），也装回主窗口。
    static NSTimeInterval lastHeal = 0;
    NSTimeInterval nowT = NSDate.timeIntervalSinceReferenceDate;
    if (!LGAutoHidden && UIApplication.sharedApplication.applicationState == UIApplicationStateActive
        && !LGIsReachable(LGGrid.parentViewController) && nowT - lastHeal > 5) {
        lastHeal = nowT;
        LGInstallTries = 0;
        LGScheduleInstall();
    }
    UIWindow *hostWindow = LGHostWindow();
    if (LGFloatIntent && LGKeyWindow() == hostWindow && (!LGFloatButton || LGFloatButton.window != hostWindow)) {
        LGFloatButton = nil;
        LGInstallFloatButton();
    }

    // 排序完全跟随 LC：它在顶部菜单里改了排序方式或自定义顺序时，
    // 网格检测到偏好变化就自动重排（指纹 = 类型 + 自定义顺序全文）
    static NSString *sortFinger = nil;
    NSUserDefaults *gd = LGAppGroupDefaults();
    NSArray *ord = [gd arrayForKey:@"LCCustomSortOrder"];
    NSString *finger = [NSString stringWithFormat:@"%@|%@",
        [gd stringForKey:@"LCAppSortType"] ?: @"default",
        [ord isKindOfClass:NSArray.class] ? [ord componentsJoinedByString:@","] : @""];
    if (sortFinger && ![finger isEqualToString:sortFinger] && !LGGrid.view.hidden) [LGGrid reloadApps];
    sortFinger = finger;

    // 深色图标开关同理跟随 LC：它在设置里切换时清掉图标缓存并重扫，
    // 网格立刻换成另一套图标，不用重启 LC。
    static BOOL darkFingerInit = NO;
    static BOOL darkFinger = NO;
    BOOL darkNow = [gd boolForKey:@"darkModeIcon"];
    if (darkFingerInit && darkNow != darkFinger && !LGGrid.view.hidden) {
        [LGIconCache() removeAllObjects];
        [LGGrid reloadApps];
    }
    darkFingerInit = YES;
    darkFinger = darkNow;

    // 装/卸 App 自动感知：在原列表、设置页或借用菜单里装卸、更新后，
    // 指纹一变网格就自己重扫，卸载的 App 立刻消失，不必等下拉刷新
    static NSString *appsFinger = nil;
    NSString *appsNow = LGAppsFingerprint();
    if (appsFinger && ![appsNow isEqualToString:appsFinger] && !LGGrid.view.hidden) [LGGrid reloadApps];
    appsFinger = appsNow;

    // 只监视 App 标签页自己的子树：其他标签页的界面变化与网格无关，
    // 混进来会让网格无故失效。范围放宽到导航层——设置页是推进同一个
    // 导航控制器的，是网格父级的兄弟。
    UIViewController *watchRoot = LGGrid.parentViewController;
    if ([watchRoot.parentViewController isKindOfClass:UINavigationController.class])
        watchRoot = watchRoot.parentViewController;
    NSMutableSet *now = [NSMutableSet set];
    LGCollectSubtree(watchRoot, now);
    // 启动 App 时 LC 是整屏接管（present 或换根控制器），天生盖住一切，
    // 不在子层级里新增 Hosting 控制器——不会触发让路，网格不会闪退。
    BOOL lcUI = LGHasNewHostingVC(now);
    if (!LGGrid.view.hidden) {
        if (lcUI) {
            LGAutoHidden = YES;
            LGClearStreak = 0;
            LGYieldVCs = [NSPointerArray weakObjectsPointerArray];
            for (NSValue *v in now) {
                if ([LGSubtreeSnapshot containsObject:v]) continue;
                UIViewController *vc = (__bridge UIViewController *)v.pointerValue;
                if ([NSStringFromClass(vc.class) containsString:@"Hosting"])
                    [LGYieldVCs addPointer:(__bridge void *)vc];
            }
            LGGrid.view.hidden = YES;
            LGSetFloatButtonVisible(YES);
        } else {
            LGSubtreeSnapshot = now;
        }
    } else if (LGAutoHidden) {
        if (LGYieldCleared()) {
            LGReshowGrid(now);
        } else if (lcUI) {
            LGClearStreak = 0;
        } else if (++LGClearStreak >= 2) {
            LGReshowGrid(now);
        }
    }
}

static void LGStartWatcher(void) {
    if (LGWatchTimer) return;
    LGWatchTimer = [NSTimer scheduledTimerWithTimeInterval:0.35 repeats:YES block:^(NSTimer *t) { LGWatchTick(); }];
}

static UIViewController *LGTopViewController(void) {
    UIWindow *window = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        if (scene.activationState != UISceneActivationStateForegroundActive) continue;
        for (UIWindow *w in ((UIWindowScene *)scene).windows) if (w.isKeyWindow) window = w;
        if (!window) window = ((UIWindowScene *)scene).windows.firstObject;
        if (window) break;
    }
    UIViewController *top = window.rootViewController;
    while (top.presentedViewController) top = top.presentedViewController;
    return top;
}

static void LGPresentGrid(void) {
    UIViewController *top = LGTopViewController();
    if (!top || [top isKindOfClass:LGGridViewController.class]) return;
    if ([top.presentedViewController isKindOfClass:LGGridViewController.class]) return;
    LGGridViewController *grid = (LGGrid && !LGGrid.parentViewController && !LGGrid.presentingViewController)
        ? LGGrid : [[LGGridViewController alloc] init];
    grid.modalPresentationStyle = UIModalPresentationFullScreen;
    [top presentViewController:grid animated:YES completion:nil];
}

static void LGInstallFloatButton(void) {
    if (LGFloatButton && LGFloatButton.window) return;
    UIViewController *top = LGTopViewController();
    UIWindow *window = top.view.window;
    if (!window) return;
    UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
    btn.frame = CGRectMake(window.bounds.size.width - 60, window.bounds.size.height * 0.55, 46, 46);
    btn.backgroundColor = [UIColor colorWithWhite:0.15 alpha:0.75];
    btn.layer.cornerRadius = 23;
    btn.tintColor = UIColor.whiteColor;
    [btn setImage:[UIImage systemImageNamed:@"square.grid.2x2.fill"] forState:UIControlStateNormal];
    if (!btn.currentImage) [btn setTitle:@"网格" forState:UIControlStateNormal];
    [btn addTarget:LGPresenter.shared action:@selector(buttonTapped) forControlEvents:UIControlEventTouchUpInside];
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:LGPresenter.shared action:@selector(buttonPan:)];
    [btn addGestureRecognizer:pan];
    UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc] initWithTarget:LGPresenter.shared action:@selector(buttonLongPress:)];
    lp.minimumPressDuration = 0.6;
    [btn addGestureRecognizer:lp];
    [window addSubview:btn];
    btn.hidden = !LGFloatIntent;
    LGFloatButton = btn;
}

// 悬浮按钮的动作目标（单例）
@implementation LGPresenter
+ (instancetype)shared {
    static LGPresenter *p;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ p = [LGPresenter new]; });
    return p;
}
- (void)buttonTapped { LGShowGrid(); }
- (void)buttonPan:(UIPanGestureRecognizer *)gesture {
    UIView *v = gesture.view;
    if (!v) return;
    CGPoint t = [gesture translationInView:v.superview];
    v.center = CGPointMake(v.center.x + t.x, v.center.y + t.y);
    [gesture setTranslation:CGPointZero inView:v.superview];
    if (gesture.state == UIGestureRecognizerStateEnded) {
        CGRect b = v.superview.bounds;
        CGFloat x = (v.center.x < b.size.width / 2) ? 34 : b.size.width - 34;
        [UIView animateWithDuration:0.25 animations:^{
            v.center = CGPointMake(x, MIN(MAX(v.center.y, 90), b.size.height - 90));
        }];
    }
}
- (void)buttonLongPress:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateBegan) return;
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    BOOL current = [d objectForKey:LGPrefAutoShow] ? [d boolForKey:LGPrefAutoShow] : YES; // 键不存在视为开
    BOOL on = !current;
    [d setBool:on forKey:LGPrefAutoShow];
    UIViewController *top = LGTopViewController();
    if (top) LGShowAlert(top, @"LCGridHome", on ? @"已开启：打开 LC 时自动显示网格主页。" : @"已关闭自动显示，用悬浮按钮打开网格。");
}
@end

#pragma mark - 入口

static int LGInstallTries = 0;
static BOOL LGChainActive = NO;
static void LGInstallPass(void);

static void LGScheduleInstall(void) {
    if (LGChainActive) return;
    LGChainActive = YES;
    LGInstallPass();
}

static void LGInstallPass(void) {
    // 前几轮密一点，赶在 LC 自己的列表渲染完之前就位；之后放宽
    NSTimeInterval delay = LGInstallTries < 10 ? 0.15 : (LGInstallTries < 16 ? 0.3 : 0.6);
    dispatch_async(dispatch_get_main_queue(), ^{
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (!LGIsHostUI()) { LGChainActive = NO; return; }
            NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
            BOOL autoShow = [d objectForKey:LGPrefAutoShow] ? [d boolForKey:LGPrefAutoShow] : YES;
            LGPrewarm();
            BOOL embedded = (LGGrid && LGGrid.parentViewController) || LGEmbedGrid();
            if (embedded) {
                LGRemoveCover(YES);
                LGStartWatcher();
                if (!LGDidAutoPresent) {
                    LGDidAutoPresent = YES;
                    LGGrid.view.hidden = !autoShow;
                    LGSetFloatButtonVisible(!autoShow);
                } else {
                    // 已初始化过：保持用户当前选择，只同步悬浮按钮
                    LGSetFloatButtonVisible(LGGrid.view.hidden);
                }
                // 预热期继续巡检：横幅出现后核对内嵌位置（早期定位可能偏），
                // 并把网格视图保持在托管视图最上层，防 SwiftUI 后画的内容盖住
                if (LGInstallTries < 16) {
                    LGInstallTries++;
                    UIViewController *real = LGFindEmbedTarget();
                    if (real && real != LGGrid.parentViewController) LGEmbedGrid();
                    else if (LGGrid.parentViewController)
                        [LGGrid.parentViewController.view bringSubviewToFront:LGGrid.view];
                    LGInstallPass();
                } else {
                    LGInstallTries = 0;
                    LGChainActive = NO;
                }
                return;
            }
            if (LGInstallTries < 16) {
                LGInstallTries++;
                LGInstallPass(); // 内嵌位置还没出现，稍后重试
                return;
            }
            // 始终找不到内嵌位置：退回旧形态（悬浮按钮 + 模态展示）
            LGInstallTries = 0;
            LGChainActive = NO;
            LGRemoveCover(NO);
            LGSetFloatButtonVisible(YES);
            if (autoShow && !LGDidAutoPresent) {
                LGDidAutoPresent = YES;
                LGPresentGrid();
            }
        });
    });
}

__attribute__((constructor)) static void LGInit(void) {
    @autoreleasepool {
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                          object:nil queue:NSOperationQueue.mainQueue
                                                      usingBlock:^(NSNotification *note) { LGScheduleInstall(); }];
        // 窗口成为 key 的时机更早：先盖遮罩挡住原列表，再启动安装链
        [[NSNotificationCenter defaultCenter] addObserverForName:UIWindowDidBecomeKeyNotification
                                                          object:nil queue:NSOperationQueue.mainQueue
                                                      usingBlock:^(NSNotification *note) {
                                                          if (!LGIsHostUI()) return;
                                                          UIWindow *w = [note.object isKindOfClass:UIWindow.class] ? note.object : nil;
                                                          LGInstallCover(w);
                                                          LGScheduleInstall();
                                                      }];
    }
}
