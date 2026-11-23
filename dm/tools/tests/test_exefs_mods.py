#!/usr/bin/env python3
"""exefs_mods.py: IPS / IPS32 / .pchtxt code patches matched by build ID and applied to a synthetic NSO, as the NSP script does before the rewriter: always-on mods into the
module, switchable ones (dm_toggle.txt) into one copy per combination, and the table and romfs the app switches them with"""
import hashlib, struct, sys, tempfile, unittest, zipfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import exefs_mods, nso

BID = bytes.fromhex('0123456789abcdef0011223344556677') + bytes(16)   # trailing zero bytes, as most games' are
NAME = '0123456789ABCDEF0011223344556677'
SEG = [(0x0000, 0x1f00), (0x2000, 0x1000), (0x3000, 0x1000)]   # text (ending before its page does: padding up to ro), ro, data


def make_nso(path, build_id=BID):
    """An NSO with uncompressed segments and the hash-check flags set, as retail modules have them (but stored plain)"""
    img = bytearray(0x4000)
    for i in range(len(img)): img[i] = (i * 7) & 0xff
    img[0x1f00:0x2000] = bytes(0x100)   # the padding after the text is not in any segment
    h = bytearray(0x100); h[:4] = b'NSO0'; struct.pack_into('<I', h, 0xc, 0b111000)
    name = b'synthetic\0'; struct.pack_into('<I', h, 0x1c, 0x100); struct.pack_into('<I', h, 0x2c, len(name))
    at, body = 0x100 + len(name), bytearray(name)
    for i, (mo, sz) in enumerate(SEG):
        struct.pack_into('<III', h, 0x10 + 0x10 * i, at, mo, sz); struct.pack_into('<I', h, 0x60 + 4 * i, sz)
        h[0xa0 + 0x20 * i:0xc0 + 0x20 * i] = hashlib.sha256(img[mo:mo + sz]).digest()
        body += img[mo:mo + sz]; at += sz
    struct.pack_into('<I', h, 0x3c, 0x800); h[0x40:0x60] = build_id
    path.write_bytes(bytes(h) + bytes(body))
    return img


def ips(records, big=False):
    out = bytearray(b'IPS32' if big else b'PATCH')
    for off, b in records:
        out += off.to_bytes(4 if big else 3, 'big')
        if isinstance(b, tuple): out += b'\0\0' + b[0].to_bytes(2, 'big') + bytes([b[1]])   # RLE (count, value)
        else: out += len(b).to_bytes(2, 'big') + b
    return bytes(out + (b'EEOF' if big else b'EOF'))


class ExefsMods(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.d = Path(self.tmp.name)
        (self.d / 'ExeFS').mkdir(); self.orig = make_nso(self.d / 'ExeFS' / 'main')
        self.mods = self.d / 'mods'

    def tearDown(self): self.tmp.cleanup()

    def put(self, mod, name, data, layered=True, toggle=None):
        p = self.mods / mod / ('exefs' if layered else ''); p.mkdir(parents=True, exist_ok=True)
        (p / name).write_bytes(data if isinstance(data, bytes) else data.encode())
        if toggle: (self.mods / mod / 'dm_toggle.txt').write_text(toggle + '\n')

    def plan(self):
        return exefs_mods.plan([self.mods], {'main': self.d / 'ExeFS' / 'main'}, self.d / 'out')

    def image(self, p): return nso.read(p).image

    def test_no_mods_folder_changes_nothing(self):
        p = exefs_mods.plan([self.d / 'none'], {'main': self.d / 'ExeFS' / 'main'}, self.d / 'out')
        self.assertEqual((p.base['main'], p.variants, p.mods, p.lines, p.fingerprint), (self.d / 'ExeFS' / 'main', [], [], [], ''))

    def test_always_on_ips_applies_at_offset_minus_header(self):
        self.put('fps', NAME + '.ips', ips([(0x100 + 0x10, b'\xaa\xbb'), (0x100 + 0x2004, (3, 0xcc)), (0x20, b'\x99')]))
        p = self.plan()
        self.assertEqual(p.base['main'], self.d / 'out' / 'main'); self.assertEqual(p.variants, []); self.assertTrue(p.fingerprint)
        m = nso.read(p.base['main'])
        want = bytearray(self.orig); want[0x10:0x12] = b'\xaa\xbb'; want[0x2004:0x2007] = b'\xcc' * 3
        self.assertEqual(bytes(m.image), bytes(want))
        self.assertEqual((m.build_id, m.bss, m.segments), (BID, 0x800, tuple(SEG)))   # the same build: the profile's cuts still apply
        self.assertTrue(any('1 in the header ignored' in l and 'text, ro' in l for l in p.lines))

    def test_switchable_mods_make_one_copy_per_combination(self):
        self.put('A 60 fps', NAME + '.ips', ips([(0x100 + 0x40, b'\x01')]), toggle='DM_FPS_TARGET=60')
        self.put('B wide', NAME + '.ips', ips([(0x100 + 0x80, b'\x02')]), toggle='DM_ULTRAWIDE=1')
        self.put('C always', NAME + '.ips', ips([(0x100 + 0xc0, b'\x03')]))
        p = self.plan()
        self.assertEqual([(x.letter, x.toggle) for x in p.mods], [('a', ('DM_FPS_TARGET', '60')), ('b', ('DM_ULTRAWIDE', '1')), ('', None)])
        self.assertEqual([(m, l) for m, l, _ in p.variants], [('main', 'a'), ('main', 'b'), ('main', 'ab')])
        imgs = {'': self.image(p.base['main'])} | {l: self.image(f) for _, l, f in p.variants}
        for letters, img in imgs.items():   # the always-on mod in every copy; each switchable one only where its letter is
            self.assertEqual(img[0xc0], 3, letters)
            self.assertEqual(img[0x40], 1 if 'a' in letters else self.orig[0x40], letters)
            self.assertEqual(img[0x80], 2 if 'b' in letters else self.orig[0x80], letters)

    def test_patch_in_the_padding_after_the_text_extends_the_text(self):   # as ACNH's ultrawide hooks: code put after the text, mapped with it by emulators
        self.put('wide', 'hooks.pchtxt', f'@nsobid-{NAME}\n@flag offset_shift 0x100\n@enabled\n00001F40 1F2003D5\n00001F44 C0035FD6\n', toggle='DM_ULTRAWIDE=1')
        p = self.plan()
        m = nso.read(p.variants[0][2])
        self.assertEqual(m.segments[0], (0, 0x1f48)); self.assertEqual(m.segments[1:], tuple(SEG[1:]))
        self.assertEqual(bytes(m.image[0x1f40:0x1f48]), bytes.fromhex('1F2003D5C0035FD6'))
        self.assertTrue(any('extended over the padding' in l for l in p.lines))

    def test_patch_from_the_padding_into_the_next_segment_stops_the_build(self):
        self.put('bad', NAME + '.ips', ips([(0x100 + 0x1ffe, b'\x01\x02\x03\x04')]))
        with self.assertRaisesRegex(exefs_mods.Error, 'into the next segment'): self.plan()

    def test_table_and_romfs_for_the_app(self):
        self.put('A 60 fps', NAME + '.ips', ips([(0x140, b'\x01')]), toggle='DM_FPS_TARGET=60')
        r = self.mods / 'A 60 fps' / 'romfs' / 'Pack'; r.mkdir(parents=True); (r / 'StaticParam.pack').write_bytes(b'params')
        p = self.plan(); app = self.d / 'app'; app.mkdir()
        exefs_mods.write_table(p, app)
        rows = [l.split('\t') for l in (app / 'code_mods.tsv').read_text().splitlines() if not l.startswith('#')]
        self.assertEqual(rows, [['mod', 'a', 'DM_FPS_TARGET=60', 'code_mods/a/romfs', 'A 60 fps'], ['variant', 'main', 'a']])
        self.assertEqual((app / 'code_mods/a/romfs/Pack/StaticParam.pack').read_bytes(), b'params')
        exefs_mods.write_table(exefs_mods.Plan({}, [], [], [], ''), app)   # no code mods any more: the table and the romfs go
        self.assertFalse((app / 'code_mods.tsv').exists() or (app / 'code_mods').exists())

    def test_bad_toggle_file_is_an_error(self):
        self.put('odd', NAME + '.ips', ips([(0x140, b'\x01')]), toggle='sixty fps please')
        with self.assertRaisesRegex(exefs_mods.Error, 'dm_toggle'): self.plan()

    def test_two_switchable_mods_patching_the_same_bytes_stop_the_build(self):
        self.put('a', NAME + '.ips', ips([(0x110, b'\x01\x02')]), toggle='DM_FPS_TARGET=60')
        self.put('b', NAME + '.ips', ips([(0x111, b'\x03')]), toggle='DM_ULTRAWIDE=1')
        with self.assertRaisesRegex(exefs_mods.Error, 'cannot be on together'): self.plan()

    def test_too_many_switchable_mods_for_one_module(self):
        for i in range(4): self.put(f'm{i}', NAME + '.ips', ips([(0x200 + 4 * i, b'\x01')]), toggle=f'DM_X{i}=1')
        with self.assertRaisesRegex(exefs_mods.Error, 'at most 3'): self.plan()

    def test_ips32_full_build_id_atmosphere_layout(self):
        self.put('big', BID.hex() + '.ips', ips([(0x100 + 0x3000, b'\x01\x02\x03\x04')], big=True), layered=False)
        self.assertEqual(bytes(self.image(self.plan().base['main'])[0x3000:0x3004]), b'\x01\x02\x03\x04')

    def test_pchtxt_enabled_blocks_and_offset_shift(self):
        self.put('ipswitch', 'any name.pchtxt', f'@nsobid-{NAME.lower()}\n@flag offset_shift 0x100\n\n'
                 '@enabled\n00000040 1F2003D5 // nop\n@disabled\n00000080 DEADBEEF\n@enabled\n00000100 "hi\\0"\n@stop\n00000200 FFFFFFFF\n')
        img = self.image(self.plan().base['main'])
        self.assertEqual(bytes(img[0x40:0x44]), bytes.fromhex('1F2003D5'))
        self.assertEqual(bytes(img[0x80:0x84]), bytes(self.orig[0x80:0x84]))   # disabled
        self.assertEqual(bytes(img[0x100:0x103]), b'hi\0')
        self.assertEqual(bytes(img[0x200:0x204]), bytes(self.orig[0x200:0x204]))   # after @stop

    def test_other_build_and_replacement_module_are_reported_not_used(self):
        self.put('old', 'FEDCBA9876543210.ips', ips([(0x110, b'\x00')]))
        self.put('code', 'main', b'NSO0 replacement')
        p = self.plan()
        self.assertEqual(p.base['main'], self.d / 'ExeFS' / 'main')
        self.assertTrue(any('another build' in l for l in p.lines)); self.assertTrue(any('replaces a whole code module' in l for l in p.lines))

    def test_disabled_mod_is_skipped(self):
        self.put('off', NAME + '.ips', ips([(0x110, b'\x00')])); (self.mods / 'off' / '.disabled').touch()
        self.assertEqual(self.plan().mods, [])

    def test_patch_past_the_image_stops_the_build(self):
        self.put('far', NAME + '.ips', ips([(0x100 + 0x3ffe, b'\x01\x02\x03')]))
        with self.assertRaisesRegex(exefs_mods.Error, 'past the module'): self.plan()

    def test_broken_ips_is_an_error(self):
        self.put('bad', NAME + '.ips', b'PATCH\x00\x01')
        with self.assertRaises(exefs_mods.Error): self.plan()

    def zip_mod(self, name, members):
        self.mods.mkdir(exist_ok=True)
        with zipfile.ZipFile(self.mods / name, 'w') as z:
            for n, data in members.items(): z.writestr(n, data)

    def test_zip_with_atmosphere_layout(self):
        self.zip_mod('ultrawide.zip', {f'atmosphere/exefs_patches/uw/{NAME}.ips': ips([(0x100 + 0x20, b'\x11\x22')]), 'readme.txt': 'x'})
        p = self.plan()
        self.assertEqual(bytes(self.image(p.base['main'])[0x20:0x22]), b'\x11\x22')
        self.assertTrue(any(l.startswith('main: ultrawide/') for l in p.lines))

    def test_zip_path_outside_is_not_written(self):
        self.zip_mod('evil.zip', {f'../escape/{NAME}.ips': ips([(0x120, b'\x01')])})
        p = self.plan()
        self.assertEqual(p.base['main'], self.d / 'ExeFS' / 'main'); self.assertFalse((self.d / 'escape').exists())

    def test_nested_folder_mod(self):
        p = self.mods / 'deep' / '01006F8002326000' / 'exefs'; p.mkdir(parents=True)
        (p / f'{NAME.lower()}.ips').write_bytes(ips([(0x130, b'\x07')]))
        self.assertEqual(self.image(self.plan().base['main'])[0x30], 7)

    def test_two_variants_of_one_patch_in_one_mod_stop_the_build(self):
        self.zip_mod('variants.zip', {f'21x9/{NAME}.ips': ips([(0x140, b'\x01')]), f'32x9/{NAME}.ips': ips([(0x140, b'\x02')])})
        with self.assertRaisesRegex(exefs_mods.Error, 'several versions'): self.plan()


if __name__ == '__main__':
    unittest.main()
