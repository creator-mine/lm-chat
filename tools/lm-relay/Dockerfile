FROM golang:1.24-alpine AS build

WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/relay ./cmd/relay

FROM scratch

COPY --from=build /out/relay /relay
USER 65532:65532
EXPOSE 8787
ENTRYPOINT ["/relay"]
