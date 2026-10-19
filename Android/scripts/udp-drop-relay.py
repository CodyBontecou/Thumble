"""Test-only TCP/UDP relay. Drop real datagrams mid-hold without changing Android's sender.
No payloads, pairing codes, tokens, or client addresses are logged or persisted.
"""
import socket
import threading


class UDPDropRelay:
    def __init__(self, host_port):
        self.stop = threading.Event()
        self.tcp = socket.socket()
        self.tcp.bind(('0.0.0.0', 0))
        self.port = self.tcp.getsockname()[1]
        self.tcp.listen(1)
        self.tcp.settimeout(0.2)
        self.udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.udp.bind(('0.0.0.0', self.port))
        self.udp.settimeout(0.2)
        self.forward = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.forward.connect(('127.0.0.1', host_port))
        self.host_port = host_port
        self.forwarded = 0
        self.dropped = 0
        self.dropped_ups = 0
        self.down_ids = set()
        self.sockets = [self.tcp, self.udp, self.forward]
        self.threads = []
        self.spawn(self.receive_udp)
        self.spawn(self.accept_tcp)

    def spawn(self, target, *args):
        thread = threading.Thread(target=target, args=args, daemon=True)
        self.threads.append(thread)
        thread.start()

    def receive_udp(self):
        while not self.stop.is_set():
            try:
                packet, _ = self.udp.recvfrom(65535)
            except socket.timeout:
                continue
            except OSError:
                break
            if len(self.down_ids) >= 2:
                self.dropped += 1
                if len(packet) == 56 and packet[2] == 3 and packet[21] == 2:
                    self.dropped_ups += 1
                continue
            self.forward.send(packet)
            self.forwarded += 1
            if len(packet) == 56 and packet[2] == 3 and packet[3] in (1, 6) and packet[21] == 1:
                self.down_ids.add(packet[4:20])

    def accept_tcp(self):
        while not self.stop.is_set():
            try:
                client, _ = self.tcp.accept()
            except socket.timeout:
                continue
            except OSError:
                break
            upstream = socket.create_connection(('127.0.0.1', self.host_port), timeout=5)
            upstream.settimeout(None)
            self.sockets.extend([client, upstream])
            self.spawn(self.copy, client, upstream, True)
            self.spawn(self.copy, upstream, client, False)

    def copy(self, source, destination, delay):
        try:
            while not self.stop.is_set():
                data = source.recv(65536)
                if not data:
                    break
                # Give the UDP lane a deterministic lead, so the first holds
                # prove UDP execution rather than only receiving redundant copies.
                if delay and self.stop.wait(0.075):
                    break
                destination.sendall(data)
        except OSError:
            pass
        finally:
            try:
                destination.shutdown(socket.SHUT_WR)
            except OSError:
                pass

    def summary(self):
        return {'forwardedDatagrams': self.forwarded, 'droppedDatagrams': self.dropped,
                'droppedButtonUps': self.dropped_ups, 'distinctForwardedDowns': len(self.down_ids),
                'webSocketDelayMillis': 75}

    def close(self):
        self.stop.set()
        for sock in self.sockets:
            try:
                sock.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            sock.close()
        for thread in self.threads:
            thread.join(timeout=1)
