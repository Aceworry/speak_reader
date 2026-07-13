import 'package:google_mlkit_translation/google_mlkit_translation.dart';
import 'package:google_mlkit_language_id/google_mlkit_language_id.dart';

/// 离线翻译(Google ML Kit On-Device Translation)。
///
/// - 用 language id 识别源语言,再用 OnDeviceTranslator 翻到目标语言。
/// - 目标语言默认中文;若源本身就是中文,则译成英文(便于中英互查)。
/// - 首次使用某语言需下载模型(约 30MB/语言),之后完全离线。
///
/// ⚠️ ML Kit 依赖 Google Play 服务,在无 GMS 的国产机上可能整体不可用。
/// 因此上层(reader_page / 设置页)对本服务的异常一律**回退在线 API**。
class OfflineTranslationService {
  final _langId = LanguageIdentifier(confidenceThreshold: 0.4);
  final _modelManager = OnDeviceTranslatorModelManager();

  /// 把 [text] 翻译为中文(源为中文时翻成英文)。失败抛异常,由上层回退在线。
  /// [downloadIfNeeded]=true 时缺模型会尝试下载(需联网,仅首次)。
  Future<String> translate(
    String text, {
    bool downloadIfNeeded = true,
  }) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) {
      throw Exception('没有可翻译的内容');
    }

    // 1) 识别源语言
    final code = await _langId.identifyLanguage(trimmed);
    if (code == 'und') {
      throw Exception('无法识别源语言,已改用在线翻译');
    }
    final source = _toTranslateLanguage(code);
    if (source == null) {
      throw Exception('离线翻译暂不支持该语言($code),已改用在线翻译');
    }

    // 2) 决定目标语言:中文↔英文,其它一律译中文
    final target = (source == TranslateLanguage.chinese)
        ? TranslateLanguage.english
        : TranslateLanguage.chinese;

    // 3) 确保两端模型就绪(缺则下载,仅首次)
    if (downloadIfNeeded) {
      await _ensureModel(source);
      await _ensureModel(target);
    }

    // 4) 翻译
    final translator =
        OnDeviceTranslator(sourceLanguage: source, targetLanguage: target);
    try {
      final result = await translator.translateText(trimmed);
      if (result.trim().isEmpty) {
        throw Exception('离线翻译无结果');
      }
      return result.trim();
    } finally {
      await translator.close();
    }
  }

  Future<void> _ensureModel(TranslateLanguage lang) async {
    final downloaded = await _modelManager.isModelDownloaded(lang.bcpCode);
    if (!downloaded) {
      // 仅在 WiFi 下下载,避免消耗流量;失败会抛异常由上层回退
      final ok = await _modelManager.downloadModel(lang.bcpCode, isWifiRequired: true);
      if (!ok) {
        throw Exception('语言模型未就绪(需 WiFi 下载),已改用在线翻译');
      }
    }
  }

  /// 把 ML Kit language-id 的语言码映射到可翻译语言(仅取常见语言)。
  TranslateLanguage? _toTranslateLanguage(String code) {
    final base = code.toLowerCase().split('-').first;
    const map = {
      'zh': TranslateLanguage.chinese,
      'en': TranslateLanguage.english,
      'ja': TranslateLanguage.japanese,
      'ko': TranslateLanguage.korean,
      'fr': TranslateLanguage.french,
      'de': TranslateLanguage.german,
      'es': TranslateLanguage.spanish,
      'ru': TranslateLanguage.russian,
      'it': TranslateLanguage.italian,
      'pt': TranslateLanguage.portuguese,
    };
    return map[base];
  }

  Future<void> dispose() async {
    await _langId.close();
  }
}
