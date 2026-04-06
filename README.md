# EMA Scanner (Flutter)

一个使用 Flutter 编写的 Binance USDT 永续合约 EMA(7/25/99) 收敛扫描工具，支持 **多任务并发扫描**，**系统级实时提醒**（Windows 托盘通知、Android 通知栏、Web 浏览器通知）。支持桌面（Windows/macOS/Linux）、移动端（Android）和 Web 浏览器。

---

## 功能概述

### 核心扫描功能
- 从 Binance USDT-M 永续合约获取交易对：
	- 通过 `/fapi/v1/exchangeInfo` 过滤出 USDT 永续合约（PERPETUAL, quoteAsset=USDT, status=TRADING）。
	- 通过 `/fapi/v1/ticker/24hr` 按 24 小时 `quoteVolume` 排序，选出前 N 个交易对。
- 对每个交易对拉取 K 线：
	- `/fapi/v1/klines?symbol=...&interval=...&limit=...`
	- 只使用已经走完的 K 线（丢弃最后一根实时 K 线）。
- 计算 EMA：
	- EMA(7)、EMA(25)、EMA(99)，使用前 span 根的简单平均作为初始值，然后按标准 EMA 公式递推。
- 收敛判断（spread 逻辑）：
	- 设三条 EMA 为 $e_7, e_{25}, e_{99}$，
	- $mn = \min(e_7, e_{25}, e_{99}), mx = \max(e_7, e_{25}, e_{99})$，
	- $spread = \dfrac{mx - mn}{|mn|}$，
	- 当 `spread <= threshold` 时认为三条均线收敛。

### 多任务扫描
- **独立任务管理**：支持同时创建多个不同周期的扫描任务，每个任务拥有独立的：
	- 扫描周期（K 线间隔）
	- 收敛阈值
	- 扫描结果集
- **连续扫描**：每个任务可独立配置为连续模式，按设定间隔自动重复扫描，无需手动触发。
- **并发执行**：多个扫描任务可同时进行，互不影响。

### 智能提醒系统
- **新币种检测**：仅在新匹配币种首次出现时发送提醒，避免重复通知。
- **币种消失后重新出现**：如果某币种在后续扫描中消失，再次出现时会重新发送提醒。
- **平台感知通知**：
	- **Windows/macOS/Linux 桌面**：
		- 应用在前台时：弹出应用内对话框
		- 应用在后台时：系统托盘通知（Windows 原生 Toast）
	- **Android 移动端**：系统通知栏提醒（无论应用是否在前台）
	- **Web 浏览器**：浏览器通知 API（需用户授权）

### 用户界面
- 参数可调：K 线周期、Top N、收敛阈值、K 线数量、并发 workers 数。
- 显示实时扫描进度、匹配到的合约及其 spread%。
- 每个扫描任务单独显示，支持独立添加、停止、查看结果。
- 支持一键终止扫描、清空单个任务结果。

---

## 主要参数说明

### 扫描任务参数

每个扫描任务需要配置以下参数：

- **interval**：K 线周期
	- 选项：`3m` / `15m` / `1h` / `4h` / `1d`
	- 说明：较短的周期适合快速交易，较长的周期适合中长期分析。
- **topN**：
	- 范围：1 ~ 500
	- 说明：从过去 24h 成交额最高的 USDT 永续合约中取前 N 个进行扫描。数值越大扫描覆盖面越广，但耗时越长。
- **threshold**：
	- 范围：0.001 ~ 1.0（推荐 0.05 ~ 0.15）
	- 说明：spread 阈值。当三条均线的相对差异 <= threshold 时判定为收敛。例如 0.1 表示 10%，数值越小收敛条件越严苛。
- **klinesLimit**：
	- 范围：100 ~ 1000（推荐 >= 100）
	- 说明：每个交易对请求的 K 线根数。更多的 K 线会使 EMA 计算更加平滑，但增加网络请求时间。
- **workers**：
	- 范围：1 ~ 50（推荐 10 ~ 20）
	- 说明：并发请求的数量。较大的值会加快扫描速度，但可能导致 API 响应变慢或被限流。
- **连续扫描**：
	- 开启：任务会每隔约 5 秒自动重复一轮扫描。
	- 关闭：任务扫描一轮后停止，需手动点击"开始扫描"再次运行。

### 全局参数

- **任务数量**：同时可运行多个独立扫描任务，互不干扰。
- **通知方式**：自动根据平台和应用状态选择（应用前台 → 对话框；应用后台 → 系统级通知）。

---

## 运行环境

- Flutter SDK：3.38.1（stable）及以上
- Dart SDK：随 Flutter 附带
- Windows 10/11（桌面运行）
- macOS 10.15+ / Linux（桌面运行）
- Android 8.0+（移动端）
- 现代浏览器（Chrome/Edge/Firefox，用于 Web 版本）
- Android SDK（Android Studio 或单独安装，用于 APK 打包）
- 已能正常访问 Binance 期货和 Flutter/Gradle 相关站点（网络要求见下文）

### 依赖版本
- `flutter_local_notifications: ^21.0.0`（系统通知支持）
- `http: ^1.2.0`（Binance API 通信）

---

## 本地运行（Windows 桌面）

1. 安装 Flutter SDK（推荐 3.38.1+），并确保 `flutter` 在 PATH 中。
2. 在项目根目录执行依赖安装：

	 ```bash
	 flutter pub get
	 ```

3. 以 Windows 桌面运行：

	 ```bash
	 flutter run -d windows
	 ```

4. 在应用中：
	 - 点击"添加扫描任务"创建一个新的扫描任务。
	 - 调整任务参数（周期 / TopN / 收敛阈值 / K线数量）。
	 - 切换"连续扫描"开关启用连续模式（如需）。
	 - 点击"开始扫描"启动该任务；可添加多个任务同时扫描。
	 - 应用在后台时会通过 Windows 系统托盘显示提醒。
	 - 点击"停止"停止单个任务、"清空结果"重置该任务的匹配结果。

---

## Android 打包与运行

### 1. 准备 Android SDK

可以使用 Android Studio 自带的 SDK，也可以手动安装 commandline-tools：

- 确保已安装：
	- `Android SDK Platform-Tools`
	- 对应版本的 `Android SDK Platform`（例如 34/35/36）
	- `Android SDK Build-Tools`
- 使用 Flutter 配置 SDK 路径，例如：

	```bash
	flutter config --android-sdk "D:\\AndroidStudioSdk"
	flutter doctor
	```

	确保 `Android toolchain` 显示为 ✓。

### 2. 接受 Android 许可证

```bash
flutter doctor --android-licenses
```

按提示输入 `y` 接受所有条款。

### 3. 配置 Gradle（重要）

本项目使用 `flutter_local_notifications v21.0.0`，该版本要求启用 Java 8 核心库反反混淆。

**这已在 `android/app/build.gradle.kts` 中预配置，不需手动修改。** 配置内容（仅供参考）：

```gradle
android {
  compileOptions {
    sourceCompatibility = JavaVersion.VERSION_11
    targetCompatibility = JavaVersion.VERSION_11
    isCoreLibraryDesugaringEnabled = true
  }
}
dependencies {
  coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}
```

### 4. 构建 APK

在项目根目录执行：

```bash
flutter build apk --debug
```

构建成功后，调试 APK 位于：

```text
build/app/outputs/flutter-apk/app-debug.apk
```

### 5. 在 Android 设备上安装与测试

#### 方式 A：使用 ADB（USB 连接）

1. 连接 Android 手机到电脑，开启"USB 调试"：
	 - 进入手机"开发者选项"（设置 → 关于手机 → 点击"版本号"7 次）
	 - 允许 USB 调试

2. 安装 APK：

	 ```bash
	 adb install build/app/outputs/flutter-apk/app-debug.apk
	 ```

3. 或在 Flutter 中直接运行到连接的设备：

	 ```bash
	 flutter run
	 ```

#### 方式 B：直接安装（无电脑）

1. 将 `app-debug.apk` 复制到手机存储。
2. 在文件浏览器中打开 APK，系统会提示安装。
3. 根据需要允许安装来自未知来源的应用（在系统设置中防火墙/安全设置）。

#### 方式 C：使用 Android Studio

1. 在 Android Studio 中打开此项目。
2. 连接 Android 设备或启动模拟器。
3. Run → Run 'app' 或按 Shift+F10。

#### Android 13+ 权限提示

首次运行应用时，系统会要求授予"通知"权限（`POST_NOTIFICATIONS`）。**请点击"允许"**，否则系统通知无法显示。

### 6. 验证通知功能

1. 安装并启动应用。
2. 添加一个扫描任务，启用"连续扫描"。
3. 将应用切换到后台（按 Home 键或打开其他应用）。
4. 当扫描到新匹配币种时，应在**通知栏**看到提醒（而非应用内对话框）。
5. 如果权限被拒绝，请在设置 → 应用 → [此应用] → 通知中手动启用。

### 7. 发布版本构建（可选）

如需发布给他人长期使用，可以构建发布版本：

```bash
flutter build apk --release
```

> 注意：发布版本需要配置签名密钥，详见 [Flutter 官方文档](https://flutter.dev/docs/deployment/android#signing-the-app)。

---

## 常见问题与故障排查

### 网络与构建问题

#### 1. 访问 Binance 失败 / Flutter 应用内无结果

- 确认系统网络或 VPN 能直接访问 Binance 期货接口，例如：

	```bash
	curl https://fapi.binance.com/fapi/v1/exchangeInfo
	```

- 若命令行可访问但 Flutter 应用报 SSL/Handshake/超时错误：
	- 检查是否有系统代理或企业代理拦截 TLS；
	- 如使用 VPN，优先选择“全局/TUN/系统代理模式”，确保桌面和命令行程序都走同一通道；
	- 如曾在系统中设置过 `http_proxy` / `https_proxy`，可参考下文“重置 http_proxy”。

#### 2. Gradle 下载超时（maven.google.com / services.gradle.org / storage.googleapis.com）

初次执行 `flutter build apk` 时，Gradle 需要从外网下载：

- Gradle 分发包：`https://services.gradle.org/...`
- Maven 依赖：`https://maven.google.com/...`
- Flutter 引擎 jar：`https://storage.googleapis.com/download.flutter.io/...`

若出现 `Connection timed out` 或 `Read timed out`：

- 确保当前网络/VPN 能访问上述站点（可用 `curl` 测试）：

	```bash
	curl https://maven.google.com -v
	curl https://services.gradle.org -v
	curl https://storage.googleapis.com/download.flutter.io -v
	```

- 如使用 VPN，请：
	- 开启“全局模式 / 系统代理 / TUN 模式”等选项；
	- 或在 Gradle 中配置 HTTP/HTTPS 代理，指向 VPN 提供的本地代理端口（编辑 `~/.gradle/gradle.properties` 或 `android/gradle.properties`）：

		```properties
		systemProp.http.proxyHost=127.0.0.1
		systemProp.http.proxyPort=本地端口
		systemProp.https.proxyHost=127.0.0.1
		systemProp.https.proxyPort=本地端口
		```

- 网络较差时，多尝试几次 `flutter build apk`，下载完成后会缓存在本机。

#### 3. 重置 http_proxy / https_proxy（PowerShell）

1. 清除当前会话中的环境变量：

	 ```powershell
	 Remove-Item Env:http_proxy  -ErrorAction SilentlyContinue
	 Remove-Item Env:https_proxy -ErrorAction SilentlyContinue
	 Remove-Item Env:HTTP_PROXY  -ErrorAction SilentlyContinue
	 Remove-Item Env:HTTPS_PROXY -ErrorAction SilentlyContinue

	 Get-ChildItem Env:http*
	 Get-ChildItem Env:https*
	 ```

2. 重置 WinHTTP 代理（管理员 PowerShell）：

	 ```powershell
	 netsh winhttp show proxy
	 netsh winhttp reset proxy
	 netsh winhttp show proxy
	 ```

3. 在 Windows 设置中关闭系统代理：
	 - 设置 → 网络和 Internet → 代理 → 关闭“使用代理服务器”。
### 应用功能与通知问题

#### 4. 扫描结果为空

- **原因**：
	1. 网络连接问题，无法访问 Binance API；
	2. 收敛阈值设置过小，没有币种符合条件；
	3. TopN 设置过小，扫描范围不够广；
	4. K 线周期过短，导致 EMA 没有充分平滑。
- **解决方案**：
	1. 检查网络连接和代理设置；
	2. 尝试增加 `threshold`（例如从 0.05 改为 0.15）；
	3. 增加 `topN` 的值（例如从 50 改为 100）；
	4. 增加 `klinesLimit`（例如从 100 改为 200）。

#### 5. 应用在后台时收不到通知

- **Windows 桌面**：
	- 检查应用是否真的在后台（Home 键或打开其他应用）；
	- 确认 Windows 通知已启用（设置 → 系统 → 通知和操作）；
	- 如仍无反应，尝试重新构建应用：`flutter clean && flutter run -d windows`。
- **Android 移动端**：
	- **首次安装时必须授予"通知"权限**（Android 13+ 会弹窗要求）；
	- 如权限已拒绝，手动启用：设置 → 应用 → [本应用] → 权限 → 通知；
	- 确认原生通知栏没有被第三方应用（如通知管理器）禁用；
	- 尝试卸载并重新安装应用。
- **Web 浏览器**：
	- 浏览器通知需要用户手动授权；第一次尝试显示通知时会提示；
	- 如已拒绝，请在浏览器设置中允许本网站的通知；
	- 确认浏览器未处于"请勿打扰"模式。

#### 6. 同时添加多个任务，但扫描速度变慢

- **原因**：并发任务数过多，或 API 限流；
- **解决方案**：
	1. 减少 `topN` 或 `klinesLimit` 的值；
	2. 减少 `workers` 的数量（过大可能被 Binance 限流）；
	3. 确保网络带宽充足；
	4. 如果有多个任务，可错开它们的"连续扫描"开始时间，而非同时全部启动。

#### 7. 匹配结果中有重复币种

- 不同的任务（不同周期或阈值）可能在不同时刻匹配到同一币种，这是正常的。
- 如同一个任务中出现重复，请联系开发者反馈。

#### 8. 应用崩溃

- 检查 Flutter 的日志输出（在 `flutter run` 的终端）；
- 确保 Flutter SDK 版本 >= 3.38.1；
- 尝试 `flutter clean && flutter pub get && flutter run`；
- 如仍有问题，根据错误信息查询 Flutter 官方文档或开源社区。
---

## 开发说明

### 项目结构

- 主要入口文件：
	- Flutter 应用入口：[lib/main.dart](lib/main.dart)
- Web 通知支持：
	- [lib/web_notifications/web_notification_service_web.dart](lib/web_notifications/web_notification_service_web.dart) - Web 浏览器 Notification API 实现
	- [lib/web_notifications/web_notification_service_stub.dart](lib/web_notifications/web_notification_service_stub.dart) - 非 Web 平台的 Stub 实现

### 核心架构

#### 多任务扫描
- 每个 `_ScanTask` 对象维护独立状态：
	- `threshold`：该任务的收敛阈值
	- `matches`：当前扫描周期的匹配结果
	- `lastMatchedSymbols`：上一轮的匹配币种集合（用于新币种检测）
	- `interval`：K 线周期
	- `continuous`：是否启用连续扫描
- 多个任务通过独立的 async worker 并发运行，互不阻塞。

#### 智能提醒系统
- **新币种检测**：每轮扫描后，计算 `newSymbols = currentSymbols - lastMatchedSymbols`，仅对新币种发送通知。
- **消失重新出现**：`lastMatchedSymbols` 每轮更新；如果币种未在当前轮出现，则从集合中移除，下轮出现时视为"新币种"。
- **平台路由**（`_notifyForTaskMatches` 方法）：
	- Web：尝试调用浏览器 Notification API；若被拒或无权限，改用应用内对话框
	- Windows/macOS/Linux：应用在前台时弹出对话框，后台时调用系统 Toast
	- Android：始终调用系统通知栏（独立于应用前后台状态）

#### 生命周期监控
- 应用实现 `WidgetsBindingObserver` 接口，通过 `didChangeAppLifecycleState()` 跟踪前后台状态。
- `_isAppResumed` 标志用于判断应用窗口是否获得焦点，影响通知的显示方式。

### UI 流程

1. 主页显示任务列表和"添加任务"按钮。
2. 用户填写新任务的参数后，点击"添加"创建 `_ScanTask` 对象并加入列表。
3. 每个任务显示独立的开始/停止按钮、进度条、匹配结果列表。
4. 扫描时调用 `_runScanForTask()` 持续获取 Binance 数据；如启用连续扫描，线程不会退出，而是每 N 秒重复扫描。
5. 匹配到新币种时，调用 `_notifyForTaskMatches()` 发送通知。

### 并发控制

- 使用 `workers` 参数分批并发请求 Binance K 线接口。
- 使用 `Future.wait` 等待一批请求完成后，继续下一批。
- 多任务时，每个任务的 `_runScanForTask` 运行在独立的 async context 中，不竞争共享资源。

### 日志与调试

- 使用 `debugPrint` 输出以 `[EMA]` 和 `[EMA][HTTP]` 为前缀的调试信息，可在 `flutter run` 的终端中查看。
- 扫描进度、API 响应、EMA 计算结果等均会被记录。

### 平台特定的配置

#### Windows 托盘通知
- 需要 GUID 和 `appUserModelId`，已在 `_initNotifications()` 中配置。

#### Android 系统通知
- 需要 `POST_NOTIFICATIONS` 和 `VIBRATE` 权限，已在 [android/app/src/main/AndroidManifest.xml](android/app/src/main/AndroidManifest.xml) 中声明。
- Android 13+ 需要用户运行时授予权限；应用启动时会自动请求。
- gradle 反反混淆配置已在 [android/app/build.gradle.kts](android/app/build.gradle.kts) 中启用。

#### Web 浏览器通知
- 使用浏览器的 Notification API（需要 HTTPS 或 localhost）。
- 首次尝试通知时会请求用户授权；用户可在浏览器设置中永久允许或拒绝。

### 扩展功能

如需扩展功能（例如增加更多指标、改用不同的 spread 计算方式、增加多语言 UI、云端保存任务等），可以从 [lib/main.dart](lib/main.dart) 入手修改对应逻辑。
