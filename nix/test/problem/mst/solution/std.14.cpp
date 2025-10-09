#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <vector>

using i32 = std::int32_t;
using i64 = std::int64_t;

struct FastInput {
  static const int BUFSIZE = 1 << 20;
  char buf[BUFSIZE];
  int len = 0, pos = 0;
  FastInput() { len = static_cast<int>(fread(buf, 1, BUFSIZE, stdin)); }

  inline auto nextChar() -> char {
    if (pos >= len) {
      len = static_cast<int>(fread(buf, 1, BUFSIZE, stdin));
      pos = 0;
      if (len == 0) return 0;
    }
    return buf[pos++];
  }

  template <typename T>
  auto readInt(T &out) -> bool {
    char c;
    T sign = 1;
    T val = 0;
    c = nextChar();
    if (!c) return false;
    while (c != 0 && (c == ' ' || c == '\n' || c == '\r' || c == '\t')) c = nextChar();
    if (!c) return false;
    if (c == '-') {
      sign = -1;
      c = nextChar();
    }
    while (c >= '0' && c <= '9') {
      val = val * 10 + (c - '0');
      c = nextChar();
    }
    out = val * sign;
    return true;
  }
} In;

struct FastOutput {
  static const int BUFSIZE = 1 << 20;
  char buf[BUFSIZE];
  int pos = 0;
  ~FastOutput() { flush(); }
  inline auto flush() -> void {
    if (pos) {
      fwrite(buf, 1, pos, stdout);
      pos = 0;
    }
  }
  inline auto pushChar(char c) -> void {
    if (pos == BUFSIZE) flush();
    buf[pos++] = c;
  }
  inline auto writeInt(i64 x) -> void {
    if (x == 0) {
      pushChar('0');
      return;
    }
    if (x < 0) {
      pushChar('-');
      x = -x;
    }
    char s[24];
    int n = 0;
    while (x > 0) {
      s[n++] = static_cast<char>('0' + x % 10);
      x /= 10;
    }
    for (int i = n - 1; i >= 0; --i) pushChar(s[i]);
  }
  inline auto writeChar(char c) -> void { pushChar(c); }
  inline auto writeSpace() -> void { pushChar(' '); }
  inline auto writeNewline() -> void { pushChar('\n'); }
} Out;

struct UnionFind {
  std::vector<i32> parent;
  std::vector<i32> sz;

  explicit UnionFind(i32 n) : parent(n), sz(n, 1) {
    for (i32 i = 0; i < n; ++i) parent[i] = i;
  }

  auto find(i32 i) -> i32 {
    if (parent[i] == i) return i;
    return parent[i] = find(parent[i]);
  }

  auto unite(i32 i, i32 j) -> void {
    i32 root_i = find(i);
    i32 root_j = find(j);
    if (root_i != root_j) {
      if (sz[root_i] < sz[root_j]) std::swap(root_i, root_j);
      parent[root_j] = root_i;
      sz[root_i] += sz[root_j];
    }
  }
};

struct Edge {
  i32 u, v, w, id;
};

auto solve() -> void {
  i32 n, m;
  if (!In.readInt(n)) return;
  In.readInt(m);

  std::vector<Edge> edges(m);
  for (i32 i = 0; i < m; ++i) {
    In.readInt(edges[i].u);
    In.readInt(edges[i].v);
    In.readInt(edges[i].w);
    --edges[i].u;
    --edges[i].v;
    edges[i].id = i + 1;
  }

  std::sort(edges.begin(), edges.end(), [](const Edge &a, const Edge &b) { return a.w < b.w; });

  UnionFind uf(n);
  i64 mst_total_weight = 0;
  std::vector<i32> mst_edge_indices;
  mst_edge_indices.reserve(n - 1);

  for (const auto &edge : edges) {
    if (uf.find(edge.u) != uf.find(edge.v)) {
      uf.unite(edge.u, edge.v);
      mst_total_weight += edge.w;
      mst_edge_indices.push_back(edge.id);
      if (static_cast<int>(mst_edge_indices.size()) == n - 1) break;
    }
  }

  Out.writeInt(mst_total_weight);
  Out.writeNewline();
  for (size_t i = 0; i < mst_edge_indices.size(); ++i) {
    if (i) Out.writeSpace();
    Out.writeInt(mst_edge_indices[i]);
  }
  Out.writeNewline();
}

auto main() -> int {
  int t = 1;
  In.readInt(t);
  while (t--) solve();
  Out.flush();
  return 0;
}
