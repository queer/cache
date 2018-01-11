defmodule Cache.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application
  require Logger

  def start(_type, _args) do
    # List all child processes to be supervised
    Logger.info "Starting cache service..."
    children = [
      # Starts a worker by calling: Cache.Worker.start_link(arg)
      # {Cache.Worker, arg},
      {Mongo, [
          name: :mongo, 
          database: "discord-cache", # System.get_env("CACHE_DATABASE"), 
          pool: DBConnection.Poolboy, 
          # TODO: Make these env vars
          hostname: "localhost", 
          port: "27017"
        ]},
      {Lace.Redis, %{
          redis_ip: System.get_env("REDIS_IP"), redis_port: 6379, pool_size: 100, redis_pass: System.get_env("REDIS_PASS")
        }},
    ]

    # Start the processing 
    Task.async fn -> Cache.process() end

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Cache.Supervisor]
    Logger.info "Done!"
    Supervisor.start_link(children, opts)
  end
end
