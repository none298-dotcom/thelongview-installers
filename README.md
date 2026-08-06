# The Long View, installers and CI

This repo holds **no application source**. It holds the workflows that build and verify the
desktop installers, and it receives the finished artifacts.

Source lives in the private repo `none298-dotcom/thelongview-app` and is fetched into the
runner's temporary workspace at build time. It is never committed here.

## Why the split exists

Not tidiness. GitHub Actions is free on public repos and metered on private ones, and this
account's metered budget is currently unavailable. Running the workflow from the private repo
produced this, in three seconds, before a runner was even assigned:

> The job was not started because recent account payments have failed or your spending limit
> needs to be increased.

No steps ran, so the job reported "failure" with an empty step list, which looks nothing like a
build failure and is easy to misread as one.

## How the source is fetched

A **read-only deploy key**, scoped to `thelongview-app` alone, stored here as the repository
secret `SOURCE_DEPLOY_KEY`. This is deliberately narrower than a personal access token: a PAT
carries whatever the account can reach, a deploy key reaches one repo and cannot write to it.

Repository secrets are not exposed to workflows triggered from forks, and `workflow_dispatch`
requires write access, so a public repo does not put the key within reach of the public.

## Workflows

### `windows-exe-verify.yml`

Builds the jpackage EXE on `windows-latest`, installs it silently the way a Microsoft Store
certifier does, and then checks the things certification actually checks.

| Check | Policy | What a failure means |
|---|---|---|
| Silent install returns 0 or 3010 | | The installer cannot be run unattended |
| A `.lnk` exists under **ProgramData**, not just APPDATA | 10.1.2.10 | No accessible method of being launched |
| An **HKLM** uninstall entry exists, with an `UninstallString` | 10.2.7 | Nothing in Add or Remove Programs |
| The installed binary is still running after N seconds | | A missing `modules()` entry, which only fails at runtime |
| UI Automation can see the window and its contents | | The UI never rendered, or is unreachable to a screen reader |

Two of those, 10.1.2.10 and 10.2.7, are the ones that failed MyLinedChart certification twice,
both times because of `perUserInstall = true`.

### Proving the checks bite before believing a green

`workflow_dispatch` takes a `break_per_user_install` input. Setting it true patches
`perUserInstall = false` to `true` before the build, reproducing the exact defect that was
rejected. **A green run only counts once the broken run has been seen going red**, naming those
two policies. A check that has never failed has not been tested, it has only been executed.

### What is deliberately not copied from MyLinedChart

- **Silent install is `/quiet`, not `/S`.** That app ships an NSIS installer; this one ships a
  jpackage WiX Burn bundle, which does not recognise `/S`.
- **Clicking does not go over the Chrome DevTools Protocol.** That app is Electron. This one is
  Compose Desktop: Skia rendering, no Chromium, no debugging port. Windows UI Automation is the
  replacement, and until it is proven that Compose exposes its semantics tree, that step reports
  rather than gates.
