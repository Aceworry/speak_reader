import 'dart:convert';

/// 文本文档的来源类型
enum DocSource {
  camera('拍照'),
  gallery('相册'),
  word('Word'),
  pdf('PDF'),
  txt('文本'),
  manual('手动');

  const DocSource(this.label);
  final String label;

  static DocSource fromName(String? name) {
    return DocSource.values.firstWhere(
      (e) => e.name == name,
      orElse: () => DocSource.manual,
    );
  }
}

/// 一篇导入的文本文档
class Document {
  final String id;
  String title;
  String content;
  final DocSource source;
  final int createdAt; // 毫秒时间戳

  Document({
    required this.id,
    required this.title,
    required this.content,
    required this.source,
    required this.createdAt,
  });

  /// 用于列表展示的预览文本(截断)
  String get preview {
    final trimmed = content.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (trimmed.length <= 60) return trimmed;
    return '${trimmed.substring(0, 60)}…';
  }

  String get createdAtText {
    final d = DateTime.fromMillisecondsSinceEpoch(createdAt);
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
  }

  Map<String, dynamic> toMap() => {
        'id': id,
        'title': title,
        'content': content,
        'source': source.name,
        'createdAt': createdAt,
      };

  factory Document.fromMap(Map<String, dynamic> map) => Document(
        id: map['id'] as String,
        title: (map['title'] as String?) ?? '未命名',
        content: (map['content'] as String?) ?? '',
        source: DocSource.fromName(map['source'] as String?),
        createdAt: (map['createdAt'] as int?) ??
            DateTime.fromMillisecondsSinceEpoch(0).millisecondsSinceEpoch,
      );

  String toJson() => jsonEncode(toMap());

  factory Document.fromJson(String source) =>
      Document.fromMap(jsonDecode(source) as Map<String, dynamic>);
}
