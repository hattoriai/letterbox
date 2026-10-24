defmodule LetterboxTest.Host do
  @moduledoc "An app that mounts the development page, for its tests."
  use PhoenixMountable.TestHost,
    otp_app: :letterbox,
    mounts: [{Letterbox.Dev.Router, "/dev/letterbox"}]
end
