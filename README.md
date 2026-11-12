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

`Makefile` 默认开着 `THEOS_PACKAGE_SCHEME = rootless`，对应 Dopamine、palera1n rootless、XinaA15。

unc0ver / checkra1n / palera1n **rootful** 把那一行注释掉，否则装不上。

---

## 已验证的构建结果

CI 实跑产出的 deb（23 KB）拆开确认过：

- `control` → `Architecture: iphoneos-arm64`、`Depends: mobilesubstrate`
- 安装路径 `var/jb/Library/MobileSubstrate/DynamicLibraries/`
- `AutoClicker.dylib` 203,936 字节，**FAT 双架构**：arm64 (cpusub 0) + arm64e (cpusub 2)
- `AutoClicker.plist` 随包一起装进同一目录

---

## 安装

```bash
# 把 deb 传到手机后
dpkg -i com.acme.autoclicker_1.0.0_iphoneos-arm64.deb
# 或直接 sileo / zebra 里点开安装

# 全局版：重启桌面进程
killall -9 SpringBoard

# App 版：重启目标 App（不用动 SpringBoard）
killall -9 WeChat    # 或直接上滑杀掉再打开
```

rootless 越狱的实际安装路径是 `/var/jb/Library/MobileSubstrate/DynamicLibraries/AutoClicker.dylib`。

**球出现 = 插件加载成功**，这是最快的自检方式。App 版要先进到那个 App 里才看得到球。

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

参数全部自动保存，下次打开还是上次的状态。

---

## 出问题怎么查

| 现象 | 原因 | 处理 |
|---|---|---|
| 没有圆球（全局版） | tweak 没加载 | `dpkg -l \| grep autoclicker`；`killall -9 SpringBoard`；rootless/rootful 用错版会在这一步暴露 |
| 没有圆球（App 版） | 没进目标 App，或 bundle id 写错 | 确认 `AutoClicker.plist` 里的 id 和 App 一致；`killall -9 <App>` 重开 |
| 面板显示「不可用」 | App 内 `_enqueueHIDEvent:` 不存在 | 这个 iOS 版本移除了该私有方法，改用全局版 |
| 面板显示正常但点了没反应 | 通道探测误判，或落点被遮 | 先换「选 点」精确点一次试；仍无效就改用全局版 |
| 点击位置**偏移**到左上角 | 坐标多乘了一次 scale | `ACCore.m` 里 `const CGFloat k = ACScale();` 改成 `k = 1.0` 重新编译 |
| 只有一半屏幕能点 | 反过来，需要乘 scale | 保持 `ACScale()`；或试 `k = ACScale() * 2` |
| 点得太快目标没响应 | 部分控件需要 >20ms 按压 | 间隔调到 0.05 以上 |
| 目标 App 一启动就闪退 | App 有反注入/完整性校验 | 这插件只注入目标 App，换 App 或改用全局版 |
| 横屏下位置错乱 | 未做旋转换算 | 当前只适配竖屏 |

### 坐标系说明

`IOHIDEventCreateDigitizerEvent` 和 `_enqueueHIDEvent:` 都用**物理像素**坐标，所以代码里做了 `point * scale`。

这套 API 在不同 iOS 版本上行为变过（有的版本直接吃 point）。落点整体缩到左上角 1/3 或 1/2 处，就是多乘了一次，按上表把 `k` 改成 `1.0`。

---

## 代码结构

```
autoclicker/
├── Makefile                  # 按 BUNDLE_ID 生成 Filter plist；rootless 开关在首行
├── control                   # deb 元信息
├── Tweak.xm                  # 入口，按宿主决定延迟
├── ACCore.h / ACCore.m       # 双通道触摸注入 + 连点引擎（dispatch_source 定时器）
├── ACUI.h / ACUI.m           # 悬浮球、设置面板、框选遮罩
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

App 版里浮窗和被点的对象在同一个进程、同一条事件路径上。浮窗层级是 `UIWindowLevelAlert + 1000`，如果落点正好压在浮球或面板上，点到的是自己。所以引擎每次注入前把浮窗的 `userInteractionEnabled` 关掉一瞬，注入完立刻恢复（`ACEngine` 的 `willTap` / `didTap` 回调）。另外点「开始」时会自动收起面板。

---

## 免责

改机有风险，别用在有强反作弊或账号价值高的场景。
