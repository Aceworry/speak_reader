import 'package:shared_preferences/shared_preferences.dart';

/// 应用设置持久化:翻译 API 配置 + 朗读参数默认值。
class AppSettings {
  // 翻译 API(OpenAI 兼容)
  String baseUrl;
  String apiKey;
  String model;

  // 朗读参数
  double wordGapSeconds; // 词间间隔(秒)
  int repeatCount; // 听写:每词重复遍数
  double dictationGapSeconds; // 听写:词间停顿(秒)
  bool loop; // 整篇读完是否循环

  AppSettings({
    this.baseUrl = 'https://api.openai.com/v1',
    this.apiKey = '',
    this.model = 'gpt-4o-mini',
    this.wordGapSeconds = 0.3,
    this.repeatCount = 2,
    this.dictationGapSeconds = 2.0,
    this.loop = false,
  });

  bool get translationReady => baseUrl.trim().isNotEmpty && apiKey.trim().isNotEmpty;
}

class SettingsService {
  static const _kBaseUrl = 'cfg_base_url';
  static const _kApiKey = 'cfg_api_key';
  static const _kModel = 'cfg_model';
  static const _kWordGap = 'cfg_word_gap';
  static const _kRepeat = 'cfg_repeat';
  static const _kDictGap = 'cfg_dict_gap';
  static const _kLoop = 'cfg_loop';

  Future<AppSettings> load() async {
    final p = await SharedPreferences.getInstance();
    final def = AppSettings();
    return AppSettings(
      baseUrl: p.getString(_kBaseUrl) ?? def.baseUrl,
      apiKey: p.getString(_kApiKey) ?? def.apiKey,
      model: p.getString(_kModel) ?? def.model,
      wordGapSeconds: p.getDouble(_kWordGap) ?? def.wordGapSeconds,
      repeatCount: p.getInt(_kRepeat) ?? def.repeatCount,
      dictationGapSeconds: p.getDouble(_kDictGap) ?? def.dictationGapSeconds,
      loop: p.getBool(_kLoop) ?? def.loop,
    );
  }

  Future<void> save(AppSettings s) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_kBaseUrl, s.baseUrl.trim());
    await p.setString(_kApiKey, s.apiKey.trim());
    await p.setString(_kModel, s.model.trim());
    await p.setDouble(_kWordGap, s.wordGapSeconds);
    await p.setInt(_kRepeat, s.repeatCount);
    await p.setDouble(_kDictGap, s.dictationGapSeconds);
    await p.setBool(_kLoop, s.loop);
  }
}
