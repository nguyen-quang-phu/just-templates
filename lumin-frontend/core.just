# Lumin frontend — project basics (build, test, lint, checkout, env)
# Part of the remote template. Imported by the fetched `remote.just`.

# Dependencies
install:
    pnpm install --no-frozen-lockfile
    # git checkout -- pnpm-lock.yaml

# Build / test / lint (nx)
build:
    pnpm run build

test:
    pnpm run test

lint:
    pnpm run lint

# Nx dependency graph
graph:
    pnpm run graph

cloudflared port="3000":
    cloudflared tunnel --url localhost:{{port}}

hubpot-upload:
    cd ./products/static/hubspot/hubspot-canny-integration
    hs project upload --debug


run project target="dev":
    pnpm nx run {{ project }}:{{ target }}
  
lumin-frontend:
    @just run lumin-frontend

no-checkout:
    git sparse-checkout disable

checkout-frontend:
    git sparse-checkout set apps/frontend .agents .cursor .github .husky products/static tools/dotenvx-cli packages/i18n packages/fe-environment packages/platform products/form-templates products/agreement-gen packages/datadog-logger packages/lumin-kit packages/redis-client packages/shell-ui scripts packages/lumin-design-system products/pdf products/sign packages/overlay-rules packages/multilingual

checkout-backend-frontend:
    just checkout-frontend
    git sparse-checkout add packages/lumin-proto tools/dev-cli apps/core/lumin-web-backend-2.0

decrypt file:
    dotenvx decrypt -f {{file}} -fk .env.keys --stdout

test_e2e url args="":
    cd apps/lumin-e2e/packages/lumin-playwright/lumin-growth && BASE_URL={{url}} PLAYWRIGHT_ENV=dev DOMAIN=.preview.luminpdf.com OAUTH2_PROXY="H7o1kmvaeN9Ng7PPvh7R84hGiahrPofx0E_wi2irzK1_ZKsFRYopJS5RpX3j5pvcO8BZTPgYbl8Pd7Ty-hIF2o7dHspvipMPvcBSJK-RGm5mEtWj-Te3cjOuw5LdyVANhdkgDN Z_eo6xQ10dQJpKZ5TVStuNpNGUdk7bK-NyuUJNWsGPahjF8dt-7bujsoG0tW39xvEZJCVWBH0U1htXOwKC-v515imj|1779764993|3nvfvD9EN_FIDih641pnP1WMXAcW56QxRas0cqM3Pbg=" LUMIN_CI_TOKEN="" pnpm run pw tests/specs/static/static-redirect-multilangues-pages.spec --project=chromium {{args}}


env project key="":
	#!/usr/bin/env bash
	set -euo pipefail
	if [ -z "{{key}}" ]; then
		npx lumin-dotenvx decrypt -p "{{project}}"
	else
		npx lumin-dotenvx decrypt -p "{{project}}" | grep -i "{{key}}"
	fi
