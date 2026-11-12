# AutoClicker 1.3.0 — Dopamine / iOS 16.1 安装说明

你的环境：iPhone 14 Pro Max（A16 / arm64e）+ iOS 16.1 + Dopamine（rootless，路径 `/var/jb`）。

**只装这一个包：`AutoClicker-1.3.0-rootless.deb`**

`rootful` 那个是给 unc0ver / checkra1n 用的，装到 Dopamine 上必然"装了没反应"——它的 dylib 落在 `/Library/MobileSubstrate/`，而 Dopamine 的 ElleKit 只扫 `/var/jb/Library/MobileSubstrate/`。

---

## 一、装之前先做两件事

1. **卸掉旧版**
   Sileo → 已安装 → 搜 `AutoClicker` → 卸载（包名 `com.acme.autoclicker`）。
   1.2.0 和 1.3.0 是同一个包名，直接覆盖容易残留，先卸干净。

2. **确认 Dopamine 的注入开关是开的**
   Dopamine App → 底部 **Settings** → 找到 **Tweak Injection**，必须是开启状态。
   这个开关关着的时候，任何 deb 都不会注入，表现就是"包装上了、什么都没发生"。

---

## 二、安装

用 **Sileo**（或 Zebra）打开 deb 安装。不要用 Filza 直接点 deb —— Filza 自带的解包器在部分越狱上不走 dpkg，文件会落错位置。

装完回到 **Dopamine，点 Respring**（或 Userspace Reboot）。等 SpringBoard 起来。

---

## 三、怎么判断这次成没成

1.3.0 在加载后 **1.2 秒会震动一次**，这是"dylib 已经被注入"的物理证据。不用看日志、不用找界面，凭手感就知道。

| 现象 | 含义 | 下一步 |
|---|---|---|
| **震了 + 右上角出现带 `1.3` 角标的圆球** | 全部正常 | 直接用 |
| **震了，但没有球** | 注入成功，卡在显示层 | 看下面第四节，把日志发我 |
| **完全没震** | 根本没注入 | 看下面第五节 |

圆球默认在屏幕左侧偏上（x=48, y=180 附近），黑底、白手形图标、右上角红色 `1.3`。

---

## 四、震了但没球

说明 dylib 加载成功、`%ctor` 跑到了，问题在窗口。

先确认设备有没有进**安全模式**：SpringBoard 顶部如果出现 "Safe Mode" 字样，所有 tweak 都不工作，重启越狱即可。

然后取日志（Filza 打开）：

```
/var/mobile/Library/Logs/AutoClicker.log
```

1.3.0 会往里面写这几行，一眼能看出卡在哪：

```
=========== AutoClicker 1.3.0 loaded ===========    ← 加载了
pid=xxx host=SpringBoard bundle=com.apple.springboard
window built: level=10000200 frame=... hidden=0 scene=yes|nil attempt=N
!! 没有 windowScene，已改挂宿主窗口 xxx            ← 走了兜底
setup done, channel=xxx fallback=0|1
```

- `scene=nil` → 1.3.0 会自动改挂到 SpringBoard 主屏窗口上，球会出现在主屏（进 App 后看不到，但至少证明能用）。
- `setup done` 之后什么都没有 → 把日志发我。

面板打开后，**最底下有一行小字**：`SB 1234 · 自建窗 · HID 派发`。装上没反应时截这一张图就能定位。

---

## 五、完全没震（最常见）

按顺序排查，每一步都是"确实会拦住注入"的：

1. **Dopamine 的 Tweak Injection 没开** —— 见第一节第 2 条。
2. **装完没 respring** —— 只在 Sileo 里装完就去看桌面，dylib 不会被加载。
3. **装成了 rootful 包** —— 见开头。卸掉重装 rootless。
4. **ElleKit 缺失** —— Dopamine 自带，但如果手动卸过：
   Sileo 搜 `ElleKit` 确认已安装。
5. **设备处于安全模式** —— 重启越狱。

确认装对了包：

```
Sileo → 已安装 → AutoClicker → 版本应为 1.3.0
```

如果显示 1.2.0，说明新包没装上。

---

## 六、球出来了但点不动

面板里那行状态会直接写原因：

- `注入通道不可用 · 点击无效` → 点「通道」按钮，切成另一条再试。
- `运行中 · 已点击 N 次 · HID 派发` 但目标没反应 → 通道选错，切到「事件队列」。

1.3.0 在 SpringBoard 下的通道优先级：`HID 派发`（有 entitlement）→ `事件队列`（`-[UIApplication _enqueueHIDEvent:]`，一定可用）。

---

## 附：文件位置

装好后设备上：

```
/var/jb/Library/MobileSubstrate/DynamicLibraries/AutoClicker.dylib
/var/jb/Library/MobileSubstrate/DynamicLibraries/AutoClicker.plist
/var/mobile/Library/Logs/AutoClicker.log
```

这四项都存在，说明包本身没问题。
