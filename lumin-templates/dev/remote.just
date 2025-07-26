_pnpm +args:
  npx pnpm@10.9.0 {{args}}

alias s := server

server:
  just _pnpm dev

install:
  just _pnpm install

[positional-arguments]
add name:
  _pnpm add $1

up:
  devenv up

_build:
  just _pnpm build
  just _pnpm start

_start env:
  cp ../.env.{{env}} .env
  just _pnpm server

start-local:
  just _start local
