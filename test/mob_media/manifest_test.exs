defmodule MobMedia.ManifestTest do
  use ExUnit.Case, async: true

  alias MobDev.Plugin.{Manifest, Validator}

  @plugin_dir Path.expand("../..", __DIR__)

  setup do
    {:ok, manifest} = Manifest.load(@plugin_dir)
    %{manifest: manifest}
  end

  test "passes the pre-publish validator", %{manifest: m} do
    assert {:ok, ^m} = Manifest.validate(m)
    assert %{errors: []} = Validator.validate_plugin(m, @plugin_dir)
  end
end
