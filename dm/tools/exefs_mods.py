#!/usr/bin/env python3
"""ExeFS mods: code patches for the game's modules (main, subsdk*, sdk), applied before the rewriter (patch_nso.py), so they are part of the build.
On the iPhone the rewritten code is embedded in the signed app (loader.c map_image) and no page of it can be written at run time, so a code mod cannot be added there the way
romfs mods are (Documents/mods, Mods.swift): code mods come from the NSP folder's mods, and the app carries them.

Switchable mods. A mod folder with dm_toggle.txt (one line, <VAR>=<value>: DM_FPS_TARGET=60, DM_ULTRAWIDE=1) is on when the launcher's setting VAR has that value. Each such mod gets a
letter (a, b, c, in name order), and every module it patches is rewritten once per combination of the switchable mods that patch it: main, maina, mainb, mainab. All of them are embedded
(gen_embed.py, sections __dm<module><letters>x0 …), and the host maps the one the settings at Play call for (loader.c code_mods). A mod's romfs folder goes into the app too, served
over the game's files while the mod is on. Three switchable mods per module at most (eight copies of it). A mod without dm_toggle.txt is always on: every copy has it.

Where they are looked for (each a folder of mods, as Switch mod managers and emulators keep them):
  · <mods>/<mod name>/exefs/<build ID>.ips | .pchtxt        (LayeredFS layout: Ryujinx, the yuzu family)
  · <mods>/<mod name>/<build ID>.ips | .pchtxt              (Atmosphère's exefs_patches/<patch name>/ layout)
  · <mods>/<mod name>/exefs/*.pchtxt with any name: a .pchtxt names its module's build with @nsobid-<hex>
  · <mods>/<mod name>.zip, or a mod folder with the patches deeper (atmosphere/exefs_patches/<x>/, <title ID>/exefs/): every folder in it that holds .ips / .pchtxt files
A mod folder holding .disabled (or a name ending in .disabled) is skipped. Patch formats:
  · IPS ("PATCH" … "EOF", 3-byte offsets, RLE records) and IPS32 ("IPS32" … "EEOF", 4-byte offsets): offsets of the NSO file as Atmosphère's loader counts them, the 0x100-byte
    header first, so module address = offset - 0x100 (ldr_patcher.cpp: NsoPatchesProtectedSize 0x100); records within the header are ignored, as there.
  · .pchtxt (IPSwitch): @nsobid-<build ID>, then @enabled / @disabled blocks of "<hex offset> <hex bytes>" (or a quoted string) lines, @stop to end; @flag offset_shift <n> adds n
    to every offset to make it an IPS offset (most files say 0x100: their offsets are module addresses already).
A patch in the padding between a segment's end and the next segment (code put after the text, as emulators map that padding with the text: ACNH's ultrawide hooks) extends that
segment over it, so the rewriter takes it as code.
A build ID in a file name is matched as Atmosphère does: hex, case-insensitive, the build ID's trailing zero bytes optional.
Replacement modules (exefs/main, exefs/subsdk9, …) and main.npdm are not used: a module of another build is not the game the profile was made for. They are named in the report.

Usage: exefs_mods.py <mods folder> <ExeFS folder> <out folder> [module …]   the patched copies into out, and the report
As a module: plan(mods_dirs, {module: path}, out) -> Plan (base, variants, mods, lines, fingerprint); write_table(plan, folder) -> code_mods.tsv and the mods' romfs"""
import hashlib, os, re, shutil, struct, sys, zipfile
from pathlib import Path
from typing import NamedTuple

sys.path.insert(0, str(Path(__file__).resolve().parent))
import nso

HEADER = 0x100   # the NSO header Atmosphère's loader protects: IPS offsets count it
MAX_SWITCHABLE = 3   # per module: 2^3 = 8 copies of it in the app


class Error(ValueError):
    pass


def parse_ips(d, what):
    """[(IPS offset, bytes)] of an IPS or IPS32 file"""
    if d[:5] == b'PATCH': w, end, at = 3, b'EOF', 5
    elif d[:5] == b'IPS32': w, end, at = 4, b'EEOF', 5
    else: raise Error(f'{what}: not an IPS or IPS32 file')
    out = []
    while True:
        if d[at:at + len(end)] == end and at + len(end) >= len(d) - (0 if w == 4 else 3): break   # (an IPS may carry a 3-byte truncation size after EOF)
        if at + w + 2 > len(d): raise Error(f'{what}: cut short at {at:#x} (no {end.decode()} marker)')
        off = int.from_bytes(d[at:at + w], 'big'); n = int.from_bytes(d[at + w:at + w + 2], 'big'); at += w + 2
        if n == 0:   # RLE: 2-byte count, 1 byte
            if at + 3 > len(d): raise Error(f'{what}: RLE record cut short at {at:#x}')
            cnt = int.from_bytes(d[at:at + 2], 'big'); out.append((off, bytes([d[at + 2]]) * cnt)); at += 3
        else:
            if at + n > len(d): raise Error(f'{what}: record at {off:#x} claims {n} bytes past the end of the file')
            out.append((off, bytes(d[at:at + n]))); at += n
    return out


def parse_pchtxt(text, what):
    """(build ID hex or None, [(IPS offset, bytes)]) of the enabled patches of an IPSwitch .pchtxt"""
    bid, shift, on, out = None, 0, False, []
    for n, raw in enumerate(text.splitlines(), 1):
        line = raw.split('//', 1)[0].strip()
        if not line: continue
        low = line.lower()
        if low.startswith('@nsobid-'): bid = low[8:].strip(); continue
        if low.startswith('@flag'):
            p = low.split()
            if len(p) >= 3 and p[1] == 'offset_shift': shift = int(p[2], 0)
            continue   # (other flags: print_values, debug_info: no effect on the bytes)
        if low.startswith('@stop'): break
        if low.startswith('@enabled'): on = True; continue
        if low.startswith('@disabled'): on = False; continue
        if line.startswith('@'): continue
        if line.startswith('#') or line.startswith('['): continue   # titles of the patches
        if not on: continue
        m = re.match(r'([0-9A-Fa-f]+)\s+(.+)$', line)
        if not m: raise Error(f'{what}:{n}: not "<offset> <bytes>": {raw.strip()[:60]}')
        off, val = int(m.group(1), 16) + shift, m.group(2).strip()
        if val.startswith('"'):
            s = val[1:val.rindex('"')] if val.count('"') >= 2 else None
            if s is None: raise Error(f'{what}:{n}: unterminated string')
            b = s.encode('utf-8').decode('unicode_escape').encode('latin-1')
        else:
            h = re.sub(r'\s+', '', val)
            if len(h) % 2 or not re.fullmatch(r'[0-9A-Fa-f]*', h): raise Error(f'{what}:{n}: not hex bytes: {val[:60]}')
            b = bytes.fromhex(h)
        out.append((off, b))
    return bid, out


def bid_matches(name_hex, build_id):
    """Atmosphère's rule: the file's hex names the build ID, trailing zero bytes optional"""
    h = name_hex.lower().strip()
    if not h or len(h) % 2 or len(h) > 64 or not re.fullmatch(r'[0-9a-f]+', h): return False
    full = build_id.hex()
    return full.startswith(h) and set(full[len(h):]) <= {'0'}


def is_patch(name): return name.lower().endswith(('.ips', '.pchtxt'))


def unzip(z, dst):
    """A mod's .zip into dst (made anew), refusing paths that leave it"""
    shutil.rmtree(dst, ignore_errors=True); dst.mkdir(parents=True)
    try:
        with zipfile.ZipFile(z) as f:
            for i in f.infolist():
                n = i.filename.replace('\\', '/')
                if i.is_dir() or n.startswith('/') or '..' in n.split('/') or '__MACOSX/' in n: continue
                t = dst / n; t.parent.mkdir(parents=True, exist_ok=True)
                with f.open(i) as a, open(t, 'wb') as b: shutil.copyfileobj(a, b)
    except zipfile.BadZipFile as e: raise Error(f'{z.name}: not a readable .zip ({e})') from None
    return dst


def patch_folders(mod):
    """The folders of a mod that hold its patches: its exefs/ or itself when they are there, else every folder below that holds .ips / .pchtxt files"""
    ex = next((c for c in mod.iterdir() if c.is_dir() and c.name.lower() == 'exefs'), None)
    if ex or any(f.is_file() and is_patch(f.name) for f in mod.iterdir()): return [(ex or mod, ex is not None)]
    out = []
    for d, dirs, files in os.walk(mod):
        dirs[:] = sorted(x for x in dirs if not x.startswith('.') and x != '__MACOSX')
        if any(is_patch(f) for f in files): out.append((Path(d), Path(d).name.lower() == 'exefs'))
    return out


def mod_roots(mods_dirs, work=None):
    """(mod name, its root folder) for every mod of the folders, in name order; a .zip is unpacked under work"""
    for root in mods_dirs:
        root = Path(root)
        if not root.is_dir(): continue
        for mod in sorted(p for p in root.iterdir() if not p.name.startswith('.')):
            if mod.name.endswith('.disabled'): continue
            if mod.is_file() and mod.suffix.lower() == '.zip':
                if work is None: continue
                yield mod.stem, unzip(mod, Path(work) / 'zips' / mod.stem)
            elif mod.is_dir() and not (mod / '.disabled').exists(): yield mod.name, mod


def romfs_of(mod):
    """The mod's romfs folder (LayeredFS: <mod>/romfs, also one level down in an archive's top folder), or None"""
    for c in [mod] + sorted(p for p in mod.iterdir() if p.is_dir()):
        r = next((x for x in c.iterdir() if x.is_dir() and x.name.lower() == 'romfs'), None)
        if r and any(f.is_file() for f in r.rglob('*')): return r
    return None


def toggle_of(mod, name):
    """(VAR, value) of the mod's dm_toggle.txt, None when it has none (always on)"""
    f = next((p for p in (mod / 'dm_toggle.txt', mod / 'dm_toggle') if p.is_file()), None)
    if not f: return None
    line = next((l.strip() for l in f.read_text(encoding='utf-8').splitlines() if l.strip() and not l.startswith('#')), '')
    m = re.fullmatch(r'(DM_[A-Z0-9_]+)=(\S+)', line)
    if not m: raise Error(f'{name}/{f.name}: one line <VAR>=<value>, VAR a launcher setting (DM_FPS_TARGET=60, DM_ULTRAWIDE=1): {line[:60]!r}')
    return m.group(1), m.group(2)


def find_one(name, mod, builds):
    """{module: [(mod name, label, records)]} of one mod, and the report lines of what it holds that is not used"""
    got, notes = {}, []
    for folder, layered in patch_folders(mod):
        here = '' if layered or folder == mod else f'{folder.name}/'   # a nested folder's files carry its name: two variants of one patch are told apart
        for f in sorted(folder.iterdir()):
            if not f.is_file() or f.name.startswith('.'): continue
            stem, ext, label = f.stem, f.suffix.lower(), here + f.name
            if ext == '.ips':
                mods = [m for m, b in builds.items() if bid_matches(stem, b)]
                if not mods:
                    if re.fullmatch(r'[0-9A-Fa-f]{16,64}', stem): notes.append(f'{name}: {label} is for another build of the game; not used')
                    continue
                recs = parse_ips(f.read_bytes(), f'{name}/{label}')
            elif ext == '.pchtxt':
                bid, recs = parse_pchtxt(f.read_text(encoding='utf-8', errors='replace'), f'{name}/{label}')
                key = bid or stem
                mods = [m for m, b in builds.items() if bid_matches(key, b)]
                if not mods: notes.append(f'{name}: {label} is for build {key[:16].upper()}, not this one; not used'); continue
                if not recs: notes.append(f'{name}: {label} has no enabled patch'); continue
            else:
                if layered and (f.name in ('main', 'main.npdm', 'rtld', 'sdk') or f.name.startswith('subsdk')):
                    notes.append(f'{name}: exefs/{f.name} replaces a whole code module, which this build cannot use (only .ips / .pchtxt patches of the game\'s own modules); left out')
                continue
            for m in mods: got.setdefault(m, []).append((name, label, recs))
    return got, notes


def write_nso(src_bytes, img, segs, out):
    """An NSO of the same header (build ID, name, bss, the dynamic table offsets) with img's segments stored uncompressed and the compression and hash flags cleared"""
    h = bytearray(src_bytes[:HEADER])
    name_off, name_size = struct.unpack_from('<I', h, 0x1c)[0], struct.unpack_from('<I', h, 0x2c)[0]
    name = bytes(src_bytes[name_off:name_off + name_size]) if HEADER <= name_off and name_off + name_size <= len(src_bytes) else b''
    struct.pack_into('<I', h, 0xc, 0)
    at = HEADER
    if name: struct.pack_into('<I', h, 0x1c, at); at += len(name)
    body = bytearray(name)
    for i, (mo, sz) in enumerate(segs):
        struct.pack_into('<III', h, 0x10 + 0x10 * i, at, mo, sz); struct.pack_into('<I', h, 0x60 + 4 * i, sz)
        h[0xa0 + 0x20 * i:0xc0 + 0x20 * i] = hashlib.sha256(img[mo:mo + sz]).digest()   # kept true, though unchecked with the flags cleared
        body += img[mo:mo + sz]; at += sz
    tmp = Path(str(out) + '.partial'); tmp.write_bytes(bytes(h) + bytes(body)); os.replace(tmp, out)


def apply(path, entries, out):
    """Patches entries [(mod name, label, records)] onto the module at path; writes out. Returns the report lines"""
    d = Path(path).read_bytes(); m = nso.load(d, str(path))
    img, segs = bytearray(m.image), [list(s) for s in m.segments]
    end = segs[2][0] + segs[2][1]
    owner, lines = {}, []   # address → (mod, label) that wrote it, for overlaps
    for mod, label, recs in entries:
        n = skipped = 0
        for off, b in recs:
            if off < HEADER: skipped += 1; continue   # within the header: Atmosphère ignores it too
            a = off - HEADER
            if a + len(b) > end: raise Error(f'{mod}/{label}: a patch at {off:#x} ({len(b)} bytes) reaches past the module\'s image ({end:#x} bytes): for another build or another module')
            for i in range(2):   # in the padding after a segment: the segment grows over it (code after the text, mapped with it by emulators)
                se = segs[i][0] + segs[i][1]
                if se <= a < segs[i + 1][0]:
                    if a + len(b) > segs[i + 1][0]: raise Error(f'{mod}/{label}: a patch at {off:#x} runs from the padding into the next segment')
                    segs[i][1] = a + len(b) - segs[i][0]
            for k in range(a, a + len(b)):
                o = owner.get(k)
                if o and o != (mod, label): raise Error(f'{mod}/{label} and {o[0]}/{o[1]} both patch {Path(path).name}+{k:#x}: ' + ('this mod holds several versions of one patch: keep only the one you want' if o[0] == mod else 'they cannot be on together (put a .disabled file in one of them)'))
                owner[k] = (mod, label)
            img[a:a + len(b)] = b; n += 1
        hit = {next((('text', 'ro', 'data')[i] for i, (mo, sz) in enumerate(segs) if mo <= off - HEADER < mo + sz), 'gap') for off, _ in recs if off >= HEADER}
        where = [w for w in ('text', 'ro', 'data', 'gap') if w in hit]
        lines.append(f'{Path(out).name}: {mod}/{label}: {n} patch{"es" if n != 1 else ""} ({", ".join(where) or "none"}){f", {skipped} in the header ignored" if skipped else ""}')
    grown = [('text', 'ro')[i] for i in range(2) if segs[i][1] != m.segments[i][1]]
    if grown: lines.append(f'{Path(out).name}: {", ".join(grown)} extended over the padding after it ({", ".join(f"{s[0]:#x}+{s[1]:#x}" for s in segs[:2])})')
    write_nso(d, img, [tuple(s) for s in segs], out)
    return lines


class Mod(NamedTuple):
    letter: str      # '' for an always-on mod
    name: str
    toggle: tuple    # (VAR, value) or None
    romfs: Path      # or None
    entries: dict    # {module: [(mod name, label, records)]}


class Plan(NamedTuple):
    base: dict       # {module: the file to rewrite as the module itself}
    variants: list   # [(module, letters, file)]: rewritten as <module><letters>
    mods: list       # [Mod] with code for these builds, switchable ones first, in letter order
    lines: list      # the report
    fingerprint: str


def plan(mods_dirs, modules, out):
    """The modules' patched copies (out) for the mods of mods_dirs, and what the app needs to switch them. Modules no mod patches keep their own file"""
    mods_dirs = [Path(p) for p in mods_dirs if p and Path(p).is_dir()]
    if not mods_dirs: return Plan(dict(modules), [], [], [], '')
    out = Path(out)
    builds = {m: nso.read(p).build_id for m, p in modules.items()}
    found, lines = [], []
    for name, root in mod_roots(mods_dirs, out):
        entries, notes = find_one(name, root, builds); lines += notes
        if not entries:
            if romfs_of(root): lines.append(f'{name}: no code patch for this build; its romfs is not packaged (romfs mods are added on the phone)')
            continue
        found.append((name, toggle_of(root, name), romfs_of(root), entries))
    switchable = [f for f in found if f[1]]; always = [f for f in found if not f[1]]
    if len(switchable) > 26: raise Error('more than 26 switchable code mods')
    mods = [Mod(chr(ord('a') + i), n, t, r, e) for i, (n, t, r, e) in enumerate(switchable)] + [Mod('', n, None, r, e) for n, _, r, e in always]
    for x in mods: lines.append(f'{x.name}: ' + (f'switchable ({x.toggle[0]}={x.toggle[1]}, letter {x.letter})' if x.letter else 'always on') + (', with its romfs' if x.romfs else ''))
    base, variants, fp = dict(modules), [], []
    if mods: out.mkdir(parents=True, exist_ok=True)
    for m in modules:
        on = [e for x in mods if not x.letter for e in x.entries.get(m, [])]
        sw = [x for x in mods if x.letter and m in x.entries]
        if len(sw) > MAX_SWITCHABLE: raise Error(f'{m}: {len(sw)} switchable mods patch it ({", ".join(x.name for x in sw)}); at most {MAX_SWITCHABLE} ({2 ** MAX_SWITCHABLE} copies of the module)')
        if on: lines += apply(modules[m], on, out / m); base[m] = out / m
        for k in range(1, 2 ** len(sw)):
            pick = [x for i, x in enumerate(sw) if k >> i & 1]
            letters = ''.join(x.letter for x in pick)
            lines += apply(modules[m], on + [e for x in pick for e in x.entries[m]], out / f'{m}{letters}')
            variants.append((m, letters, out / f'{m}{letters}'))
        fp += [f'{m} {x.letter} {x.name}/{lab} {hashlib.sha256(repr(r).encode()).hexdigest()}' for x in mods for _, lab, r in x.entries.get(m, [])]
    fp += [f'toggle {x.letter} {x.toggle}' for x in mods]
    return Plan(base, variants, mods, lines, '\n'.join(fp))


def write_table(p, out_dir):
    """code_mods.tsv for the app (loader.c code_mods, settings.py codemod:): the mods and the module copies there are; each mod's romfs copied to out_dir/code_mods/<key>/romfs.
    Nothing (and an old table removed) when there are no code mods"""
    out_dir = Path(out_dir); cm = out_dir / 'code_mods'; shutil.rmtree(cm, ignore_errors=True)
    if not p.mods: (out_dir / 'code_mods.tsv').unlink(missing_ok=True); return
    rows = ['# code mods built into the app (dm/tools/exefs_mods.py): mod <letter or -> <VAR>=<value> or - <romfs folder or -> <name>; variant <module> <letters>']
    for i, x in enumerate(p.mods):
        key = x.letter or f'on{i}'
        rf = '-'
        if x.romfs: shutil.copytree(x.romfs, cm / key / 'romfs', ignore=shutil.ignore_patterns('.*', '__MACOSX')); rf = f'code_mods/{key}/romfs'
        rows.append('\t'.join(['mod', x.letter or '-', f'{x.toggle[0]}={x.toggle[1]}' if x.toggle else '-', rf, x.name.replace('\t', ' ')]))
    rows += ['\t'.join(['variant', m, letters]) for m, letters, _ in p.variants]
    (out_dir / 'code_mods.tsv').write_text('\n'.join(rows) + '\n')


if __name__ == '__main__':
    if len(sys.argv) < 4: sys.exit(__doc__.split('Usage: ')[1].split('\n')[0])
    mods_dir, exefs, out = Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3])
    want = sys.argv[4:] or sorted(p.name for p in exefs.iterdir() if p.is_file() and (p.name == 'main' or p.name == 'sdk' or p.name.startswith('subsdk')))
    try: p = plan([mods_dir], {m: exefs / m for m in want if (exefs / m).is_file()}, out)
    except (Error, nso.Error) as e: sys.exit(f'[RED] {e}')
    for l in p.lines: print(l)
    print(f'{len(p.variants)} switchable cop{"y" if len(p.variants) == 1 else "ies"}: {", ".join(m + l for m, l, _ in p.variants) or "none"}')
