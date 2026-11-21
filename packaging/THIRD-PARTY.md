# 第三方组件

Lockgate 的应用包内附带以下第三方组件。它们作为独立的程序或数据文件随包分发，各自遵循原许可证。

## mihomo

- 用途：内置代理内核，由 Lockgate 作为独立进程启动。
- 来源：<https://github.com/MetaCubeX/mihomo>，官方 Release 的未修改二进制（arm64 与 amd64-compatible 合并为通用二进制）。
- 内嵌版本与校验值：见 `scripts/fetch-core.sh`。
- 许可证：MIT，全文如下。

```
Copyright 2023 KT

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the “Software”), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED “AS IS”, WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
```

## js-yaml

- 用途：解析订阅和覆写中的 YAML，源码内嵌在 `Sources/LockgateCore/JSYAMLSource.swift`，在系统的 JavaScriptCore 中运行。
- 来源：<https://github.com/nodeca/js-yaml>，npm 包 4.1.0 的 `dist/js-yaml.min.js`，未修改。
- 许可证：MIT，全文如下。

```
(The MIT License)

Copyright (C) 2011-2015 by Vitaly Puzrin

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.
```

## meta-rules-dat（geoip.metadb、GeoSite.dat）

- 用途：mihomo 的 GeoIP / GeoSite 规则数据，首次启动时复制到内核工作目录，之后由内核自行更新。
- 来源：<https://github.com/MetaCubeX/meta-rules-dat>，打包时取 `latest` Release。
- 许可证：GPL-3.0，<https://github.com/MetaCubeX/meta-rules-dat/blob/master/LICENSE>。
