#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static int read_exact(int fd, char *buffer, size_t length) {
  size_t offset = 0;
  while (offset < length) {
    ssize_t count = read(fd, buffer + offset, length - offset);
    if (count <= 0) return -1;
    offset += (size_t)count;
  }
  return 0;
}

static int write_exact(int fd, const char *buffer, size_t length) {
  size_t offset = 0;
  while (offset < length) {
    ssize_t count = write(fd, buffer + offset, length - offset);
    if (count <= 0) return -1;
    offset += (size_t)count;
  }
  return 0;
}

static int rdwr(const char *path) {
  char bytes[6];
  int fd = open(path, O_RDWR);
  if (fd < 0 || read_exact(fd, bytes, sizeof(bytes)) < 0 || memcmp(bytes, "abcdef", 6) != 0) {
    return 10;
  }
  if (lseek(fd, 2, SEEK_SET) != 2 || write_exact(fd, "XY", 2) < 0 || lseek(fd, 0, SEEK_SET) != 0 ||
      read_exact(fd, bytes, sizeof(bytes)) < 0 || memcmp(bytes, "abXYef", 6) != 0) {
    return 11;
  }
  return close(fd) == 0 ? 0 : 12;
}

static int trunc_rdwr(const char *path) {
  struct stat status;
  int fd = open(path, O_RDWR | O_TRUNC);
  if (fd < 0 || fstat(fd, &status) < 0 || status.st_size != 0) return 20;
  if (write_exact(fd, "new", 3) < 0) return 21;
  return close(fd) == 0 ? 0 : 22;
}

static int append_rdwr(const char *path) {
  int fd = open(path, O_RDWR | O_APPEND);
  if (fd < 0 || lseek(fd, 0, SEEK_SET) != 0 || write_exact(fd, "G", 1) < 0) return 30;
  off_t position = lseek(fd, 0, SEEK_CUR);
  if (position != 7 || pwrite(fd, "Z", 1, 0) != 1 || lseek(fd, 0, SEEK_CUR) != position) return 31;
  return close(fd) == 0 ? 0 : 32;
}

static int trunc_append_rdwr(const char *path) {
  int fd = open(path, O_RDWR | O_TRUNC | O_APPEND);
  if (fd < 0 || write_exact(fd, "A", 1) < 0 || lseek(fd, 0, SEEK_SET) != 0 ||
      write_exact(fd, "B", 1) < 0) {
    return 40;
  }
  return close(fd) == 0 ? 0 : 41;
}

static int downgraded_access(const char *path) {
  char byte;
  int fd = open(path, O_RDONLY);
  if (fd < 0 || read(fd, &byte, 1) != 1 || byte != 'a' || close(fd) < 0) return 50;
  fd = open(path, O_WRONLY);
  if (fd < 0 || write_exact(fd, "Q", 1) < 0 || close(fd) < 0) return 51;
  fd = open(path, O_RDWR);
  if (fd < 0 || read(fd, &byte, 1) != 1 || byte != 'Q') return 52;
  return close(fd) == 0 ? 0 : 53;
}

static int denied_open(int fd) {
  if (fd >= 0) {
    close(fd);
    return 60;
  }
  return 0;
}

static int create_existing(const char *path) {
  int fd = open(path, O_RDWR | O_CREAT, 0600);
  if (fd < 0 || close(fd) < 0) return 70;
  fd = open(path, O_RDWR | O_CREAT | O_EXCL, 0600);
  if (fd >= 0 || errno != EEXIST) return 71;
  return 0;
}

static int set_append(const char *path) {
  int fd = open(path, O_RDWR);
  if (fd < 0 || fcntl(fd, F_SETFL, O_APPEND) < 0 || lseek(fd, 0, SEEK_SET) != 0 ||
      write_exact(fd, "G", 1) < 0) {
    return 80;
  }
  return close(fd) == 0 ? 0 : 81;
}

static int descriptor_four(const char *path) {
  char byte;
  if (read(4, &byte, 1) != 1 || byte != 'a') return 90;
  int fd = open(path, O_RDONLY);
  if (fd < 0) return 91;
  if (read(fd, &byte, 1) != 1 || byte != 'a') return 92;
  return close(fd) == 0 ? 0 : 93;
}

static int poll_zero(void) { return poll(NULL, 0, 0) == 0 ? 0 : 94; }

static int poll_nonzero(void) {
  if (poll(NULL, 0, 1) < 0) return 95;
  return 96;
}

int main(int argc, char **argv) {
  if (argc != 3) return 2;
  if (strcmp(argv[1], "rdwr") == 0) return rdwr(argv[2]);
  if (strcmp(argv[1], "trunc-rdwr") == 0) return trunc_rdwr(argv[2]);
  if (strcmp(argv[1], "append-rdwr") == 0) return append_rdwr(argv[2]);
  if (strcmp(argv[1], "trunc-append-rdwr") == 0) return trunc_append_rdwr(argv[2]);
  if (strcmp(argv[1], "downgraded-access") == 0) return downgraded_access(argv[2]);
  if (strcmp(argv[1], "deny-rdwr") == 0) return denied_open(open(argv[2], O_RDWR));
  if (strcmp(argv[1], "deny-read") == 0) return denied_open(open(argv[2], O_RDONLY));
  if (strcmp(argv[1], "deny-trunc") == 0) return denied_open(open(argv[2], O_RDONLY | O_TRUNC));
  if (strcmp(argv[1], "create-existing") == 0) return create_existing(argv[2]);
  if (strcmp(argv[1], "set-append") == 0) return set_append(argv[2]);
  if (strcmp(argv[1], "descriptor-four") == 0) return descriptor_four(argv[2]);
  if (strcmp(argv[1], "poll-zero") == 0) return poll_zero();
  if (strcmp(argv[1], "poll-nonzero") == 0) return poll_nonzero();
  return 3;
}
