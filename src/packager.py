#!/usr/bin/env python3
"""Original logo-package workflow using VectorCraft's public command API."""
import argparse, json, re, subprocess, tempfile, zipfile, html, sys, shutil, hashlib, os, math
from pathlib import Path
from htmlguide import guide
import brandfiles
ENGINE = Path(__file__).parent / 'engine' / 'vectorcraft-cli'
FORMATS = {'ai','eps','pdf','svg','png','jpg'}
VARIANTS = {'full-colour','black','white','grayscale','dark-background','custom'}
EXTRAS = {'favicon','social','email'}
TEMPLATE = '{brand}-{item}-{colour}-{mode}-{size}'
TOKENS = {'brand','item','colour','mode','size','format'}
# Web and social sets: name, canvas pixels, background, and the share of the canvas the logo may fill.
FAVICONS = [('favicon-16x16.png',16),('favicon-32x32.png',32),('apple-touch-icon.png',180),('android-chrome-192x192.png',192),('android-chrome-512x512.png',512)]
SOCIAL = [('profile-avatar','Profile avatar',800,800,'white',0.88,0.88),('linkedin-cover','LinkedIn cover',1584,396,'white',0.45,0.4),('x-header','X header',1500,500,'white',0.45,0.4),('facebook-cover','Facebook cover',1640,624,'white',0.45,0.4),('youtube-banner','YouTube banner',2560,1440,'white',0.24,0.45)]

def website_url():
    try: return json.loads(Path(__file__).with_name('branding.json').read_text()).get('website','')
    except (OSError,ValueError): return ''

def slug(s):
    return re.sub(r'[^a-zA-Z0-9_-]+', '-', s).strip('-')[:90] or 'Logo'

def run(source, commands):
    args=[str(ENGINE),'run','--in',str(source)]
    for cmd, params in commands:
        args += ['--cmd',cmd,'--params',json.dumps(params)]
    p=subprocess.run(args, capture_output=True, text=True, timeout=240, env={**os.environ,"VECTORCRAFT_NO_PREFS":"1"})
    if p.returncode: raise RuntimeError(p.stderr.strip() or p.stdout[-2000:])
    rows=[json.loads(line) for line in p.stdout.splitlines() if line.strip()]
    for row in rows:
        if 'error' in row: raise RuntimeError(str(row['error']))
    return rows

def result(rows, command):
    return next(r['result'] for r in reversed(rows) if r.get('command')==command)

def inspect(path):
    rows=run(path,[('document.inspect',{'depth':2}),('document.info',{})])
    data=result(rows,'document.info')['document']
    return {'source':str(Path(path).resolve()),'layouts':[{'index':i,'name':a.get('name') or 'Artboard-'+str(i+1)} for i,a in enumerate(data['artboards'])], 'warnings': rows[0]['result'].get('warnings',[])}

def prepare_artwork(artwork, folder, padding):
    rows=run(artwork['source'],[('document.exportForScreens',{'folder':str(folder),'artboards':[artwork['index']],'formats':[{'format':'vectorcraft'}]})])
    isolated=result(rows,'document.exportForScreens')['files'][0]
    rows=run(isolated,[('artboard.fitToArt',{'index':0}),('document.inspect',{'depth':50,'childLimit':10000})])
    d=result(rows,'document.inspect'); a=d['artboards'][0]
    def locked(nodes):
        return any(n.get('locked',False) or locked(n.get('children',[])) for n in nodes)
    if locked(d.get('layers',[])):
        raise ValueError('Unlock the selected artwork before exporting so every shape is included.')
    x,y,w,h=[a[k] for k in ('x','y','width','height')]
    if w<=0 or h<=0: raise ValueError('The selected artboard has no visible artwork.')
    pad=max(w,h)*float(padding)/100
    prep=[('artboard.fitToArt',{'index':0}),('artboard.setProps',{'index':0,'x':x-pad,'y':y-pad,'width':w+2*pad,'height':h+2*pad,'moveArt':False}),('select.all',{})]
    palette=result(run(isolated,prep+[('recolor.colors',{})]),'recolor.colors')['colors']
    return isolated,prep,palette,w,h,pad

def preflight(cfg):
    issues=[]; colours=[]
    def add(role,message,severity='warning'):
        item=dict(role=role,message=message,severity=severity)
        if item not in issues: issues.append(item)
    with tempfile.TemporaryDirectory(prefix='logo-parcel-check-') as temp:
      for li,layout in enumerate(cfg['layouts']):
        role=layout['name']
        if 'dark-background' in cfg.get('variants',[]) and not layout.get('overrides',{}).get('dark-background'):
            add(role,'Add a dark-background artwork override or turn that version off.','error')
        sources=[('full-colour',layout)]+[(v,a) for v,a in layout.get('overrides',{}).items() if v in cfg.get('variants',[])]
        for variant,art in sources:
          label=role if variant=='full-colour' else role+' / '+variant
          try:
            folder=Path(temp)/str(li)/variant;folder.mkdir(parents=True)
            isolated,prep,palette,w,h,pad=prepare_artwork(art,folder,cfg.get('padding',10))
            rows=run(isolated,[('text.missingFonts',{}),('links.list',{}),('document.info',{})])
            if variant=='full-colour':
                for message in design_notes(layout,result(rows,'document.info'),palette,(w,h),cfg): add(label,message)
            for row in rows:
                r=row.get('result',{})
                if isinstance(r,dict):
                    for warning in r.get('warnings',[]): add(label,str(warning))
            for font in result(rows,'text.missingFonts').get('fonts',[]):
                add(label,'Font unavailable: '+font['family']+'. Install it or outline the lettering in your original artwork.','error')
            for link in result(rows,'links.list').get('links',[]):
                if link.get('status')=='missing': add(label,'A linked image is missing. Relink or embed it in your artwork.','error')
                if link.get('document'): continue
                add(label,'Contains bitmap imagery. Vector exports will still contain pixels; automatic recolouring may not affect those pixels.')
                info=result(run(isolated,[('links.info',{'id':link['id']})]),'links.info')
                ppi=info.get('effectivePpi',[])
                if 'cmyk' in cfg.get('modes',[]) and ppi and min(ppi)<300:
                    add(label,'Bitmap resolution is about '+str(round(min(ppi)))+' ppi at its placed size. Confirm the intended print size; 300 ppi is a common target.')
                ratio=max(cfg.get('sizes',[1024]) or [1024])/(w+2*pad)
                if any(f in cfg.get('formats',[]) for f in ('png','jpg')) and ratio*float(info.get('width',0))>float(info.get('pixelWidth',0))+1:
                    add(label,'An image will be enlarged beyond its pixel width in the largest raster export. Supply higher-resolution artwork or use a smaller export size.')
            if variant=='full-colour':
                for c in palette:
                    value=c.get('hex','')
                    if re.fullmatch(r'#[0-9a-fA-F]{6}',value) and value.upper() not in colours: colours.append(value.upper())
                if len(palette)>1:
                    for v in ('black','white','custom'):
                        if v in cfg.get('variants',[]) and not layout.get('overrides',{}).get(v):
                            add(label,'Automatic '+v+' recolouring merges different colours. Interior shapes may disappear. Inspect the preview or supply approved artwork for that version.')
          except Exception as e: add(label,'Artwork could not be checked: '+str(e),'error')
    return {'issues':issues,'colours':colours}

def save_project(cfg):
    """A portable archive of editable artwork snapshots, previews and settings."""
    dest=Path(cfg['path']).resolve()
    with tempfile.TemporaryDirectory(prefix='logo-parcel-project-',dir=dest.parent) as temp:
        temp=Path(temp);manifest=json.loads(json.dumps(cfg['project']));manifest['version']=1
        for i,item in enumerate(manifest['items']):
            for variant,art in item['artwork'].items():
                stem=str(i)+'-'+slug(variant)
                rows=run(art['source'],[('links.list',{})])
                links=result(rows,'links.list')['links']
                if any(l.get('status')=='missing' for l in links): raise ValueError('Relink missing artwork before saving the project.')
                cmds=[]
                ids=[l['id'] for l in links if l.get('linked')]
                if ids: cmds.append(('links.embed',{'ids':ids}))
                folder=temp/stem;folder.mkdir()
                cmds.append(('document.exportForScreens',{'folder':str(folder),'artboards':[art['index']],'formats':[{'format':'vectorcraft'}]}))
                rows=run(art['source'],cmds)
                if any(r.get('command')=='links.embed' and r['result'].get('missing') for r in rows): raise ValueError('Some linked artwork could not be embedded.')
                generated=Path(result(rows,'document.exportForScreens')['files'][0])
                asset=temp/(stem+'.vectorcraft');shutil.copyfile(generated,asset);shutil.rmtree(folder)
                thumb=temp/(stem+'.png');thumbnail(asset,thumb)
                art.update(source=asset.name,index=0,thumbnail=thumb.name)
        profile=manifest.get('settings',{}).get('profile')
        if profile:
            path=Path(profile)
            if not path.is_file() or path.stat().st_size>32_000_000: raise ValueError('The project print profile is missing or too large.')
            shutil.copyfile(path,temp/'print-profile.icc');manifest['settings']['profile']='print-profile.icc'
        (temp/'project.json').write_text(json.dumps(manifest,indent=2))
        archive=temp/'saved.zip'
        with zipfile.ZipFile(archive,'w',zipfile.ZIP_DEFLATED) as z:
            for f in temp.iterdir():
                if f.is_file() and f!=archive: z.write(f,f.name)
        os.replace(archive,dest)
    return {'path':str(dest)}

def open_project(cfg):
    folder=Path(cfg['cache']).resolve();folder.mkdir(parents=True,exist_ok=True)
    with zipfile.ZipFile(cfg['path']) as z:
        entries=z.infolist()
        if len(entries)>1500 or sum(i.file_size for i in entries)>2_000_000_000: raise ValueError('This project is too large to open safely.')
        names=[i.filename for i in entries]
        if len(names)!=len(set(names)) or any(Path(n).name!=n or n in ('.','..') or '\\' in n for n in names): raise ValueError('This project contains invalid file paths.')
        manifest=json.loads(z.read('project.json'))
        if manifest.get('version')!=1 or not isinstance(manifest.get('items'),list): raise ValueError('This project version is not supported.')
        if len(manifest['items'])>100: raise ValueError('This project has too many artwork items.')
        profile=manifest.get('settings',{}).get('profile')
        if profile:
            if profile!='print-profile.icc' or profile not in names: raise ValueError('Project print profile is missing or invalid.')
            (folder/profile).write_bytes(z.read(profile));manifest['settings']['profile']=str(folder/profile)
        for item in manifest['items']:
            for art in item['artwork'].values():
                for key,ext in [('source','.vectorcraft'),('thumbnail','.png')]:
                    name=art[key]
                    if name not in names or not name.endswith(ext): raise ValueError('Project artwork is missing or invalid.')
                    (folder/name).write_bytes(z.read(name));art[key]=str(folder/name)
                art['index']=0
    return manifest


def check_template(template):
    unknown=set(re.findall(r'\{([^}]*)\}',template))-TOKENS
    if unknown: raise ValueError('Unknown filename part {'+sorted(unknown)[0]+'}. Use {brand}, {item}, {colour}, {mode}, {size} or {format}.')
    if template.count('{')!=template.count('}') or re.search(r'[{}]',re.sub(r'\{[^}]*\}','',template)): raise ValueError('Use complete filename parts such as {brand}.')
    if len(template)>120: raise ValueError('Keep the filename pattern under 120 characters.')

def filename(task, brand, template=None):
    """The delivered file name: favicons keep their web-standard names, other files follow the pattern."""
    if task.get('fixed'): return task['fixed']
    if task.get('extra'): return slug(brand)+'-'+task['item']+'-'+task['extra']+'.'+task['format']
    template=template or TEMPLATE; check_template(template)
    values={'brand':slug(brand),'item':task['item'],'colour':task['variant'],'mode':task['mode'],'size':str(task['size'])+'px' if task.get('size') else '','format':task['format']}
    name=re.sub(r'\{(\w+)\}',lambda m:values[m[1]],template)
    name=re.sub(r'[^a-zA-Z0-9_.-]+','-',name); name=re.sub(r'([-_.])[-_.]+',r'\1',name).strip('-_.')[:150]
    if not re.search(r'[a-zA-Z0-9]',name): raise ValueError('The filename pattern produces an empty name.')
    return name+'.'+task['format']

def unique_paths(paths):
    if len({p.lower() for p in paths})!=len(paths):
        raise ValueError('The filename pattern gives two files the same name. Include {colour}, {mode} and {size}, or use the standard pattern.')

def tasks(cfg):
    formats=cfg['formats']; variants=cfg['variants']; modes=cfg['modes']; sizes=cfg['sizes']; extras=cfg.get('extras',[])
    if len(sizes)!=len(set(sizes)): raise ValueError('Choose each image size only once.')
    if not formats or not set(formats)<=FORMATS: raise ValueError('Select at least one supported format.')
    if not variants or not set(variants)<=VARIANTS: raise ValueError('Select at least one colour variation.')
    if not modes or not set(modes)<={'rgb','cmyk'}: raise ValueError('Select RGB or CMYK.')
    if not set(extras)<=EXTRAS: raise ValueError('Unknown web or social set.')
    if not cfg['layouts']: raise ValueError('Add a logo and select at least one layout.')
    if not sizes or any(type(n)!=int or n<16 or n>10000 for n in sizes): raise ValueError('Raster widths must be whole numbers between 16 and 10000.')
    if not 0<=float(cfg['padding'])<=100: raise ValueError('Padding must be between 0 and 100 percent.')
    if 'custom' in variants and not re.fullmatch(r'#[0-9a-fA-F]{6}',cfg['custom']): raise ValueError('Custom colour must be a six-digit hex value, for example #E8593F.')
    out=[]
    for i,layout in enumerate(cfg['layouts']):
      name=slug(layout['name'])
      if sum(slug(l['name'])==name for l in cfg['layouts'])>1: name+='-'+str(i+1)
      for variant in variants:
       for mode in modes:
        for fmt in formats:
         if mode=='cmyk' and fmt in {'svg','png'}: continue
         for size in sizes if fmt in {'png','jpg'} else [None]:
          task=dict(id=f'{i}:{variant}:{mode}:{fmt}:{size or 0}',layout=i,role=layout['name'],item=name,variant=variant,mode=mode,format=fmt,size=size,folder=f'{name}/{mode.upper()}/{variant}')
          out.append(task)
      common=dict(layout=i,role=layout['name'],item=name,variant='full-colour',mode='rgb')
      if 'favicon' in extras:
        for fixed,px in FAVICONS:
          out.append(dict(common,id=f'{i}:favicon:{px}',format='png',size=px,folder=f'{name}/Web-and-Social/Favicons',fixed=fixed,group='Favicons',label=f'{px}×{px}',canvas=[px,px],background='white' if fixed=='apple-touch-icon.png' else 'transparent',fill=[0.82,0.82] if fixed=='apple-touch-icon.png' else [0.96,0.96]))
        out.append(dict(common,id=f'{i}:favicon:ico',format='ico',size=48,folder=f'{name}/Web-and-Social/Favicons',fixed='favicon.ico',group='Favicons',label='ICO · 16, 32, 48',background='transparent'))
      if 'social' in extras:
        for key,label,w,h,bg,fw,fh in SOCIAL:
          out.append(dict(common,id=f'{i}:social:{key}',format='png',size=w,folder=f'{name}/Web-and-Social/Social',extra=f'{key}-{w}x{h}',group='Social media',label=f'{label} · {w}×{h}',canvas=[w,h],background=bg,fill=[fw,fh]))
      if 'email' in extras:
        out.append(dict(common,id=f'{i}:email:600',format='png',size=600,folder=f'{name}/Web-and-Social/Email',extra='email-signature-600px',group='Email signature',label='Email signature · 600 px',background='transparent'))
    for t in out: t['path']=t['folder']+'/'+filename(t,cfg['brand'])
    unique_paths([t['path'] for t in out])
    if not out: raise ValueError('The selected combination produces no files. PNG and SVG require RGB.')
    if cfg.get('include') is not None:
        wanted=set(cfg['include']); out=[t for t in out if t['path'] in wanted or t['id'] in wanted]
        if not out: raise ValueError('Select at least one file in the export preview.')
    if len(out)>3000: raise ValueError('Choose fewer combinations (maximum 3000 files per package).')
    return out

def print_profile(cfg):
    """Profiles live only in the export process (VECTORCRAFT_NO_PREFS), never in the user's store."""
    path=cfg.get('profile') or ''
    if not path or 'cmyk' not in cfg['modes']: return [],[],''
    if not Path(path).is_file(): raise ValueError('The print profile file can no longer be found. Choose it again in More options.')
    loaded=result(run(cfg['layouts'][0]['source'],[('color.loadProfile',{'path':path})]),'color.loadProfile')
    if loaded.get('kind')!='cmyk': raise ValueError(Path(path).name+' is not a CMYK output profile.')
    name=loaded['name']
    return [('color.loadProfile',{'path':path}),('edit.colorSettings',{'cmyk':name})],[],name

def design_notes(layout, info, palette, art, cfg):
    """Plain-language checks run before anything is rendered."""
    role=layout['name']; checks=[]
    fonts=info.get('fonts') or []
    if fonts and (not cfg.get('outline',True) or set(cfg['formats'])-{'svg'}):
        checks.append(f'{role} contains live text ({", ".join(fonts[:4])}). Convert the text to outlines before packaging, or check every format for font substitution.')
    for key,image in (info.get('images') or {}).items():
        if image.get('linked'): checks.append(f'{role} uses a linked image ({Path(image.get("link") or key).name}). Embed it so the exports do not depend on that file.')
        elif min(image.get('width',0),image.get('height',0))<1000: checks.append(f'{role} contains a small embedded image ({image.get("width")}×{image.get("height")} px). It may look soft in large exports and print files.')
    hexes=[c['hex'] for c in palette if re.fullmatch(r'#[0-9a-fA-F]{6}',c.get('hex',''))]
    if hexes and all(brandfiles.luminance(h)>0.9 for h in hexes):
        checks.append(f'{role} is white or very light. Its full-colour version will be hard to see on white backgrounds; add a dark version for clients.')
    w,h=art
    if cfg.get('extras') and 'favicon' in cfg['extras'] and max(w,h)/max(min(w,h),1)>2.5:
        checks.append(f'{role} is wide, so its favicons will be very small. Favicons work best from a symbol.')
    return checks

def canvas_for(art, task, padding):
    """An artboard (in document units) around art [x,y,w,h] matching the task's pixel canvas."""
    x,y,w,h=art
    if 'canvas' not in task:
        pad=max(w,h)*padding/100; return x-pad,y-pad,w+2*pad,h+2*pad
    W,H=task['canvas']; fw,fh=task['fill']
    if W==H and task.get('group')=='Social media': side=math.hypot(w,h)/fw; cw=ch=side  # survives a circular crop
    else:
        ch=max(h/fh,w/fw*H/W); cw=ch*W/H
    return x+w/2-cw/2,y+h/2-ch/2,cw,ch

def colour_sheet(source, palettes, profile):
    """Merge the artwork palettes into brand colours with RGB and profile-converted CMYK values."""
    merged={}
    for role,palette in palettes:
        for c in palette:
            hex_=c.get('hex','').upper()
            if not re.fullmatch(r'#[0-9A-F]{6}',hex_): continue
            entry=merged.setdefault(hex_,{'hex':hex_,'key':c.get('key',hex_),'count':0,'items':[]})
            entry['count']+=c.get('count',1)
            if role not in entry['items']: entry['items'].append(role)
    colours=sorted(merged.values(),key=lambda c:-c['count'])[:16]
    if not colours: return []
    pre,post,_=profile
    rows=run(source,pre+[('color.convert',{'color':c['key'],'to':'cmyk'}) for c in colours]+post)
    converted=[r['result'] for r in rows if r.get('command')=='color.convert']
    for c,conv in zip(colours,converted):
        r,g,b=(int(c['hex'][i:i+2],16) for i in (1,3,5)); c['rgb']=[r,g,b]
        # Neutral greys go on the black plate, as the CMYK exports do.
        if r==g==b and not c['key'].startswith('cmyk'): c['cmyk']=[0,0,0,round((1-r/255)*100)]
        else: c['cmyk']=[round(v*100) for v in conv['values']]
    return colours

def package(cfg):
    plan=tasks(cfg)
    parent=Path(cfg['output']).expanduser().resolve()
    if not parent.is_dir(): raise ValueError('Choose an existing output folder.')
    name=slug(cfg['brand'])+'-Logo-Package'
    final=parent/name; n=2
    while final.exists() or final.with_suffix('.zip').exists():
        final=parent/(name+'-'+str(n)); n+=1
    checked=preflight(cfg)
    errors=[i['role']+': '+i['message'] for i in checked['issues'] if i['severity']=='error']
    if errors: raise ValueError('\n'.join(errors))
    warnings=[]; report=[]; checks=[i['role']+': '+i['message'] for i in checked['issues']]; palettes=[]
    profile=print_profile(cfg); pre,post,profile_name=profile
    with tempfile.TemporaryDirectory(prefix='.logo-parcel-',dir=str(parent)) as temp:
      temp=Path(temp); staging=temp/'package'; staging.mkdir()
      for li,layout in enumerate(cfg['layouts']):
        progress(cfg, 'Preparing '+layout['name'], len(report), len(plan))
        base=temp/f'layout-{li}'; base.mkdir()
        rows=run(layout['source'],[('document.exportForScreens',{'folder':str(base),'artboards':[layout['index']],'formats':[{'format':'vectorcraft'}]})])
        warnings += rows[0]['result'].get('warnings',[])
        isolated=result(rows,'document.exportForScreens')['files'][0]
        # Work on an isolated temporary document, never the user's original.
        rows=run(isolated,[('artboard.fitToArt',{'index':0}),('document.inspect',{'depth':50,'childLimit':10000}),('document.info',{})])
        d=result(rows,'document.inspect'); a=d['artboards'][0]; info=result(rows,'document.info')
        def locked(nodes):
            return any(n.get('locked',False) or locked(n.get('children',[])) for n in nodes)
        if locked(d.get('layers',[])) and any(v!='full-colour' for v in cfg['variants']):
            raise ValueError('Unlock the artwork in '+layout['name']+' before generating colour variations. This prevents partially recoloured logos.')
        rect=[a[k] for k in ('x','y','width','height')]
        if not rect: raise RuntimeError('VectorCraft returned an unknown artboard shape: '+str(a))
        x,y,w,h=rect
        pad=max(w,h)*float(cfg['padding'])/100
        prep=[('artboard.fitToArt',{'index':0}),('artboard.setProps',{'index':0,'x':x-pad,'y':y-pad,'width':w+2*pad,'height':h+2*pad,'moveArt':False}),('select.all',{})]
        palette=result(run(isolated,prep+[('recolor.colors',{})]),'recolor.colors')['colors']
        palettes.append((layout['name'],palette)); checks+=design_notes(layout,info,palette,(w,h),cfg)
        original=(isolated,prep,palette,x,y,w,h,pad)
        for variant in cfg['variants']:
          isolated,prep,palette,x,y,w,h,pad=original
          override=layout.get('overrides',{}).get(variant)
          if variant=='dark-background' and not override: raise ValueError('Add approved dark-background artwork for '+layout['name']+'.')
          if override:
              folder=temp/f'override-{li}-{variant}';folder.mkdir()
              isolated,prep,palette,w,h,pad=prepare_artwork(override,folder,cfg['padding'])
              x=prep[1][1]['x']+pad;y=prep[1][1]['y']+pad
          for mode in cfg['modes']:
            batch=[t for t in plan if t['layout']==li and t['variant']==variant and t['mode']==mode and not t.get('group')]
            if not batch: continue
            progress(cfg, 'Rendering '+layout['name']+' · '+variant+' · '+mode.upper(), len(report), len(plan))
            cmds=(pre if mode=='cmyk' else [])+list(prep)
            if not override and variant in {'black','white','custom'}:
                color={'black':'#000000','white':'#ffffff','custom':cfg['custom']}[variant]
                cmds.append(('recolor.apply',{'map':{c['key']:color for c in palette}}))
            elif not override and variant=='grayscale':
                cmds.append(('edit.colors.toGrayscale',{}))
            cmds.append(('file.documentColorMode',{'mode':mode,'convert':True,'grays':'black'}))
            for task in batch:
                dest=staging/task['path']; dest.parent.mkdir(parents=True,exist_ok=True)
                opts={'path':str(dest),'format':task['format'],'artboard':0,'background':'black' if variant in {'white','dark-background'} and task['format']=='jpg' else 'transparent','quality':95}
                if task['size']:
                    if task['size']*(h+2*pad)/(w+2*pad)>10000: raise ValueError('This artwork is very tall. Choose a smaller image width.')
                    opts['scale']=task['size']/(w+2*pad)
                if task['format']=='jpg': opts['colorModel']=mode
                if task['format']=='eps': opts.update(cmykPostScript=mode=='cmyk',previewFormat='none',useArtboards=True)
                if task['format']=='svg': opts.update(outlineText=cfg.get('outline',True),images='embed')
                cmds.append(('document.export',opts))
            rows=run(isolated,cmds+(post if mode=='cmyk' else []))
            collect(rows,batch,staging,warnings,report)
        isolated,prep,palette,x,y,w,h,pad=original
        extras=[t for t in plan if t['layout']==li and t.get('group')]
        if extras:
            progress(cfg, 'Rendering web and social files for '+layout['name'], len(report), len(plan))
            cmds=[('artboard.fitToArt',{'index':0}),('file.documentColorMode',{'mode':'rgb','convert':True,'grays':'black'})]; rendered=[]
            for task in extras:
                dest=staging/task['path']; dest.parent.mkdir(parents=True,exist_ok=True)
                if task['format']=='ico':
                    for px in (16,32,48):
                        part=dict(task,canvas=[px,px],fill=[0.96,0.96],size=px)
                        rendered.append((None,part,temp/f'ico-{li}-{px}.png'))
                else: rendered.append((task,task,dest))
            for _,task,dest in rendered:
                cx,cy,cw,ch=canvas_for((x,y,w,h),task,0 if task.get('extra')=='email-signature-600px' else float(cfg['padding']))
                cmds.append(('artboard.setProps',{'index':0,'x':cx,'y':cy,'width':cw,'height':ch,'moveArt':False}))
                cmds.append(('document.export',{'path':str(dest),'format':'png','artboard':0,'scale':task['size']/cw,'background':task['background']}))
            rows=run(isolated,cmds)
            collect(rows,[t for t,_,_ in rendered if t],staging,warnings,report,[t is not None for t,_,_ in rendered])
            for task in [t for t in extras if t['format']=='ico']:
                parts=[(temp/f'ico-{li}-{px}.png') for px in (16,32,48)]
                if not all(p.is_file() and p.stat().st_size for p in parts): raise RuntimeError('Export was not produced: '+task['path'])
                (staging/task['path']).write_bytes(brandfiles.ico([p.read_bytes() for p in parts])); report.append(task)
      colours=colour_sheet(cfg['layouts'][0]['source'],palettes,profile)
      notes=['AI is VectorCraft’s PDF-compatible AI export, not Adobe-native private editing data.','PNG and SVG are RGB only. CMYK applies to PDF, EPS, AI and JPEG.','White and dark-background JPEGs use a black background. Transparent formats retain transparency.','CMYK conversion uses '+(profile_name if profile_name else 'VectorCraft’s generic CMYK profile')+'. Confirm the printer’s required ICC profile before production.','Layout names come from approved artboards. New logo arrangements are not invented.','SVG text is outlined when selected; other formats use their VectorCraft defaults.']
      if colours: notes.append('Brand colour CMYK values are converted with the same profile as the print files. Pantone references are supplied by the designer, not calculated.')
      warnings=list(dict.fromkeys(warnings)); checks=list(dict.fromkeys(checks))
      (staging/'export-report.json').write_text(json.dumps({'files':report,'warnings':warnings,'checks':checks,'notes':notes,'colours':colours,'padding':cfg['padding'],'profile':profile_name},indent=2))
      (staging/'START-HERE.html').write_text(guide(cfg['brand'],report,warnings,notes,website=website_url(),colours=colours),encoding='utf-8')
      archive=temp/'package.zip'
      with zipfile.ZipFile(archive,'w',zipfile.ZIP_DEFLATED) as z:
        for p in staging.rglob('*'):
          if p.is_file(): z.write(p,str(Path(final.name)/p.relative_to(staging)))
      shutil.move(str(staging),str(final)); shutil.move(str(archive),str(final)+'.zip')
    return {'folder':str(final),'zip':str(final)+'.zip','count':len(report),'warnings':warnings,'checks':checks}

def collect(rows, batch, staging, warnings, report, keep=None):
    """Check each document.export of a run produced its file, in order. keep: which exports belong to batch."""
    for row in rows:
        warnings.extend(row.get('result',{}).get('warnings',[]) if isinstance(row.get('result'),dict) else [])
    exports=[r['result'] for r in rows if r.get('command')=='document.export']
    if keep is not None: exports=[e for e,k in zip(exports,keep) if k]
    if len(exports)!=len(batch): raise RuntimeError("The export engine returned an incomplete file set. Please rebuild the preview.")
    for task, exported in zip(batch,exports):
        file=staging/task['path']
        if not file.exists() and exported.get('files') and len(exported['files'])==1:
            Path(exported['files'][0]).rename(file)
        if not file.is_file() or file.stat().st_size==0: raise RuntimeError('Export was not produced: '+task['path'])
        report.append(task)

def progress(cfg, message, completed=0, total=1):
    if cfg.get('progress'):
        p=Path(cfg['progress']); tmp=p.with_suffix('.new')
        tmp.write_text(json.dumps({'message':message,'completed':completed,'total':total}))
        tmp.replace(p)

def thumbnail(source, target, artboard=0, reread=False):
    """Render the file's visible content, not its embedded editable copy."""
    opened=[('document.open',{'path':str(source),'editingData':False})] if reread else []
    rows=run(source,opened+[('document.inspect',{'depth':0})])
    a=result(rows,'document.inspect')['artboards'][artboard]
    scale=480/max(a['width'],a['height'],1)
    rows=run(source,opened+[('document.export',{'path':str(target),'format':'png','artboard':artboard,'scale':scale,'background':'transparent'})])
    return [w for r in rows for w in (r.get('result',{}).get('warnings',[]) if isinstance(r.get('result'),dict) else [])]

def inspect_with_previews(cfg):
    folder=Path(cfg['cache']); folder.mkdir(parents=True,exist_ok=True)
    d=inspect(cfg['source']); warnings=list(d['warnings'])
    if len(d['layouts'])>100: raise ValueError('This file has more than 100 artboards. Save the logo artboards in a smaller file first.')
    for layout in d['layouts']:
        dest=folder/f'artboard-{layout["index"]}.png'
        warnings += thumbnail(cfg['source'],dest,layout['index'])
        layout['thumbnail']=str(dest)
    d['warnings']=list(dict.fromkeys(warnings))
    return d

def reopen(cfg):
    """Re-read the artwork of a recent project. Missing or changed files are reported, not fatal."""
    folder=Path(cfg['cache']); folder.mkdir(parents=True,exist_ok=True); out=[]; warnings=[]
    for i,item in enumerate(cfg['items']):
        progress(cfg,'Reopening '+item['role'],i,len(cfg['items']))
        entry={'role':item['role'],'source':item['source'],'index':item['index'],'thumbnail':'','boardName':'','missing':True}
        if Path(item['source']).is_file():
            try:
                d=inspect(item['source']); boards={l['index']:l for l in d['layouts']}
                if item['index'] in boards:
                    dest=folder/f'{i}.png'; warnings+=thumbnail(item['source'],dest,item['index'])
                    entry.update(thumbnail=str(dest),boardName=boards[item['index']]['name'],missing=False)
            except Exception: pass  # Treated as missing: the user picks the artwork again.
        out.append(entry)
    return {'items':out,'warnings':list(dict.fromkeys(warnings))}

def profiles(cfg):
    return {'profiles':brandfiles.cmyk_profiles()}

def prepare(cfg):
    """Generate once for review. Final delivery copies exactly these reviewed bytes."""
    cache=Path(cfg['cache']); cache.mkdir(parents=True,exist_ok=True)
    config={**cfg,'brand':'Logo','output':str(cache)}; config.pop('include',None)
    packaged=package(config); folder=Path(packaged['folder'])
    report=json.loads((folder/'export-report.json').read_text())
    thumbdir=cache/'thumbnails'; thumbdir.mkdir(exist_ok=True)
    for i,task in enumerate(report['files']):
        progress(cfg,'Building visual previews',i,len(report['files']))
        src=folder/task['path']; task['sha256']=hashlib.sha256(src.read_bytes()).hexdigest()
        thumb=thumbdir/f'{i}.png'
        try:
            if task['format']=='png': shutil.copyfile(src,thumb)
            elif task['format']=='ico': thumb.write_bytes(brandfiles.largest_ico_png(src.read_bytes()))
            else: thumbnail(src,thumb,reread=task['format'] in {'pdf','ai','eps'})
            task['thumbnail']=str(thumb)
        except Exception as e:
            raise RuntimeError('Could not preview '+task['path']+'. '+str(e))
    report['sourceBrand']='Logo'
    (folder/'export-report.json').write_text(json.dumps(report,indent=2))
    Path(packaged['zip']).unlink()  # This is an internal preview archive, never delivered.
    progress(cfg,'Preview ready',len(report['files']),len(report['files']))
    return {'prepared':str(folder),'files':report['files'],'warnings':report['warnings'],'checks':report.get('checks',[]),'colours':report.get('colours',[])}

def deliver(cfg):
    brand=cfg['brand'].strip()
    if not brand or not re.search(r'[a-zA-Z0-9]',brand): raise ValueError('Enter a package name containing at least one letter or number.')
    if len(brand)>80: raise ValueError('Keep the package name under 80 characters.')
    parent=Path(cfg['output']).expanduser().resolve()
    if not parent.is_dir(): raise ValueError('Choose an existing save folder.')
    prepared=Path(cfg['prepared']).resolve()
    old=json.loads((prepared/'export-report.json').read_text())
    wanted=set(cfg['include']); chosen=[t for t in old['files'] if t['id'] in wanted]
    if not chosen: raise ValueError('Choose at least one file to export.')
    if wanted-{t['id'] for t in old['files']}: raise ValueError('The preview has changed. Please build it again.')
    template=(cfg.get('template') or '').strip() or TEMPLATE
    names=[t['folder']+'/'+filename(t,brand,template) for t in chosen]; unique_paths(names)
    # Validate every prepared file before writing anything into the final package.
    for task in chosen:
        source=(prepared/task['path']).resolve()
        if prepared not in source.parents or not source.is_file(): raise ValueError('A preview file is missing. Please build the preview again.')
        if hashlib.sha256(source.read_bytes()).hexdigest()!=task['sha256']: raise ValueError('A preview file changed. Please build the preview again.')
    options=cfg.get('guide') or {}
    pantone=options.get('pantone') or {}
    colours=[dict(c,pantone=(pantone.get(c['hex']) or '').strip()[:40]) for c in old.get('colours',[])] if options.get('colours',True) else []
    usage=None
    if options.get('usage',True):
        usage={'padding':old.get('padding',10),'minDigital':max(0,min(int(options.get('minDigital') or 0),10000)),'minPrint':max(0,min(int(options.get('minPrint') or 0),10000)),'notes':(options.get('notes') or '').strip()[:600]}
    stem=slug(brand)+'-Logo-Package'; final=parent/stem; n=2
    while final.exists() or Path(str(final)+'.zip').exists():
        final=parent/(stem+'-'+str(n)); n+=1
    report=[]
    with tempfile.TemporaryDirectory(prefix='.logo-parcel-',dir=str(parent)) as temp:
        temp=Path(temp); stage=temp/'package';stage.mkdir()
        for i,(task,relative) in enumerate(zip(chosen,names)):
            progress(cfg,'Saving your logo package',i,len(chosen))
            dest=stage/relative;dest.parent.mkdir(parents=True,exist_ok=True)
            shutil.copyfile(prepared/task['path'],dest)
            report.append({k:v for k,v in {**task,'path':relative}.items() if k not in {'thumbnail','canvas','fill','background'}})
        notes=old.get('notes',[]);warnings=old.get('warnings',[]);checks=old.get('checks',[])
        previews={t['id']:t.get('thumbnail','') for t in chosen}
        hero=next((t.get('thumbnail') for t in chosen if t['variant']=='full-colour' and not t.get('group') and t.get('thumbnail')),None) or next((t.get('thumbnail') for t in chosen if t.get('thumbnail')),None)
        hero_dark=any(t.get("thumbnail")==hero and t["variant"] in ("white","dark-background") for t in chosen)
        hero_png=Path(hero).read_bytes() if hero and Path(hero).is_file() else None
        if colours:
            folder=stage/'Brand-Colours'; folder.mkdir()
            (folder/(slug(brand)+'-colours.ase')).write_bytes(brandfiles.ase(colours))
            (folder/(slug(brand)+'-colours.css')).write_text(brandfiles.css(brand,colours),encoding='utf-8')
            (folder/(slug(brand)+'-colours.json')).write_text(json.dumps([{k:c[k] for k in ('hex','rgb','cmyk','pantone')} for c in colours],indent=2),encoding='utf-8')
        if options.get('pdf',True):
            (stage/(slug(brand)+'-Brand-Sheet.pdf')).write_bytes(brandfiles.brand_sheet(brand,hero_png,colours,usage,report,website_url(),dark=hero_dark))
        (stage/'export-report.json').write_text(json.dumps({'files':report,'warnings':warnings,'checks':checks,'notes':notes,'colours':colours,'padding':old.get('padding',0),'profile':old.get('profile','')},indent=2))
        (stage/'START-HERE.html').write_text(guide(brand,report,warnings,notes,previews,website_url(),colours=colours,usage=usage,hero=hero_png,brand_files=slug(brand),pdf_sheet=options.get('pdf',True),hero_dark=hero_dark),encoding='utf-8')
        archive=temp/'package.zip'
        with zipfile.ZipFile(archive,'w',zipfile.ZIP_DEFLATED) as z:
            for f in stage.rglob('*'):
                if f.is_file(): z.write(f,str(Path(final.name)/f.relative_to(stage)))
        # Reserve the destination atomically, refusing concurrent overwrites.
        final.mkdir()
        try:
            with open(str(final)+'.zip','xb') as out, open(archive,'rb') as inp: shutil.copyfileobj(inp,out)
            for f in stage.iterdir(): shutil.move(str(f),str(final/f.name))
        except Exception:
            # Preserve any partially written result so failure is visible and recoverable.
            raise RuntimeError('Saving could not finish. Check '+str(final)+' and choose a writable folder with enough free space.')
    progress(cfg,'Package exported',len(report),len(report))
    return {'folder':str(final),'zip':str(final)+'.zip','count':len(report),'warnings':warnings}

if __name__=='__main__':
  try:
    if sys.argv[1]=='inspect': out=inspect(sys.argv[2])
    else:
      cfg=json.load(open(sys.argv[2]))
      fn={'plan':tasks,'export':package,'inspect-previews':inspect_with_previews,'prepare':prepare,'deliver':deliver,'reopen':reopen,'profiles':profiles,'preflight':preflight,'save-project':save_project,'open-project':open_project}[sys.argv[1]]
      out=fn(cfg)
    print(json.dumps(out))
  except Exception as e:
    print(json.dumps({'error':str(e)})); sys.exit(1)
