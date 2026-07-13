import 'package:shared_preferences/shared_preferences.dart';

/// OCR 识别方式
enum OcrMode {
  offline('离线识别 (Tesseract)'),
  vision('在线视觉模型');

  const OcrMode(this.label);
  final String label;

  static OcrMode fromName(String? n) =>
      OcrMode.values.firstWhere((e) => e.name == n, orElse: () => OcrMode.offline);
}

/// 音色快捷预设:一键切换语言/口音 + 尽量匹配男/女声,童声走高音调。
///
/// 注意:Android 各 TTS 引擎对"男声/女声"的暴露方式不统一,gender 仅为
/// 尽力匹配(按声音名启发式),匹配不到时回退到该语言默认声音。
enum VoicePreset {
  system('系统默认', '', 'any', 1.0),
  zhFemale('中文·女声', 'zh-CN', 'female', 1.0),
  zhMale('中文·男声', 'zh-CN', 'male', 1.0),
  usFemale('美式·女声', 'en-US', 'female', 1.0),
  usMale('美式·男声', 'en-US', 'male', 1.0),
  ukFemale('英式·女声', 'en-GB', 'female', 1.0),
  ukMale('英式·男声', 'en-GB', 'male', 1.0),
  child('童声(高音调)', '', 'any', 1.7);

  const VoicePreset(this.label, this.language, this.gender, this.pitch);
  final String label;
  final String language; // '' 表示沿用当前/默认语言
  final String gender; // 'female' | 'male' | 'any'
  final double pitch;

  static VoicePreset fromName(String? n) =>
      VoicePreset.values.firstWhere((e) => e.name == n, orElse: () => VoicePreset.system);
}

/// 导出音频格式。Android TTS synthesizeToFile 原生只产出 WAV(PCM),
/// MP3 需额外转码依赖(会拖累 CI 构建),故 v2.0.0 仅提供 WAV。
enum AudioFormat {
  wav('WAV (推荐)');

  const AudioFormat(this.label);
  final String label;
  final String ext = 'wav';

  static AudioFormat fromName(String? n) =>
      AudioFormat.values.firstWhere((e) => e.name == n, orElse: () => AudioFormat.wav);
}

/// 应用设置持久化:翻译 API 配置 + 朗读参数默认值。
class AppSettings {
  // 翻译 API(OpenAI 兼容)
  String baseUrl;
  String apiKey;
  String model;

  // OCR 方式
  OcrMode ocrMode;

  // 朗读参数
  double wordGapSeconds; // 词间间隔(秒)
  int repeatCount; // 听写:每词重复遍数
  double dictationGapSeconds; // 听写:词间停顿(秒)
  bool loop; // 整篇读完是否循环
  double speechRate; // 常规模式语速 0.1~1.0

  // 音色选择
  VoicePreset voicePreset; // 快捷预设
  String voiceLanguage; // 语言/口音代码('' = 系统默认)
  String? voiceName; // 具体声音名(null = 引擎默认)
  double pitch; // 音调 0.5~2.0,1.0 标准

  // 音频导出
  bool autoExportAudio; // 后台自动生成音频文件
  AudioFormat audioFormat; // 导出格式

  AppSettings({
    this.baseUrl = 'https://api.openai.com/v1',
    this.apiKey = '',
    this.model = 'gpt-4o-mini',
    this.ocrMode = OcrMode.offline,
    this.wordGapSeconds = 0.3,
    this.repeatCount = 2,
    this.dictationGapSeconds = 2.0,
    this.loop = false,
    this.speechRate = 0.5,
    this.voicePreset = VoicePreset.system,
    this.voiceLanguage = 'zh-CN',
    this.voiceName,
    this.pitch = 1.0,
    this.autoExportAudio = false,
    this.audioFormat = AudioFormat.wav,
  });

  bool get translationReady => baseUrl.trim().isNotEmpty && apiKey.trim().isNotEmpty;
}

class SettingsService {
  static const _kBaseUrl = 'cfg_base_url';
  static const _kApiKey = 'cfg_api_key';
  static const _kModel = 'cfg_model';
  static const _kOcrMode = 'cfg_ocr_mode';
  static const _kWordGap = 'cfg_word_gap';
  static const _kRepeat = 'cfg_repeat';
  static const _kDictGap = 'cfg_dict_gap';
  static const _kLoop = 'cfg_loop';
  static const _kRate = 'cfg_rate';
  static const _kVoicePreset = 'cfg_voice_preset';
  static const _kVoiceLang = 'cfg_voice_lang';
  static const _kVoiceName = 'cfg_voice_name';
  static const _kPitch = 'cfg_pitch';
  static const _kAutoExport = 'cfg_auto_export';
  static const _kAudioFmt = 'cfg_audio_fmt';

  Future<AppSettings> load() async {
    final p = await SharedPreferences.getInstance();
    final def = AppSettings();
    return AppSettings(
      baseUrl: p.getString(_kBaseUrl) ?? def.baseUrl,
      apiKey: p.getString(_kApiKey) ?? def.apiKey,
      model: p.getString(_kModel) ?? def.model,
      ocrMode: OcrMode.fromName(p.getString(_kOcrMode)),
      wordGapSeconds: p.getDouble(_kWordGap) ?? def.wordGapSeconds,
      repeatCount: p.getInt(_kRepeat) ?? def.repeatCount,
      dictationGapSeconds: p.getDouble(_kDictGap) ?? def.dictationGapSeconds,
      loop: p.getBool(_kLoop) ?? def.loop,
      speechRate: p.getDouble(_kRate) ?? def.speechRate,
      voicePreset: VoicePreset.fromName(p.getString(_kVoicePreset)),
      voiceLanguage: p.getString(_kVoiceLang) ?? def.voiceLanguage,
      voiceName: p.getString(_kVoiceName),
      pitch: p.getDouble(_kPitch) ?? def.pitch,
      autoExportAudio: p.getBool(_kAutoExport) ?? def.autoExportAudio,
      audioFormat: AudioFormat.fromName(p.getString(_kAudioFmt)),
    );
  }

  Future<void> save(AppSettings s) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_kBaseUrl, s.baseUrl.trim());
    await p.setString(_kApiKey, s.apiKey.trim());
    await p.setString(_kModel, s.model.trim());
    await p.setString(_kOcrMode, s.ocrMode.name);
    await p.setDouble(_kWordGap, s.wordGapSeconds);
    await p.setInt(_kRepeat, s.repeatCount);
    await p.setDouble(_kDictGap, s.dictationGapSeconds);
    await p.setBool(_kLoop, s.loop);
    await p.setDouble(_kRate, s.speechRate);
    await p.setString(_kVoicePreset, s.voicePreset.name);
    await p.setString(_kVoiceLang, s.voiceLanguage);
    if (s.voiceName == null) {
      await p.remove(_kVoiceName);
    } else {
      await p.setString(_kVoiceName, s.voiceName!);
    }
    await p.setDouble(_kPitch, s.pitch);
    await p.setBool(_kAutoExport, s.autoExportAudio);
    await p.setString(_kAudioFmt, s.audioFormat.name);
  }
}
