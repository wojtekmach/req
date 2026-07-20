defmodule Req.AuthTest do
  use Req.Case, async: true

  test "string" do
    %{req: req} =
      serve(
        "GET /": fn conn ->
          assert get_req_header(conn, "authorization") == ["foo"]
          send_resp(conn, 200, "")
        end
      )

    Req.get!(req, auth: "foo")
  end

  test "basic" do
    %{req: req} =
      serve(
        "GET /": fn conn ->
          expected = "Basic " <> Base.encode64("foo:bar")
          assert get_req_header(conn, "authorization") == [expected]
          send_resp(conn, 200, "")
        end
      )

    Req.get!(req, auth: {:basic, "foo:bar"})
  end

  test "bearer" do
    %{req: req} =
      serve(
        "GET /": fn conn ->
          assert get_req_header(conn, "authorization") == ["Bearer abcd"]
          send_resp(conn, 200, "")
        end
      )

    Req.get!(req, auth: {:bearer, "abcd"})
  end

  test "mfa" do
    defmodule AuthToken do
      def generate, do: {:bearer, "abcd"}
    end

    %{req: req} =
      serve(
        "GET /": fn conn ->
          assert get_req_header(conn, "authorization") == ["Bearer abcd"]
          send_resp(conn, 200, "")
        end
      )

    Req.get!(req, auth: {AuthToken, :generate, []})
  end

  describe "digest" do
    test "simple" do
      %{req: req} =
        serve(
          "GET /": fn conn ->
            # Does not apply authorization header until after the pre-authorized request is made
            assert get_req_header(conn, "authorization") == []
            send_resp(conn, 200, "")
          end
        )

      Req.get!(req, auth: {:digest, "foo:bar"})
    end

    test "md5 challenge" do
      %{req: req} =
        serve(
          "GET /": fn conn ->
            case get_req_header(conn, "authorization") do
              [] ->
                conn
                |> put_resp_header(
                  "www-authenticate",
                  ~s|Digest realm="test", nonce="1234567890"|
                )
                |> send_resp(401, "Unauthorized")

              [authorization | _] ->
                has_expected_header? =
                  String.starts_with?(authorization, "Digest ") and
                    authorization =~ ~r/username="foo"/ and
                    authorization =~ ~r/realm="test"/ and
                    authorization =~ ~r/nonce="1234567890"/ and
                    authorization =~ ~r/uri="\/"/ and
                    authorization =~ ~r/response="402359218de50d24c1c39d8c3c41a0c4"/

                if has_expected_header? do
                  send_resp(conn, 200, "OK")
                else
                  send_resp(conn, 401, "Unauthorized")
                end
            end
          end
        )

      resp = Req.get!(req, auth: {:digest, "foo:bar"})
      assert resp.status == 200
    end

    test "sha-256 challenge" do
      %{req: req} =
        serve(
          "GET /": fn conn ->
            case get_req_header(conn, "authorization") do
              [] ->
                conn
                |> put_resp_header(
                  "www-authenticate",
                  ~s|Digest realm="test", nonce="1234567890", algorithm=SHA-256|
                )
                |> send_resp(401, "Unauthorized")

              [authorization | _] ->
                has_expected_header? =
                  String.starts_with?(authorization, "Digest ") and
                    authorization =~ ~r/username="foo"/ and
                    authorization =~ ~r/realm="test"/ and
                    authorization =~ ~r/nonce="1234567890"/ and
                    authorization =~ ~r/uri="\/"/ and
                    authorization =~
                      ~r/response="79fbcaf8e746ff152ab381f928ee1f5875ef3dab475937cd7a6f2a34c0941021\"/

                if has_expected_header? do
                  send_resp(conn, 200, "OK")
                else
                  send_resp(conn, 401, "Unauthorized")
                end
            end
          end
        )

      resp = Req.get!(req, auth: {:digest, "foo:bar"})
      assert resp.status == 200
    end

    test "no challenge" do
      %{req: req} =
        serve(
          "GET /": fn conn ->
            send_resp(conn, 401, "Unauthorized")
          end
        )

      resp = Req.get!(req, auth: {:digest, "foo:bar"})
      assert resp.status == 401
    end

    @tag :capture_log
    test "unsupported digest algorithm" do
      %{req: req} =
        serve(
          "GET /": fn conn ->
            conn
            |> put_resp_header(
              "www-authenticate",
              ~s|Digest realm="test", nonce="1234567890", algorithm=UNSUPPORTED|
            )
            |> send_resp(401, "Unauthorized")
          end
        )

      resp = Req.get!(req, auth: {:digest, "foo:bar"})
      assert resp.status == 401

      assert Req.Response.get_header(resp, "www-authenticate") == [
               ~s|Digest realm="test", nonce="1234567890", algorithm=UNSUPPORTED|
             ]
    end

    test "unauthorized after challenge" do
      %{req: req} =
        serve(
          "GET /": fn conn ->
            conn
            |> put_resp_header(
              "www-authenticate",
              ~s|Digest realm="test", nonce="1234567890", algorithm=MD5|
            )
            |> send_resp(401, "Unauthorized")
          end
        )

      resp = Req.get!(req, auth: {:digest, "foo:bar"})
      assert resp.status == 401
    end

    test "quoted values and paths" do
      %{req: req, url: url} =
        serve(
          "GET /some/path": fn conn ->
            case get_req_header(conn, "authorization") do
              [] ->
                conn
                |> put_resp_header(
                  "www-authenticate",
                  ~s|Digest realm="test \\"realm\\"", nonce="1234567890"|
                )
                |> send_resp(401, "Unauthorized")

              [authorization | _] ->
                has_expected_header? =
                  String.starts_with?(authorization, "Digest ") and
                    authorization =~ ~r/username="foo \\"bar\\""/ and
                    authorization =~ ~r/realm="test \\"realm\\""/ and
                    authorization =~ ~r/nonce="1234567890"/ and
                    authorization =~ ~r/uri="\/some\/path"/ and
                    authorization =~ ~r/response="872e1593ea4d45f4d0a099614a6b9632\"/

                if has_expected_header? do
                  send_resp(conn, 200, "OK")
                else
                  send_resp(conn, 401, "Unauthorized")
                end
            end
          end
        )

      resp = Req.get!(req, url: "#{url}/some/path", auth: {:digest, "foo \"bar\":bar"})
      assert resp.status == 200
    end

    test "with qop" do
      %{req: req} =
        serve(
          "GET /": fn conn ->
            case get_req_header(conn, "authorization") do
              [] ->
                conn
                |> put_resp_header(
                  "www-authenticate",
                  ~s|Digest realm="test", nonce="1234567890", qop="auth"|
                )
                |> send_resp(401, "Unauthorized")

              [authorization | _] ->
                # Calculate expected response using cnonce
                cnonce = ~r/cnonce="([a-f0-9]+)"/ |> Regex.run(authorization) |> Enum.at(1)

                ha1 = :crypto.hash(:md5, "foo:test:bar") |> Base.encode16(case: :lower)
                ha2 = :crypto.hash(:md5, "GET:/") |> Base.encode16(case: :lower)

                expected_response =
                  :crypto.hash(
                    :md5,
                    # Response is calculated by hash_func(ha1:nonce:nc:cnonce:qop:ha2)
                    "#{ha1}:1234567890:00000001:#{cnonce}:auth:#{ha2}"
                  )
                  |> Base.encode16(case: :lower)

                has_expected_header? =
                  String.starts_with?(authorization, "Digest ") and
                    authorization =~ ~r/username="foo"/ and
                    authorization =~ ~r/realm="test"/ and
                    authorization =~ ~r/nonce="1234567890"/ and
                    authorization =~ ~r/uri="\/"/ and
                    authorization =~ ~r/response="#{expected_response}"/ and
                    authorization =~ ~r/qop=auth/ and
                    authorization =~ ~r/nc=00000001/ and
                    authorization =~ ~r/cnonce="#{cnonce}"/

                if has_expected_header? do
                  send_resp(conn, 200, "OK")
                else
                  send_resp(conn, 401, "Unauthorized")
                end
            end
          end
        )

      resp = Req.get!(req, auth: {:digest, "foo:bar"})
      assert resp.status == 200
    end

    test "with session" do
      %{req: req} =
        serve(
          "GET /": fn conn ->
            case get_req_header(conn, "authorization") do
              [] ->
                conn
                |> put_resp_header(
                  "www-authenticate",
                  ~s|Digest realm="test", nonce="1234567890", algorithm=MD5-SESS|
                )
                |> send_resp(401, "Unauthorized")

              [authorization | _] ->
                # Calculate expected response using cnonce
                cnonce = ~r/cnonce="([a-f0-9]+)"/ |> Regex.run(authorization) |> Enum.at(1)
                ha1 = :crypto.hash(:md5, "foo:test:bar") |> Base.encode16(case: :lower)

                ha1 =
                  :crypto.hash(:md5, "#{ha1}:1234567890:#{cnonce}") |> Base.encode16(case: :lower)

                ha2 = :crypto.hash(:md5, "GET:/") |> Base.encode16(case: :lower)

                expected_response =
                  :crypto.hash(
                    :md5,
                    "#{ha1}:1234567890:#{ha2}"
                  )
                  |> Base.encode16(case: :lower)

                has_expected_header? =
                  String.starts_with?(authorization, "Digest ") and
                    authorization =~ ~r/username="foo"/ and
                    authorization =~ ~r/realm="test"/ and
                    authorization =~ ~r/nonce="1234567890"/ and
                    authorization =~ ~r/uri="\/"/ and
                    authorization =~ ~r/response="#{expected_response}"/ and
                    authorization =~ ~r/cnonce="#{cnonce}"/

                if has_expected_header? do
                  send_resp(conn, 200, "OK")
                else
                  send_resp(conn, 401, "Unauthorized")
                end
            end
          end
        )

      resp = Req.get!(req, auth: {:digest, "foo:bar"})
      assert resp.status == 200
    end
  end

  describe "netrc" do
    @tag :tmp_dir
    test "auth: :netrc", c do
      %{req: req} =
        serve(
          "GET /": fn conn ->
            expected = "Basic " <> Base.encode64("foo:bar")

            case get_req_header(conn, "authorization") do
              [^expected] ->
                send_resp(conn, 200, "ok")

              _ ->
                send_resp(conn, 401, "unauthorized")
            end
          end
        )

      old_netrc = System.get_env("NETRC")

      System.put_env("NETRC", "#{c.tmp_dir}/.netrc")

      File.write!("#{c.tmp_dir}/.netrc", """
      machine localhost
      login foo
      password bar
      """)

      assert Req.get!(req, auth: :netrc).status == 200

      System.put_env("NETRC", "#{c.tmp_dir}/tabs")

      File.write!("#{c.tmp_dir}/tabs", """
      machine localhost
           login foo
           password bar
      """)

      assert Req.get!(req, auth: :netrc).status == 200

      System.put_env("NETRC", "#{c.tmp_dir}/single_line")

      File.write!("#{c.tmp_dir}/single_line", """
      machine otherhost
      login meat
      password potatoes
      machine localhost login foo password bar
      """)

      assert Req.get!(req, auth: :netrc).status == 200

      if old_netrc, do: System.put_env("NETRC", old_netrc), else: System.delete_env("NETRC")
    end

    @tag :tmp_dir
    test "auth: {:netrc, path}", c do
      %{req: req} =
        serve(
          "GET /": fn conn ->
            expected = "Basic " <> Base.encode64("foo:bar")

            case get_req_header(conn, "authorization") do
              [^expected] ->
                send_resp(conn, 200, "ok")

              _ ->
                send_resp(conn, 401, "unauthorized")
            end
          end
        )

      assert_raise RuntimeError, "error reading .netrc file: no such file or directory", fn ->
        Req.get!(req, auth: {:netrc, "non_existent_file"})
      end

      File.write!("#{c.tmp_dir}/custom_netrc", """
      machine localhost
      login foo
      password bar
      """)

      assert Req.get!(req, auth: {:netrc, c.tmp_dir <> "/custom_netrc"}).status == 200

      File.write!("#{c.tmp_dir}/wrong_netrc", """
      machine localhost
      login bad
      password bad
      """)

      assert Req.get!(req, auth: {:netrc, "#{c.tmp_dir}/wrong_netrc"}).status == 401

      File.write!("#{c.tmp_dir}/empty_netrc", "")

      assert_raise RuntimeError, ".netrc file is empty", fn ->
        Req.get!(req, auth: {:netrc, "#{c.tmp_dir}/empty_netrc"})
      end

      File.write!("#{c.tmp_dir}/bad_netrc", """
      bad
      """)

      assert_raise RuntimeError, "error parsing .netrc file", fn ->
        Req.get!(req, auth: {:netrc, "#{c.tmp_dir}/bad_netrc"})
      end
    end
  end
end
