#include <cstdio>
#include <cstdlib>
int getbit() {
  int c = getchar();
  while (c < '0' || c > '1') {
    c = getchar();
  }
  return c;
}
unsigned a, b;
void qaq() {
  a = ((rand() & 32767) << 30) + ((rand() & 32767) << 15) + (rand() & 32767);
  b = ((rand() & 32767) << 30) + ((rand() & 32767) << 15) + (rand() & 32767);
}
unsigned qwq(unsigned x) { return (static_cast<__int128>(a) * x + b) % 4294967311LL; }
void print(int x, int len) {
  while (x >= (1 << len)) {
    putchar('1');
    len++;
  }
  putchar('0');
  for (int i = 0; i < len; i++) {
    if (x & (1 << i)) {
      putchar('1');
    } else {
      putchar('0');
    }
  }
}
void get(int& x, int len) {
  while (getbit() == '1') {
    len++;
  }
  x = 0;
  for (int i = 0; i < len; i++) {
    if (getbit() == '1') {
      x |= (1 << i);
    }
  }
}
void print1(unsigned x) {
  for (int i = 0; i < 10; i++) {
    if (x & (1 << i)) {
      putchar('1');
    } else {
      putchar('0');
    }
  }
}
void get1(unsigned& x) {
  x = 0;
  for (int i = 0; i < 10; i++) {
    if (getbit() == '1') {
      x |= (1 << i);
    }
  }
}
char tp[1024];
unsigned k[1024];
unsigned v[1024];
unsigned k1[1024], v1[1024];
struct node {
  node* ls;
  node* rs;
  int l;
  int r;
  unsigned a;
  unsigned b;
};
node nn[2048];
int num = 0;
node* build(int l, int r) {
  node* root = &nn[num];
  num++;
  root->l = l;
  root->r = r;
  if (r - l + 1 == 8) {
    if (tp[0] == 'e') {
      for (int i = l; i <= r; i++) {
        k1[i] = k[i];
        v1[i] = v[i];
      }
      int numr;
      for (numr = 1;; numr++) {
        qaq();
        for (int i = l; i <= r; i++) {
          v[i] = 100000;
        }
        for (int i = l; i <= r; i++) {
          unsigned wz = (qwq(k1[i]) & 7) + l;
          k[wz] = k1[i];
          v[wz] = v1[i];
        }
        bool ok = true;
        for (int i = l; i <= r; i++) {
          if (v[i] > 5000) {
            ok = false;
            break;
          }
        }
        if (ok) {
          break;
        }
      }
      print(numr, 8);
      for (int i = l; i <= r; i++) {
        print1(v[i]);
      }
    } else {
      int numr;
      get(numr, 8);
      while (numr--) {
        qaq();
      }
      root->a = a;
      root->b = b;
      for (int i = l; i <= r; i++) {
        get1(v[i]);
      }
    }
    return root;
  }
  int mid = (l + r) >> 1;
  int len;
  for (len = 0;; len++) {
    if ((1 << (len << 1)) >= r - l + 1) {
      break;
    }
  }
  if (tp[0] == 'e') {
    int numr;
    for (numr = 1;; numr++) {
      qaq();
      int numk = 0;
      for (int i = l; i <= r; i++) {
        if (qwq(k[i]) & 1) {
          numk++;
        }
      }
      if (numk == mid - l + 1) {
        break;
      }
    }
    for (int i = l; i <= r; i++) {
      k1[i] = k[i];
      v1[i] = v[i];
    }
    int now1 = l, now2 = mid + 1;
    for (int i = l; i <= r; i++) {
      if (qwq(k1[i]) & 1) {
        k[now1] = k1[i];
        v[now1] = v1[i];
        now1++;
      } else {
        k[now2] = k1[i];
        v[now2] = v1[i];
        now2++;
      }
    }
    print(numr, len);
  } else {
    int numr;
    get(numr, len);
    while (numr--) {
      qaq();
    }
    root->a = a;
    root->b = b;
  }
  root->ls = build(l, mid);
  root->rs = build(mid + 1, r);
  return root;
}
unsigned query(node* root, unsigned k) {
  a = root->a;
  b = root->b;
  if (root->r - root->l + 1 == 8) {
    return v[(qwq(k) & 7) + root->l];
  }
  if (qwq(k) & 1) {
    return query(root->ls, k);
  } else {
    return query(root->rs, k);
  }
}
int main() {
  srand(19260817);
  scanf("%s", tp);
  if (tp[0] == 'e') {
    for (int i = 0; i < 1024; i++) {
      scanf("%u%u", &k[i], &v[i]);
    }
  }
  node* root = build(0, 1023);
  if (tp[0] == 'd') {
    int q;
    scanf("%d", &q);
    while (q--) {
      unsigned k;
      scanf("%u", &k);
      printf("%u\n", query(root, k));
    }
  }
  return 0;
}
