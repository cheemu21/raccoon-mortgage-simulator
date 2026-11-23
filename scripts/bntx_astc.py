#!/usr/bin/env python3
# A Nintendo (nn::gfx BNTX) game's 16-byte-block BC textures re-encoded as ASTC 4x4, so GPUs without BC formats (iPhones before the A17 Pro) read them: a RomFS image
# (dm/tools/romfs_image.py) → another image whose zstd-compressed .bntx files hold those textures in ASTC. The game then asks NVN for ASTC (Tegra X1 has it; the host maps NVN's
# ASTC formats to Metal's), so there is no work at run time and no decoded copy in memory. The same idea as LumiOS-Platinum's scripts/astc_textures.py, for BNTX instead of Unity.
#
# Block for block: BC2 / BC3 / BC7 store 16 bytes per 4x4 block, as ASTC 4x4 does, so each block is replaced in place by the ASTC block of the same 4x4 texels. The texture's
# block-linear layout (its swizzle, mip offsets, image size, alignment) only orders whole blocks, so it is kept as it is and nothing is deswizzled; the BRTI's format becomes
# ASTC 4x4 of the same colour space (unorm / sRGB). Memory, file layout and the game's view of the texture stay the same size.
# Not converted here (left to the host, which turns them into EAC / ETC2 of the same size at upload, or a stand-in): BC1 and BC4 (8-byte blocks: ASTC has no 4x4 block of
# 8 bytes), BC5 (ASTC has no signed format, and Tomodachi Life's normal maps are BC5 snorm), BC6H (NVN has no HDR ASTC format).
#
# Every converted texture is checked: its ASTC blocks are decoded again and compared with the BC blocks decoded (what the GPU showed before), PSNR over RGBA. Below --min-psnr the
# texture is encoded again at the thorough preset; one still below --floor-psnr is left as BC and listed (the host then treats it like the BC formats it does not convert).
# No output block may be all zero (ASTC's reserved block, drawn magenta by Metal). The report (--report) lists every texture with its PSNR.
# Usage: bntx_astc.py <in image> <out image> [--quality medium|thorough] [--jobs N] [--limit N] [--match TEXT] [--report FILE] [--dry-run]
#   needs: pip install texture2ddecoder astc-encoder-py backports.zstd (backports.zstd only before Python 3.14)
import argparse, collections, concurrent.futures as cf, os, struct, sys, time
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'dm/tools'))
import romfs_image
try: from compression import zstd   # Python 3.14
except ImportError: from backports import zstd

BC2, BC3, BC4, BC5, BC6, BC7, ASTC4 = 0x1b, 0x1c, 0x1d, 0x1e, 0x1f, 0x20, 0x2d   # nn::gfx ImageFormat type (high byte); the low byte is the variant
CONVERT = {BC3: 'BC3', BC7: 'BC7'}               # BC2 has no decoder in texture2ddecoder and no texture in the games seen; left as it is (counted)
UNORM, SNORM, FLOAT, SRGB = 1, 2, 5, 6
# --eac: the 8-byte BC4 and the signed BC5 blocks recoded as EAC blocks of the same size, which every Apple GPU reads (NVN has no EAC format, so the BRTI is relabelled
# as a BC format the game itself never uses, of the same block size, and the host, with DM_BC_RECODE=1 in the build's env.txt, makes that format's textures as the EAC one):
#   BC4 unorm  → EAC R11 unorm,   relabelled BC4 snorm  (NVN 0x4a → MTLPixelFormatEAC_R11Unorm)
#   BC5 snorm  → EAC RG11 snorm,  relabelled BC6H float (NVN 0x4f → MTLPixelFormatEAC_RG11Snorm)
# A game file that already holds a BC4 snorm or BC6H float texture stops the recode (the relabel would be ambiguous). Arm-free: etcpak encodes EAC (unsigned; a signed block is the
# unsigned one with its base byte moved down by 127, within half a step of 8-bit precision), texture2ddecoder decodes EAC again for the check.
#   BC5 unorm  → EAC RG11 unorm,  relabelled BC2 unorm  (NVN 0x43 → MTLPixelFormatEAC_RG11Unorm; BC2 / DXT3 is in no file, and no Switch-era encoder makes it)
MARKER = {(BC4, UNORM): (BC4, SNORM, 'BC4'), (BC5, SNORM): (BC6, FLOAT, 'BC5 snorm'), (BC5, UNORM): (BC2, UNORM, 'BC5 unorm')}
MARKER_NVN = {(BC4, SNORM): 0x4a, (BC6, FLOAT): 0x4f, (BC2, UNORM): 0x43}   # the markers' NVN formats (the host's nvn_fmt_recoded)
# And with --eac, two that keep their label:
#   BC1        → ETC2 RGB8 (sRGB as the texture is), only an opaque one (ETC2 RGB8 has no alpha) that stays within --min-psnr. BC1 has no free 8-byte label left and the game's own
#                texture compressor may make BC1 (user-made textures), so each recoded one is named in a table of fingerprints instead, written into the image as BC1_TABLE: FNV-1a 64
#                of its width and height (u32 each) and the first min(4096, level-0 blocks x 8) bytes of its storage; the host makes a BC1 texture whose storage starts so as ETC2
#   BC6H ufloat → ASTC 4x4 HDR (HDR, as BC6H is: the island's environment cubemaps hold values up to 7); NVN 0x50 → MTLPixelFormatASTC_4x4_HDR. No user-made texture is HDR
BC1, ETC2_N = 0x1a, 4096
BC1_TABLE = 'dm_bc1_etc2.tbl'   # 'DMBC1TB2', u64 count, sorted u64 fingerprints (fingerprint(): version 2, the whole storage; version 1 tables, 'DMBC1TB1', hashed its first 4096 bytes)


def fingerprint(w, h, storage):
    """The tables' key of a texture (version 2): the first 8 bytes, little-endian, of SHA-256 over its width and height (u32 each) and its whole storage, every level, as the host's
    layout code sizes it (tex_fp). Version 1 hashed only the first 4096 bytes of level 0, and two textures of one size whose first rows match (a layout's logo with a clear band
    along its top) took each other's ASTC copy or ETC2 label: Animal Crossing's Nook Inc. logo came out with another texture's blocks in it"""
    import hashlib
    return int.from_bytes(hashlib.sha256(struct.pack('<II', w, h) + bytes(storage)).digest()[:8], 'little')
ROW = 1024   # blocks per row of the block image the encoder sees: any width works, since blocks are encoded independently and kept in order


def decode_blocks(t, blocks):
    """BGRA texels of a run of BC blocks laid out ROW blocks a row (padded with zero blocks to whole rows)"""
    import texture2ddecoder as T
    n = len(blocks) // 16; rows = (n + ROW - 1) // ROW; pad = rows * ROW - n
    data = blocks + bytes(16 * pad)
    w, h = 4 * min(ROW, n) if rows == 1 else 4 * ROW, 4 * rows
    if rows == 1: data = blocks   # one short row: exactly n blocks wide
    return (T.decode_bc3 if t == BC3 else T.decode_bc7)(data, w, h), w, h, n


_ctx = {}
def ctx(srgb, quality):
    import astc_encoder as A
    key = (srgb, quality)
    if key not in _ctx:
        q = {'medium': A.ASTCQualityPreset.MEDIUM, 'thorough': A.ASTCQualityPreset.THOROUGH}[quality]
        _ctx[key] = A.ASTCContext(A.ASTCConfig(A.ASTCProfile.LDR_SRGB if srgb else A.ASTCProfile.LDR, 4, 4, 1, q))
    return _ctx[key]


def encode_check(bgra, w, h, n, srgb, quality):
    """(ASTC blocks of the first n blocks, PSNR of their decoding against bgra)"""
    import astc_encoder as A
    sw = A.ASTCSwizzle.from_str('bgra')
    src = A.ASTCImage(A.ASTCType.U8, w, h, 1, bgra)
    c = ctx(srgb, quality)
    astc = c.compress(src, sw)
    back = c.decompress(astc, A.ASTCImage(A.ASTCType.U8, w, h, 1), sw)
    psnr = A.compute_error_metrics(False, False, 4, src, back, 0, 0)['psnr']
    return astc[:16 * n], psnr


def bc4_values(blocks, signed):
    """(n, 16) texel values in [-1, 1] (signed) or [0, 1] of a run of 8-byte BC4 blocks (texels row-major within the block)"""
    import numpy as np
    b = np.frombuffer(blocks, np.uint8).reshape(-1, 8)
    r0 = b[:, 0].astype(np.int8 if signed else np.uint8).astype(np.float64); r1 = b[:, 1].astype(np.int8 if signed else np.uint8).astype(np.float64)
    if signed: r0, r1 = np.maximum(r0, -127), np.maximum(r1, -127)
    bits = np.zeros(len(b), np.uint64)
    for k in range(6): bits |= b[:, 2 + k].astype(np.uint64) << np.uint64(8 * k)
    idx = np.stack([((bits >> np.uint64(3 * i)) & np.uint64(7)).astype(np.int64) for i in range(16)], 1)
    hi, lo = (127.0, -127.0) if signed else (255.0, 0.0)
    pal = np.zeros((len(b), 8)); pal[:, 0], pal[:, 1] = r0, r1; gt = r0 > r1
    for i in range(1, 7): pal[:, i + 1] = np.where(gt, ((7 - i) * r0 + i * r1) / 7, pal[:, i + 1])
    for i in range(1, 5): pal[:, i + 1] = np.where(~gt, ((5 - i) * r0 + i * r1) / 5, pal[:, i + 1])
    pal[:, 6] = np.where(~gt, lo, pal[:, 6]); pal[:, 7] = np.where(~gt, hi, pal[:, 7])
    return np.take_along_axis(pal, idx, 1) / hi


_hq = None
def eac_hq(so):   # dm/tools/eac_hq.c, built by main() into the output's folder: the thorough encoder
    global _hq
    if _hq is None:
        import ctypes
        _hq = ctypes.CDLL(so); _hq.eac_hq_encode.argtypes = (ctypes.c_void_p, ctypes.c_long, ctypes.c_int, ctypes.c_void_p); _hq.eac_hq_encode.restype = None
    return _hq


def build_eac_hq(folder):
    import subprocess
    src = Path(__file__).resolve().parents[1] / 'dm/tools/eac_hq.c'; so = Path(folder) / 'eac_hq.dylib'
    if not so.exists() or so.stat().st_mtime < src.stat().st_mtime:
        subprocess.run(['cc', '-O3', '-shared', '-fPIC', '-o', str(so), str(src)], check=True)
    return str(so)


def eac_recode(blocks, kind, so=None, min_psnr=40.0):
    """(EAC blocks of the same size, PSNR of their decoding against the BC decoding, 'fast' / 'thorough'); kind 'BC4' (8-byte BC4 unorm → EAC R11 unorm) or 'BC5 snorm'
    (→ EAC RG11 snorm). etcpak first; below min_psnr, the thorough encoder (eac_hq.c, so) again, kept when it is better"""
    c, p = eac_recode_(blocks, kind, None)
    if p < min_psnr and so:
        c2, p2 = eac_recode_(blocks, kind, so)
        if p2 > p: return c2, p2, 'thorough'
    return c, p, 'fast'


def eac_recode_(blocks, kind, so):
    import numpy as np, etcpak, texture2ddecoder as T
    bb = 8 if kind == 'BC4' else 16; n = len(blocks) // bb; W = min(n, ROW); H = (n + W - 1) // W
    def image(vals):   # (n, 16) → (4H, 4W), blocks row-major as the encoder and decoder see them
        v = np.zeros((W * H, 16)); v[:n] = vals
        return v.reshape(H, W, 4, 4).transpose(0, 2, 1, 3).reshape(4 * H, 4 * W)
    def thorough(vals, signed):   # (n, 16) values → n 8-byte EAC R11 blocks (eac_hq.c), in the same block order as the encoder's image
        v = np.zeros((W * H, 16), np.float32); v[:n] = vals; o = np.zeros(W * H * 8, np.uint8)
        eac_hq(so).eac_hq_encode(v.ctypes.data, W * H, int(signed), o.ctypes.data); return o.reshape(-1, 8)
    src = np.zeros((4 * H, 4 * W, 4), np.uint8); src[..., 3] = 255
    if kind == 'BC4':
        vals = bc4_values(blocks, False)
        src[..., 0] = np.clip(np.rint(image(vals) * 255), 0, 255)
        c = thorough(vals, False).tobytes() if so else etcpak.compress_eac_r(src.tobytes(), 4 * W, 4 * H)
        out = np.frombuffer(T.decode_eacr(c, 4 * W, 4 * H), np.uint8).reshape(src.shape); pairs = ((2, 0),)
    elif kind == 'BC5 unorm':
        b = np.frombuffer(blocks, np.uint8).reshape(-1, 16)
        rv, gv = bc4_values(b[:, :8].tobytes(), False), bc4_values(b[:, 8:].tobytes(), False)
        for ch, vals in ((0, rv), (1, gv)): src[..., ch] = np.clip(np.rint(image(vals) * 255), 0, 255)
        c = np.concatenate([thorough(rv, False), thorough(gv, False)], 1).tobytes() if so else etcpak.compress_eac_rg(src.tobytes(), 4 * W, 4 * H)
        out = np.frombuffer(T.decode_eacrg(c, 4 * W, 4 * H), np.uint8).reshape(src.shape); pairs = ((2, 0), (1, 1))
    else:
        b = np.frombuffer(blocks, np.uint8).reshape(-1, 16)
        rv, gv = bc4_values(b[:, :8].tobytes(), True), bc4_values(b[:, 8:].tobytes(), True)
        for ch, vals in ((0, rv), (1, gv)): src[..., ch] = np.clip(np.rint((image(vals) + 1) * 127.5), 0, 255)
        if so: c = np.concatenate([thorough(rv, True), thorough(gv, True)], 1).tobytes()   # an RG11 block: the R block, then the G block
        else:
            c = bytearray(etcpak.compress_eac_rg(src.tobytes(), 4 * W, 4 * H))
            for k in range(0, len(c), 8): c[k] = max(-127, min(127, c[k] - 127)) & 0xff   # each 8-byte channel block: the unsigned base codeword as the signed one
            c = bytes(c)
        out = np.frombuffer(T.decode_eacrg_signed(c, 4 * W, 4 * H), np.uint8).reshape(src.shape); pairs = ((2, 0), (1, 1))   # decoded BGRA: R at 2, G at 1
    ps = []
    for oc, sc in pairs:
        m = float(np.mean((out[..., oc].astype(np.float64) - src[..., sc].astype(np.float64)) ** 2)); ps.append(999.0 if m == 0 else 10 * np.log10(255 ** 2 / m))
    return c[:bb * n], min(ps)


# The textures still left after the recodes above (BC1 that ETC2 cannot hold within --min-psnr, BC4 that EAC cannot): their BC data stays in the file, and an ASTC copy goes into
# SIDE_FILE at the image's root, made level by level from the texture deswizzled with the host's own layout code (dm/gfx/nvn/nvn_tex.c, dm/gfx/tex/nvn_deswizzle.c, built here
# as nvn_layout.dylib), at the largest block of SIDE_BLOCKS whose decoding over all levels stays within --min-psnr: ASTC 6x6 holds 3.56 bits a texel, under BC1's 4. The host
# (DM_BC_RECODE) makes such a texture as that ASTC format and uploads the copy from the image instead of the storage, found by the fingerprint of the storage as the file holds it.
# Plain 2D textures of one layer only (the others stay BC, for the host's decode). A BC4 copy is (value, 0, 0, 1), as BC4 samples
SIDE_FILE = 'dm_bc_astc.bin'   # 'DMBCAS02' (version 2 fingerprints; 'DMBCAS01' version 1), u32 count, u32 0, then count entries of 28 bytes sorted by fingerprint: u64 fingerprint, u64 data offset (from the end of the entries),
                               # u32 NVN format, u16 width, u16 height, u8 block w, u8 block h, u8 levels, u8 sRGB; then the data, each texture's levels one after another, 16-aligned
SIDE_BLOCKS = ((6, 6), (5, 5), (4, 4))


class _Layout(__import__('ctypes').Structure):   # nvn_tex.h nvn_texlayout
    import ctypes as _c
    _fields_ = [('size', _c.c_uint64), ('layer_size', _c.c_uint64), ('align', _c.c_uint32), ('layers', _c.c_uint32), ('bpb', _c.c_uint32), ('tileH', _c.c_uint), ('tileD', _c.c_uint)]


def tex_fp(d, i, start, size, nvn_fmt, so):
    """fingerprint() of the texture whose BRTI is at i and storage at d[start:start + size], or None when the host's layout code sizes it otherwise than the BNTX does (the host
    hashes the storage at its own size: a texture they disagree on is left out of the tables rather than matched wrongly)"""
    import ctypes
    w, h = struct.unpack_from('<ii', d, i + 0x24); mips, = struct.unpack_from('<H', d, i + 0x16); lay, = struct.unpack_from('<I', d, i + 0x34)
    L = layout_lib(so); o = _Layout()
    L.nvn_tex_layout(ctypes.byref(_Desc(1, nvn_fmt, 0, 0, w, h, 1, mips, 0, ((lay & 0xff) | ((lay >> 8) & 0xf) << 8) + 1, 0)), ctypes.byref(o))
    return fingerprint(w, h, d[start:start + size]) if o.size == size else None


class _Desc(__import__('ctypes').Structure):
    import ctypes as _c
    _fields_ = [('target', _c.c_int), ('format', _c.c_int), ('flags', _c.c_int), ('samples', _c.c_int), ('width', _c.c_uint32), ('height', _c.c_uint32),
                ('depth', _c.c_uint32), ('levels', _c.c_uint32), ('stride', _c.c_uint32), ('pkg_layout', _c.c_uint16), ('gob_order', _c.c_uint16)]


_lay = None
def layout_lib(so):
    global _lay
    if _lay is None:
        import ctypes
        _lay = ctypes.CDLL(so); _lay.nvn_tex_level_offset.restype = ctypes.c_uint64; _lay.nvn_tex_layout.restype = None
        _lay.nvn_deswizzle.argtypes = (ctypes.POINTER(_Desc), ctypes.c_uint, ctypes.c_uint, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_size_t)
    return _lay


def build_layout_lib(folder):
    import subprocess
    root = Path(__file__).resolve().parents[1]; srcs = [root / 'dm/gfx/tex/nvn_deswizzle.c', root / 'dm/gfx/nvn/nvn_tex.c']; so = Path(folder) / 'nvn_layout.dylib'
    if not so.exists() or any(so.stat().st_mtime < s.stat().st_mtime for s in srcs):
        subprocess.run(['cc', '-O2', '-shared', '-fPIC', '-o', str(so), *map(str, srcs)], check=True)
    return str(so)


def side_astc(d, i, start, size, nvn_fmt, srgb, so):
    """(side entry dict or None, PSNR, '' or why not) for the BC1 / BC4 texture whose BRTI is at i and storage at d[start:start + size]"""
    import ctypes, numpy as np, texture2ddecoder as T, astc_encoder as A
    if d[i + 0x11] != 2 or struct.unpack_from('<I', d, i + 0x5c)[0] != 1 or struct.unpack_from('<i', d, i + 0x30)[0] != 1: return None, 0.0, 'not a 2D texture of one layer'
    w, h = struct.unpack_from('<ii', d, i + 0x24); mips, = struct.unpack_from('<H', d, i + 0x16); lay, = struct.unpack_from('<I', d, i + 0x34)
    L = layout_lib(so); dsc = _Desc(1, nvn_fmt, 0, 0, w, h, 1, mips, 0, ((lay & 0xff) | ((lay >> 8) & 0xf) << 8) + 1, 0)
    src = ctypes.create_string_buffer(bytes(d[start:start + size]), size); levels = []
    for l in range(mips):
        lw, lh = max(1, w >> l), max(1, h >> l); bw, bh = (lw + 3) // 4, (lh + 3) // 4; pitch = bw * 8; lin = ctypes.create_string_buffer(pitch * bh)
        if L.nvn_deswizzle(ctypes.byref(dsc), l, 0, src, lin, pitch): return None, 0.0, 'deswizzle refused'
        if nvn_fmt == 0x49:
            v = np.clip(np.rint(bc4_values(lin.raw, False) * 255), 0, 255).astype(np.uint8)   # (n, 16), blocks row-major
            img = np.zeros((bh * 4, bw * 4, 4), np.uint8); img[..., 3] = 255
            img[..., 0] = v.reshape(bh, bw, 4, 4).transpose(0, 2, 1, 3).reshape(bh * 4, bw * 4)
        else: img = np.frombuffer(T.decode_bc1(lin.raw, bw * 4, bh * 4), np.uint8).reshape(bh * 4, bw * 4, 4)[..., [2, 1, 0, 3]].copy()   # BGRA → RGBA
        levels.append(np.ascontiguousarray(img[:lh, :lw]))
    sw = A.ASTCSwizzle.from_str('rgba'); prof = A.ASTCProfile.LDR_SRGB if srgb else A.ASTCProfile.LDR
    for bx, by in SIDE_BLOCKS:
        for q in ((A.ASTCQualityPreset.MEDIUM,) if (bx, by) != (4, 4) else (A.ASTCQualityPreset.MEDIUM, A.ASTCQualityPreset.THOROUGH)):
            c = A.ASTCContext(A.ASTCConfig(prof, bx, by, 1, q)); out, se, npx = [], 0.0, 0
            for img in levels:
                lh, lw = img.shape[:2]; ai = A.ASTCImage(A.ASTCType.U8, lw, lh, 1, img.tobytes())
                blk = c.compress(ai, sw); back = np.frombuffer(c.decompress(blk, A.ASTCImage(A.ASTCType.U8, lw, lh, 1), sw).data, np.uint8).reshape(lh, lw, 4)
                if any(blk[k:k + 16] == bytes(16) for k in range(0, len(blk), 16)): break   # ASTC's reserved block (magenta on Metal): try the next
                se += float(np.sum((back.astype(np.float64) - img.astype(np.float64)) ** 2)); npx += lw * lh * 4; out.append(blk)
            else:
                psnr = 999.0 if se == 0 else 10 * np.log10(255 ** 2 / (se / npx))
                if psnr >= 40.0 or (bx, by, q) == (4, 4, A.ASTCQualityPreset.THOROUGH):
                    fp = tex_fp(d, i, start, size, nvn_fmt, so)
                    if fp is None: return None, 0.0, 'storage size differs from the host layout'
                    return {'fp': fp, 'fmt': nvn_fmt, 'w': w, 'h': h, 'bx': bx, 'by': by, 'levels': mips, 'srgb': int(srgb), 'data': b''.join(out)}, psnr, ''
    return None, 0.0, 'no ASTC block'


def etc2_recode(blocks, srgb):
    """(ETC2 RGB8 blocks of the same size, PSNR against the BC1 decoding, '' or why it is left): etcpak, on the stored (sRGB-encoded where the texture is sRGB) values"""
    import numpy as np, etcpak, texture2ddecoder as T
    n = len(blocks) // 8; W = min(n, ROW); H = (n + W - 1) // W
    ref = np.frombuffer(T.decode_bc1(blocks + bytes(8 * (W * H - n)), 4 * W, 4 * H), np.uint8).reshape(4 * H, 4 * W, 4)   # BGRA
    if (ref[..., 3] < 255).any(): return None, 0.0, 'transparent texels'   # BC1's 1-bit alpha: ETC2 RGB8 has none
    c = etcpak.compress_etc2_rgb(ref[..., [2, 1, 0, 3]].copy().tobytes(), 4 * W, 4 * H)
    out = np.frombuffer(T.decode_etc2(c, 4 * W, 4 * H), np.uint8).reshape(ref.shape)
    m = float(np.mean((out[..., :3].astype(np.float64) - ref[..., :3].astype(np.float64)) ** 2))
    return c[:8 * n], (999.0 if m == 0 else 10 * np.log10(255 ** 2 / m)), ''


def bc6_recode(blocks, _srgb):
    """(ASTC 4x4 HDR blocks of the same size, PSNR of the two decodings tone-mapped x / (1 + x), '' or why it is left)"""
    import numpy as np, imagecodecs as ic, astc_encoder as A
    n = len(blocks) // 16; W = min(n, ROW); H = (n + W - 1) // W
    rgb = ic.bcn_decode(blocks + bytes(16 * (W * H - n)), 6, shape=(4 * H, 4 * W, 3)).astype(np.float32)   # BC6H unsigned float
    src = np.ones((4 * H, 4 * W, 4), np.float16); src[..., :3] = rgb
    c_ = A.ASTCContext(A.ASTCConfig(A.ASTCProfile.HDR, 4, 4, 1, A.ASTCQualityPreset.THOROUGH)); sw = A.ASTCSwizzle.from_str('rgba')
    img = A.ASTCImage(A.ASTCType.F16, 4 * W, 4 * H, 1, src.tobytes())
    c = c_.compress(img, sw); back = c_.decompress(c, A.ASTCImage(A.ASTCType.F16, 4 * W, 4 * H, 1), sw)
    out = np.frombuffer(back.data, np.float16).reshape(src.shape)[..., :3].astype(np.float64)
    tm = lambda x: np.maximum(x, 0) / (1 + np.maximum(x, 0))
    m = float(np.mean((tm(out) - tm(rgb.astype(np.float64))) ** 2))
    return c[:16 * n], (999.0 if m == 0 else 10 * np.log10(1 / m)), ''


def left_to_side(d, i, start, size, nvn_fmt, srgb, lay, side, st, rows, name, kind, w, h):
    """A texture left as BC: its ASTC copy into side (SIDE_FILE) when it can have one; counted and reported either way"""
    ent, psnr, why = side_astc(d, i, start, size, nvn_fmt, srgb, lay) if lay else (None, 0.0, 'no layout library')
    if ent: side.append(ent); st[f'{kind} left as BC, ASTC {ent["bx"]}x{ent["by"]} copy'] += 1; rows.append((name, kind, w, h, f'side ASTC {ent["bx"]}x{ent["by"]}', f'{psnr:.2f}'))
    else: st[f'{kind} left as BC, no copy ({why})'] += 1; rows.append((name, kind, w, h, f'left: {why}', ''))


def convert_bntx(d, bases, st, rows, path, quality, min_psnr, floor_psnr, eac=False, prints=None, lay=None, side=None):
    """d (a decompressed file, a bytearray) with the BC3 / BC7 textures of its BNTX containers re-encoded in place; returns whether it changed. bases: where each BNTX starts
    (0 for a .bntx; inside an effect's BYML or a layout's SARC, wherever they are embedded): a BRTI's pointers count from the BNTX that holds it, the last one before it.
    Every block keeps its size, so the offsets of an enclosing container stay right"""
    changed = False; i = d.find(b'BRTI')
    while i >= 0 and i + 0xa0 <= len(d):
        base = max((b for b in bases if b <= i), default=-1)
        if base < 0: i = d.find(b'BRTI', i + 4); continue
        fmt, = struct.unpack_from('<I', d, i + 0x1c); t, var = fmt >> 8, fmt & 0xff
        if t == BC2: st['BC2, left'] += 1
        if eac and (t, var) in {(m[0], m[1]) for m in MARKER.values()}:
            # A texture of the game's own in a marker format (Animal Crossing: one BC4 snorm, Model/FldUnit): kept as it is and named in the side table with no copy (bx 0), so the
            # host makes it in its own format rather than as the EAC the marker means (nvn_mtl.m bc_recoded r 3). Only a 2D texture of one layer can be named (the host's match)
            size, = struct.unpack_from('<I', d, i + 0x50); ptrs, = struct.unpack_from('<Q', d, i + 0x70); ptrs += base if ptrs else 0
            start = base + struct.unpack_from('<Q', d, ptrs)[0] if 0 < ptrs and ptrs + 8 <= len(d) else 0
            w, h = struct.unpack_from('<ii', d, i + 0x24); mips, = struct.unpack_from('<H', d, i + 0x16)
            one2d = d[i + 0x11] == 2 and struct.unpack_from('<I', d, i + 0x5c)[0] == 1 and struct.unpack_from('<i', d, i + 0x30)[0] == 1
            fp = tex_fp(d, i, start, size, MARKER_NVN[(t, var)], lay) if lay and one2d and base < start and start + size <= len(d) else None
            if side is not None and fp is not None:
                side.append({'fp': fp, 'fmt': MARKER_NVN[(t, var)], 'w': w, 'h': h, 'bx': 0, 'by': 0, 'levels': mips, 'srgb': 0, 'data': b''})
                st["game's own texture in a marker format, kept (side entry)"] += 1; rows.append((f'{path}', f'{fmt:#x}', w, h, 'own marker-format texture: kept', ''))
            else: st['MARKER FORMAT ALREADY USED'] += 1; rows.append((f'{path}', f'{fmt:#x}', 0, 0, 'marker format in use', ''))
            i = d.find(b'BRTI', i + 4); continue
        if eac and (t, var) in MARKER:
            mt, mv, kind = MARKER[(t, var)]
            size, = struct.unpack_from('<I', d, i + 0x50); ptrs, = struct.unpack_from('<Q', d, i + 0x70)
            ptrs += base if ptrs else 0
            start = base + struct.unpack_from('<Q', d, ptrs)[0] if 0 < ptrs and ptrs + 8 <= len(d) else 0
            w, h = struct.unpack_from('<ii', d, i + 0x24); name = f'{path} #{st["textures seen"]}'; st['textures seen'] += 1
            bb = 8 if kind == 'BC4' else 16   # BC4 → R11: 8-byte blocks; the BC5 kinds → RG11: 16
            if size % bb or start <= base or start + size > len(d):
                st[f'{kind} layout unreadable, left'] += 1; rows.append((name, kind, w, h, 'left: layout', ''))
            else:
                eacb, psnr, eq = eac_recode(bytes(d[start:start + size]), kind, eac, min_psnr)
                if eq == 'thorough': st['re-encoded thorough (EAC)'] += 1
                # EAC's tables are fixed shapes where BC4 spaces its 8 levels freely, so a smooth gradient can stay a little under --min-psnr even thoroughly encoded: such a
                # texture is left as BC (the host decodes the few left on a GPU without BC, small single- or two-channel textures) rather than kept with a visible loss
                if psnr < max(floor_psnr, min_psnr):
                    if kind == 'BC4': left_to_side(d, i, start, size, 0x49, False, lay, side, st, rows, name, kind, w, h)
                    else: st[f'{kind} under --min-psnr after the thorough encoder, left as BC'] += 1; rows.append((name, kind, w, h, 'left: psnr', f'{psnr:.2f}'))
                else:
                    d[start:start + size] = eacb; struct.pack_into('<I', d, i + 0x1c, mt << 8 | mv)
                    changed = True; st[f'{kind} → EAC'] += 1; st['bytes'] += size
                    st['psnr sum'] += psnr; st['psnr min'] = psnr if not st['psnr min'] else min(st['psnr min'], psnr)
                    rows.append((name, kind, w, h, {'BC4': 'EAC R11 ', 'BC5 snorm': 'EAC RG11 snorm ', 'BC5 unorm': 'EAC RG11 '}[kind] + eq, f'{psnr:.2f}'))
            i = d.find(b'BRTI', i + 4); continue
        if eac and t in (BC1, BC6) and (t, var) != (BC6, FLOAT):   # BC1 → ETC2 (fingerprinted), BC6H ufloat → ASTC 4x4 HDR; BC6H float is the BC5 snorm marker
            size, = struct.unpack_from('<I', d, i + 0x50); ptrs, = struct.unpack_from('<Q', d, i + 0x70)
            ptrs += base if ptrs else 0
            start = base + struct.unpack_from('<Q', d, ptrs)[0] if 0 < ptrs and ptrs + 8 <= len(d) else 0
            w, h = struct.unpack_from('<ii', d, i + 0x24); name = f'{path} #{st["textures seen"]}'; st['textures seen'] += 1
            kind = 'BC1' if t == BC1 else 'BC6H'; bb = 8 if t == BC1 else 16
            if size % bb or start <= base or start + size > len(d):
                st[f'{kind} layout unreadable, left'] += 1; rows.append((name, kind, w, h, 'left: layout', ''))
            else:
                new, psnr, why = (etc2_recode if t == BC1 else bc6_recode)(bytes(d[start:start + size]), var == SRGB)
                if t == BC1 and not why and (not lay or d[i + 0x11] != 2 or struct.unpack_from('<I', d, i + 0x5c)[0] != 1 or struct.unpack_from('<i', d, i + 0x30)[0] != 1):
                    why = 'not a 2D texture of one layer (the host matches those only)'
                elif t == BC1 and not why:
                    old = bytes(d[start:start + size]); d[start:start + size] = new
                    fp = tex_fp(d, i, start, size, 0x46 if var == SRGB else 0x42, lay); d[start:start + size] = old
                    if fp is None: why = 'storage size differs from the host layout'
                if why or psnr < max(floor_psnr, min_psnr):
                    if t == BC1: left_to_side(d, i, start, size, 0x46 if var == SRGB else 0x42, var == SRGB, lay, side, st, rows, name, kind, w, h)
                    else: st[f'{kind} left as BC ({why or "under --min-psnr"})'] += 1; rows.append((name, kind, w, h, f'left: {why or "psnr"}', f'{psnr:.2f}' if psnr else ''))
                else:
                    d[start:start + size] = new; changed = True
                    if t == BC1 and prints is not None: prints.append(fp)
                    st[f'{kind} → {"ETC2 RGB8" if t == BC1 else "ASTC 4x4 HDR"}'] += 1; st['bytes'] += size
                    st['psnr sum'] += psnr; st['psnr min'] = psnr if not st['psnr min'] else min(st['psnr min'], psnr)
                    rows.append((name, kind, w, h, 'ETC2 RGB8' if t == BC1 else 'ASTC 4x4 HDR', f'{psnr:.2f}'))
            i = d.find(b'BRTI', i + 4); continue
        if t in CONVERT and var in (UNORM, SRGB):
            w, h = struct.unpack_from('<ii', d, i + 0x24); mips, = struct.unpack_from('<H', d, i + 0x16)
            size, = struct.unpack_from('<I', d, i + 0x50); ptrs, = struct.unpack_from('<Q', d, i + 0x70)
            ptrs += base if ptrs else 0
            start = base + struct.unpack_from('<Q', d, ptrs)[0] if 0 < ptrs and ptrs + 8 <= len(d) else 0
            name = f'{path} #{st["textures seen"]}'; st['textures seen'] += 1
            if not mips or size % 16 or start <= base or start + size > len(d):
                st[f'{CONVERT[t]} layout unreadable, left'] += 1; rows.append((name, CONVERT[t], w, h, 'left: layout', '')); i = d.find(b'BRTI', i + 4); continue
            srgb = var == SRGB; blocks = bytes(d[start:start + size])
            bgra, bw, bh, n = decode_blocks(t, blocks)
            astc, psnr = encode_check(bgra, bw, bh, n, srgb, quality); q = quality
            if psnr < min_psnr and quality != 'thorough':
                astc2, psnr2 = encode_check(bgra, bw, bh, n, srgb, 'thorough')
                if psnr2 > psnr: astc, psnr, q = astc2, psnr2, 'thorough'
                st['re-encoded thorough'] += 1
            zero = sum(1 for k in range(0, len(astc), 16) if not any(astc[k:k + 16]))
            if zero: st['all-zero ASTC block, left'] += 1; rows.append((name, CONVERT[t], w, h, 'left: zero block', f'{psnr:.2f}'))
            elif psnr < floor_psnr: st[f'{CONVERT[t]} below the floor, left'] += 1; rows.append((name, CONVERT[t], w, h, 'left: psnr', f'{psnr:.2f}'))
            else:
                d[start:start + size] = astc
                struct.pack_into('<I', d, i + 0x1c, ASTC4 << 8 | var)
                changed = True; st[f'{CONVERT[t]}{" sRGB" if srgb else ""} → ASTC 4x4'] += 1; st['bytes'] += size
                st['psnr sum'] += psnr; st['psnr min'] = psnr if not st['psnr min'] else min(st['psnr min'], psnr)
                rows.append((name, CONVERT[t], w, h, f'ASTC 4x4 {q}', f'{psnr:.2f}'))
        i = d.find(b'BRTI', i + 4)
    return changed


def convert_file(args):
    """(path, new .zs bytes or None, Counter, report rows, BC1 fingerprints, side ASTC entries)"""
    path, raw, quality, min_psnr, floor_psnr, eac, lay = args
    st, rows, prints, side = collections.Counter(), [], [], []
    try: d = bytearray(zstd.decompress(raw))
    except Exception: st['not zstd'] += 1; return path, None, st, rows, prints, side
    bases, j = [], d.find(b'BNTX\0\0\0\0')   # the BNTX header's magic, padded to 8 bytes
    while j >= 0: bases.append(j); j = d.find(b'BNTX\0\0\0\0', j + 8)
    if not bases: return path, None, st, rows, prints, side
    st['BNTX files' if bases == [0] else 'files with embedded BNTX'] += 1
    changed = convert_bntx(d, bases, st, rows, path, quality, min_psnr, floor_psnr, eac, prints, lay, side)
    if not changed: return path, None, st, rows, prints, side
    return path, zstd.compress(bytes(d), 15), st, rows, prints, side   # level 15: about the game's own ratio, still fast to read back


def main():
    ap = argparse.ArgumentParser(description="re-encode a BNTX game's BC3 / BC7 textures as ASTC 4x4 in a RomFS image")
    ap.add_argument('src'); ap.add_argument('dst')
    ap.add_argument('--quality', choices=('medium', 'thorough'), default='medium')
    ap.add_argument('--min-psnr', type=float, default=40.0, help='below this, encode again at the thorough preset (default 40 dB)')
    ap.add_argument('--floor-psnr', type=float, default=34.0, help='below this, keep the texture as BC and list it (default 34 dB)')
    ap.add_argument('--jobs', type=int, default=os.cpu_count()); ap.add_argument('--limit', type=int, default=0); ap.add_argument('--match', default='')
    ap.add_argument('--report', default='', help='a TSV of every texture looked at: name, format, size, result, PSNR')
    ap.add_argument('--dry-run', action='store_true', help='convert and check, write no image')
    ap.add_argument('--merge-tables', action='append', default=[], metavar='IMAGE',
                    help="another converted image (a DLC's: the host reads the tables only from the game's own image) whose BC1 fingerprints and side copies go into this image's tables too")
    ap.add_argument('--eac', action='store_true', help='also recode BC4 unorm and BC5 snorm as EAC under marker formats; the build then needs DM_BC_RECODE=1 in its env.txt')
    a = ap.parse_args()
    idx = romfs_image.read_index(a.src)
    files = [(p, o, s) for p, (d, o, s) in idx.items() if not d and p.endswith('.zs') and (not a.match or a.match in p)]
    if a.limit: files = files[:a.limit]
    so = build_eac_hq(os.path.dirname(os.path.abspath(a.dst))) if a.eac else ''   # passed to the workers as the --eac switch too
    lay = build_layout_lib(os.path.dirname(os.path.abspath(a.dst))) if a.eac else ''
    t0 = time.time(); new, total, report, done, bc1_prints, side_all = {}, collections.Counter(), [], 0, set(), []
    with open(a.src, 'rb') as f:
        def jobs():
            for p, o, s in files: f.seek(o); yield (p, f.read(s), a.quality, a.min_psnr, a.floor_psnr, so, lay)
        with cf.ProcessPoolExecutor(a.jobs) as ex:
            for path, data, st, rows, pr, sd in ex.map(convert_file, jobs(), chunksize=8):
                bc1_prints.update(pr); side_all.extend(sd)
                total.update({k: v for k, v in st.items() if k != 'psnr min'})
                if st['psnr min']: total['psnr min'] = st['psnr min'] if not total['psnr min'] else min(total['psnr min'], st['psnr min'])
                report += rows; done += 1
                if data is not None: new[path] = data
                if done % 2000 == 0: print(f'  {done}/{len(files)} files, {len(new)} rewritten, {time.time() - t0:.0f} s', flush=True)
    for other in a.merge_tables:   # a DLC's converted textures: their fingerprints and copies, matched by content wherever the texture comes from (nvn_mtl.m bc_recoded)
        oidx = romfs_image.read_index(other); n1 = n2 = 0
        with open(other, 'rb') as of:
            if BC1_TABLE in oidx:
                _, o, s_ = oidx[BC1_TABLE]; of.seek(o); t = of.read(s_)
                if t[:8] == b'DMBC1TB2': c, = struct.unpack_from('<Q', t, 8); bc1_prints.update(struct.unpack_from(f'<{c}Q', t, 16)); n1 = c
            if SIDE_FILE in oidx:
                _, o, s_ = oidx[SIDE_FILE]; of.seek(o); t = of.read(s_)
                if t[:8] == b'DMBCAS02':
                    c, = struct.unpack_from('<I', t, 8); ents = [struct.unpack_from('<QQIHHBBBB', t, 16 + 28 * k) for k in range(c)]; base = 16 + 28 * c
                    offs = sorted({e[1] for e in ents} | {len(t) - base})   # a copy's data runs to the next copy's (16-byte padded); a kept entry (bx 0) has none
                    for e in ents:
                        end = next(x for x in offs if x > e[1]) if e[5] else e[1]
                        side_all.append({'fp': e[0], 'fmt': e[2], 'w': e[3], 'h': e[4], 'bx': e[5], 'by': e[6], 'levels': e[7], 'srgb': e[8], 'data': t[base + e[1]:base + end]})
                    n2 = c
        print(f'  merged from {other}: {n1} BC1 fingerprints, {n2} side entries')
    conv = sum(v for k, v in total.items() if '→' in k)
    if total['MARKER FORMAT ALREADY USED']: sys.exit(f'stopped: {total["MARKER FORMAT ALREADY USED"]} textures already use a marker format (BC4 snorm / BC6H float); --eac cannot relabel unambiguously')
    if a.eac: print('  --eac: build the app with DM_BC_RECODE=1 in its env.txt, or the recoded textures read as garbage')
    print(f'{done} .zs files read ({total["BNTX files"]} BNTX), {len(new)} rewritten in {time.time() - t0:.0f} s')
    for k, v in sorted(total.items()):
        if k not in ('bytes', 'psnr sum', 'psnr min', 'BNTX files', 'textures seen'): print(f'  {k}: {v}')
    if conv: print(f'  {conv} textures, {total["bytes"] / 2**20:.0f} MB converted (same size); PSNR against the BC picture: mean {total["psnr sum"] / conv:.2f} dB, lowest {total["psnr min"]:.2f} dB')
    if a.report:
        with open(a.report, 'w') as r:
            r.write('texture\tformat\twidth\theight\tresult\tpsnr\n'); r.writelines('\t'.join(map(str, row)) + '\n' for row in sorted(report, key=lambda x: (x[5] == '', float(x[5] or 0))))
        print(f'  report: {a.report}')
    if a.eac: print(f'  {len(bc1_prints)} BC1 fingerprints → /{BC1_TABLE}')
    if a.dry_run: return
    if bc1_prints:   # the table at the image's root, beside the game's own folders (the host reads it from DM_ROMFS: nvn_mtl.m bc1_table_load)
        new[BC1_TABLE] = b'DMBC1TB2' + struct.pack('<Q', len(bc1_prints)) + b''.join(struct.pack('<Q', x) for x in sorted(bc1_prints))
        idx[BC1_TABLE] = (False, 0, 0)
    if side_all:   # one copy per fingerprint (the same texture is in several effects' files)
        ents_s = sorted({e['fp']: e for e in side_all}.values(), key=lambda e: e['fp']); head, data = bytearray(), bytearray()
        for e in ents_s:
            head += struct.pack('<QQIHHBBBB', e['fp'], len(data), e['fmt'], e['w'], e['h'], e['bx'], e['by'], e['levels'], e['srgb'])
            data += e['data'] + bytes(-len(e['data']) % 16)
        new[SIDE_FILE] = b'DMBCAS02' + struct.pack('<II', len(ents_s), 0) + bytes(head) + bytes(data); idx[SIDE_FILE] = (False, 0, 0)
        print(f'  {len(ents_s)} ASTC copies, {len(data) / 2**20:.1f} MB → /{SIDE_FILE}')
    # the output image: the same tree, the rewritten files in place of the old ones (as LumiOS-Platinum's astc_textures.py writes it)
    kids = {'': []}
    for path, (d, off, size) in idx.items():
        kids.setdefault(path.rsplit('/', 1)[0] if '/' in path else '', []).append(path)
        if d: kids.setdefault(path, [])
    ents = [[b'', '', True, 0, 0]]; i = 0
    while i < len(ents):
        name, path, isdir, _, _ = ents[i]
        if isdir:
            ch = sorted(kids.get(path, ()), key=lambda c: c.rsplit('/', 1)[-1].encode())
            ents[i][3], ents[i][4] = len(ents), len(ch)
            ents.extend([c.rsplit('/', 1)[-1].encode(), c, idx[c][0], 0, 0] for c in ch)
        i += 1
    part = a.dst + '.part'
    with open(a.src, 'rb') as inp, open(part, 'wb') as out:
        out.write(b'\0' * romfs_image.HEAD.size); pos = romfs_image.HEAD.size
        for e in ents:
            if e[2]: continue
            if e[1] in new: out.write(new[e[1]]); size = len(new[e[1]])
            else:
                _, off, size = idx[e[1]]; inp.seek(off); left = size
                while left: b = inp.read(min(left, 8 << 20)); out.write(b); left -= len(b)
            e[3], e[4] = pos, size; pos += size
        head, index = romfs_image.layout(ents, pos)
        out.write(index); out.seek(0); out.write(head)
    os.replace(part, a.dst)
    print(f'done: {a.dst} ({os.path.getsize(a.dst) / 1e9:.2f} GB)')


if __name__ == '__main__':
    main()
