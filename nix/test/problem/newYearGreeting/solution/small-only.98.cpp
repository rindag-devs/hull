#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <cstring>

const int N = 1200;
char s[1000000];
int n = 1024, q, into[N];

struct node {
  int thing, into;
} A[N];
bool cmp(node a, node b) { return a.thing < b.thing; }
void decode() {
  scanf("\n%s", s + 1);
  int len = static_cast<int>(strlen(s + 1)), i, x, j, t;
  for (i = 2, t = 0; i <= len; i += 10) {
    x = 0;
    for (j = 0; j < 10; j++) x = x * 2 + (s[i + j] - '0');
    into[t++] = x;
  }
  scanf("%d", &q);
  while (q--) {
    scanf("%d", &x);
    printf("%d\n", into[x]);
  }
}
void encode() {
  int i, flag = 1, j;
  for (i = 1; i <= n; i++) {
    scanf("%d %d", &A[i].thing, &A[i].into);
    if (A[i].thing >= 1024) flag = 0;
  }
  printf("%d", flag);
  std::sort(A + 1, A + 1 + n, cmp);
  for (i = 1; i <= n; i++) {
    for (j = 9; j >= 0; j--) printf("%d", (A[i].into >> j) & 1);
  }
}
int main() {
  scanf("\n%s", s + 1);
  if (s[1] == 'e') {
    encode();
  } else {
    decode();
  }
  return 0;
}
