defmodule Yoke.Test.ReviewFixture do
  @moduledoc false
  import ExUnit.Assertions

  def repository(directory) do
    File.mkdir_p!(directory)
    git(directory, ["init", "-q", "-b", "main"])
    git(directory, ["config", "user.email", "review@example.invalid"])
    git(directory, ["config", "user.name", "Review Test"])
    File.write!(Path.join(directory, "sample.ex"), "old_value\n")
    commit(directory, "initial")
    base = git(directory, ["rev-parse", "HEAD"])
    git(directory, ["checkout", "-q", "-b", "feature"])
    File.write!(Path.join(directory, "sample.ex"), "reviewed_value\n")
    commit(directory, "change sample")
    %{repo: directory, base: base, head: git(directory, ["rev-parse", "HEAD"])}
  end

  def commit(repo, message) do
    git(repo, ["add", "."])
    git(repo, ["commit", "-q", "-m", message])
  end

  def git(repo, args) do
    {out, status} = System.cmd("git", ["--no-pager" | args], cd: repo, stderr_to_stdout: true)
    assert status == 0, out
    String.trim(out)
  end

  def provider(owner, responses) do
    {:ok, listen} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, {_, port}} = :inet.sockname(listen)
    pid = spawn_link(fn -> serve(listen, owner, responses) end)
    {listen, pid, "http://127.0.0.1:#{port}/v1/chat/completions"}
  end

  def choice(content, finish \\ "stop") do
    %{
      "choices" => [
        %{"message" => %{"role" => "assistant", "content" => content}, "finish_reason" => finish}
      ],
      "usage" => %{"prompt_tokens" => 10, "completion_tokens" => 5}
    }
  end

  def tool_choice(name, args, id \\ "tool-1") do
    %{
      "choices" => [
        %{
          "message" => %{
            "role" => "assistant",
            "content" => "",
            "tool_calls" => [
              %{
                "id" => id,
                "type" => "function",
                "function" => %{
                  "name" => name,
                  "arguments" => Yoke.Json.encode!(args)
                }
              }
            ]
          },
          "finish_reason" => "tool_calls"
        }
      ]
    }
  end

  defp serve(listen, owner, [response | responses]) do
    case :gen_tcp.accept(listen) do
      {:ok, socket} ->
        request = read_request(socket, "")
        send(owner, {:review_request, Yoke.Json.decode!(request)})
        response = if is_function(response, 0), do: response.(), else: response
        body = Yoke.Json.encode!(response)

        :ok =
          :gen_tcp.send(socket, [
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n",
            "Content-Length: #{byte_size(body)}\r\nConnection: close\r\n\r\n",
            body
          ])

        :gen_tcp.close(socket)
        serve(listen, owner, responses)

      {:error, :closed} ->
        :ok
    end
  end

  defp serve(listen, _owner, []), do: :gen_tcp.close(listen)

  defp read_request(socket, data) do
    case :binary.split(data, "\r\n\r\n") do
      [headers, body] ->
        [_, length] = Regex.run(~r/content-length:\s*(\d+)/i, headers)
        remaining = String.to_integer(length) - byte_size(body)

        if remaining > 0 do
          {:ok, rest} = :gen_tcp.recv(socket, remaining, 5_000)
          body <> rest
        else
          body
        end

      _ ->
        {:ok, chunk} = :gen_tcp.recv(socket, 0, 5_000)
        read_request(socket, data <> chunk)
    end
  end
end
