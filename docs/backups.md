# Object storage and recovery

Production stores Flurry repository objects in private DigitalOcean Spaces using
its S3-compatible API. The local filesystem driver remains available for
development and one-node installations.

## Environment contract

Flurry reads process environment variables; it does not load `.env` itself.
Keep real credentials in the deployment secret store.

| Variable | Meaning |
| --- | --- |
| `FLURRY_STORAGE_DRIVER` | `s3` in production or `local` for filesystem storage |
| `FLURRY_S3_ENDPOINT` | HTTPS S3 API origin, such as `https://nyc3.digitaloceanspaces.com` |
| `FLURRY_S3_BUCKET` | Private bucket name |
| `FLURRY_S3_REGION` | Signing region, such as `nyc3` |
| `FLURRY_S3_PREFIX` | Instance-specific key prefix, such as `flurry` |
| `FLURRY_S3_ACCESS_KEY_ID` | Bucket-scoped access key |
| `FLURRY_S3_SECRET_ACCESS_KEY` | Matching secret |
| `FLURRY_STORE` | Local object directory, used by the local driver and migration tooling |

Use a dedicated bucket-scoped key. Never expose it in browser responses, command
arguments, logs, or repository configuration. The admin diagnostic reports the
selected storage driver but never credentials.

## Object layout and integrity

Objects use this layout:

```text
PREFIX/objects/v1/ab/abcdef...64-hex-digit-object-id
```

The shard is the first two hexadecimal characters of the object ID. Stored bytes
are zlib-compressed. The ID is SHA-256 of the uncompressed type name, NUL
separator, and payload. Every read decompresses the object and verifies both its
type and digest. Objects stay private even when a repository is public; Flurry's
authorization layer controls access.

Writes complete in object storage before the database can reference an object.
The namespace is immutable and content-addressed, so repeating the same write is
safe. A failed database transaction can leave an unreachable object; automatic
garbage collection is deliberately not implemented yet.

## Migration

`Flurry.Store.Migration.migrate_local_to_s3/0` uploads every canonical local
object and reads the exact compressed bytes back. After it reports equal migrated
and verified counts, run `verify_local_against_s3/0`, switch
`FLURRY_STORAGE_DRIVER` to `s3`, and restart. `probe_s3/0` verifies production
write/read access without creating repository records.

Keep the old local directory until representative repository reads, history,
reviews, and Git clones succeed through the S3 driver. It is rollback material,
not the active store after cutover.

## Recovery

Postgres holds the metadata and references required to interpret the object
prefix. Nightly database backups must therefore continue. Repository objects are
immutable and are not included in the local data-directory archive after cutover.
Do not delete objects merely because they are absent from `main`: reviews,
removed repositories, and history may still reference them.

For recovery, restore the application encryption key and Postgres database,
configure access to the complete private object prefix, run the storage probe,
then verify representative file reads, history, reviews, and Git clones before
accepting traffic. A separate bucket replication or snapshot policy can add a
second physical copy; it must be additive and must never propagate application-
unaware deletes into the primary prefix.

## Docker Compose installations

The default Compose setup stores PostgreSQL in the `database` volume and local
content-addressed objects in the `objects` volume. Treat them as one recovery set.
Stopping application writes before a coordinated snapshot gives the clearest
recovery point; otherwise use a PostgreSQL-consistent dump and retain the complete
object volume from the same backup window.

Do not back up only the database or only the object volume. After restoring both,
start Flurry so pending migrations run, check `/api/health`, then verify file reads,
history, reviews, and Git clone/fetch before reopening the instance.
