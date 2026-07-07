import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';

/// 朗读状态
enum TtsState { stopped, playing, paused }

/// 语音朗读服务:封装 flutter_tts,支持分句朗读与当前句回调。
///
/// 采用"逐句朗读"策略:把全文按标点切分成句子队列,
/// 每句朗读完成后自动推进下一句,并通过 [onSentenceChanged] 回调
/// 当前句索引,便于 UI 高亮。这样即使系统 TTS 不支持字级进度,
/// 也能实现句级高亮与暂停/继续。
class TtsService {
  final FlutterTts _tts = FlutterTts();

  List<String> _sentences = [];
  int _currentIndex = 0;
  TtsState _state = TtsState.stopped;

  double _rate = 0.5; // 语速 0.0~1.0
  double _pitch = 1.0; // 音调 0.5~2.0

  /// 当前朗读句子索引变化(-1 表示无)
  void Function(int index)? onSentenceChanged;

  /// 朗读状态变化
  void Function(TtsState state)? onStateChanged;

  /// 全部朗读完成
  VoidCallback? onComplete;

  TtsState get state => _state;
  int get currentIndex => _currentIndex;
  double get rate => _rate;
  double get pitch => _pitch;
  List<String> get sentences => List.unmodifiable(_sentences);

  bool _initialized = false;

  /// 初始化引擎与回调
  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;

    await _tts.setLanguage('zh-CN');
    await _tts.setSpeechRate(_rate);
    await _tts.setPitch(_pitch);
    await _tts.setVolume(1.0);
    // iOS/部分平台:等待朗读结束再返回,保证 completion 时序
    await _tts.awaitSpeakCompletion(true);

    _tts.setCompletionHandler(() {
      // 一句读完 → 读下一句
      if (_state == TtsState.playing) {
        _currentIndex++;
        _speakCurrent();
      }
    });

    _tts.setCancelHandler(() {
      _setState(TtsState.stopped);
    });

    _tts.setErrorHandler((msg) {
      debugPrint('TTS error: $msg');
      _setState(TtsState.stopped);
    });
  }

  /// 把整段文本切成句子队列
  void setText(String text) {
    _sentences = _splitSentences(text);
    _currentIndex = 0;
  }

  /// 按中英文标点切句,保留合理长度
  List<String> _splitSentences(String text) {
    final normalized = text.replaceAll('\r\n', '\n');
    // 在句末标点后插入分隔标记
    final withMarks = normalized.replaceAllMapped(
      RegExp(r'([。！？!?；;\n])'),
      (m) => '${m[1]}',
    );
    final rawParts = withMarks.split('');

    final result = <String>[];
    for (var part in rawParts) {
      final s = part.trim();
      if (s.isEmpty) continue;
      // 过长的句子(无标点长段)再按逗号/长度二次切分,避免一句太长
      if (s.length > 120) {
        result.addAll(_splitLong(s));
      } else {
        result.add(s);
      }
    }
    return result.isEmpty ? [text.trim()] : result;
  }

  List<String> _splitLong(String s) {
    final parts = <String>[];
    final byComma = s.split(RegExp(r'(?<=[,,、])'));
    var buffer = '';
    for (final seg in byComma) {
      if ((buffer + seg).length > 120 && buffer.isNotEmpty) {
        parts.add(buffer);
        buffer = seg;
      } else {
        buffer += seg;
      }
    }
    if (buffer.trim().isNotEmpty) parts.add(buffer);
    return parts;
  }

  /// 从头或从暂停处开始朗读
  Future<void> play() async {
    await init();
    if (_sentences.isEmpty) return;
    if (_currentIndex >= _sentences.length) _currentIndex = 0;
    _setState(TtsState.playing);
    await _speakCurrent();
  }

  /// 从指定句开始朗读(点击某句)
  Future<void> playFrom(int index) async {
    await init();
    if (index < 0 || index >= _sentences.length) return;
    await _tts.stop();
    _currentIndex = index;
    _setState(TtsState.playing);
    await _speakCurrent();
  }

  Future<void> _speakCurrent() async {
    if (_currentIndex >= _sentences.length) {
      _setState(TtsState.stopped);
      _currentIndex = 0;
      onSentenceChanged?.call(-1);
      onComplete?.call();
      return;
    }
    onSentenceChanged?.call(_currentIndex);
    await _tts.speak(_sentences[_currentIndex]);
  }

  /// 暂停(记住当前句,下次从本句重读)
  Future<void> pause() async {
    if (_state != TtsState.playing) return;
    _setState(TtsState.paused);
    await _tts.stop();
  }

  /// 继续
  Future<void> resume() async {
    if (_state != TtsState.paused) return;
    _setState(TtsState.playing);
    await _speakCurrent();
  }

  /// 停止并回到开头
  Future<void> stop() async {
    _setState(TtsState.stopped);
    await _tts.stop();
    _currentIndex = 0;
    onSentenceChanged?.call(-1);
  }

  Future<void> setRate(double rate) async {
    _rate = rate.clamp(0.0, 1.0);
    await _tts.setSpeechRate(_rate);
    // 变更即时生效:若正在播放,重读当前句
    if (_state == TtsState.playing) {
      await _tts.stop();
      await _speakCurrent();
    }
  }

  Future<void> setPitch(double pitch) async {
    _pitch = pitch.clamp(0.5, 2.0);
    await _tts.setPitch(_pitch);
    if (_state == TtsState.playing) {
      await _tts.stop();
      await _speakCurrent();
    }
  }

  void _setState(TtsState s) {
    _state = s;
    onStateChanged?.call(s);
  }

  Future<void> dispose() async {
    await _tts.stop();
  }
}
