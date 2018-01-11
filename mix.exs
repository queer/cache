defmodule Cache.Mixfile do
  use Mix.Project

  def project do
    [
      app: :cache,
      version: "0.1.0",
      elixir: "~> 1.5",
      start_permanent: Mix.env == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {Cache.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:mongodb, ">= 0.0.0"},
      {:poolboy, ">= 0.0.0"},
      {:poison, "~> 3.1"},
      {:lace, github: "queer/lace"},
    ]
  end
end
