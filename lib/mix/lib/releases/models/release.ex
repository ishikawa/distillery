defmodule Mix.Releases.Release do
  @moduledoc """
  Represents metadata about a release
  """
  alias Mix.Releases.{App, Profile, Overlays, Config, Utils, Environment, Logger}

  defstruct name: nil,
            version: "0.1.0",
            applications: [
              # required for elixir apps
              :elixir,
              # included so the elixir shell works
              :iex,
              # required for upgrades
              :sasl,
              # required for some command tooling
              :runtime_tools,
              # required for config providers
              {:mix, :load},
              :distillery
              # can also use `app_name: type`, as in `some_dep: load`,
              # to only load the application, not start it
            ],
            output_dir: nil,
            is_upgrade: false,
            upgrade_from: :latest,
            resolved_overlays: [],
            profile: %Profile{
              code_paths: [],
              erl_opts: "",
              run_erl_env: "",
              exec_opts: [transient: false],
              dev_mode: false,
              include_erts: true,
              include_src: false,
              include_system_libs: true,
              included_configs: [],
              config_providers: [],
              appup_transforms: [],
              strip_debug_info: false,
              plugins: [],
              overlay_vars: [],
              overlays: [],
              commands: [],
              overrides: []
            },
            env: nil

  @type t :: %__MODULE__{
          name: atom,
          version: String.t,
          applications: list(atom | {atom, App.start_type} | App.t),
          output_dir: String.t,
          is_upgrade: boolean,
          upgrade_from: nil | String.t | :latest,
          resolved_overlays: [Overlays.overlay],
          profile: Profile.t,
          env: atom
        }

  @type app_resource ::
          {atom, app_version :: charlist}
          | {atom, app_version :: charlist, App.start_type}
  @type resource ::
          {:release, {name :: charlist, version :: charlist}, {:erts, erts_version :: charlist},
           [app_resource]}

  @doc """
  Creates a new Release with the given name, version, and applications.
  """
  @spec new(atom, String.t) :: t
  @spec new(atom, String.t, [atom]) :: t
  def new(name, version, apps \\ []) do
    build_path = Mix.Project.build_path()
    output_dir = Path.relative_to_cwd(Path.join([build_path, "rel", "#{name}"]))
    definition = %__MODULE__{name: name, version: version}

    definition
    |> Map.put(:applications, definition.applications ++ apps)
    |> Map.put(:output_dir, output_dir)
    |> Map.put(:profile, %{definition.profile | output_dir: output_dir})
  end

  @doc """
  Load a fully configured Release object given a release name and environment name.
  """
  @spec get(atom) :: {:ok, t} | {:error, term}
  @spec get(atom, atom) :: {:ok, t} | {:error, term}
  @spec get(atom, atom, Keyword.t) :: {:ok, t} | {:error, term}
  def get(name, env \\ :default, opts \\ [])

  def get(name, env, opts) when is_atom(name) and is_atom(env) do
    # load release configuration
    default_opts = [
      selected_environment: env,
      selected_release: name,
      is_upgrade: Keyword.get(opts, :is_upgrade, false),
      upgrade_from: Keyword.get(opts, :upgrade_from, false)
    ]

    case Config.get(Keyword.merge(default_opts, opts)) do
      {:error, _} = err ->
        err

      {:ok, config} ->
        with {:ok, env} <- select_environment(config),
             {:ok, rel} <- select_release(config),
             rel <- apply_environment(rel, env),
             do: apply_configuration(rel, config, false)
    end
  end

  @doc """
  Converts a Release struct to a release resource structure.

  The format of release resources is documented [in the Erlang manual](http://erlang.org/doc/design_principles/release_structure.html#res_file)
  """
  @spec to_resource(t) :: resource
  def to_resource(
        %__MODULE__{applications: apps, profile: %Profile{erts_version: erts}} = release
      ) do
    rel_name = Atom.to_charlist(release.name)
    rel_version = String.to_charlist(release.version)
    erts = String.to_charlist(erts)

    {
      :release,
      {rel_name, rel_version},
      {:erts, erts},
      for %App{name: name, vsn: vsn, start_type: start_type} <- apps do
        if is_nil(start_type) do
          {name, '#{vsn}'}
        else
          {name, '#{vsn}', start_type}
        end
      end
    }
  end

  @doc """
  Get the path to which release binaries will be output
  """
  @spec bin_path(t) :: String.t
  def bin_path(%__MODULE__{profile: %Profile{output_dir: output_dir}}) do
    Path.join([output_dir, "bin"])
  end

  @doc """
  Get the path to which versioned release data will be output
  """
  @spec version_path(t) :: String.t
  def version_path(%__MODULE__{profile: %Profile{output_dir: output_dir}} = r) do
    Path.join([output_dir, "releases", "#{r.version}"])
  end

  @doc """
  Get the path to which compiled applications will be output
  """
  @spec lib_path(t) :: String.t
  def lib_path(%__MODULE__{profile: %Profile{output_dir: output_dir}}) do
    Path.join([output_dir, "lib"])
  end

  @doc """
  Get the path to which the release tarball will be output
  """
  @spec archive_path(t) :: String.t
  def archive_path(%__MODULE__{profile: p} = r) do
    cond do
      p.executable ->
        Path.join([bin_path(r), "#{r.name}.run"])

      :else ->
        Path.join([version_path(r), "#{r.name}.tar.gz"])
    end
  end

  # Returns the environment that the provided Config has selected
  @doc false
  @spec select_environment(Config.t) :: {:ok, Environment.t} | {:error, :missing_environment}
  def select_environment(%Config{selected_environment: :default, default_environment: :default} = c) do
    case Map.get(c.environments, :default) do
      nil ->
        {:error, :missing_environment}
      env ->
        {:ok, env}
    end
  end

  def select_environment(%Config{selected_environment: :default, default_environment: name} = c),
    do: select_environment(%Config{c | selected_environment: name})

  def select_environment(%{selected_environment: name} = c) do
    case Map.get(c.environments, name) do
      nil ->
        {:error, :missing_environment}
      env ->
        {:ok, env}
    end
  end

  # Returns the release that the provided Config has selected
  @doc false
  @spec select_release(Config.t) :: {:ok, t} | {:error, :missing_release}
  def select_release(%Config{selected_release: :default, default_release: :default} = c),
    do: {:ok, List.first(Map.values(c.releases))}

  def select_release(%Config{selected_release: :default, default_release: name} = c),
    do: select_release(%Config{c | selected_release: name})

  def select_release(%Config{selected_release: name} = c) do
    case Map.get(c.releases, name) do
      nil ->
        {:error, :missing_release}
      release ->
        {:ok, release}
    end
  end

  # Applies the environment settings to a release
  @doc false
  @spec apply_environment(t, Environment.t) :: t
  def apply_environment(%__MODULE__{profile: rel_profile} = r, %Environment{name: env_name} = env) do
    env_profile = Map.from_struct(env.profile)

    profile =
      Enum.reduce(env_profile, rel_profile, fn {k, v}, acc ->
        case v do
          ignore when ignore in [nil, []] -> acc
          _ -> Map.put(acc, k, v)
        end
      end)

    %{r | :env => env_name, :profile => profile}
  end

  @doc false
  @spec validate_configuration(t) :: :ok | {:error, term} | {:ok, warning :: String.t}
  def validate_configuration(%__MODULE__{version: _, profile: profile}) do
    with :ok <- Utils.validate_erts(profile.include_erts),
         :ok <- validate_cookie(profile.cookie) do
      # Warn if not including ERTS when not obviously running in a dev configuration
      if profile.dev_mode == false and profile.include_erts == false do
        {:ok,
         "IMPORTANT: You have opted to *not* include the Erlang runtime system (ERTS).\n" <>
           "You must ensure that the version of Erlang this release is built with matches\n" <>
           "the version the release will be run with once deployed. It will fail to run otherwise."}
      else
        :ok
      end
    end
  end

  # Applies global configuration options to the release profile
  @doc false
  @spec apply_configuration(t, Config.t) :: {:ok, t} | {:error, term}
  @spec apply_configuration(t, Config.t, log? :: boolean) :: {:ok, t} | {:error, term}
  def apply_configuration(%__MODULE__{} = release, %Config{} = config, log? \\ false) do
    profile = release.profile

    profile =
      case profile.config do
        p when is_binary(p) ->
          %{profile | config: p}

        _ ->
          %{profile | config: Keyword.get(Mix.Project.config(), :config_path)}
      end

    profile =
      case profile.include_erts do
        p when is_binary(p) ->
          case Utils.detect_erts_version(p) do
            {:error, _} = err ->
              throw(err)

            vsn ->
              %{profile | erts_version: vsn, include_system_libs: true}
          end

        true ->
          %{profile | erts_version: Utils.erts_version(), include_system_libs: true}

        _ ->
          %{profile | erts_version: Utils.erts_version(), include_system_libs: false}
      end

    profile =
      case profile.cookie do
        nil ->
          profile

        c when is_atom(c) ->
          profile

        c when is_binary(c) ->
          %{profile | cookie: String.to_atom(c)}

        c ->
          throw({:error, {:assembler, {:invalid_cookie, c}}})
      end

    release = %{release | profile: profile}

    release =
      case Utils.get_apps(release) do
        {:error, _} = err ->
          throw(err)

        apps ->
          %{release | applications: apps}
      end

    if config.is_upgrade do
      apply_upgrade_configuration(release, config, log?)
    else
      {:ok, release}
    end
  catch
    :throw, {:error, _} = err ->
      err
  end

  defp apply_upgrade_configuration(%__MODULE__{} = release, %Config{upgrade_from: :latest}, log?) do
    current_version = release.version

    upfrom =
      case Utils.get_release_versions(release.profile.output_dir) do
        [] ->
          :no_upfrom

        [^current_version, v | _] ->
          v

        [v | _] ->
          v
      end

    case upfrom do
      :no_upfrom ->
        if log? do
          Logger.warn(
            "An upgrade was requested, but there are no " <>
              "releases to upgrade from, no upgrade will be performed."
          )
        end

        {:ok, %{release | :is_upgrade => false, :upgrade_from => nil}}

      v ->
        {:ok, %{release | :is_upgrade => true, :upgrade_from => v}}
    end
  end

  defp apply_upgrade_configuration(%__MODULE__{version: v}, %Config{upgrade_from: v}, _log?) do
    {:error, {:assembler, {:bad_upgrade_spec, :upfrom_is_current, v}}}
  end

  defp apply_upgrade_configuration(
         %__MODULE__{name: name} = release,
         %Config{upgrade_from: v},
         log?
       ) do
    current_version = release.version

    if log?,
      do: Logger.debug("Upgrading #{name} from #{v} to #{current_version}")

    upfrom_path = Path.join([release.profile.output_dir, "releases", v])

    if File.exists?(upfrom_path) do
      {:ok, %{release | :is_upgrade => true, :upgrade_from => v}}
    else
      {:error, {:assembler, {:bad_upgrade_spec, :doesnt_exist, v, upfrom_path}}}
    end
  end

  defp validate_cookie(nil) do
    warning =
      "Attention! You did not provide a cookie for the erlang distribution protocol in rel/config.exs\n" <>
        "    For backwards compatibility, the release name will be used as a cookie, which is potentially a security risk!\n" <>
        "    Please generate a secure cookie and use it with `set cookie: <cookie>` in rel/config.exs.\n" <>
        "    This will be an error in a future release."

    {:ok, warning}
  end

  defp validate_cookie(cookie) when is_atom(cookie) do
    if String.contains?(Atom.to_string(cookie), "insecure") do
      warning =
        "Attention! You have an insecure cookie for the erlang distribution protocol in rel/config.exs\n" <>
          "    This is probably because a secure cookie could not be auto-generated.\n" <>
          "    Please generate a secure cookie and use it with `set cookie: <cookie>` in rel/config.exs."

      {:ok, warning}
    else
      :ok
    end
  end

  @doc """
  Returns a list of all code_paths of all appliactions included in the release
  """
  @spec get_code_paths(t) :: [charlist]
  def get_code_paths(%__MODULE__{profile: %Profile{output_dir: output_dir}} = release) do
    release.applications
    |> Enum.flat_map(fn %App{name: name, vsn: version, path: path} ->
      lib_dir = Path.join([output_dir, "lib", "#{name}-#{version}", "ebin"])
      [String.to_charlist(lib_dir), String.to_charlist(Path.join(path, "ebin"))]
    end)
  end
end
