import 'dart:io';
import 'package:flutter_tesseract_ocr/flutter_tesseract_ocr.dart';

/// 离线 OCR 服务(Tesseract)。
///
/// 不依赖 Google 服务,国产手机可用。使用 assets/tessdata 下的训练数据
/// (chi_sim + eng)。识别中英文混排。
class OcrService {
  /// 识别图片文件,返回纯文本。出错抛出带中文说明的异常。
  Future<String> recognizeFile(String imagePath) async {
    final file = File(imagePath);
    if (!await file.exists()) {
      throw Exception('图片文件不存在');
    }
    if (await file.length() == 0) {
      throw Exception('图片文件为空');
    }
    try {
      // language 用 '+' 连接,同时启用中文简体与英文
      final text = await FlutterTesseractOcr.extractText(
        imagePath,
        language: 'chi_sim+eng',
        args: {
          "preserve_interword_spaces": "1",
        },
      );
      return text.trim();
    } catch (e) {
      throw Exception('文字识别出错:$e');
    }
  }

  Future<void> dispose() async {}
}
