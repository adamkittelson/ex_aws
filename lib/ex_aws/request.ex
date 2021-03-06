defmodule ExAws.Request do
  require Logger
  @max_attempts 10

  @moduledoc """
  Makes requests to AWS.
  """

  @type http_status :: pos_integer
  @type success_content :: %{body: binary, headers: [{binary, binary}]}
  @type success_t :: {:ok, success_content}
  @type error_t :: {:error, {:http_error, http_status, binary}}
  @type response_t :: success_t | error_t

  def request(http_method, url, data, headers, config, service) do
    body = case data do
      []  -> "{}"
      d when is_binary(d) -> d
      _   -> config[:json_codec].encode!(data)
    end

    request_and_retry(http_method, url, service, config, headers, body, {:attempt, 1})
  end

  def request_and_retry(_method, _url, _service, _config, _headers, _req_body, {:error, reason}), do: {:error, reason}

  def request_and_retry(method, url, service, config, headers, req_body, {:attempt, attempt}) do
    full_headers = ExAws.Auth.headers(method, url, service, config, headers, req_body)
    if config[:debug_requests] do
      Logger.debug("Request URL: #{inspect url}")
      Logger.debug("Request HEADERS: #{inspect full_headers}")
      Logger.debug("Request BODY: #{inspect req_body}")
    end

    case config[:http_client].request(method, url, req_body, full_headers) do
      {:ok, response = %{status_code: status}} when status in 200..299 ->
        {:ok, response}
      {:ok, %{status_code: status} = resp} when status in 400..499 ->
        case client_error(resp, config[:json_codec]) do
          {:retry, reason} ->
            request_and_retry(method, url, service, config, headers, req_body, attempt_again?(attempt, reason))
          {:error, reason} -> {:error, reason}
        end
      {:ok, %{status_code: status, body: body}} when status >= 500 ->
        reason = {:http_error, status, body}
        request_and_retry(method, url, service, config, headers, req_body, attempt_again?(attempt, reason))
      {:error, %{reason: reason}} ->
        Logger.warn("ExAws: HTTP ERROR: #{inspect reason}")
        request_and_retry(method, url, service, config, headers, req_body, attempt_again?(attempt, reason))
    end
  end

  def client_error(%{status_code: status, body: body}, json_codec) do
    case json_codec.decode(body) do
      {:ok, %{"__type" => error_type, "message" => message} = err} ->
        error_type
        |> String.split("#")
        |> case do
          [_, type] -> handle_aws_error(type, message)
          _         -> {:error, {:http_error, status, err}}
        end
      _ -> {:error, {:http_error, status, body}}
    end
  end

  def handle_aws_error("ProvisionedThroughputExceededException" = type, message) do
    {:retry, {type, message}}
  end

  def handle_aws_error("ThrottlingException" = type, message) do
    {:retry, {type, message}}
  end

  def handle_aws_error(type, message) do
    {:error, {type, message}}
  end

  def attempt_again?(attempt, reason) when attempt >= @max_attempts do
    {:error, reason}
  end

  def attempt_again?(attempt, _) do
    attempt |> backoff
    {:attempt, attempt + 1}
  end

  # TODO: make exponential
  # TODO: add jitter
  def backoff(attempt) do
    :timer.sleep(attempt * 1000)
  end
end
