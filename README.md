# Supabase backup and restore drill orb for CircleCI

A CircleCI orb that runs the open-source [backupdrill](https://www.npmjs.com/package/backupdrill) CLI in your own pipeline. It backs up a Supabase project into your own S3-compatible bucket, such as AWS S3, Cloudflare R2 or Backblaze B2, and restore-drills the backups.

- **Backup** dumps the Postgres database next to a `manifest.json` that records the dump's SHA-256 checksum. Once you add the Storage S3 keys, it copies your Storage files too. It dumps the `public` schema unless you list others in a `BACKUPDRILL_SCHEMAS` variable (comma-separated). By default it also tries to save Auth users to a separate `auth.dump`; see [Auth users](#auth-users).
- **Drill** restores a snapshot into a throwaway Postgres and checks it: the archive checksum, a sample of Storage file checksums, and that every table in the manifest came back. For ordinary tables it compares the exact row count with the count in the dump, and a difference of one row fails the job. Materialized views, partitioned parent tables and tables an extension fills aren't compared row by row; the drill flags them if they come back empty when the manifest expects rows. If the snapshot includes `auth.dump`, the drill also tries to restore it and reports the Auth result separately. The database and Storage checks decide whether the job passes.

Your CircleCI job reads the data from Supabase and writes the backup to your bucket. The CLI sends no database contents or Storage files to BackupDrill. The docs for the [Supabase backup CLI](https://backupdrill.com/docs/cli) explain the connection string, bucket and Storage settings these jobs read.

## Quick start

```yaml
version: 2.1

orbs:
  backupdrill: backupdrill/supabase-backup@1.0.0

parameters:
  backupdrill:
    type: string
    default: ""

workflows:
  supabase-backup:
    when:
      equal: [backup-and-drill, << pipeline.parameters.backupdrill >>]
    jobs:
      - backupdrill/backup-and-drill:
          context: supabase-backup
          bucket: my-supabase-backups
          s3_endpoint: https://<account-id>.r2.cloudflarestorage.com   # leave out for AWS S3
          serial-group: << pipeline.project.slug >>/backupdrill
```

The workflow runs only when the `backupdrill` pipeline parameter is `backup-and-drill`. A schedule trigger sets it (step 3 below), and so can you when you trigger a pipeline by hand. A push leaves it empty, so pushes don't run it.

`backup-and-drill` backs up and then drills the snapshot it has just written, in one job. The serial group stops two runs from overlapping.

## Setup

1. **Create a context for the secrets.** Go to **Organization Settings > Contexts**, create one named `supabase-backup` (any name works, as long as the jobs use it) and add these environment variables:

   | Variable | Value |
   |---|---|
   | `BACKUPDRILL_DATABASE_URL` | The Session pooler connection string from **Connect** in the Supabase dashboard |
   | `BACKUPDRILL_S3_ACCESS_KEY_ID` | The bucket's access key ID |
   | `BACKUPDRILL_S3_SECRET_ACCESS_KEY` | The bucket's secret access key |
   | `BACKUPDRILL_SUPABASE_STORAGE_ENDPOINT`, `_REGION`, `_ACCESS_KEY_ID`, `_SECRET_ACCESS_KEY` | Optional. Set all four to back up Storage files. The keys come from **Storage > Settings > S3 Access Keys** in Supabase |

   A new context can be used by every project in the organization. Restrict it to the project that runs the backups, and on GitHub organizations to a security group as well. Context values take precedence over project variables of the same name.

2. **Add the orb** to `.circleci/config.yml` as in the quick start. For AWS S3, leave out `s3_endpoint` and set `s3_region` (for example `us-east-1`). For R2, the region can stay empty.

3. **Create a schedule trigger** on your default branch, for example daily at 03:00 UTC, and give it the pipeline parameter `backupdrill` = `backup-and-drill`. Schedule triggers are under **Project Settings > Triggers** for GitHub OAuth and Bitbucket projects, and under **Project Settings > Project Setup** for GitHub App projects. The trigger runs as the user it is attributed to, who needs access to the context. Then trigger a pipeline on that branch by hand with the same parameter and check that the job passes.

## Jobs

| Job | Runs | Executor |
|---|---|---|
| `backupdrill/backup-and-drill` | `backupdrill backup`, then `backupdrill drill` on that snapshot | `machine` |
| `backupdrill/backup` | `backupdrill backup` | `node` |
| `backupdrill/drill` | `backupdrill drill` on the newest snapshot in the bucket | `machine` |

They all take the same parameters. Leave a bucket parameter empty to use its variable instead: `bucket` → `BACKUPDRILL_S3_BUCKET`, `s3_endpoint` → `BACKUPDRILL_S3_ENDPOINT`, `s3_region` → `BACKUPDRILL_S3_REGION`, `project_name` → `BACKUPDRILL_PROJECT_NAME`. A parameter you set wins over the variable.

| Parameter | Default | |
|---|---|---|
| `cli_version` | `2.11.0` | Version of the backupdrill npm package, or `latest` |
| `postgres_version` | `17` | Major version of the PostgreSQL client the job installs. It can't be lower than your Supabase Postgres version, or for a drill on its own, the `pg_dump` that made the snapshot |
| `bucket`, `s3_endpoint`, `s3_region`, `project_name` | empty | See above. `project_name` is the folder for the project's snapshots, `supabase` when nothing sets it |
| `no_output_timeout` | `30m` | How long the step may print nothing before CircleCI stops it |
| `executor` | see the table above | Executor to run on |

- The `node` executor is `node:24-trixie-slim`. The backup installs `pg_dump` into it from the PostgreSQL apt repository.
- The `machine` executor is a Linux VM, `ubuntu-2404:current`. The drill starts its throwaway Postgres with `docker run -p 127.0.0.1:0:5432` and connects to 127.0.0.1, so Docker has to run on the job's own host. With the Docker executor and `setup_remote_docker` that port opens on a remote host the job can't reach. For bigger databases, pass `executor: {name: backupdrill/machine, resource_class: large}`.

The orb also has the commands `install-postgres-client`, `backup`, `drill` and `backup-and-drill`, if you'd rather call them in a job of your own. The two that drill still need a machine executor.

## Auth users

By default the CLI tries to save `auth.users` and `auth.identities` to a separate `auth.dump` in each snapshot. The file holds email addresses and password hashes, so check who can read the bucket. To confirm a snapshot has it, look for `"status": "included"` under `auth` in its `manifest.json`.

- In the default mode the backup still passes when the database role can't read the Auth tables. Set a `BACKUPDRILL_AUTH` variable to `on` to fail the job instead, or to `off` to skip `auth.dump`. With `on`, a failed Auth backup still leaves a database snapshot that a later drill can use, but `backup-and-drill` stops before its drill.
- If you list `auth` in `BACKUPDRILL_SCHEMAS`, the Auth tables go into the main dump and `auth.dump` is skipped.

## Drill on its own schedule

To drill less often than you back up, for example once a week, run `backup` and `drill` from two workflows and two schedule triggers, one setting `backupdrill` to `backup` and the other to `drill`:

```yaml
workflows:
  daily-backup:
    when:
      equal: [backup, << pipeline.parameters.backupdrill >>]
    jobs:
      - backupdrill/backup:
          context: [backup-bucket, supabase-source]
          bucket: my-supabase-backups
          s3_region: us-east-1
          serial-group: << pipeline.project.slug >>/backupdrill
  weekly-drill:
    when:
      equal: [drill, << pipeline.parameters.backupdrill >>]
    jobs:
      - backupdrill/drill:
          context: backup-bucket
          bucket: my-supabase-backups
          s3_region: us-east-1
          serial-group: << pipeline.project.slug >>/backupdrill
```

Here the bucket keys are in a `backup-bucket` context and the Supabase variables in `supabase-source`, so the drill job never receives the database connection string. With one context for both, the orb still clears the Supabase variables before it starts the drill.

The shared serial group runs the two jobs one at a time, so a drill doesn't restore a snapshot that a backup is still writing. Schedule them at different hours: when jobs from two pipelines wait in the same group, CircleCI may skip the one from the older pipeline. A drill on its own picks the newest snapshot folder, so if a backup failed partway, the next drill fails too, and you hear about it.

## More than one Supabase project

Keep the bucket keys in one context and each project's `BACKUPDRILL_DATABASE_URL` (plus its four Storage variables, if you back up Storage files) in a context of its own. Give every job a `name`, a `project_name` and its own serial group:

```yaml
jobs:
  - backupdrill/backup-and-drill:
      name: production
      context: [backup-bucket, supabase-production]
      bucket: my-supabase-backups
      s3_endpoint: https://<account-id>.r2.cloudflarestorage.com
      project_name: production
      serial-group: << pipeline.project.slug >>/backupdrill-production
  - backupdrill/backup:
      name: staging
      context: [backup-bucket, supabase-staging]
      bucket: my-supabase-backups
      s3_endpoint: https://<account-id>.r2.cloudflarestorage.com
      project_name: staging
      serial-group: << pipeline.project.slug >>/backupdrill-staging
```

Don't put the same variable in two contexts that one job uses.

## Alerts with Healthchecks.io

Set `BACKUPDRILL_PING_URL` and the CLI sends start, success and failure pings. With `backup-and-drill`, the backup and the drill both ping the same check. When they run as separate jobs, give each its own check by putting each ping URL in a small context that only that job uses: with one shared check, daily backups keep it green even after the drills stop. After the first scheduled run, check that the checks have received a ping, because a check still in the New state won't alert.

## Good to know

- **Egress.** Each backup sends the selected schemas out of Supabase again, and that counts toward your Supabase egress. Run `npx backupdrill estimate` before scheduling daily backups of a large database. The drill reads from your bucket, not from Supabase.
- **Drill cost.** Each drill downloads the whole dump from your bucket and restores it on a CircleCI VM. AWS S3 can charge for that data transfer; R2 has no egress fees. Drilling weekly instead of daily cuts both.
- **What the orb leaves out.** It installs the CLI from the public npm registry with your `.npmrc` files ignored, and runs npm with none of your `BACKUPDRILL_*` variables in its environment. It unsets `DATABASE_URL` (the CLI would otherwise fall back to it, and in CI it usually points at a test database) and ignores any `backupdrill.config.json` in a checked-out repository. The jobs don't check out your code. Settings come from the parameters and the environment only.
- **Job log.** The log shows the CLI's progress and its summary. The JSON the CLI prints on stdout, which for a backup lists every table and Storage file path, isn't printed.
- **Versions.** `cli_version` pins the backupdrill npm version (default `2.11.0`).

## License

MIT, same as the [backupdrill CLI](https://github.com/backupdrill/cli).
