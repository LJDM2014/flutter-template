import 'dart:io';

import 'package:flutter_template/core/auth/account_store_io.dart';
import 'package:flutter_template/core/network/host_server.dart';
import 'package:flutter_template/core/network/server_probe_io.dart';
import 'package:flutter_template/core/network/server_resolver.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('parseHostPort', () {
    test('无端口时使用 fallbackPort', () {
      expect(parseHostPort('192.168.0.112', 9090), ('192.168.0.112', 9090));
    });
    test('携带端口时优先使用', () {
      expect(parseHostPort(' 10.0.0.5:8080 ', 9090), ('10.0.0.5', 8080));
    });
    test('非法格式返回 null', () {
      expect(parseHostPort('', 9090), isNull);
      expect(parseHostPort(':9090', 9090), isNull);
      expect(parseHostPort('a:b:c', 9090), isNull);
      expect(parseHostPort('host:0', 9090), isNull);
      expect(parseHostPort('host:99999', 9090), isNull);
      expect(parseHostPort('host:abc', 9090), isNull);
    });
  });

  group('formatHostPort', () {
    test('默认端口省略端口；自定义端口保留', () {
      expect(formatHostPort('192.168.0.112', 9090, 9090), '192.168.0.112');
      expect(formatHostPort('192.168.0.112', 8080, 9090), '192.168.0.112:8080');
    });
  });

  group('expandSubnet', () {
    test('展开 /24 网段 1~254 并排除自身', () {
      final hosts = expandSubnet('192.168.0.112');
      // 254 个可用主机地址（.0 为网络地址、.255 为广播地址），再排除自身。
      expect(hosts.length, 253);
      expect(hosts.contains('192.168.0.112'), isFalse);
      expect(hosts.contains('192.168.0.1'), isTrue);
      expect(hosts.contains('192.168.0.50'), isTrue);
      expect(hosts.contains('192.168.0.254'), isTrue);
    });
    test('10/8 与 172.16/12 私有网段可展开', () {
      expect(expandSubnet('10.1.2.3').length, 253);
      expect(expandSubnet('10.1.2.3').first, '10.1.2.1');
      expect(expandSubnet('172.16.0.9').length, 253);
      expect(expandSubnet('172.32.0.9'), isEmpty);
    });
    test('非私有/非法地址返回空', () {
      expect(expandSubnet('8.8.8.8'), isEmpty);
      expect(expandSubnet('169.254.1.1'), isEmpty);
      expect(expandSubnet('127.0.0.1'), isEmpty);
      expect(expandSubnet('not-an-ip'), isEmpty);
      expect(expandSubnet('1.2.3'), isEmpty);
      expect(expandSubnet('1.2.3.999'), isEmpty);
    });
  });

  group('ServerAddressResolver.resolve', () {
    /// 构造注入式解析器：记录探测调用顺序，[reachable] 中的主机返回可达。
    (ServerAddressResolver, List<String>) makeResolver(
      Set<String> reachable,
      List<String> localIps,
    ) {
      final calls = <String>[];
      final resolver = ServerAddressResolver(
        probe:
            (
              host,
              port, {
              Duration timeout = const Duration(milliseconds: 800),
            }) async {
              calls.add('$host:$port');
              return reachable.contains(host);
            },
        listLocalAddresses: () async => localIps,
      );
      return (resolver, calls);
    }

    test('保存地址可达时直接返回，且最先探测', () async {
      final (resolver, calls) = makeResolver({'10.0.0.5'}, []);
      final resolved = await resolver.resolve(
        savedAddress: '10.0.0.5',
        fallbackPort: 9090,
      );
      expect(resolved?.host, '10.0.0.5');
      expect(resolved?.port, 9090);
      expect(calls.first, '10.0.0.5:9090');
      expect(calls, hasLength(1));
    });

    test('保存地址不可达时回退到回环/本机地址', () async {
      final (resolver, calls) = makeResolver(
        {'192.168.0.112'},
        ['192.168.0.112'],
      );
      final resolved = await resolver.resolve(
        savedAddress: '192.168.255.10',
        fallbackPort: 9090,
      );
      expect(resolved?.host, '192.168.0.112');
      expect(calls, <String>[
        '192.168.255.10:9090',
        '127.0.0.1:9090',
        '192.168.0.112:9090',
      ]);
    });

    test('保存地址不可达时扫描同网段找到可连通主机', () async {
      final (resolver, calls) = makeResolver(
        {'192.168.0.50'},
        ['192.168.0.112'],
      );
      final resolved = await resolver.resolve(
        savedAddress: '192.168.255.10',
        fallbackPort: 9090,
      );
      expect(resolved?.host, '192.168.0.50');
      expect(calls.contains('192.168.0.50:9090'), isTrue);
      // 扫描按批并发、批间早停：命中位于第一批（.1~.64），不应探测 .65 之后。
      final scanCalls = calls.sublist(3);
      expect(scanCalls.contains('192.168.0.65:9090'), isFalse);
      expect(scanCalls.contains('192.168.0.254:9090'), isFalse);
    });

    test('全部候选不可达时返回 null', () async {
      final (resolver, _) = makeResolver({}, ['192.168.0.112']);
      final resolved = await resolver.resolve(
        savedAddress: '192.168.255.10',
        fallbackPort: 9090,
      );
      expect(resolved, isNull);
    });

    test('保存地址与本机地址重复时去重探测', () async {
      final (resolver, calls) = makeResolver(
        {'192.168.0.112'},
        ['192.168.0.112'],
      );
      final resolved = await resolver.resolve(
        savedAddress: '192.168.0.112',
        fallbackPort: 9090,
      );
      expect(resolved?.host, '192.168.0.112');
      expect(calls.where((c) => c == '192.168.0.112:9090'), hasLength(1));
    });

    test('保存了自定义端口时按该端口探测并保留', () async {
      final (resolver, calls) = makeResolver({'10.0.0.5'}, []);
      final resolved = await resolver.resolve(
        savedAddress: '10.0.0.5:8080',
        fallbackPort: 9090,
      );
      expect(resolved?.port, 8080);
      expect(calls.first, '10.0.0.5:8080');
    });
  });

  test('probeHost：运行中的中继端口可达，未监听端口不可达', () async {
    final tempDir = await Directory.systemTemp.createTemp('server_resolver');
    addTearDown(() => tempDir.delete(recursive: true));
    final status = await HostServer.instance.start(
      port: 0,
      accountStore: JsonFileAccountStore(tempDir, pbkdf2Iterations: 1000),
    );
    expect(status.running, isTrue);
    try {
      expect(
        await probeHost('127.0.0.1', status.port!),
        isTrue,
        reason: '运行中的中继端口应探测可达',
      );
      // 先占用再释放一个端口，得到确定未监听的端口号。
      final temp = await ServerSocket.bind('127.0.0.1', 0);
      final closedPort = temp.port;
      await temp.close();
      expect(
        await probeHost('127.0.0.1', closedPort),
        isFalse,
        reason: '未监听端口应探测不可达',
      );
    } finally {
      await HostServer.instance.stop();
    }
  });
}
