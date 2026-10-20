import 'dart:io';

/// 枚举本机非回环、非链路本地的局域网 IPv4 地址。
///
/// 用于桌面端展示可接入地址，也便于移动端确认自身网段。
Future<List<String>> listLanIpv4() async {
  final interfaces = await NetworkInterface.list(
    type: InternetAddressType.IPv4,
    includeLoopback: false,
    includeLinkLocal: false,
  );
  return [
    for (final interface in interfaces)
      for (final address in interface.addresses) address.address,
  ];
}
