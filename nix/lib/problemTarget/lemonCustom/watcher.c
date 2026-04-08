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

#include <archive.h>
#include <archive_entry.h>
#include <errno.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

#define REPORT_JSON_SUFFIX ".hull-report.json"
#define REPORT_TXT_SUFFIX ".hull-report.txt"
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

static int mkdirs_for_path(const char *path) {
  char buffer[PATH_MAX];
  char *p;
  if (snprintf(buffer, sizeof(buffer), "%s", path) >= (int)sizeof(buffer)) {
    return -1;
  }
  for (p = buffer + 1; *p != '\0'; ++p) {
    if (*p == '/') {
      *p = '\0';
      mkdir(buffer, 0755);
      *p = '/';
    }
  }
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
  char current_input_path[PATH_MAX];
  char report_json_path[PATH_MAX];
  char report_txt_path[PATH_MAX];
  char inner_report_json_path[PATH_MAX];
  char inner_report_txt_path[PATH_MAX];
  char fallback_output_path[PATH_MAX];
  char official_data_path[PATH_MAX];
  char tick_limit_path[PATH_MAX];
  char memory_limit_path[PATH_MAX];
  char testcase_name[PATH_MAX];
  char tick_str[64];
  char memory_str[64];
  char score_str[64];
  char status_str[128];
  char message_buf[4096];
  char report_buf[8192];
  char tick_limit_buf[64];
  char memory_limit_buf[64];
  char *child_argv[64];
  const char *input_path;
  const char *output_path;
  const char *effective_output_path;
  const char *error_path;
  pid_t child_pid;
  int status;
  FILE *error_fp;

  if (argc != 12) {
    fprintf(stderr, "invalid HullBundle watcher argument count: %d\n", argc - 1);
    return 1;
  }

  if (argv[2][0] == '/') {
    if (snprintf(submission_path, sizeof(submission_path), "%s", argv[2]) >=
        (int)sizeof(submission_path)) {
      fprintf(stderr, "submission path too long\n");
      return 1;
    }
  } else {
    if (getcwd(cwd, sizeof(cwd)) == NULL ||
        snprintf(submission_path, sizeof(submission_path), "%s/%s", cwd, argv[2]) >=
            (int)sizeof(submission_path)) {
      fprintf(stderr, "failed to resolve relative HullBundle path\n");
      return 1;
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
      make_path(current_input_path, sizeof(current_input_path), extract_root, "/current-input") !=
          0 ||
      make_path(report_json_path, sizeof(report_json_path), extract_root, "/watcher-report.json") !=
          0 ||
      make_path(report_txt_path, sizeof(report_txt_path), extract_root, "/watcher-report.txt") !=
          0 ||
      snprintf(inner_report_json_path, sizeof(inner_report_json_path), "%s",
               "/bundle-host/watcher-report.json") >= (int)sizeof(inner_report_json_path) ||
      snprintf(inner_report_txt_path, sizeof(inner_report_txt_path), "%s",
               "/bundle-host/watcher-report.txt") >= (int)sizeof(inner_report_txt_path) ||
      make_path(nix_user_chroot_path, sizeof(nix_user_chroot_path), runtime_nix_dir,
                "/store@NIX_USER_CHROOT_STORE_SUFFIX@") != 0) {
    fprintf(stderr, "path too long\n");
    return 1;
  }

  mkdir(extract_root, 0755);

  if (extract_tar_archive(submission_path, extract_root) != 0) {
    fprintf(stderr, "failed to extract HullBundle archive\n");
    return 1;
  }

  if (read_text_file(problem_name_path, problem_name, sizeof(problem_name)) != 0) {
    fprintf(stderr, "failed to read HullBundle metadata from %s\n", problem_name_path);
    return 1;
  }
  trim_newline(problem_name);

  input_path = argv[3];
  output_path = argv[4];
  error_path = argv[5];

  if (output_path[0] == '\0') {
    if (getcwd(cwd, sizeof(cwd)) == NULL ||
        snprintf(fallback_output_path, sizeof(fallback_output_path), "%s/%s", cwd, argv[11]) >=
            (int)sizeof(fallback_output_path)) {
      fprintf(stderr, "failed to resolve fallback watcher output path\n");
      return 1;
    }
    effective_output_path = fallback_output_path;
  } else {
    effective_output_path = output_path;
  }

  if (copy_file(input_path, current_input_path) != 0) {
    fprintf(stderr, "failed to stage testcase input into HullBundle\n");
    return 1;
  }

  {
    const char *file_slash = strrchr(input_path, '/');
    const char *dir_end;
    const char *dir_start;
    size_t len;
    if (file_slash == NULL) {
      fprintf(stderr, "invalid testcase input path: %s\n", input_path);
      return 1;
    }
    dir_end = file_slash;
    while (dir_end > input_path && dir_end[-1] == '/') {
      --dir_end;
    }
    dir_start = dir_end;
    while (dir_start > input_path && dir_start[-1] != '/') {
      --dir_start;
    }
    len = (size_t)(dir_end - dir_start);
    if (len == 0 || len >= sizeof(testcase_name)) {
      fprintf(stderr, "invalid testcase parent path: %s\n", input_path);
      return 1;
    }
    memcpy(testcase_name, dir_start, len);
    testcase_name[len] = '\0';
  }

  if (snprintf(official_data_path, sizeof(official_data_path), "%s/%s/official-data.tar",
               bundle_root, testcase_name) >= (int)sizeof(official_data_path)) {
    fprintf(stderr, "official-data path too long\n");
    return 1;
  }
  if (snprintf(tick_limit_path, sizeof(tick_limit_path), "%s/%s/tick-limit", bundle_root,
               testcase_name) >= (int)sizeof(tick_limit_path) ||
      snprintf(memory_limit_path, sizeof(memory_limit_path), "%s/%s/memory-limit", bundle_root,
               testcase_name) >= (int)sizeof(memory_limit_path)) {
    fprintf(stderr, "limit path too long\n");
    return 1;
  }
  if (read_text_file(tick_limit_path, tick_limit_buf, sizeof(tick_limit_buf)) != 0 ||
      read_text_file(memory_limit_path, memory_limit_buf, sizeof(memory_limit_buf)) != 0) {
    fprintf(stderr, "failed to read testcase limits\n");
    return 1;
  }
  trim_newline(tick_limit_buf);
  trim_newline(memory_limit_buf);

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
  child_argv[14] = "/bundle-host/submission";
  child_argv[15] = "--submission-language";
  child_argv[16] = "HullBundle";
  child_argv[17] = "--testcase-name";
  child_argv[18] = testcase_name;
  child_argv[19] = "--input-path";
  child_argv[20] = "/bundle-host/current-input";
  child_argv[21] = "--official-data-path";
  child_argv[22] = official_data_path;
  child_argv[23] = "--tick-limit";
  child_argv[24] = tick_limit_buf;
  child_argv[25] = "--memory-limit";
  child_argv[26] = memory_limit_buf;
  child_argv[27] = "--participant-solution-name";
  child_argv[28] = "lemonCustom";
  child_argv[29] = "--output-path";
  child_argv[30] = inner_report_json_path;
  child_argv[31] = "--plain-output-path";
  child_argv[32] = inner_report_txt_path;
  child_argv[33] = NULL;

  child_pid = fork();
  if (child_pid < 0) {
    fprintf(stderr, "failed to fork watcher child: %s\n", strerror(errno));
    return 1;
  }
  if (child_pid == 0) {
    execv(nix_user_chroot_path, child_argv);
    fprintf(stderr, "failed to exec %s: %s\n", nix_user_chroot_path, strerror(errno));
    _exit(1);
  }
  if (waitpid(child_pid, &status, 0) < 0 || !WIFEXITED(status) || WEXITSTATUS(status) != 0) {
    return 1;
  }

  if (read_text_file(report_txt_path, report_buf, sizeof(report_buf)) != 0) {
    fprintf(stderr, "failed to read watcher plain report\n");
    return 1;
  }

  tick_str[0] = '\0';
  memory_str[0] = '\0';
  score_str[0] = '\0';
  status_str[0] = '\0';
  message_buf[0] = '\0';
  sscanf(report_buf, "%63[^\n]\n%63[^\n]\n%63[^\n]\n%127[^\n]\n%4095[^\n]", tick_str, memory_str,
         score_str, status_str, message_buf);

  printf("%lld %lld\n", atoll(tick_str) / (long long)TICKS_PER_MS, atoll(memory_str));
  fflush(stdout);

  error_fp = fopen(error_path, "ab");
  if (error_fp != NULL) {
    if (message_buf[0] != '\0') {
      fprintf(error_fp, "%s\n", message_buf);
    }
    fclose(error_fp);
  }
  {
    FILE *output_fp = fopen(effective_output_path, "wb");
    if (output_fp == NULL) {
      fprintf(stderr, "failed to open watcher output path %s\n", effective_output_path);
      return 1;
    }
    fclose(output_fp);
  }
  {
    char final_report_path[PATH_MAX];
    if (make_path(final_report_path, sizeof(final_report_path), effective_output_path,
                  REPORT_JSON_SUFFIX) != 0 ||
        copy_file(report_json_path, final_report_path) != 0) {
      fprintf(stderr, "failed to copy final watcher JSON report\n");
      return 1;
    }
  }

  if (strcmp(status_str, "accepted") == 0 || strcmp(status_str, "partially_correct") == 0 ||
      strcmp(status_str, "wrong_answer") == 0) {
    return 0;
  }
  if (strcmp(status_str, "runtime_error") == 0) {
    return 2;
  }
  if (strcmp(status_str, "time_limit_exceeded") == 0) {
    return 3;
  }
  if (strcmp(status_str, "memory_limit_exceeded") == 0) {
    return 4;
  }
  return 1;
}
