import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show kIsWeb, debugPrint;
import 'package:flutter/gestures.dart' show TapGestureRecognizer;
import 'package:flutter/services.dart' show MethodChannel;
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'web_notifications/web_notification_service_stub.dart'
    if (dart.library.html) 'web_notifications/web_notification_service_web.dart';
import 'src/browse_queue_bridge_stub.dart'
    if (dart.library.html) 'src/browse_queue_bridge_web.dart';
import 'src/binance_viewer_stub.dart'
    if (dart.library.html) 'src/binance_viewer_web.dart';

class _AlphaTokenInfo {
  final String chainName;
  final String contractAddress;
  const _AlphaTokenInfo(this.chainName, this.contractAddress);
}

String binanceFuturesUrl(String symbol) {
  if (_EmaScannerPageState._linkMode == 'futures') {
    return 'https://www.binance.com/en/futures/$symbol';
  }

  // spot_alpha mode: auto-detect
  final cache = _EmaScannerPageState._spotSymbols;
  if (cache != null && cache.isNotEmpty) {
    // Try exact futures symbol first (e.g. BTCUSDT)
    if (cache.contains(symbol)) {
      return 'https://www.binance.com/en/trade/${symbol}?type=spot';
    }
    // Try underscore format (e.g. BTC_USDT)
    final usdtIdx = symbol.lastIndexOf('USDT');
    if (usdtIdx > 0) {
      final spotSymbol = '${symbol.substring(0, usdtIdx)}_USDT';
      if (cache.contains(spotSymbol)) {
        return 'https://www.binance.com/en/trade/$spotSymbol?type=spot';
      }
    }
  }

  // Fallback to alpha
  final base = symbol.replaceAll(RegExp(r'USDT$'), '');
  final alphaCache = _EmaScannerPageState._alphaTokens;
  if (alphaCache != null && alphaCache.isNotEmpty) {
    final info = alphaCache[base] ?? alphaCache[base.toLowerCase()];
    if (info != null) {
      return 'https://www.binance.com/en/alpha/${info.chainName.toLowerCase()}/${info.contractAddress}';
    }
  }
  return 'https://www.binance.com/en/alpha?keyword=$base';
}

String formatVolume(double volume) {
  if (volume >= 1e9) {
    return '${(volume / 1e9).toStringAsFixed(2)}B';
  } else if (volume >= 1e6) {
    return '${(volume / 1e6).toStringAsFixed(2)}M';
  } else if (volume >= 1e3) {
    return '${(volume / 1e3).toStringAsFixed(2)}K';
  } else {
    return volume.toStringAsFixed(2);
  }
}

const MethodChannel _binanceChannel = MethodChannel('perpscope/binance');

Future<void> _openSymbol(String symbol, String linkMode) async {
  if (!kIsWeb && Platform.isAndroid) {
    try {
      final handled = await _binanceChannel.invokeMethod<bool>('openBinance', {
        'symbol': symbol,
        'mode': linkMode,
      });
      if (handled == true) return;
    } catch (e) {
      // ignore and fallback to web
    }
  }

  await openBinanceViewerUrl(binanceFuturesUrl(symbol));
}

TextSpan boldSymbolSpan(String symbol) => TextSpan(
  text: symbol,
  style: const TextStyle(
    fontWeight: FontWeight.bold,
    color: Colors.blue,
    decoration: TextDecoration.underline,
  ),
  recognizer: TapGestureRecognizer()
    ..onTap = () {
      _openSymbol(symbol, _EmaScannerPageState._linkMode);
    },
);

Widget symbolBoldText(String symbol, String suffix) {
  return Text.rich(
    TextSpan(
      children: [
        boldSymbolSpan(symbol),
        TextSpan(text: suffix),
      ],
    ),
  );
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'PerpScope',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      home: const EmaScannerPage(),
    );
  }
}

class EmaScannerPage extends StatefulWidget {
  const EmaScannerPage({super.key});

  @override
  State<EmaScannerPage> createState() => _EmaScannerPageState();
}

class _EmaScannerPageState extends State<EmaScannerPage>
    with WidgetsBindingObserver {
  static String _linkMode = 'futures'; // 'futures' | 'spot_alpha'
  static Set<String>? _spotSymbols;
  static bool _spotFetching = false;
  static Map<String, _AlphaTokenInfo>? _alphaTokens;
  static bool _alphaFetching = false;

  DateTime? listingStartDate;
  DateTime? listingEndDate;

  List<ListingVolumeResult> listingResults = [];
  bool listingSearchRunning = false;
  List<String> _browseSymbols = const <String>[];
  int _browseIndex = -1;
  static const int _browseStep = 3;

  static Future<void> _ensureSpotSymbols() async {
    if (_spotSymbols != null || _spotFetching) return;
    _spotFetching = true;
    try {
      final info =
          await httpGetJson('https://api.binance.com/api/v3/exchangeInfo')
              as dynamic;
      final symbols = <String>{};
      if (info is Map<String, dynamic>) {
        final list = info['symbols'];
        if (list is List) {
          for (final s in list) {
            if (s is! Map<String, dynamic>) continue;
            final sym = (s['symbol'] ?? '').toString();
            if (s['status'] == 'TRADING' && sym.isNotEmpty) {
              symbols.add(sym);
            }
          }
        }
      }
      _spotSymbols = symbols;
      debugPrint('[EMA] 已缓存 ${symbols.length} 个现货交易对');
    } catch (e) {
      debugPrint('[EMA] 获取现货交易对失败: $e');
    } finally {
      _spotFetching = false;
    }
  }

  static Future<void> _ensureAlphaTokens() async {
    if (_alphaTokens != null || _alphaFetching) return;
    _alphaFetching = true;
    try {
      final resp =
          await httpGetJson(
                'https://www.binance.com/bapi/defi/v1/public/wallet-direct/buw/wallet/cex/alpha/all/token/list',
              )
              as dynamic;
      final tokens = <String, _AlphaTokenInfo>{};
      if (resp is Map<String, dynamic>) {
        final list = resp['data'];
        if (list is List) {
          for (final t in list) {
            if (t is! Map<String, dynamic>) continue;
            final sym = (t['symbol'] ?? '').toString();
            final chain = (t['chainName'] ?? '').toString();
            final addr = (t['contractAddress'] ?? '').toString();
            if (sym.isNotEmpty && chain.isNotEmpty && addr.isNotEmpty) {
              tokens[sym.toUpperCase()] = _AlphaTokenInfo(chain, addr);
            }
          }
        }
      }
      _alphaTokens = tokens;
      debugPrint('[EMA] 已缓存 ${tokens.length} 个 Alpha 代币');
    } catch (e) {
      debugPrint('[EMA] 获取 Alpha 代币列表失败: $e');
    } finally {
      _alphaFetching = false;
    }
  }

  String _status = '';

  // 为了让 EMA120 更贴近交易所图表，需要更长历史进行预热。
  static const int _indicatorWarmupKlines = 1000;
  static const int _binanceKlinesMaxLimit = binanceKlinesMaxLimit;

  String interval = '1d';
  int topN = 100;
  double threshold = 0.2;
  int klinesLimit = 1500;
  int workers = 8;

  static const Duration _fallbackContinuousDelay = Duration(seconds: 5);
  static const Duration _scanAlignSafetyBuffer = Duration(seconds: 1);

  final List<_ScanTask> _tasks = <_ScanTask>[];

  final FlutterLocalNotificationsPlugin _notifications =
      FlutterLocalNotificationsPlugin();

  bool _isAppResumed = true;

  late TextEditingController _topNController;
  late TextEditingController _thresholdController;
  late TextEditingController _klinesLimitController;
  late TextEditingController _workersController;
  late TextEditingController _newListingDaysController;
  late TextEditingController _minListingDaysController;

  int newListingDays = 550;
  int minListingDays = 0;
  bool scanOnlyNew = false;

  bool _postDenseTrendScanRunning = false;
  bool _postDenseTrendBacktestRunning = false;
  bool _stableScanRunning = false;
  final List<PostDenseTrendResult> _postDenseTrendResults =
      <PostDenseTrendResult>[];
  final List<PostDenseTrendResult> _postDenseTrendBacktestResults =
      <PostDenseTrendResult>[];
  final List<StableSymbolResult> _stableSymbolResults = <StableSymbolResult>[];

  void _log(String message) {
    debugPrint('[EMA] $message');
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _topNController = TextEditingController(text: topN.toString());
    _thresholdController = TextEditingController(
      text: threshold.toStringAsFixed(2),
    );
    _klinesLimitController = TextEditingController(
      text: klinesLimit.toString(),
    );
    _workersController = TextEditingController(text: workers.toString());
    _newListingDaysController = TextEditingController(
      text: newListingDays.toString(),
    );
    _minListingDaysController = TextEditingController(
      text: minListingDays.toString(),
    );

    _initNotifications();
    _ensureSpotSymbols();
    _ensureAlphaTokens();
  }

  @override
  void dispose() {
    _topNController.dispose();
    _thresholdController.dispose();
    _klinesLimitController.dispose();
    _workersController.dispose();
    _newListingDaysController.dispose();
    _minListingDaysController.dispose();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _isAppResumed = state == AppLifecycleState.resumed;
  }

  Future<void> _initNotifications() async {
    if (kIsWeb) {
      await initWebNotifications();
      return;
    }

    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    const windowsInit = WindowsInitializationSettings(
      appName: 'PerpScope',
      appUserModelId: 'dev.perpscope.app',
      guid: 'd49b0314-ee7a-4626-bf79-97cdb8a991bb',
    );

    const initSettings = InitializationSettings(
      android: androidInit,
      windows: windowsInit,
    );

    await _notifications.initialize(settings: initSettings);

    if (Platform.isAndroid) {
      final androidImpl = _notifications
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >();
      await androidImpl?.requestNotificationsPermission();
    }
  }

  void _clearResults() {
    setState(() {
      for (final task in _tasks) {
        task.matches.clear();
        task.lastMatchedSymbols.clear();
        task.status = '';
        task.isRunning = false;
        task.cancelRequested = false;
      }
      _postDenseTrendResults.clear();
      _postDenseTrendBacktestResults.clear();
      _stableSymbolResults.clear();
      listingResults = [];
      _browseSymbols = const <String>[];
      _browseIndex = -1;
      _status = '已清空所有任务结果';
    });
    clearPublishedBrowseQueue();
    _log('已清空所有任务结果');
  }

  int _parsedMinListingDays() {
    final v = int.tryParse(_minListingDaysController.text);
    if (v == null || v < 0) return 0;
    return v;
  }

  String _listingDaysFilterLabel(int maxDays, int minDays) {
    if (minDays > 0 && maxDays > 0) {
      return '上市${minDays}~${maxDays}天';
    }
    if (minDays > 0) return '上市≥${minDays}天';
    if (maxDays > 0) return '上市≤${maxDays}天';
    return '不限上市天数';
  }

  bool _validateListingDaysRange(int maxDays, int minDays) {
    if (minDays > 0 && maxDays > 0 && minDays > maxDays) {
      setState(() {
        _status = '参数不合法：天数>($minDays) 不能大于 天数≤($maxDays)';
      });
      return false;
    }
    return true;
  }

  List<String> _buildBrowseSymbolsFromCurrentResults() {
    final symbols = <String>[];
    final seen = <String>{};

    void addSymbol(String symbol) {
      if (symbol.isEmpty || !seen.add(symbol)) return;
      symbols.add(symbol);
    }

    final trendUp = _sortedTrendResults(_postDenseTrendResults, 'up');
    final backtestUp = _sortedTrendResults(_postDenseTrendBacktestResults, 'up');

    for (final item in trendUp) {
      addSymbol(item.symbol);
    }
    for (final item in backtestUp) {
      addSymbol(item.symbol);
    }
    for (final item in _stableSymbolResults) {
      addSymbol(item.symbol);
    }
    for (final task in _tasks) {
      for (final match in task.matches) {
        addSymbol(match.symbol);
      }
    }
    for (final item in listingResults) {
      addSymbol(item.symbol);
    }

    return symbols;
  }

  void _publishBrowseQueue() {
    if (!kIsWeb) return;
    final symbols = _browseSymbols;
    final urls = symbols.map(binanceFuturesUrl).toList(growable: false);
    final currentIndex =
        symbols.isEmpty ? -1 : _browseIndex.clamp(0, symbols.length - 1);
    publishBrowseQueue({
      'symbols': symbols,
      'urls': urls,
      'currentIndex': currentIndex,
      'linkMode': _linkMode,
      'updatedAt': DateTime.now().toUtc().toIso8601String(),
    });
  }

  Future<void> _openBrowseIndex(int index) async {
    if (_browseSymbols.isEmpty || index < 0 || index >= _browseSymbols.length) {
      return;
    }
    final symbol = _browseSymbols[index];
    if (!mounted) return;
    final batchEnd = math.min(_browseSymbols.length, index + _browseStep);
    setState(() {
      _browseIndex = index;
      _status =
          '顺序浏览 ${index + 1}-$batchEnd/${_browseSymbols.length}: $symbol';
    });
    _publishBrowseQueue();

    final payload = kIsWeb
        ? Uri.encodeComponent(
            jsonEncode({
              'symbols': _browseSymbols,
              'urls': _browseSymbols
                  .map(binanceFuturesUrl)
                  .toList(growable: false),
              'currentIndex': index,
              'linkMode': _linkMode,
              'updatedAt': DateTime.now().toUtc().toIso8601String(),
            }),
          )
        : null;

    for (var i = index; i < batchEnd; i++) {
      final itemSymbol = _browseSymbols[i];
      var url = binanceFuturesUrl(itemSymbol);
      if (payload != null && i == index) {
        url = '$url#perpscope_queue=$payload';
      }
      await openBinanceViewerUrl(
        url,
        targetName: 'perpscope_$i',
      );
    }
  }

  Future<void> _startBrowseCurrentResults() async {
    final symbols = _buildBrowseSymbolsFromCurrentResults();
    await _startBrowseWithSymbols(symbols);
  }

  Future<void> _startBrowseWithSymbols(Iterable<String> symbols) async {
    final uniqueSymbols = <String>[];
    final seen = <String>{};
    for (final symbol in symbols) {
      if (symbol.isEmpty || !seen.add(symbol)) continue;
      uniqueSymbols.add(symbol);
    }
    if (uniqueSymbols.isEmpty) {
      setState(() {
        _status = '没有可浏览的结果';
      });
      return;
    }

    setState(() {
      _browseSymbols = uniqueSymbols;
      _browseIndex = 0;
    });
    _publishBrowseQueue();
    await _openBrowseIndex(0);
  }

  Future<void> _browsePrev() async {
    if (_browseSymbols.isEmpty) return;
    final nextIndex = _browseIndex <= 0
        ? 0
        : math.max(0, _browseIndex - _browseStep);
    await _openBrowseIndex(nextIndex);
  }

  Future<void> _browseNext() async {
    if (_browseSymbols.isEmpty) return;
    final nextIndex = _browseIndex < 0
        ? 0
        : math.min(_browseSymbols.length - 1, _browseIndex + _browseStep);
    await _openBrowseIndex(nextIndex);
  }

  void _addTask() {
    final parsedThreshold = double.tryParse(_thresholdController.text);
    if (parsedThreshold == null || parsedThreshold <= 0) {
      setState(() {
        _status = '无法添加任务：threshold 不合法（需要 > 0）';
      });
      _log('添加任务失败：threshold 不合法，值=${_thresholdController.text}');
      return;
    }

    threshold = parsedThreshold;
    final int id = _tasks.isEmpty ? 1 : (_tasks.last.id + 1);
    final parsedDays =
        int.tryParse(_newListingDaysController.text) ?? newListingDays;
    setState(() {
      _tasks.add(
        _ScanTask(
          id: id,
          interval: interval,
          threshold: parsedThreshold,
          onlyNewSymbols: scanOnlyNew,
          newListingDays: parsedDays,
        ),
      );
      _status = '已添加任务 #$id (周期 $interval, threshold=$parsedThreshold)';
    });
    _log('已添加任务 #$id (周期 $interval, threshold=$parsedThreshold)');
  }

  void _stopTask(_ScanTask task) {
    if (!task.isRunning) return;
    setState(() {
      task.cancelRequested = true;
      task.status = '已请求终止扫描...';
    });
    _log('收到终止任务 #${task.id} (周期 ${task.interval}) 的请求');
  }

  void _deleteTask(_ScanTask task) {
    setState(() {
      if (task.isRunning) {
        task.cancelRequested = true;
        task.status = '删除中，已请求终止扫描...';
      }
      _tasks.remove(task);
      _status = '已删除任务 #${task.id} (周期 ${task.interval})';
    });
    _log('已删除任务 #${task.id} (周期 ${task.interval})');
  }

  Future<void> _showMatchesDialog(
    String taskInterval,
    List<MatchResult> matches,
  ) async {
    if (!mounted || matches.isEmpty) return;

    await showDialog<void>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text('周期 $taskInterval 发现 EMA 收敛币种'),
          content: SizedBox(
            width: 320,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: matches
                    .map(
                      (m) => symbolBoldText(
                        m.symbol,
                        '  spread=${m.spreadPct.toStringAsFixed(4)}%',
                      ),
                    )
                    .toList(),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () async {
                await _startBrowseWithSymbols(matches.map((m) => m.symbol));
              },
              child: const Text('开始顺序浏览'),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('确定'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _showMatchesNotification(
    String taskInterval,
    List<MatchResult> matches,
  ) async {
    if (kIsWeb || matches.isEmpty) return;

    const androidDetails = AndroidNotificationDetails(
      'ema_scanner_channel',
      'EMA 收敛提醒',
      channelDescription: '当扫描到满足 EMA 收敛条件的币种时提醒',
      importance: Importance.high,
      priority: Priority.high,
    );

    const details = NotificationDetails(android: androidDetails);

    final title = '周期 $taskInterval 发现 ${matches.length} 个 EMA 收敛币种';
    final body = matches
        .take(3)
        .map((m) => '${m.symbol} (${m.spreadPct.toStringAsFixed(2)}%)')
        .join(', ');

    try {
      await _notifications.show(
        id: 0,
        title: title,
        body: body.isEmpty ? null : body,
        notificationDetails: details,
      );
    } catch (e) {
      _log('发送系统通知失败: $e');
    }
  }

  Future<void> _notifyForTaskMatches(
    _ScanTask task,
    List<MatchResult> matches,
  ) async {
    if (!mounted || matches.isEmpty) return;

    if (kIsWeb) {
      final canNotify = await webCanNotify();
      final title = '周期 ${task.interval} 发现 ${matches.length} 个 EMA 收敛币种';
      final body = matches
          .take(3)
          .map((m) => '${m.symbol} (${m.spreadPct.toStringAsFixed(2)}%)')
          .join(', ');

      if (canNotify) {
        await showWebNotification(title, body);
      }

      if (_isAppResumed || !canNotify) {
        await _showMatchesDialog(task.interval, matches);
      }
      return;
    }

    final isDesktop =
        !kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS);

    if (isDesktop) {
      if (_isAppResumed) {
        await _showMatchesDialog(task.interval, matches);
      } else {
        await _showMatchesNotification(task.interval, matches);
      }
    } else {
      // 手机端统一使用系统通知，避免后台场景弹对话框失败。
      await _showMatchesNotification(task.interval, matches);
    }
  }

  Future<void> _scanNewListings() async {
    final parsedDays =
        int.tryParse(_newListingDaysController.text) ?? newListingDays;
    final parsedTopN = int.tryParse(_topNController.text) ?? topN;
    if (parsedDays <= 0) {
      setState(() {
        _status = '天数必须为正整数';
      });
      return;
    }

    setState(() {
      _status = '扫描新币(${parsedDays}天, top=${parsedTopN}) ...';
    });
    try {
      final results = await fetchNewlyListedSymbols(parsedDays, parsedTopN);
      if (results.isEmpty) {
        setState(() {
          _status = '未发现最近 ${parsedDays} 天内的新币 (top ${parsedTopN})';
        });
        _log('未发现最近 ${parsedDays} 天内的新币 (top ${parsedTopN})');
        await showDialog<void>(
          context: context,
          builder: (context) {
            return AlertDialog(
              title: Text('最近 ${parsedDays} 天新币 (top ${parsedTopN})'),
              content: SizedBox(
                width: 320,
                child: Text('未发现最近 ${parsedDays} 天内的新币 (top ${parsedTopN})。'),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('确定'),
                ),
              ],
            );
          },
        );
        return;
      }

      setState(() {
        _status =
            '发现 ${results.length} 个最近 ${parsedDays} 天新币 (top ${parsedTopN})';
      });
      _log('发现 ${results.length} 个最近 ${parsedDays} 天新币 (top ${parsedTopN})');
      await _showNewListingsDialog(results);
    } catch (e) {
      setState(() {
        _status = '扫描新币失败: $e';
      });
      _log('扫描新币失败: $e');
    }
  }

  Future<void> _scanNewListingsByLifetimeVolume() async {
    final parsedDays =
        int.tryParse(_newListingDaysController.text) ?? newListingDays;
    final parsedTopN = int.tryParse(_topNController.text) ?? topN;
    final parsedWorkers = int.tryParse(_workersController.text) ?? workers;
    if (parsedDays <= 0) {
      setState(() {
        _status = '天数必须为正整数';
      });
      return;
    }
    if (parsedTopN <= 0 || parsedWorkers == null || parsedWorkers <= 0) {
      setState(() {
        _status = '参数不合法，请检查 topN、workers（>0）、天数（>0）';
      });
      return;
    }

    setState(() {
      _status =
          '扫描新币(${parsedDays}天, 按全时成交额排序, top=${parsedTopN}, workers=$parsedWorkers) ...';
    });
    try {
      final results = await fetchNewlyListedSymbolsByLifetimeVolume(
        days: parsedDays,
        topN: parsedTopN,
        workers: parsedWorkers,
        onProgress: (current, total) {
          if (mounted) {
            setState(() {
              _status =
                  '扫描新币(${parsedDays}天, 按全时成交额排序, top=${parsedTopN}) [$current/$total] ...';
            });
          }
        },
      );
      if (results.isEmpty) {
        setState(() {
          _status = '未发现最近 ${parsedDays} 天内的新币 (top ${parsedTopN})';
        });
        _log('未发现最近 ${parsedDays} 天内的新币 (top ${parsedTopN})');
        await showDialog<void>(
          context: context,
          builder: (context) {
            return AlertDialog(
              title: Text('最近 ${parsedDays} 天新币-全时成交额排序 (top ${parsedTopN})'),
              content: SizedBox(
                width: 320,
                child: Text('未发现最近 ${parsedDays} 天内的新币 (top ${parsedTopN})。'),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('确定'),
                ),
              ],
            );
          },
        );
        return;
      }

      setState(() {
        _status =
            '发现 ${results.length} 个最近 ${parsedDays} 天新币 (按全时成交额排序, top ${parsedTopN})';
      });
      _log(
        '发现 ${results.length} 个最近 ${parsedDays} 天新币 (按全时成交额排序, top ${parsedTopN})',
      );
      await _showNewListingsByLifetimeVolumeDialog(results);
    } catch (e) {
      setState(() {
        _status = '扫描新币(全时成交额)失败: $e';
      });
      _log('扫描新币(全时成交额)失败: $e');
    }
  }

  Future<void> _showNewListingsDialog(List<_NewListingResult> results) async {
    if (!mounted || results.isEmpty) return;

    await showDialog<void>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('最近上新的币种 (24h成交额排序)'),
          content: SizedBox(
            width: 360,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: results.map((r) {
                  final d = r.listedAt.toUtc();
                  final date =
                      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
                  return Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(text: '$date  '),
                        boldSymbolSpan(r.symbol),
                        TextSpan(
                          text: '  24h成交额=${formatVolume(r.quoteVolume)}',
                        ),
                      ],
                    ),
                  );
                }).toList(),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () async {
                await _startBrowseWithSymbols(results.map((r) => r.symbol));
              },
              child: const Text('开始顺序浏览'),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('确定'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _showListingRangeDialog(
    List<ListingVolumeResult> results,
  ) async {
    if (!mounted) return;

    await showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text('指定时间发行币种 (${results.length})'),

          content: SizedBox(
            width: 400,
            height: results.isEmpty ? null : 360,
            child: results.isEmpty
                ? const Text('该时间范围内没有符合条件的 USDT 永续合约')
                : ListView.builder(
                    shrinkWrap: results.length <= 8,
                    itemCount: results.length,
                    itemBuilder: (context, index) {
                      final r = results[index];
                      return Text.rich(
                        TextSpan(
                          children: [
                            boldSymbolSpan(r.symbol),
                            TextSpan(text: '  ${formatVolume(r.quoteVolume)}'),
                          ],
                        ),
                      );
                    },
                  ),
          ),

          actions: [
            TextButton(
              onPressed: () async {
                await _startBrowseWithSymbols(results.map((r) => r.symbol));
              },
              child: const Text('开始顺序浏览'),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('确定'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _scanPostDenseTrend() async {
    if (_postDenseTrendScanRunning) return;

    final parsedTopN = int.tryParse(_topNController.text);
    final parsedThreshold = double.tryParse(_thresholdController.text);
    final parsedKlinesLimit = int.tryParse(_klinesLimitController.text);
    final parsedWorkers = int.tryParse(_workersController.text);
    final parsedDays =
        int.tryParse(_newListingDaysController.text) ?? newListingDays;
    final parsedMinDays = _parsedMinListingDays();

    if (parsedTopN == null ||
        parsedTopN <= 0 ||
        parsedThreshold == null ||
        parsedThreshold <= 0 ||
        parsedKlinesLimit == null ||
        parsedKlinesLimit < 121 ||
        parsedWorkers == null ||
        parsedWorkers <= 0 ||
        parsedDays <= 0) {
      setState(() {
        _status =
            '参数不合法，请检查 topN、threshold、klinesLimit（>=121）、workers（>0）、天数≤（>0）';
      });
      return;
    }
    if (!_validateListingDaysRange(parsedDays, parsedMinDays)) return;

    topN = parsedTopN;
    threshold = parsedThreshold;
    klinesLimit = parsedKlinesLimit;
    workers = parsedWorkers;
    newListingDays = parsedDays;
    minListingDays = parsedMinDays;

    setState(() {
      _postDenseTrendScanRunning = true;
      _postDenseTrendResults.clear();
      _status =
          '扫描密集后上升趋势(周期 $interval, ${_listingDaysFilterLabel(parsedDays, parsedMinDays)}, topN=$parsedTopN) ...';
    });
    _log(
      '开始扫描密集后上升趋势: interval=$interval topN=$parsedTopN threshold=$parsedThreshold '
      'klinesLimit=$klinesLimit workers=$workers maxListingDays=$parsedDays minListingDays=$parsedMinDays',
    );

    try {
      final symbols = await fetchTopSymbolsByQuoteVolume(
        parsedTopN,
        maxListingDays: parsedDays,
        minListingDays: parsedMinDays,
      );

      if (symbols.isEmpty) {
        setState(() {
          _status = '未获取到任何 symbol';
        });
        _log('密集后上升趋势扫描：未获取到任何 symbol');
        return;
      }

      final matches = <PostDenseTrendResult>[];
      final total = symbols.length;
      var idx = 0;

      Future<PostDenseTrendResult?> worker(int localIdx, String symbol) async {
        try {
          final indicatorLimit = math.min(
            math.max(klinesLimit, _indicatorWarmupKlines),
            _binanceKlinesMaxLimit,
          );
          final bars = await fetchKlineBars(symbol, interval, indicatorLimit);
          if (bars.length < 122) {
            _log('[$localIdx/$total] $symbol 跳过(数据不足)');
            return null;
          }

          final trend = detectPostDenseTrend(bars, threshold: parsedThreshold);
          if (trend == null) {
            _log('[$localIdx/$total] $symbol 不满足密集后上升趋势');
            return null;
          }

          final result = PostDenseTrendResult.fromDetection(symbol, trend);
          _log(
            '[$localIdx/$total] $symbol 命中 '
            '${result.directionLabel} '
            '${result.timeRangeLabel} '
            '密集spread=${result.denseSpreadPct.toStringAsFixed(4)}% '
            '持续${trend.barsSinceDense}根 '
            '净变动=${result.netMovePct.toStringAsFixed(4)}% '
            '贴MA20=${result.alongMa20Pct.toStringAsFixed(1)}% '
            '均偏差=${result.avgMa20DevPct.toStringAsFixed(4)}%',
          );
          return result;
        } catch (e) {
          _log('[$localIdx/$total] $symbol 失败: $e');
          return null;
        }
      }

      var i = 0;
      while (i < total) {
        final end = (i + workers) > total ? total : (i + workers);
        final batch = symbols.sublist(i, end);
        final futures = <Future<PostDenseTrendResult?>>[];
        for (final symbol in batch) {
          idx += 1;
          futures.add(worker(idx, symbol));
        }
        final batchResults = await Future.wait(futures);
        for (final r in batchResults) {
          if (r != null) {
            matches.add(r);
          }
        }
        if (mounted) {
          setState(() {
            _status = '扫描密集后上升趋势 [$idx/$total]，已找到 ${matches.length} 个';
          });
        }
        i = end;
      }

      matches.sort((a, b) => b.netMovePct.abs().compareTo(a.netMovePct.abs()));

      if (!mounted) return;
      setState(() {
        _postDenseTrendResults.addAll(matches);
        _status =
            '密集后上升趋势扫描完成，共找到 ${matches.length} 个 (周期 $interval, ${_listingDaysFilterLabel(parsedDays, parsedMinDays)})';
      });
      _log('密集后上升趋势扫描完成，匹配数量: ${matches.length}');

      if (matches.isNotEmpty) {
        await _showPostDenseTrendDialog(matches);
      } else {
        await showDialog<void>(
          context: context,
          builder: (context) {
            return AlertDialog(
              title: Text(
                '密集后上升趋势 (周期 $interval, ${_listingDaysFilterLabel(parsedDays, parsedMinDays)})',
              ),
              content: const Text('未发现满足条件的币种。'),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('确定'),
                ),
              ],
            );
          },
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _status = '密集后上升趋势扫描失败: $e';
        });
      }
      _log('密集后上升趋势扫描失败: $e');
    } finally {
      if (mounted) {
        setState(() {
          _postDenseTrendScanRunning = false;
        });
      }
    }
  }

  Future<void> _backtestPostDenseTrend() async {
    if (_postDenseTrendBacktestRunning) return;

    final parsedTopN = int.tryParse(_topNController.text);
    final parsedThreshold = double.tryParse(_thresholdController.text);
    final parsedKlinesLimit = int.tryParse(_klinesLimitController.text);
    final parsedWorkers = int.tryParse(_workersController.text);
    final parsedDays =
        int.tryParse(_newListingDaysController.text) ?? newListingDays;
    final parsedMinDays = _parsedMinListingDays();

    if (parsedTopN == null ||
        parsedTopN <= 0 ||
        parsedThreshold == null ||
        parsedThreshold <= 0 ||
        parsedKlinesLimit == null ||
        parsedKlinesLimit < 121 ||
        parsedWorkers == null ||
        parsedWorkers <= 0 ||
        parsedDays <= 0) {
      setState(() {
        _status =
            '参数不合法，请检查 topN、threshold、klinesLimit（>=121）、workers（>0）、天数≤（>0）';
      });
      return;
    }
    if (!_validateListingDaysRange(parsedDays, parsedMinDays)) return;

    topN = parsedTopN;
    threshold = parsedThreshold;
    klinesLimit = parsedKlinesLimit;
    workers = parsedWorkers;
    newListingDays = parsedDays;
    minListingDays = parsedMinDays;

    setState(() {
      _postDenseTrendBacktestRunning = true;
      _postDenseTrendBacktestResults.clear();
      _status =
          '回测密集后上升趋势(周期 $interval, ${_listingDaysFilterLabel(parsedDays, parsedMinDays)}, topN=$parsedTopN) ...';
    });
    _log(
      '开始回测密集后上升趋势: interval=$interval topN=$parsedTopN threshold=$parsedThreshold '
      'klinesLimit=$klinesLimit workers=$workers maxListingDays=$parsedDays minListingDays=$parsedMinDays',
    );

    try {
      final symbols = await fetchTopSymbolsByQuoteVolume(
        parsedTopN,
        maxListingDays: parsedDays,
        minListingDays: parsedMinDays,
      );

      if (symbols.isEmpty) {
        setState(() {
          _status = '回测：未获取到任何 symbol';
        });
        return;
      }

      final matches = <PostDenseTrendResult>[];
      final total = symbols.length;
      var idx = 0;

      Future<List<PostDenseTrendResult>> worker(
        int localIdx,
        String symbol,
      ) async {
        try {
          final indicatorLimit = math.min(
            math.max(klinesLimit, _indicatorWarmupKlines),
            _binanceKlinesMaxLimit,
          );
          final bars = await fetchKlineBars(symbol, interval, indicatorLimit);
          if (bars.length < 122) {
            return const [];
          }

          final segments = backtestPostDenseTrendAllSegments(
            bars,
            threshold: parsedThreshold,
          );
          if (segments.isEmpty) {
            return const [];
          }

          _log('[$localIdx/$total] $symbol 回测命中 ${segments.length} 段');
          return segments
              .map((s) => PostDenseTrendResult.fromDetection(symbol, s))
              .toList(growable: false);
        } catch (e) {
          _log('[$localIdx/$total] $symbol 回测失败: $e');
          return const [];
        }
      }

      var i = 0;
      while (i < total) {
        final end = (i + workers) > total ? total : (i + workers);
        final batch = symbols.sublist(i, end);
        final futures = <Future<List<PostDenseTrendResult>>>[];
        for (final symbol in batch) {
          idx += 1;
          futures.add(worker(idx, symbol));
        }
        final batchResults = await Future.wait(futures);
        for (final list in batchResults) {
          matches.addAll(list);
        }
        if (mounted) {
          setState(() {
            _status = '回测密集后上升趋势 [$idx/$total]，已找到 ${matches.length} 段';
          });
        }
        i = end;
      }

      matches.sort((a, b) {
        final bySymbol = a.symbol.compareTo(b.symbol);
        if (bySymbol != 0) return bySymbol;
        return a.startTimeUtc.compareTo(b.startTimeUtc);
      });

      if (!mounted) return;
      setState(() {
        _postDenseTrendBacktestResults.addAll(matches);
        _status =
            '回测完成，共 ${matches.length} 段 (周期 $interval, ${_listingDaysFilterLabel(parsedDays, parsedMinDays)})';
      });
      _log('回测密集后上升趋势完成，段数: ${matches.length}');

      if (matches.isNotEmpty) {
        await _showPostDenseTrendBacktestDialog(matches);
      } else {
        await showDialog<void>(
          context: context,
          builder: (context) {
            return AlertDialog(
              title: Text(
                '回测密集后上升趋势 (周期 $interval, ${_listingDaysFilterLabel(parsedDays, parsedMinDays)})',
              ),
              content: const Text('未发现符合模型的历史时间段。'),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('确定'),
                ),
              ],
            );
          },
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _status = '回测密集后上升趋势失败: $e';
        });
      }
      _log('回测密集后上升趋势失败: $e');
    } finally {
      if (mounted) {
        setState(() {
          _postDenseTrendBacktestRunning = false;
        });
      }
    }
  }

  Future<void> _showPostDenseTrendDialog(
    List<PostDenseTrendResult> results,
  ) async {
    if (!mounted || results.isEmpty) return;

    final upResults = _sortedTrendResults(results, 'up');

    Widget buildResultRow(PostDenseTrendResult m) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text.rich(
          TextSpan(
            children: [
              boldSymbolSpan(m.symbol),
              TextSpan(
                text:
                    '  ${m.crossVoteLabel}\n'
                    '${m.timeRangeLabel}\n'
                    '密集=${m.denseSpreadPct.toStringAsFixed(4)}%  '
                    '持续${m.barsSinceDense}根  '
                    '净变动=${m.netMovePct.toStringAsFixed(4)}%  '
                    '贴MA20=${m.alongMa20Pct.toStringAsFixed(1)}%  '
                    '均偏差=${m.avgMa20DevPct.toStringAsFixed(4)}%',
              ),
            ],
          ),
        ),
      );
    }

    Widget buildSection(String title, List<PostDenseTrendResult> section) {
      if (section.isEmpty) return const SizedBox.shrink();
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          ...section.map(buildResultRow),
          const SizedBox(height: 12),
        ],
      );
    }

    await showDialog<void>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text('密集后上升趋势 (周期 $interval, 共 ${results.length} 个)'),
          content: SizedBox(
            width: 360,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  buildSection('— ↑ 上涨 (${upResults.length}) —', upResults),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () async {
                await _startBrowseWithSymbols(results.map((m) => m.symbol));
              },
              child: const Text('开始顺序浏览'),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('确定'),
            ),
          ],
        );
      },
    );
  }

  List<PostDenseTrendResult> _sortedTrendResults(
    List<PostDenseTrendResult> results,
    String direction,
  ) {
    return results.where((r) => r.direction == direction).toList()
      ..sort((a, b) => b.netMovePct.abs().compareTo(a.netMovePct.abs()));
  }

  Widget _postDenseTrendListTile(
    PostDenseTrendResult t, {
    bool backtest = false,
  }) {
    final alongLabel = backtest ? '贴MA/EMA20' : '贴MA20';
    return ListTile(
      title: symbolBoldText(t.symbol, '  (${t.crossVoteLabel}, $interval)'),
      subtitle: Text(
        '${t.timeRangeLabel}\n'
        '密集=${t.denseSpreadPct.toStringAsFixed(4)}%  '
        '持续${t.barsSinceDense}根  '
        '净变动=${t.netMovePct.toStringAsFixed(4)}%  '
        '$alongLabel=${t.alongMa20Pct.toStringAsFixed(1)}%  '
        '均偏差=${t.avgMa20DevPct.toStringAsFixed(4)}%',
      ),
    );
  }

  Future<void> _showPostDenseTrendBacktestDialog(
    List<PostDenseTrendResult> results,
  ) async {
    if (!mounted || results.isEmpty) return;

    final upResults = _sortedTrendResults(results, 'up');

    Widget buildResultRow(PostDenseTrendResult m) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text.rich(
          TextSpan(
            children: [
              boldSymbolSpan(m.symbol),
              TextSpan(
                text:
                    '  ${m.crossVoteLabel}\n'
                    '${m.timeRangeLabel}\n'
                    '密集=${m.denseSpreadPct.toStringAsFixed(4)}%  '
                    '持续${m.barsSinceDense}根  '
                    '净变动=${m.netMovePct.toStringAsFixed(4)}%  '
                    '贴MA/EMA20=${m.alongMa20Pct.toStringAsFixed(1)}%  '
                    '均偏差=${m.avgMa20DevPct.toStringAsFixed(4)}%',
              ),
            ],
          ),
        ),
      );
    }

    Widget buildSection(String title, List<PostDenseTrendResult> section) {
      if (section.isEmpty) return const SizedBox.shrink();
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          ...section.map(buildResultRow),
          const SizedBox(height: 12),
        ],
      );
    }

    await showDialog<void>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text('回测密集后上升趋势 (周期 $interval, 共 ${results.length} 段)'),
          content: SizedBox(
            width: 400,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '回测逻辑：密集区金叉 → 沿 MA20+EMA20 上升；'
                    '趋势 >10 根后破势则截段（含破势前最后一根）。',
                    style: TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                  const SizedBox(height: 12),
                  buildSection('— ↑ 上涨 (${upResults.length}) —', upResults),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () async {
                await _startBrowseWithSymbols(results.map((m) => m.symbol));
              },
              child: const Text('开始顺序浏览'),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('确定'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _showNewListingsByLifetimeVolumeDialog(
    List<_NewListingResult> results,
  ) async {
    if (!mounted || results.isEmpty) return;

    await showDialog<void>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('最近上新的币种 (全时成交额排序)'),
          content: SizedBox(
            width: 360,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: results.map((r) {
                  final d = r.listedAt.toUtc();
                  final date =
                      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
                  return Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(text: '$date  '),
                        boldSymbolSpan(r.symbol),
                        TextSpan(
                          text: '  全时成交额=${formatVolume(r.quoteVolume)}',
                        ),
                      ],
                    ),
                  );
                }).toList(),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () async {
                await _startBrowseWithSymbols(results.map((r) => r.symbol));
              },
              child: const Text('开始顺序浏览'),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('确定'),
            ),
          ],
        );
      },
    );
  }

  Duration? _intervalToDuration(String value) {
    final match = RegExp(r'^(\d+)([mhdw])$').firstMatch(value);
    if (match == null) return null;

    final amount = int.tryParse(match.group(1) ?? '');
    final unit = match.group(2);
    if (amount == null || amount <= 0 || unit == null) return null;

    switch (unit) {
      case 'm':
        return Duration(minutes: amount);
      case 'h':
        return Duration(hours: amount);
      case 'd':
        return Duration(days: amount);
      case 'w':
        return Duration(days: amount * 7);
      default:
        return null;
    }
  }

  DateTime _nextBoundaryUtc(DateTime nowUtc, Duration interval) {
    final intervalMs = interval.inMilliseconds;
    final nowMs = nowUtc.millisecondsSinceEpoch;
    final nextMs = ((nowMs ~/ intervalMs) + 1) * intervalMs;
    return DateTime.fromMillisecondsSinceEpoch(nextMs, isUtc: true);
  }

  Future<DateTime> _getExchangeNowUtc() async {
    try {
      final data =
          await httpGetJson('https://fapi.binance.com/fapi/v1/time') as dynamic;
      if (data is Map<String, dynamic>) {
        final serverTimeMs = data['serverTime'];
        if (serverTimeMs is int) {
          return DateTime.fromMillisecondsSinceEpoch(serverTimeMs, isUtc: true);
        }
        if (serverTimeMs is String) {
          final parsed = int.tryParse(serverTimeMs);
          if (parsed != null) {
            return DateTime.fromMillisecondsSinceEpoch(parsed, isUtc: true);
          }
        }
      }
    } catch (e) {
      _log('获取 Binance 服务器时间失败，回退本地时间: $e');
    }
    return DateTime.now().toUtc();
  }

  Future<void> _waitUntilNextKlineClose(_ScanTask task) async {
    final intervalDuration = _intervalToDuration(task.interval);
    if (intervalDuration == null) {
      _log('任务 #${task.id} 周期 ${task.interval} 无法解析，使用兜底等待 5 秒');
      await Future.delayed(_fallbackContinuousDelay);
      return;
    }

    final nowUtc = await _getExchangeNowUtc();
    final nextCloseUtc = _nextBoundaryUtc(nowUtc, intervalDuration);
    var remaining = nextCloseUtc.difference(nowUtc) + _scanAlignSafetyBuffer;
    if (remaining <= Duration.zero) {
      remaining = const Duration(milliseconds: 500);
    }

    _log(
      '任务 #${task.id} 等待至下一根 ${task.interval} K线收线后再扫描（约 ${remaining.inSeconds}s）',
    );

    const tick = Duration(seconds: 1);
    while (!task.cancelRequested && remaining > Duration.zero) {
      final step = remaining > tick ? tick : remaining;
      await Future.delayed(step);
      remaining -= step;
    }
  }

  Future<void> _runScanForTask(_ScanTask task) async {
    if (task.isRunning) return;

    final parsedTopN = int.tryParse(_topNController.text);
    final parsedKlinesLimit = int.tryParse(_klinesLimitController.text);
    final parsedWorkers = int.tryParse(_workersController.text);

    if (parsedTopN == null ||
        parsedTopN <= 0 ||
        parsedKlinesLimit == null ||
        parsedKlinesLimit < 121 ||
        parsedWorkers == null ||
        parsedWorkers <= 0) {
      setState(() {
        _status = '参数不合法，请检查 topN、threshold、klinesLimit（>=121）、workers（>0）';
        task.status = '参数不合法，无法启动任务';
      });
      _log(
        '任务 #${task.id} 参数不合法: topN=$parsedTopN klinesLimit=$parsedKlinesLimit workers=$parsedWorkers',
      );
      return;
    }

    topN = parsedTopN;
    klinesLimit = parsedKlinesLimit;
    workers = parsedWorkers;

    final taskThreshold = task.threshold;

    setState(() {
      task.isRunning = true;
      task.cancelRequested = false;
      task.status = '开始扫描...';
      task.matches.clear();
      task.lastMatchedSymbols.clear();
      _status = '任务 #${task.id} (周期 ${task.interval}) 开始扫描';
    });
    _log(
      '任务 #${task.id} 开始扫描: interval=${task.interval} topN=$topN threshold=$taskThreshold klinesLimit=$klinesLimit workers=$workers 持续=${task.continuous}',
    );

    try {
      while (true) {
        if (!mounted || task.cancelRequested) {
          _log('检测到任务 #${task.id} 终止标志，结束扫描循环');
          break;
        }

        _log('任务 #${task.id} 开始新一轮扫描');
        final parsedListingDays =
            int.tryParse(_newListingDaysController.text) ?? newListingDays;
        final parsedMinListingDays = _parsedMinListingDays();
        final symbols = await fetchTopSymbolsByQuoteVolume(
          topN,
          maxListingDays: parsedListingDays,
          minListingDays: parsedMinListingDays,
        );
        if (symbols.isEmpty) {
          setState(() {
            task.status = '未获取到任何 symbol';
            _status = '任务 #${task.id} (周期 ${task.interval}) 未获取到任何 symbol';
          });
          _log('任务 #${task.id} 未获取到任何 symbol');

          if (!task.continuous) {
            break;
          }

          await _waitUntilNextKlineClose(task);
          continue;
        }

        final matches = <MatchResult>[];
        final total = symbols.length;
        int idx = 0;

        Future<MatchResult?> worker(int localIdx, String symbol) async {
          if (task.cancelRequested) {
            return null;
          }
          try {
            final indicatorLimit = math.min(
              math.max(klinesLimit, _indicatorWarmupKlines),
              _binanceKlinesMaxLimit,
            );
            _log(
              '任务 #${task.id} [$localIdx/$total] $symbol 使用K线数量=$indicatorLimit (UI klinesLimit=$klinesLimit)',
            );
            final closes = await fetchKlines(
              symbol,
              task.interval,
              indicatorLimit,
            );
            final List<double> closedCloses = closes.length > 1
                ? closes.sublist(0, closes.length - 1)
                : [];

            if (closedCloses.length < 120) {
              if (!mounted) return null;
              setState(() {
                task.status = '[$localIdx/$total] $symbol 跳过(数据不足)';
                _status =
                    '任务 #${task.id} (周期 ${task.interval}) $symbol 跳过(数据不足) [$localIdx/$total]';
              });
              _log('任务 #${task.id} [$localIdx/$total] $symbol 跳过(数据不足)');
              return null;
            }

            final ema20 = ema(closedCloses, 20);
            final ema60 = ema(closedCloses, 60);
            final ema120 = ema(closedCloses, 120);
            final ma20 = ma(closedCloses, 20);
            final ma60 = ma(closedCloses, 60);
            final ma120 = ma(closedCloses, 120);

            if (ema20 == null ||
                ema60 == null ||
                ema120 == null ||
                ma20 == null ||
                ma60 == null ||
                ma120 == null) {
              if (!mounted) return null;
              setState(() {
                task.status = '[$localIdx/$total] $symbol 跳过(均线计算失败)';
                _status =
                    '任务 #${task.id} (周期 ${task.interval}) $symbol 跳过(均线计算失败) [$localIdx/$total]';
              });
              _log('任务 #${task.id} [$localIdx/$total] $symbol 跳过(均线计算失败)');
              return null;
            }

            final result = isDense6([
              ema20,
              ema60,
              ema120,
              ma20,
              ma60,
              ma120,
            ], taskThreshold);
            final spreadPct = result.spread * 100.0;
            final lines = <double>[ema20, ema60, ema120, ma20, ma60, ma120];
            final mn = lines.reduce(math.min);
            final mx = lines.reduce(math.max);
            _log(
              '任务 #${task.id} [$localIdx/$total] $symbol 明细 '
              'EMA20=${ema20.toStringAsFixed(6)} '
              'EMA60=${ema60.toStringAsFixed(6)} '
              'EMA120=${ema120.toStringAsFixed(6)} '
              'MA20=${ma20.toStringAsFixed(6)} '
              'MA60=${ma60.toStringAsFixed(6)} '
              'MA120=${ma120.toStringAsFixed(6)} '
              'min=${mn.toStringAsFixed(6)} '
              'max=${mx.toStringAsFixed(6)} '
              'spread=${spreadPct.toStringAsFixed(4)}% '
              'threshold=${(taskThreshold * 100).toStringAsFixed(4)}% '
              'ok=${result.ok}',
            );

            if (result.ok) {
              final m = MatchResult(symbol: symbol, spreadPct: spreadPct);
              if (!mounted) return m;
              if (task.cancelRequested) return null;
              setState(() {
                task.status =
                    '[$localIdx/$total] $symbol 发现 EMA+MA 密集 spread=${spreadPct.toStringAsFixed(4)}%';
                _status =
                    '任务 #${task.id} (周期 ${task.interval}) $symbol 发现 EMA+MA 密集 spread=${spreadPct.toStringAsFixed(4)}% [$localIdx/$total]';
                task.matches = [...task.matches, m];
              });
              _log(
                '任务 #${task.id} [$localIdx/$total] $symbol 发现 EMA+MA 密集 spread=${spreadPct.toStringAsFixed(4)}%',
              );
              return m;
            } else {
              if (!mounted) return null;
              if (task.cancelRequested) return null;
              setState(() {
                task.status =
                    '[$localIdx/$total] $symbol 不满足 EMA+MA 密集 spread=${spreadPct.toStringAsFixed(4)}%';
                _status =
                    '任务 #${task.id} (周期 ${task.interval}) $symbol 不满足 EMA+MA 密集 spread=${spreadPct.toStringAsFixed(4)}% [$localIdx/$total]';
              });
              _log(
                '任务 #${task.id} [$localIdx/$total] $symbol 不满足 EMA+MA 密集 spread=${spreadPct.toStringAsFixed(4)}%',
              );
              return null;
            }
          } catch (e) {
            if (!mounted) return null;
            if (task.cancelRequested) return null;
            setState(() {
              task.status = '[$localIdx/$total] $symbol 失败($e)';
              _status =
                  '任务 #${task.id} (周期 ${task.interval}) $symbol 失败($e) [$localIdx/$total]';
            });
            _log('任务 #${task.id} [$localIdx/$total] $symbol 失败: $e');
            return null;
          }
        }

        var i = 0;
        final batchSize = workers;
        while (i < total) {
          if (task.cancelRequested) {
            break;
          }
          final end = (i + batchSize) > total ? total : (i + batchSize);
          final batch = symbols.sublist(i, end);
          final futures = <Future<MatchResult?>>[];
          for (final symbol in batch) {
            idx += 1;
            futures.add(worker(idx, symbol));
          }
          final results = await Future.wait(futures);
          for (final r in results) {
            if (r != null) {
              matches.add(r);
            }
          }
          i = end;
        }

        if (task.cancelRequested) {
          setState(() {
            task.status = '扫描已终止，当前匹配数量: ${matches.length}';
            _status =
                '任务 #${task.id} (周期 ${task.interval}) 扫描已终止，当前匹配数量: ${matches.length}';
          });
          _log('任务 #${task.id} 扫描被终止，匹配数量: ${matches.length}');
          break;
        }

        // 本轮匹配的 symbol 集合，用于判断哪些是“本轮新加入队伍”的币种。
        final currentSymbols = matches.map((m) => m.symbol).toSet();
        // 与上一轮相比，新进入“符合条件队伍”的币种。
        final newSymbols = currentSymbols.difference(task.lastMatchedSymbols);

        setState(() {
          if (matches.isEmpty) {
            task.status = task.continuous
                ? '本轮扫描完成，没有任何币种满足阈值条件（持续扫描已开启）。'
                : '扫描完成，没有任何币种满足阈值条件。';
          } else {
            task.status = task.continuous
                ? '本轮扫描完成，共找到 ${matches.length} 个匹配币种（持续扫描已开启）。'
                : '扫描完成，共找到 ${matches.length} 个匹配币种。';
          }
          _status = '任务 #${task.id} (周期 ${task.interval}) ${task.status}';
          // 用本轮匹配结果覆盖任务的匹配列表，移除本轮不再符合的币种。
          task.matches = List<MatchResult>.from(matches);
        });
        _log('任务 #${task.id} 本轮扫描完成，匹配数量: ${matches.length}');

        // 只对“本轮新进入符合条件队伍”的币种提醒；
        // 对于中途消失又在本轮重新出现的币种，会再次被视为新成员并提醒。
        final toNotify = matches
            .where((m) => newSymbols.contains(m.symbol))
            .toList(growable: false);

        // 记录本轮的符合条件队伍，用于下一轮对比；
        // 没有在本轮中出现的币种会从集合中移除，
        // 以后若再次出现，将再次被视为“新出现”，重新提醒。
        task.lastMatchedSymbols = currentSymbols;
        if (toNotify.isNotEmpty) {
          await _notifyForTaskMatches(task, toNotify);
        }

        if (!task.continuous) {
          break;
        }

        if (task.cancelRequested) {
          break;
        }

        _log('任务 #${task.id} 持续扫描已开启，等待当前未走完 K线收线...');
        await _waitUntilNextKlineClose(task);
      }
    } catch (e) {
      setState(() {
        task.status = '扫描失败: $e';
        _status = '任务 #${task.id} (周期 ${task.interval}) 扫描失败: $e';
      });
      _log('任务 #${task.id} 扫描失败: $e');
    } finally {
      setState(() {
        task.isRunning = false;
      });
    }
  }

  Future<void> _scanStableSymbols() async {
    if (_stableScanRunning) return;

    final parsedTopN = int.tryParse(_topNController.text);
    final parsedWorkers = int.tryParse(_workersController.text);
    final parsedDays =
        int.tryParse(_newListingDaysController.text) ?? newListingDays;
    final parsedMinDays = _parsedMinListingDays();

    if (parsedTopN == null ||
        parsedTopN <= 0 ||
        parsedWorkers == null ||
        parsedWorkers <= 0 ||
        parsedDays <= 0) {
      setState(() {
        _status = '参数不合法，请检查 topN、workers（>0）、天数≤（>0）';
      });
      return;
    }
    if (!_validateListingDaysRange(parsedDays, parsedMinDays)) return;

    topN = parsedTopN;
    workers = parsedWorkers;
    newListingDays = parsedDays;
    minListingDays = parsedMinDays;

    setState(() {
      _stableScanRunning = true;
      _stableSymbolResults.clear();
      _status =
          '扫描稳定币种(${_listingDaysFilterLabel(parsedDays, parsedMinDays)}, topN=$parsedTopN, 波动<${stableMaxRangeMultiple.toInt()}倍) ...';
    });
    _log(
      '开始扫描稳定币种: topN=$parsedTopN maxListingDays=$parsedDays '
      'minListingDays=$parsedMinDays workers=$workers maxRangeMultiple=$stableMaxRangeMultiple',
    );

    try {
      final listingTimes = await fetchUsdtPerpListingTimesMs();
      final symbols = await fetchTopSymbolsByQuoteVolume(
        parsedTopN,
        maxListingDays: parsedDays,
        minListingDays: parsedMinDays,
      );

      if (symbols.isEmpty) {
        setState(() {
          _status = '稳定币种扫描：未获取到任何 symbol';
        });
        return;
      }

      final tickers = await fetchBinanceTicker24hr() as dynamic;
      final vol24h = <String, double>{};
      if (tickers is List) {
        for (final t in tickers) {
          if (t is! Map<String, dynamic>) continue;
          final sym = (t['symbol'] ?? '').toString();
          vol24h[sym] =
              double.tryParse((t['quoteVolume'] ?? '0').toString()) ?? 0.0;
        }
      }

      final stable = <StableSymbolResult>[];
      final total = symbols.length;
      var idx = 0;

      Future<StableSymbolResult?> worker(int localIdx, String symbol) async {
        try {
          final listedAtMs = listingTimes[symbol];
          if (listedAtMs == null) {
            _log('[$localIdx/$total] $symbol 跳过(无上市时间)');
            return null;
          }

          final range = await fetchLifetimePriceRange(symbol, listedAtMs);
          if (range == null) {
            _log('[$localIdx/$total] $symbol 跳过(价格区间数据不足)');
            return null;
          }

          if (!range.isStable(maxMultiple: stableMaxRangeMultiple)) {
            _log(
              '[$localIdx/$total] $symbol 非稳定 '
              '低点=${range.minLow} 高点=${range.maxHigh} '
              '倍数=${range.rangeMultiple.toStringAsFixed(2)}',
            );
            return null;
          }

          final result = StableSymbolResult(
            symbol: symbol,
            listedAt: DateTime.fromMillisecondsSinceEpoch(
              listedAtMs,
              isUtc: true,
            ),
            minLow: range.minLow,
            maxHigh: range.maxHigh,
            rangeMultiple: range.rangeMultiple,
            quoteVolume24h: vol24h[symbol] ?? 0.0,
            dailyBarsUsed: range.barCount,
          );
          _log(
            '[$localIdx/$total] $symbol 稳定 '
            '倍数=${result.rangeMultiple.toStringAsFixed(2)} '
            '24h额=${formatVolume(result.quoteVolume24h)}',
          );
          return result;
        } catch (e) {
          _log('[$localIdx/$total] $symbol 稳定扫描失败: $e');
          return null;
        }
      }

      var i = 0;
      while (i < total) {
        final end = (i + workers) > total ? total : (i + workers);
        final batch = symbols.sublist(i, end);
        final futures = <Future<StableSymbolResult?>>[];
        for (final symbol in batch) {
          idx += 1;
          futures.add(worker(idx, symbol));
        }
        final batchResults = await Future.wait(futures);
        for (final r in batchResults) {
          if (r != null) stable.add(r);
        }
        if (mounted) {
          setState(() {
            _status =
                '扫描稳定币种 [$idx/$total]，已找到 ${stable.length} 个 (波动<${stableMaxRangeMultiple.toInt()}倍)';
          });
        }
        i = end;
      }

      stable.sort((a, b) {
        final byRange = a.rangeMultiple.compareTo(b.rangeMultiple);
        if (byRange != 0) return byRange;
        return b.quoteVolume24h.compareTo(a.quoteVolume24h);
      });

      if (!mounted) return;
      setState(() {
        _stableSymbolResults.addAll(stable);
        _status =
            '稳定币种扫描完成，共 ${stable.length}/${total} 个 (${_listingDaysFilterLabel(parsedDays, parsedMinDays)}, topN=$parsedTopN)';
      });
      _log('稳定币种扫描完成，匹配 ${stable.length}/${total}');

      if (stable.isNotEmpty) {
        await _showStableSymbolsDialog(
          stable,
          parsedDays,
          parsedMinDays,
          parsedTopN,
        );
      } else {
        await showDialog<void>(
          context: context,
          builder: (context) {
            return AlertDialog(
              title: Text(
                '稳定币种 (${_listingDaysFilterLabel(parsedDays, parsedMinDays)}, top $parsedTopN)',
              ),
              content: Text(
                '在 ${total} 个候选中，未发现自上市以来高低点倍数低于 '
                '${stableMaxRangeMultiple.toInt()} 倍的币种。',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('确定'),
                ),
              ],
            );
          },
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _status = '稳定币种扫描失败: $e';
        });
      }
      _log('稳定币种扫描失败: $e');
    } finally {
      if (mounted) {
        setState(() {
          _stableScanRunning = false;
        });
      }
    }
  }

  Future<void> _showStableSymbolsDialog(
    List<StableSymbolResult> results,
    int maxListingDays,
    int minListingDays,
    int topN,
  ) async {
    if (!mounted || results.isEmpty) return;

    await showDialog<void>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(
            '稳定币种 (${_listingDaysFilterLabel(maxListingDays, minListingDays)}, top $topN, 共 ${results.length} 个)',
          ),
          content: SizedBox(
            width: 400,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '稳定定义：自上市以来日线最低价→最高价倍数 < '
                    '${stableMaxRangeMultiple.toInt()}（无百倍级单边波动）。',
                    style: const TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                  const SizedBox(height: 12),
                  ...results.map((r) {
                    final d = r.listedAt.toUtc();
                    final date =
                        '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text.rich(
                        TextSpan(
                          children: [
                            boldSymbolSpan(r.symbol),
                            TextSpan(
                              text:
                                  '  $date\n'
                                  '低点→高点=${r.rangeMultiple.toStringAsFixed(2)}倍  '
                                  '低=${r.minLow.toStringAsFixed(6)}  '
                                  '高=${r.maxHigh.toStringAsFixed(6)}  '
                                  '24h额=${formatVolume(r.quoteVolume24h)}',
                            ),
                          ],
                        ),
                      ),
                    );
                  }),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('确定'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _searchListings() async {
    if (listingStartDate == null || listingEndDate == null) {
      setState(() {
        _status = '请先选择起始日期和终止日期';
      });
      return;
    }
    if (listingStartDate!.isAfter(listingEndDate!)) {
      setState(() {
        _status = '起始日期不能晚于终止日期';
      });
      return;
    }

    setState(() {
      listingSearchRunning = true;
      _status = '查询发行币种中...';
    });

    try {
      final result = await fetchSymbolsListedBetweenDates(
        startDate: listingStartDate!,
        endDate: listingEndDate!,
      );

      if (!mounted) return;
      setState(() {
        listingResults = result;
        _status = '查询完成，共 ${result.length} 个币种';
      });
      await _showListingRangeDialog(result);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _status = '查询发行币种失败: $e';
      });
      _log('查询发行币种失败: $e');
    } finally {
      if (mounted) {
        setState(() {
          listingSearchRunning = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    const double taskPanelHeight = 300;
    const double resultPanelHeight = 720;

    return Scaffold(
      appBar: AppBar(
        title: const Text('PerpScope'),
      ),
      body: LayoutBuilder(
          builder: (context, constraints) {
            return SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  minHeight: constraints.maxHeight - 32,
                ),
                child: Column(
                  children: [
                  Card(
                    elevation: 2,
                    child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              const Text('周期:'),
                              const SizedBox(width: 8),
                              DropdownButton<String>(
                                value: interval,
                                items: const [
                                  DropdownMenuItem(
                                    value: '3m',
                                    child: Text('3m'),
                                  ),
                                  DropdownMenuItem(
                                    value: '15m',
                                    child: Text('15m'),
                                  ),
                                  DropdownMenuItem(
                                    value: '1h',
                                    child: Text('1h'),
                                  ),
                                  DropdownMenuItem(
                                    value: '4h',
                                    child: Text('4h'),
                                  ),
                                  DropdownMenuItem(
                                    value: '1d',
                                    child: Text('1d'),
                                  ),
                                ],
                                onChanged: (v) {
                                  if (v == null) return;
                                  setState(() {
                                    interval = v;
                                  });
                                },
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              Flexible(
                                child: TextField(
                                  controller: _topNController,
                                  keyboardType:
                                      const TextInputType.numberWithOptions(
                                        decimal: false,
                                      ),
                                  decoration: const InputDecoration(
                                    labelText: 'topN',
                                    hintText: '例如 100',
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Flexible(
                                child: TextField(
                                  controller: _thresholdController,
                                  keyboardType:
                                      const TextInputType.numberWithOptions(
                                        decimal: true,
                                      ),
                                  decoration: const InputDecoration(
                                    labelText: 'threshold',
                                    hintText: '例如 0.2',
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              Flexible(
                                child: TextField(
                                  controller: _klinesLimitController,
                                  keyboardType:
                                      const TextInputType.numberWithOptions(
                                        decimal: false,
                                      ),
                                  decoration: const InputDecoration(
                                    labelText: 'klinesLimit',
                                    hintText: '例如 1500 (>=121)',
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Flexible(
                                child: TextField(
                                  controller: _workersController,
                                  keyboardType:
                                      const TextInputType.numberWithOptions(
                                        decimal: false,
                                      ),
                                  decoration: const InputDecoration(
                                    labelText: 'workers',
                                    hintText: '并发数，例如 8',
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              Flexible(
                                child: TextField(
                                  controller: _newListingDaysController,
                                  keyboardType:
                                      const TextInputType.numberWithOptions(
                                        decimal: false,
                                      ),
                                  decoration: const InputDecoration(
                                    labelText: '天数≤',
                                    hintText: '上市不超过，例如 550',
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Flexible(
                                child: TextField(
                                  controller: _minListingDaysController,
                                  keyboardType:
                                      const TextInputType.numberWithOptions(
                                        decimal: false,
                                      ),
                                  decoration: const InputDecoration(
                                    labelText: '天数>',
                                    hintText: '发行天数大于，0=不限',
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              ElevatedButton(
                                onPressed: _addTask,
                                child: const Text('添加任务'),
                              ),
                              const SizedBox(width: 8),
                              OutlinedButton(
                                onPressed: _clearResults,
                                child: const Text('清空结果'),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              Flexible(
                                fit: FlexFit.loose,
                                child: OutlinedButton(
                                  onPressed: _scanNewListings,
                                  child: const Text('扫描新币(24h成交额排序)'),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              Flexible(
                                fit: FlexFit.loose,
                                child: OutlinedButton(
                                  onPressed: _scanNewListingsByLifetimeVolume,
                                  child: const Text('扫描新币(全时成交额排序)'),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              Flexible(
                                fit: FlexFit.loose,
                                child: OutlinedButton(
                                  onPressed:
                                      _stableScanRunning ? null : _scanStableSymbols,
                                  child: Text(
                                    _stableScanRunning
                                        ? '扫描稳定币种...'
                                        : '扫描稳定币种(<100倍波动)',
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),

                          Row(
                            children: [
                              ElevatedButton(
                                onPressed: () async {
                                  final d = await showDatePicker(
                                    context: context,
                                    firstDate: DateTime(2020),
                                    lastDate: DateTime.now(),
                                    initialDate:
                                        listingStartDate ?? DateTime.now(),
                                  );

                                  if (d != null) {
                                    setState(() {
                                      listingStartDate = d;
                                    });
                                  }
                                },
                                child: Text(
                                  listingStartDate == null
                                      ? '起始日期'
                                      : listingStartDate!
                                            .toString()
                                            .split(' ')
                                            .first,
                                ),
                              ),

                              const SizedBox(width: 10),

                              ElevatedButton(
                                onPressed: () async {
                                  final d = await showDatePicker(
                                    context: context,
                                    firstDate: DateTime(2020),
                                    lastDate: DateTime.now(),
                                    initialDate:
                                        listingEndDate ?? DateTime.now(),
                                  );

                                  if (d != null) {
                                    setState(() {
                                      listingEndDate = d;
                                    });
                                  }
                                },
                                child: Text(
                                  listingEndDate == null
                                      ? '终止日期'
                                      : listingEndDate!
                                            .toString()
                                            .split(' ')
                                            .first,
                                ),
                              ),

                              const SizedBox(width: 10),

                              ElevatedButton(
                                onPressed: listingSearchRunning
                                    ? null
                                    : _searchListings,
                                child: const Text('查询发行币种'),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              Flexible(
                                fit: FlexFit.loose,
                                child: ElevatedButton(
                                  onPressed:
                                      _postDenseTrendScanRunning ||
                                          _postDenseTrendBacktestRunning
                                      ? null
                                      : _scanPostDenseTrend,
                                  child: Text(
                                    _postDenseTrendScanRunning
                                        ? '扫描密集后上升趋势...'
                                        : '扫描密集后上升趋势',
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              Flexible(
                                fit: FlexFit.loose,
                                child: OutlinedButton(
                                  onPressed:
                                      _postDenseTrendBacktestRunning ||
                                          _postDenseTrendScanRunning
                                      ? null
                                      : _backtestPostDenseTrend,
                                  child: Text(
                                    _postDenseTrendBacktestRunning
                                        ? '回测密集后上升趋势...'
                                        : '回测密集后上升趋势',
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Checkbox(
                                    value: scanOnlyNew,
                                    onChanged: (v) {
                                      if (v == null) return;
                                      setState(() {
                                        scanOnlyNew = v;
                                      });
                                    },
                                  ),
                                  const Text('仅在新币中扫描EMA'),
                                ],
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              const Text('链接: '),
                              DropdownButton<String>(
                                value: _linkMode,
                                items: const [
                                  DropdownMenuItem(
                                    value: 'futures',
                                    child: Text('合约'),
                                  ),
                                  DropdownMenuItem(
                                    value: 'spot_alpha',
                                    child: Text('现货/Alpha'),
                                  ),
                                ],
                                onChanged: (v) {
                                  if (v == null) return;
                                  setState(() {
                                    _linkMode = v;
                                  });
                                  _publishBrowseQueue();
                                  if (v == 'spot_alpha') {
                                    _ensureSpotSymbols();
                                    _ensureAlphaTokens();
                                  }
                                },
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(_status, style: const TextStyle(fontSize: 12)),
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    height: taskPanelHeight,
                    child: Card(
                      elevation: 1,
                      child: _tasks.isEmpty
                          ? const Center(
                              child: Text(
                                '暂无扫描任务，先在上方选择周期并点击“添加任务”。',
                                style: TextStyle(color: Colors.grey),
                              ),
                            )
                          : ListView.builder(
                              itemCount: _tasks.length,
                              itemBuilder: (context, index) {
                                final task = _tasks[index];
                                final statusText = task.status.isEmpty
                                    ? (task.isRunning ? '运行中' : '未开始')
                                    : task.status;
                                return ListTile(
                                  title: Text(
                                    '任务 #${task.id}  周期: ${task.interval}',
                                  ),
                                  subtitle: Text(
                                    '状态: $statusText\n匹配数量: ${task.matches.length}  持续扫描: ${task.continuous ? '是' : '否'}  threshold=${task.threshold}',
                                    maxLines: 2,
                                  ),
                                  isThreeLine: true,
                                  trailing: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Checkbox(
                                        value: task.continuous,
                                        onChanged: (v) {
                                          if (v == null) return;
                                          setState(() {
                                            task.continuous = v;
                                          });
                                        },
                                      ),
                                      IconButton(
                                        icon: Icon(
                                          task.isRunning
                                              ? Icons.stop
                                              : Icons.play_arrow,
                                        ),
                                        tooltip: task.isRunning
                                            ? '停止任务'
                                            : '开始任务',
                                        onPressed: () {
                                          if (task.isRunning) {
                                            _stopTask(task);
                                          } else {
                                            _runScanForTask(task);
                                          }
                                        },
                                      ),
                                      IconButton(
                                        icon: const Icon(Icons.delete),
                                        tooltip: '删除任务',
                                        onPressed: () => _deleteTask(task),
                                      ),
                                    ],
                                  ),
                                );
                              },
                            ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Card(
                    elevation: 1,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      child: Row(
                        children: [
                          ElevatedButton(
                            onPressed: _startBrowseCurrentResults,
                            child: const Text('开始浏览'),
                          ),
                          const SizedBox(width: 8),
                          OutlinedButton(
                            onPressed:
                                _browseSymbols.isEmpty ? null : _browsePrev,
                            child: const Text('上一个(-3)'),
                          ),
                          const SizedBox(width: 8),
                          OutlinedButton(
                            onPressed:
                                _browseSymbols.isEmpty ? null : _browseNext,
                            child: const Text('下一个(+3)'),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              _browseSymbols.isEmpty
                                  ? '当前没有浏览队列'
                                  : '浏览队列 ${_browseIndex >= 0 ? _browseIndex + 1 : 0}/${_browseSymbols.length}'
                                      '  ${_browseIndex >= 0 ? _browseSymbols[_browseIndex] : ''}',
                              style: const TextStyle(fontSize: 12),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(width: 8),
                          const Text(
                            '需安装 Tampermonkey；快捷键每次跳 3 个: [ ] / ← → / J K',
                            style: TextStyle(fontSize: 12, color: Colors.grey),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    height: resultPanelHeight,
                    child: Card(
                      elevation: 1,
                      child: Builder(
                        builder: (context) {
                          final entries = <_TaskMatchEntry>[];
                          for (final task in _tasks) {
                            for (final m in task.matches) {
                              entries.add(_TaskMatchEntry(task.interval, m));
                            }
                          }
                          final hasTrend = _postDenseTrendResults.isNotEmpty;
                          final hasBacktest =
                              _postDenseTrendBacktestResults.isNotEmpty;
                          final hasStable = _stableSymbolResults.isNotEmpty;
                          final trendUp = _sortedTrendResults(
                            _postDenseTrendResults,
                            'up',
                          );
                          final backtestUp = _sortedTrendResults(
                            _postDenseTrendBacktestResults,
                            'up',
                          );
                          if (entries.isEmpty &&
                              !hasTrend &&
                              !hasBacktest &&
                              !hasStable) {
                            return const Center(
                              child: Text(
                                '暂无匹配结果',
                                style: TextStyle(color: Colors.grey),
                              ),
                            );
                          }
                          final itemCount =
                              (trendUp.isNotEmpty ? 1 + trendUp.length : 0) +
                              (backtestUp.isNotEmpty
                                  ? 1 + backtestUp.length
                                  : 0) +
                              (hasStable
                                  ? 1 + _stableSymbolResults.length
                                  : 0) +
                              (entries.isNotEmpty ? 1 + entries.length : 0);
                          return ListView.builder(
                            itemCount: itemCount,
                            itemBuilder: (context, index) {
                              var cursor = 0;

                              if (trendUp.isNotEmpty) {
                                if (index == cursor) {
                                  return ListTile(
                                    title: Text(
                                      '— ↑ 上涨 (${trendUp.length}) —',
                                      style: const TextStyle(
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  );
                                }
                                cursor += 1;
                                final upIdx = index - cursor;
                                if (upIdx < trendUp.length) {
                                  return _postDenseTrendListTile(
                                    trendUp[upIdx],
                                  );
                                }
                                cursor += trendUp.length;
                              }

                              if (backtestUp.isNotEmpty) {
                                if (index == cursor) {
                                  return ListTile(
                                    title: Text(
                                      '— 回测 ↑ 上涨 (${backtestUp.length}) —',
                                      style: const TextStyle(
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  );
                                }
                                cursor += 1;
                                final upIdx = index - cursor;
                                if (upIdx < backtestUp.length) {
                                  return _postDenseTrendListTile(
                                    backtestUp[upIdx],
                                    backtest: true,
                                  );
                                }
                                cursor += backtestUp.length;
                              }

                              if (hasStable) {
                                if (index == cursor) {
                                  return ListTile(
                                    title: Text(
                                      '— 稳定币种 (${_stableSymbolResults.length}) —',
                                      style: const TextStyle(
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  );
                                }
                                cursor += 1;
                                final stableIdx = index - cursor;
                                if (stableIdx < _stableSymbolResults.length) {
                                  final s = _stableSymbolResults[stableIdx];
                                  return ListTile(
                                    title: symbolBoldText(
                                      s.symbol,
                                      '  (${s.rangeMultiple.toStringAsFixed(2)}倍)',
                                    ),
                                    subtitle: Text(
                                      '上市 ${formatUtcDate(s.listedAt)}  '
                                      '低=${s.minLow.toStringAsFixed(6)}  '
                                      '高=${s.maxHigh.toStringAsFixed(6)}  '
                                      '24h额=${formatVolume(s.quoteVolume24h)}',
                                    ),
                                  );
                                }
                                cursor += _stableSymbolResults.length;
                              }

                              if (entries.isNotEmpty) {
                                if (index == cursor) {
                                  return const ListTile(
                                    title: Text(
                                      '— EMA 收敛匹配 —',
                                      style: TextStyle(
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  );
                                }
                                cursor += 1;
                                final e = entries[index - cursor];
                                return ListTile(
                                  title: symbolBoldText(
                                    e.match.symbol,
                                    '  (${e.interval})',
                                  ),
                                  subtitle: Text(
                                    'spread=${e.match.spreadPct.toStringAsFixed(4)}%',
                                  ),
                                );
                              }

                              return const SizedBox.shrink();
                            },
                          );
                        },
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

// ===== 网络与计算逻辑 =====

class _ScanTask {
  final int id;
  final String interval;
  final double threshold;
  final bool onlyNewSymbols;
  final int newListingDays;
  bool continuous;
  bool isRunning;
  bool cancelRequested;
  String status;
  List<MatchResult> matches;
  Set<String> lastMatchedSymbols;

  _ScanTask({
    required this.id,
    required this.interval,
    required this.threshold,
    this.onlyNewSymbols = false,
    this.newListingDays = 7,
    this.continuous = true,
  }) : isRunning = false,
       cancelRequested = false,
       status = '',
       matches = <MatchResult>[],
       lastMatchedSymbols = <String>{};
}

class _TaskMatchEntry {
  final String interval;
  final MatchResult match;

  _TaskMatchEntry(this.interval, this.match);
}

// 自上市以来高低点倍数低于此值视为「稳定」（无百倍级单边波动）。
const double stableMaxRangeMultiple = 100.0;

// 直接访问 Binance USDT 永续合约接口，对应 Python 代码中的 BINANCE_FAPI_BASE。
const String binanceFapiBase = 'https://fapi.binance.com';
const int binanceKlinesMaxLimit = 1500;

dynamic _cachedExchangeInfo;
DateTime? _cachedExchangeInfoAt;
dynamic _cachedTicker24hr;
DateTime? _cachedTicker24hrAt;

const Duration _exchangeInfoCacheTtl = Duration(minutes: 5);
const Duration _ticker24hrCacheTtl = Duration(seconds: 45);

Future<dynamic> fetchBinanceExchangeInfo({bool forceRefresh = false}) async {
  final now = DateTime.now();
  if (!forceRefresh &&
      _cachedExchangeInfo != null &&
      _cachedExchangeInfoAt != null &&
      now.difference(_cachedExchangeInfoAt!) < _exchangeInfoCacheTtl) {
    return _cachedExchangeInfo;
  }
  final data =
      await httpGetJson('$binanceFapiBase/fapi/v1/exchangeInfo');
  _cachedExchangeInfo = data;
  _cachedExchangeInfoAt = now;
  return data;
}

Future<dynamic> fetchBinanceTicker24hr({bool forceRefresh = false}) async {
  final now = DateTime.now();
  if (!forceRefresh &&
      _cachedTicker24hr != null &&
      _cachedTicker24hrAt != null &&
      now.difference(_cachedTicker24hrAt!) < _ticker24hrCacheTtl) {
    return _cachedTicker24hr;
  }
  final data = await httpGetJson('$binanceFapiBase/fapi/v1/ticker/24hr');
  _cachedTicker24hr = data;
  _cachedTicker24hrAt = now;
  return data;
}

String? _tryParseBinanceBanMessage(String body, int statusCode) {
  try {
    final decoded = jsonDecode(body);
    if (decoded is! Map) return null;
    final msg = decoded['msg']?.toString() ?? '';
    final code = decoded['code'];
    final isRateLimit = code == -1003 ||
        msg.toLowerCase().contains('too many requests') ||
        msg.contains('banned until');
    if (!isRateLimit && msg.isEmpty) return null;

    final match = RegExp(r'banned until (\d+)').firstMatch(msg);
    if (match != null) {
      final untilMs = int.tryParse(match.group(1)!);
      if (untilMs != null) {
        final until =
            DateTime.fromMillisecondsSinceEpoch(untilMs, isUtc: true).toLocal();
        final wait = until.difference(DateTime.now());
        if (!wait.isNegative) {
          final mins = wait.inMinutes;
          final secs = wait.inSeconds.remainder(60);
          return 'Binance API 请求过多，IP 已被限流至 $until（约 ${mins}分${secs}秒后可重试）';
        }
      }
    }

    if (msg.isNotEmpty) {
      return 'Binance API 请求过多 (HTTP $statusCode): $msg';
    }
  } catch (_) {}
  return null;
}

Future<dynamic> httpGetJson(
  String url, {
  Map<String, String>? params,
  int timeoutSeconds = 15,
  int maxRetries = 6,
}) async {
  var uri = Uri.parse(url);
  if (params != null && params.isNotEmpty) {
    uri = uri.replace(queryParameters: {...uri.queryParameters, ...params});
  }

  final headers = <String, String>{
    'User-Agent': 'Mozilla/5.0 (compatible; ema-converge-scanner/1.0)',
    'Accept': 'application/json',
  };

  Object? lastError;

  for (var attempt = 1; attempt <= maxRetries; attempt++) {
    try {
      debugPrint('[EMA][HTTP] GET $uri (attempt $attempt/$maxRetries)');
      http.Response resp;
      if (kIsWeb) {
        resp = await http
            .get(uri, headers: headers)
            .timeout(Duration(seconds: timeoutSeconds));
      } else {
        final ioHttpClient = HttpClient()
          ..badCertificateCallback =
              (X509Certificate cert, String host, int port) => true;
        ioHttpClient.findProxy = (uri) => 'DIRECT';
        final ioClient = IOClient(ioHttpClient);
        resp = await ioClient
            .get(uri, headers: headers)
            .timeout(Duration(seconds: timeoutSeconds));
      }
      if (resp.statusCode >= 200 && resp.statusCode < 300) {
        debugPrint('[EMA][HTTP] OK $uri status=${resp.statusCode}');
        return jsonDecode(utf8.decode(resp.bodyBytes));
      }

      lastError = 'HTTP ${resp.statusCode} ${resp.reasonPhrase}';
      debugPrint('[EMA][HTTP] Non-2xx $uri: $lastError');
      if (resp.statusCode == 418) {
        final banMsg = _tryParseBinanceBanMessage(resp.body, resp.statusCode);
        debugPrint('[EMA][HTTP] 418 response body: ${resp.body}');
        throw Exception(
          banMsg ?? 'Binance API 限流 (HTTP 418)，请稍后再试或减少扫描频率',
        );
      }
      if ([429, 500, 502, 503, 504].contains(resp.statusCode)) {
        if (resp.statusCode == 429) {
          final banMsg = _tryParseBinanceBanMessage(resp.body, resp.statusCode);
          if (banMsg != null) {
            lastError = banMsg;
          }
        }
        final baseMs = 500 * attempt;
        final jitter = math.Random().nextInt(500);
        final delay = Duration(milliseconds: baseMs + jitter);
        debugPrint('[EMA][HTTP] retrying after ${delay.inMilliseconds}ms');
        await Future.delayed(delay);
        continue;
      } else {
        await Future.delayed(Duration(milliseconds: 400 * attempt));
      }
    } on TimeoutException catch (e) {
      lastError = e;
      debugPrint('[EMA][HTTP] Timeout $uri on attempt $attempt: $e');
      await Future.delayed(Duration(milliseconds: 400 * attempt));
    } catch (e) {
      lastError = e;
      debugPrint('[EMA][HTTP] Error $uri on attempt $attempt: $e');
      await Future.delayed(Duration(milliseconds: 400 * attempt));
    }
  }

  throw Exception('请求失败，已重试 $maxRetries 次。最后错误: $lastError');
}

int? parseSymbolOnboardTimestampMs(Map<String, dynamic> symbolInfo) {
  final timeField =
      symbolInfo['onboardDate'] ??
      symbolInfo['onboardTime'] ??
      symbolInfo['listTime'] ??
      symbolInfo['onboardAt'] ??
      symbolInfo['onboardTimestamp'];
  if (timeField is int) return timeField;
  if (timeField is String) return int.tryParse(timeField);
  return null;
}

Future<Map<String, int>> fetchUsdtPerpListingTimesMs() async {
  final info = await fetchBinanceExchangeInfo() as dynamic;
  final listingTimes = <String, int>{};
  if (info is! Map<String, dynamic>) return listingTimes;

  final list = info['symbols'];
  if (list is! List) return listingTimes;

  for (final s in list) {
    if (s is! Map<String, dynamic>) continue;
    try {
      if (s['contractType'] != 'PERPETUAL') continue;
      if (s['status'] != 'TRADING') continue;
      if (s['quoteAsset'] != 'USDT') continue;

      final symbol = (s['symbol'] ?? '').toString();
      if (symbol.isEmpty) continue;

      final ts = parseSymbolOnboardTimestampMs(s);
      if (ts != null) {
        listingTimes[symbol] = ts;
      }
    } catch (_) {
      continue;
    }
  }
  return listingTimes;
}

Future<List<ListingVolumeResult>> fetchSymbolsListedBetweenDates({
  required DateTime startDate,
  required DateTime endDate,
}) async {
  final exchangeInfo = await fetchBinanceExchangeInfo() as dynamic;

  final ticker24h = await fetchBinanceTicker24hr() as dynamic;

  if (exchangeInfo is! Map<String, dynamic>) {
    return [];
  }

  final symbols = exchangeInfo['symbols'];
  if (symbols is! List) {
    return [];
  }

  final volumeMap = <String, double>{};

  if (ticker24h is List) {
    for (final item in ticker24h) {
      if (item is! Map<String, dynamic>) continue;

      final symbol = item['symbol']?.toString() ?? '';

      final volume =
          double.tryParse(item['quoteVolume']?.toString() ?? '0') ?? 0;

      volumeMap[symbol] = volume;
    }
  }

  final results = <ListingVolumeResult>[];

  final startMs = DateTime(
    startDate.year,
    startDate.month,
    startDate.day,
  ).millisecondsSinceEpoch;
  final endMs = DateTime(
    endDate.year,
    endDate.month,
    endDate.day,
    23,
    59,
    59,
    999,
  ).millisecondsSinceEpoch;

  for (final s in symbols) {
    if (s is! Map<String, dynamic>) continue;

    try {
      if (s['contractType'] != 'PERPETUAL') continue;
      if (s['status'] != 'TRADING') continue;
      if (s['quoteAsset'] != 'USDT') continue;

      final symbol = s['symbol']?.toString() ?? '';

      final listedAt = parseSymbolOnboardTimestampMs(s);

      if (listedAt == null) continue;

      if (listedAt < startMs || listedAt > endMs) {
        continue;
      }

      results.add(
        ListingVolumeResult(
          symbol: symbol,
          listingTime: listedAt,
          quoteVolume: volumeMap[symbol] ?? 0,
        ),
      );
    } catch (_) {}
  }

  results.sort((a, b) => b.quoteVolume.compareTo(a.quoteVolume));

  return results;
}

Future<Set<String>> fetchUsdtPerpetualSymbols() async {
  final info = await fetchBinanceExchangeInfo() as dynamic;

  final symbols = <String>{};
  if (info is! Map<String, dynamic>) {
    return symbols;
  }

  final list = info['symbols'];
  if (list is! List) return symbols;

  for (final s in list) {
    if (s is! Map<String, dynamic>) continue;
    try {
      if (s['contractType'] != 'PERPETUAL') continue;
      if (s['status'] != 'TRADING') continue;
      if (s['quoteAsset'] != 'USDT') continue;

      final symbol = (s['symbol'] ?? '').toString();
      if (symbol.isNotEmpty) {
        symbols.add(symbol);
      }
    } catch (_) {
      continue;
    }
  }
  return symbols;
}

Future<List<String>> fetchTopSymbolsByQuoteVolume(
  int topN, {
  int? maxListingDays,
  int? minListingDays,
}) async {
  final usdtPerpSymbols = await fetchUsdtPerpetualSymbols();
  if (usdtPerpSymbols.isEmpty) {
    throw Exception('未能获取 USDT 永续合约列表');
  }

  final useMaxFilter = maxListingDays != null && maxListingDays > 0;
  final useMinFilter = minListingDays != null && minListingDays > 0;

  Map<String, int>? listingTimes;
  int? maxListingCutoffMs;
  int? minListingCutoffMs;
  if (useMaxFilter || useMinFilter) {
    listingTimes = await fetchUsdtPerpListingTimesMs();
    final nowUtc = DateTime.now().toUtc();
    if (useMaxFilter) {
      maxListingCutoffMs = nowUtc
          .subtract(Duration(days: maxListingDays))
          .millisecondsSinceEpoch;
    }
    if (useMinFilter) {
      minListingCutoffMs = nowUtc
          .subtract(Duration(days: minListingDays))
          .millisecondsSinceEpoch;
    }
  }

  final tickers = await fetchBinanceTicker24hr() as dynamic;
  if (tickers is! List) {
    throw Exception('返回数据格式异常：期望 list');
  }

  final filtered = <_SymbolVolume>[];

  for (final item in tickers) {
    if (item is! Map<String, dynamic>) continue;
    try {
      final symbol = (item['symbol'] ?? '').toString();
      if (!usdtPerpSymbols.contains(symbol)) continue;

      if (listingTimes != null) {
        final listedAtMs = listingTimes[symbol];
        if (listedAtMs == null) continue;
        if (maxListingCutoffMs != null && listedAtMs < maxListingCutoffMs) {
          continue;
        }
        if (minListingCutoffMs != null && listedAtMs > minListingCutoffMs) {
          continue;
        }
      }

      final qv =
          double.tryParse((item['quoteVolume'] ?? '0').toString()) ?? 0.0;
      if (qv <= 0) continue;

      filtered.add(_SymbolVolume(symbol: symbol, quoteVolume: qv));
    } catch (_) {
      continue;
    }
  }

  filtered.sort((a, b) => b.quoteVolume.compareTo(a.quoteVolume));
  final result = filtered.take(topN).map((e) => e.symbol).toList();
  return result;
}

/// 返回最近 `days` 天内上新的币种，按自发行以来的累计 futures USDT 成交额排序。
Future<List<_NewListingResult>> fetchNewlyListedSymbolsByLifetimeVolume({
  required int days,
  required int topN,
  required int workers,
  void Function(int current, int total)? onProgress,
}) async {
  final info = await fetchBinanceExchangeInfo() as dynamic;
  if (info is! Map<String, dynamic>) return <_NewListingResult>[];

  final list = info['symbols'];
  if (list is! List) return <_NewListingResult>[];

  final cutoffMs = DateTime.now()
      .toUtc()
      .subtract(Duration(days: days))
      .millisecondsSinceEpoch;

  // 预取 24h 成交量数据，用于初筛排序。
  final tickersRaw = await fetchBinanceTicker24hr() as dynamic;
  final Map<String, double> vol24h = {};
  if (tickersRaw is List) {
    for (final t in tickersRaw) {
      if (t is! Map<String, dynamic>) continue;
      try {
        final sym = (t['symbol'] ?? '').toString();
        final qv = double.tryParse((t['quoteVolume'] ?? '0').toString()) ?? 0.0;
        vol24h[sym] = qv;
      } catch (_) {
        continue;
      }
    }
  }

  // 收集符合天数条件的新币。
  final candidates = <_NewListingResult>[];
  for (final s in list) {
    if (s is! Map<String, dynamic>) continue;
    try {
      if (s['contractType'] != 'PERPETUAL') continue;
      if (s['status'] != 'TRADING') continue;
      if (s['quoteAsset'] != 'USDT') continue;

      final symbol = (s['symbol'] ?? '').toString();
      if (symbol.isEmpty) continue;

      dynamic timeField =
          s['onboardDate'] ??
          s['onboardTime'] ??
          s['listTime'] ??
          s['onboardAt'] ??
          s['onboardTimestamp'];
      int? ts;
      if (timeField is int) ts = timeField;
      if (timeField is String) ts = int.tryParse(timeField);
      if (ts == null) continue;

      if (ts >= cutoffMs) {
        candidates.add(
          _NewListingResult(
            symbol: symbol,
            listedAt: DateTime.fromMillisecondsSinceEpoch(ts, isUtc: true),
            quoteVolume: vol24h[symbol] ?? 0.0,
          ),
        );
      }
    } catch (_) {
      continue;
    }
  }

  if (candidates.isEmpty) return <_NewListingResult>[];

  // 按 24h 成交额降序，只对头部候选计算全时成交额。
  candidates.sort((a, b) => b.quoteVolume.compareTo(a.quoteVolume));
  final refineCount = (topN * 2).clamp(1, candidates.length);
  final toRefine = candidates.take(refineCount).toList();

  debugPrint(
    '[EMA] 全时成交额扫描: days=$days topN=$topN 共 ${candidates.length} 个新币, '
    '对前 $refineCount 个计算全时成交额 (workers=$workers)',
  );

  // 按 workers 并行分批获取全时成交额。
  final effectiveWorkers = workers.clamp(1, 16);
  final volumes = <String, double>{};
  var idx = 0;
  while (idx < toRefine.length) {
    final end = (idx + effectiveWorkers).clamp(0, toRefine.length);
    final batch = toRefine.sublist(idx, end);
    final futures = <Future<void>>[];
    for (final c in batch) {
      futures.add(
        (() async {
          try {
            final vol = await fetchFuturesLifetimeQuoteVolume(
              c.symbol,
              c.listedAt.millisecondsSinceEpoch,
            );
            volumes[c.symbol] = vol;
          } catch (e) {
            debugPrint('[EMA] 获取 ${c.symbol} futures累计成交额失败: $e');
          }
        })(),
      );
    }
    await Future.wait(futures);
    idx = end;
    onProgress?.call(idx, toRefine.length);
    debugPrint('[EMA] 全时成交额 [$idx/${toRefine.length}]');
    if (idx < toRefine.length) {
      await Future.delayed(const Duration(milliseconds: 300));
    }
  }

  // 用实际成交量重建结果列表。
  final results = toRefine.map((c) {
    final vol = volumes[c.symbol] ?? c.quoteVolume;
    return _NewListingResult(
      symbol: c.symbol,
      listedAt: c.listedAt,
      quoteVolume: vol,
    );
  }).toList();

  results.sort((a, b) => b.quoteVolume.compareTo(a.quoteVolume));
  return results.take(topN).toList();
}

class LifetimePriceRange {
  final double minLow;
  final double maxHigh;
  final int barCount;

  LifetimePriceRange({
    required this.minLow,
    required this.maxHigh,
    required this.barCount,
  });

  double get rangeMultiple => minLow > 0 ? maxHigh / minLow : double.infinity;

  bool isStable({double maxMultiple = stableMaxRangeMultiple}) {
    return rangeMultiple < maxMultiple;
  }
}

/// 用日线 K 线统计自上市以来的最低价与最高价（仅统计上市时间之后的 K 线）。
Future<LifetimePriceRange?> fetchLifetimePriceRange(
  String symbol,
  int listingTimeMs,
) async {
  final listedAt = DateTime.fromMillisecondsSinceEpoch(
    listingTimeMs,
    isUtc: true,
  );
  final ageDays = DateTime.now().toUtc().difference(listedAt).inDays;
  if (ageDays < 1) return null;

  final klineLimit = math.min(ageDays + 1, binanceKlinesMaxLimit);
  final klines =
      await httpGetJson(
            '$binanceFapiBase/fapi/v1/klines',
            params: {
              'symbol': symbol,
              'interval': '1d',
              'limit': '$klineLimit',
            },
          )
          as dynamic;

  if (klines is! List || klines.isEmpty) return null;

  double? minLow;
  double? maxHigh;
  var barCount = 0;

  for (final k in klines) {
    try {
      if (k is! List || k.length < 4) continue;
      final openTimeMs = int.tryParse(k[0].toString());
      if (openTimeMs == null || openTimeMs < listingTimeMs) continue;

      final high = double.tryParse(k[2].toString());
      final low = double.tryParse(k[3].toString());
      if (high == null || low == null || low <= 0) continue;

      minLow = minLow == null ? low : math.min(minLow, low);
      maxHigh = maxHigh == null ? high : math.max(maxHigh, high);
      barCount += 1;
    } catch (_) {
      continue;
    }
  }

  if (minLow == null || maxHigh == null || barCount == 0) return null;

  return LifetimePriceRange(
    minLow: minLow,
    maxHigh: maxHigh,
    barCount: barCount,
  );
}

Future<double> fetchFuturesLifetimeQuoteVolume(
  String symbol,
  int listingTimeMs,
) async {
  // 首先尝试使用日线K线聚合（较少请求，低限流风险）
  try {
    final listedAt = DateTime.fromMillisecondsSinceEpoch(
      listingTimeMs,
      isUtc: true,
    );
    final ageDays = DateTime.now().toUtc().difference(listedAt).inDays;
    final klineLimit = math.min(ageDays + 1, binanceKlinesMaxLimit);

    debugPrint(
      '[EMA][VOL] $symbol listed=$listedAt ageDays=$ageDays klineLimit=$klineLimit',
    );

    final klines =
        await httpGetJson(
              '$binanceFapiBase/fapi/v1/klines',
              params: {
                'symbol': symbol,
                'interval': '1d',
                'limit': '$klineLimit',
              },
            )
            as dynamic;

    if (klines is List && klines.isNotEmpty) {
      double total = 0.0;
      for (final k in klines) {
        try {
          if (k is List && k.length > 7) {
            final quoteVol = double.tryParse(k[7].toString()) ?? 0.0;
            total += quoteVol;
          }
        } catch (_) {
          continue;
        }
      }
      debugPrint(
        '[EMA][VOL] $symbol klinesCount=${klines.length} sum=${total.toStringAsFixed(2)}',
      );
      return total;
    }

    // klines 返回了非数组（如 API 业务错误），抛出异常让调用方处理。
    throw Exception('klines 返回异常数据: $klines');
  } catch (e) {
    debugPrint('[EMA] 日线聚合失败，准备回退到逐笔聚合: $e');
  }

  // 回退到逐笔聚合（aggTrades）——带指数退避和小延迟以降低限流风险
  var totalQuoteVolume = 0.0;
  var fromId = 0;
  var hasMore = true;
  var consecutive429 = 0;
  var pageCount = 0;

  debugPrint('[EMA][VOL] $symbol fallback aggTrades startTime=$listingTimeMs');

  while (hasMore) {
    final params = <String, String>{
      'symbol': symbol,
      'limit': '1000',
      'startTime': fromId == 0 ? '$listingTimeMs' : '',
    };
    params.removeWhere((key, value) => value.isEmpty);
    if (fromId > 0) params['fromId'] = '$fromId';

    try {
      final data =
          await httpGetJson(
                '$binanceFapiBase/fapi/v1/aggTrades',
                params: params,
              )
              as dynamic;

      if (data is! List || data.isEmpty) break;

      for (final item in data) {
        if (item is! Map<String, dynamic>) continue;
        final price = double.tryParse((item['p'] ?? '0').toString()) ?? 0.0;
        final qty = double.tryParse((item['q'] ?? '0').toString()) ?? 0.0;
        totalQuoteVolume += price * qty;
      }

      pageCount += 1;
      if (pageCount == 1 || pageCount % 10 == 0) {
        debugPrint(
          '[EMA][VOL] $symbol aggTrades pages=$pageCount fromId=$fromId sum=${totalQuoteVolume.toStringAsFixed(2)}',
        );
      }

      consecutive429 = 0;

      if (data.length < 1000) break;

      final last = data.last;
      if (last is Map<String, dynamic>) {
        final lastId = last['a'];
        if (lastId is int) {
          fromId = lastId + 1;
        } else if (lastId is String) {
          fromId = (int.tryParse(lastId) ?? fromId) + 1;
        } else {
          hasMore = false;
        }
      } else {
        hasMore = false;
      }

      await Future.delayed(Duration(milliseconds: 200));
    } catch (e) {
      final err = e.toString();
      if (err.contains('HTTP 429')) {
        consecutive429 += 1;
        final backoffMs = math.min(
          1000 * math.pow(2, consecutive429).toInt(),
          16000,
        );
        debugPrint('[EMA] 收到 429，退避 ${backoffMs}ms (count=$consecutive429)');
        await Future.delayed(Duration(milliseconds: backoffMs));
        if (consecutive429 >= 5) {
          debugPrint('[EMA] 429 重试过多，停止逐笔聚合');
          break;
        }
        continue;
      }

      debugPrint('[EMA] 逐笔聚合异常，停止: $e');
      break;
    }
  }

  debugPrint(
    '[EMA][VOL] $symbol aggTrades done pages=$pageCount sum=${totalQuoteVolume.toStringAsFixed(2)}',
  );
  return totalQuoteVolume;
}

/// 返回最近 `days` 天内上新的 USDT 永续合约列表（基于 exchangeInfo 中的上架时间字段）
Future<List<_NewListingResult>> fetchNewlyListedSymbols(
  int days,
  int topN,
) async {
  final info = await fetchBinanceExchangeInfo() as dynamic;
  final results = <_NewListingResult>[];
  if (info is! Map<String, dynamic>) return results;

  final list = info['symbols'];
  if (list is! List) return results;

  final cutoffMs = DateTime.now()
      .toUtc()
      .subtract(Duration(days: days))
      .millisecondsSinceEpoch;

  // 预取 24h 成交量数据，用于按成交量排序
  final tickersRaw = await fetchBinanceTicker24hr() as dynamic;
  final Map<String, double> volMap = {};
  if (tickersRaw is List) {
    for (final t in tickersRaw) {
      if (t is! Map<String, dynamic>) continue;
      try {
        final sym = (t['symbol'] ?? '').toString();
        final qv = double.tryParse((t['quoteVolume'] ?? '0').toString()) ?? 0.0;
        volMap[sym] = qv;
      } catch (_) {
        continue;
      }
    }
  }

  for (final s in list) {
    if (s is! Map<String, dynamic>) continue;
    try {
      if (s['contractType'] != 'PERPETUAL') continue;
      if (s['status'] != 'TRADING') continue;
      if (s['quoteAsset'] != 'USDT') continue;

      final symbol = (s['symbol'] ?? '').toString();
      if (symbol.isEmpty) continue;

      dynamic timeField =
          s['onboardDate'] ??
          s['onboardTime'] ??
          s['listTime'] ??
          s['onboardAt'] ??
          s['onboardTimestamp'];
      int? ts;
      if (timeField is int) ts = timeField;
      if (timeField is String) ts = int.tryParse(timeField);
      if (ts == null) continue;

      if (ts >= cutoffMs) {
        double qv = volMap[symbol] ?? 0.0;
        if (qv == 0.0) {
          try {
            final single =
                await httpGetJson(
                      '$binanceFapiBase/fapi/v1/ticker/24hr',
                      params: {'symbol': symbol},
                    )
                    as dynamic;
            if (single is Map<String, dynamic>) {
              qv =
                  double.tryParse((single['quoteVolume'] ?? '0').toString()) ??
                  qv;
            }
          } catch (_) {
            // ignore fetch errors, keep qv as-is
          }
        }

        results.add(
          _NewListingResult(
            symbol: symbol,
            listedAt: DateTime.fromMillisecondsSinceEpoch(ts, isUtc: true),
            quoteVolume: qv,
          ),
        );
      }
    } catch (_) {
      continue;
    }
  }

  // 按成交量降序，并取前 topN
  results.sort((a, b) => b.quoteVolume.compareTo(a.quoteVolume));
  return results.take(topN).toList();
}

Future<List<double>> fetchKlines(
  String symbol,
  String interval,
  int limit,
) async {
  final bars = await fetchKlineBars(symbol, interval, limit);
  return bars.map((bar) => bar.close).toList(growable: false);
}

class KlineBar {
  final DateTime openTimeUtc;
  final double close;

  const KlineBar({required this.openTimeUtc, required this.close});
}

Future<List<KlineBar>> fetchKlineBars(
  String symbol,
  String interval,
  int limit,
) async {
  final klines =
      await httpGetJson(
            '$binanceFapiBase/fapi/v1/klines',
            params: {'symbol': symbol, 'interval': interval, 'limit': '$limit'},
          )
          as dynamic;

  if (klines is! List || klines.isEmpty) {
    return const [];
  }

  final bars = <KlineBar>[];
  for (final k in klines) {
    try {
      if (k is List && k.length > 4) {
        final openTimeMs = int.tryParse(k[0].toString());
        if (openTimeMs == null) continue;
        bars.add(
          KlineBar(
            openTimeUtc: DateTime.fromMillisecondsSinceEpoch(
              openTimeMs,
              isUtc: true,
            ),
            close: double.parse(k[4].toString()),
          ),
        );
      }
    } catch (_) {
      continue;
    }
  }
  return bars;
}

double? ema(List<double> values, int span) {
  if (span <= 0) {
    throw ArgumentError('span 必须为正数');
  }
  if (values.length < span) {
    return null;
  }

  // Binance/主流行情图表常见做法：以第一根收盘价为初值递推 EMA。
  final alpha = 2.0 / (span + 1.0);
  double e = values.first;

  for (var i = 1; i < values.length; i++) {
    final x = values[i];
    e = alpha * x + (1.0 - alpha) * e;
  }
  return e;
}

double? ma(List<double> values, int span) {
  if (span <= 0) {
    throw ArgumentError('span 必须为正数');
  }
  if (values.length < span) {
    return null;
  }

  final window = values.sublist(values.length - span);
  return window.reduce((a, b) => a + b) / span.toDouble();
}

class ConvergeResult {
  final bool ok;
  final double spread;

  ConvergeResult(this.ok, this.spread);
}

ConvergeResult isDense6(List<double> averages, double threshold) {
  final mn = averages.reduce(math.min);
  final mx = averages.reduce(math.max);
  final mnAbs = mn.abs();
  if (mnAbs == 0) {
    return ConvergeResult(false, double.infinity);
  }
  final spread = (mx - mn) / mnAbs;
  return ConvergeResult(spread <= threshold, spread);
}

List<double> emaSeries(List<double> values, int span) {
  if (values.isEmpty) return const [];
  final alpha = 2.0 / (span + 1.0);
  final series = <double>[values.first];
  var e = values.first;
  for (var i = 1; i < values.length; i++) {
    e = alpha * values[i] + (1.0 - alpha) * e;
    series.add(e);
  }
  return series;
}

List<double?> maSeries(List<double> values, int span) {
  final series = List<double?>.filled(values.length, null);
  if (values.length < span) return series;

  var sum = 0.0;
  for (var i = 0; i < values.length; i++) {
    sum += values[i];
    if (i >= span) {
      sum -= values[i - span];
    }
    if (i >= span - 1) {
      series[i] = sum / span;
    }
  }
  return series;
}

/// 密集点前后截取窗口（各 15 根，不足则以已有 K 线为准）。
const int denseCrossWindowBars = 15;

(int, int) denseCrossWindow(int denseIdx, int length) {
  final start = math.max(0, denseIdx - denseCrossWindowBars);
  final end = math.min(length - 1, denseIdx + denseCrossWindowBars);
  return (start, end);
}

/// 在 (startIdx, endIdx] 内寻找快/慢线首次金叉/死叉。
String? detectFirstCrossInWindow(
  List<double> fast,
  List<double> slow,
  int startIdx,
  int endIdx,
) {
  if (startIdx >= endIdx) return null;

  for (var i = startIdx + 1; i <= endIdx; i++) {
    final prevFast = fast[i - 1];
    final currFast = fast[i];
    final prevSlow = slow[i - 1];
    final currSlow = slow[i];
    if (prevFast <= prevSlow && currFast > currSlow) return 'up';
    if (prevFast >= prevSlow && currFast < currSlow) return 'down';
  }
  return null;
}

String? detectFirstCrossInWindowNullable(
  List<double?> fast,
  List<double?> slow,
  int startIdx,
  int endIdx,
) {
  if (startIdx >= endIdx) return null;

  for (var i = startIdx + 1; i <= endIdx; i++) {
    final prevFast = fast[i - 1];
    final currFast = fast[i];
    final prevSlow = slow[i - 1];
    final currSlow = slow[i];
    if (prevFast == null ||
        currFast == null ||
        prevSlow == null ||
        currSlow == null) {
      continue;
    }
    if (prevFast <= prevSlow && currFast > currSlow) return 'up';
    if (prevFast >= prevSlow && currFast < currSlow) return 'down';
  }
  return null;
}

class _CrossVoteSummary {
  final String? direction;
  final int upVotes;
  final int downVotes;

  const _CrossVoteSummary({
    required this.direction,
    required this.upVotes,
    required this.downVotes,
  });

  int get totalVotes => upVotes + downVotes;
}

/// 在密集点前后各 [denseCrossWindowBars] 根窗口内，
/// 对 EMA/MA 的 20/60/120 六组快慢线对综合投票判定金叉/死叉。
_CrossVoteSummary resolveComprehensiveCrossDirection({
  required List<double> ema20s,
  required List<double> ema60s,
  required List<double> ema120s,
  required List<double?> ma20s,
  required List<double?> ma60s,
  required List<double?> ma120s,
  required int denseIdx,
  required int length,
}) {
  final (windowStart, windowEnd) = denseCrossWindow(denseIdx, length);
  return resolveComprehensiveCrossDirectionInWindow(
    ema20s: ema20s,
    ema60s: ema60s,
    ema120s: ema120s,
    ma20s: ma20s,
    ma60s: ma60s,
    ma120s: ma120s,
    windowStart: windowStart,
    windowEnd: windowEnd,
  );
}

_CrossVoteSummary resolveComprehensiveCrossDirectionInWindow({
  required List<double> ema20s,
  required List<double> ema60s,
  required List<double> ema120s,
  required List<double?> ma20s,
  required List<double?> ma60s,
  required List<double?> ma120s,
  required int windowStart,
  required int windowEnd,
}) {
  if (windowStart >= windowEnd) {
    return const _CrossVoteSummary(direction: null, upVotes: 0, downVotes: 0);
  }

  var upVotes = 0;
  var downVotes = 0;

  void vote(String? direction) {
    if (direction == 'up') {
      upVotes += 1;
    } else if (direction == 'down') {
      downVotes += 1;
    }
  }

  vote(detectFirstCrossInWindow(ema20s, ema60s, windowStart, windowEnd));
  vote(detectFirstCrossInWindow(ema20s, ema120s, windowStart, windowEnd));
  vote(detectFirstCrossInWindow(ema60s, ema120s, windowStart, windowEnd));
  vote(detectFirstCrossInWindowNullable(ma20s, ma60s, windowStart, windowEnd));
  vote(detectFirstCrossInWindowNullable(ma20s, ma120s, windowStart, windowEnd));
  vote(detectFirstCrossInWindowNullable(ma60s, ma120s, windowStart, windowEnd));

  if (upVotes == 0 || upVotes <= downVotes) {
    return _CrossVoteSummary(
      direction: null,
      upVotes: upVotes,
      downVotes: downVotes,
    );
  }

  return _CrossVoteSummary(
    direction: 'up',
    upVotes: upVotes,
    downVotes: downVotes,
  );
}

class _PostDenseTrendDetection {
  final String direction;
  final double denseSpread;
  final int barsSinceDense;
  final double netMovePct;
  final double avgMa20DevPct;
  final double alongMa20Pct;
  final DateTime startTimeUtc;
  final DateTime endTimeUtc;
  final int crossUpVotes;
  final int crossDownVotes;
  final int denseEndIdx;
  final int trendEndIdx;

  const _PostDenseTrendDetection({
    required this.direction,
    required this.denseSpread,
    required this.barsSinceDense,
    required this.netMovePct,
    required this.avgMa20DevPct,
    required this.alongMa20Pct,
    required this.startTimeUtc,
    required this.endTimeUtc,
    required this.crossUpVotes,
    required this.crossDownVotes,
    required this.denseEndIdx,
    required this.trendEndIdx,
  });
}

String formatUtcDateTime(DateTime dt) {
  final d = dt.toUtc();
  final month = d.month.toString().padLeft(2, '0');
  final day = d.day.toString().padLeft(2, '0');
  final hour = d.hour.toString().padLeft(2, '0');
  final minute = d.minute.toString().padLeft(2, '0');
  return '${d.year}-$month-$day $hour:$minute UTC';
}

String formatUtcDate(DateTime dt) {
  final d = dt.toUtc();
  final month = d.month.toString().padLeft(2, '0');
  final day = d.day.toString().padLeft(2, '0');
  return '${d.year}-$month-$day';
}

ConvergeResult? dense6AtIndex(
  int index,
  List<double> ema20s,
  List<double> ema60s,
  List<double> ema120s,
  List<double?> ma20s,
  List<double?> ma60s,
  List<double?> ma120s,
  double threshold,
) {
  if (index < 119) return null;
  final ma20 = ma20s[index];
  final ma60 = ma60s[index];
  final ma120 = ma120s[index];
  if (ma20 == null || ma60 == null || ma120 == null) return null;

  return isDense6([
    ema20s[index],
    ema60s[index],
    ema120s[index],
    ma20,
    ma60,
    ma120,
  ], threshold);
}

/// 从最近一根密集 K 线向前回溯，找到连续密集区间的起始索引。
int findDenseClusterStartIdx(
  int denseEndIdx,
  int searchStart,
  List<double> ema20s,
  List<double> ema60s,
  List<double> ema120s,
  List<double?> ma20s,
  List<double?> ma60s,
  List<double?> ma120s,
  double threshold,
) {
  var startIdx = denseEndIdx;
  for (var i = denseEndIdx - 1; i >= searchStart; i--) {
    final dense = dense6AtIndex(
      i,
      ema20s,
      ema60s,
      ema120s,
      ma20s,
      ma60s,
      ma120s,
      threshold,
    );
    if (dense == null || !dense.ok) break;
    startIdx = i;
  }
  return startIdx;
}

/// 从 [cursor] 起找下一段连续密集区，返回 (起始索引, 结束索引)。
(int, int)? findNextDenseClusterBounds(
  _PostDenseTrendIndicatorContext ctx,
  int cursor,
  double threshold,
) {
  if (cursor > ctx.closes.length - 2) return null;

  int? clusterStart;
  int? clusterEnd;
  for (var i = cursor; i <= ctx.closes.length - 2; i++) {
    final dense = dense6AtIndex(
      i,
      ctx.ema20s,
      ctx.ema60s,
      ctx.ema120s,
      ctx.ma20s,
      ctx.ma60s,
      ctx.ma120s,
      threshold,
    );
    if (dense != null && dense.ok) {
      clusterStart ??= i;
      clusterEnd = i;
    } else if (clusterStart != null) {
      break;
    }
  }

  if (clusterStart == null || clusterEnd == null) return null;
  return (clusterStart, clusterEnd);
}

class _PostDenseTrendIndicatorContext {
  final List<double> closes;
  final List<double> ema20s;
  final List<double> ema60s;
  final List<double> ema120s;
  final List<double?> ma20s;
  final List<double?> ma60s;
  final List<double?> ma120s;
  final int searchStart;

  _PostDenseTrendIndicatorContext._({
    required this.closes,
    required this.ema20s,
    required this.ema60s,
    required this.ema120s,
    required this.ma20s,
    required this.ma60s,
    required this.ma120s,
    required this.searchStart,
  });

  factory _PostDenseTrendIndicatorContext.fromBars(List<KlineBar> bars) {
    final closes = bars.map((bar) => bar.close).toList(growable: false);
    return _PostDenseTrendIndicatorContext._(
      closes: closes,
      ema20s: emaSeries(closes, 20),
      ema60s: emaSeries(closes, 60),
      ema120s: emaSeries(closes, 120),
      ma20s: maSeries(closes, 20),
      ma60s: maSeries(closes, 60),
      ma120s: maSeries(closes, 120),
      searchStart: 119,
    );
  }
}

_PostDenseTrendDetection? evaluatePostDenseTrendSegment(
  _PostDenseTrendIndicatorContext ctx,
  List<KlineBar> bars, {
  required int denseEndIdx,
  required int trendEndIdx,
  required double threshold,
}) {
  if (ctx.closes.length < 122 || threshold <= 0) return null;
  if (trendEndIdx <= denseEndIdx + 1) return null;
  if (trendEndIdx >= ctx.closes.length) return null;

  final dense = dense6AtIndex(
    denseEndIdx,
    ctx.ema20s,
    ctx.ema60s,
    ctx.ema120s,
    ctx.ma20s,
    ctx.ma60s,
    ctx.ma120s,
    threshold,
  );
  if (dense == null || !dense.ok) return null;

  final denseStartIdx = findDenseClusterStartIdx(
    denseEndIdx,
    ctx.searchStart,
    ctx.ema20s,
    ctx.ema60s,
    ctx.ema120s,
    ctx.ma20s,
    ctx.ma60s,
    ctx.ma120s,
    threshold,
  );

  final barsSinceDense = trendEndIdx - denseEndIdx;
  if (barsSinceDense < 2) return null;

  final crossSummary = resolveComprehensiveCrossDirection(
    ema20s: ctx.ema20s,
    ema60s: ctx.ema60s,
    ema120s: ctx.ema120s,
    ma20s: ctx.ma20s,
    ma60s: ctx.ma60s,
    ma120s: ctx.ma120s,
    denseIdx: denseEndIdx,
    length: trendEndIdx + 1,
  );
  final crossDirection = crossSummary.direction;
  if (crossDirection != 'up') return null;

  final anchor = ctx.closes[denseEndIdx];
  final endClose = ctx.closes[trendEndIdx];
  if (anchor == 0) return null;

  if (endClose <= anchor) return null;

  final direction = 'up';
  final netMovePct = (endClose - anchor) / anchor.abs() * 100.0;
  if (netMovePct < threshold * 100.0 * 0.3) return null;

  final ma20AtDense = ctx.ma20s[denseEndIdx];
  final ma20AtEnd = ctx.ma20s[trendEndIdx];
  if (ma20AtDense == null || ma20AtEnd == null) return null;
  if (ma20AtEnd <= ma20AtDense) return null;

  var alongMa20Count = 0;
  var totalBars = 0;
  var devSum = 0.0;

  for (var i = denseEndIdx + 1; i <= trendEndIdx; i++) {
    final price = ctx.closes[i];
    final ma20 = ctx.ma20s[i];
    final ma120 = ctx.ma120s[i];
    if (ma20 == null || ma120 == null) continue;

    final prevClose = ctx.closes[i - 1];
    final prevMa120 = ctx.ma120s[i - 1];
    if (prevMa120 != null) {
      if (prevClose >= prevMa120 && price < ma120) {
        return null;
      }
    }

    totalBars += 1;
    final ma20Abs = ma20.abs();
    if (ma20Abs == 0) continue;

    final signedDev = (price - ma20) / ma20Abs;
    devSum += signedDev.abs();

    if (signedDev >= -threshold) alongMa20Count += 1;
  }

  if (totalBars < 2) return null;

  final alongMa20Pct = alongMa20Count / totalBars * 100.0;
  if (alongMa20Pct < 75.0) return null;

  return _PostDenseTrendDetection(
    direction: direction,
    denseSpread: dense.spread,
    barsSinceDense: barsSinceDense,
    netMovePct: netMovePct,
    avgMa20DevPct: devSum / totalBars * 100.0,
    alongMa20Pct: alongMa20Pct,
    startTimeUtc: bars[denseStartIdx].openTimeUtc,
    endTimeUtc: bars[trendEndIdx].openTimeUtc,
    crossUpVotes: crossSummary.upVotes,
    crossDownVotes: crossSummary.downVotes,
    denseEndIdx: denseEndIdx,
    trendEndIdx: trendEndIdx,
  );
}

/// 在已加载 K 线中寻找最近一次 6 线密集后的有效趋势（结束于最新 K 线）。
_PostDenseTrendDetection? detectPostDenseTrend(
  List<KlineBar> bars, {
  required double threshold,
}) {
  if (bars.length < 122 || threshold <= 0) return null;

  final ctx = _PostDenseTrendIndicatorContext.fromBars(bars);
  int? denseEndIdx;

  for (var i = ctx.closes.length - 2; i >= ctx.searchStart; i--) {
    final dense = dense6AtIndex(
      i,
      ctx.ema20s,
      ctx.ema60s,
      ctx.ema120s,
      ctx.ma20s,
      ctx.ma60s,
      ctx.ma120s,
      threshold,
    );
    if (dense != null && dense.ok) {
      denseEndIdx = i;
      break;
    }
  }

  if (denseEndIdx == null) return null;

  return evaluatePostDenseTrendSegment(
    ctx,
    bars,
    denseEndIdx: denseEndIdx,
    trendEndIdx: ctx.closes.length - 1,
    threshold: threshold,
  );
}

/// 回测判定：收盘价同时贴合 MA20 与 EMA20，沿叉的方向运行。
bool isAlongMa20AndEma20(
  _PostDenseTrendIndicatorContext ctx,
  int index,
  String direction,
  double threshold,
) {
  final price = ctx.closes[index];
  final ma20 = ctx.ma20s[index];
  if (ma20 == null) return false;

  final ma20Abs = ma20.abs();
  if (ma20Abs == 0) return false;

  final ema20 = ctx.ema20s[index];
  final ema20Abs = ema20.abs();
  if (ema20Abs == 0) return false;

  final maDev = (price - ma20) / ma20Abs;
  final emaDev = (price - ema20) / ema20Abs;

  if (direction == 'up') {
    return maDev >= -threshold && emaDev >= -threshold;
  }
  return maDev <= threshold && emaDev <= threshold;
}

/// 回测：在密集区内判叉，随后逐根检查 MA20+EMA20 贴线；>10 根后破势则截段记录。
const int backtestMinTrendBars = 10;

_PostDenseTrendDetection? evaluateBacktestDenseCluster(
  _PostDenseTrendIndicatorContext ctx,
  List<KlineBar> bars, {
  required int clusterStart,
  required int clusterEnd,
  required double threshold,
}) {
  final dense = dense6AtIndex(
    clusterEnd,
    ctx.ema20s,
    ctx.ema60s,
    ctx.ema120s,
    ctx.ma20s,
    ctx.ma60s,
    ctx.ma120s,
    threshold,
  );
  if (dense == null || !dense.ok) return null;

  final crossWindowStart = math.max(ctx.searchStart, clusterStart);
  final crossWindowEnd = math.min(
    ctx.closes.length - 1,
    clusterEnd + denseCrossWindowBars,
  );
  final crossSummary = resolveComprehensiveCrossDirectionInWindow(
    ema20s: ctx.ema20s,
    ema60s: ctx.ema60s,
    ema120s: ctx.ema120s,
    ma20s: ctx.ma20s,
    ma60s: ctx.ma60s,
    ma120s: ctx.ma120s,
    windowStart: crossWindowStart,
    windowEnd: crossWindowEnd,
  );
  final direction = crossSummary.direction;
  if (direction != 'up') return null;

  var trendBarCount = 0;
  int? lastTrendBar;
  var devSum = 0.0;

  for (var i = clusterEnd + 1; i < ctx.closes.length; i++) {
    if (!isAlongMa20AndEma20(ctx, i, 'up', threshold)) {
      break;
    }
    trendBarCount += 1;
    lastTrendBar = i;

    final ma20 = ctx.ma20s[i];
    final ema20 = ctx.ema20s[i];
    if (ma20 != null && ma20.abs() > 0) {
      devSum +=
          ((ctx.closes[i] - ma20).abs() / ma20.abs() +
              (ctx.closes[i] - ema20).abs() / ema20.abs()) /
          2.0;
    }
  }

  if (trendBarCount <= backtestMinTrendBars || lastTrendBar == null) {
    return null;
  }

  final anchor = ctx.closes[clusterEnd];
  if (anchor == 0) return null;

  final endClose = ctx.closes[lastTrendBar];
  if (endClose <= anchor) return null;

  return _PostDenseTrendDetection(
    direction: 'up',
    denseSpread: dense.spread,
    barsSinceDense: lastTrendBar - clusterEnd,
    netMovePct: (endClose - anchor) / anchor.abs() * 100.0,
    avgMa20DevPct: devSum / trendBarCount * 100.0,
    alongMa20Pct: 100.0,
    startTimeUtc: bars[clusterStart].openTimeUtc,
    endTimeUtc: bars[lastTrendBar].openTimeUtc,
    crossUpVotes: crossSummary.upVotes,
    crossDownVotes: crossSummary.downVotes,
    denseEndIdx: clusterEnd,
    trendEndIdx: lastTrendBar,
  );
}

/// 在历史 K 线中找出所有符合回测模型的非重叠时间段。
List<_PostDenseTrendDetection> backtestPostDenseTrendAllSegments(
  List<KlineBar> bars, {
  required double threshold,
}) {
  if (bars.length < 122 || threshold <= 0) return const [];

  final ctx = _PostDenseTrendIndicatorContext.fromBars(bars);
  final segments = <_PostDenseTrendDetection>[];
  var cursor = ctx.searchStart;

  while (cursor <= ctx.closes.length - 3) {
    final cluster = findNextDenseClusterBounds(ctx, cursor, threshold);
    if (cluster == null) break;

    final clusterStart = cluster.$1;
    final clusterEnd = cluster.$2;

    final segment = evaluateBacktestDenseCluster(
      ctx,
      bars,
      clusterStart: clusterStart,
      clusterEnd: clusterEnd,
      threshold: threshold,
    );

    if (segment != null) {
      segments.add(segment);
      cursor = segment.trendEndIdx + 1;
    } else {
      cursor = clusterEnd + 1;
    }
  }

  return segments;
}

class PostDenseTrendResult {
  final String symbol;
  final String direction;
  final double denseSpreadPct;
  final int barsSinceDense;
  final double netMovePct;
  final double avgMa20DevPct;
  final double alongMa20Pct;
  final DateTime startTimeUtc;
  final DateTime endTimeUtc;
  final int crossUpVotes;
  final int crossDownVotes;

  PostDenseTrendResult({
    required this.symbol,
    required this.direction,
    required this.denseSpreadPct,
    required this.barsSinceDense,
    required this.netMovePct,
    required this.avgMa20DevPct,
    required this.alongMa20Pct,
    required this.startTimeUtc,
    required this.endTimeUtc,
    required this.crossUpVotes,
    required this.crossDownVotes,
  });

  factory PostDenseTrendResult.fromDetection(
    String symbol,
    _PostDenseTrendDetection detection,
  ) {
    return PostDenseTrendResult(
      symbol: symbol,
      direction: detection.direction,
      denseSpreadPct: detection.denseSpread * 100.0,
      barsSinceDense: detection.barsSinceDense,
      netMovePct: detection.netMovePct,
      avgMa20DevPct: detection.avgMa20DevPct,
      alongMa20Pct: detection.alongMa20Pct,
      startTimeUtc: detection.startTimeUtc,
      endTimeUtc: detection.endTimeUtc,
      crossUpVotes: detection.crossUpVotes,
      crossDownVotes: detection.crossDownVotes,
    );
  }

  String get crossVoteLabel =>
      '金叉 ${crossUpVotes}/${crossUpVotes + crossDownVotes}';

  String get directionLabel => '↑ 上涨($crossVoteLabel)';

  String get timeRangeLabel =>
      '${formatUtcDate(startTimeUtc)} ~ ${formatUtcDateTime(endTimeUtc)}';
}

class MatchResult {
  final String symbol;
  final double spreadPct;

  MatchResult({required this.symbol, required this.spreadPct});
}

class _NewListingResult {
  final String symbol;
  final DateTime listedAt;
  final double quoteVolume;

  _NewListingResult({
    required this.symbol,
    required this.listedAt,
    required this.quoteVolume,
  });
}

class _SymbolVolume {
  final String symbol;
  final double quoteVolume;

  _SymbolVolume({required this.symbol, required this.quoteVolume});
}

class ListingVolumeResult {
  final String symbol;
  final int listingTime;
  final double quoteVolume;

  ListingVolumeResult({
    required this.symbol,
    required this.listingTime,
    required this.quoteVolume,
  });
}

class StableSymbolResult {
  final String symbol;
  final DateTime listedAt;
  final double minLow;
  final double maxHigh;
  final double rangeMultiple;
  final double quoteVolume24h;
  final int dailyBarsUsed;

  StableSymbolResult({
    required this.symbol,
    required this.listedAt,
    required this.minLow,
    required this.maxHigh,
    required this.rangeMultiple,
    required this.quoteVolume24h,
    required this.dailyBarsUsed,
  });
}
