/*
  This file is part of Hull.

  Hull is free software: you can redistribute it and/or modify it under the terms of the GNU
  Lesser General Public License as published by the Free Software Foundation, either version 3 of
  the License, or (at your option) any later version.

  Hull is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even
  the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU Lesser
  General Public License for more details.

  You should have received a copy of the GNU Lesser General Public License along with Hull. If
  not, see <https://www.gnu.org/licenses/>.
*/

#define _GNU_SOURCE

#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

void b64(const char *in, uint8_t *out) {
  int v[256] = {0};
  for (int i = 0; i < 64; ++i) {
    v[(int)"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"[i]] = i;
  }

  uint8_t *p = out;
  for (; *in && *in != '='; in += 4) {
    uint32_t n = v[(int)in[0]] << 18 | v[(int)in[1]] << 12 |
                 (in[2] == '=' ? 0 : v[(int)in[2]]) << 6 | (in[3] == '=' ? 0 : v[(int)in[3]]);
    *p++ = n >> 16;
    if (in[2] != '=') *p++ = n >> 8;
    if (in[3] != '=') *p++ = n;
  }
}

void lz4D(const uint8_t *src, uint8_t *dst, size_t *dlen) {
  uint8_t *d = dst;

  if (*(uint32_t *)src == 0x184D2204) {
    /* LZ4 Frame Magic */
    uint8_t flg = src[4];
    /* Skip Frame Header (Magic, FLG, BD, Opt. Content Size, Opt. Dict ID, HC) */
    src += 7 + ((flg >> 3) & 1 ? 8 : 0) + ((flg >> 0) & 1 ? 4 : 0);
    int bchk = (flg >> 4) & 1; /* Block checksum flag */

    while (1) {
      uint32_t bs = *(uint32_t *)src;
      src += 4;
      if (bs == 0) break; /* EndMark */

      if (bs & 0x80000000) { /* Uncompressed block */
        bs &= 0x7FFFFFFF;
        memcpy(d, src, bs);
        d += bs;
        src += bs;
      } else {
        /* Compressed block */
        const uint8_t *end = src + bs;
        while (src < end) {
          uint8_t tok = *src++;
          uint32_t ll = tok >> 4; /* Literal length */
          if (ll == 15) {
            while (*src == 255) ll += *src++;
            ll += *src++;
          }

          memcpy(d, src, ll);
          d += ll;
          src += ll;
          if (src >= end) break;

          uint16_t off = *(uint16_t *)src;
          src += 2;                     /* Offset */
          uint32_t ml = (tok & 15) + 4; /* Match length */
          if (ml == 19) {
            while (*src == 255) ml += *src++;
            ml += *src++;
          }

          /* Match copy (must use byte-loop to handle overlapping ranges properly) */
          uint8_t *m = d - off;
          while (ml--) *d++ = *m++;
        }
      }
      if (bchk) src += 4; /* Skip optional Block Checksum */
    }
  }
  *dlen = d - dst;
}

#define BIN_OUT_BUF_LEN (/* HULL_RAW_SIZE */ +10)
#define B64_OUT_BUF_LEN (/* HULL_LZ4_SIZE */ +10)
const char b64_str[] = "HULL_B64_STR";

uint8_t b64_out_buf[B64_OUT_BUF_LEN];
uint8_t bin_out_buf[BIN_OUT_BUF_LEN];

int main(int argc, char **argv) {
  (void)argc;
  size_t so_size = 0;
  b64(b64_str, b64_out_buf);
  lz4D(b64_out_buf, bin_out_buf, &so_size);
  int fd = memfd_create("fd", 0);
  write(fd, bin_out_buf, so_size);
  char pth[256];
  sprintf(pth, "/proc/self/fd/%d", fd);
  execve(pth, argv, NULL);
  return -1;
}
