part of 'internal_representation.dart';

// We will try to build our emails using the following structure:
// (from https://stackoverflow.com/questions/3902455/mail-multipart-alternative-vs-multipart-mixed)
// mixed
//   alternative
//     text
//     related
//       html
//       inline image
//       inline image
//   attachment
//   attachment
enum _MultipartType { alternative, mixed, related }

abstract class _IRContent extends _IROutput {
  List<_IRHeader> _header = [];

  Stream<List<int>> _outH(_IRMetaInformation metaInformation) async* {
    for (var hs in _header.map((h) => h.out(metaInformation))) yield* hs;
  }

  Stream<List<int>> _out64(
      Stream<List<int>> content, _IRMetaInformation irMetaInformation) async* {
    yield* _outH(irMetaInformation);
    yield eol8;
    yield* content
        .transform(convert.base64.encoder)
        .transform(convert.ascii.encoder)
        .transform(new StreamSplitter(splitOverLength, maxLineLength));
    yield eol8;
    yield eol8;
  }
}

abstract class _IRContentPart extends _IRContent {
  bool _active = false;
  String _boundary = _buildBoundary();
  Iterable<_IRContent> _content;

  List<int> _boundaryStart(String boundary) => to8('--$boundary$eol');
  List<int> _boundaryEnd(String boundary) => to8('--$boundary--$eol');

  // We don't want to expose the number of sent emails.
  // Only use the counter, if milliseconds hasn't changed.
  static int _counter = 0;
  static int _prevTimestamp = null;
  static String _buildBoundary() {
    var now = new DateTime.now().millisecondsSinceEpoch;
    if (now != _prevTimestamp) _counter = 0;
    _prevTimestamp = now;
    return 'mailer-?=_${_counter++}-$now';
  }

  @override
  Stream<List<int>> out(_IRMetaInformation irMetaInformation) async* {
    // If not active, don't output anything and output the nested content
    // directly.
    if (!_active) {
      assert(_content.length == 1);
      yield* _content.first.out(irMetaInformation);
      return;
    }

    // If we are active output headers and then surround embedded contents
    // with boundary lines.
    yield* _outH(irMetaInformation);
    yield eol8;
    for (var part in _content) {
      yield _boundaryStart(_boundary);
      yield* part.out(irMetaInformation);
    }
    yield _boundaryEnd(_boundary);
    yield eol8;
  }
}

Iterable<T> _follow<T>(T t, Iterable<T> ts) sync* {
  yield t;
  yield* ts;
}

class _IRContentPartMixed extends _IRContentPart {
  _IRContentPartMixed(Message message, List<_IRHeader> header) {
    var attachments = message.attachments ?? [];
    var attached = attachments.where((a) => a.location == Location.attachment);

    _active = attached.isNotEmpty;

    if (_active) {
      _header = header;
      _header.add(new _IRHeaderContentType(_boundary, _MultipartType.mixed));
      _IRContent contentAlternative =
          new _IRContentPartAlternative(message, []);
      var contentAttachments = attached.map((a) => new _IRContentAttachment(a));
      _content = _follow(contentAlternative, contentAttachments);
    } else {
      _content = [new _IRContentPartAlternative(message, header)];
    }
  }
}

class _IRContentPartAlternative extends _IRContentPart {
  _IRContentPartAlternative(Message message, List<_IRHeader> header) {
    var attachments = message.attachments ?? [];
    var hasEmbedded = attachments.any((a) => a.location == Location.inline);

    _active = message.text != null && (message.html != null || hasEmbedded);

    if (_active) {
      _header = header;
      _header
          .add(new _IRHeaderContentType(_boundary, _MultipartType.alternative));
      var contentTxt = new _IRContentText(message.text, _IRTextType.plain, []);
      var contentRelated = new _IRContentPartRelated(message, []);
      _content = [contentTxt, contentRelated];
    } else if (message.text != null) {
      // text only
      _content = [new _IRContentText(message.text, _IRTextType.plain, header)];
    } else {
      // html only
      _content = [new _IRContentPartRelated(message, header)];
    }
  }
}

class _IRContentPartRelated extends _IRContentPart {
  _IRContentPartRelated(Message message, List<_IRHeader> header) {
    var attachments = message.attachments ?? [];
    var embedded = attachments.where((a) => a.location == Location.inline);

    _active = embedded.isNotEmpty;

    if (_active) {
      _header = header;
      _header.add(new _IRHeaderContentType(_boundary, _MultipartType.related));
      _IRContent contentHtml =
          new _IRContentText(message.html, _IRTextType.html, []);
      var contentAttachments = embedded.map((a) => new _IRContentAttachment(a));
      _content = _follow(contentHtml, contentAttachments);
    } else {
      _content = [new _IRContentText(message.html, _IRTextType.html, header)];
    }
  }
}

class _IRContentAttachment extends _IRContent {
  final Attachment _attachment;

  _IRContentAttachment(this._attachment) {
    final contentType = _attachment.contentType;
    final filename = _attachment.fileName;

    _header.add(new _IRHeaderText('content-type', contentType));
    _header.add(new _IRHeaderText('content-transfer-encoding', 'base64'));

    if ((_attachment.cid ?? '').isNotEmpty) {
      _header.add(new _IRHeaderText('content-id', _attachment.cid));
    }

    String fnSuffix = '';
    if ((filename ?? '').isNotEmpty) fnSuffix = '; filename="$filename"';
    _header.add(new _IRHeaderText('content-disposition',
        '${_describeEnum(_attachment.location)}$fnSuffix'));
  }

  @override
  Stream<List<int>> out(_IRMetaInformation irMetaInformation) {
    return _out64(_attachment.asStream(), irMetaInformation);
  }
}

enum _IRTextType { plain, html }

class _IRContentText extends _IRContent {
  String _text;

  _IRContentText(String text, _IRTextType textType, List<_IRHeader> header) {
    _header = header;
    var type = _describeEnum(textType);
    _header.add(new _IRHeaderText('content-type', 'text/$type; charset=utf-8'));
    _header.add(new _IRHeaderText('content-transfer-encoding', 'base64'));

    _text = text ?? '';
  }

  @override
  Stream<List<int>> out(_IRMetaInformation irMetaInformation) {
    addEol(String s) async* {
      yield s;
      yield eol;
    }

    return _out64(
        new Stream.fromIterable([_text])
            .transform(new dart_convert.LineSplitter())
            .asyncExpand(addEol) // Replace all eols with \r\n → canonical form.
            .transform(convert.utf8.encoder),
        irMetaInformation);
  }
}
