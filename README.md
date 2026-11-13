# MouseNudge

A small macOS menu bar app that nudges the mouse pointer by one pixel (and back) every few minutes during your work hours, so the Mac and chat apps don't mark you as away.

[中文说明](#中文说明)

## Features

- Nudges only in your work hours on working days (Monday–Friday), every N minutes (default 10, 09:00–18:00). Both are set from the menu.
- Night shifts: a stretch like 22:00–06:00 belongs to the day it starts on.
- Public holidays from any iCalendar subscription (`.ics` or `webcal://`, e.g. a holiday calendar from Apple Calendar or officeholidays.com). None is set by default, so only weekends are days off until you add one under **More → Subscribe to Holiday Calendar**.
- Overtime (one day, several days in a row, or repeating), breaks (daily, weekly, Nth or last weekday of the month, one-off), and leave (whole days or part of a day).
- Skips a nudge when you used the keyboard or mouse in the last minute, and when the screen is locked (can be turned on).
- Run log, cleared every quarter by default or by hand.
- Interface in English, 简体中文, 繁體中文, 日本語, 한국어, Bahasa Melayu, Español, Français and Deutsch. You can add your own language file from the Language menu.
- Optional start at login.

Requires macOS 13 or later. Runs on Apple silicon and Intel.

Please use it in line with your workplace's policies.

## Install

### From the disk image

1. Download `MouseNudge-<version>.dmg` from [Releases](https://github.com/Mar-er/MouseNudge/releases) and drag MouseNudge to Applications.
2. The app is not notarized by Apple, so the first launch shows an "unidentified developer" or "can't be checked" warning. Either:
   - right-click MouseNudge in Applications and choose **Open**, then **Open** again, or
   - open it once, then go to **System Settings → Privacy & Security** and click **Open Anyway**.
3. Grant Accessibility permission when asked (**System Settings → Privacy & Security → Accessibility**, turn on MouseNudge). Moving the pointer needs it. The menu shows a warning until it is granted.
4. To start it at login, tick **More → Open at login** in the menu.

### From source

Needs the Xcode Command Line Tools (`xcode-select --install`).

```sh
git clone https://github.com/Mar-er/MouseNudge.git
cd MouseNudge
./build.sh --install      # builds build/MouseNudge.app, copies it to /Applications and starts it
```

| Command | What it does |
| --- | --- |
| `./build.sh` | Builds `build/MouseNudge.app` for this Mac |
| `./build.sh --install` | Also replaces `/Applications/MouseNudge.app` and restarts it |
| `./make-dmg.sh` | Builds `build/MouseNudge-<version>.dmg` (Apple silicon + Intel), named after the version in `Resources/Info.plist` |
| `./tests/run.sh` | Runs the schedule tests |

The app icon is drawn at build time from the Mac's own Mouse settings icon, so no Apple artwork is stored in this repository.

**Signing.** macOS ties the Accessibility grant to the app's signature. The build is signed ad hoc by default, which means you have to grant Accessibility again after every rebuild. To avoid that, create a self-signed code signing certificate named `MouseNudge Local Signing` in Keychain Access (**Certificate Assistant → Create a Certificate**, type **Code Signing**). `build.sh` uses it when it exists. Set `SIGN_IDENTITY` to use another identity.

### Releases

Pushing a tag that matches the version in `Resources/Info.plist` (for example `v1.0.1`) makes GitHub Actions run the tests, build the disk image and publish it as a release (`.github/workflows/release.yml`). To give every release the same signature, so people keep their Accessibility grant when they update, export the signing certificate with its private key as a `.p12` file and add it as the repository secrets `SIGNING_CERT_P12` (the file, base64 encoded) and `SIGNING_CERT_P12_PASSWORD`. Without them releases are signed ad hoc.

## Privacy

MouseNudge makes no network requests except fetching the holiday calendar you set. It sends nothing anywhere.

Its data stays on your Mac, in `~/Library/Application Support/mouse-nudge/`:

| File | Contents |
| --- | --- |
| `holidays.json` | Cached holidays |
| `leave.json`, `overtime.json`, `breaks.json` | Your leave, overtime and breaks |
| `nudge.log` | Run log |
| `languages/` | Your own language files |

Settings are in the app's preferences (`defaults read io.github.mar-er.mousenudge`).

## Translations

`Sources/Strings.swift` is the translation table. The code looks text up by short dotted keys such as `T("menu.subscribeHoliday")`, grouped by where the text appears (`menu.`, `status.`, `log.`, `confirm.`, `common.` and so on). Missing text falls back to English.

To add or change strings, write one row per key with ten columns separated by ` | ` (key | zh-Hans | en | zh-Hant | ja | ko | ms | es | fr | de), for example

```text
menu.more | 更多 | More | 更多 | その他 | 더 보기 | Lagi | Más | Plus | Mehr
```

then run:

```sh
python3 -I tools/strings.py Sources/Strings.swift rows.txt
```

A row whose key already exists replaces it. Running the tool without a rows file just rewrites the table, which checks its format.

## License

[GPL-3.0-or-later](LICENSE). You may use, change and share it. If you distribute it or a modified version, you must share the source under the same license.

---

## 中文说明

MouseNudge 是一个 macOS 菜单栏小工具。在你的上班时间里，它每隔几分钟把鼠标移动 1 像素再移回来，这样电脑和聊天软件就不会把你显示为"离开"。

### 功能

- 只在工作日（周一到周五）的上班时间挪动。间隔默认 10 分钟，时间默认 09:00–18:00，都可以在菜单里改。
- 支持夜班：像 22:00–06:00 这样跨午夜的时段，算在开始的那一天。
- 节假日来自任意日历订阅（`.ics` 或 `webcal://`，例如 Apple 日历里的节假日日历，或 officeholidays.com）。默认不设置，这时只排除周末；在"更多 → 订阅假期日历"里设置。
- 支持加班（单天、连续多天、或重复）、休息（每天、每周、每月第几个或最后一个星期几、单次）和请假（整天或几个小时）。
- 最近一分钟内用过键盘或鼠标时不挪动。锁屏时默认也不挪，可以在菜单里打开。
- 有运行记录，默认每季度自动清除一次，也可以手动清除。
- 界面支持 9 种语言，还可以在"语言"菜单里添加自己的语言文件。
- 可以设置登录时自动启动。

需要 macOS 13 或更高版本，支持 Apple 芯片和 Intel 芯片。

请在公司规定允许的范围内使用。

### 安装

1. 从 [Releases](https://github.com/Mar-er/MouseNudge/releases) 下载 `MouseNudge-<版本号>.dmg`，把 MouseNudge 拖进"应用程序"。
2. 这个 App 没有经过 Apple 公证，第一次打开时会提示"无法验证开发者"。可以用下面任一种方法打开：
   - 在"应用程序"里右键点 MouseNudge，选"打开"，再点一次"打开"。
   - 先双击打开一次，然后到"系统设置 → 隐私与安全性"，点"仍要打开"。
3. 按提示打开辅助功能权限：在"系统设置 → 隐私与安全性 → 辅助功能"里打开 MouseNudge。没有这个权限就不能移动鼠标，菜单里会一直显示提醒。
4. 如果想开机自动运行，在菜单里勾选"更多 → 登录时自动启动"。

从源码构建：先安装 Xcode 命令行工具（`xcode-select --install`），然后运行 `./build.sh --install`。

默认构建使用临时签名（ad hoc），所以每次重新构建后都要重新授权辅助功能。如果不想每次重新授权，可以在"钥匙串访问"里创建一个名为 `MouseNudge Local Signing` 的自签名代码签名证书，`build.sh` 找到它就会自动使用。

发布：推送和 `Resources/Info.plist` 版本号一致的 tag（例如 `v1.0.1`），GitHub Actions 会自动跑测试、打包 DMG 并发布到 Releases。要让每个版本签名都一样（用户更新后不用重新授权辅助功能），把签名证书连同私钥导出成 `.p12`，在仓库 Secrets 里添加 `SIGNING_CERT_P12`（文件的 base64）和 `SIGNING_CERT_P12_PASSWORD`。没有这两个 Secret 时使用临时签名。

### 隐私

除了下载你设置的节假日日历，MouseNudge 不联网，也不上传任何数据。数据都保存在本机的 `~/Library/Application Support/mouse-nudge/` 文件夹里。

### 许可证

[GPL-3.0-or-later](LICENSE)。你可以使用、修改和分享这个项目。如果你分发它或修改后的版本，必须以同样的许可证公开源码。
