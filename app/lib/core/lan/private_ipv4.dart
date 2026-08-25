final class PrivateIpv4 {
  const PrivateIpv4._(this.address);

  final String address;

  static PrivateIpv4 parse(String raw) {
    if (!RegExp(r'^(?:0|[1-9][0-9]{0,2})(?:\.(?:0|[1-9][0-9]{0,2})){3}$')
        .hasMatch(raw)) {
      throw const FormatException('invalid_private_ipv4');
    }
    final octets = raw.split('.').map(int.parse).toList(growable: false);
    if (octets.any((value) => value > 255) || !_isPrivate(octets)) {
      throw const FormatException('invalid_private_ipv4');
    }
    return PrivateIpv4._(raw);
  }

  static bool _isPrivate(List<int> octets) {
    if (octets[0] == 10) return true;
    if (octets[0] == 172 && octets[1] >= 16 && octets[1] <= 31) {
      return true;
    }
    return octets[0] == 192 && octets[1] == 168;
  }

  @override
  bool operator ==(Object other) =>
      other is PrivateIpv4 && other.address == address;

  @override
  int get hashCode => address.hashCode;

  @override
  String toString() => address;
}
