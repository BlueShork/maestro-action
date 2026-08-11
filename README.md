# MaestroDeck Cloud Action

Run [Maestro](https://maestro.mobile.dev/) tests on [MaestroDeck Cloud](https://maestrodeck.cloud) from your CI, on **iOS, Android or Web**, with a single step. The build fails if the tests fail.

```yaml
- uses: BlueShork/maestro-action@v5
  with:
    api_key: ${{ secrets.MAESTRO_API_KEY }}
    platform: android
    app: build/app-release.apk
    flow: .maestro/
```

## How it works

The action uploads your app and flows to MaestroDeck Cloud, runs them on a real simulator/emulator, waits for the result, and exits `0` (passed) or `1` (failed/error). Android jobs dispatch instantly; iOS jobs run on the macOS worker pool. You get the same pipeline as the dashboard, triggered from CI.

Web works the same way with one difference: there is no app to build or upload, so you pass `url` instead of `app` and the flows run against that site in a browser.

Pass `bank_path` to also run visual regression: the action uploads every `.png` in that folder as the reference bank for the run, alongside the flows, and the platform compares each flow's `takeScreenshot` captures against it.

## Setup

1. Generate an API key: open your [MaestroDeck dashboard](https://dashboard.maestrodeck.cloud) profile page, section **API keys**, click **Generate key**. Copy it (it is shown only once).
2. Add it as a secret in your repo: **Settings → Secrets and variables → Actions → New repository secret**, name `MAESTRO_API_KEY`.
3. Add the step to a workflow (see examples below).

## Inputs

| Input | Required | Default | Description |
|---|---|---|---|
| `api_key` | yes | | Your MaestroDeck API key (`mk_live_...`). Always pass it via a secret. |
| `platform` | yes | | `ios`, `android` or `web`. |
| `app` | for `ios`/`android` | | Path to the `.apk` (Android) or `.app.zip` (iOS). Ignored when `platform: web`. |
| `url` | for `web` | | URL of the site to test, e.g. `https://example.com`. Must be reachable from the public internet. |
| `flow` | yes | | Path or glob to your Maestro `.yaml` flow files, or a directory of them. |
| `email` | no | account email | Send the report to a specific address instead of your account email. |
| `timeout` | no | `1800` | Max seconds to wait for the result before giving up. Does not change the run's own server-side timeout. |
| `bank_path` | no | `""` | Folder of reference `.png` images, relative to the repo root. Empty disables visual regression entirely. |
| `app_name` | no | `""` | Name under which to file the bank on the platform (groups runs under `/apps` on the dashboard). Only meaningful when `bank_path` is set. |
| `visual_strict` | no | `"false"` | Fail the step when the visual report shows a difference (`changed` or `missing` images). Never affects the run's own `status`, only this step's exit code. |
| `screen_size` | no | `""` | Browser size for web runs, as `{width}x{height}` in pixels (e.g. `1440x900`). Empty uses the platform default, `1512x982`. Width 320 to 3840, height 320 to 2160. Web only: sending it with `platform: ios` or `platform: android` fails the run with `SCREEN_SIZE_NOT_SUPPORTED`. |

## Outputs

| Output | Description |
|---|---|
| `job_id` | The created job id. |
| `status` | Final status: `passed`, `failed`, or `error`. |
| `report_url` | Link to the full report in the dashboard. |
| `visual_changed` | Number of bank images whose capture differs from the reference. Empty when `bank_path` was not set. |
| `visual_missing` | Number of bank images with no matching capture. Empty when `bank_path` was not set. |

## Examples

### Android

```yaml
name: E2E
on: [push]
jobs:
  e2e:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      # ... build your APK into build/app-release.apk ...
      - uses: BlueShork/maestro-action@v5
        with:
          api_key: ${{ secrets.MAESTRO_API_KEY }}
          platform: android
          app: build/app-release.apk
          flow: .maestro/
```

### iOS

```yaml
- uses: BlueShork/maestro-action@v5
  with:
    api_key: ${{ secrets.MAESTRO_API_KEY }}
    platform: ios
    app: build/MyApp.app.zip
    flow: .maestro/login.yaml
```

### Web

No build step and no `app`: point the action at a URL.

```yaml
name: E2E
on: [push]
jobs:
  e2e:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: BlueShork/maestro-action@v5
        with:
          api_key: ${{ secrets.MAESTRO_API_KEY }}
          platform: web
          url: https://example.com
          flow: .maestro/
```

To test a preview deployment, feed it the URL your deploy step produced:

```yaml
- uses: BlueShork/maestro-action@v5
  with:
    api_key: ${{ secrets.MAESTRO_API_KEY }}
    platform: web
    url: ${{ steps.deploy.outputs.preview_url }}
    flow: .maestro/checkout.yaml
```

### Browser size

Web runs open the browser at `1512x982` by default. Set `screen_size` to test another viewport:

```yaml
- uses: BlueShork/maestro-action@v5
  with:
    api_key: ${{ secrets.MAESTRO_API_KEY }}
    platform: web
    url: https://example.com
    flow: .maestro/
    screen_size: 1440x900
```

This matters most alongside a bank: the platform refuses to compare two images of different dimensions and records the capture as `changed`. A bank captured at `1440x900` is only usable if the run opens at `1440x900`, so keep the two in step.

The input is web-only. Sent with `platform: ios` or `platform: android`, the run is rejected with `SCREEN_SIZE_NOT_SUPPORTED` rather than silently ignored, so a mismatched bank never gets blamed on the wrong thing.

### Visual regression

```yaml
- uses: BlueShork/maestro-action@v5
  id: maestro
  with:
    api_key: ${{ secrets.MAESTRO_API_KEY }}
    platform: web
    url: https://example.com
    flow: .maestro/
    bank_path: .maestro/bank
    app_name: my-app
    visual_strict: "true"
- if: always()
  run: |
    echo "changed: ${{ steps.maestro.outputs.visual_changed }}"
    echo "missing: ${{ steps.maestro.outputs.visual_missing }}"
```

The bank is matched by filename against each flow's `takeScreenshot` captures. `visual_strict: "true"` fails this step (not the run's own `status`) when any capture changed or is missing; leave it `"false"` (the default) to only record the report without failing the build. When `bank_path` is empty, behavior is unchanged from before: no bank is sent, no visual comparison runs, `visual_strict` is a no-op, and the outputs are empty strings.

### Using the outputs

```yaml
- uses: BlueShork/maestro-action@v5
  id: maestro
  with:
    api_key: ${{ secrets.MAESTRO_API_KEY }}
    platform: android
    app: build/app-release.apk
    flow: .maestro/
- if: always()
  run: echo "Report: ${{ steps.maestro.outputs.report_url }}"
```

## Notes

- `flow` accepts a single file (`.maestro/login.yaml`), a glob (`.maestro/*.yaml`), or a directory (`.maestro/`, which picks up every `.yaml`/`.yml` inside).
- For `platform: web`, the target site must be reachable from the public internet. `localhost`, private IP ranges and internal hostnames are rejected, so run the action against a deployed preview rather than a server started inside the job.
- The step consumes one run from your MaestroDeck quota per invocation.
- Requires `curl` and `jq`, both preinstalled on GitHub-hosted runners.

## License

MIT
