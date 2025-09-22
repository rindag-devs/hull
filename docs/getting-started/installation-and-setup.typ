#import "../book.typ": book-page

#show: book-page.with(title: "Installation & Setup")

= Installation & Setup

This chapter will guide you through the initial setup process required to use Hull. We will cover the necessary prerequisites, how to create a new problem project from the official template, and how to enter the specialized development environment.

== Prerequisites

Hull's core philosophy of perfect reproducibility is built upon the Nix package manager. Therefore, the only prerequisite is a working Nix installation with Flakes support enabled.

=== 1. Install Nix

If you do not have Nix installed, please follow the official instructions at #link("https://nixos.org/download/"). The recommended installation method for non-NixOS systems is the "Multi-user installation".

=== 2. Enable Flakes

Flakes are a new, powerful feature in Nix that provide better reproducibility and a more user-friendly interface. Hull relies on them. To enable Flakes, you need to edit your Nix configuration file.

The location of this file depends on your system:
- On NixOS: `/etc/nixos/configuration.nix`
- On Linux (multi-user install) or macOS: `~/.config/nix/nix.conf` (you may need to create the file and directory).

Add the following lines to your configuration file:

```nix
experimental-features = nix-command flakes
```

After saving the file, you may need to restart the Nix daemon for the changes to take effect. You can typically do this with:

```bash
sudo systemctl restart nix-daemon
```

To verify that Flakes are enabled, run the following command. It should execute without errors.

```bash
nix flake --version
```

== Creating a New Problem

The easiest way to start a new problem is by using the official Hull flake template. This provides a standard directory structure and a pre-configured `problem.nix` file.

=== Creating a New Project Directory

To create a new problem in a new directory, use the `nix flake new` command. This will create a directory and populate it with the contents of the template.

```bash
# This creates a new project in the 'myProblem' directory
nix flake new -t github:rindag-devs/hull --refresh myProblem
```

=== Initializing an Existing Directory

If you already have an empty directory where you want to set up your problem, you can use `nix flake init`.

```bash
mkdir myProblem
cd myProblem
nix flake init -t github:rindag-devs/hull --refresh
```

== Entering the Development Environment

Once your project is created, you need to enter the Nix development shell. This is a crucial step.

```bash
cd myProblem
nix develop
```

The `nix develop` command launches a new shell session that is specifically configured for your Hull project. Inside this shell:
- The `hull` command-line interface (CLI) is available in your `PATH`.
- All necessary compilers (e.g., `wasm-judge-clang++`) and tools are ready to use.
- Environment variables are set up for seamless integration with libraries like `cplib`.

This shell is a hermetic, isolated environment. The tools and their versions are precisely defined by the `flake.nix` file. This ensures that you and anyone else working on the problem are using the exact same versions of all tools, which is fundamental to Hull's guarantee of reproducibility.

You will notice your shell prompt change, indicating that you are inside the development environment. All `hull` commands described in the following chapters must be run from within this shell.

With the environment set up, you are now ready to start working with your problem.
