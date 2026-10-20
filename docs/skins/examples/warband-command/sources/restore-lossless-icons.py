"""Reproduce the exact56×56 borderless interiors from verified64×64 PNG originals.
No resizing, filters, enhancement, palette alteration, or generated artwork.
"""
from pathlib import Path
from PIL import Image
import hashlib,json
p=Path(__file__).resolve().parent.parent
for r in json.loads((p/'sources/provenance.json').read_text()):
 info=r['wikiOriginal'];src=p/'sources'/info['file'];assert hashlib.sha1(src.read_bytes()).hexdigest()==info['apiSHA1']
 im=Image.open(src);assert im.size==(64,64);im.crop(tuple(info['crop'])).save(p/'sources'/r['pngFile'])
