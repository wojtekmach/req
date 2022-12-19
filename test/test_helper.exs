unless System.get_env("CI") do
  ExUnit.configure(exclude: :integration)
end

ExUnit.start()
