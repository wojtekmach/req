defmodule EzstdFilter do
  # Filter out:
  # 17:56:39.116 [debug] Loading library: ~c"/path/to/req/_build/test/lib/ezstd/priv/ezstd_nif"
  def filter(log_event, _opts) do
    case log_event.msg do
      {"Loading library" <> _, [path]} ->
        ^path = to_charlist(Application.app_dir(:ezstd, "priv/ezstd_nif"))
        :stop

      _ ->
        :ignore
    end
  end
end

:logger.add_primary_filter(:ezstd_filter, {&EzstdFilter.filter/2, []})

ExUnit.configure(exclude: :integration)
ExUnit.start()
