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

#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif

#include <elf.h>
#include <link.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/types.h>
#include <unistd.h>

#ifndef __cplusplus
#include <stdbool.h>
#endif

#ifdef __cplusplus
extern "C" {
#endif

void __register_frame(void *);
void __deregister_frame(void *);
int *__errno_location(void);

#ifdef __cplusplus
}
#endif

#define SO_OUT_BUF_LEN (/* HULL_RAW_SIZE */ +16)
#define B64_OUT_BUF_LEN (/* HULL_LZ4_SIZE */ +16)
static const char b64_str[] = "HULL_B64_STR";

static unsigned char b64_out_buf[B64_OUT_BUF_LEN];
static unsigned char so_out_buf[SO_OUT_BUF_LEN];
static unsigned char g_dummy_tls[4096];

struct TlsIndex {
  uint64_t ti_module;
  uint64_t ti_offset;
};

struct TlsDesc {
  void *entry;
  uintptr_t arg;
};

struct LoadedSO {
  unsigned char *file;
  size_t file_sz;

  unsigned char *base;
  size_t map_sz;

  Elf64_Ehdr *eh;
  Elf64_Phdr *ph;
  Elf64_Dyn *dynamic;

  const char *dynstr;
  Elf64_Sym *dynsym;
  size_t dynsym_cnt;

  Elf64_Rela *rela;
  size_t rela_cnt;

  Elf64_Rela *jmprela;
  size_t jmprela_cnt;

  void (**init_array)(void);
  size_t init_array_cnt;

  void (**fini_array)(void);
  size_t fini_array_cnt;

  void (*init_func)(void);
  void (*fini_func)(void);

  void *eh_frame;
  bool eh_frame_registered;

  uintptr_t relro_start;
  size_t relro_sz;

  Elf64_Addr tls_vaddr;
  size_t tls_filesz;
  size_t tls_memsz;
  size_t tls_align;

  void *tls_block;
  size_t tls_block_size;
  uint64_t tls_module_id;
};

static struct LoadedSO g_so;

static void die(const char *msg) {
  if (msg) {
    write(2, msg, strlen(msg));
    write(2, "\n", 1);
  }
  _exit(120);
}

static size_t page_size_cached(void) {
  static size_t p = 0;
  if (!p) p = (size_t)sysconf(_SC_PAGESIZE);
  return p;
}

static uintptr_t pg_down(uintptr_t x) {
  size_t p = page_size_cached();
  return x & ~(uintptr_t)(p - 1);
}

static uintptr_t pg_up(uintptr_t x) {
  size_t p = page_size_cached();
  return (x + p - 1) & ~(uintptr_t)(p - 1);
}

static void *x_mmap(void *addr, size_t len, int prot, int flags, int fd, off_t off) {
  void *p = mmap(addr, len, prot, flags, fd, off);
  if (p == MAP_FAILED) die("mmap failed");
  return p;
}

static size_t align_up_sz(size_t x, size_t a) {
  if (a <= 1) return x;
  return ((x + a - 1) / a) * a;
}

static uintptr_t get_tp(void) {
#if defined(__x86_64__)
  uintptr_t tp;
  __asm__ __volatile__("movq %%fs:0, %0" : "=r"(tp));
  return tp;
#else
#error unsupported arch
#endif
}

static void force_link_libm(void) {
  volatile long long a = llround(0.0);
  volatile double b = sin((double)a);
  (void)a;
  (void)b;
}

static void b64(const char *in, uint8_t *out) {
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

static void lz4D(const uint8_t *src, uint8_t *dst, size_t *dlen) {
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

#ifdef __cplusplus
extern "C"
#endif
    void *__tls_get_addr(void *arg) {
  struct TlsIndex *ti = (struct TlsIndex *)arg;

  if (ti->ti_module == g_so.tls_module_id) {
    if (g_so.tls_block) {
      return (void *)((uintptr_t)g_so.tls_block + ti->ti_offset);
    }
    return (void *)((uintptr_t)g_dummy_tls + ti->ti_offset);
  }

  return (void *)((uintptr_t)g_dummy_tls + ti->ti_offset);
}

#ifdef __cplusplus
extern "C"
#endif
    uintptr_t _root_tlsdesc_static(void);

__asm__(
    ".text\n"
    ".global _root_tlsdesc_static\n"
    "_root_tlsdesc_static:\n"
    "    mov 8(%rax), %rax\n"
    "    ret\n");

static void parse_dynsym_from_shdr(struct LoadedSO *so) {
  Elf64_Shdr *sh;
  const char *shstr;
  int i;

  so->dynsym = NULL;
  so->dynstr = NULL;
  so->dynsym_cnt = 0;
  so->eh_frame = NULL;

  if (!so->eh->e_shoff || !so->eh->e_shnum) return;

  sh = (Elf64_Shdr *)(so->file + so->eh->e_shoff);
  shstr = NULL;

  if (so->eh->e_shstrndx != SHN_UNDEF) {
    shstr = (const char *)(so->file + sh[so->eh->e_shstrndx].sh_offset);
  }

  for (i = 0; i < so->eh->e_shnum; ++i) {
    if (sh[i].sh_type == SHT_DYNSYM) {
      so->dynsym = (Elf64_Sym *)(so->base + sh[i].sh_addr);
      so->dynsym_cnt = sh[i].sh_size / sizeof(Elf64_Sym);
      if (sh[i].sh_link < so->eh->e_shnum) {
        so->dynstr = (const char *)(so->file + sh[sh[i].sh_link].sh_offset);
      }
    }

    if (shstr) {
      const char *nm = shstr + sh[i].sh_name;
      if (!strcmp(nm, ".eh_frame")) {
        so->eh_frame = so->base + sh[i].sh_addr;
      }
    }
  }
}

static size_t gnu_hash_symcount(uint32_t *gh) {
  uint32_t nbuckets = gh[0];
  uint32_t symoffset = gh[1];
  uint32_t bloom_size = gh[2];
  Elf64_Xword *bloom = (Elf64_Xword *)(gh + 4);
  uint32_t *buckets = (uint32_t *)(bloom + bloom_size);
  uint32_t *chains = buckets + nbuckets;
  uint32_t max_sym = symoffset;
  uint32_t i;

  (void)gh[3];

  for (i = 0; i < nbuckets; ++i) {
    uint32_t b = buckets[i];
    if (b < symoffset) continue;

    {
      uint32_t idx = b;
      for (;;) {
        uint32_t h = chains[idx - symoffset];
        if (idx + 1 > max_sym) max_sym = idx + 1;
        if (h & 1U) break;
        ++idx;
      }
    }
  }

  return (size_t)max_sym;
}

static void *decode_dyn_ptr(uintptr_t base, Elf64_Addr p) {
  uintptr_t up = (uintptr_t)p;
#if defined(__x86_64__)
  if (up >= 0x400000ULL && up < 0x0000800000000000ULL) {
    return (void *)up;
  }
#endif
  return (void *)(base + up);
}

struct LookupCtx {
  const char *name;
  void *result;
};

static int phdr_lookup_cb(struct dl_phdr_info *info, size_t size, void *data) {
  struct LookupCtx *ctx = (struct LookupCtx *)data;
  uintptr_t base;
  const Elf64_Phdr *phdr;
  Elf64_Half phnum;
  Elf64_Dyn *dyn;
  Elf64_Sym *symtab;
  const char *strtab;
  uint32_t *sysv_hash;
  uint32_t *gnu_hash;
  Elf64_Half i;
  size_t nsyms;
  size_t j;

  (void)size;

  if (ctx->result) return 1;

  base = (uintptr_t)info->dlpi_addr;
  phdr = (const Elf64_Phdr *)info->dlpi_phdr;
  phnum = info->dlpi_phnum;
  dyn = NULL;

  for (i = 0; i < phnum; ++i) {
    if (phdr[i].p_type == PT_DYNAMIC) {
      dyn = (Elf64_Dyn *)(base + phdr[i].p_vaddr);
      break;
    }
  }
  if (!dyn) return 0;

  symtab = NULL;
  strtab = NULL;
  sysv_hash = NULL;
  gnu_hash = NULL;

  for (; dyn->d_tag != DT_NULL; ++dyn) {
    switch (dyn->d_tag) {
      case DT_SYMTAB:
        symtab = (Elf64_Sym *)decode_dyn_ptr(base, dyn->d_un.d_ptr);
        break;
      case DT_STRTAB:
        strtab = (const char *)decode_dyn_ptr(base, dyn->d_un.d_ptr);
        break;
      case DT_HASH:
        sysv_hash = (uint32_t *)decode_dyn_ptr(base, dyn->d_un.d_ptr);
        break;
      case DT_GNU_HASH:
        gnu_hash = (uint32_t *)decode_dyn_ptr(base, dyn->d_un.d_ptr);
        break;
      default:
        break;
    }
  }

  if (!symtab || !strtab) return 0;

  if (sysv_hash) {
    nsyms = (size_t)sysv_hash[1];
  } else if (gnu_hash) {
    nsyms = gnu_hash_symcount(gnu_hash);
  } else {
    return 0;
  }

  for (j = 0; j < nsyms; ++j) {
    Elf64_Sym *s = &symtab[j];
    unsigned bind;
    unsigned type;
    const char *nm;

    if (!s->st_name) continue;
    if (s->st_shndx == SHN_UNDEF) continue;

    bind = ELF64_ST_BIND(s->st_info);
    if (!(bind == STB_GLOBAL || bind == STB_WEAK)) continue;

    type = ELF64_ST_TYPE(s->st_info);
    if (type == STT_TLS) continue;

    nm = strtab + s->st_name;
    if (strcmp(nm, ctx->name) != 0) continue;

#ifdef STT_GNU_IFUNC
    if (type == STT_GNU_IFUNC) {
      void *(*resolver)(void) = (void *(*)(void))(base + s->st_value);
      ctx->result = resolver();
      return 1;
    }
#endif

    ctx->result = (void *)(base + s->st_value);
    return 1;
  }

  return 0;
}

static void *lookup_loaded_symbol_addr(const char *name) {
  struct LookupCtx ctx;
  ctx.name = name;
  ctx.result = NULL;
  dl_iterate_phdr(phdr_lookup_cb, &ctx);
  return ctx.result;
}

static void load_needed_libs(struct LoadedSO *so) { (void)so; }

static void *resolve_sym_addr(struct LoadedSO *so, size_t idx) {
  Elf64_Sym *sym;
  const char *name;
  void *p;

  if (idx >= so->dynsym_cnt) die("bad sym idx");

  sym = &so->dynsym[idx];

  if (sym->st_shndx != SHN_UNDEF) {
    return so->base + sym->st_value;
  }

  name = so->dynstr + sym->st_name;

  if (!strcmp(name, "__tls_get_addr")) {
    return (void *)&__tls_get_addr;
  }

  p = lookup_loaded_symbol_addr(name);
  if (!p) {
    if (ELF64_ST_BIND(sym->st_info) == STB_WEAK) return NULL;
    die(name);
  }
  return p;
}

static uintptr_t resolve_tls_tpoff(struct LoadedSO *so, size_t symi, Elf64_Sxword addend) {
  Elf64_Sym *sym;
  uintptr_t tp;
  const char *name;

  if (symi >= so->dynsym_cnt) die("bad tls sym idx");

  sym = &so->dynsym[symi];
  tp = get_tp();

  if (sym->st_shndx != SHN_UNDEF) {
    uintptr_t base = g_so.tls_block ? (uintptr_t)g_so.tls_block : (uintptr_t)g_dummy_tls;
    uintptr_t var_addr = base + sym->st_value + addend;
    return var_addr - tp;
  }

  name = so->dynstr + sym->st_name;

  if (!strcmp(name, "errno")) {
    void *p = (void *)__errno_location();
    return (uintptr_t)p + addend - tp;
  }

  if (ELF64_ST_BIND(sym->st_info) == STB_WEAK) return 0;
  return (uintptr_t)g_dummy_tls + addend - tp;
}

static void init_tls(struct LoadedSO *so) {
  void *blk;
  uintptr_t p;
  size_t al;

  if (so->tls_memsz == 0) return;

  al = so->tls_align ? so->tls_align : 1;
  so->tls_block_size = align_up_sz(so->tls_memsz, al);

  blk = mmap(NULL, so->tls_block_size + al + 64, PROT_READ | PROT_WRITE,
             MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
  if (blk == MAP_FAILED) die("tls mmap failed");

  p = (uintptr_t)blk;
  if (al > 1) p = (p + al - 1) & ~(uintptr_t)(al - 1);

  so->tls_block = (void *)p;
  memset(so->tls_block, 0, so->tls_block_size);
  memcpy(so->tls_block, so->base + so->tls_vaddr, so->tls_filesz);
}

static void apply_one_rela(struct LoadedSO *so, Elf64_Rela *r) {
  uint32_t type = ELF64_R_TYPE(r->r_info);
  uint32_t symi = ELF64_R_SYM(r->r_info);
  Elf64_Addr *where = (Elf64_Addr *)(so->base + r->r_offset);

  switch (type) {
    case R_X86_64_NONE:
      break;

    case R_X86_64_RELATIVE:
      *where = (Elf64_Addr)(so->base + r->r_addend);
      break;

    case R_X86_64_GLOB_DAT:
    case R_X86_64_JUMP_SLOT:
    case R_X86_64_64: {
      void *sym = resolve_sym_addr(so, symi);
      *where = (Elf64_Addr)((uintptr_t)sym + r->r_addend);
      break;
    }

    case R_X86_64_IRELATIVE: {
      Elf64_Addr (*resolver)(void) = (Elf64_Addr (*)(void))(so->base + r->r_addend);
      *where = resolver();
      break;
    }

    case R_X86_64_DTPMOD64:
      *where = so->tls_module_id;
      break;

    case R_X86_64_DTPOFF64: {
      Elf64_Sym *sym;
      if (symi >= so->dynsym_cnt) die("bad tls sym idx");
      sym = &so->dynsym[symi];
      *where = sym->st_value + r->r_addend;
      break;
    }

    case R_X86_64_TPOFF64:
      *where = (Elf64_Addr)resolve_tls_tpoff(so, symi, r->r_addend);
      break;

    case R_X86_64_TLSDESC: {
      struct TlsDesc *td = (struct TlsDesc *)where;
      uintptr_t tpoff = resolve_tls_tpoff(so, symi, r->r_addend);
      td->entry = (void *)&_root_tlsdesc_static;
      td->arg = tpoff;
      break;
    }

    case R_X86_64_TLSDESC_CALL:
      break;

    default:
      die("unsupported relocation");
  }
}

static void protect_segments(struct LoadedSO *so) {
  int i;

  for (i = 0; i < so->eh->e_phnum; ++i) {
    Elf64_Phdr *p = &so->ph[i];
    uintptr_t seg_b;
    uintptr_t seg_e;
    int prot;

    if (p->p_type != PT_LOAD) continue;

    seg_b = pg_down((uintptr_t)(so->base + p->p_vaddr));
    seg_e = pg_up((uintptr_t)(so->base + p->p_vaddr + p->p_memsz));
    prot = 0;
    if (p->p_flags & PF_R) prot |= PROT_READ;
    if (p->p_flags & PF_W) prot |= PROT_WRITE;
    if (p->p_flags & PF_X) prot |= PROT_EXEC;

    if (mprotect((void *)seg_b, seg_e - seg_b, prot) != 0) {
      die("mprotect failed");
    }
  }

  if (so->relro_sz) {
    uintptr_t b = pg_down(so->relro_start);
    uintptr_t e = pg_up(so->relro_start + so->relro_sz);
    if (mprotect((void *)b, e - b, PROT_READ) != 0) {
      die("relro mprotect failed");
    }
  }
}

static void call_init(struct LoadedSO *so) {
  size_t i;
  if (so->init_func) so->init_func();
  for (i = 0; i < so->init_array_cnt; ++i) {
    if (so->init_array[i]) so->init_array[i]();
  }
}

static void call_fini(void) {
  size_t i;

  for (i = g_so.fini_array_cnt; i > 0; --i) {
    if (g_so.fini_array[i - 1]) g_so.fini_array[i - 1]();
  }

  if (g_so.fini_func) g_so.fini_func();

  if (g_so.eh_frame_registered && g_so.eh_frame) {
    __deregister_frame(g_so.eh_frame);
    g_so.eh_frame_registered = false;
  }
}

static void map_so_from_memory(struct LoadedSO *so) {
  Elf64_Addr minva, maxva;
  int i;

  so->eh = (Elf64_Ehdr *)so->file;
  if (memcmp(so->eh->e_ident, ELFMAG, SELFMAG) != 0) die("not elf");
  if (so->eh->e_ident[EI_CLASS] != ELFCLASS64) die("not elf64");
  if (so->eh->e_machine != EM_X86_64) die("not x86_64");
  if (so->eh->e_type != ET_DYN) die("not ET_DYN");

  so->ph = (Elf64_Phdr *)(so->file + so->eh->e_phoff);

  minva = (Elf64_Addr)-1;
  maxva = 0;

  for (i = 0; i < so->eh->e_phnum; ++i) {
    Elf64_Phdr *p = &so->ph[i];
    if (p->p_type != PT_LOAD) continue;

    {
      Elf64_Addr b = pg_down(p->p_vaddr);
      Elf64_Addr e = pg_up(p->p_vaddr + p->p_memsz);
      if (b < minva) minva = b;
      if (e > maxva) maxva = e;
    }
  }

  if (minva == (Elf64_Addr)-1) die("no PT_LOAD");

  so->map_sz = maxva - minva;
  so->base = (unsigned char *)x_mmap(NULL, so->map_sz, PROT_READ | PROT_WRITE | PROT_EXEC,
                                     MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);

  for (i = 0; i < so->eh->e_phnum; ++i) {
    Elf64_Phdr *p = &so->ph[i];
    unsigned char *dst;

    if (p->p_type != PT_LOAD) continue;
    if (p->p_offset + p->p_filesz > so->file_sz) die("bad segment");

    dst = so->base + p->p_vaddr;
    memcpy(dst, so->file + p->p_offset, p->p_filesz);
    if (p->p_memsz > p->p_filesz) {
      memset(dst + p->p_filesz, 0, p->p_memsz - p->p_filesz);
    }
  }

  so->dynamic = NULL;
  so->rela = NULL;
  so->rela_cnt = 0;
  so->jmprela = NULL;
  so->jmprela_cnt = 0;
  so->init_array = NULL;
  so->init_array_cnt = 0;
  so->fini_array = NULL;
  so->fini_array_cnt = 0;
  so->init_func = NULL;
  so->fini_func = NULL;
  so->eh_frame = NULL;
  so->eh_frame_registered = false;
  so->relro_start = 0;
  so->relro_sz = 0;
  so->tls_vaddr = 0;
  so->tls_filesz = 0;
  so->tls_memsz = 0;
  so->tls_align = 1;
  so->tls_block = NULL;
  so->tls_block_size = 0;
  so->tls_module_id = 1;

  for (i = 0; i < so->eh->e_phnum; ++i) {
    Elf64_Phdr *p = &so->ph[i];
    if (p->p_type == PT_DYNAMIC) {
      so->dynamic = (Elf64_Dyn *)(so->base + p->p_vaddr);
    } else if (p->p_type == PT_GNU_RELRO) {
      so->relro_start = (uintptr_t)(so->base + p->p_vaddr);
      so->relro_sz = p->p_memsz;
    } else if (p->p_type == PT_TLS) {
      so->tls_vaddr = p->p_vaddr;
      so->tls_filesz = p->p_filesz;
      so->tls_memsz = p->p_memsz;
      so->tls_align = p->p_align ? p->p_align : 1;
    }
  }

  if (!so->dynamic) die("no dynamic");

  parse_dynsym_from_shdr(so);
  if (!so->dynsym || !so->dynstr) die("no dynsym");

  {
    Elf64_Dyn *d;
    for (d = so->dynamic; d->d_tag != DT_NULL; ++d) {
      switch (d->d_tag) {
        case DT_STRTAB:
          so->dynstr = (const char *)(so->base + d->d_un.d_ptr);
          break;
        case DT_SYMTAB:
          so->dynsym = (Elf64_Sym *)(so->base + d->d_un.d_ptr);
          break;
        case DT_RELA:
          so->rela = (Elf64_Rela *)(so->base + d->d_un.d_ptr);
          break;
        case DT_RELASZ:
          so->rela_cnt = d->d_un.d_val / sizeof(Elf64_Rela);
          break;
        case DT_JMPREL:
          so->jmprela = (Elf64_Rela *)(so->base + d->d_un.d_ptr);
          break;
        case DT_PLTRELSZ:
          so->jmprela_cnt = d->d_un.d_val / sizeof(Elf64_Rela);
          break;
        case DT_INIT:
          so->init_func = (void (*)(void))(so->base + d->d_un.d_ptr);
          break;
        case DT_FINI:
          so->fini_func = (void (*)(void))(so->base + d->d_un.d_ptr);
          break;
        case DT_INIT_ARRAY:
          so->init_array = (void (**)(void))(so->base + d->d_un.d_ptr);
          break;
        case DT_INIT_ARRAYSZ:
          so->init_array_cnt = d->d_un.d_val / sizeof(void (*)(void));
          break;
        case DT_FINI_ARRAY:
          so->fini_array = (void (**)(void))(so->base + d->d_un.d_ptr);
          break;
        case DT_FINI_ARRAYSZ:
          so->fini_array_cnt = d->d_un.d_val / sizeof(void (*)(void));
          break;
        default:
          break;
      }
    }
  }

  load_needed_libs(so);
  init_tls(so);

  {
    size_t j;
    for (j = 0; j < so->rela_cnt; ++j) {
      apply_one_rela(so, &so->rela[j]);
    }
    for (j = 0; j < so->jmprela_cnt; ++j) {
      apply_one_rela(so, &so->jmprela[j]);
    }
  }

  if (so->eh_frame) {
    __register_frame(so->eh_frame);
    so->eh_frame_registered = true;
  }

  protect_segments(so);
  call_init(so);
  atexit(call_fini);
}

static int (*find_main(struct LoadedSO *so))(int, char **) {
  size_t i;

  for (i = 0; i < so->dynsym_cnt; ++i) {
    Elf64_Sym *s = &so->dynsym[i];
    const char *name = so->dynstr + s->st_name;
    if (!strcmp(name, "main")) {
      return (int (*)(int, char **))(so->base + s->st_value);
    }
  }

  die("main not found");
  return NULL;
}

int main(int argc, char **argv) {
  size_t so_size = 0;
  int (*entry)(int, char **);
  int ret;

  force_link_libm();

  b64(b64_str, b64_out_buf);
  lz4D(b64_out_buf, so_out_buf, &so_size);

  memset(&g_so, 0, sizeof(g_so));
  g_so.file = so_out_buf;
  g_so.file_sz = so_size;

  map_so_from_memory(&g_so);

  entry = find_main(&g_so);
  ret = entry(argc, argv);
  exit(ret);
}
