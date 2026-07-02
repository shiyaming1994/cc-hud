enum AppInfo {
    /// 版本号唯一来源。build-app.sh 会从这里提取写入 Info.plist 的
    /// CFBundleShortVersionString，保证菜单显示的版本与打包 app 一致。改版本只改这一行。
    static let version = "1.2.1"
}
