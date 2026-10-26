# Third-party components

Thumble Receiver uses dynamically linked Qt/PySide6 libraries (LGPLv3), shiboken6,
Cryptography (Apache-2.0/BSD), qrcode (BSD), PyPNG (MIT), websockets (BSD),
python-evdev (BSD, Linux), and vgamepad/ViGEmClient (MIT, Windows).

License texts shipped with these distributions are copied into `ThirdParty/`.
Qt's LGPLv3 and GPLv3 texts are also included there. The receiver uses a directory
bundle so its dynamically linked libraries remain replaceable. No Qt library is
modified. Keep the application and `_internal` folder together when moving it.

Source and build information:

- Receiver: https://github.com/CodyBontecou/Thumble/tree/main/apps/receiver-desktop
- Qt/PySide6: https://code.qt.io/pyside/pyside-setup.git/
- Qt libraries: https://code.qt.io/qt/qtbase.git/
- Cryptography: https://github.com/pyca/cryptography
- qrcode: https://github.com/lincolnloop/python-qrcode
- PyPNG: https://gitlab.com/drj11/pypng
- websockets: https://github.com/python-websockets/websockets
- python-evdev: https://github.com/gvalkov/python-evdev
- vgamepad: https://github.com/yannbouteiller/vgamepad/tree/3f910aa8bbde49a576683db74ad5e4a0879f8a80
- ViGEmClient: https://github.com/nefarius/ViGEmClient

The ViGEmBus kernel driver is a separate installation and is not bundled. Receiver
build instructions and pinned dependencies are in `pyproject.toml`, `build.py`,
and `.github/workflows/desktop-receiver.yml` in the receiver source repository.
