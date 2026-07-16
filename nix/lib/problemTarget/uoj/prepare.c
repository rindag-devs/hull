#include <fcntl.h>
#include <stdio.h>
#include <sys/stat.h>
#include <unistd.h>

static int replace(const char *path, const char *temporary) {
  char buffer[65536];
  ssize_t size;
  int input = open(path, O_RDONLY);
  int output;

  if (input < 0) {
    return 1;
  }
  output = open(temporary, O_WRONLY | O_CREAT | O_TRUNC, 0755);
  if (output < 0) {
    return 1;
  }
  while ((size = read(input, buffer, sizeof(buffer))) > 0) {
    ssize_t offset = 0;

    while (offset < size) {
      ssize_t written = write(output, buffer + offset, (size_t)(size - offset));
      if (written <= 0) {
        return 1;
      }
      offset += written;
    }
  }
  if (size < 0 || close(input) < 0 || close(output) < 0 || chmod(temporary, 0755) < 0) {
    return 1;
  }
  return rename(temporary, path) < 0;
}

int main(void) {
  return replace("judger", ".judger.hull-prepare") || replace("busybox", ".busybox.hull-prepare") ||
         replace("zstd", ".zstd.hull-prepare");
}
