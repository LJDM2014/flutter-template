import 'package:flutter_template/core/protocol/message_envelope.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('MessageEnvelope 协议模型', () {
    const from = DeviceProfile(id: 'device-a', nickname: '小明');

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
      final forwarded = base.copyWith(
        from: from,
        timestamp: 2,
      );
      expect(base.from, isNull);
      expect(forwarded.from, from);
      expect(forwarded.msgId, 'm1');
      expect(forwarded.payload, same(base.payload));
    });

    test('hello 消息 payload 携带设备身份', () {
      final hello = MessageEnvelope(
        type: MessageType.hello,
        timestamp: 5,
        payload: <String, dynamic>{
          'id': 'device-b',
          'nickname': '小红',
        },
      );
      final parsed = MessageEnvelope.tryParse(hello.encode());
      expect(parsed!.type, MessageType.hello);
      expect(parsed.payload['id'], 'device-b');
      expect(parsed.payload['nickname'], '小红');
    });
  });
}
