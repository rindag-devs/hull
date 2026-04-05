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

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <sched.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

struct dir_mapping {
  char *src;
  char *dest;
  struct dir_mapping *next;
};

struct env_mapping {
  char *key;
  char *value;
  struct env_mapping *next;
};

static volatile sig_atomic_t child_died = 0;
static pid_t child_pid = 0;

static void die_errno(const char *message) {
  fprintf(stderr, "%s: %s\n", message, strerror(errno));
  exit(EXIT_FAILURE);
}

static void die_message(const char *message) {
  fprintf(stderr, "%s\n", message);
  exit(EXIT_FAILURE);
}

static void push_dir_mapping(struct dir_mapping **head, const char *src, const char *dest) {
  struct dir_mapping *node = malloc(sizeof(*node));
  if (!node) die_errno("malloc");
  node->src = strdup(src);
  node->dest = strdup(dest);
  node->next = *head;
  *head = node;
}

static void push_env_mapping(struct env_mapping **head, const char *key, const char *value) {
  struct env_mapping *node = malloc(sizeof(*node));
  if (!node) die_errno("malloc");
  node->key = strdup(key);
  node->value = strdup(value);
  node->next = *head;
  *head = node;
}

static void usage(const char *name) {
  fprintf(stderr, "Usage: %s -n <nixpath> [-m src:dest] -- <command>\n", name);
  exit(EXIT_FAILURE);
}

static void update_map(const char *mapping, const char *map_file) {
  int fd = open(map_file, O_WRONLY);
  if (fd < 0) die_errno("open uid/gid map");
  if (write(fd, mapping, strlen(mapping)) < 0) die_errno("write uid/gid map");
  close(fd);
}

static void ensure_dir_recursive(const char *path, mode_t mode) {
  char buffer[PATH_MAX];
  size_t len;
  char *cursor;

  len = strlen(path);
  if (len >= sizeof(buffer)) die_message("path too long");
  memcpy(buffer, path, len + 1);

  for (cursor = buffer + 1; *cursor; ++cursor) {
    if (*cursor != '/') continue;
    *cursor = '\0';
    if (mkdir(buffer, mode) < 0 && errno != EEXIST) die_errno("mkdir");
    *cursor = '/';
  }

  if (mkdir(buffer, mode) < 0 && errno != EEXIST) die_errno("mkdir");
}

static void remove_tree(const char *path) {
  DIR *dir = opendir(path);
  struct dirent *entry;
  char child[PATH_MAX];

  if (!dir) {
    if (errno == ENOENT) return;
    die_errno("opendir cleanup");
  }

  while ((entry = readdir(dir)) != NULL) {
    struct stat st;
    if (strcmp(entry->d_name, ".") == 0 || strcmp(entry->d_name, "..") == 0) continue;
    snprintf(child, sizeof(child), "%s/%s", path, entry->d_name);
    if (lstat(child, &st) < 0) continue;
    if (S_ISDIR(st.st_mode)) {
      remove_tree(child);
    } else {
      unlink(child);
    }
  }

  closedir(dir);
  if (rmdir(path) < 0 && errno != ENOENT) die_errno("rmdir cleanup");
}

static void add_path(const char *src, const char *dest, const char *rootdir) {
  struct stat st;
  char target[PATH_MAX];
  if (stat(src, &st) < 0) {
    fprintf(stderr, "Cannot stat %s: %s\n", src, strerror(errno));
    return;
  }
  snprintf(target, sizeof(target), "%s/%s", rootdir, dest);
  if (S_ISDIR(st.st_mode)) {
    ensure_dir_recursive(target, st.st_mode & 0777);
    if (mount(src, target, "none", MS_BIND | MS_REC, NULL) < 0) {
      fprintf(stderr, "Cannot bind mount %s to %s: %s\n", src, target, strerror(errno));
    }
  }
}

static void handle_child_death(int signo, siginfo_t *info, void *context) {
  (void)signo;
  (void)context;
  if (child_pid == 0 || info->si_pid == child_pid) child_died = 1;
}

static int child_proc(const char *rootdir, const char *nixdir, int clear_env,
                      struct dir_mapping *dir_mappings, struct env_mapping *env_mappings,
                      const char *executable, char *const argv[]) {
  uid_t uid = getuid();
  gid_t gid = getgid();

  if (unshare(CLONE_NEWNS | CLONE_NEWUSER) < 0) {
    if (errno == EPERM) {
      die_message("Enable unprivileged user namespaces to run selfeval.");
    }
    die_errno("unshare");
  }

  for (struct dir_mapping *m = dir_mappings; m; m = m->next) {
    add_path(m->src, m->dest, rootdir);
  }

  struct stat st;
  char nix_mount[PATH_MAX];
  if (stat(nixdir, &st) < 0) die_errno("stat nixdir");
  snprintf(nix_mount, sizeof(nix_mount), "%s/nix", rootdir);
  ensure_dir_recursive(nix_mount, st.st_mode & 0777);
  if (mount(nixdir, nix_mount, "none", MS_BIND | MS_REC, NULL) < 0) die_errno("mount nix");

  int fd = open("/proc/self/setgroups", O_WRONLY);
  if (fd >= 0) {
    (void)!write(fd, "deny", 4);
    close(fd);
  }

  char map_buf[128];
  snprintf(map_buf, sizeof(map_buf), "%d %d 1", uid, uid);
  update_map(map_buf, "/proc/self/uid_map");
  snprintf(map_buf, sizeof(map_buf), "%d %d 1", gid, gid);
  update_map(map_buf, "/proc/self/gid_map");

  if (chroot(rootdir) < 0) die_errno("chroot");
  if (chdir("/") < 0) die_errno("chdir /");

  if (clear_env) clearenv();
  setenv("PATH", "/usr/bin:/bin", 1);
  for (struct env_mapping *e = env_mappings; e; e = e->next) {
    setenv(e->key, e->value, 1);
  }

  execvp(executable, argv);
  die_errno("execvp");
  return 1;
}

int main(int argc, char *argv[]) {
  int clear_env = 0;
  char *nixdir = NULL;
  struct dir_mapping *dir_mappings = NULL;
  struct env_mapping *env_mappings = NULL;

  push_dir_mapping(&dir_mappings, "/dev", "dev");
  push_dir_mapping(&dir_mappings, "/proc", "proc");
  push_dir_mapping(&dir_mappings, "/sys", "sys");
  push_dir_mapping(&dir_mappings, "/run", "run");
  push_dir_mapping(&dir_mappings, "/tmp", "tmp");
  push_dir_mapping(&dir_mappings, "/var", "var");
  push_dir_mapping(&dir_mappings, "/etc", "etc");
  push_dir_mapping(&dir_mappings, "/usr", "usr");
  push_dir_mapping(&dir_mappings, "/home", "home");
  push_dir_mapping(&dir_mappings, "/root", "root");

  int opt;
  while ((opt = getopt(argc, argv, "cn:m:p:")) != -1) {
    switch (opt) {
      case 'c':
        clear_env = 1;
        break;
      case 'n':
        nixdir = realpath(optarg, NULL);
        if (!nixdir) die_errno("realpath nixdir");
        break;
      case 'm': {
        char *sep = strchr(optarg, ':');
        if (!sep) usage(argv[0]);
        *sep = '\0';
        push_dir_mapping(&dir_mappings, optarg, sep + 1);
        break;
      }
      case 'p': {
        const char *value = getenv(optarg);
        if (value) push_env_mapping(&env_mappings, optarg, value);
        break;
      }
      default:
        usage(argv[0]);
    }
  }

  if (!nixdir || optind >= argc) usage(argv[0]);

  const char *tmpdir = getenv("TMPDIR");
  if (!tmpdir) tmpdir = "/tmp";
  char template_path[PATH_MAX];
  snprintf(template_path, sizeof(template_path), "%s/nixXXXXXX", tmpdir);
  char *rootdir = mkdtemp(template_path);
  if (!rootdir) die_errno("mkdtemp");

  int pipefd[2];
  if (pipe(pipefd) < 0) die_errno("pipe");

  struct sigaction sa;
  memset(&sa, 0, sizeof(sa));
  sa.sa_sigaction = handle_child_death;
  sa.sa_flags = SA_SIGINFO;
  if (sigaction(SIGCHLD, &sa, NULL) < 0) die_errno("sigaction");

  pid_t child = fork();
  if (child < 0) die_errno("fork");
  if (child == 0) {
    close(pipefd[1]);
    char buf[8];
    (void)!read(pipefd[0], buf, sizeof(buf));
    close(pipefd[0]);
    return child_proc(rootdir, nixdir, clear_env, dir_mappings, env_mappings, argv[optind],
                      argv + optind);
  }

  child_pid = child;
  close(pipefd[0]);
  close(pipefd[1]);

  int status = 0;
  waitpid(child, &status, 0);
  remove_tree(rootdir);
  if (WIFEXITED(status)) return WEXITSTATUS(status);
  return 1;
}
