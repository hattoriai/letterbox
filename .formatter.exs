# Used by "mix format"
[
  import_deps: [:ecto, :ecto_sql, :phoenix, :phoenix_mountable],
  inputs: ["{mix,.formatter}.exs", "{config,lib,test,scripts}/**/*.{ex,exs}"],
  locals_without_parens: [route: 2],
  export: [locals_without_parens: [route: 2]]
]
