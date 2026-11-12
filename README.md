# AutoClicker — 越狱自动连点器

iOS 越狱插件。注入 SpringBoard，屏幕上常驻一个可拖动的悬浮球，点开就是面板：设间隔、设次数、选单点或拖框选区域，开始后按 IOHID 事件注入真实触摸，全局任意 App 上都生效。

不需要 SimulateTouch、不需要签名、不依赖任何第三方库。

---

## 功能 CVVVVVVVV

- **悬浮球**：56pt 圆形，可拖到任意位置，位置自动记忆，跨重启保留
- **点击间隔**：0.02 秒 ~ 5 秒，对数刻度滑块，低区间调得细
- **点击次数**：1 次 ~ 500 次，或无限
- **单点模式**：点一下屏幕任意位置作为连点目标
- **区域模式**：手指拖出矩形，每次点击在区域内**随机落点**（不是固定一点，更接近真人操作）
- **穿透**：悬浮球之外的区域完全不拦截触摸，正常操作 App 不受影响

---

## 编译

### 方式 A：GitHub Actions（最省事，不用装环境）

把 `autoclicker/` 整个目录推到一个 GitHub 仓库，Actions 会自动编译，产物在 Artifacts 里的 `AutoClicker-deb`。

### 方式 B：本地 Theos（macOS 或 Linux/WSL）

```bash
export THEOS=$HOME/theos
bash <(curl -fsSL https://raw.githubusercontent.com/theos/headers/master/install-theos)   # 或用官方文档装

cd autoclicker
make clean
make package FINALPACKAGE=1
# 产物：packages/com.acme.autoclicker_1.0.0_iphoneos-arm64.deb
```

需要 iOS SDK 在 `$THEOS/sdks/`。没装的话：

```bash
git clone --depth 1 https://github.com/theos/sdks /tmp/sdks
cp -R /tmp/sdks/*.sdk $THEOS/sdks/
```

### rootless vs rootful

`Makefile` 第一行默认开着 `THEOS_PACKAGE_SCHEME = rootless`，对应 Dopamine、palera1n rootless、XinaA15。

如果你是 unc0ver / checkra1n / palera1n **rootful**，把那一行注释掉再编译，否则装不上。

---

## 安装

```bash
# 把 deb 传到手机后
dpkg -i com.acme.autoclicker_1.0.0_iphoneos-arm64.deb
# 或直接 sileo / zebra 里点开安装

# 装完重启桌面进程
killall -9 SpringBoard
```

rootless 越狱的实际安装路径是 `/var/jb/Library/MobileSubstrate/DynamicLibraries/AutoClicker.dylib`。

装好后屏幕上会出现一个深色圆球（带一只手指图标）。**球出现 = 插件加载成功**，这是最快的自检方式。

---

## 用法

1. 拖动圆球到不挡视线的地方
2. 点球 → 弹出面板
3. 先设 **点击位置**：
   - 「选 点」→ 屏幕变暗，点你要点的那个按钮，立即生效
   - 「框选区域」→ 屏幕变暗，手指拖出一个矩形，松手生效
4. 调 **间隔** 和 **次数**（次数拉到最左是无限）
5. 点绿色「开 始」→ 按钮变红「停 止」，面板顶部实时显示已点击次数
6. 要停就再点一次

参数全部自动保存，下次打开还是上次的状态。

---

## 出问题怎么查

| 现象                   | 原因                 | 处理                                                                                       |
| -------------------- | ------------------ | ---------------------------------------------------------------------------------------- |
| 没有圆球                 | tweak 没加载          | `dpkg -l \| grep autoclicker` 确认装上；`killall -9 SpringBoard`；rootless/rootful 用错版本会在这一步暴露 |
| 圆球在，点了没反应            | IOHID 注入失败         | 越狱环境应支持；TrollStore 非越狱环境部分系统版本会拦，换越狱设备                                                   |
| 点击位置**偏移**，落在目标左上或右上 | 坐标系缩放不对            | 打开 `ACCore.m`，找到 `const CGFloat k = ACScale();`，改成 `const CGFloat k = 1.0;` 重新编译         |
| 点击位置**超出屏幕**或只有一半    | 反过来，需要乘 scale      | 保持 `ACScale()` 不动；若仍不对，试 `k = ACScale() * 2`                                             |
| 只有第一次点中，后面全偏         | 目标 App 在点击后换了布局    | 正常现象，重新「选点」                                                                              |
| 横屏下位置错乱              | digitizer 坐标不做旋转换算 | 当前只适配竖屏。横屏场景需要按 orientation 做坐标变换，改 `ACInjectTap` 即可                                     |
| 点得太快目标没响应            | 部分控件需要 >20ms 的按压   | 把间隔调到 0.05 以上                                                                            |

### 坐标系说明

`IOHIDEventCreateDigitizerEvent` 用的是**物理像素**坐标，所以代码里做了 `point * scale`。

但这套 API 在不同 iOS 版本上的行为历史上有过变化（有的版本直接吃 point）。如果你发现点击落点整体缩到了左上角 1/3 或 1/2 处，就是多乘了一次，按上表把 `k` 改成 `1.0` 即可。这个只要调一次，之后就固定了。

---

## 代码结构

```
autoclicker/
├── Makefile                  # Theos 构建（rootless 开关在首行）
├── control                   # deb 元信息
├── AutoClicker.plist         # 注入过滤，默认 SpringBoard
├── Tweak.xm                  # 入口，延迟 3 秒加载 UI
├── ACCore.h / ACCore.m       # IOHID 注入 + 连点引擎（dispatch_source 定时器）
├── ACUI.h / ACUI.m           # 悬浮球、设置面板、框选遮罩
└── .github/workflows/build.yml
```

### 为什么注入 SpringBoard 而不是 App

注入 App 进程也能画浮窗，但每个 App 都要单独配置、且触摸注入要各自的权限。注入 SpringBoard 后：

- 一层浮窗覆盖所有 App
- 触摸注入只用一份 IOHID client
- 切 App 时连点不中断

想限制只在某个 App 里生效，改 `AutoClicker.plist` 的 `Bundles` 就行，代码不用动。

### 触摸注入怎么做的

```objc
IOHIDEventSystemClientRef client = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
IOHIDEventSystemClientScheduleWithRunLoop(client, CFRunLoopGetMain(), kCFRunLoopDefaultMode);

// 按下
IOHIDEventRef down = IOHIDEventCreateDigitizerEvent(..., kIOHIDDigitizerEventRange|kIOHIDDigitizerEventTouch, ..., true, true, 0);
IOHIDEventSystemClientDispatchEvent(client, down);

// 8ms 后抬起
IOHIDEventRef up = IOHIDEventCreateDigitizerEvent(..., 0, ..., false, false, 0);
IOHIDEventSystemClientDispatchEvent(client, up);
```

符号全部走 `dlopen` + `dlsym` 从 `/System/Library/PrivateFrameworks/IOKit.framework/IOKit` 取，编译期不链接私有框架 —— 这样即使某个符号在特定系统上缺失，tweak 也不会整个 crash，只是点击不生效。

---

## 免责

改机有风险，别用在有强反作弊或账号价值高的场景。
