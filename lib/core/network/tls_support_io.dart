import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// IO 平台：ws 用默认连接器；wss 使用接受自签证书的 HttpClient
/// （局域网中继为自签 TLS，桌面/移动端明确接受）。
WebSocketChannel connectWs(Uri uri) {
  if (uri.scheme == 'wss') {
    return IOWebSocketChannel.connect(
      uri,
      customClient: HttpClient()..badCertificateCallback = (_, _, _) => true,
    );
  }
  return WebSocketChannel.connect(uri);
}

/// 供 REST 层复用：接受自签证书的 http 客户端（https 场景专用）。
http.Client createSelfSignedHttpClient() {
  final inner = HttpClient()..badCertificateCallback = (_, _, _) => true;
  return IOClient(inner);
}
