/// Web 端实现：浏览器无法获取本机局域网 IP，始终返回空。
Future<List<String>> listLanIpv4() async => const [];
