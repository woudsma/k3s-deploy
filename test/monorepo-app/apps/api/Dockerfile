FROM nginx:alpine
# A build arg proves BUILD_ARGS from .deploy/<app>.conf reaches Kaniko.
ARG APP_LABEL=unset
RUN printf 'MONOREPO-API %s\n' "$APP_LABEL" > /usr/share/nginx/html/index.html
