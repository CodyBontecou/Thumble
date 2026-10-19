"""Prepare disposable demo data; never touches user preferences or app code."""
import copy, json, plistlib, uuid
from pathlib import Path
ROOT = Path(__file__).resolve().parents[3]
OUT = Path(__file__).parent
base = json.loads((ROOT/'Host/fixtures/controller-templates/v1/productivityStarter.json').read_text())['profile']
def rgb(h):
    return dict(zip(('red','green','blue'),[int(h[i:i+2],16)/255 for i in (1,3,5)]), alpha=1)
def profile(name, rows):
    p=copy.deepcopy(base); p['id']=str(uuid.uuid5(uuid.NAMESPACE_URL,'thumble-marketing/'+name)).upper(); p['name']=name;p['orientationPreference']='portrait';p['outputMode']='keyboard'
    for k in ('customization','portraitCustomization','landscapeCustomization'):
        c=p[k]; c['colorSchemePreference']='light'; c['controlScale']='standard'; c['deviceCanvas']={'frameID':'iphone-17-pro-portrait' if k!='landscapeCustomization' else 'iphone-17-pro-landscape'}
        c['backgroundLightFillStyle']={'kind':'solid','color':rgb('#F4EFE5')};c['backgroundDarkFillStyle']={'kind':'solid','color':rgb('#F4EFE5')}
        c['elements']=c['elements'][:6]; c['buttonCustomizations']=[];c['labelOverrides']=[]; c['customButtons']=[]
        c['designMetadata']['layerOrder']=[{'kind':'system','system':'top_bar_activation'}]
        c['designMetadata']['notes']='Marketing demonstration profile with real keyboard outputs.'
        for i,(e,row) in enumerate(zip(c['elements'],rows)):
            label,code,mods,glyph,icon=row
            l=e['layout']; l.update(centerX=[.27,.73][i%2],centerY=[.32,.53,.74][i//2],widthScale=1.28,heightScale=1.12,cornerRadius=22,shadowStrength=.20,fillColor=rgb('#FF6A00' if i==0 else '#272722'),foregroundColor=rgb('#FFFFFF'))
            l['icon']={'source':'sf_symbol','value':icon,'placement':'top','scale':.64,'renderingMode':'template'}
            e['label']=label;e['output']={'keyboard':{'keyCode':code,'modifiersRawValue':mods},'gamepadButtons':[]};e['defaultOutput']=copy.deepcopy(e['output'])
            e.pop('presentation',None)
            c['buttonCustomizations'] += [e['id'],copy.deepcopy(l)];c['labelOverrides'] += [e['id'],label];c['designMetadata']['layerOrder'].append({'kind':'builtin','button':e['id']})
    return p
rows1=[('Search',49,1,'⌘Space','magnifyingglass'),('Switch app',48,1,'⌘Tab','rectangle.on.rectangle'),('Copy',8,1,'⌘C','doc.on.doc'),('Paste',9,1,'⌘V','clipboard'),('Undo',6,1,'⌘Z','arrow.uturn.backward'),('Escape',53,0,'Esc','escape')]
rows2=[('Palette',35,3,'⇧⌘P','terminal'),('Quick open',35,1,'⌘P','doc.text.magnifyingglass'),('Find',3,1,'⌘F','magnifyingglass'),('Save',1,1,'⌘S','square.and.arrow.down'),('New tab',17,1,'⌘T','plus.rectangle.on.rectangle'),('Escape',53,0,'Esc','escape')]
profiles=[profile('Everyday',rows1),profile('Developer',rows2)]
presentations=[{'profileID':p['id'],'entries':[{'input':{'elementID':e['id'],'part':'primary'},'compactText':r[3],'accessibilityText':r[3]} for e,r in zip(p['customization']['elements'],rows)]} for p,rows in zip(profiles,(rows1,rows2))]
for p in profiles:(OUT/'profiles'/f"{p['name'].lower()}.json").write_text(json.dumps(p,indent=2)+'\n')
for selected in profiles:
    state={'profiles':profiles,'activeProfileID':selected['id'],'defaultProfileID':selected['id']}
    prefs={'PocketPad.gamepadConfigurationProfiles.v1':json.dumps(state).encode(),'PocketPad.gamepadCustomization.v1':json.dumps(selected['customization']).encode(),'PocketPad.iOS.bindingPresentations.v1':json.dumps(presentations).encode(),'PocketPad.iOS.hasSavedKeypadSnapshot.v1':True,'PocketPad.iOS.onboarding.completed.v1':True,'PocketPad.iOS.discordPromoDismissed.v1':True,'PocketPad.iOS.showBindingGlyphs.v1':True,'PocketPad.iOS.immersiveKeypad.v1':False,'PocketPadMac.onboarding.completed.v1':True,'PocketPad.GamepadEditor.firstKeypadOnboardingCompleted.v1':True}
    keys={p['id']:{e['id']:{'keyCode':e['output']['keyboard']['keyCode'],'modifiers':e['output']['keyboard']['modifiersRawValue']} for e in p['customization']['elements']} for p in profiles}
    outputs={pid:{eid:{'keyboard':kb,'gamepadButtons':[]} for eid,kb in rows.items()} for pid,rows in keys.items()}
    for key,value in {'PocketPadMac.keyBindings.v2':keys[selected['id']],'PocketPadMac.outputBindings.v1':outputs[selected['id']],'PocketPadMac.profileKeyBindings.v1':keys,'PocketPadMac.profileOutputBindings.v1':outputs}.items(): prefs[key]=json.dumps(value).encode()
    (OUT/'profiles'/f"{selected['name'].lower()}-preferences.plist").write_bytes(plistlib.dumps(prefs))
print('Prepared two profiles and disposable preference fixtures.')
