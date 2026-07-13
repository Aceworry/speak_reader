import 'dart:io' show File;
import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:android_intent_plus/android_intent.dart';
import 'settings_service.dart';

/// 朗读状态
enum TtsState { stopped, playing, paused }

/// 系统可用的一个声音(来自引擎 getVoices)。
class VoiceInfo {
  final String name;
  final String locale;
  VoiceInfo(this.name, this.locale);

  @override
  String toString() => '$name ($locale)';
}

/// 语音朗读服务:支持两种模式。
///
/// - **常规模式**(dictationMode=false):连续朗读,按句切分、句级高亮,
///   用 [speechRate] 调整单词本身语速(回归第一版行为)。
/// - **听写模式**(dictationMode=true):把文本切成词组(英文按单词、
///   中文按短句),**过滤掉纯标点**,逐个播报;每词可重复 N 遍、
///   词间留 [dictationGapSeconds] 书写停顿,可整篇循环。
///
/// 两种模式共用一套 token 列表 [tokens] 与索引高亮机制。
class TtsService {
  final FlutterTts _tts = FlutterTts();

  List<String> _tokens = [];
  int _currentIndex = 0;
  TtsState _state = TtsState.stopped;

  // 播放代次:每次 stop/pause/playFrom 自增,用于取消正在进行的循环
  int _playToken = 0;

  bool dictationMode = false;

  // 常规模式参数
  double speechRate = 0.5; // 0.1~1.0

  // 听写模式参数
  int repeatCount = 2;
  double dictationGapSeconds = 2.0;
  double dictationRate = 0.4; // 听写单词语速(部分单词读太快,独立于常规语速)
  final double _repeatGapSeconds = 0.6;
  bool loop = false;

  // 音色参数
  String voiceLanguage = 'zh-CN'; // '' = 系统默认
  String? voiceName; // null = 引擎默认声音
  double pitch = 1.0; // 0.5~2.0
  List<VoiceInfo> availableVoices = [];
  List<String> availableLanguages = [];

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

    await _tts.setSpeechRate(speechRate);
    await _tts.setPitch(pitch);
    await _tts.setVolume(1.0);
    await _tts.awaitSpeakCompletion(true);
    await _tts.awaitSynthCompletion(true);

    _tts.setErrorHandler((msg) {
      debugPrint('TTS error: $msg');
    });

    await loadVoices();
    await applyVoiceSettings();
  }

  /// 枚举系统 TTS 引擎支持的语言与声音。
  Future<void> loadVoices() async {
    try {
      final langs = await _tts.getLanguages;
      if (langs is List) {
        availableLanguages = langs
            .map((e) => e?.toString() ?? '')
            .where((s) => s.isNotEmpty)
            .toSet() // 去重:个别引擎会返回重复语言码,否则下拉断言崩溃
            .toList()..sort();
      }
    } catch (e) {
      debugPrint('getLanguages failed: $e');
    }
    try {
      final voices = await _tts.getVoices;
      if (voices is List) {
        availableVoices = voices.map((v) {
          if (v is Map) {
            return VoiceInfo(
              (v['name'] ?? '').toString(),
              (v['locale'] ?? '').toString(),
            );
          }
          return VoiceInfo(v?.toString() ?? '', '');
        }).where((v) => v.name.isNotEmpty).toList();
      }
    } catch (e) {
      debugPrint('getVoices failed: $e');
    }
  }

  /// 把当前 voiceLanguage/voiceName/pitch 应用到引擎。
  /// 导出前、朗读前均会调用,保证音色一致。
  Future<void> applyVoiceSettings() async {
    try {
      if (voiceLanguage.isNotEmpty) {
        await _tts.setLanguage(voiceLanguage);
      }
      if (voiceName != null) {
        final locale = _localeForVoice(voiceName!) ?? voiceLanguage;
        await _tts.setVoice({'name': voiceName!, 'locale': locale});
      } else {
        await _tts.clearVoice();
      }
      await _tts.setPitch(pitch);
    } catch (e) {
      debugPrint('applyVoiceSettings failed: $e');
    }
  }

  String? _localeForVoice(String name) {
    for (final v in availableVoices) {
      if (v.name == name) return v.locale.isNotEmpty ? v.locale : null;
    }
    return null;
  }

  /// 应用快捷预设:设置语言、尽量按性别匹配声音、设置音调。
  /// 返回是否成功匹配到指定性别的声音(用于 UI 提示)。
  ///
  /// - system: 重置为系统默认(清空语言/声音/音调)。
  /// - 童声(gender=any 且 language 为空):保持当前声音,仅调高音调。
  /// - 其它:设置语言并尝试匹配男/女声,匹配不到回退默认声音。
  Future<bool> applyPreset(VoicePreset p) async {
    if (p == VoicePreset.system) {
      voiceLanguage = '';
      voiceName = null;
      pitch = 1.0;
      await applyVoiceSettings();
      return true;
    }
    if (p.language.isNotEmpty) voiceLanguage = p.language;
    pitch = p.pitch;
    bool matched = true;
    if (p.gender != 'any') {
      final found = _pickVoiceByGender(p.language, p.gender);
      voiceName = found?.name;
      matched = found != null;
    }
    // gender == 'any'(如童声):保持当前声音,仅靠 pitch 改变音色
    await applyVoiceSettings();
    return matched;
  }

  /// 按声音名启发式匹配性别(各引擎不统一,仅尽力而为)。
  VoiceInfo? _pickVoiceByGender(String language, String gender) {
    final base = language.split('-').first.toLowerCase();
    final pool = availableVoices.where((v) {
      final lb = v.locale.toLowerCase().replaceAll('_', '-').split('-').first;
      return base.isEmpty || lb == base;
    }).toList();
    if (pool.isEmpty) return null;
    final hints = gender == 'female' ? _femaleHints : _maleHints;
    for (final h in hints) {
      for (final v in pool) {
        if (v.name.toLowerCase().contains(h)) return v;
      }
    }
    return null;
  }

  /// 返回某语言下可用的具体声音列表(按声音名去重,避免下拉断言崩溃)。
  List<VoiceInfo> voicesForLanguage(String language) {
    final Iterable<VoiceInfo> pool;
    if (language.isEmpty) {
      pool = availableVoices;
    } else {
      final base = language.split('-').first.toLowerCase();
      pool = availableVoices.where((v) {
        final lb = v.locale.toLowerCase().replaceAll('_', '-').split('-').first;
        return lb == base;
      });
    }
    final seen = <String>{};
    final result = <VoiceInfo>[];
    for (final v in pool) {
      if (seen.add(v.name)) result.add(v);
    }
    return result;
  }

  static const _femaleHints = [
    'female', 'samantha', 'karen', 'tessa', 'fiona', 'victoria', 'moira',
    'zira', 'huihui', 'yaoyao', 'xiaoxiao', 'xiaoyi', 'sunhi', 'yuna',
    'tina', 'serena', 'amelie', 'anna', 'marie', 'sinji', 'laila',
  ];
  static const _maleHints = [
    'male', 'david', 'mark', 'daniel', 'alex', 'george', 'james', 'rishi',
    'arthur', 'oliver', 'thomas', 'kangkang', 'liangliang', 'yunfeng',
  ];

  /// 设置文本;按当前模式切分为 token。
  void setText(String text) {
    _tokens = dictationMode ? _tokenizeWords(text) : _splitSentences(text);
    _currentIndex = 0;
  }

  /// 切换模式后需要重新切分(在 UI 层调用 setText 重新灌入)
  void setModeAndText(bool dictation, String text) {
    dictationMode = dictation;
    setText(text);
  }

  /// 供音频导出复用:按听写规则切词(与朗读一致)。
  List<String> tokenizeForDictation(String text) => _tokenizeWords(text);

  // ---------- 常规模式:按句切分(第一版逻辑) ----------
  List<String> _splitSentences(String text) {
    final normalized = text.replaceAll('\r\n', '\n');
    final rawParts = normalized.split(RegExp(r'(?<=[。!?！?;;\n])'));
    final result = <String>[];
    for (var part in rawParts) {
      final s = part.trim();
      if (s.isEmpty) continue;
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

  // ---------- 听写模式:词组切分,过滤纯标点 ----------
  List<String> _tokenizeWords(String text) {
    final normalized = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (normalized.isEmpty) return [];

    final tokens = <String>[];
    // 英文词(含数字/连字符/撇号) | 连续中文
    final re = RegExp(r"[A-Za-z0-9][A-Za-z0-9'’\-]*|[一-鿿]+");
    for (final m in re.allMatches(normalized)) {
      final t = m.group(0)!;
      final isCjk = RegExp(r'[一-鿿]').hasMatch(t);
      if (isCjk) {
        tokens.addAll(_splitCjkBySentence(t));
      } else {
        final trimmed = t.trim();
        if (trimmed.isNotEmpty) tokens.add(trimmed);
      }
    }
    // re 已只匹配"英文词"和"中文串",标点与空白天然被排除
    return tokens;
  }

  /// 中文按短句切(不做词典分词):以标点为界,过长再按长度兜底。
  /// 注意:_tokenizeWords 的正则只截取连续中文,标点已不在 t 内,
  /// 因此这里主要处理"很长的一段无标点中文"。
  List<String> _splitCjkBySentence(String s) {
    final out = <String>[];
    // 连续中文串通常无标点(标点已被上层正则排除),按每 8 字兜底成短句
    if (s.length <= 12) {
      out.add(s);
    } else {
      for (var i = 0; i < s.length; i += 8) {
        out.add(s.substring(i, i + 8 > s.length ? s.length : i + 8));
      }
    }
    return out;
  }

  // ---------------- 播放控制 ----------------

  /// 当前生效语速:听写模式用 dictationRate,常规模式用 speechRate。
  double get _effectiveRate => dictationMode ? dictationRate : speechRate;

  Future<void> play() async {
    await init();
    if (_tokens.isEmpty) return;
    if (_currentIndex >= _tokens.length) _currentIndex = 0;
    await applyVoiceSettings();
    await _tts.setSpeechRate(_effectiveRate);
    _setState(TtsState.playing);
    _runLoop();
  }

  Future<void> playFrom(int index) async {
    await init();
    if (index < 0 || index >= _tokens.length) return;
    _playToken++;
    await _tts.stop();
    await applyVoiceSettings();
    await _tts.setSpeechRate(_effectiveRate);
    _currentIndex = index;
    _setState(TtsState.playing);
    _runLoop();
  }

  Future<void> pause() async {
    if (_state != TtsState.playing) return;
    _playToken++;
    _setState(TtsState.paused);
    await _tts.stop();
  }

  Future<void> resume() async {
    if (_state != TtsState.paused) return;
    await _tts.setSpeechRate(_effectiveRate);
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

  /// 实时调整常规模式语速(播放中立即重读当前句生效)
  Future<void> setSpeechRate(double rate) async {
    speechRate = rate.clamp(0.1, 1.0);
    await _tts.setSpeechRate(speechRate);
    if (_state == TtsState.playing && !dictationMode) {
      // 重读当前句以应用新语速
      _playToken++;
      final resumeIndex = _currentIndex;
      await _tts.stop();
      _currentIndex = resumeIndex;
      _setState(TtsState.playing);
      _runLoop();
    }
  }

  /// 实时调整听写模式单词语速(播放中从当前词重新生效)
  Future<void> setDictationRate(double rate) async {
    dictationRate = rate.clamp(0.1, 1.0);
    await _tts.setSpeechRate(dictationRate);
    if (_state == TtsState.playing && dictationMode) {
      _playToken++;
      final resumeIndex = _currentIndex;
      await _tts.stop();
      _currentIndex = resumeIndex;
      _setState(TtsState.playing);
      _runLoop();
    }
  }

  /// 把一段文本离线合成到 [fullPath](WAV/PCM)。使用当前音色/音调,
  /// 语速用 [rate](null 时按当前模式的生效语速)。导出前会先停止朗读。
  /// 返回是否成功(文件存在且非空)。
  /// 单次调用受引擎最大输入长度限制,长文本请由上层分块后多次调用再拼接。
  Future<bool> synthToFile(String text, String fullPath, {double? rate}) async {
    await init();
    _playToken++;
    await _tts.stop();
    await applyVoiceSettings();
    await _tts.setSpeechRate(rate ?? _effectiveRate);
    try {
      final file = File(fullPath);
      if (await file.exists()) await file.delete();
      await _tts.synthesizeToFile(text, fullPath, true).timeout(
        const Duration(seconds: 90),
        onTimeout: () => debugPrint('synthToFile timeout: $text'),
      );
      return await file.exists() && await file.length() > 44;
    } catch (e) {
      debugPrint('synthToFile error: $e');
      return false;
    }
  }

  /// 试听当前音色:用当前语言/声音/音调/语速朗读一句示例,不走切分循环。
  Future<void> speakPreview(String text) async {
    await init();
    _playToken++;
    await _tts.stop();
    await applyVoiceSettings();
    await _tts.setSpeechRate(_effectiveRate);
    await _tts.speak(text);
  }

  /// 检查某语言是否有可用声音/语言数据。
  bool hasVoiceFor(String language) {
    if (language.isEmpty) return true;
    final base = language.split('-').first.toLowerCase();
    final langHit = availableLanguages.any((l) =>
        l.toLowerCase().replaceAll('_', '-').split('-').first == base);
    return langHit || voicesForLanguage(language).isNotEmpty;
  }

  /// 跳转系统"安装 TTS 语音数据"界面;失败则跳应用商店 Google TTS 页。
  /// (Android 不允许第三方 App 把声音包打进 APK 给系统引擎加载,只能引导安装。)
  Future<void> openInstallVoiceData() async {
    try {
      final intent = AndroidIntent(
        action: 'android.speech.tts.engine.INSTALL_TTS_DATA',
      );
      await intent.launch();
    } catch (e) {
      debugPrint('INSTALL_TTS_DATA failed: $e');
      try {
        final market = AndroidIntent(
          action: 'android.intent.action.VIEW',
          data: 'market://details?id=com.google.android.tts',
        );
        await market.launch();
      } catch (e2) {
        debugPrint('open market failed: $e2');
        rethrow;
      }
    }
  }

  /// 核心播放循环:常规=逐句连读;听写=逐词组、重复、停顿。
  Future<void> _runLoop() async {
    final myToken = ++_playToken;

    while (_currentIndex < _tokens.length) {
      if (myToken != _playToken) return;
      onTokenChanged?.call(_currentIndex);

      final reps =
          dictationMode ? (repeatCount < 1 ? 1 : repeatCount) : 1;
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

      // 听写模式在词组间插入书写停顿;常规模式连读(无额外停顿)
      if (dictationMode && dictationGapSeconds > 0 &&
          _currentIndex < _tokens.length) {
        await _sleep(dictationGapSeconds);
        if (myToken != _playToken) return;
      }

      if (_currentIndex >= _tokens.length) {
        if (loop) {
          _currentIndex = 0;
          if (dictationMode && dictationGapSeconds > 0) {
            await _sleep(dictationGapSeconds);
            if (myToken != _playToken) return;
          }
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
