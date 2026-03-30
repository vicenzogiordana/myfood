defmodule MealPlannerApi.Auth.SocialVerifier do
  @moduledoc """
  Verifies third-party social identity tokens and returns normalized identity data.
  """

  @type provider :: String.t()

  @callback verify(provider(), String.t(), keyword()) ::
              {:ok,
               %{
                 provider: String.t(),
                 provider_user_id: String.t(),
                 email: String.t() | nil,
                 name: String.t() | nil
               }}
              | {:error, atom()}

  @behaviour __MODULE__

  @impl true
  def verify("google", id_token, opts) when is_binary(id_token) and id_token != "" do
    tokeninfo_url = Keyword.get(opts, :google_tokeninfo_url, default_google_tokeninfo_url())

    with {:ok, tokeninfo} <-
           request_json(tokeninfo_url <> "?id_token=" <> URI.encode_www_form(id_token)),
         {:ok, sub} <- required_string(tokeninfo, "sub"),
         :ok <-
           validate_audience(Map.get(tokeninfo, "aud"), Keyword.get(opts, :google_client_ids, [])),
         :ok <- validate_google_email_verified(tokeninfo) do
      {:ok,
       %{
         provider: "google",
         provider_user_id: sub,
         email: normalize_optional_string(Map.get(tokeninfo, "email")),
         name: name_from_id_token(id_token)
       }}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_social_token}
    end
  end

  def verify("apple", id_token, opts) when is_binary(id_token) and id_token != "" do
    apple_jwks_url = Keyword.get(opts, :apple_jwks_url, default_apple_jwks_url())

    with {:ok, header} <- decode_jwt_header(id_token),
         {:ok, kid} <- required_string(header, "kid"),
         {:ok, alg} <- required_string(header, "alg"),
         {:ok, jwk} <- fetch_apple_jwk(apple_jwks_url, kid),
         {:ok, claims} <- verify_jwt_claims(id_token, jwk, alg),
         :ok <- validate_apple_claims(claims, Keyword.get(opts, :apple_client_ids, [])),
         {:ok, sub} <- required_string(claims, "sub") do
      {:ok,
       %{
         provider: "apple",
         provider_user_id: sub,
         email: normalize_optional_string(Map.get(claims, "email")),
         name: nil
       }}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_social_token}
    end
  end

  def verify("facebook", user_access_token, opts)
      when is_binary(user_access_token) and user_access_token != "" do
    graph_url = Keyword.get(opts, :facebook_graph_url, default_facebook_graph_url())
    app_id = Keyword.get(opts, :facebook_app_id)
    app_secret = Keyword.get(opts, :facebook_app_secret)

    with :ok <- validate_facebook_config(app_id, app_secret),
         {:ok, debug_data} <-
           fetch_facebook_debug_token(graph_url, user_access_token, app_id, app_secret),
         :ok <- validate_facebook_debug_token(debug_data, app_id),
         {:ok, profile} <- fetch_facebook_profile(graph_url, user_access_token),
         {:ok, user_id} <- required_string(debug_data, "user_id"),
         {:ok, profile_id} <- required_string(profile, "id"),
         true <- user_id == profile_id do
      {:ok,
       %{
         provider: "facebook",
         provider_user_id: user_id,
         email: normalize_optional_string(Map.get(profile, "email")),
         name: normalize_optional_string(Map.get(profile, "name"))
       }}
    else
      false -> {:error, :invalid_social_token}
      {:error, _} = error -> error
      _ -> {:error, :invalid_social_token}
    end
  end

  def verify(_provider, _id_token, _opts), do: {:error, :unsupported_provider}

  defp validate_google_email_verified(%{"email" => _email, "email_verified" => "true"}), do: :ok
  defp validate_google_email_verified(%{"email" => _email, "email_verified" => true}), do: :ok
  defp validate_google_email_verified(%{"email" => _email}), do: {:error, :email_not_verified}
  defp validate_google_email_verified(_), do: :ok

  defp validate_apple_claims(claims, allowed_audiences) do
    with :ok <- validate_required_issuer(claims),
         :ok <- validate_expiration(claims),
         :ok <- validate_audience(Map.get(claims, "aud"), allowed_audiences) do
      :ok
    end
  end

  defp validate_required_issuer(%{"iss" => "https://appleid.apple.com"}), do: :ok
  defp validate_required_issuer(_), do: {:error, :invalid_issuer}

  defp validate_expiration(%{"exp" => exp}) when is_integer(exp) do
    if exp > System.os_time(:second), do: :ok, else: {:error, :token_expired}
  end

  defp validate_expiration(%{"exp" => exp}) when is_binary(exp) do
    case Integer.parse(exp) do
      {int, _} -> validate_expiration(%{"exp" => int})
      _ -> {:error, :invalid_social_token}
    end
  end

  defp validate_expiration(_), do: {:error, :invalid_social_token}

  defp validate_audience(_audience, []), do: :ok

  defp validate_audience(audience, allowed_audiences) when is_binary(audience) do
    if audience in allowed_audiences, do: :ok, else: {:error, :invalid_audience}
  end

  defp validate_audience(_audience, _allowed_audiences), do: {:error, :invalid_audience}

  defp validate_facebook_config(app_id, app_secret)
       when is_binary(app_id) and app_id != "" and is_binary(app_secret) and app_secret != "",
       do: :ok

  defp validate_facebook_config(_, _), do: {:error, :facebook_not_configured}

  defp validate_facebook_debug_token(debug_data, app_id) when is_map(debug_data) do
    with true <- facebook_valid?(Map.get(debug_data, "is_valid")),
         :ok <- validate_facebook_app_id(debug_data, app_id),
         :ok <- validate_facebook_expiry(debug_data) do
      :ok
    else
      false -> {:error, :invalid_social_token}
      {:error, _} = error -> error
      _ -> {:error, :invalid_social_token}
    end
  end

  defp validate_facebook_debug_token(_debug_data, _app_id), do: {:error, :invalid_social_token}

  defp validate_facebook_app_id(debug_data, app_id) do
    expected = normalize_optional_string(app_id)
    received = normalize_optional_string(Map.get(debug_data, "app_id"))

    if expected == received, do: :ok, else: {:error, :invalid_audience}
  end

  defp validate_facebook_expiry(debug_data) do
    case Map.get(debug_data, "expires_at") do
      nil ->
        :ok

      0 ->
        :ok

      exp when is_integer(exp) ->
        if exp > System.os_time(:second), do: :ok, else: {:error, :token_expired}

      exp when is_binary(exp) ->
        case Integer.parse(exp) do
          {int, _} -> validate_facebook_expiry(%{"expires_at" => int})
          _ -> {:error, :invalid_social_token}
        end

      _ ->
        {:error, :invalid_social_token}
    end
  end

  defp facebook_valid?(true), do: true
  defp facebook_valid?("true"), do: true
  defp facebook_valid?(_), do: false

  defp fetch_facebook_debug_token(graph_url, user_access_token, app_id, app_secret) do
    app_token = app_id <> "|" <> app_secret

    url =
      graph_url <>
        "/debug_token?" <>
        URI.encode_query(%{
          "input_token" => user_access_token,
          "access_token" => app_token
        })

    with {:ok, %{"data" => data}} <- request_json(url),
         true <- is_map(data) do
      {:ok, data}
    else
      false -> {:error, :invalid_social_token}
      {:error, _} = error -> error
      _ -> {:error, :invalid_social_token}
    end
  end

  defp fetch_facebook_profile(graph_url, user_access_token) do
    url =
      graph_url <>
        "/me?" <>
        URI.encode_query(%{
          "fields" => "id,name,email",
          "access_token" => user_access_token
        })

    request_json(url)
  end

  defp decode_jwt_header(id_token) do
    with [header_b64 | _] <- String.split(id_token, "."),
         {:ok, decoded} <- Base.url_decode64(header_b64, padding: false),
         {:ok, header} <- Jason.decode(decoded) do
      {:ok, header}
    else
      _ -> {:error, :invalid_social_token}
    end
  end

  defp decode_jwt_claims(id_token) do
    with [_header, payload, _signature] <- String.split(id_token, "."),
         {:ok, decoded} <- Base.url_decode64(payload, padding: false),
         {:ok, claims} <- Jason.decode(decoded) do
      {:ok, claims}
    else
      _ -> {:error, :invalid_social_token}
    end
  end

  defp verify_jwt_claims(id_token, jwk, alg) do
    case JOSE.JWT.verify_strict(jwk, [alg], id_token) do
      {true, %JOSE.JWT{fields: claims}, _jws} -> {:ok, claims}
      _ -> {:error, :invalid_social_token}
    end
  end

  defp fetch_apple_jwk(apple_jwks_url, kid) do
    with {:ok, %{"keys" => keys}} <- request_json(apple_jwks_url),
         key when is_map(key) <- Enum.find(keys, &match?(%{"kid" => ^kid}, &1)) do
      {:ok, JOSE.JWK.from_map(key)}
    else
      nil -> {:error, :invalid_social_token}
      {:error, _} = error -> error
      _ -> {:error, :invalid_social_token}
    end
  end

  defp request_json(url) when is_binary(url) do
    request = {String.to_charlist(url), []}
    options = [timeout: 10_000, connect_timeout: 5_000]

    case :httpc.request(:get, request, options, body_format: :binary) do
      {:ok, {{_version, status, _reason_phrase}, _headers, body}} when status in 200..299 ->
        Jason.decode(body)

      {:ok, {{_version, _status, _reason_phrase}, _headers, _body}} ->
        {:error, :social_provider_unavailable}

      {:error, _reason} ->
        {:error, :social_provider_unavailable}
    end
  end

  defp required_string(map, key) when is_map(map) and is_binary(key) do
    case Map.get(map, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, :invalid_social_token}
    end
  end

  defp name_from_id_token(id_token) do
    case decode_jwt_claims(id_token) do
      {:ok, claims} ->
        normalize_optional_string(Map.get(claims, "name")) ||
          normalize_optional_string(Map.get(claims, "given_name"))

      _ ->
        nil
    end
  end

  defp normalize_optional_string(value) when is_binary(value) and value != "", do: value
  defp normalize_optional_string(_), do: nil

  defp default_google_tokeninfo_url,
    do:
      Application.get_env(
        :meal_planner_api,
        :google_tokeninfo_url,
        "https://oauth2.googleapis.com/tokeninfo"
      )

  defp default_apple_jwks_url,
    do:
      Application.get_env(
        :meal_planner_api,
        :apple_jwks_url,
        "https://appleid.apple.com/auth/keys"
      )

  defp default_facebook_graph_url,
    do:
      Application.get_env(
        :meal_planner_api,
        :facebook_graph_url,
        "https://graph.facebook.com"
      )
end
