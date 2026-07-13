import 'dart:io';

import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

/// 离线文字识别(Google ML Kit Text Recognition):完全本地运行,无需 API key / 联网。
///
/// 用中文识别器(同时能识别其中夹杂的英文/数字)。与离线翻译同属 ML Kit 生态,
/// 依赖 Google Play 服务;无 GMS 的机型可能不可用——上层(home_page)对异常
/// 一律回退到在线视觉模型。
///
/// ⚠️ 历史上 ML Kit 在个别机型有原生崩溃,故这里的调用点必须由上层 try-catch
/// 包裹并回退。
class MlkitOcrService {
  // 中文脚本识别器可识别中文 + 拉丁字母/数字,覆盖中英文混排场景。
  final _recognizer =
      TextRecognizer(script: TextRecognitionScript.chinese);

  Future<String> recognizeFile(String imagePath) async {
    final file = File(imagePath);
    if (!await file.exists()) {
      throw Exception('图片文件不存在');
    }
    try {
      final input = InputImage.fromFilePath(imagePath);
      final result = await _recognizer.processImage(input);
      return result.text.trim();
    } catch (e) {
      throw Exception(
          '离线识别失败:$e\n(该机型可能缺少 Google 服务;可在设置切换为「在线视觉模型」识别)');
    }
  }

  Future<void> dispose() async {
    await _recognizer.close();
  }
}
