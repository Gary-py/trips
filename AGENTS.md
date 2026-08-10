# Travel Library operating rules

- `Desktop\Trips` is the only Git root for the Travel Library.
- Trip folders never contain nested `.git` directories.
- Preserve each trip template unless explicitly asked to change it.
- Never overwrite a local trip with a stale ChatGPT/Gemini copy.
- Fetch before publish.
- Stop on remote/local conflict.
- Never force push.
- `_archive` is local-only rollback storage.
- Validate before commit.
- Verify GitHub Pages after publish.
- A trip `PUBLISH.cmd` may stage and publish only its own direct-child folder.
