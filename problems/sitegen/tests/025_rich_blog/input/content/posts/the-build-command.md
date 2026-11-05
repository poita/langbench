+++
title = "The build command"
date = "2022-02-14"
tags = ["Tooling"]
+++
The `build` command turns a source tree into a site.

```sh
sitegen ./src ./out
```

It reads `site.toml`, renders every post through the templates, and copies
everything under `static/` verbatim.

See the [documentation](https://example.com/docs) for the full list of
options.
