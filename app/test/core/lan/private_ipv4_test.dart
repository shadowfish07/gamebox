import 'package:flutter_test/flutter_test.dart';
import 'package:gamebox/core/lan/private_ipv4.dart';

void main() {
  test('accepts only canonical RFC1918 IPv4 addresses', () {
    for (final value in [
      '10.0.2.2',
      '10.255.255.255',
      '172.16.0.1',
      '172.31.255.254',
      '192.168.1.2',
    ]) {
      expect(PrivateIpv4.parse(value).address, value);
    }
    for (final value in [
      '8.8.8.8',
      '127.0.0.1',
      '169.254.1.1',
      '224.0.0.1',
      '172.15.0.1',
      '172.32.0.1',
      '192.0.2.1',
      '010.0.0.1',
      '10.0.0.256',
    ]) {
      expect(
        () => PrivateIpv4.parse(value),
        throwsFormatException,
        reason: value,
      );
    }
  });
}
