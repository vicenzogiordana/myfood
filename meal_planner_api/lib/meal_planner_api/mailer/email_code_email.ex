defmodule MealPlannerApi.Mailer.EmailCodeEmail do
  @moduledoc """
  Verification-code delivery for the email-code authentication flow.

  Phase 1 — Persistence and Code Request (issue #31). One email per
  `request_code/2` call, carrying only the six-digit plaintext code
  (never the hash, never the user record). The plaintext is rendered
  in both a plain text body and an HTML body so the same template
  works in plain and rich mail clients.

  Body design:

    * Subject: "Your Myfood sign-in code"
    * Text body: a one-line "Your code is XXXXXX" with a short
      expiry note. Plaintext-only retrieval is rare but supported.
    * HTML body: the same value wrapped in a `<strong>` tag so the
      `~r/\b\d{6}\b/` regex in the tests reliably matches across
      both bodies without false positives from any other digits
      (such as the year).

  No plaintext code is logged or echoed anywhere outside the email
  itself (spec: "The system MUST NOT ... log code values").
  """
  import Bamboo.Email

  @from {"Myfood", "no-reply@myfood.app"}
  @subject "Your Myfood sign-in code"

  @spec build(String.t(), String.t()) :: Bamboo.Email.t()
  def build(email_address, code)
      when is_binary(email_address) and is_binary(code) and byte_size(code) == 6 do
    new_email(
      from: @from,
      to: {display_name_for(email_address), email_address},
      subject: @subject,
      text_body: text_body(code),
      html_body: html_body(code)
    )
  end

  defp text_body(code) do
    "Your Myfood sign-in code is #{code}. " <>
      "It expires in 10 minutes and can only be used once."
  end

  defp html_body(code) do
    """
    <p>Your Myfood sign-in code is <strong>#{code}</strong>.</p>
    <p>It expires in 10 minutes and can only be used once.</p>
    """
  end

  # The Plaintext User is unknown to the service at the moment we
  # render this email; the only header we have is the address itself.
  # Use the local-part as a sensible default display name when no
  # User row has yet been loaded.
  defp display_name_for(email) when is_binary(email) do
    email
    |> String.split("@", parts: 2)
    |> hd()
  end
end
