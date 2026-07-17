#import "/templates/page.typ": page

#show: page.with(
  title: "Installation & Setup",
  summary: "Set up Nix with Flakes, create a Hull problem project, and enter the development environment.",
)

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

Using an AI agent is the recommended way to create a Hull problem. Point an agent that supports Agent Skills to the #link("https://hull.aberter0x3f.top/.well-known/agent-skills/index.json")[Hull skill index] and ask it to use `author-hull-problems`. The #link("https://hull.aberter0x3f.top/.well-known/agent-skills/author-hull-problems.tar.gz")[skill archive] is also available directly.

You may give the agent only an idea, a partial problem, an existing problem, or an existing Hull workspace. Ask it to complete omitted details, initialize the basic template when needed, and implement and verify the problem in your workspace.

To create a problem manually, use the Hull template.

Run this command in the target directory:

```bash
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
