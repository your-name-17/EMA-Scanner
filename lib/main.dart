import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show kIsWeb, debugPrint;
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Binance EMA Scanner',
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

class _EmaScannerPageState extends State<EmaScannerPage> {
  bool _isLoading = false;
  bool _cancelRequested = false;
  String _status = '';
  List<MatchResult> _matches = [];

  String interval = '1d';
  int topN = 100;
  double threshold = 0.1;
  int klinesLimit = 120;
  int workers = 8;

  late TextEditingController _topNController;
  late TextEditingController _thresholdController;
  late TextEditingController _klinesLimitController;
  late TextEditingController _workersController;

  void _log(String message) {
    debugPrint('[EMA] $message');
  }

  @override
  void initState() {
    super.initState();
    _topNController = TextEditingController(text: topN.toString());
    _thresholdController = TextEditingController(
      text: threshold.toStringAsFixed(2),
    );
    _klinesLimitController = TextEditingController(
      text: klinesLimit.toString(),
    );
    _workersController = TextEditingController(text: workers.toString());
  }

  @override
  void dispose() {
    _topNController.dispose();
    _thresholdController.dispose();
    _klinesLimitController.dispose();
    _workersController.dispose();
    super.dispose();
  }

  void _stopScan() {
    if (!_isLoading) return;
    setState(() {
      _cancelRequested = true;
      _status = '已请求终止扫描...';
    });
    _log('收到终止扫描请求');
  }

  void _clearResults() {
    setState(() {
      _matches = [];
      _status = '';
    });
    _log('已清空结果和状态');
  }

  Future<void> _startScan() async {
    if (_isLoading) return;

    final parsedTopN = int.tryParse(_topNController.text);
    final parsedThreshold = double.tryParse(_thresholdController.text);
    final parsedKlinesLimit = int.tryParse(_klinesLimitController.text);
    final parsedWorkers = int.tryParse(_workersController.text);

    if (parsedTopN == null ||
        parsedTopN <= 0 ||
        parsedThreshold == null ||
        parsedThreshold <= 0 ||
        parsedKlinesLimit == null ||
        parsedKlinesLimit < 100 ||
        parsedWorkers == null ||
        parsedWorkers <= 0) {
      setState(() {
        _status = '参数不合法，请检查 topN、threshold、klinesLimit（>=100）、workers（>0）';
      });
      _log(
        '参数不合法: topN=$parsedTopN threshold=$parsedThreshold klinesLimit=$parsedKlinesLimit workers=$parsedWorkers',
      );
      return;
    }

    topN = parsedTopN;
    threshold = parsedThreshold;
    klinesLimit = parsedKlinesLimit;
    workers = parsedWorkers;

    setState(() {
      _isLoading = true;
      _cancelRequested = false;
      _status = '开始扫描...';
      _matches = [];
    });
    _log(
      '开始扫描: interval=$interval topN=$topN threshold=$threshold klinesLimit=$klinesLimit workers=$workers',
    );

    try {
      final symbols = await fetchTopSymbolsByQuoteVolume(topN);
      if (symbols.isEmpty) {
        setState(() {
          _status = '未获取到任何 symbol';
        });
        _log('未获取到任何 symbol');
        return;
      }

      final matches = <MatchResult>[];
      final total = symbols.length;
      int idx = 0;

      Future<MatchResult?> worker(int localIdx, String symbol) async {
        if (_cancelRequested) {
          return null;
        }
        try {
          final closes = await fetchKlines(symbol, interval, klinesLimit);
          final List<double> closedCloses = closes.length > 1
              ? closes.sublist(0, closes.length - 1)
              : [];

          if (closedCloses.length < 100) {
            if (!mounted) return null;
            setState(() {
              _status = '[$localIdx/$total] $symbol 跳过(数据不足)';
            });
            _log('[$localIdx/$total] $symbol 跳过(数据不足)');
            return null;
          }

          final e7 = ema(closedCloses, 7);
          final e25 = ema(closedCloses, 25);
          final e99 = ema(closedCloses, 99);

          if (e7 == null || e25 == null || e99 == null) {
            if (!mounted) return null;
            setState(() {
              _status = '[$localIdx/$total] $symbol 跳过(EMA 计算失败)';
            });
            _log('[$localIdx/$total] $symbol 跳过(EMA 计算失败)');
            return null;
          }

          final result = isEmaConverged(e7, e25, e99, threshold);
          final spreadPct = result.spread * 100.0;

          if (result.ok) {
            final m = MatchResult(symbol: symbol, spreadPct: spreadPct);
            if (!mounted) return m;
            if (_cancelRequested) return null;
            setState(() {
              _status =
                  '[$localIdx/$total] $symbol 发现匹配 spread=${spreadPct.toStringAsFixed(4)}%';
              _matches = [...matches, m];
            });
            _log(
              '[$localIdx/$total] $symbol 发现匹配 spread=${spreadPct.toStringAsFixed(4)}%',
            );
            return m;
          } else {
            if (!mounted) return null;
            if (_cancelRequested) return null;
            setState(() {
              _status =
                  '[$localIdx/$total] $symbol 不满足阈值 spread=${spreadPct.toStringAsFixed(4)}%';
            });
            _log(
              '[$localIdx/$total] $symbol 不满足阈值 spread=${spreadPct.toStringAsFixed(4)}%',
            );
            return null;
          }
        } catch (e) {
          if (!mounted) return null;
          if (_cancelRequested) return null;
          setState(() {
            _status = '[$localIdx/$total] $symbol 失败($e)';
          });
          _log('[$localIdx/$total] $symbol 失败: $e');
          return null;
        }
      }

      var i = 0;
      final batchSize = workers;
      while (i < total) {
        if (_cancelRequested) {
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

      if (_cancelRequested) {
        setState(() {
          _status = '扫描已终止，当前匹配数量: ${matches.length}';
        });
        _log('扫描被终止，匹配数量: ${matches.length}');
      } else {
        setState(() {
          if (matches.isEmpty) {
            _status = '扫描完成，没有任何币种满足阈值条件。';
          } else {
            _status = '扫描完成，共找到 ${matches.length} 个匹配币种。';
          }
        });
        _log('扫描完成，匹配数量: ${matches.length}');
      }
    } catch (e) {
      setState(() {
        _status = '扫描失败: $e';
      });
      _log('扫描失败: $e');
    } finally {
      setState(() {
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Binance USDT EMA(7/25/99) 扫描器')),
      body: Padding(
        padding: const EdgeInsets.all(16),
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
                            DropdownMenuItem(value: '3m', child: Text('3m')),
                            DropdownMenuItem(value: '15m', child: Text('15m')),
                            DropdownMenuItem(value: '1h', child: Text('1h')),
                            DropdownMenuItem(value: '4h', child: Text('4h')),
                            DropdownMenuItem(value: '1d', child: Text('1d')),
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
                            keyboardType: const TextInputType.numberWithOptions(
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
                            keyboardType: const TextInputType.numberWithOptions(
                              decimal: true,
                            ),
                            decoration: const InputDecoration(
                              labelText: 'threshold',
                              hintText: '例如 0.1',
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
                            keyboardType: const TextInputType.numberWithOptions(
                              decimal: false,
                            ),
                            decoration: const InputDecoration(
                              labelText: 'klinesLimit',
                              hintText: '例如 120 (>=100)',
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Flexible(
                          child: TextField(
                            controller: _workersController,
                            keyboardType: const TextInputType.numberWithOptions(
                              decimal: false,
                            ),
                            decoration: const InputDecoration(
                              labelText: 'workers',
                              hintText: '并发数，例如 8',
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        ElevatedButton(
                          onPressed: _isLoading ? null : _startScan,
                          child: _isLoading
                              ? const SizedBox(
                                  height: 18,
                                  width: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Text('开始扫描'),
                        ),
                        const SizedBox(width: 8),
                        ElevatedButton(
                          onPressed: _isLoading ? _stopScan : null,
                          child: const Text('终止'),
                        ),
                        const SizedBox(width: 8),
                        OutlinedButton(
                          onPressed: _clearResults,
                          child: const Text('清空结果'),
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
            const Divider(),
            Expanded(
              child: _matches.isEmpty
                  ? const Center(
                      child: Text(
                        '暂无匹配结果',
                        style: TextStyle(color: Colors.grey),
                      ),
                    )
                  : ListView.builder(
                      itemCount: _matches.length,
                      itemBuilder: (context, index) {
                        final m = _matches[index];
                        return ListTile(
                          title: Text(m.symbol),
                          subtitle: Text(
                            'spread=${m.spreadPct.toStringAsFixed(4)}%',
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

// ===== 网络与计算逻辑 =====

// 直接访问 Binance USDT 永续合约接口，对应 Python 代码中的 BINANCE_FAPI_BASE。
const String binanceFapiBase = 'https://fapi.binance.com';

Future<dynamic> httpGetJson(
  String url, {
  Map<String, String>? params,
  int timeoutSeconds = 15,
  int maxRetries = 3,
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
          // 如需严格校验证书，可以把下面这一行去掉。
          ..badCertificateCallback =
              (X509Certificate cert, String host, int port) => true;
        // 与 curl/Python 一样，强制直连，不使用系统代理，避免某些环境下代理拦截。
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
      if ([418, 429, 500, 502, 503, 504].contains(resp.statusCode)) {
        final delay = Duration(milliseconds: 500 * attempt);
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

Future<Set<String>> fetchUsdtPerpetualSymbols() async {
  final info =
      await httpGetJson('$binanceFapiBase/fapi/v1/exchangeInfo') as dynamic;

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

Future<List<String>> fetchTopSymbolsByQuoteVolume(int topN) async {
  final usdtPerpSymbols = await fetchUsdtPerpetualSymbols();
  if (usdtPerpSymbols.isEmpty) {
    throw Exception('未能获取 USDT 永续合约列表');
  }

  final tickers =
      await httpGetJson('$binanceFapiBase/fapi/v1/ticker/24hr') as dynamic;
  if (tickers is! List) {
    throw Exception('返回数据格式异常：期望 list');
  }

  final filtered = <_SymbolVolume>[];

  for (final item in tickers) {
    if (item is! Map<String, dynamic>) continue;
    try {
      final symbol = (item['symbol'] ?? '').toString();
      if (!usdtPerpSymbols.contains(symbol)) continue;

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

Future<List<double>> fetchKlines(
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

  final closes = <double>[];
  for (final k in klines) {
    try {
      if (k is List && k.length > 4) {
        closes.add(double.parse(k[4].toString()));
      }
    } catch (_) {
      continue;
    }
  }
  return closes;
}

double? ema(List<double> values, int span) {
  if (span <= 0) {
    throw ArgumentError('span 必须为正数');
  }
  if (values.length < span) {
    return null;
  }

  final alpha = 2.0 / (span + 1.0);
  double e = values.take(span).reduce((a, b) => a + b) / span.toDouble();

  for (var i = span; i < values.length; i++) {
    final x = values[i];
    e = alpha * x + (1.0 - alpha) * e;
  }
  return e;
}

class ConvergeResult {
  final bool ok;
  final double spread;

  ConvergeResult(this.ok, this.spread);
}

ConvergeResult isEmaConverged(
  double e7,
  double e25,
  double e99,
  double threshold,
) {
  final ems = [e7, e25, e99];
  final mn = ems.reduce(math.min);
  final mx = ems.reduce(math.max);
  final mnAbs = mn.abs();
  if (mnAbs == 0) {
    return ConvergeResult(false, double.infinity);
  }
  final spread = (mx - mn) / mnAbs;
  return ConvergeResult(spread <= threshold, spread);
}

class MatchResult {
  final String symbol;
  final double spreadPct;

  MatchResult({required this.symbol, required this.spreadPct});
}

class _SymbolVolume {
  final String symbol;
  final double quoteVolume;

  _SymbolVolume({required this.symbol, required this.quoteVolume});
}
