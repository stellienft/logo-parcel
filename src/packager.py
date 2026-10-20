#!/usr/bin/env python3
"""Original logo-package workflow using VectorCraft's public command API."""
import argparse, json, re, subprocess, tempfile, zipfile, html, sys, shutil, hashlib, os
from pathlib import Path
from htmlguide import guide
ENGINE = Path(__file__).parent / 'engine' / 'vectorcraft-cli'
FORMATS = {'ai','eps','pdf','svg','png','jpg'}
VARIANTS = {'full-colour','black','white','grayscale','inverted','custom'}

def website_url():
    try: return json.loads(Path(__file__).with_name('branding.json').read_text()).get('website','')
    except (OSError,ValueError): return ''

def slug(s):
    return re.sub(r'[^a-zA-Z0-9_-]+', '-', s).strip('-')[:90] or 'Logo'

def run(source, commands):
    args=[str(ENGINE),'run','--in',str(source)]
    for cmd, params in commands:
        args += ['--cmd',cmd,'--params',json.dumps(params)]
    p=subprocess.run(args, capture_output=True, text=True, timeout=240)
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

def tasks(cfg):
    formats=cfg['formats']; variants=cfg['variants']; modes=cfg['modes']; sizes=cfg['sizes']
    if len(sizes)!=len(set(sizes)): raise ValueError('Choose each image size only once.')
    if not formats or not set(formats)<=FORMATS: raise ValueError('Select at least one supported format.')
    if not variants or not set(variants)<=VARIANTS: raise ValueError('Select at least one colour variation.')
    if not modes or not set(modes)<={'rgb','cmyk'}: raise ValueError('Select RGB or CMYK.')
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
          # White JPEG must have a dark background to remain visible.
          label='-'+str(size)+'px' if size else ''
          rel=f'{name}/{mode.upper()}/{variant}/{slug(cfg["brand"])}-{name}-{variant}-{mode}{label}.{fmt}'
          out.append(dict(id=f'{i}:{variant}:{mode}:{fmt}:{size or 0}',layout=i,role=layout['name'],variant=variant,mode=mode,format=fmt,size=size,path=rel))
    if not out: raise ValueError('The selected combination produces no files. PNG and SVG require RGB.')
    if cfg.get('include') is not None:
        wanted=set(cfg['include']); out=[t for t in out if t['path'] in wanted or t['id'] in wanted]
        if not out: raise ValueError('Select at least one file in the export preview.')
    if len(out)>3000: raise ValueError('Choose fewer combinations (maximum 3000 files per package).')
    return out

def package(cfg):
    plan=tasks(cfg)
    parent=Path(cfg['output']).expanduser().resolve()
    if not parent.is_dir(): raise ValueError('Choose an existing output folder.')
    name=slug(cfg['brand'])+'-Logo-Package'
    final=parent/name; n=2
    while final.exists() or final.with_suffix('.zip').exists():
        final=parent/(name+'-'+str(n)); n+=1
    warnings=[]; report=[]
    with tempfile.TemporaryDirectory(prefix='.logo-parcel-',dir=str(parent)) as temp:
      temp=Path(temp); staging=temp/'package'; staging.mkdir()
      for li,layout in enumerate(cfg['layouts']):
        progress(cfg, 'Preparing '+layout['name'], len(report), len(plan))
        base=temp/f'layout-{li}'; base.mkdir()
        rows=run(layout['source'],[('document.exportForScreens',{'folder':str(base),'artboards':[layout['index']],'formats':[{'format':'vectorcraft'}]})])
        warnings += rows[0]['result'].get('warnings',[])
        isolated=result(rows,'document.exportForScreens')['files'][0]
        # Work on an isolated temporary document, never the user's original.
        rows=run(isolated,[('artboard.fitToArt',{'index':0}),('document.inspect',{'depth':50,'childLimit':10000})])
        d=result(rows,'document.inspect'); a=d['artboards'][0]
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
        for variant in cfg['variants']:
          for mode in cfg['modes']:
            batch=[t for t in plan if t['layout']==li and t['variant']==variant and t['mode']==mode]
            if not batch: continue
            progress(cfg, 'Rendering '+layout['name']+' · '+variant+' · '+mode.upper(), len(report), len(plan))
            cmds=list(prep)
            if variant in {'black','white','custom'}:
                color={'black':'#000000','white':'#ffffff','custom':cfg['custom']}[variant]
                cmds.append(('recolor.apply',{'map':{c['key']:color for c in palette}}))
            elif variant in {'grayscale','inverted'}:
                cmds.append(('edit.colors.toGrayscale' if variant=='grayscale' else 'edit.colors.invert',{}))
            cmds.append(('file.documentColorMode',{'mode':mode,'convert':True,'grays':'black'}))
            for task in batch:
                dest=staging/task['path']; dest.parent.mkdir(parents=True,exist_ok=True)
                opts={'path':str(dest),'format':task['format'],'artboard':0,'background':'black' if variant=='white' and task['format']=='jpg' else 'transparent','quality':95}
                if task['size']:
                    if task['size']*(h+2*pad)/(w+2*pad)>10000: raise ValueError('This artwork is very tall. Choose a smaller image width.')
                    opts['scale']=task['size']/(w+2*pad)
                if task['format']=='jpg': opts['colorModel']=mode
                if task['format']=='eps': opts.update(cmykPostScript=mode=='cmyk',previewFormat='none',useArtboards=True)
                if task['format']=='svg': opts.update(outlineText=cfg.get('outline',True),images='embed')
                cmds.append(('document.export',opts))
            rows=run(isolated,cmds)
            for row in rows:
                warnings.extend(row.get('result',{}).get('warnings',[]) if isinstance(row.get('result'),dict) else [])
            exports=[r['result'] for r in rows if r.get('command')=='document.export']
            for task, exported in zip(batch,exports):
                file=staging/task['path']
                if not file.exists() and exported.get('files') and len(exported['files'])==1:
                    Path(exported['files'][0]).rename(file)
                if not file.is_file() or file.stat().st_size==0: raise RuntimeError('Export was not produced: '+task['path'])
                report.append(task)
      notes=['AI is VectorCraft’s PDF-compatible AI export, not Adobe-native private editing data.','PNG and SVG are RGB only. CMYK applies to PDF, EPS, AI and JPEG.','White JPEGs use a black background. Transparent formats retain transparency.','CMYK conversion uses VectorCraft’s configured colour settings. Confirm the printer’s required ICC profile before production.','Layout names come from approved artboards. New logo arrangements are not invented.','SVG text is outlined when selected; other formats use their VectorCraft defaults.']
      (staging/'export-report.json').write_text(json.dumps({'files':report,'warnings':list(dict.fromkeys(warnings)),'notes':notes},indent=2))
      links=''.join('<li><a href="'+html.escape(t['path'],quote=True)+'">'+html.escape(t['path'])+'</a></li>' for t in report)
      (staging/'START-HERE.html').write_text(guide(cfg['brand'],report,list(dict.fromkeys(warnings)),notes,website=website_url()),encoding='utf-8')
      archive=temp/'package.zip'
      with zipfile.ZipFile(archive,'w',zipfile.ZIP_DEFLATED) as z:
        for p in staging.rglob('*'):
          if p.is_file(): z.write(p,str(Path(final.name)/p.relative_to(staging)))
      shutil.move(str(staging),str(final)); shutil.move(str(archive),str(final)+'.zip')
    return {'folder':str(final),'zip':str(final)+'.zip','count':len(report),'warnings':list(dict.fromkeys(warnings))}


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
            else: thumbnail(src,thumb,reread=task['format'] in {'pdf','ai','eps'})
            task['thumbnail']=str(thumb)
        except Exception as e:
            raise RuntimeError('Could not preview '+task['path']+'. '+str(e))
    report['sourceBrand']='Logo'
    (folder/'export-report.json').write_text(json.dumps(report,indent=2))
    Path(packaged['zip']).unlink()  # This is an internal preview archive, never delivered.
    progress(cfg,'Preview ready',len(report['files']),len(report['files']))
    return {'prepared':str(folder),'files':report['files'],'warnings':report['warnings']}

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
    # Validate every prepared file before writing anything into the final package.
    for task in chosen:
        source=(prepared/task['path']).resolve()
        if prepared not in source.parents or not source.is_file(): raise ValueError('A preview file is missing. Please build the preview again.')
        if hashlib.sha256(source.read_bytes()).hexdigest()!=task['sha256']: raise ValueError('A preview file changed. Please build the preview again.')
    stem=slug(brand)+'-Logo-Package'; final=parent/stem; n=2
    while final.exists() or Path(str(final)+'.zip').exists():
        final=parent/(stem+'-'+str(n)); n+=1
    report=[]
    with tempfile.TemporaryDirectory(prefix='.logo-parcel-',dir=str(parent)) as temp:
        temp=Path(temp); stage=temp/'package';stage.mkdir()
        for i,task in enumerate(chosen):
            progress(cfg,'Saving your logo package',i,len(chosen))
            relative=Path(task['path'])
            newname=slug(brand)+relative.name[len(slug(old['sourceBrand'])):]
            relative=relative.parent/newname
            dest=stage/relative;dest.parent.mkdir(parents=True,exist_ok=True)
            shutil.copyfile(prepared/task['path'],dest)
            report.append({k:v for k,v in {**task,'path':str(relative)}.items() if k!='thumbnail'})
        notes=old.get('notes',[]);warnings=old.get('warnings',[])
        (stage/'export-report.json').write_text(json.dumps({'files':report,'warnings':warnings,'notes':notes},indent=2))
        links=''.join('<li><a href="'+html.escape(t['path'],quote=True)+'">'+html.escape(t['path'])+'</a></li>' for t in report)
        (stage/'START-HERE.html').write_text(guide(brand,report,warnings,notes,{t['id']:t.get('thumbnail','') for t in chosen},website_url()),encoding='utf-8')
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
      fn={'plan':tasks,'export':package,'inspect-previews':inspect_with_previews,'prepare':prepare,'deliver':deliver}[sys.argv[1]]
      out=fn(cfg)
    print(json.dumps(out))
  except Exception as e:
    print(json.dumps({'error':str(e)})); sys.exit(1)
