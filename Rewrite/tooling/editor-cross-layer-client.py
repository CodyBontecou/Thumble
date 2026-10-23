#!/usr/bin/env python3
"""Synthetic loopback client. Secrets travel only on inherited pipes, never logs."""
import hashlib
import json
from pathlib import Path
import socket
import ssl
import struct
import sys


def emit(value):
    print(json.dumps(value, separators=(",", ":")), flush=True)


def exact_read(stream, size):
    output = b""
    while len(output) < size:
        part = stream.recv(size - len(output))
        if not part:
            raise EOFError()
        output += part
    return output


def receive(stream):
    length = struct.unpack(">I", exact_read(stream, 4))[0]
    assert 1 <= length <= 16385
    body = exact_read(stream, length)
    assert body[0] == 1
    return json.loads(body[1:].decode("utf-8", errors="strict"))


def send(stream, value):
    payload = json.dumps(value, separators=(",", ":"), ensure_ascii=False).encode()
    assert len(payload) <= 2048
    stream.sendall(struct.pack(">I", len(payload) + 1) + b"\x01" + payload)


phase = "input"

def main():
    global phase
    config = json.loads(sys.stdin.readline())
    endpoint = config["endpoint"]
    assert endpoint["host"] == "127.0.0.1"
    phase = "tls_setup"
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    context.check_hostname = False
    context.verify_mode = ssl.CERT_NONE
    context.minimum_version = ssl.TLSVersion.TLSv1_3
    context.set_alpn_protocols(["thumble-rewrite-control/1"])
    with socket.create_connection((endpoint["host"], endpoint["port"]), timeout=4) as tcp:
        with context.wrap_socket(tcp, server_hostname="thumble-rewrite.local") as stream:
            phase = "pin_check"
            assert stream.selected_alpn_protocol() == "thumble-rewrite-control/1"
            assert hashlib.sha256(stream.getpeercert(binary_form=True)).hexdigest() == endpoint["pin"]
            enroll = config["mode"] == "enroll"
            hello = {"version": 1, "command": "hello", "controlVersion": 2 if enroll else 12,
                     "inputVersion": 1, "documentVersion": 1, "capabilitiesVersion": 1}
            if not enroll:
                hello["role"] = "management"
            phase = "hello"
            send(stream, hello)
            admitted = receive(stream)
            assert admitted["controlVersion"] == hello["controlVersion"]
            assert admitted["authorityInstanceId"] == endpoint["authority"]
            assert admitted["inputEnabled"] is False
            hello_fields = {"version", "command", "authorityInstanceId", "controlVersion", "inputVersion", "documentVersion", "capabilitiesVersion", "inputEnabled"}
            if not enroll:
                hello_fields.update({"role", "inputSessionAvailable"})
            assert set(admitted) == hello_fields
            if not enroll:
                vectors = json.loads((Path(__file__).resolve().parents[1] / "packages/fixtures/phone-editor-control-v1.json").read_text())
                expected_hello = dict(vectors["helloReply"])
                expected_hello["authorityInstanceId"] = endpoint["authority"]
                assert admitted == expected_hello
            assert admitted["version"] == 1 and admitted["command"] == "hello"
            if enroll:
                phase = "enroll"
                send(stream, {"version": 1, "command": "enroll", "authorityInstanceId": endpoint["authority"],
                              "windowId": config["offer"]["windowId"], "proof": config["offer"]["secret"],
                              "phoneId": "cross-layer-phone", "label": "Synthetic editor witness"})
                credential = receive(stream)
                phase = "enrollment_stored"
                send(stream, {"version": 1, "command": "enrollment-stored", "phoneId": credential["phoneId"],
                              "credentialEpoch": credential["credentialEpoch"]})
                assert receive(stream)["command"] == "enrollment-complete"
                emit({"credential": credential})
                return
            assert admitted["role"] == "management" and admitted["inputSessionAvailable"] is False
            credential = config["credential"]
            send(stream, {"version": 1, "command": "authenticate", "authorityInstanceId": endpoint["authority"],
                          "phoneId": credential["phoneId"], "credentialEpoch": credential["credentialEpoch"],
                          "credential": credential["credential"]})
            authenticated = receive(stream)
            assert set(authenticated) == {"version", "command", "authorityInstanceId", "phoneId", "credentialEpoch", "connectionId", "expiresAt", "inputSessionAvailable", "inputEnabled", "role"}
            assert authenticated["version"] == 1 and authenticated["command"] == "authenticated"
            assert authenticated["authorityInstanceId"] == endpoint["authority"]
            assert authenticated["phoneId"] == credential["phoneId"] and authenticated["credentialEpoch"] == credential["credentialEpoch"]
            assert authenticated["role"] == "management"
            assert authenticated["inputEnabled"] is False and authenticated["inputSessionAvailable"] is False
            request = dict(config["request"])
            request.update(version=1, connectionId=authenticated["connectionId"], authorityInstanceId=endpoint["authority"])
            request.update(config.get("extra", {}))
            send(stream, request)
            emit({"sent": True})
            try:
                emit({"reply": receive(stream)})
            except (EOFError, ssl.SSLError, ConnectionError):
                emit({"closed": True})


try:
    main()
except Exception as error:
    emit({"failed": "cross_layer_client_" + phase + "_" + type(error).__name__})
    sys.exit(1)
