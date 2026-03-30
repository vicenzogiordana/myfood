# MealPlannerApi

To start your Phoenix server:

* Create local direnv file: `cp .envrc.local.example .envrc.local` and set required values
* Allow direnv to load variables: `direnv allow`
* Run `mix setup` to install and setup dependencies
* Start Phoenix endpoint with `mix phx.server` or inside IEx with `iex -S mix phx.server`

Now you can visit [`localhost:4000`](http://localhost:4000) from your browser.

Ready to run in production? Please [check our deployment guides](https://hexdocs.pm/phoenix/deployment.html).

## Learn more

* Official website: https://www.phoenixframework.org/
* Guides: https://hexdocs.pm/phoenix/overview.html
* Docs: https://hexdocs.pm/phoenix
* Forum: https://elixirforum.com/c/phoenix-forum
* Source: https://github.com/phoenixframework/phoenix

## Project Notes

* Known issues: `docs/known-issues.md`

## Auth Policy

Current supported sign-in methods:

* `POST /api/auth/password`
* `POST /api/auth/social`

Removed endpoint:

* `POST /api/auth/token` is no longer available.

Reason:

* The app login surface is intentionally limited to email/password and social providers (Google, Apple, Facebook).

## Social Auth Setup (Google / Apple / Facebook)

This API supports social sign-in via `POST /api/auth/social`.
It also supports email/password auth via `POST /api/auth/password`.

Required environment variables (set them in `.envrc.local`):

```env
# Google: one or more OAuth client IDs separated by commas
GOOGLE_OAUTH_CLIENT_IDS=your_google_ios_client_id,your_google_web_client_id

# Apple: one or more Services IDs / client IDs separated by commas
APPLE_OAUTH_CLIENT_IDS=com.myfood.app,com.myfood.web

# Facebook app credentials
FACEBOOK_APP_ID=123456789012345
FACEBOOK_APP_SECRET=your_facebook_app_secret

# Optional overrides (normally keep defaults)
GOOGLE_TOKENINFO_URL=https://oauth2.googleapis.com/tokeninfo
APPLE_JWKS_URL=https://appleid.apple.com/auth/keys
FACEBOOK_GRAPH_URL=https://graph.facebook.com
```

Endpoint contract:

* Path: `POST /api/auth/social`
* Body:

```json
{
	"provider": "google",
	"id_token": "<provider_token>",
	"subscription_tier": "free"
}
```

Provider token type for `id_token`:

* `google`: Google ID token (JWT)
* `apple`: Apple identity token (JWT)
* `facebook`: Facebook user access token

Example calls:

```bash
curl -X POST http://localhost:4000/api/auth/social \
	-H 'content-type: application/json' \
	-d '{"provider":"google","id_token":"GOOGLE_ID_TOKEN"}'

curl -X POST http://localhost:4000/api/auth/social \
	-H 'content-type: application/json' \
	-d '{"provider":"apple","id_token":"APPLE_ID_TOKEN"}'

curl -X POST http://localhost:4000/api/auth/social \
	-H 'content-type: application/json' \
	-d '{"provider":"facebook","id_token":"FACEBOOK_USER_ACCESS_TOKEN"}'
```

On success, both auth endpoints return this payload and include:

* `access_token`
* `token_type`
* `user`
* `account`
* `subscription`
* `websocket` connection params

Email/password examples:

```bash
curl -X POST http://localhost:4000/api/auth/password \
	-H 'content-type: application/json' \
	-d '{"mode":"register","email":"user@example.com","password":"supersecret123","name":"User"}'

curl -X POST http://localhost:4000/api/auth/password \
	-H 'content-type: application/json' \
	-d '{"mode":"login","email":"user@example.com","password":"supersecret123"}'
```
