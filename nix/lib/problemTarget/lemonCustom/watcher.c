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

#define _XOPEN_SOURCE 700

#include <archive.h>
#include <archive_entry.h>
#include <errno.h>
#include <ftw.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

/* clang-format off */
#define TICKS_PER_MS @TICKS_PER_MS@
/* clang-format on */

static int make_path(char *buffer, size_t buffer_size, const char *lhs, const char *rhs) {
  int written = snprintf(buffer, buffer_size, "%s%s", lhs, rhs);
  return written >= 0 && (size_t)written < buffer_size ? 0 : -1;
}

static int read_text_file(const char *path, char *buffer, size_t buffer_size) {
  FILE *fp = fopen(path, "rb");
  size_t len;
  if (fp == NULL) {
    return -1;
  }
  len = fread(buffer, 1, buffer_size - 1, fp);
  fclose(fp);
  buffer[len] = '\0';
  return 0;
}

static int copy_file(const char *src, const char *dst) {
  FILE *in = fopen(src, "rb");
  FILE *out;
  char buffer[8192];
  size_t read_size;

  if (in == NULL) {
    return -1;
  }
  out = fopen(dst, "wb");
  if (out == NULL) {
    fclose(in);
    return -1;
  }
  while ((read_size = fread(buffer, 1, sizeof(buffer), in)) > 0) {
    if (fwrite(buffer, 1, read_size, out) != read_size) {
      fclose(in);
      fclose(out);
      return -1;
    }
  }
  fclose(in);
  fclose(out);
  return 0;
}

static int copy_archive_data(struct archive *reader, struct archive *writer) {
  const void *buffer;
  size_t size;
  la_int64_t offset;
  int result;

  for (;;) {
    result = archive_read_data_block(reader, &buffer, &size, &offset);
    if (result == ARCHIVE_EOF) {
      return ARCHIVE_OK;
    }
    if (result != ARCHIVE_OK) {
      return result;
    }
    result = archive_write_data_block(writer, buffer, size, offset);
    if (result != ARCHIVE_OK) {
      return result;
    }
  }
}

static int remove_path_entry(const char *path, const struct stat *st, int flag, struct FTW *ftw) {
  (void)st;
  (void)flag;
  (void)ftw;
  return remove(path);
}

static void remove_tree_if_exists(const char *path) {
  struct stat st;
  if (lstat(path, &st) != 0) {
    return;
  }
  nftw(path, remove_path_entry, 32, FTW_DEPTH | FTW_PHYS);
}

static int extract_tar_archive(const char *archive_path, const char *dest_dir) {
  struct archive *reader = archive_read_new();
  struct archive *writer = archive_write_disk_new();
  struct archive_entry *entry;
  int result;

  if (reader == NULL || writer == NULL) {
    return -1;
  }
  archive_read_support_filter_all(reader);
  archive_read_support_format_tar(reader);
  archive_write_disk_set_options(writer, ARCHIVE_EXTRACT_TIME | ARCHIVE_EXTRACT_PERM);

  result = archive_read_open_filename(reader, archive_path, 10240);
  if (result != ARCHIVE_OK) {
    fprintf(stderr, "archive open failed: %s\n", archive_error_string(reader));
    archive_write_free(writer);
    archive_read_free(reader);
    return -1;
  }

  for (;;) {
    char path[PATH_MAX];
    result = archive_read_next_header(reader, &entry);
    if (result == ARCHIVE_EOF) {
      break;
    }
    if (result != ARCHIVE_OK) {
      fprintf(stderr, "archive read header failed: %s\n", archive_error_string(reader));
      archive_write_free(writer);
      archive_read_free(reader);
      return -1;
    }
    if (snprintf(path, sizeof(path), "%s/%s", dest_dir, archive_entry_pathname(entry)) >=
        (int)sizeof(path)) {
      archive_write_free(writer);
      archive_read_free(reader);
      return -1;
    }
    archive_entry_set_pathname(entry, path);
    result = archive_write_header(writer, entry);
    if (result != ARCHIVE_OK) {
      fprintf(stderr, "archive write header failed: %s\n", archive_error_string(writer));
      archive_write_free(writer);
      archive_read_free(reader);
      return -1;
    }
    result = copy_archive_data(reader, writer);
    if (result != ARCHIVE_OK) {
      fprintf(stderr, "archive data copy failed: %s\n", archive_error_string(reader));
      archive_write_free(writer);
      archive_read_free(reader);
      return -1;
    }
    result = archive_write_finish_entry(writer);
    if (result != ARCHIVE_OK) {
      fprintf(stderr, "archive finish entry failed: %s\n", archive_error_string(writer));
      archive_write_free(writer);
      archive_read_free(reader);
      return -1;
    }
  }

  archive_write_free(writer);
  archive_read_free(reader);
  return 0;
}

static void trim_newline(char *value) {
  size_t len = strlen(value);
  while (len > 0 && (value[len - 1] == '\n' || value[len - 1] == '\r')) {
    value[len - 1] = '\0';
    --len;
  }
}

static const char *advance_report_line(const char *cursor, char *buffer, size_t buffer_size) {
  size_t len = 0;
  while (*cursor != '\0' && *cursor != '\n' && len + 1 < buffer_size) {
    buffer[len++] = *cursor++;
  }
  buffer[len] = '\0';
  if (*cursor == '\n') {
    ++cursor;
  }
  return cursor;
}

int main(int argc, char **argv) {
  char submission_path[PATH_MAX];
  char cwd[PATH_MAX];
  char extract_root[PATH_MAX];
  char bundle_root[PATH_MAX];
  char runtime_nix_dir[PATH_MAX];
  char nix_user_chroot_path[PATH_MAX];
  char extract_mount[PATH_MAX * 2];
  char bundle_mount[PATH_MAX * 2];
  char problem_name_path[PATH_MAX];
  char problem_name[PATH_MAX];
  char submission_name_path[PATH_MAX];
  char submission_name[PATH_MAX];
  char bundled_submission_path[PATH_MAX];
  char report_txt_path[PATH_MAX];
  char inner_report_txt_path[PATH_MAX];
  char fallback_output_path[PATH_MAX];
  char tick_str[64];
  char memory_str[64];
  char score_str[64];
  char status_str[128];
  char message_buf[4096];
  char report_buf[8192];
  char *child_argv[64];
  const char *output_path;
  const char *effective_output_path;
  const char *error_path;
  pid_t child_pid;
  int status;
  int exit_code = 1;
  int extract_root_ready = 0;
  FILE *error_fp;

  if (argc != 12) {
    fprintf(stderr, "invalid HullBundle watcher argument count: %d\n", argc - 1);
    return 1;
  }

  if (argv[2][0] == '/') {
    if (snprintf(submission_path, sizeof(submission_path), "%s", argv[2]) >=
        (int)sizeof(submission_path)) {
      fprintf(stderr, "submission path too long\n");
      goto cleanup;
    }
  } else {
    if (getcwd(cwd, sizeof(cwd)) == NULL ||
        snprintf(submission_path, sizeof(submission_path), "%s/%s", cwd, argv[2]) >=
            (int)sizeof(submission_path)) {
      fprintf(stderr, "failed to resolve relative HullBundle path\n");
      goto cleanup;
    }
  }

  if (snprintf(extract_root, sizeof(extract_root), "%s.extract", submission_path) >=
          (int)sizeof(extract_root) ||
      make_path(bundle_root, sizeof(bundle_root), extract_root, "/bundle") != 0 ||
      make_path(runtime_nix_dir, sizeof(runtime_nix_dir), extract_root, "/runtime-nix") != 0 ||
      snprintf(extract_mount, sizeof(extract_mount), "%s:%s", extract_root, "/bundle-host") >=
          (int)sizeof(extract_mount) ||
      snprintf(bundle_mount, sizeof(bundle_mount), "%s:%s", bundle_root, "/bundle") >=
          (int)sizeof(bundle_mount) ||
      make_path(problem_name_path, sizeof(problem_name_path), extract_root, "/problem-name") != 0 ||
      make_path(submission_name_path, sizeof(submission_name_path), extract_root,
                "/submission-name") != 0 ||
      make_path(report_txt_path, sizeof(report_txt_path), extract_root, "/watcher-report.txt") !=
          0 ||
      snprintf(inner_report_txt_path, sizeof(inner_report_txt_path), "%s",
               "/bundle-host/watcher-report.txt") >= (int)sizeof(inner_report_txt_path) ||
      make_path(nix_user_chroot_path, sizeof(nix_user_chroot_path), runtime_nix_dir,
                "/store@NIX_USER_CHROOT_STORE_SUFFIX@") != 0) {
    fprintf(stderr, "path too long\n");
    goto cleanup;
  }

  mkdir(extract_root, 0755);
  extract_root_ready = 1;

  if (extract_tar_archive(submission_path, extract_root) != 0) {
    fprintf(stderr, "failed to extract HullBundle archive\n");
    goto cleanup;
  }

  if (read_text_file(problem_name_path, problem_name, sizeof(problem_name)) != 0) {
    fprintf(stderr, "failed to read HullBundle metadata from %s\n", problem_name_path);
    goto cleanup;
  }
  if (read_text_file(submission_name_path, submission_name, sizeof(submission_name)) != 0) {
    fprintf(stderr, "failed to read HullBundle submission metadata from %s\n",
            submission_name_path);
    goto cleanup;
  }
  trim_newline(problem_name);
  trim_newline(submission_name);
  if (snprintf(bundled_submission_path, sizeof(bundled_submission_path), "/bundle-host/%s",
               submission_name) >= (int)sizeof(bundled_submission_path)) {
    fprintf(stderr, "bundled submission path too long\n");
    goto cleanup;
  }

  output_path = argv[4];
  error_path = argv[5];

  if (output_path[0] == '\0') {
    if (getcwd(cwd, sizeof(cwd)) == NULL ||
        snprintf(fallback_output_path, sizeof(fallback_output_path), "%s/%s", cwd, argv[11]) >=
            (int)sizeof(fallback_output_path)) {
      fprintf(stderr, "failed to resolve fallback watcher output path\n");
      goto cleanup;
    }
    effective_output_path = fallback_output_path;
  } else {
    effective_output_path = output_path;
  }

  child_argv[0] = nix_user_chroot_path;
  child_argv[1] = "-m";
  child_argv[2] = extract_mount;
  child_argv[3] = "-m";
  child_argv[4] = bundle_mount;
  child_argv[5] = "-n";
  child_argv[6] = runtime_nix_dir;
  child_argv[7] = "--";
  child_argv[8] = "@CUSTOM_JUDGE_RUNNER_RELATIVE@";
  child_argv[9] = "--bundle-root";
  child_argv[10] = "/bundle";
  child_argv[11] = "--metadata-path";
  child_argv[12] = "problem.json";
  child_argv[13] = "--submission-file";
  child_argv[14] = bundled_submission_path;
  child_argv[15] = "--submission-language";
  child_argv[16] = "HullBundle";
  child_argv[17] = "--language-map-path";
  child_argv[18] = "lemon-language-map.json";
  child_argv[19] = "--participant-solution-name";
  child_argv[20] = "lemonCustom";
  child_argv[21] = "--threads";
  child_argv[22] = "0";
  child_argv[23] = "--plain-output-path";
  child_argv[24] = inner_report_txt_path;
  child_argv[25] = NULL;

  child_pid = fork();
  if (child_pid < 0) {
    fprintf(stderr, "failed to fork watcher child: %s\n", strerror(errno));
    goto cleanup;
  }
  if (child_pid == 0) {
    execv(nix_user_chroot_path, child_argv);
    fprintf(stderr, "failed to exec %s: %s\n", nix_user_chroot_path, strerror(errno));
    _exit(1);
  }
  if (waitpid(child_pid, &status, 0) < 0 || !WIFEXITED(status) || WEXITSTATUS(status) != 0) {
    goto cleanup;
  }

  if (read_text_file(report_txt_path, report_buf, sizeof(report_buf)) != 0) {
    fprintf(stderr, "failed to read watcher plain report\n");
    goto cleanup;
  }

  {
    const char *cursor = report_buf;
    cursor = advance_report_line(cursor, tick_str, sizeof(tick_str));
    cursor = advance_report_line(cursor, memory_str, sizeof(memory_str));
    cursor = advance_report_line(cursor, score_str, sizeof(score_str));
    cursor = advance_report_line(cursor, status_str, sizeof(status_str));
    snprintf(message_buf, sizeof(message_buf), "%s", cursor);
    trim_newline(message_buf);
  }

  printf("%lld %lld\n", atoll(tick_str) / (long long)TICKS_PER_MS, atoll(memory_str));
  fflush(stdout);

  error_fp = fopen(error_path, "ab");
  if (error_fp != NULL) {
    if (message_buf[0] != '\0') {
      fprintf(error_fp, "%s\n", message_buf);
    }
    fclose(error_fp);
  }
  if (copy_file(report_txt_path, effective_output_path) != 0) {
    fprintf(stderr, "failed to copy final watcher plain report\n");
    goto cleanup;
  }

  if (strcmp(status_str, "accepted") == 0 || strcmp(status_str, "partially_correct") == 0 ||
      strcmp(status_str, "wrong_answer") == 0 || strcmp(status_str, "runtime_error") == 0 ||
      strcmp(status_str, "time_limit_exceeded") == 0 ||
      strcmp(status_str, "memory_limit_exceeded") == 0) {
    exit_code = 0;
    goto cleanup;
  }

cleanup:
  if (extract_root_ready) {
    remove_tree_if_exists(extract_root);
  }
  return exit_code;
}
