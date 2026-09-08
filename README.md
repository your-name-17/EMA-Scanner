# PerpScope

Binance USDT 永续合约扫描工具（Flutter）。用于 6 线密度扫描、新币/发行日查询、密集后趋势观察，以及在 Binance 页面上按队列顺序浏览结果。

支持平台：Windows / macOS / Linux、Android、Web。

---

## 功能概览

### 1. 6 线混合密度扫描

从 USDT-M 永续合约中按 24h 成交额取前 `topN`，拉取 K 线后计算：

- EMA(20 / 60 / 120)
- MA(20 / 60 / 120)

密度公式：

$$
mn = \min(\text{6条线}),\quad
mx = \max(\text{6条线}),\quad
spread = \frac{mx - mn}{|mn|}
$$

`spread <= threshold` 视为匹配。扫描包含当前未走完的 K 线；内部会把 K 线数量至少扩展到 1000 根，保证 EMA120 / MA120 充分热身。

### 2. 新币与发行日

- **扫描新币(24h成交额排序)**：最近 N 天上新，按 24h 成交额排序。
- **扫描新币(全时成交额排序)**：最近 N 天上新，按上市以来累计成交额排序（优先日线 `quoteVolume`，失败再回退 aggTrades）。
- **查询发行币种**：先选起始/终止日期，再查该区间内上线的 USDT 永续合约。
- **扫描稳定币种(<100倍波动)**：自上市以来日线高低点倍数低于 100 的币种。

上市天数过滤（多数扫描共用）：

- **天数≤**：只看上市不超过这么多天的币（默认 550）。
- **天数>**：只看上市超过这么多天的币（默认 0）。

### 3. 密集后上升趋势

- **扫描密集后上升趋势**：在密度收敛之后，寻找后续上升形态。
- **回测密集后上升趋势**：对同一规则做历史回测。

### 4. 多任务与连续扫描

可同时添加多个任务（不同周期、阈值）。每个任务可单独开始、停止、删除。开启连续扫描后，会等到该周期下一根 K 线收线再扫下一轮（优先用 Binance 服务器时间）。

仅对本轮**新出现**的匹配币种发通知，避免重复提醒。

### 5. 顺序浏览 Binance

扫描或查询出结果后，不必逐个点链接：

- 每次打开 **3 个** 标签为一批；**下一个(+3) / 上一个(-3)** 按批次前进/后退。
- 点结果里的**币种链接**：以该币为**批次起点**打开 3 个标签。
- **同一批次里任意一个窗口**点下一组，打开的都是**相同的下一批 3 个**（按批次起点计算，不会因当前是第 1/2/3 个窗口而偏移）。
- 新开标签，**不覆盖、不关闭**已打开的页。
- 主界面 **开始浏览**：若队列里还有上次位置，从该批次续扫；关光标签后再点也会续扫，不必从头。
- 结果弹窗 **开始顺序浏览**：从该批结果的第一个开始；点过后弹窗仍保留，点 **确定** 才关。

链接模式：

- **合约**：打开永续合约页。
- **现货/Alpha**：优先现货，找不到再走 Alpha。

---

## Binance 顺序浏览（Tampermonkey）

Web 端建议配合油猴脚本，在 Binance 页里也能切队列。

脚本路径：[`tools/tampermonkey/perpscope-binance-browser.user.js`](tools/tampermonkey/perpscope-binance-browser.user.js)（当前 **v0.6.0**）。

### 安装

1. 浏览器安装 [Tampermonkey](https://www.tampermonkey.net/)。
2. 用脚本内容新建用户脚本并保存。
3. 更新脚本后请覆盖安装到同一条，不要留着旧版本。

### 用法

1. 先在 PerpScope 点 **开始浏览** / **开始顺序浏览**，或直接点某个币种链接（浏览器可能拦截弹窗，需允许本站点弹窗）。
2. 打开的 Binance 页右下角有 **Prev -3 / Next +3**。
3. 快捷键同样每次跳 3 个：**[ ]**、**← →**、**J K**、**PageUp / PageDown**（焦点在图表 iframe 里时可能无效，用按钮即可）。
4. 同一批 3 个窗口里，任意窗口点 Next，下一组结果一致。

脚本不会把当前标签导航走，下一组 3 个会新开；已打开的标签会保留。游标存的是**批次起点**，三个窗口共享同一起点。

---

## 参数说明

### 任务参数

- **周期**：3m / 15m / 1h / 4h / 1d
- **topN**：按 24h 成交额取前 N 个
- **threshold**：密度阈值（建议 0.05 ~ 0.20）
- **klinesLimit**：请求根数；内部至少扩到 1000
- **workers**：并发数（建议 8 ~ 20）
- **天数≤ / 天数>**：上市天数区间
- **仅在新币中扫描EMA**：密度任务只扫新币池

### 使用建议

- 更快发现：短周期（3m/15m），略提高 workers。
- 更稳：长周期（1h/4h/1d）。
- 结果太少：加大 threshold 或 topN。
- 超时/限流多：减小 workers，降低连点扫描的频率。

---

## 环境要求

- Flutter SDK 3.9+
- 可访问 `https://fapi.binance.com`

主要依赖：`http`、`flutter_local_notifications`、`url_launcher`、`shared_preferences`。

---

## 快速开始

```bash
flutter pub get
flutter run -d windows    # 桌面
flutter run -d chrome     # Web
flutter run               # Android 真机
```

Web 调试也可用：

```bash
flutter run -d web-server
```

---

## Android 打包

```bash
flutter build apk --debug
flutter build apk --release
```

产物：`build/app/outputs/flutter-apk/`

- 已声明 `POST_NOTIFICATIONS`、`VIBRATE`。
- 已启用 core library desugaring（配合 `flutter_local_notifications`）。
- 发布包需要自行配置签名。

---

## 通知

- **Android 13+**：首次启动会请求通知权限。
- **桌面**：前台弹窗，后台走系统通知。
- **Web**：首次通知时请求浏览器授权。

---

## 常见问题

### 查询发行币种没反应？

先选 **起始日期** 和 **终止日期**。未选日期时状态栏会提示，不会静默卡住。

### HTTP 418 / IP 被限流？

这是 Binance 对当前 IP 的临时封禁，不是程序故障。等状态栏给出的时间后再试，期间不要连续点多个扫描。也可换网络（例如手机热点）。`exchangeInfo` 会缓存约 5 分钟，`ticker/24hr` 约 45 秒，以减少重复请求。

### ClientException: Failed to fetch？

Web 端浏览器直连 Binance 可能被 CORS 或网络拦截。可改用 `flutter run -d windows`，或检查本机能否打开 `https://fapi.binance.com`。

### 连续扫描为什么不是几秒一次？

按任务周期对齐到下一根 K 线收线后再扫。

### 顺序浏览没有弹出新标签？

浏览器拦截了弹窗。允许本站点弹窗后，再点一次 **开始浏览**。油猴脚本请更新到 v0.6.0。

### 结果弹窗点了开始顺序浏览就消失？

当前版本会保留弹窗，点 **确定** 才关闭。若仍会关掉，请热重启后再试。

---

## 开发说明

| 文件 | 作用 |
| --- | --- |
| [`lib/main.dart`](lib/main.dart) | UI、任务、扫描、发行日查询、浏览队列 |
| [`lib/market/indicators.dart`](lib/market/indicators.dart) | EMA / MA |
| [`lib/market/post_dense.dart`](lib/market/post_dense.dart) | 密集后趋势 |
| [`lib/src/binance_viewer_web.dart`](lib/src/binance_viewer_web.dart) | Web 打开 Binance 标签 |
| [`lib/src/browse_queue_bridge_web.dart`](lib/src/browse_queue_bridge_web.dart) | 把浏览队列写到 `localStorage` |
| [`tools/tampermonkey/perpscope-binance-browser.user.js`](tools/tampermonkey/perpscope-binance-browser.user.js) | Binance 页内 Prev/Next 与快捷键 |

要点：

- 浏览步进为 **3**。每个币种使用独立窗口名 `perpscope_<index>`，下一组不会覆盖上一组标签。
- `currentIndex` 表示**当前批次起点**；同批三个窗口 URL hash 都带同一起点，Next/Prev 结果一致。
- 队列通过 URL hash `#perpscope_queue=` 注入油猴脚本，并同步到 `localStorage` 键 `perpscopeBrowseQueue`。
- 密度算法：EMA 为首价种子 + 递推（`alpha = 2/(span+1)`），MA 为尾部 span 根简单平均。

---

## 最近更新

### 2026-09-08

- 同一批次任意窗口点「下一组」，都打开相同的下一批 3 个（按批次起点计算，不再按当前页面币种偏移）。
- 点击结果里的币种链接会定位浏览游标，并从该币起打开 3 个标签；「下一个(+3)」从此处继续。
- 主界面「开始浏览」会从上次位置续扫；弹窗「开始顺序浏览」仍从该批开头。
- 油猴脚本 v0.6.0。

### 2026-08-18

- 顺序浏览每次跳 3 个币种，新开标签，不覆盖已打开页面。
- 结果弹窗点「开始顺序浏览」后仍保留。
- 「查询发行币种」补齐日期校验、进度/失败提示；418 限流立即失败并显示封禁时间。
- 常用接口增加短时缓存。
- 油猴脚本更新至 v0.4.0。

---

## 免责声明

本项目仅用于技术研究与策略观察，不构成投资建议。数字资产交易存在高风险，请自行评估并承担风险。
