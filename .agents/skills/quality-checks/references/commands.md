# Quality Check Commands

## Preferred full-run path

Run the Docker Compose quality stack first:

```powershell
docker compose -f docker-compose.yml -f test/docker-compose.quality.yml run --rm --build quality-check
```

This is the preferred path because it reuses the purpose-built quality image and benefits from Docker layer caching after the first run.

## Wrapper verification

PowerShell:

```powershell
.\test\check-code-quality.ps1
```

Bash:

```bash
./test/check-code-quality.sh
```

## Useful targeted runs

PowerShell:

```powershell
.\test\check-code-quality.ps1 -Instructions -Documentation
.\test\check-code-quality.ps1 -PurgeCSS
```

Bash:

```bash
./test/check-code-quality.sh --instructions --documentation
./test/check-code-quality.sh --purgecss
```
