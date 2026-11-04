<#
.SYNOPSIS
  Arranca toda la infraestructura local del stack STAC/PostGIS despues de un
  reinicio de la maquina (PostgreSQL no lo necesita - corre como servicio de
  Windows y arranca solo).

.EXAMPLE
  .\start_services.ps1
#>

# Serves data\Sink Analysis Final\_flood_serve (not the folder itself) so the
# merged "Flood Analysis" root catalog (data\Sink Analysis Final\flood_stac\
# catalog.json, built by services\build_flood_catalog.py) can link to every
# prefecture's own catalog and have their relative asset hrefs resolve from
# this one server root. _flood_serve only contains NTFS directory junctions
# (one per prefecture folder, plus flood_stac itself), so nothing outside
# those is reachable through http-server even though the relative folder
# layout is identical to data\Sink Analysis Final\. The asset URLs stored in
# pgstac (http://localhost:8000/<pref>/...) also resolve against this root.
$dataRoot = "C:\Users\Pedro\Documents\PSS\data\Sink Analysis Final"
$serveDir = Join-Path $dataRoot "_flood_serve"

Write-Host "Verificando PostgreSQL (deberia estar corriendo solo, es un servicio de Windows)..."
$pg = Get-Service -Name "postgresql-18" -ErrorAction SilentlyContinue
if ($pg -and $pg.Status -eq "Running") {
    Write-Host "  OK: postgresql-18 esta Running"
} else {
    Write-Host "  AVISO: postgresql-18 no esta corriendo, intentando iniciarlo..."
    Start-Service -Name "postgresql-18" -ErrorAction SilentlyContinue
}

if (-not (Test-Path (Join-Path $serveDir "flood_stac"))) {
    Write-Host "Generando Sink Analysis Final\_flood_serve (catalogo + junctions por prefectura)..."
    & "C:\Users\Pedro\miniforge3\envs\pdal_env\python.exe" "C:\Users\Pedro\Documents\PSS\services\build_flood_catalog.py" $dataRoot
}

Write-Host "Levantando http-server (solo Sink Analysis Final\_flood_serve, puerto 8000)..."
Start-Process -FilePath "cmd.exe" -ArgumentList "/c", "npx http-server `"$serveDir`" -p 8000 --cors -c-1" -WindowStyle Hidden

Write-Host "Levantando stac-fastapi (API STAC dinamica, puerto 8080)..."
$env:PGUSER = "postgres"
$env:PGPASSWORD = "pss_local_dev"
$env:PGHOST = "localhost"
$env:PGPORT = "5432"
$env:PGDATABASE = "pss_geo"
$env:STAC_FASTAPI_TITLE = "Flood Analysis"
$env:STAC_FASTAPI_DESCRIPTION = "Flood risk analysis (sink depth, roads, buildings) across every processed prefecture"
$env:STAC_FASTAPI_LANDING_ID = "flood-analysis"
Start-Process -FilePath "C:\Users\Pedro\miniforge3\envs\pdal_env\python.exe" `
    -ArgumentList "-m", "uvicorn", "stac_fastapi.pgstac.app:create_app", "--factory", "--host", "127.0.0.1", "--port", "8080" `
    -WindowStyle Hidden

Write-Host "Levantando pg_featureserv (consultas por feature, puerto 58211)..."
$env:DATABASE_URL = "postgresql://postgres:pss_local_dev@localhost:5432/pss_geo"
Start-Process -FilePath "C:\Users\Pedro\Documents\PSS\services\pg_featureserv\pg_featureserv.exe" `
    -ArgumentList "-c", "config\pg_featureserv.toml" `
    -WorkingDirectory "C:\Users\Pedro\Documents\PSS\services\pg_featureserv" `
    -WindowStyle Hidden

Write-Host "Levantando stac-browser (interfaz visual, puerto 5173)..."
Start-Process -FilePath "cmd.exe" -ArgumentList "/c", "npx vite --port 5173" `
    -WorkingDirectory "C:\Users\Pedro\Documents\PSS\notebooks\stac_browser\stac_browser" `
    -WindowStyle Hidden

Write-Host ""
Write-Host "Listo. Espera unos 10 segundos a que todo termine de arrancar, luego abre:"
Write-Host "  http://localhost:5173/           <- catalogo STAC navegable"
Write-Host "  http://127.0.0.1:58211/          <- mapa de features (roads/buildings)"
Write-Host "  http://127.0.0.1:8080/collections <- API STAC cruda (JSON, ya unificada por prefectura)"
Write-Host "  http://localhost:8000/flood_stac/catalog.json <- catalogo estatico 'Flood Analysis' (todas las prefecturas)"
