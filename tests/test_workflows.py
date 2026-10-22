"""Regression checks; real exports require LOGO_PARCEL_ENGINE."""
import unittest,sys,os,tempfile,json,zipfile,copy,hashlib
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'src'))
import packager as p
from htmlguide import guide

class Workflows(unittest.TestCase):
 def setUp(self):
  self.tmp=tempfile.TemporaryDirectory();self.root=Path(self.tmp.name)
  self.svg=self.root/'logo.svg';self.svg.write_text('<svg xmlns="http://www.w3.org/2000/svg" width="200" height="100"><rect x="10" y="10" width="80" height="80" rx="10" fill="#143D48"/><path d="M30 30h40v10H40v10h25v10H40v20H30z" fill="#56B5AC"/><path d="M110 30h80v20h-80z" fill="#143D48"/></svg>')
  self.white=self.root/'white.svg';self.white.write_text('<svg xmlns="http://www.w3.org/2000/svg" width="200" height="100"><path fill="#ffffff" fill-rule="evenodd" d="M10 10h80v80H10z M30 30h40v10H40v10h25v10H40v20H30z"/><path d="M110 30h80v20h-80z" fill="#ffffff"/></svg>')
  self.cfg=dict(layouts=[dict(name='Full logo',source=str(self.svg),index=0,overrides={})],formats=['svg','png','jpg','pdf','eps','ai'],variants=['full-colour'],modes=['rgb','cmyk'],sizes=[256],padding=10,custom='#7355DD',outline=True,brand='Test',output=str(self.root),cache=str(self.root/'cache'))
 def tearDown(self): self.tmp.cleanup()
 def test_plan(self):
  self.assertEqual(len(p.tasks(self.cfg)),10)
  self.cfg['variants']=['inverted']
  with self.assertRaises(ValueError):p.tasks(self.cfg)
 def test_html_escaping_and_guidance(self):
  text=guide('<script>bad</script>',[],[],[],colours=[dict(hex='#143D48',rgb=[20,61,72],cmyk=[72,15,0,72]),dict(hex='" onmouseover="bad')],usage={'padding':10})
  self.assertNotIn('<script>bad',text);self.assertIn('20 61 72',text);self.assertIn('10%',text);self.assertNotIn('onmouseover',text);self.assertNotIn('__GUIDANCE__',text)
 @unittest.skipUnless(os.environ.get('LOGO_PARCEL_ENGINE'),'Requires bundled VectorCraft engine')
 def test_real_extra_sets_and_profile_project(self):
  import brandfiles
  p.ENGINE=Path(os.environ['LOGO_PARCEL_ENGINE'])
  self.cfg.update(formats=['png','pdf'],extras=['favicon','social','email'])
  profile=Path('/System/Library/ColorSync/Profiles/Generic CMYK Profile.icc')
  if profile.is_file(): self.cfg['profile']=str(profile)
  result=p.prepare(self.cfg)
  self.assertEqual(len(result['files']),15)
  for item in result['files']:
   if item.get('canvas') and item['format']=='png':self.assertEqual(brandfiles.png_size((Path(result['prepared'])/item['path']).read_bytes()),tuple(item['canvas']))
  out=p.deliver(dict(prepared=result['prepared'],include=[t['id'] for t in result['files']],brand='Extras',output=str(self.root),guide={'pdf':False},template='{brand}_{item}_{colour}_{mode}_{size}'))
  page=(Path(out['folder'])/'START-HERE.html').read_text();self.assertNotIn('Extras-Brand-Sheet.pdf',page)
  self.assertTrue((Path(out['folder'])/'Brand-Colours'/'Extras-colours.ase').is_file())
  if profile.is_file():
   saved=self.root/'profile.logoparcel';p.save_project(dict(path=str(saved),project=dict(version=1,items=[],settings={'profile':str(profile)},guide={'notes':'Keep this guidance'})))
   opened=p.open_project(dict(path=str(saved),cache=str(self.root/'profile-open')))
   self.assertEqual(Path(opened['settings']['profile']).read_bytes(),profile.read_bytes());self.assertEqual(opened['guide']['notes'],'Keep this guidance')
 def test_project_traversal(self):
  file=self.root/'bad.logoparcel'
  with zipfile.ZipFile(file,'w') as z:z.writestr('../escape','bad');z.writestr('project.json','{}')
  with self.assertRaises(ValueError):p.open_project(dict(path=str(file),cache=str(self.root/'open')))
 @unittest.skipUnless(os.environ.get('LOGO_PARCEL_ENGINE'),'Requires bundled VectorCraft engine')
 def test_real_export_override_and_project(self):
  p.ENGINE=Path(os.environ['LOGO_PARCEL_ENGINE'])
  self.cfg['variants']=['full-colour','white','dark-background']
  pre=p.preflight(self.cfg);self.assertTrue(any(i['severity']=='error' for i in pre['issues']));self.assertTrue(any('merges' in i['message'] for i in pre['issues']))
  self.cfg['layouts'][0]['overrides']={v:dict(source=str(self.white),index=0) for v in ['white','dark-background']}
  pre=p.preflight(self.cfg);self.assertFalse(pre['issues'],pre)
  result=p.prepare(self.cfg);self.assertEqual(len(result['files']),30)
  svg=next(t for t in result['files'] if t['format']=='svg' and t['variant']=='white')
  data=(Path(result['prepared'])/svg['path']).read_text();self.assertIn('evenodd',data)
  chosen=[t['id'] for t in result['files'] if t['variant']=='white']
  delivered=p.deliver(dict(prepared=result['prepared'],include=chosen,brand='Example',output=str(self.root)))
  report=json.loads((Path(delivered['folder'])/'export-report.json').read_text());self.assertEqual(len(report['files']),10)
  for item in report['files']:self.assertEqual(hashlib.sha256((Path(delivered['folder'])/item['path']).read_bytes()).hexdigest(),item['sha256'])
  self.assertIn('Colour values',(Path(delivered['folder'])/'START-HERE.html').read_text())
  project=dict(version=1,items=[dict(name='Full logo',artwork={'full-colour':dict(source=str(self.svg),index=0,thumbnail='',boardName='Logo'),'white':dict(source=str(self.white),index=0,thumbnail='',boardName='White')})],settings={'padding':10})
  saved=self.root/'example.logoparcel';p.save_project(dict(path=str(saved),project=copy.deepcopy(project)))
  self.svg.unlink();self.white.unlink()
  opened=p.open_project(dict(path=str(saved),cache=str(self.root/'reopened')))
  for art in opened['items'][0]['artwork'].values():self.assertTrue(Path(art['source']).is_file());self.assertTrue(Path(art['thumbnail']).is_file());self.assertEqual(len(p.inspect(art['source'])['layouts']),1)
 @unittest.skipUnless(os.environ.get('LOGO_PARCEL_ENGINE'),'Requires bundled VectorCraft engine')
 def test_missing_font_and_bitmap(self):
  p.ENGINE=Path(os.environ['LOGO_PARCEL_ENGINE'])
  self.svg.write_text('<svg xmlns="http://www.w3.org/2000/svg" width="400" height="100"><text x="5" y="50" font-family="NonexistentLogoParcelFont9321" font-size="30">Example</text></svg>')
  check=p.preflight(self.cfg);self.assertTrue(any(i['severity']=='error' and 'Font unavailable' in i['message'] for i in check['issues']),check)
  import base64,struct,zlib
  def chunk(kind,data):return struct.pack('!I',len(data))+kind+data+struct.pack('!I',zlib.crc32(kind+data)&0xffffffff)
  png=b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('!IIBBBBB',2,2,8,2,0,0,0))+chunk(b'IDAT',zlib.compress((b'\0'+b'\xff\0\0'*2)*2))+chunk(b'IEND',b'')
  self.svg.write_text('<svg xmlns="http://www.w3.org/2000/svg" width="400" height="100"><image width="400" height="100" href="data:image/png;base64,'+base64.b64encode(png).decode()+'"/></svg>')
  check=p.preflight(self.cfg);self.assertTrue(any('Bitmap resolution' in i['message'] for i in check['issues']),check);self.assertTrue(any('enlarged' in i['message'] for i in check['issues']),check)
if __name__=='__main__':unittest.main()
