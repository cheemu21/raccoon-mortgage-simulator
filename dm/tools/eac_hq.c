// A thorough EAC R11 encoder (unsigned and signed), for the textures scripts/bntx_astc.py --eac finds etcpak's fast encoder too coarse on (smooth gradients: an effect's
// light and smoke masks). Per 4x4 block it tries every modifier table and multiplier, and for each a window of base codewords around the one the block's range suggests,
// keeping the least squared error over the 16 texels in the 11-bit domain. Built and loaded by bntx_astc.py through ctypes (cc -O3 -shared); no state, thread-safe.
//   eac_hq_encode(const float *v, long n, int is_signed, uint8_t *out): v holds n blocks of 16 texel values, each block's texels row-major (x + 4y), in [0, 1] (unsigned) or
//   [-1, 1] (signed); out gets n 8-byte EAC R11 blocks: base codeword, multiplier << 4 | table, 48 bits of 3-bit modifier indices, most significant first, texels in column-major
//   order (the first index is texel (0,0), then (0,1), (0,2), (0,3), (1,0), ...), as the EAC format stores them.
#include <stdint.h>
#include <math.h>

static const int TAB[16][8] = {
    {-3, -6, -9, -15, 2, 5, 8, 14}, {-3, -7, -10, -13, 2, 6, 9, 12}, {-2, -5, -8, -13, 1, 4, 7, 12}, {-2, -4, -6, -13, 1, 3, 5, 12},
    {-3, -6, -8, -12, 2, 5, 7, 11}, {-3, -7, -9, -11, 2, 6, 8, 10}, {-4, -7, -8, -11, 3, 6, 7, 10}, {-3, -5, -8, -11, 2, 4, 7, 10},
    {-2, -6, -8, -10, 1, 5, 7, 9}, {-2, -5, -8, -10, 1, 4, 7, 9}, {-2, -4, -8, -10, 1, 3, 7, 9}, {-2, -5, -7, -10, 1, 4, 6, 9},
    {-3, -4, -7, -10, 2, 3, 6, 9}, {-1, -2, -3, -10, 0, 1, 2, 9}, {-4, -6, -8, -9, 3, 5, 7, 8}, {-3, -5, -7, -9, 2, 4, 6, 8}};

static inline int clampi(int x, int lo, int hi) { return x < lo ? lo : x > hi ? hi : x; }

// The decoded 11-bit value of base b, multiplier m, modifier d (EAC: m 0 counts as 1/8)
static inline int dec(int b, int m, int d, int s) {
    int v = s ? b * 8 + (m ? d * m * 8 : d) : b * 8 + 4 + (m ? d * m * 8 : d);
    return s ? clampi(v, -1023, 1023) : clampi(v, 0, 2047);
}

void eac_hq_encode(const float *v, long n, int s, uint8_t *out) {
    for (long k = 0; k < n; k++) {
        const float *p = v + 16 * k; float t[16]; float lo = 1e9f, hi = -1e9f;
        for (int i = 0; i < 16; i++) { t[i] = s ? fmaxf(-1023.f, fminf(1023.f, p[i] * 1023.f)) : fmaxf(0.f, fminf(2047.f, p[i] * 2047.f)); lo = fminf(lo, t[i]); hi = fmaxf(hi, t[i]); }
        double best = 1e30; int bb = 0, bm = 0, bt = 0; uint8_t bi[16] = {0};
        for (int tb = 0; tb < 16; tb++) {
            int dmin = TAB[tb][3], dmax = TAB[tb][7];
            for (int m = 0; m < 16; m++) {
                double mm = m ? m * 8.0 : 1.0;
                // the base that centres the table's span on the block's range, then a window around it
                double c = ((lo + hi) * 0.5 - (s ? 0.0 : 4.0) - (dmin + dmax) * 0.5 * mm) / 8.0;
                int c0 = (int)floor(c);
                for (int b = c0 - 3; b <= c0 + 4; b++) {
                    int bc = s ? clampi(b, -127, 127) : clampi(b, 0, 255);
                    double err = 0; uint8_t ix[16];
                    int cand[8]; for (int d = 0; d < 8; d++) cand[d] = dec(bc, m, TAB[tb][d], s);
                    for (int i = 0; i < 16 && err < best; i++) {
                        double e = 1e30; int w = 0;
                        for (int d = 0; d < 8; d++) { double q = t[i] - cand[d]; q *= q; if (q < e) { e = q; w = d; } }
                        err += e; ix[i] = (uint8_t)w;
                    }
                    if (err < best) { best = err; bb = bc; bm = m; bt = tb; for (int i = 0; i < 16; i++) bi[i] = ix[i]; }
                }
            }
        }
        uint8_t *o = out + 8 * k;
        o[0] = (uint8_t)(int8_t)bb; o[1] = (uint8_t)(bm << 4 | bt);
        uint64_t bits = 0;
        for (int x = 0; x < 4; x++) for (int y = 0; y < 4; y++) bits = bits << 3 | bi[x + 4 * y];   // column-major: (0,0), (0,1), ...
        for (int j = 0; j < 6; j++) o[2 + j] = (uint8_t)(bits >> (40 - 8 * j));
    }
}
