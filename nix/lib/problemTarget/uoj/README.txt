Host requirements:

- Linux matching the package target architecture.
- Unprivileged user namespaces enabled for nix-user-chroot.
- UOJ invokes make before running the packaged judger.

The package contains the static judger supervisor, busybox and zstd tools,
supervisor configuration, and the compressed Hull runtime closure.

Set the UOJ problem extra_config to this JSON before syncing data:

{"dont_use_formatter": true}

This prevents UOJ's formatter from modifying packaged binary files.
