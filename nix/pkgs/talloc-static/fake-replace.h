#ifndef _FAKE_REPLACE_H
#define _FAKE_REPLACE_H

#define _GNU_SOURCE 1
#define _XOPEN_SOURCE 700

#include <ctype.h>
#include <errno.h>
#include <inttypes.h>
#include <limits.h>
#include <malloc.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/auxv.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

#ifndef _PUBLIC_
#define _PUBLIC_ __attribute__((visibility("default")))
#endif

#ifndef PRINTF_ATTRIBUTE
#define PRINTF_ATTRIBUTE(a1, a2) __attribute__((format(__printf__, a1, a2)))
#endif

#ifndef discard_const_p
#define discard_const_p(type, ptr) ((type *)((intptr_t)(ptr)))
#endif

#ifndef likely
#define likely(x) __builtin_expect(!!(x), 1)
#endif

#ifndef unlikely
#define unlikely(x) __builtin_expect(!!(x), 0)
#endif

#ifndef MIN
#define MIN(a, b) ((a) < (b) ? (a) : (b))
#endif

#ifndef __location__
#define __TALLOC_STRING_LINE1__(s) #s
#define __TALLOC_STRING_LINE2__(s) __TALLOC_STRING_LINE1__(s)
#define __TALLOC_STRING_LINE3__ __TALLOC_STRING_LINE2__(__LINE__)
#define __location__ __FILE__ ":" __TALLOC_STRING_LINE3__
#endif

#ifndef va_copy
#define va_copy(dest, src) __builtin_va_copy(dest, src)
#endif

#endif
