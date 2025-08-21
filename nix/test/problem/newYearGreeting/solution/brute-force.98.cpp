#include <cstdio>
#include <cstring>
#include <map>

unsigned Q, i, j, k, u, v;
char opt[100005];
std::map<unsigned, unsigned> ans;

void out(unsigned x, int y) {
  if (!y) return;
  out(x >> 1, y - 1);
  printf("%u", x & 1);
}

void Encode() {
  for (i = 1; i <= 1024; ++i) {
    scanf("%u%u", &u, &v);
    out(u, 32);
    out(v, 10);
  }
  printf("\n");
}

void Decode() {
  scanf("%s", opt);
  k = 0;
  for (i = 1; i <= 1024; ++i) {
    u = v = 0;
    for (j = 1; j <= 32; ++j) u = (u << 1) + (opt[k] - '0'), ++k;
    for (j = 1; j <= 10; ++j) v = (v << 1) + (opt[k] - '0'), ++k;
    ans[u] = v;
  }
  scanf("%u", &Q);
  for (; Q; --Q) {
    scanf("%u", &u);
    printf("%u\n", ans[u]);
  }
}

int main() {
  scanf("%s", opt);
  if (opt[0] == 'e') {
    Encode();
  } else {
    Decode();
  }
}
