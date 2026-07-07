import 'dart:io';
import 'package:docx_to_text/docx_to_text.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';

import '../models/document.dart';

/// 文档解析结果
class ImportResult {
  final String content;
  final DocSource source;
  final String title;
  ImportResult(this.content, this.source, this.title);
}

/// 文档导入服务:解析 .docx / .pdf / .txt 为纯文本。
class ImportService {
  /// 根据文件扩展名解析文本内容
  Future<ImportResult> importFile(String path) async {
    final file = File(path);
    if (!await file.exists()) {
      throw Exception('文件不存在');
    }
    final name = _fileName(path);
    final ext = _ext(path);

    switch (ext) {
      case 'docx':
        return ImportResult(await _readDocx(file), DocSource.word, name);
      case 'pdf':
        return ImportResult(await _readPdf(file), DocSource.pdf, name);
      case 'txt':
      case 'text':
      case 'md':
        return ImportResult(await _readTxt(file), DocSource.txt, name);
      case 'doc':
        throw Exception('暂不支持旧版 .doc,请另存为 .docx 后再导入');
      default:
        throw Exception('不支持的文件类型:.$ext');
    }
  }

  Future<String> _readDocx(File file) async {
    final bytes = await file.readAsBytes();
    final text = docxToText(bytes);
    return text.trim();
  }

  Future<String> _readPdf(File file) async {
    final bytes = await file.readAsBytes();
    final PdfDocument document = PdfDocument(inputBytes: bytes);
    try {
      final extractor = PdfTextExtractor(document);
      final text = extractor.extractText();
      return text.trim();
    } finally {
      document.dispose();
    }
  }

  Future<String> _readTxt(File file) async {
    // 优先按 UTF-8,失败则回退系统编码
    try {
      return (await file.readAsString()).trim();
    } catch (_) {
      final bytes = await file.readAsBytes();
      return String.fromCharCodes(bytes).trim();
    }
  }

  String _fileName(String path) {
    final parts = path.split(RegExp(r'[/\\]'));
    return parts.isEmpty ? '文档' : parts.last;
  }

  String _ext(String path) {
    final name = _fileName(path);
    final dot = name.lastIndexOf('.');
    if (dot < 0) return '';
    return name.substring(dot + 1).toLowerCase();
  }
}
