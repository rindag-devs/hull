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

#include <errno.h>
#include <limits.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

#define JUDGER_SHELL_BASENAME "judger.sh"

static int get_dirname(const char *path, char *buffer, size_t buffer_size) {
  size_t len;
  const char *slash;

  if (path == NULL || buffer == NULL || buffer_size == 0) {
    return -1;
  }

  slash = strrchr(path, '/');
  if (slash == NULL) {
    if (buffer_size < 2) {
      return -1;
    }
    buffer[0] = '.';
    buffer[1] = '\0';
    return 0;
  }

  len = (size_t)(slash - path);
  if (len == 0) {
    len = 1;
  }
  if (len + 1 > buffer_size) {
    return -1;
  }

  memcpy(buffer, path, len);
  buffer[len] = '\0';
  return 0;
}

int main(int argc, char **argv) {
  char self_dir[PATH_MAX];
  char shell_path[PATH_MAX];
  char **child_argv;
  size_t dir_len;
  size_t shell_name_len;
  int i;
  int status;
  pid_t child_pid;

  if (get_dirname(argv[0], self_dir, sizeof(self_dir)) != 0) {
    fprintf(stderr, "failed to resolve launcher directory\n");
    return EXIT_FAILURE;
  }

  dir_len = strlen(self_dir);
  shell_name_len = strlen(JUDGER_SHELL_BASENAME);
  if (dir_len + 1 + shell_name_len + 1 > sizeof(shell_path)) {
    fprintf(stderr, "launcher path too long\n");
    return EXIT_FAILURE;
  }
  memcpy(shell_path, self_dir, dir_len);
  shell_path[dir_len] = '/';
  memcpy(shell_path + dir_len + 1, JUDGER_SHELL_BASENAME, shell_name_len + 1);

  child_argv = (char **)malloc((size_t)(argc + 2) * sizeof(char *));
  if (child_argv == NULL) {
    fprintf(stderr, "malloc failed\n");
    return EXIT_FAILURE;
  }

  child_argv[0] = (char *)"/bin/sh";
  child_argv[1] = shell_path;
  for (i = 1; i < argc; ++i) {
    child_argv[i + 1] = argv[i];
  }
  child_argv[argc + 1] = NULL;

  child_pid = fork();
  if (child_pid < 0) {
    fprintf(stderr, "failed to fork judger shell: %s\n", strerror(errno));
    free((void *)child_argv);
    return EXIT_FAILURE;
  }

  if (child_pid == 0) {
    execv("/bin/sh", child_argv);
    fprintf(stderr, "failed to exec /bin/sh %s: %s\n", shell_path, strerror(errno));
    _exit(EXIT_FAILURE);
  }

  free((void *)child_argv);
  if (waitpid(child_pid, &status, 0) < 0) {
    fprintf(stderr, "failed to wait for judger shell: %s\n", strerror(errno));
    return EXIT_FAILURE;
  }

  if (WIFEXITED(status)) {
    return WEXITSTATUS(status);
  }
  if (WIFSIGNALED(status)) {
    raise(WTERMSIG(status));
  }

  fprintf(stderr, "judger shell ended unexpectedly\n");
  return EXIT_FAILURE;
}
