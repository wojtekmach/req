excludes = [:integration]
excludes = excludes ++ if System.otp_release() < "24", do: [:otp24], else: []

ExUnit.configure(exclude: excludes)
ExUnit.start()
