#include <stdio.h>
#include <stdlib.h>

static void close_if_open(FILE *file) {
  if (file != NULL) {
    fclose(file);
  }
}

static int skip_line(FILE *file) {
  int ch;
  do {
    ch = fgetc(file);
    if (ch == EOF) {
      return 0;
    }
  } while (ch != '\n');
  return 1;
}

static int copy_line(FILE *input, FILE *output) {
  int ch;
  do {
    ch = fgetc(input);
    if (ch == EOF) {
      return 0;
    }
    fputc(ch, output);
  } while (ch != '\n');
  return 1;
}

static void copy_stream(FILE *input, FILE *output) {
  int ch;
  while ((ch = fgetc(input)) != EOF) {
    fputc(ch, output);
  }
}

static int report_invalid_hull_report(const char *user_out_path, FILE *user_out, FILE *score_file,
                                      FILE *message_file) {
  fputs("0\n", score_file);
  fprintf(message_file, "invalid hull report: %s\n", user_out_path);
  close_if_open(user_out);
  close_if_open(score_file);
  close_if_open(message_file);
  return 0;
}

int main(int argc, char **argv) {
  if (argc < 7) {
    return 1;
  }

  const char *user_out_path = argv[2];
  const char *score_path = argv[5];
  const char *message_path = argv[6];

  FILE *user_out = fopen(user_out_path, "r");
  FILE *score_file = fopen(score_path, "w");
  FILE *message_file = fopen(message_path, "w");
  if (score_file == NULL || message_file == NULL) {
    close_if_open(user_out);
    close_if_open(score_file);
    close_if_open(message_file);
    return 1;
  }

  if (user_out == NULL) {
    fputs("0\n", score_file);
    fprintf(message_file, "missing hull report: %s\n", user_out_path);
    fclose(score_file);
    fclose(message_file);
    return 0;
  }

  if (!skip_line(user_out)) {
    return report_invalid_hull_report(user_out_path, user_out, score_file, message_file);
  }
  if (!skip_line(user_out)) {
    return report_invalid_hull_report(user_out_path, user_out, score_file, message_file);
  }
  if (!copy_line(user_out, score_file)) {
    return report_invalid_hull_report(user_out_path, user_out, score_file, message_file);
  }

  if (!skip_line(user_out)) {
    fprintf(message_file, "missing status in hull report: %s\n", user_out_path);
    fclose(user_out);
    fclose(score_file);
    fclose(message_file);
    return 0;
  }

  copy_stream(user_out, message_file);

  fclose(user_out);
  fclose(score_file);
  fclose(message_file);
  return 0;
}
