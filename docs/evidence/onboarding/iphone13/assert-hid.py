import json,collections,sys
from pathlib import Path
out={}
for name in ['hid-first-pass','hid-replay']:
 rows=[json.loads(l) for l in (Path(__file__).parent / (name+'.jsonl')).read_text().splitlines()]
 assert rows and all(r['product']=='Thumble Wi-Fi Gamepad' and r['page'] in [1,9] for r in rows)
 groups=collections.defaultdict(list)
 for r in rows:groups[(r['page'],r['usage'])].append(r['value'])
 channels=[]
 for page,usage,lo,hi in [(1,u,-32768,32767) for u in [48,49,51,52]]+[(1,u,0,255)for u in[50,53]]+[(9,u,0,1)for u in[1,2,3,4,5,6,12,13,14,15]]:
  values=groups[(page,usage)]
  assert values and min(values)==lo and max(values)==hi and values[-1]==0,(name,page,usage,values[-5:])
  channels.append({'page':page,'usage':usage,'min':min(values),'max':max(values),'neutral':values[-1]==0})
 out[name]={'pass':True,'events':len(rows),'channels':channels}
(Path(__file__).parent / 'hid-summary.json').write_text(json.dumps(out,indent=2)+'\n')
print('PASS both independent raw HID captures: 4 signed axes full range, 2 triggers full range, 10 digital buttons pressed/released, all final values neutral; no other devices captured')
