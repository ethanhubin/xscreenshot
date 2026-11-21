# XScreenshot 安装包

`XScreenshot.dmg` 是最新生成的安装包，支持 macOS 14 或更新版本的 Apple 芯片和 Intel Mac。打开磁盘映像后，把 `XScreenshot.app` 拖到「应用程序」。启动后，可从菜单栏的取景框图标开始截图。

## 生成试装包

在仓库根目录运行 `./scripts/build-release.sh`。脚本成功后会替换 `release/XScreenshot.dmg`。版本号取自 `App/Info.plist`，DMG 由脚本生成，不纳入源码版本控制。

默认构建使用临时签名，适合本机试装。其他 Mac 下载后可能被 Gatekeeper 拦截。接收者确认包的来源后，可以按 Apple 的步骤为该应用单独授权。 [Apple 支持](https://support.apple.com/zh-cn/102445)

## 对外发布

更新 `App/Info.plist` 的 `CFBundleShortVersionString` 和 `CFBundleVersion`。需要钥匙串里有 `Developer ID Application` 证书，并且已用 `xcrun notarytool store-credentials` 存好 Apple 公证凭据。把下面的证书名和凭据名称替换为实际值，然后在仓库根目录运行。 [Apple 签名与公证文档](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)

```sh
XSCREENSHOT_SIGN_IDENTITY='Developer ID Application: Your Name (TEAMID)' \
XSCREENSHOT_NOTARY_PROFILE='xscreenshot-notary' \
./scripts/build-release.sh
```

脚本会签名应用和 DMG，提交 Apple 公证并附加票据。成功后，把 `release/XScreenshot.dmg` 上传为对应版本的 GitHub Release 附件。
