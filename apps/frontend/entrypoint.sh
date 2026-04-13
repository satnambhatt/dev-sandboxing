#!/bin/sh
set -eu
: "${BACKEND_URL:=http://localhost:3000}"
envsubst '${BACKEND_URL}' < /usr/share/nginx/html/config.js.template > /usr/share/nginx/html/config.js
exec nginx -g 'daemon off;'
