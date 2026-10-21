"""Engine tests against a fake vectorcraft-cli. Run from the repository root: python3 -m unittest discover tests"""
import json, shutil, struct, subprocess, sys, tempfile, unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

class PackagerTest(unittest.TestCase):
    def setUp(self):
        self.dir = Path(tempfile.mkdtemp(prefix='logo-parcel-test-'))
        for name in ('packager.py', 'htmlguide.py', 'brandfiles.py'):
            shutil.copy(ROOT/'src'/name, self.dir)
        shutil.copy(ROOT/'resources'/'branding.json', self.dir)
        (self.dir/'engine').mkdir(); shutil.copy(ROOT/'tests'/'fake-vectorcraft-cli', self.dir/'engine'/'vectorcraft-cli')
        (self.dir/'art').mkdir(); (self.dir/'out').mkdir()
        for name in ('logo.svg', 'symbol.svg'): (self.dir/'art'/name).write_text('<svg/>')
        header = bytearray(200); header[16:20] = b'CMYK'; header[36:40] = b'acsp'
        (self.dir/'art'/'print.icc').write_bytes(bytes(header))
        sys.path.insert(0, str(self.dir)); import brandfiles; self.brandfiles = brandfiles

    def tearDown(self):
        sys.path.remove(str(self.dir)); sys.modules.pop('brandfiles', None)
        shutil.rmtree(self.dir)

    def engine(self, command, config):
        path = self.dir/(command+'.json'); path.write_text(json.dumps(config))
        p = subprocess.run([sys.executable, '-E', '-s', '-B', str(self.dir/'packager.py'), command, str(path)], capture_output=True, text=True)
        return json.loads(p.stdout)

    def prepare(self, **extra):
        art = self.dir/'art'
        config = {'layouts': [{'source': str(art/'logo.svg'), 'index': 0, 'name': 'Full logo'}, {'source': str(art/'symbol.svg'), 'index': 0, 'name': 'Symbol'}],
                  'brand': 'Logo', 'formats': ['svg', 'png', 'pdf'], 'variants': ['full-colour', 'white'], 'modes': ['rgb', 'cmyk'], 'sizes': [1024],
                  'padding': 10, 'custom': '#7355DD', 'outline': True, 'cache': str(self.dir/'cache'), **extra}
        out = self.engine('prepare', config); self.assertNotIn('error', out); return out

    def deliver(self, prepared, **extra):
        return self.engine('deliver', {'prepared': prepared['prepared'], 'include': [f['id'] for f in prepared['files']], 'brand': 'Acme', 'output': str(self.dir/'out'), **extra})

    def test_default_names_are_unchanged(self):
        out = self.deliver(self.prepare())
        names = sorted(p.name for p in Path(out['folder']).rglob('*.svg'))
        self.assertIn('Acme-Full-logo-full-colour-rgb.svg', names)
        self.assertTrue((Path(out['folder'])/'Full-logo'/'RGB'/'full-colour'/'Acme-Full-logo-full-colour-rgb-1024px.png').is_file())

    def test_filename_pattern(self):
        prepared = self.prepare(sizes=[512, 1024])
        out = self.deliver(prepared, template='{item}_{colour}_{mode}_{size}_{brand}')
        self.assertTrue((Path(out['folder'])/'Symbol'/'CMYK'/'white'/'Symbol_white_cmyk_Acme.pdf').is_file())
        self.assertIn('same name', self.deliver(prepared, template='{brand}-{item}')['error'])
        self.assertIn('{shape}', self.deliver(prepared, template='{brand}-{shape}')['error'])

    def test_web_and_social_sets(self):
        prepared = self.prepare(extras=['favicon', 'social', 'email'])
        folder = Path(prepared['prepared'])
        sizes = {Path(f['path']).name: self.brandfiles.png_size((folder/f['path']).read_bytes()) for f in prepared['files'] if f.get('group') and f['format'] == 'png' and f['role'] == 'Symbol'}
        self.assertEqual(sizes['apple-touch-icon.png'], (180, 180))
        self.assertEqual(sizes['Logo-Symbol-linkedin-cover-1584x396.png'], (1584, 396))
        self.assertEqual(sizes['Logo-Symbol-youtube-banner-2560x1440.png'], (2560, 1440))
        ico = (folder/'Symbol'/'Web-and-Social'/'Favicons'/'favicon.ico').read_bytes()
        self.assertEqual(struct.unpack('<HHH', ico[:6]), (0, 1, 3))

    def test_checks_colours_and_guide(self):
        prepared = self.prepare(profile=str(self.dir/'art'/'print.icc'))
        self.assertTrue(any('live text' in c for c in prepared['checks']))
        self.assertEqual(prepared['colours'][0]['hex'], '#E8593F')
        self.assertEqual(prepared['colours'][2]['cmyk'], [0, 0, 0, 50])  # Neutral grey on the black plate.
        out = self.deliver(prepared, guide={'pantone': {'#E8593F': 'PANTONE 7416 C'}, 'minDigital': 120, 'notes': 'Symbol only for app icons.'})
        folder = Path(out['folder'])
        page = (folder/'START-HERE.html').read_text()
        for text in ('PANTONE 7416 C', '120 px', 'Symbol only for app icons.', 'Acme-Brand-Sheet.pdf'): self.assertIn(text, page)
        self.assertNotIn('live text', page)  # Designer checks stay out of the client guide.
        self.assertTrue((folder/'Acme-Brand-Sheet.pdf').read_bytes().startswith(b'%PDF-1.4'))
        self.assertEqual((folder/'Brand-Colours'/'Acme-colours.ase').read_bytes()[:4], b'ASEF')
        report = json.loads((folder/'export-report.json').read_text())
        self.assertTrue(report['checks']); self.assertIn('Coated FOGRA39 (test)', ' '.join(report['notes']))

    def test_guide_options_off(self):
        out = self.deliver(self.prepare(), guide={'colours': False, 'usage': False, 'pdf': False})
        folder = Path(out['folder'])
        self.assertFalse((folder/'Brand-Colours').exists()); self.assertFalse((folder/'Acme-Brand-Sheet.pdf').exists())
        self.assertNotIn('id="usage"', (folder/'START-HERE.html').read_text())

    def test_reopen_reports_missing_artwork(self):
        art = self.dir/'art'
        out = self.engine('reopen', {'cache': str(self.dir/'reopen'), 'items': [{'role': 'Full logo', 'source': str(art/'logo.svg'), 'index': 0}, {'role': 'Symbol', 'source': str(art/'gone.svg'), 'index': 0}]})
        self.assertEqual([i['missing'] for i in out['items']], [False, True])

    def test_png_decoder_and_profile_names(self):
        prepared = self.prepare()
        thumb = Path(prepared['files'][0]['thumbnail']).read_bytes()
        w, h, rgb, alpha = self.brandfiles.decode_png(thumb)
        self.assertEqual(len(rgb), w*h*3); self.assertEqual(len(alpha), w*h)
        name = 'Coated GRACoL 2006'.encode('utf-16-be')
        tag = b'mluc'+b'\0'*4+struct.pack('>II', 1, 12)+b'enUS'+struct.pack('>II', len(name), 28)+name
        icc = bytearray(132)+struct.pack('>4sII', b'desc', 144, len(tag))+tag
        icc[16:20] = b'CMYK'; icc[36:40] = b'acsp'; struct.pack_into('>I', icc, 128, 1)
        (self.dir/'icc').mkdir(); (self.dir/'icc'/'gracol.icc').write_bytes(bytes(icc))
        self.assertEqual(self.brandfiles.cmyk_profiles([str(self.dir/'icc')])[0]['name'], 'Coated GRACoL 2006')

if __name__ == '__main__':
    unittest.main()
