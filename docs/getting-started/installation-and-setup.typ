#import "../book.typ": book-page

#show: book-page.with(title: "Installation & Setup")

= Installation & Setup

This chapter shows the required setup and the standard project entry points.

== Prerequisites

Hull requires Nix with Flakes enabled.

=== 1. Install Nix

Install Nix by following #link("https://nixos.org/download/").

=== 2. Enable Flakes

Enable Flakes in the Nix configuration file.

The location of this file depends on your system:

- On NixOS: `/etc/nixos/configuration.nix`
- On Linux (multi-user install) or macOS: `~/.config/nix/nix.conf` (you may need to create the file and directory).

Add the following lines to your configuration file:

```nix
experimental-features = nix-command flakes
```

Restart the Nix daemon if required.

```bash
sudo systemctl restart nix-daemon
```

Verify the setup with:

```bash
nix flake --version
```

== Creating a New Problem

Use the Hull template to create a project.

=== Creating a New Project Directory

To create a problem in a directory, use `nix flake init` inside that directory.

```bash
# Initialize this directory from the basic Hull template
nix flake init -t github:rindag-devs/hull#basic
```

=== Initializing an Existing Directory

If you already have an empty directory where you want to set up your problem, you can initialize it directly.

```bash
mkdir myProblem
cd myProblem
nix flake init -t github:rindag-devs/hull#basic
```

== Entering the Development Environment

Enter the development shell:

```bash
cd myProblem
nix develop
```

Inside this shell:

- The `hull` command-line interface (CLI) is available in your `PATH`.
- All necessary compilers (e.g., `wasm32-wasi-wasip1-clang++`) and tools are ready to use.
- Environment variables are set up for seamless integration with libraries like `cplib`.

Run Hull commands inside this shell.
