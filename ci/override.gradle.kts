
// 由 CI 追加:强制所有插件子模块使用 compileSdk 36
// file_picker 等插件在自身构建文件里写死了旧版本,需在此统一覆盖。
subprojects {
    afterEvaluate {
        val androidExt = extensions.findByName("android")
        if (androidExt is com.android.build.gradle.BaseExtension) {
            androidExt.compileSdkVersion(36)
        }
    }
}
