# EMA Scanner (Flutter)

一个使用 Flutter 编写的 Binance USDT 永续合约 EMA(7/25/99) 收敛扫描工具，支持桌面（Windows）和 Android。

---

## 功能概述

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
- UI 支持：
	- 参数可调：K 线周期、Top N、收敛阈值、K 线数量、并发 workers 数。
	- 显示当前扫描进度、匹配到的合约及其 spread%。
	- 支持一键终止扫描、清空结果。

---

## 主要参数

在主界面中可以直接调整以下参数：

- **interval**：K 线周期
	- 选项：`3m` / `15m` / `1h` / `4h` / `1d`
- **topN**：
	- 从 24h 成交额最高的 USDT 永续合约中取前 N 个进行扫描。
- **threshold**：
	- spread 阈值（例如 0.1 表示 10%），`spread <= threshold` 视为收敛。
- **klinesLimit**：
	- 每个交易对请求的 K 线根数，建议 `>= 100`，例如 `120`。
- **workers**：
	- 并发扫描的“worker”数量，用于控制同时请求的交易对数量。

扫描时：

- 使用 `klines` 返回的所有收盘价，丢弃最后一根（未走完的 K 线）。
- 对剩余收盘价序列 `closedCloses` 计算 EMA7/EMA25/EMA99。
- 使用上面的 spread 公式判断是否满足阈值。

---

## 运行环境

- Flutter SDK：3.35.5（stable）及以上
- Dart SDK：随 Flutter 附带
- Windows 10/11（桌面运行）
- Android SDK（Android Studio 或单独安装）
- 已能正常访问 Binance 期货和 Flutter/Gradle 相关站点（网络要求见下文）

---

## 本地运行（Windows 桌面）

1. 安装 Flutter SDK，并确保 `flutter` 在 PATH 中。
2. 在项目根目录执行依赖安装：

	 ```bash
	 flutter pub get
	 ```

3. 以 Windows 桌面运行：

	 ```bash
	 flutter run -d windows
	 ```

4. 在应用中：
	 - 调整参数（interval / topN / threshold / klinesLimit / workers）。
	 - 点击“开始扫描”启动，过程中可以点击“终止”停止、点击“清空结果”重置状态。

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

### 3. 构建 APK

在项目根目录执行：

```bash
flutter build apk --debug
```

构建成功后，调试 APK 位于：

```text
build/app/outputs/flutter-apk/app-debug.apk
```

将 APK 复制到安卓手机安装即可（需要在系统设置中允许安装未知来源应用）。

> 如需发布给他人长期使用，可使用 `flutter build apk --release` 并按官方文档配置签名。

---

## 常见网络与构建问题

### 1. 访问 Binance 失败 / Flutter 应用内无结果

- 确认系统网络或 VPN 能直接访问 Binance 期货接口，例如：

	```bash
	curl https://fapi.binance.com/fapi/v1/exchangeInfo
	```

- 若命令行可访问但 Flutter 应用报 SSL/Handshake/超时错误：
	- 检查是否有系统代理或企业代理拦截 TLS；
	- 如使用 VPN，优先选择“全局/TUN/系统代理模式”，确保桌面和命令行程序都走同一通道；
	- 如曾在系统中设置过 `http_proxy` / `https_proxy`，可参考下文“重置 http_proxy”。

### 2. Gradle 下载超时（maven.google.com / services.gradle.org / storage.googleapis.com）

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

### 3. 重置 http_proxy / https_proxy（PowerShell）

若曾设置过代理导致命令行网络异常，可以在 PowerShell 中重置：

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

---

## 开发说明

- 主要入口文件：
	- Flutter 应用入口：`lib/main.dart`
- UI：
	- 单页面 `EmaScannerPage`，包含参数表单、状态文本、结果列表、开始/终止/清空按钮。
- 并发：
	- 按 `workers` 将交易对分批，使用 `Future.wait` 并发请求 Binance K 线。
- 日志：
	- 使用 `debugPrint` 输出以 `[EMA]` 和 `[EMA][HTTP]` 为前缀的调试信息，可在 `flutter run` 的终端中查看。

如需扩展功能（例如增加更多指标、改用不同的 spread 计算方式、增加多语言 UI 等），可以从 `lib/main.dart` 入手修改对应逻辑。
