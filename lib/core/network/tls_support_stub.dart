import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';

/// Web 平台桩：浏览器无法在代码内放行自签证书（证书信任由浏览器策略管理，
/// 需用户先访问一次中继地址完成信任）；连接走默认实现。
WebSocketChannel connectWs(Uri uri) => WebSocketChannel.connect(uri);

http.Client createSelfSignedHttpClient() => http.Client();
