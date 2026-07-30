#include <stdio.h>

int main() {
  int n;
  scanf("%d", &n);
  for (int i = 0; i <= 50; ++i) {
    puts("Q 1");
    fflush(stdout);
    char response[64];
    if (scanf("%1s", response) != 1) break;
  }
  return 0;
}
