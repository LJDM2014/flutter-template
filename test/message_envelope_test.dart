import 'package:flutter_template/core/protocol/message_envelope.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('MessageEnvelope 协议模型', () {
    const from = UserProfile(id: 'device-a', nickname: '小明');

    test('chat 消息序列化/反序列化往返一致', () {
      final envelope = MessageEnvelope(
        type: MessageType.chat,
        msgId: 'msg-1',
        from: from,
        to: kBroadcastTarget,
        timestamp: 1710000000000,
        payload: <String, dynamic>{'text': '大家好'},
      );

      final parsed = MessageEnvelope.tryParse(envelope.encode());

      expect(parsed, isNotNull);
      expect(parsed!.type, MessageType.chat);
      expect(parsed.msgId, 'msg-1');
      expect(parsed.from, from);
      expect(parsed.to, kBroadcastTarget);
      expect(parsed.timestamp, 1710000000000);
      expect(parsed.payload['text'], '大家好');
    });

    test('to 字段缺省时按广播目标处理', () {
      final parsed = MessageEnvelope.fromJson(<String, dynamic>{
        'type': 'ping',
        'timestamp': 1,
      });
      expect(parsed.to, kBroadcastTarget);
      expect(parsed.msgId, isNull);
      expect(parsed.from, isNull);
      expect(parsed.payload, isEmpty);
    });

    test('未知类型解析为 unknown 而不是抛异常', () {
      final parsed = MessageEnvelope.tryParse(
        '{"type":"future_type","timestamp":1}',
      );
      expect(parsed!.type, MessageType.unknown);
    });

    test('非法 JSON 返回 null', () {
      expect(MessageEnvelope.tryParse('not-json'), isNull);
      expect(MessageEnvelope.tryParse('["array"]'), isNull);
      expect(MessageEnvelope.tryParse(''), isNull);
    });

    test('copyWith 覆盖字段且不影响原对象', () {
      final base = MessageEnvelope(
        type: MessageType.chat,
        msgId: 'm1',
        to: kBroadcastTarget,
        timestamp: 1,
        payload: <String, dynamic>{'text': 'a'},
      );
      final forwarded = base.copyWith(from: from, timestamp: 2);
      expect(base.from, isNull);
      expect(forwarded.from, from);
      expect(forwarded.msgId, 'm1');
      expect(forwarded.payload, same(base.payload));
    });

    test('hello 消息 payload 携带设备身份', () {
      final hello = MessageEnvelope(
        type: MessageType.hello,
        timestamp: 5,
        payload: <String, dynamic>{'id': 'device-b', 'nickname': '小红'},
      );
      final parsed = MessageEnvelope.tryParse(hello.encode());
      expect(parsed!.type, MessageType.hello);
      expect(parsed.payload['id'], 'device-b');
      expect(parsed.payload['nickname'], '小红');
    });
  });

  group('UserProfile 用户身份模型', () {
    test('序列化/反序列化往返一致（含 username）', () {
      const user = UserProfile(id: 'user-1', username: 'alice', nickname: '小明');
      final parsed = UserProfile.fromJson(user.toJson());
      expect(parsed, user);
      expect(parsed.username, 'alice');
      expect(parsed.nickname, '小明');
    });

    test('旧载荷缺少 username 字段时按空串兼容', () {
      final parsed = UserProfile.fromJson(<String, dynamic>{
        'id': 'user-1',
        'nickname': '小明',
      });
      expect(parsed.username, isEmpty);
      expect(parsed.id, 'user-1');
      expect(parsed.nickname, '小明');
    });

    test('相等性包含 id / username / nickname', () {
      expect(
        const UserProfile(id: 'u', username: 'a', nickname: 'n'),
        const UserProfile(id: 'u', username: 'a', nickname: 'n'),
      );
      expect(
        const UserProfile(id: 'u', username: 'a', nickname: 'n'),
        isNot(const UserProfile(id: 'u', username: 'b', nickname: 'n')),
      );
    });
  });

  group('error 消息类型', () {
    test('error 编解码往返一致', () {
      final envelope = MessageEnvelope(
        type: MessageType.error,
        timestamp: 9,
        payload: <String, dynamic>{'code': 'INVALID_TOKEN', 'message': '登录已过期'},
      );
      final parsed = MessageEnvelope.tryParse(envelope.encode());
      expect(parsed!.type, MessageType.error);
      expect(parsed.payload['code'], 'INVALID_TOKEN');
      expect(parsed.payload['message'], '登录已过期');
    });
  });

  group('roster 成员列表（users 键 + 旧 devices 键兼容）', () {
    const alice = UserProfile(id: 'u1', username: 'alice', nickname: '甲');
    const bob = UserProfile(id: 'u2', nickname: '乙');

    test('rosterPayload 构建后可经 rosterUsersFromPayload 还原', () {
      final parsed = rosterUsersFromPayload(rosterPayload([alice, bob]));
      expect(parsed, <UserProfile>[alice, bob]);
    });

    test('兼容旧服务端的 devices 键', () {
      final legacy = <String, dynamic>{
        'devices': <Map<String, dynamic>>[
          <String, dynamic>{'id': 'u1', 'nickname': '甲'},
        ],
      };
      // 旧载荷无 username，解析为空串。
      const expected = UserProfile(id: 'u1', nickname: '甲');
      expect(rosterUsersFromPayload(legacy), <UserProfile>[expected]);
    });

    test('users 键优先于 devices 键', () {
      final both = <String, dynamic>{
        'users': <Map<String, dynamic>>[
          <String, dynamic>{'id': 'u2', 'nickname': '乙'},
        ],
        'devices': <Map<String, dynamic>>[
          <String, dynamic>{'id': 'u1', 'nickname': '甲'},
        ],
      };
      expect(rosterUsersFromPayload(both), <UserProfile>[bob]);
    });

    test('键缺失或类型非法时返回空列表', () {
      expect(rosterUsersFromPayload(<String, dynamic>{}), isEmpty);
      expect(
        rosterUsersFromPayload(<String, dynamic>{'users': 'bad'}),
        isEmpty,
      );
      expect(
        rosterUsersFromPayload(<String, dynamic>{'devices': <Object>[]}),
        isEmpty,
      );
    });
  });
}
