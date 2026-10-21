import 'dart:io';

/// 枚举本机非回环、非链路本地的局域网 IPv4 地址，并过滤当前不可用的地址。
///
/// 网卡断开（如网线拔出、网络切换）后其配置地址仍会被系统枚举，
/// 通过对每个地址尝试绑定临时端口验证可用性，仅返回绑定成功的地址。
Future<List<String>> listLanIpv4() async {
  final interfaces = await NetworkInterface.list(
    type: InternetAddressType.IPv4,
    includeLoopback: false,
    includeLinkLocal: false,
  );
  final addresses = <String>[];
  for (final interface in interfaces) {
    for (final address in interface.addresses) {
      if (await _isUsable(address)) {
        addresses.add(address.address);
      }
    }
  }
  return addresses;
}

/// 地址当前是否可用：能成功绑定临时端口即视为在线。
Future<bool> _isUsable(InternetAddress address) async {
  ServerSocket? socket;
  try {
    socket = await ServerSocket.bind(address, 0);
    return true;
  } catch (_) {
    return false;
  } finally {
    await socket?.close();
  }
}
