#include <stdint.h>

#include "add.h"

int32_t add(int32_t a, int32_t b) {
  if (a < 0 || b < 0) return -12345;
  return a + b;
}
