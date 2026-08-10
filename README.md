# Gary's Trips Travel Library

This folder is the single local Git root for the Travel Library and maps to the public `Gary-py/trips` repository.

- Live library: https://gary-py.github.io/trips/
- Okinawa 2026: https://gary-py.github.io/trips/okinawa-2026/
- Every trip is a normal subfolder; trip folders never contain nested `.git` directories.
- `_archive` is local-only rollback storage and is ignored by Git.
- Use a trip's `PUBLISH.cmd` to publish only that trip. Use `PUBLISH_LIBRARY.cmd` explicitly for shared/root changes.

The active Okinawa source is `Gary-py/trips/okinawa-2026/index.html`; preserve the existing travel template unless explicitly asked to change it.
