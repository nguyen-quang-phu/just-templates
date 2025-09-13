repo_path := "~/Code/keynold/copier-templates"
project := `basename "$(dirname "$PWD")"`
type := "react-component"
react_component_template_path := repo_path / project / type
sm_dev :="https://lumindev.cdn.prismic.io/api/v2"
sm_local := "https://local-lumin.cdn.prismic.io/api/v2"

_pnpm +args:
  npx pnpm@10.9.0 {{args}}

alias s := server

_debug env:
  doppler run --config=dev_{{env}} -- node node_modules/gatsby/cli.js develop --inspect-brk

debug-local:
  just _debug local

debug-dev:
  just _debug dev

debug-stag:
  just _debug staging

debug-prod:
  just _debug production

server:
  just _pnpm start

serve:
  just _pnpm serve

sm:
  just _pnpm sm

sm-login:
  npx prismic-cli@latest login

install:
  just _pnpm install


[positional-arguments]
add name:
  just _pnpm add $1

up:
  devenv up

update-env-gastby-config:
  #!/usr/bin/env node
  const fs = require('fs');

  const filePath = './gatsby-config.js';
  const content = fs.readFileSync(filePath, 'utf8');

  const updatedContent = content.replace(
    "path: `.env.${process.env.NODE_ENV}`",
    'path: `.env.development`'
  );

  fs.writeFileSync(filePath, updatedContent);

update-sm-config newEndpoint:
  #!/usr/bin/env node
  const fs = require('fs');

  const filePath = './sm.json';

  const content = fs.readFileSync(filePath, 'utf8');
  const json = JSON.parse(content);

  const oldEndpoint = json.apiEndpoint;

  json.apiEndpoint = '{{newEndpoint}}';

  fs.writeFileSync(filePath, JSON.stringify(json, null, 2));

  console.log(`Updated apiEndpoint from ${oldEndpoint} to ${json.apiEndpoint}`);

update-sm-local:
  just update-sm-config {{sm_local}}

update-sm-dev:
  just update-sm-config {{sm_dev}}

update-sm-staging:
  # just update-sm-config {{sm_dev}} {{sm_dev}}
  #
update-sm-production:
  # just update-sm-config {{sm_dev}} {{sm_dev}}

_build env:
  # @just _set-env {{env}}
  doppler run --config=dev_{{env}} -- just _pnpm build:dev

_set-env env:
  # cp ../.env.{{env}} .env.development
  @just update-sm-{{env}}
  @just update-env-gastby-config

_start env:
  @just update-sm-{{env}}
  doppler run --config=dev_{{env}} -- just s

start-local:
  just _start local

start-dev:
  just _start dev

start-stag:
  just _start staging

start-prod:
  just _start production

build-local:
  just _build local

build-dev:
  just _build dev

build-staging:
  just _build staging

build-prod:
  just _build production

add-stylelint:
  npx pnpm add stylelint@latest stylelint-config-standard@latest stylelint-order@latest postcss-scss@latest stylelint-config-standard-scss@latest stylelint-config-standard@latest stylelint-scss@latest stylelint-config-css-modules

cloudflared:
  cloudflared tunnel --url localhost:8000

link-commit-msg:
 ln -s ~/.config/git/hooks/commit-msg .husky/commit-msg

[positional-arguments]
generate-component path:
  copier copy {{react_component_template_path}} $1
