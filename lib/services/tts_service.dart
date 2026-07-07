import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';

/// 朗读状态
enum TtsState { stopped, playing, paused }

/// 语音朗读服务(逐词朗读版)。
///
/// 设计要点:
/// - 把文本切成 **token(词/短语)** 序列:英文按单词、中文按标点/短块。
/// - **逐个** speak,token 之间插入可调 [wordGapSeconds] 停顿。
///   → "变慢"靠拉长词间停顿实现,单词本身语速保持自然,不被压缩失真。
/// - **听写模式**:每个词连读 [repeatCount] 遍,词间用更长的 [dictationGapSeconds]
///   停顿(留给听写者书写),整篇可 [loop] 循环。
/// - 通过 [onTokenChanged] 回调当前 token 索引,供 UI 高亮。
class TtsService {
  final FlutterTts _tts = FlutterTts();

  List<String> _tokens = [];
  int _currentIndex = 0;
  TtsState _state = TtsState.stopped;

  // 播放代次:每次 stop/pause 自增,用于取消正在进行的播放循环
  int _playToken = 0;

  // 朗读参数(可运行时调整,下一个 token 生效)
  double wordGapSeconds = 0.3; // 普通模式词间间隔
  int repeatCount = 2; // 听写:每词重复遍数
  double dictationGapSeconds = 2.0; // 听写:词间停顿
  bool dictationMode = false; // 是否听写模式
  bool loop = false; // 整篇循环

  final double _repeatGapSeconds = 0.6; // 同一词多遍之间的短停顿

  /// 当前朗读 token 索引变化(-1 表示无)
  void Function(int index)? onTokenChanged;
  void Function(TtsState state)? onStateChanged;
  VoidCallback? onComplete;

  TtsState get state => _state;
  int get currentIndex => _currentIndex;
  List<String> get tokens => List.unmodifiable(_tokens);

  bool _initialized = false;

  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;

    await _tts.setLanguage('zh-CN');
    await _tts.setSpeechRate(0.5); // 自然语速,固定;调速交给词间间隔
    await _tts.setPitch(1.0);
    await _tts.setVolume(1.0);
    await _tts.awaitSpeakCompletion(true); // speak 等到读完再返回

    _tts.setErrorHandler((msg) {
      debugPrint('TTS error: $msg');
    });
  }

  /// 设置文本并切分为 token
  void setText(String text) {
    _tokens = _tokenize(text);
    _currentIndex = 0;
  }

  /// 分词:英文按单词,中文按标点/短块,其余符号单独成块。
  List<String> _tokenize(String text) {
    final normalized = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (normalized.isEmpty) return [];

    final tokens = <String>[];
    // 英文词(含数字、连字符、撇号) | 连续中文 | 其它可读符号
    final re = RegExp(
      r"[A-Za-z0-9][A-Za-z0-9'’\-]*"
      r"|[一-鿿]+"
      r"|[^\sA-Za-z0-9一-鿿]+",
    );
    for (final m in re.allMatches(normalized)) {
      final t = m.group(0)!;
      final isCjk = RegExp(r'[一-鿿]').hasMatch(t);
      if (isCjk) {
        // 中文长串按标点或每 4 字切成短块,避免一次读太长
        tokens.addAll(_splitCjk(t));
      } else {
        final trimmed = t.trim();
        if (trimmed.isNotEmpty) tokens.add(trimmed);
      }
    }
    return tokens;
  }

  List<String> _splitCjk(String s) {
    final out = <String>[];
    final byPunc = s.split(RegExp(r'(?<=[。!?！?,,、;;:：])'));
    for (var seg in byPunc) {
      seg = seg.trim();
      if (seg.isEmpty) continue;
      if (seg.length <= 6) {
        out.add(seg);
      } else {
        for (var i = 0; i < seg.length; i += 4) {
          out.add(seg.substring(i, i + 4 > seg.length ? seg.length : i + 4));
        }
      }
    }
    return out;
  }

  // ---------------- 播放控制 ----------------

  Future<void> play() async {
    await init();
    if (_tokens.isEmpty) return;
    if (_currentIndex >= _tokens.length) _currentIndex = 0;
    _setState(TtsState.playing);
    _runLoop();
  }

  Future<void> playFrom(int index) async {
    await init();
    if (index < 0 || index >= _tokens.length) return;
    _playToken++; // 取消现有循环
    await _tts.stop();
    _currentIndex = index;
    _setState(TtsState.playing);
    _runLoop();
  }

  Future<void> pause() async {
    if (_state != TtsState.playing) return;
    _playToken++; // 取消循环
    _setState(TtsState.paused);
    await _tts.stop();
  }

  Future<void> resume() async {
    if (_state != TtsState.paused) return;
    _setState(TtsState.playing);
    _runLoop();
  }

  Future<void> stop() async {
    _playToken++;
    _setState(TtsState.stopped);
    await _tts.stop();
    _currentIndex = 0;
    onTokenChanged?.call(-1);
  }

  /// 核心逐词循环
  Future<void> _runLoop() async {
    final myToken = ++_playToken;

    while (_currentIndex < _tokens.length) {
      if (myToken != _playToken) return; // 被取消
      onTokenChanged?.call(_currentIndex);

      final reps = dictationMode ? (repeatCount < 1 ? 1 : repeatCount) : 1;
      for (var r = 0; r < reps; r++) {
        if (myToken != _playToken) return;
        await _tts.speak(_tokens[_currentIndex]);
        if (myToken != _playToken) return;
        if (r < reps - 1) {
          await _sleep(_repeatGapSeconds);
          if (myToken != _playToken) return;
        }
      }

      _currentIndex++;

      // 词间间隔:听写模式用更长停顿
      final gap = dictationMode ? dictationGapSeconds : wordGapSeconds;
      if (gap > 0) {
        await _sleep(gap);
        if (myToken != _playToken) return;
      }

      // 整篇读完
      if (_currentIndex >= _tokens.length) {
        if (loop) {
          _currentIndex = 0;
        } else {
          break;
        }
      }
    }

    if (myToken != _playToken) return;
    _setState(TtsState.stopped);
    _currentIndex = 0;
    onTokenChanged?.call(-1);
    onComplete?.call();
  }

  Future<void> _sleep(double seconds) =>
      Future.delayed(Duration(milliseconds: (seconds * 1000).round()));

  void _setState(TtsState s) {
    _state = s;
    onStateChanged?.call(s);
  }

  Future<void> dispose() async {
    _playToken++;
    await _tts.stop();
  }
}
