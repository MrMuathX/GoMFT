# GoMFT Architecture

Read-only survey of the codebase as of this session. Every claim below is tied to a
file actually opened; paths are relative to the repo root
`E:\SHADOW\Projects\GoMFT`. Nothing here was inferred without reading the source.

## 1. Top-level layout

- `main.go` — process entrypoint: config load, DB init, default admin bootstrap, cron/scheduler wiring, Gin router setup, embedded `static` serving, calls `web.NewHandler(...).InitializeRoutes(router)`.
- `internal/config` — `config.Load()`, env-driven config struct (`DataDir`, `BackupDir`, `JWTSecret`, `ServerAddress`, `SkipSSLVerify`, etc.).
- `internal/db` — GORM models + store methods (one `*_store.go` per model) + `internal/db/migrations` (gormigrate).
- `internal/scheduler` — cron scheduling, job execution, rclone transfer execution, notifications, metadata bookkeeping.
- `internal/rclone_service` — standalone helper used only for the "Test Connection" button (`TestRcloneConnection`), separate from the scheduler's transfer path.
- `internal/web` — thin wrapper (`handlers.go`) that constructs `internal/web/handlers.Handlers` and calls `RegisterRoutes`.
- `internal/web/handlers` — all Gin handlers, one file per feature area (`auth_handlers.go`, `config_handlers.go`, `job_handlers.go`, `admin_handlers.go`, `routes.go`, etc.).
- `internal/api` — currently unused; `main.go` imports it commented out (`// "github.com/starfleetcptn/gomft/internal/api"`), and `routes.go`'s `/api` group is served directly from `internal/web/handlers`, not this package.
- `internal/auth`, `internal/email`, `internal/logging`, `internal/testutils` — supporting packages (JWT/password/TOTP helpers, email sending, file+WebSocket logger, test fixtures).
- `components/` — all `.templ` source and their generated `_templ.go` counterparts.
- `static/` — source assets (`css/app.css`, `js/{app,init,vendor}.js`, images); `static/dist/` is the build output directory created by `build.js` (not committed, see `.gitignore`).
- `build.js` — esbuild + Tailwind pipeline (see §7).
- `.air.toml` — live-reload config for local dev (`templ generate && go build`).
- `Dockerfile` — multi-stage build: frontend build → Go build (with `templ generate`) → Alpine runtime with `rclone` installed.
- `entrypoint.sh` — container entrypoint; handles PUID/PGID remap, then execs the binary.
- `docs/` — separate Docusaurus site, not part of the Go app runtime.

## 2. Templates

- All `.templ` source files live flat in `components/` (plus subpackages `components/providers/{source,destination,common}`, `components/notifications`, `components/file_metadata`, `components/shared`).
- Organization is by page/feature, not a strict layout/pages/partials split, but the convention is:
  - `layout.templ` — the shared `Layout`/`LayoutWithContext` shell (nav, theme, HTMX/Alpine script tags) used by every page-level `templ` function.
  - Page-level templates: `login.templ`, `dashboard.templ`, `jobs.templ`, `configs.templ`, `history.templ`, `users.templ`, `settings.templ`, `admin*.templ`, etc. — each exports a top-level `templ FuncName(...)` that wraps content in `@LayoutWithContext(...)`.
  - Form/partial templates: `config_form.templ`, `job_form.templ`, `admin_role_form.templ`, `auth_provider_form.templ`, `dashboard_notifications.templ` — rendered either as full pages or as HTMX fragment responses (handlers call `.Render(c, c.Writer)` directly without wrapping HTML boilerplate for partial routes such as `/notifications/dropdown`).
  - `components.go` is not a components file — it's a one-line package marker (`components/components.go:1-3`).
- Build integration: `.air.toml:8` — `cmd = "templ generate && go build -o ./tmp/main ."`, and `Dockerfile:39-46` runs `go install github.com/a-h/templ/cmd/templ@v0.3.857` then `RUN templ generate` before `go build`. `templ generate` produces a `<name>_templ.go` next to each `<name>.templ`; those generated files are compiled straight into the `components` Go package (same package, same directory) — there is no separate output directory.

## 3. Routes

- Router construction: `main.go:180` creates `router := gin.New()`, adds a custom logger formatter and `gin.Recovery()`, mounts `/static/*filepath` from the embedded `staticFiles` FS (`main.go:196-206`), then calls `webHandler.InitializeRoutes(router)` (`main.go:216`), which is `internal/web/handlers.go:47` → `h.handlers.RegisterRoutes(router)`.
- All route registration is centralized in `internal/web/handlers/routes.go`, function `RegisterRoutes` (`routes.go:8`).
- Middleware chain (defined in `internal/web/handlers/auth_handlers.go`):
  - `AuthMiddleware()` (`auth_handlers.go:35`) — reads `jwt_token` cookie, parses JWT with `h.JWTSecret`, sets `userID`/`email`/`username`/`isAdmin`/`user` in Gin context, redirects to `/login` on failure. Applied to the `authorized` group and the `admin` group (`routes.go:29-30`, `routes.go:113-114`).
  - `AdminMiddleware()` (`auth_handlers.go:103`) — checks `isAdmin` bool in context; currently unused in `routes.go` (the commented-out admin dashboard route at `routes.go:117`).
  - `PermissionMiddleware(perms...)` (`auth_handlers.go:113`) — RBAC check via `db.User.HasPermission`; used per-subgroup under `/admin` (users, roles, audit, logs, settings, database).
  - `APIAuthMiddleware()` (`auth_handlers.go:161`) — Bearer-token JWT auth for `/api` routes.
  - `APIAdminMiddleware()` (`auth_handlers.go:223`) — admin check for `/api/.../admin` routes.
  - No CSRF middleware was found anywhere in `internal/web/handlers` — forms rely on cookie-based JWT auth only.
- Route table (selected, not exhaustive — full detail in `routes.go`):

| Route | Method | Handler | File |
|---|---|---|---|
| `/` | GET | `HandleHome` | `basic_handlers.go` |
| `/login` | GET | `HandleLoginPage` | `auth_handlers.go` |
| `/login` | POST | `HandleLogin` | `auth_handlers.go:277` |
| `/login/verify` | GET/POST | `Handle2FAVerifyPage` / `Handle2FAVerify` | `two_factor_handlers.go` |
| `/forgot-password`, `/reset-password` | GET/POST | `HandleForgotPassword*`, `HandleResetPassword*` | `auth_handlers.go` |
| `/auth/providers`, `/auth/provider/:id`, `/auth/callback` | GET | `GetAuthProviders`, `HandleAuthProviderInit`, `HandleAuthProviderCallback` | `auth_handlers.go` |
| `/logout` | POST | `HandleLogout` | `auth_handlers.go:334` |
| `/dashboard` | GET | `HandleDashboard` | `dashboard_handlers.go` |
| `/configs` | GET | `HandleConfigs` | `config_handlers.go:20` |
| `/configs/new` | GET | `HandleNewConfig` | `config_handlers.go:38` |
| `/configs/:id` | GET | `HandleEditConfig` | `config_handlers.go:46` |
| `/configs` | POST | `HandleCreateConfig` | `config_handlers.go:114` |
| `/configs/:id` | PUT/POST | `HandleUpdateConfig` | `config_handlers.go` |
| `/configs/:id` | DELETE | `HandleDeleteConfig` | `config_handlers.go` |
| `/configs/test-connection` | POST | `HandleTestProviderConnection` | `config_handlers.go` |
| `/jobs`, `/jobs/new`, `/jobs/:id` | GET/POST/PUT/DELETE | `HandleJobs`/`HandleNewJob`/`HandleEditJob`/`HandleCreateJob`/`HandleUpdateJob`/`HandleDeleteJob` | `job_handlers.go` |
| `/jobs/:id/run` | POST | `HandleRunJob` | `job_handlers.go` |
| `/history`, `/job-runs/:id` | GET | `HandleHistory`, `HandleJobRunDetails` | `job_handlers.go`/`dashboard_handlers.go` |
| `/files*` | GET/DELETE | `FileMetadataHandler` methods | `file_metadata_handlers.go` |
| `/admin/users*` | GET/POST/PUT/DELETE | `HandleUsers`, `HandleCreateUser`, etc. | `user_handlers.go` |
| `/admin/roles*` | GET/POST/PUT/DELETE | `HandleRoles`, `HandleCreateRole`, etc. | `admin_handlers.go` |
| `/admin/audit*` | GET | `HandleAuditLogs`, `HandleExportAuditLogs` | `admin_handlers.go` |
| `/admin/logs`, `/admin/logs/ws` | GET | `HandleLogViewer`, `HandleLogStream` (WebSocket) | `admin_handlers.go` |
| `/admin/settings*` | GET/POST | `HandleSettings`, auth-provider & notification sub-routes | `settings_handlers.go`, `auth_provider_handlers.go`, `notifications_handlers.go` |
| `/admin/database*` | GET/POST | `HandleDatabaseTools`, backup/restore/vacuum/export | `database_handlers.go` |
| `/api/login` | POST | `HandleAPILogin` | `api_handlers.go` |
| `/api/configs`, `/api/jobs`, `/api/history`, `/api/admin/*` | GET/POST/PUT/DELETE | `HandleAPI*` | `api_handlers.go` |

## 4. Scheduler

- Package `internal/scheduler`, split into: `scheduler.go` (cron lifecycle), `job_executor.go` (per-job orchestration), `transfer_executor.go` (rclone invocation), `notification.go`, `metadata.go`, `logger.go`, `utils.go`, plus mocks/tests.
- `Scheduler` (`scheduler.go:47`) wraps a `SchedulerCron` interface (backed by `robfig/cron/v3`), a `SchedulerDB`, a `SchedulerLogger`, and a `SchedulerJobExecutor`. Constructed in `main.go:163-183`: a real `cron.New(cron.WithChain(cron.Recover(cron.DefaultLogger)))` is created and started (`main.go:164-165`), then `scheduler.New(...)` wires everything together and calls `s.loadJobs()` (`scheduler.go:92`).
- `loadJobs()` (`scheduler.go:99`) pulls `db.GetActiveJobs()`, clears the shared `jobs map[uint]cron.EntryID`, and calls `ScheduleJob` for each enabled job.
- `ScheduleJob(job *db.Job)` (`scheduler.go:145`) removes any existing cron entry for that job ID, then calls `s.cron.AddFunc(job.Schedule, func(){ s.executor.executeJob(jobID) })` — i.e. the job's `Schedule` field is a raw cron expression passed straight to `robfig/cron`. On success it records `job.NextRun` from `cron.Entry.Next` and persists via `UpdateJobStatus`.
- `RunJobNow(jobID)` (`scheduler.go:220`) launches `s.executor.executeJob(jobID)` in a goroutine — this is what `/jobs/:id/run` (`HandleRunJob`) calls.
- Job lifecycle: `job_executor.go` (`executeJob`) creates a `db.JobHistory` row, iterates the job's configs, and for each config calls `TransferExecutor.executeConfigTransfer` (`transfer_executor.go:78`). History rows are updated in place (`UpdateJobHistory`) with `Status` (`completed` / `completed_with_errors` / `failed`), `BytesTransferred`, `FilesTransferred`, `ErrorMessage`, `EndTime`. File-level results are recorded as `db.FileMetadata` rows (`CreateFileMetadata`) — this is the "file metadata"/history the `/files` and `/job-runs/:id` UI reads from.
- Notifications: `Notifier` (`notification.go`) sends per-job notifications after each execution via `SendNotifications`/`createJobNotification`.
- Logs: `scheduler.NewLogger()` (`logger.go`) writes to files under `<DataDir>/logs` (created in `main.go:80-84`) and is bridged to a WebSocket broadcaster (`main.go:219-224`, consumed by `/admin/logs/ws`).

## 5. rclone invocation

Two independent code paths shell out to the `rclone` binary — they are **not** unified:

- **Connection test** (`internal/rclone_service/rclone_service.go`): `TestRcloneConnection(config, providerType, dbInstance)` (`rclone_service.go:31`) builds a throwaway `rclone config create <name> <provider> --config <tmpfile> --non-interactive` command per provider type (`sftp`, `s3`, `wasabi`, `minio`, `b2`, `ftp`, `smb`, `webdav`, `nextcloud`, `gdrive`, `gphotos`, `local`), then runs `rclone --config <tmpfile> lsd <name>:<path>` with a 30s timeout, using the mockable vars `execCommandContext`/`cmdCombinedOutput`/`cmdRun` (`rclone_service.go:21-27`). Called from `config_handlers.go`'s `HandleTestProviderConnection`.
- **Actual transfer config generation**: `internal/db/transfer_config_store.go`, `GenerateRcloneConfig(config *TransferConfig)` (`transfer_config_store.go:74`). Computes the persistent path via `GetConfigRclonePath` (`transfer_config_store.go:60-69`): `filepath.Join(os.Getenv("DATA_DIR") or "./data", "configs", fmt.Sprintf("config_%d.conf", config.ID))`, then shells out to `rclone config create source_<id> ...` and `rclone config create dest_<id> ...` (one block per provider type, same provider list as above) to populate that persistent `.conf` file on disk — no manual INI templating, rclone itself writes the file.
- **Job execution**: `internal/scheduler/transfer_executor.go`. `executeConfigTransfer` (`transfer_executor.go:78`) resolves `configPath := te.db.GetConfigRclonePath(&config)`, determines the rclone subcommand from `config.CommandID` (default `copyto`), and either:
  - runs `rclone --config <path> lsjson --hash --recursive [--filter-from <file>] source_<id>:<path>` to enumerate files, then transfers file-by-file with `rclone --config <path> <cmd> source_<id>:<src>/<file> dest_<id>:<dst>/<file>` inside a bounded worker pool (`concurrencySemaphore`, size = `config.MaxConcurrentTransfers`, forced to 1 for `gphotos`); or
  - for directory-based commands (`sync`,`bisync`,`copy`,`move`) / non-transfer commands, `executeSimpleCommand` (`transfer_executor.go:~430`) runs a single `rclone --config <path> <cmd> <src> <dst> --log-file <tmp> --log-level DEBUG` and parses the temp log file with regexes (`Copied`, hash lines, `Transferred:` stats) to populate `FileMetadata`/`JobHistory`.
  - Optional post-steps per file: archive copy (`rclone copyto ... source_<id>:<archivePath>/<file>`) and delete (`rclone deletefile ...`) — both driven by `config.ArchiveEnabled`/`config.DeleteAfterTransfer`.
  - All `rclone` invocations resolve the binary path from `os.Getenv("RCLONE_PATH")`, falling back to the bare string `"rclone"` (found identically in all three files above).
  - Exit codes/output: everywhere output is captured via `cmd.CombinedOutput()` or explicit `Stdout`/`Stderr` buffers and `cmd.Run()`; non-nil `error` from `exec.Cmd` (which encodes a non-zero exit code) drives `history.Status = "failed"`/`"completed_with_errors"`, with stderr text pattern-matched for friendlier error strings (`rclone_service.go:~275-286`).
- Docker: `Dockerfile:80-93` downloads a versioned rclone zip from `https://downloads.rclone.org/rclone-current-linux-<arch>.zip` in the builder stage and copies the extracted binary to `/usr/local/bin/rclone` in both the builder and the final Alpine runtime stage (`Dockerfile:118`). No rclone version pin — always pulls "current".

## 6. Database

- GORM models live in `internal/db/*.go` (not a separate `models` folder): `user.go`, `job.go`, `transfer_config.go`, `role.go`, `rclone.go`, `auth_provider.go`, `notification.go`, `file_metadata.go`, `audit_log.go`, `user_notification.go`. Each has a paired `*_store.go` with the CRUD methods (e.g. `transfer_config.go` = struct + getters/setters, `transfer_config_store.go` = `CreateTransferConfig`/`GetTransferConfig`/... + rclone config generation).
- Migrations: `internal/db/migrations/`, one file per numbered migration (`001_initial_schema.go` … `013_cleanup_invalid_booleans.go`, plus `012a/b/c` recovery migrations), registered in order inside `GetMigrations()` (`migrations.go:13-30`) using `github.com/go-gormigrate/gormigrate/v2`.
- DB init: `internal/db/db.go`, `Initialize(dbPath)` — opens SQLite via `github.com/glebarez/sqlite` (pure-Go, no CGO), runs `gormigrate`, closes, reopens for a "clean state". `db.go:52` also exposes `ReopenWithoutMigrations` used for backup/restore flows in `database_handlers.go`.
- SQLite file path: `main.go:104` — `dbPath := filepath.Join(cfg.DataDir, "gomft.db")`. `DataDir` comes from `internal/config.Config` (env-driven; default value not re-verified this pass — see `internal/config/config.go`).

## 7. Front-end pipeline

- `build.js` (Node/esbuild script, not a bundler config file): copies Font Awesome CSS/webfonts into `static/dist/fontawesome/`, then esbuild-bundles three entry points — `static/js/vendor.js`, `static/js/app.js`, `static/js/init.js` — each to `static/dist/{vendor,app,init}.js` (IIFE, minified, sourcemapped), and separately shells out to `npx tailwindcss -i ./static/css/app.css -o ./static/dist/app.css --minify` (`build.js:66-68`). `--watch` mode re-runs esbuild in watch context and Tailwind with `--watch`.
- `tailwind.config.js` — not read in depth this pass; referenced only via the CLI invocation above.
- Static assets are embedded into the Go binary via `//go:embed static` in `main.go:31` and served by a custom handler at `/static/*filepath` (`main.go:196-206`) with manual `Content-Type`/`Cache-Control` headers set in `setContentType`/`setCacheHeaders` (`main.go:29-63`). This means `static/dist/**` must exist and be populated by `build.js` *before* `go build` — the Dockerfile enforces this ordering explicitly (frontend-builder stage runs first, `Dockerfile:1-25`, then its `static/dist/` output is copied into the Go build stage at `Dockerfile:35`).
- HTMX usage: templates use `hx-get`/`hx-trigger`/`hx-target` for partial refreshes (e.g. `login.templ:120` loads `/auth/providers` via `hx-get` into `#provider-buttons` on `load`; similar patterns exist for dashboard/notification partial routes registered in `routes.go`). Alpine.js (`x-data`, `x-model`, `x-bind`, `x-show`) is used for client-side form state (e.g. `login.templ:38-107`).

## 8. Notes for redesign

Files a UI redesign must touch:

- `components/layout.templ` — shared shell (nav, header, theme toggle, script/style includes for HTMX/Alpine/Flowbite/Tailwind CSS output). Almost every page template calls into this, so its structure change is the single highest-leverage/highest-risk edit.
- Every page-level `.templ` file listed in §2 (`login.templ`, `dashboard.templ`, `configs.templ`, `config_form.templ`, `jobs.templ`, `job_form.templ`, `history.templ`, `settings.templ`, `admin*.templ`, `users.templ`, etc.) — each hardcodes Tailwind utility classes inline; there is no shared design-token layer or CSS component library beyond raw Tailwind + Flowbite.
- `static/css/app.css` and `tailwind.config.js` — the actual token/theme surface (colors like `primary-*`, dark-mode variants) is defined here, referenced by class name across every `.templ`.
- `static/js/{app,init,vendor}.js` and `build.js` — any change to build tooling (e.g. swapping esbuild/Tailwind versions or adding a component framework) must keep the `static/dist` output contract intact because `main.go`'s embed + Dockerfile copy order both assume that directory exists post-build.
- `components/config_form.templ` + `components/components.go`'s `getInitialData` — the config form is generated from a large Alpine.js `x-data` object built by string-concatenating ~40 default field values (`components.go:14-80` and following); this is tightly coupled to the exact `form:"..."` tag names in `internal/db/transfer_config.go` and to per-provider conditional sections (source/destination "provider" partials under `components/providers/{source,destination,common}`). Any redesign of this form has to keep those field names in sync with `config_handlers.go`'s manual boolean-field parsing (`HandleCreateConfig`, `config_handlers.go:114-160`), since Gin's `ShouldBind` handles most fields but checkboxes are re-parsed manually via `c.Request.FormValue(...)`.

Coupling that makes redesign risky:

- Handlers render templates by calling the generated Go functions directly (`components.Login(...).Render(c, c.Writer)`), so template signatures (`ConfigFormData`, `ConfigsData`, etc., defined in `components.go`) are part of the Go compile-time contract with `internal/web/handlers/*.go` — renaming/restructuring template params requires updating every calling handler in lockstep.
- HTMX partial routes (`/notifications/dropdown`, `/auth/providers`, `/dashboard/data`, `/files/partial`, etc.) return bare HTML fragments, not full pages — a redesign that changes the shared layout must keep these fragment-only responses compatible with whatever container markup replaces them, since the fragments are injected by `hx-target` into pre-existing DOM in the full-page templates.
- Static asset embedding is build-order-dependent (`static/dist` must exist before `go build` due to `//go:embed static`), so any front-end tooling swap (e.g. moving off esbuild/Tailwind CLI to a bundler with a different output path) requires updating `Dockerfile` COPY steps and `.air.toml`'s dev build command together.
- No CSRF tokens exist on any form (verified: not present in `auth_handlers.go`, `config_handlers.go`, or `routes.go`) — forms are authorized purely by the `jwt_token` cookie; a redesign that introduces a JS framework doing fetch/XHR submissions must not accidentally drop the cookie-based auth without adding an equivalent CSRF/auth story.

## Uncertain / not verified

- `internal/config/config.go` was not read in depth in this pass — default values for `DataDir`, `ServerAddress`, etc. are asserted only insofar as they're referenced in `main.go`; the config file itself should be checked before relying on specific defaults.
- `tailwind.config.js` content (theme customization, `primary-*` color scale) was not opened; only its CLI usage in `build.js` was confirmed.
- The full remainder of `config_handlers.go` (past line ~160) and `transfer_executor.go` (past line ~1000, `HandleUpdateConfig`/tail of `executeSimpleCommand`) was not read line-by-line; behavior described for those functions is based on the portions actually read.
