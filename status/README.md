# Status

- [STANDARD.md](STANDARD.md): what a package does to fit in: workflows, job names, pins, logs, tests by platform. Start here to bring a package in line.
- [packages.md](packages.md): the packages that use Kiln or telosnex_ci_tools on their default branch. Generated; do not edit.
- [The live dashboard](https://github.com/Telosnex/telosnex_ci_tools/tree/dashboard): the newest CI run of each package, by workflow and by platform. Every 30 minutes.
- [packages.yaml](packages.yaml): the list both come from. Add a package here; the Dashboard workflow does the rest.

Both are built by `.github/workflows/dashboard.yml` with `dart run telosnex_ci_tools:dashboard`, which prints the dashboard locally.
