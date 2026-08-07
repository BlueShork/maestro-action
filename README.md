# MaestroDeck Cloud Action

Run [Maestro](https://maestro.mobile.dev/) tests on [MaestroDeck Cloud](https://maestrodeck.cloud) from your CI, on **iOS, Android or Web**, with a single step. The build fails if the tests fail.

```yaml
- uses: BlueShork/maestro-action@v1
  with:
    api_key: ${{ secrets.MAESTRO_API_KEY }}
    platform: android
    app: build/app-release.apk
    flow: .maestro/
```

## How it works

The action uploads your app and flows to MaestroDeck Cloud, runs them on a real simulator/emulator, waits for the result, and exits `0` (passed) or `1` (failed/error). Android jobs dispatch instantly; iOS jobs run on the macOS worker pool. You get the same pipeline as the dashboard, triggered from CI.

Web works the same way with one difference: there is no app to build or upload, so you pass `url` instead of `app` and the flows run against that site in a browser.

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

## Outputs

| Output | Description |
|---|---|
| `job_id` | The created job id. |
| `status` | Final status: `passed`, `failed`, or `error`. |
| `report_url` | Link to the full report in the dashboard. |

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
      - uses: BlueShork/maestro-action@v1
        with:
          api_key: ${{ secrets.MAESTRO_API_KEY }}
          platform: android
          app: build/app-release.apk
          flow: .maestro/
```

### iOS

```yaml
- uses: BlueShork/maestro-action@v1
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
      - uses: BlueShork/maestro-action@v1
        with:
          api_key: ${{ secrets.MAESTRO_API_KEY }}
          platform: web
          url: https://example.com
          flow: .maestro/
```

To test a preview deployment, feed it the URL your deploy step produced:

```yaml
- uses: BlueShork/maestro-action@v1
  with:
    api_key: ${{ secrets.MAESTRO_API_KEY }}
    platform: web
    url: ${{ steps.deploy.outputs.preview_url }}
    flow: .maestro/checkout.yaml
```

### Using the outputs

```yaml
- uses: BlueShork/maestro-action@v1
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
