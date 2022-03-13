unless System.get_env("CI") do
  ExUnit.configure(exclude: :httpbin)
end

ExUnit.start()
