# XScreenshot

XScreenshot 是一款 macOS 菜单栏截图工具。按下快捷键即可框选屏幕区域，添加箭头、文字等标注，再把截图复制到剪贴板，直接粘贴到聊天或文档中。

## 安装

打开下载或构建得到的 `XScreenshot.dmg`，把 `XScreenshot.app` 拖入「应用程序」，然后从 Finder 的「应用程序」打开。截图入口在屏幕顶部的菜单栏。安装包支持运行 macOS 14 或更新版本的 Apple 芯片和 Intel Mac。

## 构建和发布

源码在 `Sources/XScreenshot/`，测试在 `Tests/`，应用图标和版本信息在 `App/`。`.build/` 存放本地构建产物，`release/` 存放最新的安装包。

构建需要带 Swift 6 的 Xcode 或 Xcode Command Line Tools。在仓库根目录运行 `./scripts/build-release.sh`，生成 `release/XScreenshot.dmg`。签名、公证及上传方法见 [发布说明](release/README.md)。

### 本地构建和运行

```sh
./scripts/build-app.sh
open .build/XScreenshot.app
```

也可以在 Xcode 中打开 `Package.swift` 编辑源码。通过上面的脚本生成 `.app` 并启动，以便 macOS 用应用的包标识处理屏幕录制权限。

### 使用证书签名

默认构建使用临时签名。修改代码后，macOS 可能要求重新授予屏幕录制权限。本机开发可以使用 **Apple Development** 证书。首次换用证书签名时需要重新授权一次。后续构建沿用同一签名身份和包标识 `com.ethan.xscreenshot`，即可保留授权。

1. 在 Xcode 的「设置 → Accounts」中登录 Apple 账户，选择团队，点击「Manage Certificates…」，用「+」创建 **Apple Development** 证书。
2. 运行 `security find-identity -v -p codesigning`，复制对应证书的完整名称或该行的哈希。
3. 用该身份构建。将示例值替换为上一步复制的值。

   ```sh
   export XSCREENSHOT_SIGN_IDENTITY="Apple Development: Your Name (XXXXXXXXXX)"
   ./scripts/build-app.sh
   codesign --display -r - .build/XScreenshot.app
   ```

退出旧版后，用 `.build/XScreenshot.app` 替换原来安装的应用，再从该位置打开。每次构建时都设置 `XSCREENSHOT_SIGN_IDENTITY`。如果首次换用证书后系统设置仍显示旧授权，可以运行 `tccutil reset ScreenCapture com.ethan.xscreenshot`，再打开应用并授权。

## 截图

1. 按 `Control + Shift + 4`，或在菜单栏的取景框图标中选择「区域截图」。
2. 首次使用时，在「系统设置 → 隐私与安全性 → 屏幕录制」（新版 macOS 为「屏幕与系统录音」）中允许 XScreenshot，然后退出并重新打开应用。
3. 在半透明黑色遮罩上按住鼠标左键拖动。选区上方显示导出的像素尺寸，松开后显示工具栏。
4. 点击画笔、直线、矩形、椭圆、箭头或文本工具可在下方展开色板。切回工具栏最左侧的选择工具，可以调整已有标注和截图选区。
5. 点击确认按钮或按 `Return`，将编辑后的截图以 PNG 复制到剪贴板。按 `⌘V` 可在支持图片的应用中粘贴。按 `Esc` 或右键可取消截图。在输入文字时，`Return` 提交文字，`Esc` 取消文字输入。

| 要调整的内容 | 选择工具的操作 |
| --- | --- |
| 图形或文字的位置 | 单击图形线条、矩形或椭圆内部，或单击文字，即可选中。也可以直接按住标注拖动。 |
| 图形或文本框的大小 | 选中后拖动控制点。直线和箭头可分别调整两个端点。 |
| 文字内容 | 双击文字重新输入。无框文字在编辑时可滚动调整字号。 |
| 标注的颜色或删除 | 选中标注后点击色板换色，或按 `Delete` 删除。 |
| 截图选区 | 拖动空白处或选区边框，图形和文字会随选区移动。拖动选区边缘或角上的控制点可缩放。 |

点击撤销按钮或按 `⌘Z`，可回退上一次标注编辑或选区调整。

使用画笔、直线、矩形、椭圆和箭头时，滚动鼠标滚轮可调整线条粗细。光标圆环同步显示当前线宽，每种工具在本次截图中各自记住线宽。

选中「文本」工具后，可以在截图选区内编辑或添加文字。

| 操作 | 输入方式 |
| --- | --- |
| 单击已有文字或文本框 | 在点击处定位光标并编辑原文字。 |
| 单击空白处 | 在点击处无框输入。按 `Shift + Return` 换行，滚动鼠标滚轮调整字号。 |
| 拖拽 | 拉出文本框。文字自动换行，字号随框的大小和内容调整。 |

从菜单栏选择「设置截图快捷键…」变更快捷键。组合键至少包含 `⌘`、`⌃` 或 `⌥` 之一，保存后立即生效。工具栏优先显示在选区下方，空间不足时放在上方。缩放选区时，超出选区的部分会被裁切。

点击菜单栏中的「登录时自动启动」即可开启或关闭。开启后，下次登录 macOS 时，XScreenshot 会自动出现在菜单栏。如果菜单显示「待批准」，请选择「打开系统登录项…」，然后允许 XScreenshot 自动启动。

有多个显示器时，可以在任意一块屏幕上开始框选，选区会限制在拖动起点所在的显示器内。
