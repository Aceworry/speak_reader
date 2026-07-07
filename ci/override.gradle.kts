
// 由 CI 追加:强制所有插件子模块使用 compileSdk 36
// 用插件加载钩子而非 afterEvaluate,避免"项目已评估"的时机错误。
subprojects {
    plugins.withId("com.android.library") {
        extensions.configure<com.android.build.gradle.LibraryExtension>("android") {
            compileSdk = 36
        }
    }
    plugins.withId("com.android.application") {
        extensions.configure<com.android.build.gradle.AppExtension>("android") {
            compileSdkVersion(36)
        }
    }
}
