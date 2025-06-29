repo_path := "~/Code/keynold/copier-templates"
project := `basename "$(dirname "$PWD")"`
type := "react-component"
react_component_template_path := repo_path / project / type

alias s := server

server:
  npx pnpm@10.9.0 start

sm:
  npx pnpm@10.9.0 sm

sm-login:
  npx prismic-cli@latest login

install:
  npx pnpm@10.9.0 install

[positional-arguments]
add name:
  npx pnpm@10.9.0 add $1

up:
  devenv up

build:
  npx pnpm@10.9.0 build

build-dev:
  npx pnpm@10.9.0 build:dev

start-local:
  cp .env.local .env.development
  cp sm.json.local sm.json
  @just s

start-dev:
  cp .env.dev .env.development
  cp sm.json.dev sm.json
  @just s

build-staging:
  cp .env.staging .env.development
  @just build-dev

build-production:
  cp .env.production .env.development
  @just build-dev

add-stylelint:
  npx pnpm add stylelint@latest stylelint-config-standard@latest stylelint-order@latest postcss-scss@latest stylelint-config-standard-scss@latest stylelint-config-standard@latest stylelint-scss@latest stylelint-order@latest stylelint-config-idiomatic-order@latest


debug:
  node --inspect node_modules/.bin/gatsby develop

[positional-arguments]
generate-component path:
  copier copy {{react_component_template_path}} $1
