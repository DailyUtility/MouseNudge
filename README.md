# Shiftbell

A small macOS menu bar app that runs scheduled tasks around your work time: pop-ups, opening and quitting apps, shortcuts, links and shell commands. One of the tasks, off on a fresh install, nudges the mouse pointer by one pixel (and back) every few minutes during your work hours, so the Mac and chat apps don't mark you as away.

[中文说明](#中文说明)

## Features

- Work hours on working days (Monday–Friday), default 09:00–18:00, set from the menu.
- Night shifts: a stretch like 22:00–06:00 belongs to the day it starts on.
- Public holidays from any iCalendar subscription (`.ics` or `webcal://`, e.g. a holiday calendar from Apple Calendar or officeholidays.com). None is set by default, so only weekends are days off until you add one under **More → Subscribe to Holiday Calendar**.
- Overtime (one day, several days in a row, or repeating), periods (daily, weekly, monthly, one-off), and leave (whole days or part of a day). Monthly goes by weekday (1st to 5th or last) or by date (a day of the month, the last day, or N days from the end), for overtime, periods and tasks alike.
- A period is a stretch of time, optionally named: lunch, a meeting, focus time. It gives the time a name and a countdown, and tasks can run at its start or end. Periods apply on working days and days with overtime; a one-off period applies on its own date. A period never adds work time; overtime does that.
- Scheduled tasks: each is an action and when it runs. Actions: a pop-up, opening and quitting an app, running a shortcut, opening a link, running a shell command (in your login shell), or the mouse nudge. When: at a set time (daily, weekly, monthly or one-off; repeating ones on working days only, unless ticked to run on days off too: weekends, holidays and leave), at the start or end of work hours, overtime or any of your periods (optionally a few minutes early), or every few minutes while inside them. A task every few minutes can be quiet during chosen periods (Quiet during), such as no water reminders in meetings. Work hours and overtime are separate choices; with both ticked, work running into overtime tells you overtime is starting, and the end-of-work pop-up comes when the overtime ends. A fresh install has pop-ups at the start and end of work. The form only shows the fields the chosen action and timing need.
- The mouse nudge is one task that can be turned off: every N minutes (default 10) during work and overtime, set in that task, with the periods it pauses in ticked under Quiet during. Saving a new period while the nudge is on asks whether to pause the nudge in it. Accessibility access is only asked for while it is on.
- Each leave, overtime, period and task can be edited, or turned off without deleting it.
- Each task has a Test button that runs it once right away (shows its pop-up, moves the cursor, opens its app, and so on), to check it is set up right.
- Leave comes first: during leave (whole-day or part-day) there is no nudging, overtime does not count, and reminders, timed tasks and apps wait, except timed tasks set to run on days off and one-off ones. Repeating overtime runs on weekends but skips holidays. A period only pauses the nudge, or another task every few minutes, if that task has it ticked under Quiet during; timed tasks run as usual. Periods (one-off ones too) do not count on leave days. Pause in the menu holds the nudge and every task; to stop only the nudge, turn off its task. On resume, and on waking from sleep or starting again, one pop-up lists today's timed pop-ups that came due meanwhile. Missed starts and ends, pop-ups every few minutes and earlier days are left out; missed shortcuts, links and commands are not run later, only noted in the log.
- No clock in the menu bar: the 🖱 icon fills from the top down as the next nudge comes closer, the rest faded (faded all over off hours and while paused); with the nudge off it fills as the work stretch goes by. A countdown appears only in the 10 minutes before a named period, a period the nudge pauses in, or a timed pop-up. The countdown to the next nudge is in the menu, under the last one.
- An app task keeps the app open during any of the times it follows (work hours, overtime, your periods); it opens a set number of minutes before that time starts and quits a set number of minutes after it ends (both default 0), or is only opened and never quit. Deleting a period removes it from the tasks that follow it, and deletes the tasks that followed only that period.
- Skips a nudge when you used the keyboard or mouse in the last minute, and when the screen is locked (can be turned on).
- Run log, cleared every quarter by default or by hand.
- Interface in English, 简体中文, 繁體中文, 日本語, 한국어, Bahasa Melayu, Español, Français and Deutsch. You can add your own language file from the Language menu.
- Optional start at login; while it is on, Shiftbell also reopens itself within about 10 seconds if it crashes (Quit does not).

Requires macOS 13 or later. Runs on Apple silicon and Intel.

Please use it in line with your workplace's policies.

## Install

### From the disk image

1. Download `Shiftbell-<version>.dmg` from [Releases](https://github.com/DailyUtility/MouseNudge/releases) and drag Shiftbell to Applications.
2. The app is not notarized by Apple, so the first launch shows an "unidentified developer" or "can't be checked" warning. Either:
   - right-click Shiftbell in Applications and choose **Open**, then **Open** again, or
   - open it once, then go to **System Settings → Privacy & Security** and click **Open Anyway**.
3. To use the mouse nudge, turn its task on under **Scheduled Tasks**, then grant Accessibility permission when asked (**System Settings → Privacy & Security → Accessibility**, turn on Shiftbell). Moving the pointer needs it. The menu shows a warning until it is granted.
4. To start it at login, tick **More → Open at login, reopen after crash** in the menu.

### From source

Needs the Xcode Command Line Tools (`xcode-select --install`).

```sh
git clone https://github.com/DailyUtility/MouseNudge.git
cd MouseNudge
./build.sh --install      # builds build/Shiftbell.app, copies it to /Applications and starts it
```

| Command | What it does |
| --- | --- |
| `./build.sh` | Builds `build/Shiftbell.app` for this Mac |
| `./build.sh --install` | Also replaces `/Applications/Shiftbell.app` and restarts it |
| `./make-dmg.sh` | Builds `build/Shiftbell-<version>.dmg` (Apple silicon + Intel), named after the version in `Resources/Info.plist` |
| `./tests/run.sh` | Runs the schedule tests |

The app icon is drawn at build time from the Mac's own Mouse settings icon, so no Apple artwork is stored in this repository.

**Signing.** macOS ties the Accessibility grant to the app's signature. The build is signed ad hoc by default, which means you have to grant Accessibility again after every rebuild. To avoid that, create a self-signed code signing certificate named `Shiftbell Local Signing` (or the older `MouseNudge Local Signing`) in Keychain Access (**Certificate Assistant → Create a Certificate**, type **Code Signing**). `build.sh` uses it when it exists. Set `SIGN_IDENTITY` to use another identity.

### Releases

Pushing a tag that matches the version in `Resources/Info.plist` (for example `v1.0.1`) makes GitHub Actions run the tests, build the disk image and publish it as a release (`.github/workflows/release.yml`). To give every release the same signature, so people keep their Accessibility grant when they update, export the signing certificate with its private key as a `.p12` file and add it as the repository secrets `SIGNING_CERT_P12` (the file, base64 encoded) and `SIGNING_CERT_P12_PASSWORD`. Without them releases are signed ad hoc.

## Privacy

Shiftbell makes no network requests except fetching the holiday calendar you set. It sends nothing anywhere.

Its data stays on your Mac, in `~/Library/Application Support/shiftbell/`:

| File | Contents |
| --- | --- |
| `holidays.json` | Cached holidays |
| `leave.json`, `overtime.json`, `periods.json` | Your leave, overtime and periods |
| `tasks.json` | Your scheduled tasks, the mouse nudge included |
| `nudge.log` | Run log |
| `languages/` | Your own language files |

Settings are in the app's preferences (`defaults read io.github.mar-er.shiftbell`).

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

Shiftbell 是一个 macOS 菜单栏小工具，围绕上班时间运行定时任务：弹窗提醒、自动开关 App、运行快捷指令、打开链接和运行命令。其中一个任务是挪鼠标（新装时关闭）：在上班时间里每隔几分钟把鼠标移动 1 像素再移回来，这样电脑和聊天软件就不会把你显示为"离开"。

### 功能

- 上班时间只算工作日（周一到周五），默认 09:00–18:00，可以在菜单里改。
- 支持夜班：像 22:00–06:00 这样跨午夜的时段，算在开始的那一天。
- 节假日来自任意日历订阅（`.ics` 或 `webcal://`，例如 Apple 日历里的节假日日历，或 officeholidays.com）。默认不设置，这时只排除周末；在"更多 → 订阅假期日历"里设置。
- 支持加班（单天、连续多天、或重复）、时段（每天、每周、每月、单次）和请假（整天或几个小时）。每月可以按星期（第一到第五个或最后一个星期几），也可以按日期（几号、最后一天或倒数第几天），加班、时段和定时任务都一样。
- 时段就是一段时间，可以起个名字，比如午饭、会议、专注。它用来给这段时间命名、显示倒计时，定时任务也可以跟着它的开始或结束运行。时段在工作日和有加班的日子生效，单次时段在它自己的日期生效。时段不会延长上班时间，要多上班就加加班。
- 定时任务：每个任务都是"动作 + 时机"。动作有弹窗提醒、自动开关 App、运行快捷指令、打开链接、运行命令（在你的登录 shell 里运行）和挪鼠标。时机有定时（每天、每周、每月或单次，重复的只在工作日，也可以勾选「休息日也运行」，周末、节假日和请假的日子也会运行）、上班、加班或各时段的开始或结束（可以提前几分钟），或者期间每隔几分钟。每隔几分钟的任务可以勾选「暂停时段」，比如开会时不提醒喝水。上班和加班是分开的选项；两个都勾时，上班接着加班会在上班结束时提示加班开始，加班结束时才提示下班。新装时默认有上班、下班两个弹窗提醒。表单只显示所选动作和时机用得到的项。
- 挪鼠标是一个可以停用的任务：在上班和加班期间每隔 N 分钟（默认 10）挪一次，间隔和要暂停的时段（「暂停时段」）都在这个任务里改。挪鼠标开着时新建时段，会问要不要在这个时段暂停挪鼠标。只有它开着时才会请求辅助功能权限。
- 请假、加班、时段和定时任务都可以修改，也可以单独停用，不用删除。
- 每个定时任务都有「测试」按钮，点一下马上执行一次（弹出提醒、挪一下鼠标、打开 App 等），用来确认设置对不对。
- 请假优先：请假期间（整天或半天）不挪鼠标，加班也不算，提醒、定时任务和自动开关的 App 都暂停；勾了「休息日也运行」的和单次定时任务除外。重复的加班周末照常，遇到节假日跳过。时段本身不暂停任何东西：挪鼠标或其他每隔几分钟的任务只在勾选了「暂停时段」的时段里暂停，定时任务照常运行。请假当天时段（包括单次的）都不算。菜单里的「暂停」会暂停挪鼠标和所有任务；只想停挪鼠标，就在定时任务里停用挪鼠标那条。恢复时，以及电脑睡眠醒来或重新打开时，会用一个弹窗列出这期间错过的当天定时弹窗；上下班、开始结束、每隔几分钟的提醒和前几天的都不补。错过的快捷指令、链接和命令不补运行，只记在日志里。
- 菜单栏不显示时间：🖱 图标随着下次挪动临近从上往下慢慢填满，没填到的部分是半透明的（下班和暂停时整个半透明）；挪鼠标停用时，图标按这一段上班时间过了多少来填满。只有有名称的时段、挪鼠标会暂停的时段或定时弹窗前 10 分钟才出现倒计时。下次挪动的倒计时在菜单里"上次"的下面。
- 自动开关 App 的任务：可以多选跟随上班、加班和各个时段，任一时间内 App 都会开着；开始前提前几分钟打开，结束后延后几分钟关闭（默认都是 0），也可以只开不关。删除时段时，任务不再跟随它；只跟随这个时段的任务会一起删除。
- 最近一分钟内用过键盘或鼠标时不挪动。锁屏时默认也不挪，可以在菜单里打开。
- 有运行记录，默认每季度自动清除一次，也可以手动清除。
- 界面支持 9 种语言，还可以在"语言"菜单里添加自己的语言文件。
- 可以设置登录时自动启动；打开后，Shiftbell 崩溃也会在约 10 秒内自动重开（在菜单里点退出不会）。

需要 macOS 13 或更高版本，支持 Apple 芯片和 Intel 芯片。

请在公司规定允许的范围内使用。

### 安装

1. 从 [Releases](https://github.com/DailyUtility/MouseNudge/releases) 下载 `Shiftbell-<版本号>.dmg`，把 Shiftbell 拖进"应用程序"。
2. 这个 App 没有经过 Apple 公证，第一次打开时会提示"无法验证开发者"。可以用下面任一种方法打开：
   - 在"应用程序"里右键点 Shiftbell，选"打开"，再点一次"打开"。
   - 先双击打开一次，然后到"系统设置 → 隐私与安全性"，点"仍要打开"。
3. 如果要用挪鼠标：在"定时任务"里启用它，再按提示打开辅助功能权限（"系统设置 → 隐私与安全性 → 辅助功能"里打开 Shiftbell）。没有这个权限就不能移动鼠标，菜单里会一直显示提醒。
4. 如果想开机自动运行，在菜单里勾选"更多 → 登录时启动，崩溃后重开"。

从源码构建：先安装 Xcode 命令行工具（`xcode-select --install`），然后运行 `./build.sh --install`。

默认构建使用临时签名（ad hoc），所以每次重新构建后都要重新授权辅助功能。如果不想每次重新授权，可以在"钥匙串访问"里创建一个名为 `Shiftbell Local Signing`（旧名 `MouseNudge Local Signing` 也可以）的自签名代码签名证书，`build.sh` 找到它就会自动使用。

发布：推送和 `Resources/Info.plist` 版本号一致的 tag（例如 `v1.0.1`），GitHub Actions 会自动跑测试、打包 DMG 并发布到 Releases。要让每个版本签名都一样（用户更新后不用重新授权辅助功能），把签名证书连同私钥导出成 `.p12`，在仓库 Secrets 里添加 `SIGNING_CERT_P12`（文件的 base64）和 `SIGNING_CERT_P12_PASSWORD`。没有这两个 Secret 时使用临时签名。

### 隐私

除了下载你设置的节假日日历，Shiftbell 不联网，也不上传任何数据。数据都保存在本机的 `~/Library/Application Support/shiftbell/` 文件夹里。

### 许可证

[GPL-3.0-or-later](LICENSE)。你可以使用、修改和分享这个项目。如果你分发它或修改后的版本，必须以同样的许可证公开源码。
