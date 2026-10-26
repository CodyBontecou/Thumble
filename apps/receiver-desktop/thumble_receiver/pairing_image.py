import base64
import io
from pathlib import Path
import time

import qrcode
from qrcode.image.pure import PyPNGImage

from .private_files import private_json


def pairing_png(invitation):
    qr = qrcode.QRCode(box_size=6, border=4, image_factory=PyPNGImage)
    qr.add_data(invitation)
    qr.make(fit=True)
    stream = io.BytesIO()
    qr.make_image().save(stream)
    return stream.getvalue()


class PairingImage:
    def __init__(self, directory, wall=time.time):
        self.path = Path(directory) / 'pairing-code.json'
        self.wall, self.invitation, self.png = wall, '', ''

    def publish(self, invitation, expires):
        if not invitation or self.wall() >= expires:
            self.clear()
            return
        if invitation != self.invitation:
            self.png = base64.b64encode(pairing_png(invitation)).decode()
            self.invitation = invitation
        private_json(self.path, dict(version=1, updatedAt=int(self.wall() * 1000),
                                     expiresAt=int(expires * 1000), png=self.png))

    def clear(self):
        self.invitation, self.png = '', ''
        self.path.unlink(missing_ok=True)
