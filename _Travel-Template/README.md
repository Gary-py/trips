# Travel Template

This folder documents the reusable trip-library layout. Each actual trip belongs in its own direct child folder under `Desktop\Trips` and must be an independent Git repository.

Required trip files:

- `index.html` — authoritative trip page
- `PUBLISH.cmd` — one-click safe publish
- `AGENTS.md` — trip-specific operating rules
- `README.md` — trip documentation

Use `..\_tools\Initialize-Trip.ps1` to create a future trip and `..\_tools\Publish-Trip.ps1` to publish an existing trip.
