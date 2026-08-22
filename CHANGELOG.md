# Changelog

All notable changes to this fork are documented here.
This fork starts from upstream [StarFleetCPTN/GoMFT](https://github.com/StarFleetCPTN/GoMFT) v0.2.11
(archived September 2025). Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added
- `ARCHITECTURE.md` — map of routes, Templ components, the scheduler and rclone
  invocation, written to support the redesign work.
- Dark-first design system in `static/css/app.css` (layered slate surfaces, a
  single restrained teal accent, tabular numerals for sizes/durations/timestamps).
- Dashboard now shows job status counts, last-run results (status, duration,
  bytes, timestamp) and next scheduled runs.
- Thin custom scrollbars applied globally.
- `.gitattributes` enforcing LF endings for shell scripts.

### Changed
- **Front-end redesign** across `layout`, `login`, `dashboard`, `configs`,
  `config_form`, `jobs` and `history`. Stack is unchanged — still Templ + HTMX +
  Tailwind, no JS framework introduced, no Go handler restructured.
- Transfer-config form regrouped into Identity / Command / Source / Destination /
  Filters & patterns / Advanced, with the long tail collapsed behind disclosures.
  All field names, `hx-*` attributes and provider-switching behaviour preserved.
- Data tables collapse into stacked label/value cards below 640px. Verified at
  375px: no horizontal overflow on any redesigned page.
- rclone is now pinned to **v1.75.0** via `ARG RCLONE_VERSION`. It previously used
  `rclone-current`, which silently changed the bundled version on every rebuild.
- Go builder image moved to `golang:1.25-alpine` to match the `go` directive.

### Fixed
- **Container failed to start from a Windows clone.** `entrypoint.sh` was checked
  out with CRLF endings, so the shebang was invalid and the container restart-looped
  with `exec /entrypoint.sh: no such file or directory`.
- **Docker build was broken.** The Dockerfile installed `templ@latest`, which now
  requires Go >= 1.25 and failed on the Go 1.24 builder stage. The templ CLI is
  pinned to `v0.3.857` to match the library version in `go.mod`.
- **Tailwind produced a near-empty stylesheet.** The `frontend-builder` stage never
  copied `components/`, so Tailwind's content glob matched no `.templ` files and the
  image shipped almost no utility classes. Added `COPY components/ ./components/`.
- Security: bumped `golang.org/x/text` to v0.39.0 for
  [GO-2026-5970](https://pkg.go.dev/vuln/GO-2026-5970) (infinite loop on invalid
  input, reachable through GORM). `govulncheck ./...` is now clean.
- Repaired pre-existing test/build failures: two `go vet` non-constant format
  string errors in `internal/db/transfer_config_store.go`; `notification_test.go`
  out of sync with `NotificationService.IsEnabled` (`*bool`) and the `NewNotifier`
  signature; an `email_test.go` assertion that ignored `html/template` escaping
  `+` as `&#43;`.

### Known issues
- **Cron field-count mismatch (deferred).** Three tests in `internal/scheduler`
  (`TestNewScheduler_LoadJobs`, `TestScheduleJob_Success`,
  `TestScheduleJob_InvalidCron`) fail. The tests expect 6-field cron expressions
  with a seconds column (`0 10 * * * *`) but the scheduler registers 5-field
  expressions (`10 * * * *`), and `ScheduleJob` accepts an invalid cron expression
  without returning an error. Resolving this changes scheduling semantics, so it is
  deliberately deferred rather than papered over. Decide whether seconds-precision
  cron is intended before fixing.
- No CSRF protection anywhere in the application (pre-existing, upstream).
- `formvalidation` in the config form uses the Alpine v2 `form.__x.$data` API.
- The dashboard's "next scheduled runs" only covers jobs present in recent history,
  because `DashboardData` carries no full jobs list.
