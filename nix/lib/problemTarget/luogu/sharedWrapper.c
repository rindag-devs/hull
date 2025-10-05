#define _GNU_SOURCE

#include <assert.h>
#include <dlfcn.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

struct sinfl {
  int bits, bitcnt;
  unsigned lits[288];
  unsigned dsts[32];
  unsigned lens[19];
  int tlit, tdist, tlen;
};

static const unsigned char sinfl_mirror[256] = {
#define R2(n) n, n + 128, n + 64, n + 192
#define R4(n) R2(n), R2(n + 32), R2(n + 16), R2(n + 48)
#define R6(n) R4(n), R4(n + 8), R4(n + 4), R4(n + 12)
    R6(0),
    R6(2),
    R6(1),
    R6(3),
};
static int sinfl_get(const unsigned char **src, const unsigned char *end, struct sinfl *s, int n) {
  const unsigned char *in = *src;
  int v = s->bits & ((1 << n) - 1);
  s->bits >>= n;
  s->bitcnt = s->bitcnt - n;
  s->bitcnt = s->bitcnt < 0 ? 0 : s->bitcnt;
  while (s->bitcnt < 16 && in < end) {
    s->bits |= (*in++) << s->bitcnt;
    s->bitcnt += 8;
  }
  *src = in;
  return v;
}
static int sinfl_build(unsigned *tree, unsigned char *lens, int symcnt) {
  int n, cnt[16], first[16], codes[16];
  memset(cnt, 0, sizeof(cnt));
  cnt[0] = first[0] = codes[0] = 0;
  for (n = 0; n < symcnt; ++n) cnt[lens[n]]++;
  for (n = 1; n <= 15; n++) {
    codes[n] = (codes[n - 1] + cnt[n - 1]) << 1;
    first[n] = first[n - 1] + cnt[n - 1];
  }
  for (n = 0; n < symcnt; n++) {
    int slot, code, len = lens[n];
    if (!len) continue;
    code = codes[len]++;
    slot = first[len]++;
    tree[slot] = (unsigned)((code << (32 - len)) | (n << 4) | len);
  }
  return first[15];
}
static int sinfl_decode(const unsigned char **in, const unsigned char *end, struct sinfl *s,
                        unsigned *tree, int max) {
/* bsearch next prefix code */
#define sinfl_rev16(n) ((sinfl_mirror[(n) & 0xff] << 8) | sinfl_mirror[((n) >> 8) & 0xff])
  unsigned key, lo = 0, hi = (unsigned)max;
  unsigned search = (unsigned)(sinfl_rev16(s->bits) << 16) | 0xffff;
  while (lo < hi) {
    unsigned guess = (lo + hi) / 2;
    if (search < tree[guess]) {
      hi = guess;
    } else {
      lo = guess + 1;
    }
  }
  /* pull out and check key */
  key = tree[lo - 1];
  sinfl_get(in, end, s, (int)key & 0x0f);
  return ((int)key >> 4) & 0x0fff;
}
int sinflate(unsigned char *out, const unsigned char *in, int size) {
  static const char order[] = {16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15};
  static const short dbase[30 + 2] = {
      1,   2,   3,   4,   5,   7,    9,    13,   17,   25,   33,   49,   65,    97,    129,
      193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577};
  static const unsigned char dbits[30 + 2] = {0,  0,  0,  0,  1,  1,  2,  2,  3, 3, 4,
                                              4,  5,  5,  6,  6,  7,  7,  8,  8, 9, 9,
                                              10, 10, 11, 11, 12, 12, 13, 13, 0, 0};
  static const short lbase[29 + 2] = {3,  4,   5,   6,   7,   8,   9,   10, 11, 13, 15,
                                      17, 19,  23,  27,  31,  35,  43,  51, 59, 67, 83,
                                      99, 115, 131, 163, 195, 227, 258, 0,  0};
  static const unsigned char lbits[29 + 2] = {0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2,
                                              3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0, 0, 0};

  const unsigned char *e = in + size, *o = out;
  enum sinfl_states { hdr, stored, fixed, dyn, blk };
  enum sinfl_states state = hdr;
  struct sinfl s;
  int last = 0;

  memset(&s, 0, sizeof(s));
  sinfl_get(&in, e, &s, 0); /* buffer input */
  while (in < e || s.bitcnt) {
    switch (state) {
      case hdr: {
        int type = 0; /* block header */
        last = sinfl_get(&in, e, &s, 1);
        type = sinfl_get(&in, e, &s, 2);

        switch (type) {
          default:
            return (int)(out - o);
          case 0x00:
            state = stored;
            break;
          case 0x01:
            state = fixed;
            break;
          case 0x02:
            state = dyn;
            break;
        }
      } break;
      case stored: {
        int len; /* uncompressed block */
        sinfl_get(&in, e, &s, s.bitcnt & 7);
        len = sinfl_get(&in, e, &s, 16);
        sinfl_get(&in, e, &s, 16);
        in -= 2;
        s.bitcnt = 0;

        if (len > (e - in) || !len) return (int)(out - o);
        memcpy(out, in, (size_t)len);
        in += len, out += len;
        state = hdr;
      } break;
      case fixed: {
        /* fixed huffman codes */
        int n;
        unsigned char lens[288 + 32];
        for (n = 0; n <= 143; n++) lens[n] = 8;
        for (n = 144; n <= 255; n++) lens[n] = 9;
        for (n = 256; n <= 279; n++) lens[n] = 7;
        for (n = 280; n <= 287; n++) lens[n] = 8;
        for (n = 0; n < 32; n++) lens[288 + n] = 5;

        /* build trees */
        s.tlit = sinfl_build(s.lits, lens, 288);
        s.tdist = sinfl_build(s.dsts, lens + 288, 32);
        state = blk;
      } break;
      case dyn: {
        /* dynamic huffman codes */
        int n, i, nlit, ndist, nlen;
        unsigned char nlens[19] = {0}, lens[288 + 32];
        nlit = 257 + sinfl_get(&in, e, &s, 5);
        ndist = 1 + sinfl_get(&in, e, &s, 5);
        nlen = 4 + sinfl_get(&in, e, &s, 4);
        for (n = 0; n < nlen; n++) nlens[(int)order[n]] = (unsigned char)sinfl_get(&in, e, &s, 3);
        s.tlen = sinfl_build(s.lens, nlens, 19);

        /* decode code lengths */
        for (n = 0; n < nlit + ndist;) {
          int sym = sinfl_decode(&in, e, &s, s.lens, s.tlen);
          switch (sym) {
            default:
              lens[n++] = (unsigned char)sym;
              break;
            case 16:
              for (i = 3 + sinfl_get(&in, e, &s, 2); i; i--, n++) lens[n] = lens[n - 1];
              break;
            case 17:
              for (i = 3 + sinfl_get(&in, e, &s, 3); i; i--, n++) lens[n] = 0;
              break;
            case 18:
              for (i = 11 + sinfl_get(&in, e, &s, 7); i; i--, n++) lens[n] = 0;
              break;
          }
        }
        /* build lit/dist trees */
        s.tlit = sinfl_build(s.lits, lens, nlit);
        s.tdist = sinfl_build(s.dsts, lens + nlit, ndist);
        state = blk;
      } break;
      case blk: {
        /* decompress block */
        int sym = sinfl_decode(&in, e, &s, s.lits, s.tlit);
        if (sym > 256) {
          sym -= 257; /* match symbol */
          {
            int len = sinfl_get(&in, e, &s, lbits[sym]) + lbase[sym];
            int dsym = sinfl_decode(&in, e, &s, s.dsts, s.tdist);
            int offs = sinfl_get(&in, e, &s, dbits[dsym]) + dbase[dsym];
            if (offs > (int)(out - o)) return (int)(out - o);
            while (len--) *out = *(out - offs), out++;
          }
        } else if (sym == 256) {
          if (last) return (int)(out - o);
          state = hdr;
        } else {
          *out++ = (unsigned char)sym;
        }
      } break;
    }
  }
  return (int)(out - o);
}

unsigned char dtb[128];

void init_tb() {
  int p = 0;
  for (int i = 'A'; i <= 'Z'; ++i) dtb[i] = p++;
  for (int i = 'a'; i <= 'z'; ++i) dtb[i] = p++;
  for (int i = '0'; i <= '9'; ++i) dtb[i] = p++;
  dtb['+'] = p++;
  dtb['/'] = p++;
}

int from_base64(const char *c, unsigned char *o, int l) {
  if (c == NULL || o == NULL || l == 0 || (l % 4) != 0) return 0;
  int p = 0;
  for (int i = 0; i < l; i += 4) {
    unsigned int s = (unsigned int)dtb[(int)c[i]] << 18 | (unsigned int)dtb[(int)c[i + 1]] << 12 |
                     (unsigned int)dtb[(int)c[i + 2]] << 6 | (unsigned int)dtb[(int)c[i + 3]];
    o[p++] = (s >> 16) & 0xFF;
    if (c[i + 2] != '=') o[p++] = (s >> 8) & 0xFF;
    if (c[i + 3] != '=') o[p++] = s & 0xFF;
  }
  return p;
}

#define FLATE_OUT_BUF_LEN (/* HULL_RAW_SO_SIZE */ +10)
#define B64_OUT_BUF_LEN (/* HULL_DEFLATE_SO_SIZE */ +10)
const char b64_str[] = "HULL_B64_STR";

unsigned char b64_out_buf[B64_OUT_BUF_LEN];
unsigned char flate_out_buf[FLATE_OUT_BUF_LEN];

int main(int argc, char **argv) {
  init_tb();
  int b64_out_size = from_base64(b64_str, b64_out_buf, strlen(b64_str));
  int so_size = sinflate(flate_out_buf, b64_out_buf + 2, b64_out_size - 6);
  int fd = memfd_create("so", 0);
  write(fd, flate_out_buf, so_size);
  char pth[256];
  sprintf(pth, "/proc/self/fd/%d", fd);
  void *handle = dlopen(pth, RTLD_NOW);
  assert(handle != NULL);
  void (*entry)(int, char **);
  *(void **)(&entry) = dlsym(handle, "main");
  char *error = dlerror();
  if (error != NULL) {
    fprintf(stderr, "%s\n", error);
    return 1;
  }
  entry(argc, argv);
}
