defmodule MobMedia.MixProject do
  use Mix.Project

  @source_url "https://github.com/GenericJam/mob_media"
  @version "0.1.0"

  def project do
    [
      app: :mob_media,
      version: @version,
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      aliases: aliases(),
      description:
        "Media helpers for Mob apps: info, audio track to PCM (for speech-to-text) and " <>
          "video frames as JPEG, through the platform decoders (Android MediaCodec, iOS AVFoundation).",
      package: package(),
      docs: [
        main: "readme",
        extras: ["README.md", "CHANGELOG.md"]
      ],
      source_url: @source_url
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  def application do
    [extra_applications: [:logger]]
  end

  defp aliases do
    # `mix setup` after cloning: fetches deps and activates the shared git
    # hooks (.githooks): format / Credo --strict / compile on every push and
    # the full suite when mix.exs changes — the same gate CI enforces.
    [setup: ["deps.get", "cmd git config core.hooksPath .githooks"]]
  end

  defp deps do
    [
      {:mob, "~> 0.9"},
      # Test-only: the manifest tests run mob_dev's real pre-publish validator.
      {:mob_dev, "~> 0.7", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ex_slop, "~> 0.4.2", only: [:dev, :test], runtime: false},
      {:jump_credo_checks, "~> 0.1.0", only: [:dev, :test], runtime: false}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      # The native sources and the manifest ship in the package: the host's
      # native build compiles them from deps/mob_media/priv.
      files: ~w(lib src priv mix.exs README* CHANGELOG* LICENSE*)
    ]
  end
end
