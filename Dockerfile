# Build stage
FROM dart:stable AS build
WORKDIR /app

COPY pubspec.yaml ./
COPY pubspec.lock ./
RUN dart pub get

COPY . .
RUN dart pub get --offline

# Runtime stage
FROM dart:stable
WORKDIR /app

# sqlite3 FFI needs the native library present at runtime.
RUN apt-get update \
    && apt-get install -y --no-install-recommends libsqlite3-0 \
    && rm -rf /var/lib/apt/lists/*

COPY --from=build /app ./

ENV SDSC_DB=/data/sdsc.db
VOLUME /data

CMD ["dart", "run", "bin/main.dart"]
