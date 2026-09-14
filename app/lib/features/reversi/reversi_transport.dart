import 'dart:async';
import 'dart:io';

abstract interface class ReversiTransport {
  Stream<Object?> get messages;
  void send(String message);
  Future<void> close();
}

Future<ReversiTransport> connectReversi(String url) async {
  final opening = WebSocket.connect(url);
  final socket = await opening.timeout(
    const Duration(seconds: 10),
    onTimeout: () {
      // A late connection still needs an owner to close it.
      unawaited(
        opening.then<void>((socket) async {
          await socket.close();
        }, onError: (Object _) {}),
      );
      throw TimeoutException('Connection timeout');
    },
  );
  return _SocketTransport(socket);
}

final class _SocketTransport implements ReversiTransport {
  _SocketTransport(this.socket);
  final WebSocket socket;
  @override
  Stream<Object?> get messages => socket;
  @override
  void send(String message) => socket.add(message);
  @override
  Future<void> close() async {
    await socket.close();
  }
}
