# Apps Directory

Place your application Docker Compose files or Dockerfiles here.

## Adding a New App

See the main [README](../README.md#extending-the-infra-with-new-apps) for the extension guide.

## Example Structure

```
apps/
├── my-react-app/      # React frontend
├── my-node-api/       # Node.js backend
└── shared/            # Shared configs if needed
```

Each app should:
1. Connect to `traefik-network` for HTTP/HTTPS routing through Traefik
2. Connect to `backend-network` for Redis/Postgres access
3. Add Traefik labels for routing
4. Use environment variables from an app-specific `.env`
