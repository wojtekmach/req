# This is a hack to suppress output from ezstd on_load.
# The proper fix is https://github.com/silviucpp/ezstd/pull/3.
:ezstd.compress("")
IO.write([IO.ANSI.cursor_up(), IO.ANSI.clear_line()])

unless System.get_env("CI") do
  ExUnit.configure(exclude: :integration)
end

ExUnit.start()
