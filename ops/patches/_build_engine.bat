@echo off
set PATH=C:\burjex\dockerhelper;%PATH%
cd /d C:\burjex
docker compose -f deploy\docker-compose.ip.yml --env-file deploy\.env.prod.ip up -d --build btrader-engine
echo BUILD_EXITCODE=%ERRORLEVEL%
