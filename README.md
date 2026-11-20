# XScreenshot

XScreenshot 是一个 macOS 菜单栏截图工具。需要 macOS 14 或更新版本，以及带 Swift 6 的 Xcode 或 Xcode Command Line Tools。

## 构建和运行

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
3. 在半透明黑色遮罩上按住鼠标左键拖动。选区内保持原亮度，松开后显示工具栏。
4. 选择工具栏中的移动工具，可以拖动选区内部来移动选区，或拖动边缘和角上的控制点来缩放。用画笔、直线、矩形、椭圆、箭头或文本添加标注，点击色板更换标注颜色。用撤销按钮或 `⌘Z` 回退上一次标注或选区调整。
5. 点击确认按钮或按 `Return`，将编辑后的截图以 PNG 复制到剪贴板。按 `⌘V` 可在支持图片的应用中粘贴。按 `Esc` 或右键可取消截图。在输入文字时，`Return` 提交文字，`Esc` 取消文字输入。

从菜单栏选择「设置截图快捷键…」变更快捷键。组合键至少包含 `⌘`、`⌃` 或 `⌥` 之一，保存后立即生效。工具栏优先显示在选区下方，空间不足时放在上方。标注随屏幕内容固定，缩放或移动选区时会裁掉范围外的部分。

有多个显示器时，可以在任意一块屏幕上开始框选，选区会限制在拖动起点所在的显示器内。
