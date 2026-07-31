# Contributing to Hull

Thank you for helping improve Hull. Bug reports, documentation fixes, tests, and focused code changes are all welcome.

## Before You Start

- Search existing issues and pull requests before opening a duplicate.
- Open an issue before a large change so its scope and design can be discussed early.
- Keep each pull request focused on one logical change.
- Do not include third-party code, generated material, or assets unless their origin and license are clearly identified and compatible with Hull.
- Review and test any AI-assisted work as carefully as work written by hand. You must have the right to submit the result.

## Development

Enter the development environment:

```console
nix develop
```

Useful commands:

```console
just format
just lint
just -- problem aPlusB --stop-on-failure
just -- all-problems --stop-on-failure
just integration
```

Run the narrowest relevant checks while developing, then run `just format` and `just lint` before requesting review. Changes to problem evaluation or packaging should also build a representative problem or contest target.

## Pull Requests

A pull request should explain:

- the problem being solved;
- the chosen approach and important trade-offs;
- the verification performed;
- any user-visible or breaking behavior.

Maintainers may ask for a pull request to be split, revised, or accompanied by documentation. Submission does not guarantee acceptance.

## Contribution Licence Agreement

All contributions are subject to the [Hull Contributor Licence Agreement](CLA.md). You retain copyright in your contribution. The agreement grants the Project Steward broad, irrevocable, and sublicensable rights, including the ability to distribute the contribution under other licence terms. Accepted contributions remain available from Hull under the project's open-source licence.

To record your agreement, leave the CLA acknowledgement checked in the pull request template. If your employer or another organisation owns rights in your work, you must be authorised to make the grant in the CLA.
