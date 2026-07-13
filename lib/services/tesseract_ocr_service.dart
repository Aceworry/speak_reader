import 'dart:io';

import 'package:flutter_tesseract_ocr/flutter_tesseract_ocr.dart';

/// 离线文字识别(Tesseract):完全本地运行,无需 API key / 联网。
///
/// 依赖 `assets/tessdata/` 下的训练数据(chi_sim.traineddata + eng.traineddata),
/// 由 CI 在打包时下载进 assets(见 .github/workflows/build-apk.yml)。
/// 插件会在首次调用时把这些文件释放到应用可读目录再供引擎加载。
class TesseractOcrService {
  /// 识别语言:简体中文 + 英文。二者训练数据都需存在于 assets/tessdata。
  static const _language = 'chi_sim+eng';

  Future<String> recognizeFile(String imagePath) async {
    final file = File(imagePath);
    if (!await file.exists()) {
      throw Exception('图片文件不存在');
    }
    try {
      final text = await FlutterTesseractOcr.extractText(
        imagePath,
        language: _language,
        args: {
          // 自动页面分割:整页文本;preserve_interword_spaces 保留词间空格
          'psm': '3',
          'preserve_interword_spaces': '1',
        },
      );
      return text.trim();
    } catch (e) {
      throw Exception(
          '离线识别失败:$e\n(若提示缺少语言数据,可能是训练数据未随包打入;'
          '可在设置切换为「在线视觉模型」识别)');
    }
  }
}
