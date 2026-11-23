// BC textures decoded on the GPU, for a GPU without BC formats (A14-A16 iPhones; nvn_mtl.m bcd_*): a texture the game makes in a BC format is made in an uncompressed stand-in format
// (RGBA8 / sRGB for BC1, BC2, BC3, BC7; R8 / RG8, unorm or snorm, for BC4 / BC5), and each copy of BC blocks into it is this kernel instead: one thread per 4x4 block, which decodes
// the block and writes its texels' bytes, as they would read, through an integer view of the stand-in (RGBA8Uint, R8Uint, RG8Uint: the bytes land as they are, sRGB and snorm
// alike). Blocks are read from src, block rows `row` bytes apart; the region is w x h texels at (ox, oy) of layer `slice`, level `level`, clipped to it.
// BC1-5 follow the D3D10 block formats; BC7 its eight modes. The BC7 partition and anchor tables are the format's own, as tabulated in texture2ddecoder's bcn.cpp
// (MIT License, Copyright (c) 2020 K0lb3; dm/third_party/README.md); the decoding below is written for this kernel.
#include <metal_stdlib>
using namespace metal;

struct BD { ulong row; uint w, h, ox, oy, slice, level, fmt, sn; };   // fmt: 1 BC1, 2 BC2, 3 BC3, 4 BC4, 5 BC5, 7 BC7; sn: BC4 / BC5 signed

constant ushort P2[64] = {
    0xcccc, 0x8888, 0xeeee, 0xecc8, 0xc880, 0xfeec, 0xfec8, 0xec80, 0xc800, 0xffec, 0xfe80, 0xe800, 0xffe8, 0xff00, 0xfff0, 0xf000,
    0xf710, 0x008e, 0x7100, 0x08ce, 0x008c, 0x7310, 0x3100, 0x8cce, 0x088c, 0x3110, 0x6666, 0x366c, 0x17e8, 0x0ff0, 0x718e, 0x399c,
    0xaaaa, 0xf0f0, 0x5a5a, 0x33cc, 0x3c3c, 0x55aa, 0x9696, 0xa55a, 0x73ce, 0x13c8, 0x324c, 0x3bdc, 0x6996, 0xc33c, 0x9966, 0x0660,
    0x0272, 0x04e4, 0x4e40, 0x2720, 0xc936, 0x936c, 0x39c6, 0x639c, 0x9336, 0x9cc6, 0x817e, 0xe718, 0xccf0, 0x0fcc, 0x7744, 0xee22};
constant uint P3[64] = {
    0xaa685050, 0x6a5a5040, 0x5a5a4200, 0x5450a0a8, 0xa5a50000, 0xa0a05050, 0x5555a0a0, 0x5a5a5050, 0xaa550000, 0xaa555500, 0xaaaa5500, 0x90909090, 0x94949494, 0xa4a4a4a4, 0xa9a59450, 0x2a0a4250,
    0xa5945040, 0x0a425054, 0xa5a5a500, 0x55a0a0a0, 0xa8a85454, 0x6a6a4040, 0xa4a45000, 0x1a1a0500, 0x0050a4a4, 0xaaa59090, 0x14696914, 0x69691400, 0xa08585a0, 0xaa821414, 0x50a4a450, 0x6a5a0200,
    0xa9a58000, 0x5090a0a8, 0xa8a09050, 0x24242424, 0x00aa5500, 0x24924924, 0x24499224, 0x50a50a50, 0x500aa550, 0xaaaa4444, 0x66660000, 0xa5a0a5a0, 0x50a050a0, 0x69286928, 0x44aaaa44, 0x66666600,
    0xaa444444, 0x54a854a8, 0x95809580, 0x96969600, 0xa85454a8, 0x80959580, 0xaa141414, 0x96960000, 0xaaaa1414, 0xa05050a0, 0xa0a5a5a0, 0x96000000, 0x40804080, 0xa9a8a9a8, 0xaaaaaa44, 0x2a4a5254};
constant uchar A2[64] = {15,15,15,15,15,15,15,15, 15,15,15,15,15,15,15,15, 15,2,8,2,2,8,8,15, 2,8,2,2,8,8,2,2, 15,15,6,8,2,8,15,15, 2,8,2,2,2,15,15,6, 6,2,6,8,15,15,2,2, 15,15,15,15,15,2,2,15};
constant uchar A3a[64] = {3,3,15,15,8,3,15,15, 8,8,6,6,6,5,3,3, 3,3,8,15,3,3,6,10, 5,8,8,6,8,5,15,15, 8,15,3,5,6,10,8,15, 15,3,15,5,15,15,15,15, 3,15,5,5,5,8,5,10, 5,10,8,13,15,12,3,3};
constant uchar A3b[64] = {15,8,8,3,15,15,3,8, 15,15,15,15,15,15,15,8, 15,8,15,3,15,8,15,8, 3,15,6,10,15,15,10,8, 15,3,15,10,10,8,9,10, 6,15,8,15,3,6,6,8, 15,3,15,15,15,15,15,15, 15,15,15,15,3,15,15,8};
constant uchar W2[4] = {0, 21, 43, 64};
constant uchar W3[8] = {0, 9, 18, 27, 37, 46, 55, 64};
constant uchar W4[16] = {0, 4, 9, 13, 17, 21, 26, 30, 34, 38, 43, 47, 51, 55, 60, 64};
// BC7 modes: subsets, partition bits, rotation bits, index-selection bits, colour bits, alpha bits, a P-bit per endpoint, a shared P-bit per subset, index bits, second index bits
constant uchar M7[8][10] = {{3,4,0,0,4,0,1,0,3,0}, {2,6,0,0,6,0,0,1,3,0}, {3,6,0,0,5,0,0,0,2,0}, {2,6,0,0,7,0,1,0,2,0},
                            {1,0,2,1,5,6,0,0,2,3}, {1,0,2,0,7,8,0,0,2,2}, {1,0,0,0,7,7,1,0,4,0}, {2,6,0,0,5,5,1,0,2,0}};

struct Bits { uint4 q; uint pos; };   // a 128-bit block read from bit 0 up
static uint bits(thread Bits &b, uint n) {
    if (!n) return 0;
    uint r = 0;
    for (uint i = 0; i < n; i++, b.pos++) r |= ((b.q[b.pos >> 5] >> (b.pos & 31)) & 1u) << i;
    return r;
}
static uint weight(uint nbits, uint i) { return nbits == 2 ? W2[i] : nbits == 3 ? W3[i] : W4[i]; }

// BC1's colour block (8 bytes at lo, hi), texel i; four colours when forced (BC2 / BC3) or c0 > c1, else three and transparent black
static uchar4 bc1_texel(uint lo, uint hi, uint i, bool four) {
    uint c0 = lo & 0xffff, c1 = lo >> 16;   // 5:6:5 widened to 8 bits by repeating the top bits, as hardware does
    uint3 a = uint3(((c0 >> 8) & 0xf8) | (c0 >> 13), ((c0 >> 3) & 0xfc) | ((c0 >> 9) & 3), ((c0 << 3) & 0xf8) | ((c0 >> 2) & 7));
    uint3 b = uint3(((c1 >> 8) & 0xf8) | (c1 >> 13), ((c1 >> 3) & 0xfc) | ((c1 >> 9) & 3), ((c1 << 3) & 0xf8) | ((c1 >> 2) & 7));
    uint k = (hi >> (2 * i)) & 3;
    if (k == 0) return uchar4(uchar3(a), 255);
    if (k == 1) return uchar4(uchar3(b), 255);
    if (four || c0 > c1) return uchar4(uchar3(k == 2 ? (2 * a + b) / 3 : (a + 2 * b) / 3), 255);
    return k == 2 ? uchar4(uchar3((a + b) / 2), 255) : uchar4(0);
}
// BC4's block (8 bytes at lo, hi), texel i: the byte as it reads (unsigned), or as an int8 bit pattern (signed, -127..127)
static uint bc4_texel(uint lo, uint hi, uint i, bool sn) {
    ulong idx = ((ulong)hi << 16 | (lo >> 16)); uint k = (uint)(idx >> (3 * i)) & 7;
    if (!sn) {
        float r0 = float(lo & 0xff), r1 = float((lo >> 8) & 0xff), v;
        if (k == 0) v = r0; else if (k == 1) v = r1;
        else if (r0 > r1) v = ((8 - k) * r0 + (k - 1) * r1) / 7;
        else v = k == 6 ? 0.0f : k == 7 ? 255.0f : ((6 - k) * r0 + (k - 1) * r1) / 5;
        return uint(clamp(rint(v), 0.0f, 255.0f));
    }
    float r0 = max(float(as_type<char>(uchar(lo & 0xff))), -127.0f), r1 = max(float(as_type<char>(uchar((lo >> 8) & 0xff))), -127.0f), v;
    if (k == 0) v = r0; else if (k == 1) v = r1;
    else if (r0 > r1) v = ((8 - k) * r0 + (k - 1) * r1) / 7;
    else v = k == 6 ? -127.0f : k == 7 ? 127.0f : ((6 - k) * r0 + (k - 1) * r1) / 5;
    return uint(int(clamp(rint(v), -127.0f, 127.0f))) & 0xff;
}
static uchar4 bc7_texel(uint4 q, uint i) {
    uint mode = 0; while (mode < 8 && !((q.x >> mode) & 1u)) mode++;
    if (mode >= 8) return uchar4(0);
    constant uchar *m = M7[mode];
    Bits b = {q, mode + 1};
    uint ns = m[0], part = bits(b, m[1]), rot = bits(b, m[2]), isel = bits(b, m[3]), cb = m[4], ab = m[5];
    uint e[6][4];   // endpoints (two a subset), r g b a, as read
    for (uint c = 0; c < 3; c++) for (uint j = 0; j < 2 * ns; j++) e[j][c] = bits(b, cb);
    for (uint j = 0; j < 2 * ns; j++) e[j][3] = ab ? bits(b, ab) : 255;
    uint cbits = cb, abits = ab;
    if (m[6]) { for (uint j = 0; j < 2 * ns; j++) { uint p = bits(b, 1); for (uint c = 0; c < 3; c++) e[j][c] = e[j][c] << 1 | p; if (ab) e[j][3] = e[j][3] << 1 | p; } cbits++; if (ab) abits++; }
    if (m[7]) { for (uint s = 0; s < ns; s++) { uint p = bits(b, 1); for (uint c = 0; c < 3; c++) { e[2 * s][c] = e[2 * s][c] << 1 | p; e[2 * s + 1][c] = e[2 * s + 1][c] << 1 | p; } } cbits++; }
    for (uint j = 0; j < 2 * ns; j++) {
        for (uint c = 0; c < 3; c++) { uint v = e[j][c] << (8 - cbits); e[j][c] = v | (v >> cbits); }
        if (ab) { uint v = e[j][3] << (8 - abits); e[j][3] = v | (v >> abits); }
    }
    uint sub = ns == 2 ? (P2[part] >> i) & 1u : ns == 3 ? (P3[part] >> (2 * i)) & 3u : 0;
    uint a1 = ns == 2 ? A2[part] : ns == 3 ? A3a[part] : 16, a2 = ns == 3 ? A3b[part] : 16;
    // the index of texel i in the first set: earlier texels' indices first, anchors one bit short
    uint ib = m[8], ix = 0;
    for (uint t = 0; t <= i; t++) { uint n = (t == 0 || t == a1 || t == a2) ? ib - 1 : ib; uint v = bits(b, n); if (t == i) ix = v; }
    for (uint t = i + 1; t < 16; t++) b.pos += (t == 0 || t == a1 || t == a2) ? ib - 1 : ib;
    uint ib2 = m[9], ix2 = 0;
    if (ib2) for (uint t = 0; t <= i; t++) { uint v = bits(b, t == 0 ? ib2 - 1 : ib2); if (t == i) ix2 = v; }
    uint ci = ix, ai = ix, cw = ib, aw = ib;
    if (ib2) { if (isel) { ci = ix2; cw = ib2; } else { ai = ix2; aw = ib2; } }
    uint4 o;
    for (uint c = 0; c < 3; c++) { uint w = weight(cw, ci); o[c] = ((64 - w) * e[2 * sub][c] + w * e[2 * sub + 1][c] + 32) >> 6; }
    { uint w = weight(aw, ai); o[3] = ab ? ((64 - w) * e[2 * sub][3] + w * e[2 * sub + 1][3] + 32) >> 6 : 255; }
    if (rot) { uint t = o[3]; o[3] = o[rot - 1]; o[rot - 1] = t; }   // rotation: alpha swapped with r (1), g (2) or b (3)
    return uchar4(o);
}

kernel void bcdec(device const uchar *src [[buffer(0)]], constant BD& p [[buffer(2)]], texture2d_array<uint, access::write> dst [[texture(0)]], uint2 id [[thread_position_in_grid]]) {
    uint bw = (p.w + 3) / 4, bh = (p.h + 3) / 4;
    if (id.x >= bw || id.y >= bh) return;
    uint bb = (p.fmt == 1 || p.fmt == 4) ? 8 : 16;
    device const uint *s = (device const uint *)(src + (ulong)id.y * p.row + (ulong)id.x * bb);   // blocks are 8-byte aligned in the staging the host copies from
    uint4 q = bb == 8 ? uint4(s[0], s[1], 0, 0) : uint4(s[0], s[1], s[2], s[3]);
    for (uint i = 0; i < 16; i++) {
        uint x = id.x * 4 + (i & 3), y = id.y * 4 + (i >> 2);
        if (x >= p.w || y >= p.h) continue;
        uint4 v;
        switch (p.fmt) {
            case 1: v = uint4(bc1_texel(q.x, q.y, i, false)); break;
            case 2: { uint4 c = uint4(bc1_texel(q.z, q.w, i, true)); uint a = ((i < 8 ? q.x : q.y) >> (4 * (i & 7))) & 15; v = uint4(c.rgb, a * 17); break; }
            case 3: { uint4 c = uint4(bc1_texel(q.z, q.w, i, true)); v = uint4(c.rgb, bc4_texel(q.x, q.y, i, false)); break; }
            case 4: v = uint4(bc4_texel(q.x, q.y, i, p.sn), 0, 0, 0); break;
            case 5: v = uint4(bc4_texel(q.x, q.y, i, p.sn), bc4_texel(q.z, q.w, i, p.sn), 0, 0); break;
            default: v = uint4(bc7_texel(q, i)); break;
        }
        dst.write(v, uint2(p.ox + x, p.oy + y), p.slice, p.level);
    }
}
