
SELECT 'CREATE ROLE glitchtip LOGIN PASSWORD ''glitchtip'' NOSUPERUSER NOCREATEDB NOCREATEROLE'
WHERE 1 = 1
  AND NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'glitchtip')
\gexec

SELECT 'CREATE DATABASE glitchtip OWNER glitchtip'
WHERE 1 = 1
  AND NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'glitchtip')
\gexec