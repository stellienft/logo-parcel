"""Standard-library writers for the extra handoff files: swatches, favicons, the PDF brand sheet and ICC discovery."""
import json, re, struct, zlib
from pathlib import Path

def luminance(hex_):
    r,g,b=(int(hex_[i:i+2],16)/255 for i in (1,3,5))
    return 0.2126*r+0.7152*g+0.0722*b

def colour_name(i, colour):
    return colour.get('name') or 'Colour '+str(i+1)

# Adobe Swatch Exchange: big-endian blocks of UTF-16 names and float components.
def ase(colours):
    blocks=[]
    def block(name, model, values):
        title=(name+'\0').encode('utf-16-be')
        body=struct.pack('>H',len(title)//2)+title+model.encode('ascii')+struct.pack('>'+'f'*len(values),*values)+struct.pack('>H',2)
        blocks.append(struct.pack('>HI',1,len(body))+body)
    for i,c in enumerate(colours):
        block(colour_name(i,c),'RGB ',[v/255 for v in c['rgb']])
        block(colour_name(i,c)+' (CMYK)','CMYK',[v/100 for v in c['cmyk']])
    return b'ASEF'+struct.pack('>HHI',1,0,len(blocks))+b''.join(blocks)

def css(brand, colours):
    rows=''.join(f'  --brand-colour-{i+1}: {c["hex"]};\n' for i,c in enumerate(colours))
    return '/* '+brand.replace('*/','* /')+f' brand colours, exported by Logo Parcel */\n:root {{\n{rows}}}\n'

def png_size(data):
    if data[:8]!=b'\x89PNG\r\n\x1a\n': raise ValueError('Not a PNG file.')
    return struct.unpack('>II',data[16:24])

# ICO files may hold PNG images directly (Windows Vista and every current browser).
def ico(pngs):
    entries=b''; offset=6+16*len(pngs)
    for data in pngs:
        w,h=png_size(data)
        entries+=struct.pack('<BBBBHHII',w%256,h%256,0,0,1,32,len(data),offset); offset+=len(data)
    return struct.pack('<HHH',0,1,len(pngs))+entries+b''.join(pngs)

def largest_ico_png(data):
    count=struct.unpack('<H',data[4:6])[0]
    entries=[struct.unpack('<BBBBHHII',data[6+16*i:22+16*i]) for i in range(count)]
    e=max(entries,key=lambda e:e[0] or 256)
    return data[e[7]:e[7]+e[6]]

def decode_png(data):
    """8-bit, non-interlaced PNG → (width, height, rgb bytes, alpha bytes or None)."""
    w,h=png_size(data); depth,ctype,interlace=data[24],data[25],data[28]
    channels={0:1,2:3,4:2,6:4}.get(ctype)
    if depth!=8 or not channels or interlace: raise ValueError('Unsupported PNG layout.')
    pos=8; idat=b''
    while pos<len(data):
        n,kind=struct.unpack('>I4s',data[pos:pos+8])
        if kind==b'IDAT': idat+=data[pos+8:pos+8+n]
        pos+=12+n
    raw=zlib.decompress(idat); stride=w*channels; out=bytearray(); prev=bytearray(stride); i=0
    for _ in range(h):
        f=raw[i]; line=bytearray(raw[i+1:i+1+stride]); i+=1+stride
        for x in range(stride):
            a=line[x-channels] if x>=channels else 0; b=prev[x]; c=prev[x-channels] if x>=channels else 0
            if f==1: line[x]=(line[x]+a)&255
            elif f==2: line[x]=(line[x]+b)&255
            elif f==3: line[x]=(line[x]+(a+b)//2)&255
            elif f==4:
                p=a+b-c; pa,pb,pc=abs(p-a),abs(p-b),abs(p-c)
                line[x]=(line[x]+(a if pa<=pb and pa<=pc else b if pb<=pc else c))&255
        out+=line; prev=line
    if channels in (1,2): rgb=bytes(v for px in range(w*h) for v in (out[px*channels],)*3)
    else: rgb=bytes(v for px in range(w*h) for v in out[px*channels:px*channels+3])
    alpha=bytes(out[px*channels+channels-1] for px in range(w*h)) if channels in (2,4) else None
    return w,h,rgb,alpha

def wrap(text, size, width):
    """Greedy wrap using an average Helvetica glyph width."""
    limit=max(8,int(width/(size*0.5))); lines=[]
    for para in text.split('\n'):
        line=''
        for word in para.split():
            if line and len(line)+1+len(word)>limit: lines.append(line); line=word
            else: line=(line+' '+word).strip()
        lines.append(line)
    return lines

def pdf_text(s):
    s=s.replace('—','-').replace('–','-').replace('’',"'").replace('‘',"'").replace('“','"').replace('”','"').replace('·','-').replace('×','x')
    s=s.encode('cp1252','replace').decode('cp1252')
    return '('+s.replace('\\','\\\\').replace('(','\\(').replace(')','\\)')+')'

def brand_sheet(brand, logo_png, colours, usage, files, website='', dark=False):
    """A one-page A4 PDF for clients who will not open the HTML guide."""
    W,H=595,842; ops=[]; images=[]
    def text(x,y,s,size=10,bold=False,grey=False):
        ops.append(f'BT /{"F2" if bold else "F1"} {size} Tf {"0.42 0.42 0.4" if grey else "0.06 0.06 0.07"} rg {x:.1f} {y:.1f} Td {pdf_text(s)} Tj ET')
    def rect(x,y,w,h,rgb,stroke=False):
        r,g,b=(v/255 for v in rgb)
        ops.append(f'{r:.3f} {g:.3f} {b:.3f} {"RG" if stroke else "rg"} {x:.1f} {y:.1f} {w:.1f} {h:.1f} re {"S" if stroke else "f"}')
    rect(0,H-6,W,6,(250,74,59))
    text(40,H-50,'BRAND SHEET',9,True,True); text(40,H-82,brand,min(26,515/max(1,len(brand)*0.65)),True)
    text(40,H-102,f'{len(files)} logo files - open START-HERE.html in the package for every file.',9,grey=True)
    y=H-130; box=150
    rect(40,y-box,W-80,box,(204,202,197),stroke=True)
    if dark: rect(41,y-box+1,W-82,box-2,(32,32,34))
    if logo_png:
        try:
            w,h,rgb,alpha=decode_png(logo_png); images.append((w,h,rgb,alpha))
            scale=min((W-120)/w,(box-30)/h); dw,dh=w*scale,h*scale
            ops.append(f'q {dw:.1f} 0 0 {dh:.1f} {(W-dw)/2:.1f} {y-box+(box-dh)/2:.1f} cm /Im1 Do Q')
        except (ValueError,zlib.error,IndexError,struct.error): pass
    y-=box+34
    if colours:
        text(40,y,'BRAND COLOURS',9,True,True); y-=14
        cols=4; cw=(W-80-(cols-1)*12)/cols
        for i,c in enumerate(colours[:12]):
            cx=40+(i%cols)*(cw+12); cy=y-(i//cols)*92
            rect(cx,cy-40,cw,40,c['rgb']); rect(cx,cy-40,cw,40,(204,202,197),stroke=True)
            text(cx,cy-54,colour_name(i,c)+'  '+c['hex'].upper(),8,True)
            text(cx,cy-65,'RGB '+' '.join(map(str,c['rgb'])),7,grey=True)
            text(cx,cy-75,'CMYK '+' '.join(map(str,c['cmyk'])),7,grey=True)
            if c.get('pantone'): text(cx,cy-85,c['pantone'][:28],7,grey=True)
        y-=((min(len(colours),12)-1)//cols+1)*92+16
    if usage:
        text(40,y,'USING THE LOGO',9,True,True); y-=16
        rules=[f'Export padding: {usage["padding"]}% of the longest side on each edge. Follow approved brand guidelines for clear space.']
        if usage.get('minDigital'): rules.append(f'Minimum size on screen: {usage["minDigital"]} px wide.')
        if usage.get('minPrint'): rules.append(f'Minimum size in print: {usage["minPrint"]} mm wide.')
        rules+=['Do use the supplied files without changes, on backgrounds with enough contrast.','Do not stretch, rotate, recolour, outline or add effects such as shadows.','Do not place the logo on busy images where it is hard to read.']
        if usage.get('notes'): rules.append(usage['notes'])
        for rule in rules:
            for i,line in enumerate(wrap(rule,9,W-95)):
                if y<70: break
                text(52 if i else 40,y,('- ' if not i else '')+line,9); y-=13
            y-=3
    text(40,51,'See START-HERE.html for the full colour list and usage guidance.',7,grey=True)
    text(40,36,'Packaged with Logo Parcel'+(' - '+website if website else ''),7,grey=True)
    stream='\n'.join(ops).encode('cp1252','replace')
    objs=['<< /Type /Catalog /Pages 2 0 R >>','<< /Type /Pages /Kids [3 0 R] /Count 1 >>']
    xobj=' /XObject << /Im1 6 0 R >>' if images else ''
    objs.append(f'<< /Type /Page /Parent 2 0 R /MediaBox [0 0 {W} {H}] /Resources << /Font << /F1 4 0 R /F2 5 0 R >>{xobj} >> /Contents {7 if images else 6} 0 R >>')
    objs.append('<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>')
    objs.append('<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold /Encoding /WinAnsiEncoding >>')
    binary={}
    if images:
        w,h,rgb,alpha=images[0]; data=zlib.compress(rgb)
        smask=f' /SMask {8} 0 R' if alpha else ''
        objs.append(f'<< /Type /XObject /Subtype /Image /Width {w} /Height {h} /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /FlateDecode /Length {len(data)}{smask} >>'); binary[len(objs)]=data
    content=zlib.compress(stream)
    objs.append(f'<< /Filter /FlateDecode /Length {len(content)} >>'); binary[len(objs)]=content
    if images and images[0][3]:
        w,h,_,alpha=images[0]; data=zlib.compress(alpha)
        objs.append(f'<< /Type /XObject /Subtype /Image /Width {w} /Height {h} /ColorSpace /DeviceGray /BitsPerComponent 8 /Filter /FlateDecode /Length {len(data)} >>'); binary[len(objs)]=data
    out=bytearray(b'%PDF-1.4\n%\xe2\xe3\xcf\xd3\n'); offsets=[]
    for n,obj in enumerate(objs,1):
        offsets.append(len(out)); out+=f'{n} 0 obj\n{obj}\n'.encode('latin-1')
        if n in binary: out+=b'stream\n'+binary[n]+b'\nendstream\n'
        out+=b'endobj\n'
    xref=len(out)
    out+=f'xref\n0 {len(objs)+1}\n0000000000 65535 f \n'.encode()+b''.join(f'{o:010d} 00000 n \n'.encode() for o in offsets)
    out+=f'trailer\n<< /Size {len(objs)+1} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n'.encode()
    return bytes(out)

ICC_FOLDERS=['~/Library/ColorSync/Profiles','/Library/ColorSync/Profiles','/System/Library/ColorSync/Profiles','/Library/Application Support/Adobe/Color/Profiles/Recommended','/Library/Application Support/Adobe/Color/Profiles']

def icc_description(data):
    count=struct.unpack('>I',data[128:132])[0]
    for i in range(min(count,200)):
        sig,off,size=struct.unpack('>4sII',data[132+12*i:144+12*i])
        if sig!=b'desc': continue
        tag=data[off:off+size]
        if tag[:4]==b'desc':
            n=struct.unpack('>I',tag[8:12])[0]; return tag[12:12+n].rstrip(b'\0').decode('latin-1')
        if tag[:4]==b'mluc':
            length,start=struct.unpack('>II',tag[20:28]); return tag[start:start+length].decode('utf-16-be').rstrip('\0')
    return ''

def cmyk_profiles(folders=None):
    """Installed CMYK output profiles, read from their headers only."""
    found={}
    for folder in folders or ICC_FOLDERS:
        root=Path(folder).expanduser()
        if not root.is_dir(): continue
        for p in sorted(root.rglob('*')):
            if p.suffix.lower() not in {'.icc','.icm'} or not p.is_file(): continue
            try:
                with open(p,'rb') as f: head=f.read(65536)
                if head[16:20]!=b'CMYK' or head[36:40]!=b'acsp': continue
                name=icc_description(head) or p.stem
            except (OSError,struct.error,UnicodeDecodeError): continue
            found.setdefault(name,str(p))
    return [{'name':n,'path':found[n]} for n in sorted(found,key=str.lower)]

if __name__=='__main__':
    print(json.dumps(cmyk_profiles()))
