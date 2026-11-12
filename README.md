# AutoClicker — 越狱自动连点器

iOS 越狱插件。屏幕上常驻一个可拖动的悬浮球，点开就是面板：设间隔、设次数、选单点或拖框选区域，开始后注入真实触摸事件。

支持两种注入模式：

| 模式 | 效果 | 编译参数 |
|---|---|---|
| **全局版**（默认） | 注入 SpringBoard，浮窗盖在所有 App 之上，切 App 连点不断 | `make package` |
| **App 版** | 只注入你指定的 App，浮窗只在这个 App 里出现 | `make package BUNDLE_ID=com.tencent.xin` |

不需要 SimulateTouch、不依赖任何第三方库。

---

## 注入到指定 App

`BUNDLE_ID` 就是目标 App 的 bundle identifier。改它一个参数就能换目标，代码不用动。

```bash
# 只注入微信
make clean && make package BUNDLE_ID=com.tencent.xin

# 同时注入多个 App（英文逗号分隔）
make clean && make package BUNDLE_ID=com.tencent.xin,com.tencent.mqq

# 回到全局版
make clean && make package BUNDLE_ID=com.apple.springboard
```

Makefile 会用这个值生成 `AutoClicker.plist`（就是 Theos 的 Filter 文件），所以你不用手写 plist。

### 怎么查 bundle id

任选一种：

- **已越狱设备**：`frida-ps -Ua` 列出所有 App 的 bundle id
- **Filza**：进 `/var/containers/Bundle/Application/`，每个 App 目录里翻 `Info.plist` 的 `CFBundleIdentifier`
- **电脑上**：把 IPA 后缀改 zip 解压，看 `Payload/*.app/Info.plist`
- **不想装任何东西**：App Store 网页版链接里 `/id` 后面那串数字不是 bundle id，得用上面几种

### 两种宿主的真实差异

这不是"换个 bundle id"就完事的事，注入通道必须跟着换：

| | SpringBoard 版 | App 版 |
|---|---|---|
| HID entitlement | 有 | **没有** |
| 注入方式 | `IOHIDEventSystemClientDispatchEvent` | `-[UIApplication _enqueueHIDEvent:]` |
| 事件作用范围 | 全系统，能点任何 App | 只在被注入的那个 App 进程内 |
| 窗口层级 | 10000200 | `UIWindowLevelAlert + 1000` |
| 目标 App 更新后 | 继续生效 | 继续生效（按 bundle id 匹配，与版本无关） |

**关键点**：普通 App 进程没有 `com.apple.private.hid.client.event-dispatch`，直接调 `IOHIDEventSystemClientDispatchEvent` 会静默失败 —— 不报错，就是一个点击都不产生。所以 App 版必须走 `_enqueueHIDEvent:`，把事件直接塞进本进程的 UIKit 事件流。代码里 `ACRefreshInjectChannel()` 会运行时探测，面板状态栏会显示当前用的是哪个通道：

- `HID 派发` → SpringBoard 版
- `事件队列` → App 版
- `不可用` → 红色警告，点了不会有任何反应

---

## 功能

- **悬浮球**：56pt 圆形，可拖到任意位置，位置自动记忆，跨重启保留
- **点击间隔**：0.02 秒 ~ 5 秒，对数刻度滑块，低区间调得细
- **点击次数**：1 次 ~ 500 次，或无限
- **单点模式**：点一下屏幕任意位置作为连点目标
- **区域模式**：手指拖出矩形，每次点击在区域内**随机落点**（更接近真人操作）
- **穿透**：悬浮球之外的区域完全不拦截触摸；连点注入前浮窗会自动让开一瞬，不会点到自己

---

## 编译

### 方式 A：GitHub Actions（已配好，push 就出包）

仓库：<https://github.com/lihan663366/autoclicker>

往 `main` 推提交就自动构建，产物在 Actions 页面 → 对应 run → Artifacts。

**指定目标 App**：Actions 页面 → 这个 workflow → `Run workflow` → 在 `bundle_id` 输入框里填 bundle id（默认 `com.apple.springboard`）。

跑在 `ubuntu-latest` 上 —— macOS runner 在这个账号不可用（实测 job 会在 1 秒内被取消、一个 step 都不执行），所以走 Linux 路线：`L1ghtmann/llvm-project` 的预编译 iOS 工具链 + `theos/sdks`。

### 方式 B：本地 Theos（macOS 或 Linux/WSL）

```bash
export THEOS=$HOME/theos
bash <(curl -fsSL https://raw.githubusercontent.com/theos/headers/master/install-theos)

cd autoclicker
make clean
make package FINALPACKAGE=1 BUNDLE_ID=com.your.app
# 产物：packages/com.acme.autoclicker_1.0.0_iphoneos-arm64.deb
```

需要 iOS SDK 在 `$THEOS/sdks/`：

```bash
git clone --depth 1 https://github.com/theos/sdks /tmp/sdks
cp -R /tmp/sdks/*.sdk $THEOS/sdks/
```

### rootless vs rootful

`Makefile` 默认 `THEOS_PACKAGE_SCHEME = rootless`，对应 Dopamine、palera1n rootless、XinaA15。

unc0ver / checkra1n / palera1n **rootful** 加参数编译：

```bash
make package ROOTFUL=1
```

**这一项装错是最常见的"包能装、但完全没反应"**：rootless 包的 dylib 落在 `/var/jb/Library/MobileSubstrate/DynamicLibraries/`，老越狱只读根目录，Substrate 永远加载不到它。CI 两个版都出，装一个不行就换另一个，30 秒就能排除。

---

## 已验证的构建结果

CI 实跑产出的 deb 拆开确认过：

- `control` → `Architecture: iphoneos-arm64`（rootless）/ `iphoneos-arm`（rootful）
- 安装路径 `var/jb/Library/MobileSubstrate/DynamicLibraries/`（rootless）
- `AutoClicker.dylib` **FAT 双架构**：arm64 (cpusub 0) + arm64e (cpusub 2)
- `AutoClicker.plist` 随包一起装进同一目录

---

## 安装

三条路，按你的环境选。

**① 越狱设备（推荐）** — 装 deb

```bash
# 传到手机后
dpkg -i AutoClicker-1.2.0-rootless.deb     # rootful 就用 rootful 那个

# 全局版：重启桌面进程
killall -9 SpringBoard

# App 版：重启目标 App（不用动 SpringBoard）
killall -9 WeChat
```

rootless 越狱的实际安装路径是 `/var/jb/Library/MobileSubstrate/DynamicLibraries/AutoClicker.dylib`。

**② 没有越狱，但有 TrollStore** — 用 TrollFools 注入 `AutoClicker.dylib`

TrollFools 里选目标 App → 导入 `AutoClicker.dylib` → 注入 → 重开 App。这条路不需要越狱，也不需要改 IPA。注入后走的就是 App 通道（`_enqueueHIDEvent:`），浮球只出现在那个 App 里。

**③ 手动注入 IPA** — 把 dylib 塞进 App 的 `Frameworks/` 并在主二进制加 `LC_LOAD_DYLIB`，重签后用 TrollStore 装。

**球出现 = 插件加载成功**，这是最快的自检方式。App 版要先进到那个 App 里才看得到球。

> 这个 tweak **没有**「设置 → AutoClicker」那样的系统设置面板。所有参数都在浮球点开的面板里。设置里找不到是正常的，不代表没装好。

---

## 用法

1. 拖动圆球到不挡视线的地方
2. 点球 → 弹出面板，顶部会显示当前注入通道
3. 先设 **点击位置**：
   - 「选 点」→ 屏幕变暗，点你要点的那个按钮，立即生效
   - 「框选区域」→ 屏幕变暗，手指拖出一个矩形，松手生效
4. 调 **间隔** 和 **次数**（次数拉到最左是无限）
5. 点绿色「开 始」→ 面板自动收起，按钮变红「停 止」，再点球可看实时次数
6. 要停就再点一次

参数全部自动保存，下次打开还是上次的状态。浮球右上角的红字是版本号，装错包一眼能认出来。

### 面板底部两个按钮

**「通道：xxx」** — 点一下在 `HID 派发` → `事件队列` → `不可用` 之间轮换。

两条注入通道在不同 iOS 版本上有效性不一样，自动探测有可能选错。表现就是「面板显示正常运行、次数也在涨，但目标毫无反应」。这种情况手动切一次通道，多半立刻就好了。切换会写进日志。

**「查看日志」** — 直接看运行日志，不用连电脑。

日志同时写在 `/var/mobile/Library/Logs/AutoClicker.log`，用 Filza / SSH 也能读。

---

## 出问题怎么查

先看日志。装完打开浮球面板 → 「查看日志」，或者：

```bash
cat /var/mobile/Library/Logs/AutoClicker.log
```

正常加载的日志长这样：

```
[20:31:02.114] SpringBoard/1024  =========== AutoClicker 1.2.0 loaded ===========
[20:31:02.115] SpringBoard/1024  host=SpringBoard isSpringBoard=1 bundle=com.apple.springboard pid=1024
[20:31:02.116] SpringBoard/1024  symbols: dispatch=1 createEvent=1 createFinger=1 append=1 typedCreate=1
[20:31:02.117] SpringBoard/1024  client created with type=1
[20:31:02.118] SpringBoard/1024  channel = HID 派发 (canDispatch=1 clientType=1 canEnqueue=1)
[20:31:05.203] SpringBoard/1024  window built: level=10000200 ...
[20:31:05.260] SpringBoard/1024  setup done, channel=HID 派发
```

**日志文件都不存在** = dylib 没被加载，跟功能无关，是安装层问题。

| 现象 | 原因 | 处理 |
|---|---|---|
| 设置里找不到 AutoClicker | 这个 tweak 没有系统设置面板 | 正常现象，参数全在浮球面板里 |
| 没有圆球，日志也没有 | dylib 没加载 | 换 rootful / rootless 另一版；`killall -9 SpringBoard`；确认越狱已启用 tweak 注入 |
| 没有圆球，日志有 `loaded` 但卡在后面 | 建窗失败 | 看日志里 `window built` 那行，把日志发我 |
| 面板显示「不可用」 | 两条通道都探不到 | 点「通道」手动切；仍不行说明该系统版本移除了两个私有接口 |
| 面板正常、次数在涨，但目标没反应 | 通道选错 | 点「通道」切到另一个再试 —— 这是 90% 的原因 |
| 点击位置**偏移**到左上角 | 坐标多乘了一次 scale | `ACCore.m` 里 `const CGFloat k = ACScale();` 改成 `k = 1.0` 重新编译 |
| 只有一半屏幕能点 | 反过来，需要乘 scale | 保持 `ACScale()`；或试 `k = ACScale() * 2` |
| 点得太快目标没响应 | 部分控件需要 >20ms 按压 | 间隔调到 0.05 以上 |
| 目标 App 一启动就闪退 | App 有反注入/完整性校验 | 换 App，或改用全局版 |
| 横屏下位置错乱 | 未做旋转换算 | 当前只适配竖屏 |

### 坐标系说明

`IOHIDEventCreateDigitizerEvent` 和 `_enqueueHIDEvent:` 都用**物理像素**坐标，所以代码里做了 `point * scale`。

这套 API 在不同 iOS 版本上行为变过（有的版本直接吃 point）。落点整体缩到左上角 1/3 或 1/2 处，就是多乘了一次，按上表把 `k` 改成 `1.0`。

---

## 代码结构

```
autoclicker/
├── Makefile                  # 按 BUNDLE_ID 生成 Filter plist；ROOTFUL=1 切 rootful
├── control                   # deb 元信息
├── Tweak.xm                  # 入口，按宿主决定延迟，第一件事就是写日志
├── ACCore.h / ACCore.m       # 双通道触摸注入 + 连点引擎（dispatch_source 定时器）
├── ACDebug.h / ACDebug.m     # 落盘日志（越狱环境没调试器，只能靠它）
├── ACUI.h / ACUI.m           # 悬浮球、设置面板、框选遮罩、通道切换、日志查看
└── .github/workflows/build.yml
```

`AutoClicker.plist` 不进版本库，由 Makefile 每次按 `BUNDLE_ID` 生成。

### 两条注入通道

**SpringBoard（系统级派发）**

```objc
IOHIDEventSystemClientRef client = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
IOHIDEventSystemClientScheduleWithRunLoop(client, CFRunLoopGetMain(), kCFRunLoopDefaultMode);

IOHIDEventRef down = IOHIDEventCreateDigitizerEvent(..., kIOHIDDigitizerEventRange|kIOHIDDigitizerEventTouch, ..., true, true, 0);
IOHIDEventSystemClientDispatchEvent(client, down);
// 8ms 后抬起
IOHIDEventSystemClientDispatchEvent(client, up);
```

**注意 iOS 15+ 的坑**：`IOHIDEventSystemClientCreate()` 返回的 default client 已经不能派发了 —— 返回非 NULL，`DispatchEvent` 不报错，事件被静默丢弃。这正是「代码看着没问题、点了完全没反应」的头号原因。

必须用带类型的创建函数，Monitor 类型才能派发：

```objc
// kIOHIDEventSystemClientTypeMonitor = 1
IOHIDEventSystemClientRef client =
    IOHIDEventSystemClientCreateWithType(kCFAllocatorDefault, 1, NULL);
```

代码里先试 Monitor，失败再退 legacy create，并通过 `sClientType` 记录下来 —— 如果最终是 default 类型，SpringBoard 也会改走事件队列通道，而不是硬派发。

**App 内（事件队列）**

```objc
// hand 事件 + finger 子事件，坐标仍是物理像素
IOHIDEventRef hand = IOHIDEventCreateDigitizerEvent(...);
IOHIDEventAppendEvent(hand, finger, 0);

// 私有方法，把事件直接塞进本进程 UIKit 事件流
[(id)[UIApplication sharedApplication] _enqueueHIDEvent:(__bridge id)hand];
```

所有符号走 `dlopen` + `dlsym` 从 `/System/Library/PrivateFrameworks/IOKit.framework/IOKit` 取，编译期不链接私有框架 —— 某个符号在特定系统上缺失时，tweak 不会整个 crash，只是通道探测会返回「不可用」。

### 为什么注入前要让开浮窗

App 版里浮窗和被点的对象在同一个进程、同一条事件路径上。浮窗层级是 `UIWindowLevelAlert + 1000`，如果落点正好压在浮球或面板上，点到的是自己。

所以引擎每次注入前把浮窗的 `userInteractionEnabled` 关掉。**关键细节：恢复必须延迟 120ms**。注入的 down 和 up 之间隔 8ms，如果 tap 返回就立刻恢复，down 会落到 App、up 会落到浮窗，App 收到的是一次没有抬起的按下 —— 什么都不触发。这个 bug 极难从现象上看出来（次数在涨、日志正常），第一版就是这么写的。

---

## 免责

改机有风险，别用在有强反作弊或账号价值高的场景。
