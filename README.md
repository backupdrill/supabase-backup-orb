# Supabase backup and restore drill orb for CircleCI

A CircleCI orb with two jobs that run the open-source [backupdrill](https://www.npmjs.com/package/backupdrill) CLI in your own pipeline:

- `backupdrill/backup` dumps a Supabase project's Postgres database into your own S3-compatible bucket, such as AWS S3, Cloudflare R2 or Backblaze B2, next to a `manifest.json` that records the dump's SHA-256 checksum. Once you add the Storage S3 keys, it copies your Storage files too. It dumps the `public` schema unless you list others in a `BACKUPDRILL_SCHEMAS` variable (comma-separated). By default it also tries to save Auth users to a separate `auth.dump`; see [Auth users](#auth-users).
- `backupdrill/drill` restores the latest snapshot into a throwaway Postgres and checks it: the archive checksum, a sample of Storage file checksums, and that every table in the manifest came back. For ordinary tables it compares the exact row count with the count in the dump, and a difference of one row fails the job. The dump holds no rows of their own for materialized views, partitioned parent tables or tables an extension fills, so for those the drill only checks they aren't empty when the manifest expects rows. If the snapshot includes `auth.dump`, the drill also tries to restore it and reports the Auth result separately. The database and Storage checks decide whether the job passes.

Your CircleCI job reads the data from Supabase and writes the backup to your bucket. The CLI sends no database contents or Storage files to BackupDrill. Every `BACKUPDRILL_*` variable the CLI reads is listed in the docs for the [Supabase backup CLI](https://backupdrill.com/docs/cli).

## Quick start

```yaml
version: 2.1

orbs:
  backupdrill: backupdrill/supabase-backup@1.0.0

parameters:
  run-backupdrill:
    type: boolean
    default: false

workflows:
  supabase-backup:
    when:
      or:
        - equal: [scheduled_pipeline, << pipeline.trigger_source >>]
        - << pipeline.parameters.run-backupdrill >>
    jobs:
      - backupdrill/backup:
          context: supabase-backup
          bucket: my-supabase-backups
          s3_endpoint: https://<account-id>.r2.cloudflarestorage.com   # leave out for AWS S3
          serial-group: << pipeline.project.slug >>/backupdrill
      - backupdrill/drill:
          context: supabase-backup
          requires:
            - backupdrill/backup
          bucket: my-supabase-backups
          s3_endpoint: https://<account-id>.r2.cloudflarestorage.com
```

The workflow runs only when a schedule starts the pipeline, or when you trigger a pipeline by hand with `run-backupdrill` set to `true`. Pushes don't run it.

## Setup

1. **Create a context for the secrets.** Go to **Organization Settings > Contexts**, create one named `supabase-backup` (any name works, as long as the jobs use it) and add these environment variables:

   | Variable | Needed by | Value |
   |---|---|---|
   | `BACKUPDRILL_DATABASE_URL` | backup | The Session pooler connection string from **Connect** in the Supabase dashboard |
   | `BACKUPDRILL_S3_ACCESS_KEY_ID` | backup, drill | The bucket's access key ID |
   | `BACKUPDRILL_S3_SECRET_ACCESS_KEY` | backup, drill | The bucket's secret access key |
   | `BACKUPDRILL_SUPABASE_STORAGE_ENDPOINT`, `_REGION`, `_ACCESS_KEY_ID`, `_SECRET_ACCESS_KEY` | backup (optional) | Set all four to back up Storage files. The keys come from **Storage > Settings > S3 Access Keys** in Supabase |

   The drill doesn't need the connection string, and the orb doesn't pass it on to the drill. Project-level environment variables work too, but a context can be limited to a security group, and context values win over project variables of the same name.

2. **Add the orb** to `.circleci/config.yml` as in the quick start. For AWS S3, leave out `s3_endpoint` and set `s3_region` (for example `us-east-1`). For R2, the region can stay empty.

3. **Create a schedule.** In **Project Settings > Triggers**, add a schedule trigger, for example daily at 03:00 UTC, on your default branch. Then trigger a pipeline on that branch with the `run-backupdrill` parameter set to `true` and check that both jobs pass.

## Jobs

Both jobs take the same parameters. Leave a bucket parameter empty to use its variable instead: `bucket` → `BACKUPDRILL_S3_BUCKET`, `s3_endpoint` → `BACKUPDRILL_S3_ENDPOINT`, `s3_region` → `BACKUPDRILL_S3_REGION`, `project_name` → `BACKUPDRILL_PROJECT_NAME`. A parameter you set wins over the variable.

| Parameter | Default | |
|---|---|---|
| `cli_version` | `2.11.0` | Version of the backupdrill npm package, or `latest` |
| `postgres_version` | `17` | Major version of the PostgreSQL client the job installs. For `backup` it can't be lower than your Supabase Postgres version, for `drill` not lower than the `pg_dump` that made the snapshot |
| `bucket`, `s3_endpoint`, `s3_region`, `project_name` | empty | See above. `project_name` is the folder for the project's snapshots, `supabase` when nothing sets it |
| `no_output_timeout` | `30m` | How long the step may print nothing before CircleCI stops it |
| `executor` | `node` for backup, `machine` for drill | Executor to run on |

- **backup** runs on `node:24-trixie-slim` (the orb's `node` executor) and installs `pg_dump` from the PostgreSQL apt repository.
- **drill** runs on a Linux VM, `ubuntu-2404:current` (the orb's `machine` executor). The drill starts its throwaway Postgres with `docker run -p 127.0.0.1:0:5432` and connects to 127.0.0.1, so Docker has to run on the job's own host. With the Docker executor and `setup_remote_docker` that port opens on a remote host the job can't reach. Pass `executor: {name: backupdrill/machine, resource_class: large}` for bigger databases.

The orb also has the commands `install-postgres-client`, `backup` and `drill`, if you'd rather call them in a job of your own. `drill` still needs a machine executor.

## Auth users

By default the CLI tries to save `auth.users` and `auth.identities` to a separate `auth.dump` in each snapshot. The file holds email addresses and password hashes, so check who can read the bucket. To confirm a snapshot has it, look for `"status": "included"` under `auth` in its `manifest.json`.

- In the default mode the backup job still passes when the database role can't read the Auth tables. Set a `BACKUPDRILL_AUTH` variable to `on` to fail the job instead, or to `off` to skip `auth.dump`. With `on`, a failed Auth backup still leaves a database snapshot that a later drill can use.
- If you list `auth` in `BACKUPDRILL_SCHEMAS`, the Auth tables go into the main dump and `auth.dump` is skipped.

## Drill on its own schedule

A drill downloads the database dump from your bucket and restores it. To drill less often than you back up, for example once a week, add two schedule triggers named `daily-backup` and `weekly-drill`, and run each job from its own workflow:

```yaml
workflows:
  daily-backup:
    when:
      and:
        - equal: [scheduled_pipeline, << pipeline.trigger_source >>]
        - equal: [daily-backup, << pipeline.schedule.name >>]
    jobs:
      - backupdrill/backup:
          context: supabase-backup
          bucket: my-supabase-backups
          s3_region: us-east-1
          serial-group: << pipeline.project.slug >>/backupdrill
  weekly-drill:
    when:
      and:
        - equal: [scheduled_pipeline, << pipeline.trigger_source >>]
        - equal: [weekly-drill, << pipeline.schedule.name >>]
    jobs:
      - backupdrill/drill:
          context: supabase-backup
          bucket: my-supabase-backups
          s3_region: us-east-1
          serial-group: << pipeline.project.slug >>/backupdrill
```

The shared serial group runs the two jobs one at a time, so a drill doesn't restore a snapshot that a backup is still writing. Schedule them at different hours: when jobs from two pipelines wait in the same group, CircleCI may skip the one from the older pipeline.

## More than one Supabase project

Keep the bucket keys in one context and each project's `BACKUPDRILL_DATABASE_URL` (plus its four Storage variables, if you back up Storage files) in a context of its own, then give every job a `name` and a `project_name`:

```yaml
jobs:
  - backupdrill/backup:
      name: backup-production
      context: [backup-bucket, supabase-production]
      project_name: production
  - backupdrill/backup:
      name: backup-staging
      context: [backup-bucket, supabase-staging]
      project_name: staging
  - backupdrill/drill:
      name: drill-production
      context: backup-bucket
      project_name: production
      requires:
        - backup-production
```

Don't put the same variable in two contexts that one job uses.

## Alerts with Healthchecks.io

Set `BACKUPDRILL_PING_URL` and the CLI sends start, success and failure pings. Give the backup and the drill separate checks, by putting each ping URL in a small context that only that job uses: with one shared check, daily backups keep it green even after the drills stop. After the first scheduled run, check that both checks have received a ping, because a check still in the New state won't alert.

## Good to know

- **Egress.** Each backup transfers the selected schemas out of Supabase again, and Supabase counts that as egress on your bill. Run `npx backupdrill estimate` before scheduling daily backups of a large database. The drill reads from your bucket, not from Supabase.
- **Drill cost.** Each drill downloads the whole dump from your bucket (AWS S3 charges for that download, R2 doesn't) and restores it on a VM, so a weekly drill costs less than a daily one.
- **What the orb leaves out.** It installs the CLI from the public npm registry with your `.npmrc` files ignored, unsets `DATABASE_URL` (the CLI would otherwise fall back to it, and in CI it usually points at a test database) and ignores any `backupdrill.config.json` in a checked-out repository. The jobs don't check out your code. Settings come from the parameters and the environment only.
- **Job log.** The log shows the CLI's progress and its summary. The JSON the CLI prints on stdout, which for a backup lists every table and Storage file path, isn't printed.
- **Versions.** `cli_version` pins the backupdrill npm version (default `2.11.0`).

## License

MIT, same as the [backupdrill CLI](https://github.com/backupdrill/cli).
